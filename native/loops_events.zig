//! Bounded native Loop envelopes. Fields borrow parsed storage.
const std = @import("std");
pub const max_frame = 8 * 1024 * 1024;
pub const Kind = enum { run_started, step_started, step_completed, run_finished };
pub const Event = struct { kind: Kind, run_id: []const u8, sequence: u64, step_id: ?[]const u8 = null, iteration: ?u64 = null };
pub const Message = union(enum) { event: Event, response: struct { id: u64, value: std.json.Value, is_error: bool } };
pub const Decoded = struct {
    json: std.json.Parsed(std.json.Value),
    message: Message,
    pub fn deinit(self: *Decoded) void {
        self.json.deinit();
    }
};
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (bytes.len == 0 or bytes.len > max_frame or !std.unicode.utf8ValidateSlice(bytes)) return error.MalformedBridgeMessage;
    var depth: usize = 0;
    var nodes: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |c| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                quoted = false;
            }
            continue;
        }
        if (c == '"') {
            quoted = true;
            nodes += 1;
        }
        if (c == '{' or c == '[') {
            depth += 1;
            nodes += 1;
            if (depth > 160) return error.MalformedBridgeMessage;
        }
        if (c == '}' or c == ']') {
            if (depth == 0) return error.MalformedBridgeMessage;
            depth -= 1;
        }
        if (c == ',' or c == ':') nodes += 1;
        if (nodes > 600000) return error.MalformedBridgeMessage;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{ .duplicate_field_behavior = .@"error", .allocate = .alloc_always, .max_value_len = max_frame }) catch return error.MalformedBridgeMessage;
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.MalformedBridgeMessage;
    const root = parsed.value.object;
    if (root.get("event")) |name| {
        if (bytes.len > 4096 or name != .string) return error.MalformedBridgeMessage;
        try keys(root, &.{ "event", "run_id", "sequence", "step_id", "iteration" });
        const kind: Kind = if (std.mem.eql(u8, name.string, "run.started")) .run_started else if (std.mem.eql(u8, name.string, "step.started")) .step_started else if (std.mem.eql(u8, name.string, "step.completed")) .step_completed else if (std.mem.eql(u8, name.string, "run.finished")) .run_finished else return error.UnknownBridgeMessage;
        var event: Event = .{ .kind = kind, .run_id = try string(root, "run_id"), .sequence = try integer(root, "sequence", 1) };
        if (event.run_id.len > 128) return error.MalformedBridgeMessage;
        if (kind == .step_started or kind == .step_completed) {
            event.step_id = try string(root, "step_id");
            event.iteration = try integer(root, "iteration", 0);
        }
        return .{ .json = parsed, .message = .{ .event = event } };
    }
    try keys(root, &.{ "id", "result", "error" });
    const id = try integer(root, "id", 1);
    const err = root.get("error");
    const result = root.get("result");
    if ((err == null) == (result == null)) return error.MalformedBridgeMessage;
    if (err) |e| {
        if (e != .object) return error.MalformedBridgeMessage;
        _ = try string(e.object, "code");
        _ = try string(e.object, "message");
    }
    return .{ .json = parsed, .message = .{ .response = .{ .id = id, .value = err orelse result.?, .is_error = err != null } } };
}
fn keys(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    for (object.keys()) |key| {
        for (allowed) |valid| {
            if (std.mem.eql(u8, key, valid)) break;
        } else return error.UnknownBridgeMessage;
    }
}
fn string(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = object.get(key) orelse return error.MalformedBridgeMessage;
    if (v != .string or v.string.len == 0) return error.MalformedBridgeMessage;
    return v.string;
}
fn integer(object: std.json.ObjectMap, key: []const u8, min: i64) !u64 {
    const v = object.get(key) orelse return error.MalformedBridgeMessage;
    if (v != .integer or v.integer < min or v.integer > 9007199254740991) return error.MalformedBridgeMessage;
    return @intCast(v.integer);
}
pub fn display(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var view = (try std.unicode.Utf8View.init(text)).iterator();
    while (view.nextCodepointSlice()) |slice| {
        const cp = try std.unicode.utf8Decode(slice);
        if ((cp < 32 and cp != 10 and cp != 9) or (cp >= 127 and cp <= 159) or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) {
            try out.append(alloc, ' ');
        } else try out.appendSlice(alloc, slice);
    }
    return out.toOwnedSlice(alloc);
}
