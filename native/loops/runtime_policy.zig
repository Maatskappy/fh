//! Context for source-runtime configuration failures, independent of Docker admission.
const std = @import("std");
const code = @import("code.zig");
const deps = @import("dependencies.zig");
const schema = @import("schema.zig");
const Value = std.json.Value;
pub const Issue = struct {
    path_buffer: [1024]u8 = undefined,
    message_buffer: [2048]u8 = undefined,
    path_len: usize = 0,
    message_len: usize = 0,
    pub fn path(self: *const Issue) []const u8 {
        return self.path_buffer[0..self.path_len];
    }
    pub fn message(self: *const Issue) []const u8 {
        return self.message_buffer[0..self.message_len];
    }
    pub fn reject(self: *Issue, path_text: []const u8, expected: []const u8, actual: []const u8, err: anyerror) anyerror {
        self.path_len = @min(path_text.len, self.path_buffer.len);
        @memcpy(self.path_buffer[0..self.path_len], path_text[0..self.path_len]);
        self.path_len = abbreviate(self.path_buffer[0..self.path_len], path_text.len > self.path_len);
        var message_writer = std.Io.Writer.fixed(&self.message_buffer);
        var truncated = false;
        // The reason must survive even when the expected value includes a long artifact.
        message_writer.print("{s}: actual {s}; expected {s}.", .{ self.path(), actual, expected }) catch {
            truncated = true;
        };
        self.message_len = abbreviate(message_writer.buffered(), truncated);
        return err;
    }
    fn abbreviate(bytes: []u8, truncated: bool) usize {
        if (!truncated) return bytes.len;
        const marker = "...";
        var end = bytes.len - marker.len;
        // Both inputs and formatted fields are UTF-8; only the bounded cut can split one.
        while (end > 0 and bytes[end] & 0xc0 == 0x80) end -= 1;
        @memcpy(bytes[end..][0..marker.len], marker);
        return end + marker.len;
    }
};
pub const Profile = struct { runtime: code.Runtime, value: Value, version: [3]u32, modules: Value };
pub fn moduleKey(runtime: code.Runtime) []const u8 {
    return if (runtime == .node) "builtins" else "stdlib";
}
pub fn family(runtime: code.Runtime) []const u8 {
    return if (runtime == .node) "builtin" else "stdlib";
}
pub fn imageValid(image: []const u8) bool {
    const marker = std.mem.lastIndexOf(u8, image, "@sha256:") orelse return false;
    if (marker == 0 or image.len - marker - 8 != 64) return false;
    for (image[marker + 8 ..]) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    for (image[0..marker]) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "./_-", c) == null) return false;
    return true;
}
pub fn socketValid(path: []const u8) bool {
    // Match the Docker transport's existing sockaddr and control-character contract.
    if (!std.fs.path.isAbsolute(path) or path.len >= @sizeOf(@FieldType(std.c.sockaddr.un, "path"))) return false;
    for (path) |c| if (c < 32 or c == 127) return false;
    return true;
}
fn field(alloc: std.mem.Allocator, runtime: []const u8, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "runtimeProfiles.{s}.{s}", .{ runtime, key });
}
fn text(issue: *Issue, value: Value, key: []const u8, path: []const u8) ![]const u8 {
    const v = schema.get(value, key) orelse return issue.reject(path, "a nonempty string", "missing", error.InvalidBindings);
    if (v != .string or v.string.len == 0) return issue.reject(path, "a nonempty string", "wrong type or empty", error.InvalidBindings);
    return v.string;
}
// Existing installation profiles accepted major.minor; new manifest minima and setup
// arguments require all three components. Preserve those older profile declarations.
fn profileVersion(alloc: std.mem.Allocator, raw: []const u8) ![3]u32 {
    if (std.mem.count(u8, raw, ".") == 1) return deps.version(try std.fmt.allocPrint(alloc, "{s}.0", .{raw}));
    return deps.version(raw);
}
pub fn validate(alloc: std.mem.Allocator, configuration: Value, registered: Value, name: []const u8, issue: *Issue) !Profile {
    const path = try std.fmt.allocPrint(alloc, "runtimeProfiles.{s}", .{name});
    const runtime = std.meta.stringToEnum(code.Runtime, name) orelse return issue.reject(path, "supported source runtime python3 or node", "unknown runtime", error.UnsupportedRuntime);
    const profiles = schema.get(configuration, "runtimeProfiles") orelse .null;
    const profile = schema.get(profiles, name) orelse {
        const advice = try std.fmt.allocPrint(alloc, "registered optional {s} source runtime; run fh setup runtime {s} --socket /absolute/docker.sock --image IMAGE@sha256:DIGEST --version MAJOR.MINOR.PATCH", .{ name, name });
        return issue.reject(path, advice, "missing (fh itself is native Zig)", error.RuntimeUnbound);
    };
    if (profile != .object) return issue.reject(path, "runtime profile object", "wrong type", error.InvalidBindings);
    const available = schema.get(profile, "available") orelse return issue.reject(try field(alloc, name, "available"), "true", "missing", error.UnsupportedRuntime);
    if (available != .bool or !available.bool) return issue.reject(try field(alloc, name, "available"), "true", "unavailable or wrong type", error.UnsupportedRuntime);
    const f = try text(issue, profile, "profile", try field(alloc, name, "profile"));
    if (!std.mem.eql(u8, f, family(runtime))) return issue.reject(try field(alloc, name, "profile"), family(runtime), f, error.UnsupportedRuntime);
    const raw = try text(issue, profile, "version", try field(alloc, name, "version"));
    const v = profileVersion(alloc, raw) catch return issue.reject(try field(alloc, name, "version"), "numeric MAJOR.MINOR[.PATCH]", raw, error.UnsupportedRuntime);
    if (!code.supportedVersion(runtime, v)) return issue.reject(try field(alloc, name, "version"), if (runtime == .node) "Node 22.15+, 23.5+ or 24+" else "Python 3.10+", raw, error.UnsupportedRuntime);
    const image = try text(issue, profile, "image", try field(alloc, name, "image"));
    if (!imageValid(image)) return issue.reject(try field(alloc, name, "image"), "immutable IMAGE@sha256: followed by 64 lowercase hex digits", "invalid image", error.RuntimeUnsupported);
    const interpreter_key = if (runtime == .node) "node" else "python";
    if (schema.get(profile, interpreter_key)) |interpreter| {
        const fixed = if (runtime == .node) "/usr/local/bin/node" else "/usr/bin/python3";
        if (interpreter != .string or !std.mem.eql(u8, interpreter.string, fixed)) return issue.reject(try field(alloc, name, interpreter_key), fixed, "non-fixed interpreter", error.RuntimeUnsupported);
    }
    const modules = schema.get(profile, moduleKey(runtime)) orelse return issue.reject(try field(alloc, name, moduleKey(runtime)), "module inventory array", "missing", error.InvalidBindings);
    if (modules != .array) return issue.reject(try field(alloc, name, moduleKey(runtime)), "module inventory array", "wrong type", error.InvalidBindings);
    for (modules.array.items) |m| if (m != .string or m.string.len == 0) return issue.reject(try field(alloc, name, moduleKey(runtime)), "nonempty module names", "invalid entry", error.InvalidBindings);
    const resources = schema.get(profile, "resources") orelse return issue.reject(try field(alloc, name, "resources"), "nonempty logical resource array", "missing", error.RuntimeUnbound);
    if (resources != .array or resources.array.items.len == 0) return issue.reject(try field(alloc, name, "resources"), "nonempty logical resource array", "empty or wrong type", error.RuntimeUnbound);
    var runtime_count: usize = 0;
    for (resources.array.items) |logical| {
        if (logical != .string) return issue.reject(try field(alloc, name, "resources"), "logical resource names", "wrong type", error.InvalidBindings);
        const resource_path = try std.fmt.allocPrint(alloc, "bindings.{s}.resources.{s}", .{ (schema.get(registered, "id") orelse return error.InvalidBindings).string, logical.string });
        const handle = schema.get(schema.get(registered, "resources") orelse .null, logical.string) orelse return issue.reject(resource_path, "registered resource handle", "missing", error.MissingBinding);
        if (handle != .string) return issue.reject(resource_path, "resource handle string", "wrong type", error.InvalidBindings);
        const resource = schema.get(schema.get(configuration, "resources") orelse .null, handle.string) orelse return issue.reject(resource_path, "existing resource", "missing", error.MissingBinding);
        const kind = schema.get(resource, "kind") orelse return issue.reject(resource_path, "resource kind", "missing", error.InvalidBindings);
        if (kind == .string and std.mem.eql(u8, kind.string, "runtime")) runtime_count += 1;
    }
    if (runtime_count != 1) return issue.reject(try field(alloc, name, "resources"), "exactly one kind=runtime resource", "missing or ambiguous runtime handle", error.RuntimeUnbound);
    const docker = schema.get(configuration, "docker") orelse return issue.reject("docker.socketPath", "absolute Docker-compatible socket path", "docker missing", error.MissingBinding);
    const socket = try text(issue, docker, "socketPath", "docker.socketPath");
    if (!socketValid(socket)) return issue.reject("docker.socketPath", "absolute Unix socket path accepted by the Docker transport", "relative, oversized or control-character path", error.InvalidBindings);
    const digest_path = try std.fmt.allocPrint(alloc, "bindings.{s}.policyDigest", .{(schema.get(registered, "id") orelse return error.InvalidBindings).string});
    const digest = try text(issue, registered, "policyDigest", digest_path);
    if (digest.len != 64) return issue.reject(digest_path, "64 lowercase hex digits", "invalid policy digest", error.InvalidBindings);
    for (digest) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return issue.reject(digest_path, "64 lowercase hex digits", "invalid policy digest", error.InvalidBindings);
    return .{ .runtime = runtime, .value = profile, .version = v, .modules = modules };
}
pub fn minimum(alloc: std.mem.Allocator, runtime: []const u8, requirement: Value, actual: [3]u32, measured: bool, issue: *Issue) !void {
    const expected = (schema.get(requirement, "min_version") orelse return error.InvalidDependencies).string;
    if (!deps.atLeast(actual, try deps.version(expected))) {
        const path = try std.fmt.allocPrint(alloc, "dependencies.runtimes.{s}.min_version", .{runtime});
        const value = try std.fmt.allocPrint(alloc, "{d}.{d}.{d} ({s})", .{ actual[0], actual[1], actual[2], if (measured) "probed/cached interpreter" else "configured profile" });
        return issue.reject(path, expected, value, error.UnsupportedRuntime);
    }
}

