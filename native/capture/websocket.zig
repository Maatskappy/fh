//! Bounded RFC6455 framing over std.http verified plain/TLS streams.
const std = @import("std");
pub const max_message = 16 * 1024 * 1024;
pub const Event = union(enum) { text: []const u8, ping: []const u8, pong: []const u8, close: []const u8 };
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    cap: usize,
    input: std.ArrayList(u8) = .empty,
    message: std.ArrayList(u8) = .empty,
    payload: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    fragmented: bool = false,
    pub fn init(a: std.mem.Allocator, cap: usize) Decoder {
        return .{ .allocator = a, .cap = cap };
    }
    pub fn deinit(d: *Decoder) void {
        d.input.deinit(d.allocator);
        d.message.deinit(d.allocator);
        d.payload.deinit(d.allocator);
    }
    pub fn feed(d: *Decoder, bytes: []const u8) !void {
        if (d.offset != 0) {
            const left = d.input.items.len - d.offset;
            std.mem.copyForwards(u8, d.input.items[0..left], d.input.items[d.offset..]);
            d.input.items.len = left;
            d.offset = 0;
        }
        if (bytes.len > d.cap + 8192 + 14 - d.input.items.len) return error.MessageLimit;
        try d.input.appendSlice(d.allocator, bytes);
    }
    pub fn next(d: *Decoder) !?Event {
        while (true) {
            const b = d.input.items[d.offset..];
            if (b.len < 2) return null;
            const fin = b[0] & 128 != 0;
            const op = b[0] & 15;
            if (b[0] & 112 != 0 or b[1] & 128 != 0 or (op != 0 and op != 1 and op != 8 and op != 9 and op != 10)) return error.WebSocketProtocol;
            if ((op >= 8 and (!fin or b[1] > 125)) or (op == 0 and !d.fragmented) or (op == 1 and d.fragmented)) return error.WebSocketProtocol;
            var n: u64 = b[1];
            var h: usize = 2;
            if (n == 126) {
                if (b.len < 4) return null;
                n = std.mem.readInt(u16, b[2..4], .big);
                h = 4;
                if (n < 126) return error.WebSocketProtocol;
            }
            if (n == 127) {
                if (b.len < 10) return null;
                n = std.mem.readInt(u64, b[2..10], .big);
                h = 10;
                if (n < 65536 or n >> 63 != 0) return error.WebSocketProtocol;
            }
            if (n > d.cap or (op < 8 and n > d.cap - d.message.items.len)) return error.MessageLimit;
            const len: usize = @intCast(n);
            if (b.len < h + len) return null;
            d.payload.clearRetainingCapacity();
            try d.payload.appendSlice(d.allocator, b[h..][0..len]);
            d.offset += h + len;
            const p = d.payload.items;
            switch (op) {
                8 => {
                    if (p.len == 1) return error.WebSocketProtocol;
                    if (p.len >= 2) {
                        const code = std.mem.readInt(u16, p[0..2], .big);
                        if (code < 1000 or code >= 5000 or code == 1004 or code == 1005 or code == 1006 or code == 1015 or (code >= 1016 and code < 3000) or !std.unicode.utf8ValidateSlice(p[2..])) return error.WebSocketProtocol;
                    }
                    return .{ .close = p };
                },
                9 => return .{ .ping = p },
                10 => return .{ .pong = p },
                else => {
                    if (op == 1) d.message.clearRetainingCapacity();
                    try d.message.appendSlice(d.allocator, p);
                    d.fragmented = !fin;
                    if (fin) {
                        if (!std.unicode.utf8ValidateSlice(d.message.items)) return error.WebSocketProtocol;
                        const result = d.message.items;
                        d.message.items.len = 0;
                        return .{ .text = result };
                    }
                },
            }
        }
    }
};
pub fn validateEndpoint(bytes: []const u8) !std.Uri {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidEndpoint;
    for (bytes) |c| if (c <= 32 or c == 127) return error.InvalidEndpoint;
    const uri = std.Uri.parse(bytes) catch return error.InvalidEndpoint;
    if ((!std.mem.eql(u8, uri.scheme, "ws") and !std.mem.eql(u8, uri.scheme, "wss")) or uri.host == null or uri.user != null or uri.password != null or uri.fragment != null or uri.port == 0) return error.InvalidEndpoint;
    var host: [std.Io.net.HostName.max_len]u8 = undefined;
    _ = uri.getHost(&host) catch return error.InvalidEndpoint;
    return uri;
}
pub const Socket = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    connection: ?*std.http.Client.Connection = null,
    decoder: Decoder,
    pub fn init(a: std.mem.Allocator, io: std.Io) Socket {
        return .{ .allocator = a, .io = io, .client = .{ .allocator = a, .io = io, .read_buffer_size = 32768 }, .decoder = Decoder.init(a, max_message) };
    }
    pub fn deinit(s: *Socket) void {
        if (s.connection) |c| {
            c.closing = true;
            s.client.connection_pool.release(c, s.io);
            s.connection = null;
        }
        s.client.deinit();
        s.decoder.deinit();
    }
    pub fn connect(s: *Socket, endpoint: []const u8, token: ?[]const u8) !void {
        var uri = try validateEndpoint(endpoint);
        uri.scheme = if (std.mem.eql(u8, uri.scheme, "wss")) "https" else "http";
        var entropy: [16]u8 = undefined;
        s.io.random(&entropy);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &entropy);
        var headers: [4]std.http.Header = .{ .{ .name = "Upgrade", .value = "websocket" }, .{ .name = "Sec-WebSocket-Version", .value = "13" }, .{ .name = "Sec-WebSocket-Key", .value = &key }, .{ .name = "Authorization", .value = "" } };
        const auth = if (token) |t| try std.fmt.allocPrint(s.allocator, "Bearer {s}", .{t}) else null;
        defer if (auth) |a| s.allocator.free(a);
        if (auth) |a| headers[3].value = a;
        var request = try s.client.request(.GET, uri, .{ .redirect_behavior = .unhandled, .headers = .{ .connection = .{ .override = "Upgrade" }, .authorization = .omit }, .extra_headers = headers[0..if (auth != null) @as(usize, 4) else 3] });
        // Request owns failed upgrades. On success detach it before deinit, retaining
        // the connection reader's bytes beyond the HTTP head (including TLS buffers).
        defer {
            if (request.connection) |c| {
                c.closing = true;
                request.reader.state = .ready;
            }
            request.deinit();
        }
        try request.sendBodiless();
        const response = try request.receiveHead(&.{});
        if (response.head.status != .switching_protocols) return error.UpgradeRejected;
        var upgrade = false;
        var connection = false;
        var accept = false;
        var hash = std.crypto.hash.Sha1.init(.{});
        hash.update(&key);
        hash.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
        var digest: [20]u8 = undefined;
        hash.final(&digest);
        var expected: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&expected, &digest);
        var it = response.head.iterateHeaders();
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "Upgrade")) {
                if (upgrade) return error.WebSocketProtocol;
                upgrade = hasToken(header.value, "websocket");
            }
            if (std.ascii.eqlIgnoreCase(header.name, "Connection")) connection = connection or hasToken(header.value, "upgrade");
            if (std.ascii.eqlIgnoreCase(header.name, "Sec-WebSocket-Accept")) {
                if (accept or !std.mem.eql(u8, header.value, &expected)) return error.WebSocketProtocol;
                accept = true;
            }
        }
        if (!upgrade or !connection or !accept) return error.WebSocketProtocol;
        s.connection = request.connection;
        request.connection = null;
        s.connection.?.closing = true;
    }
    pub fn send(s: *Socket, op: u8, bytes: []const u8) !void {
        if (bytes.len > max_message or (op >= 8 and bytes.len > 125)) return error.MessageLimit;
        const c = s.connection orelse return error.Disconnected;
        var head: [14]u8 = undefined;
        head[0] = 128 | op;
        var h: usize = 2;
        if (bytes.len < 126) head[1] = 128 | @as(u8, @intCast(bytes.len)) else if (bytes.len <= 65535) {
            head[1] = 128 | 126;
            std.mem.writeInt(u16, head[2..4], @intCast(bytes.len), .big);
            h = 4;
        } else {
            head[1] = 128 | 127;
            std.mem.writeInt(u64, head[2..10], @intCast(bytes.len), .big);
            h = 10;
        }
        var mask: [4]u8 = undefined;
        s.io.random(&mask);
        @memcpy(head[h..][0..4], &mask);
        h += 4;
        try c.writer().writeAll(head[0..h]);
        var buf: [8192]u8 = undefined;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = @min(buf.len, bytes.len - offset);
            for (buf[0..n], 0..) |*b, i| b.* = bytes[offset + i] ^ mask[(offset + i) % 4];
            try c.writer().writeAll(buf[0..n]);
            offset += n;
        }
        try c.flush();
    }
    pub fn receive(s: *Socket) ![]const u8 {
        while (true) {
            if (try s.decoder.next()) |event| switch (event) {
                .text => |t| return t,
                .ping => |p| {
                    try s.send(10, p);
                    continue;
                },
                .pong => continue,
                .close => |p| {
                    s.send(8, p) catch {};
                    return error.Disconnected;
                },
            };
            const reader = (s.connection orelse return error.Disconnected).reader();
            // Wait for one byte, then consume only what is available. Filling an
            // 8 KiB slice deadlocks when a peer awaits the next small command.
            _ = reader.peek(1) catch |err| switch (err) {
                error.EndOfStream => return error.Disconnected,
                else => return err,
            };
            const available = @min(reader.bufferedLen(), 8192);
            try s.decoder.feed(try reader.take(available));
        }
    }
};
fn hasToken(value: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |t| if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, t, " \t"), want)) return true;
    return false;
}
test "native capture fragmented text survives partial/coalesced input and ping" {
    var d = Decoder.init(std.testing.allocator, 32);
    defer d.deinit();
    try d.feed(&.{ 0x01, 0x02, 'a' });
    try std.testing.expect((try d.next()) == null);
    try d.feed(&.{ 'b', 0x89, 1, 'x', 0x80, 2, 'c', 'd', 0x81, 1, 'z' });
    try std.testing.expectEqualStrings("x", (try d.next()).?.ping);
    try std.testing.expectEqualStrings("abcd", (try d.next()).?.text);
    try std.testing.expectEqualStrings("z", (try d.next()).?.text);
    try std.testing.expect((try d.next()) == null);
}
test "native capture rejects masked reserved oversized and malformed control frames" {
    const cases = [_][]const u8{ &.{ 0x81, 0x80 }, &.{ 0xc1, 0 }, &.{ 0x09, 0 }, &.{ 0x82, 0 }, &.{ 0x80, 0 }, &.{ 0x81, 126, 0, 1 } };
    for (cases) |bytes| {
        var d = Decoder.init(std.testing.allocator, 32);
        defer d.deinit();
        try d.feed(bytes);
        try std.testing.expectError(error.WebSocketProtocol, d.next());
    }
    var d = Decoder.init(std.testing.allocator, 8);
    defer d.deinit();
    try d.feed(&.{ 0x81, 127, 0, 0, 0, 0, 1, 0, 0, 0 });
    try std.testing.expectError(error.MessageLimit, d.next());
}
test "native capture close and invalid UTF8 cannot become text" {
    var d = Decoder.init(std.testing.allocator, 32);
    defer d.deinit();
    try d.feed(&.{ 0x88, 2, 3, 232 });
    try std.testing.expectEqual(@as(usize, 2), (try d.next()).?.close.len);
    try d.feed(&.{ 0x81, 1, 255 });
    try std.testing.expectError(error.WebSocketProtocol, d.next());
}
