//! Sequential case execution/evaluation over the ordinary durable runner.
const std = @import("std");
const code = @import("loops/code.zig");
const runner = @import("loops/runner.zig");
const A = std.mem.Allocator;
const V = std.json.Value;
pub const max_cases = 1000;
pub const max_suite_bytes = 16 * 1048576;
pub const max_report_bytes = 16 * 1048576;
pub const Case = struct { id: []const u8, input: V, source: []const u8, pointer: ?[]const u8 = null, expected: V = .null };
pub const Suite = struct {
    arena: std.heap.ArenaAllocator,
    cases: []const Case,
    source: []const u8,
    pub fn deinit(self: *Suite) void {
        self.arena.deinit();
    }
};
pub const Reply = struct { value: V, is_error: bool = false };
pub const Ports = struct {
    context: *anyopaque,
    callFn: *const fn (*anyopaque, A, []const u8, V) anyerror!Reply,
    eventFn: ?*const fn (*anyopaque, V) anyerror!void = null,
    cancelledFn: *const fn (*anyopaque) bool,
    /// The run the failed call had already been given, if any, so a worker error still names it.
    acceptedFn: ?*const fn (*anyopaque) ?[]const u8 = null,
};
fn object() V {
    return .{ .object = .empty };
}
fn str(s: []const u8) V {
    return .{ .string = s };
}
fn put(a: A, v: *V, key: []const u8, item: V) !void {
    try v.object.put(a, key, item);
}
fn get(v: V, key: []const u8) ?V {
    return if (v == .object) v.object.get(key) else null;
}
fn text(v: V, key: []const u8) ?[]const u8 {
    const value = get(v, key) orelse return null;
    return if (value == .string) value.string else null;
}
fn fields(v: V, names: []const []const u8) !void {
    if (v != .object) return error.InvalidCases;
    for (v.object.keys()) |key| {
        var found = false;
        for (names) |name| if (std.mem.eql(u8, name, key)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidCases;
    }
}
fn validatePointer(path: []const u8) !void {
    if (path.len > 4096 or (path.len > 0 and path[0] != '/')) return error.InvalidCases;
    var i: usize = 0;
    while (i < path.len) : (i += 1) if (path[i] == '~') {
        i += 1;
        if (i == path.len or (path[i] != '0' and path[i] != '1')) return error.InvalidCases;
    };
}
fn validateExpected(value: V) !void {
    switch (value) {
        .number_string => return error.InvalidCases,
        .array => |items| for (items.items) |item| try validateExpected(item),
        .object => |items| for (items.values()) |item| try validateExpected(item),
        else => {},
    }
}
fn readFile(a: A, io: std.Io, path: []const u8, cap: usize) ![]const u8 {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
    var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > cap) return error.CasesLimit;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(a, .limited(cap)) catch |err| if (err == error.StreamTooLong) error.CasesLimit else err;
}
pub fn fromBytes(owner: A, io: std.Io, bytes: []const u8, source: []const u8, evaluate: bool) !Suite {
    var unused: Refused = .{};
    return fromBytesReporting(owner, io, bytes, source, evaluate, &unused);
}
pub fn fromBytesReporting(owner: A, io: std.Io, bytes: []const u8, source: []const u8, evaluate: bool, refused: *Refused) !Suite {
    var arena = std.heap.ArenaAllocator.init(owner);
    errdefer arena.deinit();
    const a = arena.allocator();
    if (bytes.len > max_suite_bytes) return error.CasesLimit;
    const value = code.parse(a, bytes, max_suite_bytes) catch return error.InvalidCases;
    try fields(value, &.{"cases"});
    const items = get(value, "cases") orelse return error.InvalidCases;
    if (items != .array or items.array.items.len == 0 or items.array.items.len > max_cases) return error.CasesLimit;
    const cases = try a.alloc(Case, items.array.items.len);
    var captured_bytes: usize = bytes.len;
    for (items.array.items, cases, 0..) |item, *case, i| {
        try fields(item, &.{ "id", "input", "input_file", "expect" });
        const id = text(item, "id") orelse return error.InvalidCases;
        if (id.len == 0 or id.len > 256) return error.InvalidCases;
        for (cases[0..i]) |prior| if (std.mem.eql(u8, prior.id, id)) return error.DuplicateCase;
        if ((get(item, "input") != null) == (get(item, "input_file") != null)) return error.InvalidCases;
        var input: V = undefined;
        var input_source: []const u8 = undefined;
        if (text(item, "input_file")) |file| {
            if (file.len == 0 or file.len > 4096 or std.mem.indexOfScalar(u8, file, 0) != null) return error.InvalidCases;
            // "Relative to the suite file" means inside its directory: a cases file is data,
            // and must not be able to point the runner at any file the user can read.
            var parts = std.mem.splitScalar(u8, file, '/');
            var outside = std.fs.path.isAbsolute(file);
            while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) {
                outside = true;
            };
            if (outside) {
                @memcpy(refused.buffer[0..id.len], id);
                refused.len = id.len;
                return error.CaseInputOutsideSuite;
            }
            input_source = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(source) orelse ".", file });
            const file_bytes = try readFile(a, io, input_source, 1048576);
            if (file_bytes.len > max_suite_bytes - captured_bytes) return error.CasesLimit;
            captured_bytes += file_bytes.len;
            input = code.parse(a, file_bytes, 1048576) catch return error.InvalidCases;
        } else {
            input = get(item, "input") orelse return error.InvalidCases;
            input_source = try std.fmt.allocPrint(a, "{s}#{s}", .{ source, id });
        }
        const encoded = try std.json.Stringify.valueAlloc(a, input, .{});
        if (encoded.len > 1048576) return error.CasesLimit;
        a.free(encoded);
        case.* = .{ .id = id, .input = input, .source = input_source };
        if (get(item, "expect")) |expect| {
            try fields(expect, &.{ "pointer", "value" });
            case.pointer = text(expect, "pointer") orelse return error.InvalidCases;
            try validatePointer(case.pointer.?);
            case.expected = get(expect, "value") orelse return error.InvalidCases;
            try validateExpected(case.expected);
        } else if (evaluate) return error.InvalidCases;
    }
    return .{ .arena = arena, .cases = cases, .source = try a.dupe(u8, source) };
}
/// The case a suite was refused for, when the refusal is about one case.
pub const Refused = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,
    pub fn id(self: *const Refused) []const u8 {
        return self.buffer[0..self.len];
    }
};
pub fn load(owner: A, io: std.Io, path: []const u8, evaluate: bool) !Suite {
    var unused: Refused = .{};
    return loadReporting(owner, io, path, evaluate, &unused);
}
pub fn loadReporting(owner: A, io: std.Io, path: []const u8, evaluate: bool, refused: *Refused) !Suite {
    var scratch = std.heap.ArenaAllocator.init(owner);
    defer scratch.deinit();
    return fromBytesReporting(owner, io, try readFile(scratch.allocator(), io, path, max_suite_bytes), path, evaluate, refused);
}
fn clone(a: A, v: V) !V {
    const bytes = try std.json.Stringify.valueAlloc(a, v, .{});
    defer a.free(bytes);
    return code.parse(a, bytes, max_report_bytes);
}
fn integerFloat(integer: i64, number: f64) bool {
    if (number < -9223372036854775808.0 or number >= 9223372036854775808.0 or @trunc(number) != number) return false;
    return integer == @as(i64, @intFromFloat(number));
}
fn jsonEqual(left: V, right: V) bool {
    if (left == .integer and right == .float) return integerFloat(left.integer, right.float);
    if (left == .float and right == .integer) return integerFloat(right.integer, left.float);
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => left.bool == right.bool,
        .integer => left.integer == right.integer,
        .float => left.float == right.float,
        .number_string => std.mem.eql(u8, left.number_string, right.number_string),
        .string => std.mem.eql(u8, left.string, right.string),
        .array => blk: {
            if (left.array.items.len != right.array.items.len) break :blk false;
            for (left.array.items, right.array.items) |l, r| if (!jsonEqual(l, r)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (left.object.count() != right.object.count()) break :blk false;
            for (left.object.keys(), left.object.values()) |key, item| if (!jsonEqual(item, right.object.get(key) orelse break :blk false)) break :blk false;
            break :blk true;
        },
    };
}
pub fn isCancelled(value: V) bool {
    if (text(value, "code")) |name| if (std.mem.eql(u8, name, "cancelled")) return true;
    if (get(value, "stop")) |stop| {
        if (text(stop, "reason")) |reason| if (std.mem.eql(u8, reason, "cancelled")) return true;
        if (text(stop, "cause")) |cause| if (std.mem.eql(u8, cause, "Cancelled") or std.mem.eql(u8, cause, "cancelled")) return true;
    }
    return false;
}
fn unsafeToContinue(reply: Reply) bool {
    if (isCancelled(reply.value)) return true;
    if (get(reply.value, "recovery_required")) |flag| if (flag == .bool and flag.bool) return true;
    if (text(reply.value, "run_id") != null) {
        const count = get(reply.value, "model_request_dispatches") orelse return true;
        const complete = get(reply.value, "model_request_dispatches_complete") orelse return true;
        if (count != .integer or count.integer < 0 or complete != .bool or !complete.bool) return true;
    }
    if (get(reply.value, "uncertain_effects")) |flag| if (flag == .bool and flag.bool) return true;
    if (get(reply.value, "usage_unknown")) |flag| if (flag == .bool and flag.bool) return true;
    if (text(reply.value, "code")) |name| {
        for ([_][]const u8{ "cancelled", "recovery_required", "worker_disconnected", "owner_busy", "package_changed" }) |code_name| if (std.mem.eql(u8, name, code_name)) return true;
    }
    if (get(reply.value, "stop")) |stop| if (text(stop, "reason")) |reason| if (std.mem.eql(u8, reason, "recovery_required") or std.mem.eql(u8, reason, "uncertain_effect") or std.mem.eql(u8, reason, "usage_unavailable")) return true;
    return false;
}
pub fn execute(a: A, suite: Suite, package_path: []const u8, binding_id: []const u8, evaluate: bool, streaming: bool, ports: Ports) !Reply {
    var reserve_arena = std.heap.ArenaAllocator.init(a);
    defer reserve_arena.deinit();
    const reserve_a = reserve_arena.allocator();
    const reserves = try reserve_a.alloc(usize, suite.cases.len);
    var remaining_reserved: usize = 0;
    for (suite.cases, reserves) |case, *reserved| {
        var worst = object();
        try put(reserve_a, &worst, "id", str(case.id));
        try put(reserve_a, &worst, "input_source", str(case.source));
        if (case.pointer) |pointer| try put(reserve_a, &worst, "pointer", str(pointer));
        const encoded = try std.json.Stringify.valueAlloc(reserve_a, worst, .{});
        reserved.* = encoded.len + 512;
        if (reserved.* > max_report_bytes - 4096 - remaining_reserved) return error.ReportLimit;
        remaining_reserved += reserved.*;
    }
    var check = object();
    try put(a, &check, "packagePath", str(package_path));
    try put(a, &check, "bindingsId", str(binding_id));
    const checked = try ports.callFn(ports.context, a, "check", check);
    if (checked.is_error or get(checked.value, "ok") == null or get(checked.value, "ok").? != .bool or !get(checked.value, "ok").?.bool) return .{ .value = checked.value, .is_error = true };
    const digest = text(checked.value, "package_digest") orelse return error.InvalidResult;
    var result = object();
    var rows: V = .{ .array = std.array_list.Managed(V).init(a) };
    var passed: u64 = 0;
    var mismatched: u64 = 0;
    var failed: u64 = 0;
    var skipped: u64 = 0;
    var stopped = false;
    var stop_reason: []const u8 = "";
    var stop_cause: ?[]const u8 = null;
    // The bindings the first run was admitted under. Every later case must run under the same.
    var binding_digest: ?[]const u8 = null;
    var retained: usize = 4096;
    for (suite.cases, 0..) |case, index| {
        remaining_reserved -= reserves[index];
        var case_arena = std.heap.ArenaAllocator.init(a);
        defer case_arena.deinit();
        const temp = case_arena.allocator();
        var row = object();
        try put(temp, &row, "id", str(case.id));
        try put(temp, &row, "input_source", str(case.source));
        if (ports.cancelledFn(ports.context)) {
            stopped = true;
            stop_reason = "cancelled";
        }
        if (stopped) {
            skipped += 1;
            try put(temp, &row, "verdict", str("skipped"));
            try put(temp, &row, "reason", str(stop_reason));
        } else {
            var params = object();
            try put(temp, &params, "packagePath", str(package_path));
            try put(temp, &params, "bindingsId", str(binding_id));
            try put(temp, &params, "expectedPackageDigest", str(digest));
            try put(temp, &params, "input", case.input);
            try put(temp, &params, "inputSource", str(case.source));
            try put(temp, &params, "caseId", str(case.id));
            if (binding_digest) |pinned| try put(temp, &params, "expectedBindingDigest", str(pinned));
            if (ports.callFn(ports.context, temp, "run", params)) |reply| {
                if (binding_digest == null) if (text(reply.value, "binding_digest")) |seen| {
                    binding_digest = try a.dupe(u8, seen);
                };
                if (text(reply.value, "run_id")) |id| try put(temp, &row, "run_id", str(id));
                try put(temp, &row, "result", reply.value);
                const status = text(reply.value, "status") orelse "rejected";
                try put(temp, &row, "status", str(status));
                if (reply.is_error or !std.mem.eql(u8, status, "completed")) {
                    failed += 1;
                    try put(temp, &row, "verdict", str("run_failed"));
                } else if (evaluate) {
                    var binding = object();
                    try put(temp, &binding, "from", str(case.pointer.?));
                    const actual: ?V = runner.resolve(temp, binding, get(reply.value, "output") orelse .null) catch |err| blk: {
                        if (err != error.MissingBinding) return err;
                        break :blk null;
                    };
                    const matched = if (actual) |v| jsonEqual(v, case.expected) else false;
                    try put(temp, &row, "expected", case.expected);
                    try put(temp, &row, "pointer", str(case.pointer.?));
                    try put(temp, &row, "actual_present", .{ .bool = actual != null });
                    if (actual) |value| try put(temp, &row, "actual", value);
                    if (matched) passed += 1 else mismatched += 1;
                    try put(temp, &row, "verdict", str(if (matched) "matched" else "mismatch"));
                } else {
                    passed += 1;
                    try put(temp, &row, "verdict", str("completed"));
                }
                if (isCancelled(reply.value) or ports.cancelledFn(ports.context)) {
                    stopped = true;
                    stop_reason = "cancelled";
                } else if (std.mem.eql(u8, text(reply.value, "code") orelse "", "binding_changed")) {
                    stopped = true;
                    stop_reason = "binding_changed";
                } else if (unsafeToContinue(reply)) {
                    stopped = true;
                    stop_reason = "reconciliation_required";
                }
            } else |err| {
                // The worker failed under this case. The cases that already ran keep their
                // results: the suite stops here and reports what it has.
                if (err == error.OutOfMemory) return err;
                failed += 1;
                if (ports.acceptedFn) |accepted| if (accepted(ports.context)) |id| try put(temp, &row, "run_id", str(id));
                try put(temp, &row, "status", str("unknown"));
                try put(temp, &row, "verdict", str("run_failed"));
                try put(temp, &row, "cause", str(@errorName(err)));
                stopped = true;
                stop_reason = "worker_error";
                stop_cause = @errorName(err);
            }
        }
        if (ports.eventFn) |event| {
            var envelope = object();
            try put(temp, &envelope, "event", str("case_result"));
            try put(temp, &envelope, "index", .{ .integer = @intCast(index) });
            try put(temp, &envelope, "case", row);
            try event(ports.context, envelope);
        }
        if (streaming) _ = row.object.swapRemove("result");
        var encoded = try std.json.Stringify.valueAlloc(temp, row, .{});
        if (encoded.len + 1 + remaining_reserved > max_report_bytes - retained) {
            _ = row.object.swapRemove("result");
            _ = row.object.swapRemove("actual");
            _ = row.object.swapRemove("expected");
            try put(temp, &row, "details_omitted", .{ .bool = true });
            stopped = true;
            if (!std.mem.eql(u8, stop_reason, "cancelled")) stop_reason = "report_limit";
            encoded = try std.json.Stringify.valueAlloc(temp, row, .{});
            if (encoded.len + 1 > reserves[index]) return error.ReportLimit;
        }
        retained += encoded.len + 1;
        try rows.array.append(try clone(a, row));
    }
    try put(a, &result, "format", str("fh.cases/0.1"));
    try put(a, &result, "mode", str(if (evaluate) "eval" else "batch"));
    try put(a, &result, "source", str(suite.source));
    try put(a, &result, "package_digest", str(digest));
    try put(a, &result, "status", str(if (stopped) "stopped" else "completed"));
    if (stopped) try put(a, &result, "stop_reason", str(stop_reason));
    if (stop_cause) |cause| try put(a, &result, "stop_cause", str(cause));
    if (binding_digest) |pinned| try put(a, &result, "binding_digest", str(pinned));
    try put(a, &result, "ok", .{ .bool = !stopped and failed == 0 and mismatched == 0 });
    try put(a, &result, "total", .{ .integer = @intCast(suite.cases.len) });
    try put(a, &result, "passed", .{ .integer = @intCast(passed) });
    try put(a, &result, "mismatched", .{ .integer = @intCast(mismatched) });
    try put(a, &result, "failed", .{ .integer = @intCast(failed) });
    try put(a, &result, "skipped", .{ .integer = @intCast(skipped) });
    try put(a, &result, "cases", rows);
    return .{ .value = result };
}