test "native missing source runtime parent and entry share complete setup advice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{}", "{\"runtimeProfiles\":{}}" }) |bytes| {
        const configuration = try schema.parse(a, bytes);
        for ([_][]const u8{ "node", "python3" }) |name| {
            var issue: Issue = .{};
            try std.testing.expectError(error.RuntimeUnbound, validate(a, configuration, .null, name, &issue));
            try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "runtimeProfiles.{s}", .{name}), issue.path());
            const command = try std.fmt.allocPrint(a, "fh setup runtime {s} --socket /absolute/docker.sock --image IMAGE@sha256:DIGEST --version MAJOR.MINOR.PATCH", .{name});
            try std.testing.expect(std.mem.indexOf(u8, issue.message(), command) != null);
            try std.testing.expect(std.mem.indexOf(u8, issue.message(), "fh itself is native Zig") != null);
        }
    }
}

test "native runtime issue keeps multibyte paths and full message boundaries as JSON strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The steps. prefix makes the existing path bound split a four-byte character.
    var issue: Issue = .{};
    const path = "steps." ++ "🙂" ** 300 ++ ".file";
    try std.testing.expectEqual(error.WasmImport, issue.reject(path, "wasm32-wasi-json/1", "unsupported import random_get", error.WasmImport));
    try std.testing.expect(std.unicode.utf8ValidateSlice(issue.path()));
    try std.testing.expect(std.mem.endsWith(u8, issue.path(), "..."));
    try std.testing.expect(std.mem.indexOf(u8, issue.message(), "random_get") != null);
    const encoded = try std.json.Stringify.valueAlloc(a, .{ .path = issue.path(), .message = issue.message() }, .{});
    const decoded = try schema.parse(a, encoded);
    try std.testing.expect(schema.get(decoded, "path").? == .string);
    try std.testing.expect(schema.get(decoded, "message").? == .string);

    // A source-profile value also crosses the independent final-message bound.
    try std.testing.expectEqual(error.UnsupportedRuntime, issue.reject("runtimeProfiles.node.version", "numeric version", "🙂" ** 700, error.UnsupportedRuntime));
    try std.testing.expect(issue.message_len <= issue.message_buffer.len);
    try std.testing.expect(issue.message_len > issue.message_buffer.len - "🙂".len - "...".len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(issue.message()));
    try std.testing.expect(std.mem.endsWith(u8, issue.message(), "..."));
    const full = try schema.parse(a, try std.json.Stringify.valueAlloc(a, .{ .path = issue.path(), .message = issue.message() }, .{}));
    try std.testing.expect(schema.get(full, "path").? == .string);
    try std.testing.expect(schema.get(full, "message").? == .string);
}
