//! Jev readiness is local metadata, never a key load or a provider request.
const std = @import("std");
const io = @import("../vendor/fx/src/core/shared/io.zig");
const keys = @import("credentials.zig");
const decision = @import("loops/decision.zig");
const schema = @import("loops/schema.zig");
const store = @import("loops/store.zig");
pub const Snapshot = @import("../vendor/fx/src/core/output/output_contracts.zig").DecisionStatus;
const Allocator = std.mem.Allocator;

pub const Probe = struct {
    context: ?*anyopaque = null,
    environment: *const fn (?*anyopaque, []const u8) ?[]const u8 = realEnvironment,
    saved: *const fn (?*anyopaque, Allocator, []const u8) anyerror!keys.Presence = realSaved,
    fn realEnvironment(_: ?*anyopaque, name: []const u8) ?[]const u8 {
        return io.getenv(name);
    }
    fn realSaved(_: ?*anyopaque, alloc: Allocator, name: []const u8) !keys.Presence {
        return keys.presenceSaved(alloc, name);
    }
};

/// Borrowed policy strings must outlive the returned snapshot. Probe has no secret-load API.
pub fn fromPolicy(alloc: Allocator, policy: decision.Policy, probe: Probe) Snapshot {
    var result: Snapshot = .{ .model = policy.model, .api_key_env = policy.env };
    if (probe.environment(probe.context, policy.env)) |key| {
        // Match execution's environment precedence, including invalid overrides.
        keys.validateKey(key) catch return result;
        result.credential_presence = .present;
        result.credential_source = .environment;
        return result;
    }
    const presence = probe.saved(probe.context, alloc, policy.env) catch return result;
    switch (presence) {
        .present => {
            result.credential_presence = .present;
            result.credential_source = .saved;
        },
        .missing => {
            result.credential_presence = .missing;
            result.credential_source = .none;
        },
        .unavailable => {},
    }
    return result;
}

/// No installation file means default policy; unsafe/unreadable policy is unknown.
pub fn loadPolicy(alloc: Allocator) !decision.Policy {
    const profile = if (io.getenv("FH_DATA_DIR")) |root| root else blk: {
        const home = io.getenv("HOME") orelse return error.MissingHome;
        break :blk try std.fs.path.join(alloc, &.{ home, ".fh" });
    };
    if (!std.fs.path.isAbsolute(profile)) return error.InvalidProfilePath;
    var dir = store.openDirectory(io.getIo(), profile) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer dir.close(io.getIo());
    try store.privateHandle(dir.handle, false);
    var file = io.openExistingRegularFile(dir, "installation.json", .read_only) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close(io.getIo());
    try store.privateHandle(file.handle, true);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io.getIo(), &buffer);
    const bytes = try reader.interface.allocRemaining(alloc, .limited(1048576));
    const configuration = try schema.parse(alloc, bytes);
    return decision.policyConfiguration(configuration);
}

/// `alloc` is the caller's command arena. All provider access remains unverified.
pub fn inspect(alloc: Allocator) !Snapshot {
    const policy = loadPolicy(alloc) catch return .{ .provider = null, .model = null, .api_key_env = null };
    return fromPolicy(alloc, policy, .{});
}

const Fixture = struct {
    key: ?[]const u8 = null,
    presence: keys.Presence = .missing,
    saved_calls: usize = 0,
    fail: bool = false,
    fn environment(raw: ?*anyopaque, name: []const u8) ?[]const u8 {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        std.debug.assert(std.mem.eql(u8, name, "CUSTOM_JEV_KEY"));
        return self.key;
    }
    fn saved(raw: ?*anyopaque, _: Allocator, name: []const u8) !keys.Presence {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        try std.testing.expectEqualStrings("CUSTOM_JEV_KEY", name);
        self.saved_calls += 1;
        if (self.fail) return error.TestStorageFailure;
        return self.presence;
    }
    fn probe(self: *Fixture) Probe {
        return .{ .context = self, .environment = environment, .saved = saved };
    }
};

test "fh native Jev readiness uses custom environment precedence and masks all credentials" {
    var fixture: Fixture = .{ .key = "synthetic-environment-secret", .presence = .present };
    const policy: decision.Policy = .{ .model = "custom-jev", .env = "CUSTOM_JEV_KEY" };
    var snapshot = fromPolicy(std.testing.allocator, policy, fixture.probe());
    try std.testing.expectEqual(.present, snapshot.credential_presence);
    try std.testing.expectEqual(.environment, snapshot.credential_source);
    try std.testing.expectEqual(@as(usize, 0), fixture.saved_calls);
    var encoded = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer encoded.deinit();
    try std.json.Stringify.value(snapshot, .{}, &encoded.writer);
    try std.testing.expect(std.mem.find(u8, encoded.written(), fixture.key.?) == null);
    try std.testing.expect(std.mem.find(u8, encoded.written(), "not_checked") != null);
    fixture.key = null;
    snapshot = fromPolicy(std.testing.allocator, policy, fixture.probe());
    try std.testing.expectEqual(.saved, snapshot.credential_source);
    fixture.presence = .missing;
    snapshot = fromPolicy(std.testing.allocator, policy, fixture.probe());
    try std.testing.expectEqual(.missing, snapshot.credential_presence);
    fixture.fail = true;
    snapshot = fromPolicy(std.testing.allocator, policy, fixture.probe());
    try std.testing.expectEqual(.unknown, snapshot.credential_presence);
    fixture.key = "invalid override";
    const calls = fixture.saved_calls;
    snapshot = fromPolicy(std.testing.allocator, policy, fixture.probe());
    try std.testing.expectEqual(.unknown, snapshot.credential_presence);
    try std.testing.expectEqual(calls, fixture.saved_calls);
}

test "fh native Jev readiness defaults absent and null policy consistently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "{}", "{\"decision\":null}", "{\"decision\":{}}" }) |bytes| {
        const policy = try decision.policyConfiguration(try schema.parse(arena.allocator(), bytes));
        try std.testing.expectEqualStrings("jev-1.13.0", policy.model);
        try std.testing.expectEqualStrings("TYPESAFE_API_KEY", policy.env);
    }
    const policy = try decision.policyConfiguration(try schema.parse(arena.allocator(), "{\"decision\":{\"model\":\"custom-jev\",\"apiKeyEnv\":\"CUSTOM_JEV_KEY\"}}"));
    try std.testing.expectEqualStrings("CUSTOM_JEV_KEY", policy.env);
    try std.testing.expectError(error.InvalidDecisionPolicy, decision.policyConfiguration(try schema.parse(arena.allocator(), "{\"decision\":{\"apiKeyEnv\":\"2BAD\"}}")));
}