test "native bulk validates entire case declaration before execution" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.DuplicateCase, fromBytes(a, std.testing.io, "{\"cases\":[{\"id\":\"same\",\"input\":{}},{\"id\":\"same\",\"input\":{}}]}", "/tmp/cases.json", false));
    try std.testing.expectError(error.InvalidCases, fromBytes(a, std.testing.io, "{\"cases\":[{\"id\":\"label\",\"input\":{},\"expect\":{\"pointer\":\"/bad~x\",\"value\":null}}]}", "/tmp/cases.json", true));
    try std.testing.expectError(error.InvalidCases, fromBytes(a, std.testing.io, "{\"cases\":[{\"id\":\"label\",\"input\":{}}]}", "/tmp/cases.json", true));
}
test "native evaluation preserves large integer labels and numeric equivalence" {
    try std.testing.expect(jsonEqual(.{ .integer = 1 }, .{ .float = 1.0 }));
    try std.testing.expect(!jsonEqual(.{ .integer = 9007199254740993 }, .{ .integer = 9007199254740992 }));
    try std.testing.expect(!jsonEqual(.{ .integer = 9007199254740993 }, .{ .float = 9007199254740992.0 }));
}

const TestWorker = struct {
    replies: []const []const u8,
    checks: usize = 0,
    runs: usize = 0,
    cancelled: bool = false,
    cancel_after_run: bool = false,
    output_bytes: ?[]const u8 = null,
    expected_input: ?V = null,
    fail_run: ?usize = null,
    pinned: usize = 0,
    unpinned: usize = 0,
    fn cast(raw: *anyopaque) *TestWorker {
        return @ptrCast(@alignCast(raw));
    }
    fn call(raw: *anyopaque, a: A, method: []const u8, params: V) !Reply {
        const self = cast(raw);
        if (std.mem.eql(u8, method, "check")) {
            self.checks += 1;
            return .{ .value = try code.parse(a, "{\"ok\":true,\"package_digest\":\"fixed-digest\"}", 1024) };
        }
        try std.testing.expectEqualStrings("run", method);
        try std.testing.expectEqualStrings("fixed-digest", text(params, "expectedPackageDigest").?);
        if (self.expected_input) |input| try std.testing.expect(jsonEqual(input, get(params, "input").?));
        const index = self.runs;
        self.runs += 1;
        if (self.fail_run) |failing| if (failing == index) return error.WorkerDisconnected;
        if (text(params, "expectedBindingDigest")) |expected| {
            try std.testing.expectEqualStrings("binding-one", expected);
            self.pinned += 1;
        } else self.unpinned += 1;
        if (self.cancel_after_run) self.cancelled = true;
        var value = try code.parse(a, self.replies[@min(index, self.replies.len - 1)], 4096);
        if (self.output_bytes) |bytes| try put(a, &value, "output", str(bytes));
        return .{ .value = value, .is_error = get(value, "code") != null };
    }
    fn isCancelled(raw: *anyopaque) bool {
        return cast(raw).cancelled;
    }
    fn ports(self: *TestWorker) Ports {
        return .{ .context = self, .callFn = call, .cancelledFn = TestWorker.isCancelled };
    }
};
const three_cases = "{\"cases\":[{\"id\":\"first\",\"input\":{}},{\"id\":\"second\",\"input\":{}},{\"id\":\"third\",\"input\":{}}]}";
const completed_reply = "{\"run_id\":\"run_first\",\"status\":\"completed\",\"model_request_dispatches\":0,\"model_request_dispatches_complete\":true,\"output\":null}";

