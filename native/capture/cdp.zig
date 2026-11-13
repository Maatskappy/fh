//! Flattened CDP routing. Every await pumps unsolicited events.
const std = @import("std");
const ws = @import("websocket.zig");
pub const Value = std.json.Value;
pub const Client = struct {
    allocator: std.mem.Allocator,
    socket: *ws.Socket,
    next_id: i64 = 1,
    session: ?[]const u8 = null,
    event_context: ?*anyopaque = null,
    event_fn: ?*const fn (*anyopaque, Value) anyerror!void = null,
    pending: std.AutoHashMapUnmanaged(i64, std.json.Parsed(Value)) = .empty,
    last_error: ?[]const u8 = null,
    outstanding: std.AutoHashMapUnmanaged(i64, struct { session: bool, method: []const u8 }) = .empty,
    pub fn deinit(c: *Client) void {
        var it = c.pending.valueIterator();
        while (it.next()) |p| p.deinit();
        c.pending.deinit(c.allocator);
        c.outstanding.deinit(c.allocator);
        if (c.last_error) |s| c.allocator.free(s);
    }
    pub fn send(c: *Client, method: []const u8, params: Value, session: bool) !i64 {
        var value = Value{ .object = .{} };
        defer value.object.deinit(c.allocator);
        if (c.outstanding.count() >= 8) return error.CdpCommandLimit;
        const id = c.next_id;
        try c.outstanding.put(c.allocator, id, .{ .session = session, .method = method });
        errdefer _ = c.outstanding.remove(id);
        c.next_id += 1;
        try value.object.put(c.allocator, "id", .{ .integer = id });
        try value.object.put(c.allocator, "method", .{ .string = method });
        try value.object.put(c.allocator, "params", params);
        if (session) try value.object.put(c.allocator, "sessionId", .{ .string = c.session orelse return error.NoSession });
        const bytes = try std.json.Stringify.valueAlloc(c.allocator, value, .{});
        defer c.allocator.free(bytes);
        try c.socket.send(1, bytes);
        return id;
    }
    pub fn awaitReply(c: *Client, id: i64) !std.json.Parsed(Value) {
        while (true) {
            var reply: std.json.Parsed(Value) = if (c.pending.fetchRemove(id)) |p| p.value else blk: {
                const bytes = try c.socket.receive();
                var p = std.json.parseFromSlice(Value, c.allocator, bytes, .{ .allocate = .alloc_always, .max_value_len = ws.max_message }) catch return error.CdpProtocol;
                errdefer p.deinit();
                if (p.value != .object) return error.CdpProtocol;
                if (p.value.object.get("id")) |reply_id| {
                    if (reply_id != .integer or reply_id.integer <= 0 or reply_id.integer >= c.next_id) return error.CdpProtocol;
                    const expected = c.outstanding.get(reply_id.integer) orelse return error.CdpProtocol;
                    if (expected.session) {
                        const received_session = p.value.object.get("sessionId") orelse return error.CdpProtocol;
                        if (received_session != .string or !std.mem.eql(u8, received_session.string, c.session.?)) return error.CdpProtocol;
                    } else if (p.value.object.get("sessionId") != null) return error.CdpProtocol;
                    if (reply_id.integer == id) break :blk p;
                    if (c.pending.count() >= 8 or c.pending.contains(reply_id.integer)) return error.CdpProtocol;
                    try c.pending.put(c.allocator, reply_id.integer, p);
                    continue;
                }
                if (c.event_fn) |f| try f(c.event_context.?, p.value);
                p.deinit();
                continue;
            };
            const completed = c.outstanding.fetchRemove(id) orelse {
                reply.deinit();
                return error.CdpProtocol;
            };
            if (reply.value.object.get("error")) |e| {
                defer reply.deinit();
                if (c.last_error) |s| c.allocator.free(s);
                // Keep method error details, scrub optional authentication at final export.
                const detail = try std.json.Stringify.valueAlloc(c.allocator, e, .{});
                defer c.allocator.free(detail);
                c.last_error = try std.fmt.allocPrint(c.allocator, "{s}: {s}", .{ completed.value.method, detail });
                return error.CdpCommand;
            }
            if (reply.value.object.get("result") == null) {
                reply.deinit();
                return error.CdpProtocol;
            }
            return reply;
        }
    }
    pub fn command(c: *Client, method: []const u8, params: Value, session: bool) !std.json.Parsed(Value) {
        return c.awaitReply(try c.send(method, params, session));
    }
};