fn expectStoppedOnce(reply_bytes: []const u8, reason: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var suite = try fromBytes(std.testing.allocator, std.testing.io, three_cases, "/tmp/cases.json", false);
    defer suite.deinit();
    var worker: TestWorker = .{ .replies = &.{reply_bytes} };
    const result = try execute(arena.allocator(), suite, "package", "local", false, false, worker.ports());
    try std.testing.expectEqual(@as(usize, 1), worker.checks);
    try std.testing.expectEqual(@as(usize, 1), worker.runs);
    try std.testing.expectEqualStrings(reason, text(result.value, "stop_reason").?);
    try std.testing.expectEqual(@as(i64, 2), get(result.value, "skipped").?.integer);
    const rows = get(result.value, "cases").?.array.items;
    for (rows, suite.cases, 0..) |row, case, i| {
        try std.testing.expectEqualStrings(case.id, text(row, "id").?);
        try std.testing.expectEqualStrings(case.source, text(row, "input_source").?);
        if (i == 0) {
            try std.testing.expectEqualStrings("run_first", text(row, "run_id").?);
            try std.testing.expect(jsonEqual(get(row, "result").?, try code.parse(arena.allocator(), reply_bytes, 4096)));
        } else try std.testing.expectEqualStrings("skipped", text(row, "verdict").?);
    }
}

test "native bulk recovered orphan stops after one dispatch retaining all case identities" {
    try expectStoppedOnce("{\"run_id\":\"run_first\",\"status\":\"stopped\",\"recovery_required\":true,\"stop\":{\"reason\":\"recovery_required\"},\"model_request_dispatches\":0,\"model_request_dispatches_complete\":false}", "reconciliation_required");
    try expectStoppedOnce("{\"run_id\":\"run_first\",\"status\":\"stopped\",\"recovery_required\":true,\"model_request_dispatches\":0,\"model_request_dispatches_complete\":true}", "reconciliation_required");
    try expectStoppedOnce("{\"run_id\":\"run_first\",\"status\":\"stopped\",\"stop\":{\"reason\":\"recovery_required\"},\"model_request_dispatches\":0,\"model_request_dispatches_complete\":true}", "reconciliation_required");
}

test "native bulk accepted results require complete dispatch accounting" {
    for ([_][]const u8{
        "{\"run_id\":\"run_first\",\"status\":\"failed\",\"model_request_dispatches\":0,\"model_request_dispatches_complete\":false}",
        "{\"run_id\":\"run_first\",\"status\":\"failed\",\"model_request_dispatches\":0}",
        "{\"run_id\":\"run_first\",\"status\":\"failed\",\"model_request_dispatches_complete\":true}",
        "{\"run_id\":\"run_first\",\"status\":\"failed\",\"model_request_dispatches\":-1,\"model_request_dispatches_complete\":true}",
        "{\"run_id\":\"run_first\",\"status\":\"failed\",\"model_request_dispatches\":0,\"model_request_dispatches_complete\":\"true\"}",
    }) |reply| try expectStoppedOnce(reply, "reconciliation_required");
}

test "native bulk settled failures and preaccept rejection continue ordinary cases" {
    for ([_][]const u8{
        "{\"run_id\":\"run_first\",\"status\":\"failed\",\"model_request_dispatches\":0,\"model_request_dispatches_complete\":true}",
        "{\"code\":\"invalid_input\"}",
    }) |reply_bytes| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var suite = try fromBytes(std.testing.allocator, std.testing.io, three_cases, "/tmp/cases.json", false);
        defer suite.deinit();
        var worker: TestWorker = .{ .replies = &.{ reply_bytes, completed_reply, completed_reply } };
        const result = try execute(arena.allocator(), suite, "package", "local", false, false, worker.ports());
        try std.testing.expectEqual(@as(usize, 3), worker.runs);
        try std.testing.expectEqualStrings("completed", text(result.value, "status").?);
        try std.testing.expectEqual(@as(i64, 1), get(result.value, "failed").?.integer);
        try std.testing.expectEqual(@as(i64, 2), get(result.value, "passed").?.integer);
    }
}

test "native bulk external cancellation preserves cancellation and skips later cases" {
    try expectStoppedOnce("{\"run_id\":\"run_first\",\"status\":\"stopped\",\"stop\":{\"reason\":\"cancelled\"},\"model_request_dispatches\":0,\"model_request_dispatches_complete\":true}", "cancelled");
    try expectStoppedOnce("{\"run_id\":\"run_first\",\"status\":\"stopped\",\"stop\":{\"reason\":\"usage_unavailable\",\"cause\":\"Cancelled\"},\"model_request_dispatches\":0,\"model_request_dispatches_complete\":true}", "cancelled");
}

test "native bulk final case cancellation is preserved from reply or post-call flag" {
    for ([_][]const u8{
        "{\"run_id\":\"run_first\",\"status\":\"stopped\",\"stop\":{\"reason\":\"cancelled\"},\"model_request_dispatches\":0,\"model_request_dispatches_complete\":true}",
        "{\"code\":\"cancelled\"}",
        completed_reply,
    }, 0..) |reply_bytes, i| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var suite = try fromBytes(std.testing.allocator, std.testing.io, "{\"cases\":[{\"id\":\"only\",\"input\":{}}]}", "/tmp/cases.json", false);
        defer suite.deinit();
        var worker: TestWorker = .{ .replies = &.{reply_bytes}, .cancel_after_run = i == 2 };
        const result = try execute(arena.allocator(), suite, "package", "local", false, false, worker.ports());
        try std.testing.expectEqual(@as(usize, 1), worker.runs);
        try std.testing.expectEqualStrings("cancelled", text(result.value, "stop_reason") orelse "");
        try std.testing.expectEqualStrings("only", text(get(result.value, "cases").?.array.items[0], "id").?);
    }
}

test "native evaluation rejects unsupported expected numbers recursively before worker dispatch" {
    var worker: TestWorker = .{ .replies = &.{completed_reply} };
    for ([_][]const u8{ "9223372036854775808", "-9223372036854775809", "{\"nested\":[9223372036854775808]}" }) |label| {
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"cases\":[{{\"id\":\"only\",\"input\":{{}},\"expect\":{{\"pointer\":\"\",\"value\":{s}}}}}]}}", .{label});
        defer std.testing.allocator.free(bytes);
        try std.testing.expectError(error.InvalidCases, executeDeclaration(bytes, "/tmp/cases.json", true, &worker));
    }
    try std.testing.expectEqual(@as(usize, 0), worker.checks);
    try std.testing.expectEqual(@as(usize, 0), worker.runs);
}

fn executeDeclaration(bytes: []const u8, source: []const u8, evaluate: bool, worker: *TestWorker) !void {
    var suite = try fromBytes(std.testing.allocator, std.testing.io, bytes, source, evaluate);
    defer suite.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try execute(arena.allocator(), suite, "package", "local", evaluate, false, worker.ports());
}

test "native bulk rejects oversized declarations and too many cases before any worker call" {
    const a = std.testing.allocator;
    var worker: TestWorker = .{ .replies = &.{completed_reply} };
    const oversized = try a.alloc(u8, max_suite_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.CasesLimit, executeDeclaration(oversized, "/tmp/cases.json", false, &worker));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    var declaration = object();
    var cases: V = .{ .array = std.array_list.Managed(V).init(temp) };
    for (0..max_cases + 1) |i| {
        var case = object();
        try put(temp, &case, "id", str(try std.fmt.allocPrint(temp, "case-{d}", .{i})));
        try put(temp, &case, "input", .null);
        try cases.array.append(case);
    }
    try put(temp, &declaration, "cases", cases);
    try std.testing.expectError(error.CasesLimit, executeDeclaration(try std.json.Stringify.valueAlloc(temp, declaration, .{}), "/tmp/cases.json", false, &worker));
    try std.testing.expectEqual(@as(usize, 0), worker.checks);
    try std.testing.expectEqual(@as(usize, 0), worker.runs);
}

test "native bulk reserves every identity before any worker call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = try a.alloc(Case, max_cases);
    const source = try a.alloc(u8, 17000);
    @memset(source, 's');
    for (cases, 0..) |*case, i| case.* = .{ .id = try std.fmt.allocPrint(a, "case-{d}", .{i}), .input = .null, .source = source };
    var worker: TestWorker = .{ .replies = &.{completed_reply} };
    try std.testing.expectError(error.ReportLimit, execute(a, .{ .arena = arena, .cases = cases, .source = "suite" }, "package", "local", false, false, worker.ports()));
    try std.testing.expectEqual(@as(usize, 0), worker.checks);
    try std.testing.expectEqual(@as(usize, 0), worker.runs);
}

test "native bulk omits oversized details preserves every identity and stops dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var suite = try fromBytes(std.testing.allocator, std.testing.io, three_cases, "/tmp/cases.json", false);
    defer suite.deinit();
    const output = try a.alloc(u8, max_report_bytes);
    @memset(output, 'x');
    var worker: TestWorker = .{ .replies = &.{completed_reply}, .output_bytes = output };
    const result = try execute(a, suite, "package", "local", false, false, worker.ports());
    try std.testing.expectEqual(@as(usize, 1), worker.runs);
    try std.testing.expectEqualStrings("report_limit", text(result.value, "stop_reason").?);
    const rows = get(result.value, "cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("run_first", text(rows[0], "run_id").?);
    try std.testing.expect(get(rows[0], "details_omitted").?.bool);
    try std.testing.expect(get(rows[0], "result") == null);
    for (rows, suite.cases, 0..) |row, case, i| {
        try std.testing.expectEqualStrings(case.id, text(row, "id").?);
        try std.testing.expectEqualStrings(case.source, text(row, "input_source").?);
        if (i > 0) try std.testing.expectEqualStrings("skipped", text(row, "verdict").?);
    }
}

test "native bulk file inputs retain captured values after source mutation" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "input.json", .data = "{\"captured\":1}" });
    const path = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/cases.json", .{path});
    defer std.testing.allocator.free(source);
    var suite = try fromBytes(std.testing.allocator, io, "{\"cases\":[{\"id\":\"first\",\"input_file\":\"input.json\"},{\"id\":\"second\",\"input_file\":\"input.json\"}]}", source, false);
    defer suite.deinit();
    try temporary.dir.writeFile(io, .{ .sub_path = "input.json", .data = "{\"captured\":2}" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var worker: TestWorker = .{ .replies = &.{completed_reply}, .expected_input = try code.parse(arena.allocator(), "{\"captured\":1}", 128) };
    const result = try execute(arena.allocator(), suite, "package", "local", false, false, worker.ports());
    try std.testing.expectEqual(@as(usize, 2), worker.runs);
    try std.testing.expect(get(result.value, "ok").?.bool);
}

test "native bulk individual input and aggregate source snapshot budgets reject before worker calls" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/cases.json", .{path});
    defer std.testing.allocator.free(source);
    var file = try temporary.dir.createFile(io, "input.json", .{});
    defer file.close(io);
    try file.setLength(io, 1048577);
    var worker: TestWorker = .{ .replies = &.{completed_reply} };
    try std.testing.expectError(error.CasesLimit, executeDeclaration("{\"cases\":[{\"id\":\"only\",\"input_file\":\"input.json\"}]}", source, false, &worker));
    const input = try std.testing.allocator.alloc(u8, 1048576);
    defer std.testing.allocator.free(input);
    @memset(input, 'x');
    input[0] = '"';
    input[input.len - 1] = '"';
    try temporary.dir.writeFile(io, .{ .sub_path = "input.json", .data = input });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var declaration = object();
    var cases: V = .{ .array = std.array_list.Managed(V).init(a) };
    for (0..16) |i| {
        var case = object();
        try put(a, &case, "id", str(try std.fmt.allocPrint(a, "case-{d}", .{i})));
        try put(a, &case, "input_file", str("input.json"));
        try cases.array.append(case);
    }
    try put(a, &declaration, "cases", cases);
    try std.testing.expectError(error.CasesLimit, executeDeclaration(try std.json.Stringify.valueAlloc(a, declaration, .{}), source, false, &worker));
    try std.testing.expectEqual(@as(usize, 0), worker.checks);
    try std.testing.expectEqual(@as(usize, 0), worker.runs);
}

test "native evaluation parsed signed64 labels match finite64 equivalent numbers without integer collapse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = @import("loops/schema.zig");
    try std.testing.expect(jsonEqual(try code.parse(a, "1", 128), try schema.parse(a, "1.0")));
    try std.testing.expect(jsonEqual(try code.parse(a, "1.25", 128), try schema.parse(a, "1.25e0")));
    try std.testing.expect(jsonEqual(try code.parse(a, "9223372036854775807", 128), try schema.parse(a, "9223372036854775807")));
    try std.testing.expect(!jsonEqual(try code.parse(a, "9007199254740993", 128), try schema.parse(a, "9007199254740992.0")));
}

const bound_reply = "{\"run_id\":\"run_first\",\"status\":\"completed\",\"binding_digest\":\"binding-one\",\"model_request_dispatches\":0,\"model_request_dispatches_complete\":true,\"output\":null}";

test "native bulk pins the binding digest from the first run and stops when it changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var suite = try fromBytes(std.testing.allocator, std.testing.io, three_cases, "/tmp/cases.json", false);
    defer suite.deinit();
    var steady: TestWorker = .{ .replies = &.{bound_reply} };
    const completed = try execute(arena.allocator(), suite, "package", "local", false, false, steady.ports());
    try std.testing.expectEqualStrings("completed", text(completed.value, "status").?);
    try std.testing.expectEqual(@as(usize, 1), steady.unpinned);
    try std.testing.expectEqual(@as(usize, 2), steady.pinned);
    try std.testing.expectEqualStrings("binding-one", text(completed.value, "binding_digest").?);
    // The installation changed under the suite: the next case is refused and nothing more runs.
    var moved: TestWorker = .{ .replies = &.{ bound_reply, "{\"code\":\"binding_changed\"}", bound_reply } };
    const stopped = try execute(arena.allocator(), suite, "package", "local", false, false, moved.ports());
    try std.testing.expectEqual(@as(usize, 2), moved.runs);
    try std.testing.expectEqualStrings("stopped", text(stopped.value, "status").?);
    try std.testing.expectEqualStrings("binding_changed", text(stopped.value, "stop_reason").?);
    try std.testing.expectEqual(@as(i64, 1), get(stopped.value, "skipped").?.integer);
}

test "native bulk worker error keeps the report for cases that already ran" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var suite = try fromBytes(std.testing.allocator, std.testing.io, three_cases, "/tmp/cases.json", false);
    defer suite.deinit();
    var worker: TestWorker = .{ .replies = &.{completed_reply}, .fail_run = 1 };
    const result = try execute(arena.allocator(), suite, "package", "local", false, false, worker.ports());
    try std.testing.expectEqual(@as(usize, 2), worker.runs);
    try std.testing.expectEqualStrings("stopped", text(result.value, "status").?);
    try std.testing.expectEqualStrings("worker_error", text(result.value, "stop_reason").?);
    try std.testing.expectEqualStrings("WorkerDisconnected", text(result.value, "stop_cause").?);
    try std.testing.expect(!get(result.value, "ok").?.bool);
    const rows = get(result.value, "cases").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("run_first", text(rows[0], "run_id").?);
    try std.testing.expectEqualStrings("completed", text(rows[0], "verdict").?);
    try std.testing.expectEqualStrings("run_failed", text(rows[1], "verdict").?);
    try std.testing.expectEqualStrings("unknown", text(rows[1], "status").?);
    try std.testing.expectEqualStrings("WorkerDisconnected", text(rows[1], "cause").?);
    try std.testing.expectEqualStrings("skipped", text(rows[2], "verdict").?);
    try std.testing.expectEqual(@as(i64, 1), get(result.value, "passed").?.integer);
    try std.testing.expectEqual(@as(i64, 1), get(result.value, "failed").?.integer);
    try std.testing.expectEqual(@as(i64, 1), get(result.value, "skipped").?.integer);
}

test "native bulk refuses an input_file outside the suite directory and names the case" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "suite", .fromMode(0o755));
    try temporary.dir.writeFile(io, .{ .sub_path = "outside.json", .data = "{\"secret\":1}" });
    try temporary.dir.writeFile(io, .{ .sub_path = "suite/inside.json", .data = "{\"ok\":1}" });
    const path = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/suite/cases.json", .{path});
    defer std.testing.allocator.free(source);
    const absolute = try std.fmt.allocPrint(std.testing.allocator, "{{\"cases\":[{{\"id\":\"inside\",\"input_file\":\"inside.json\"}},{{\"id\":\"rooted\",\"input_file\":\"{s}/outside.json\"}}]}}", .{path});
    defer std.testing.allocator.free(absolute);
    for ([_][]const u8{
        "{\"cases\":[{\"id\":\"inside\",\"input_file\":\"inside.json\"},{\"id\":\"climbs\",\"input_file\":\"../outside.json\"}]}",
        "{\"cases\":[{\"id\":\"inside\",\"input_file\":\"./inside.json\"},{\"id\":\"climbs\",\"input_file\":\"nested/../../outside.json\"}]}",
        absolute,
    }, [_][]const u8{ "climbs", "climbs", "rooted" }) |declaration, case| {
        var refused: Refused = .{};
        try std.testing.expectError(error.CaseInputOutsideSuite, fromBytesReporting(std.testing.allocator, io, declaration, source, false, &refused));
        try std.testing.expectEqualStrings(case, refused.id());
    }
    var refused: Refused = .{};
    var suite = try fromBytesReporting(std.testing.allocator, io, "{\"cases\":[{\"id\":\"inside\",\"input_file\":\"inside.json\"}]}", source, false, &refused);
    defer suite.deinit();
    try std.testing.expectEqual(@as(usize, 0), refused.len);
}
