//! Fixed Unix Docker HTTP transport. No process, environment, TCP or auth discovery.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
pub const Bound = struct {
    io: std.Io,
    deadline_ms: i64,
    cancel: ?*const std.atomic.Value(bool) = null,
    gate: ?*Gate = null,
    pub fn now(self: Bound) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }
    pub fn check(self: Bound) !void {
        if (self.cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        if (self.now() >= self.deadline_ms) return error.TimeLimit;
        if (self.gate) |gate| try gate.check(self.now());
    }
};
/// A shared bounded authority check across all control and attach connections.
pub const Gate = struct {
    context: *anyopaque,
    checkFn: *const fn (*anyopaque) anyerror!void,
    next_ms: i64 = 0,
    fn check(self: *Gate, now_ms: i64) !void {
        if (now_ms < self.next_ms) return;
        try self.checkFn(self.context);
        self.next_ms = now_ms + 250;
    }
};
pub const Response = struct { status: u16, body: []u8 };
pub const Client = struct {
    allocator: Allocator,
    socket_path: []const u8,
    bound: Bound,
    pub fn validate(self: Client) !void {
        if (self.socket_path.len == 0 or self.socket_path[0] != '/' or self.socket_path.len >= @sizeOf(@FieldType(std.c.sockaddr.un, "path"))) return error.InvalidDockerSocket;
        for (self.socket_path) |c| if (c < 32 or c == 127) return error.InvalidDockerSocket;
    }
    fn connect(self: Client) !Connection {
        try self.validate();
        try self.bound.check();
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.DockerUnavailable;
        errdefer _ = std.c.close(fd);
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(usize, std.c.FD_CLOEXEC)) != 0) return error.DockerUnavailable;
        const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(usize, 0));
        const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
        if (flags < 0 or std.c.fcntl(fd, std.c.F.SETFL, @as(usize, @intCast(flags | nonblock))) != 0) return error.DockerUnavailable;
        if (builtin.os.tag == .macos) {
            const one: c_int = 1;
            if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, &one, @sizeOf(c_int)) != 0) return error.DockerUnavailable;
        }
        var address: std.c.sockaddr.un = .{ .family = std.c.AF.UNIX, .path = @splat(0) };
        @memcpy(address.path[0..self.socket_path.len], self.socket_path);
        const length: std.c.socklen_t = @intCast(@offsetOf(std.c.sockaddr.un, "path") + self.socket_path.len + 1);
        if (@hasField(std.c.sockaddr.un, "len")) address.len = @intCast(length);
        var connection: Connection = .{ .fd = fd, .bound = self.bound };
        const rc = std.c.connect(fd, @ptrCast(&address), length);
        if (rc != 0) {
            if (std.c.errno(rc) != .INPROGRESS) return error.DockerUnavailable;
            try connection.ready(std.c.POLL.OUT);
            var socket_error: c_int = 0;
            var size: std.c.socklen_t = @sizeOf(c_int);
            if (std.c.getsockopt(fd, std.c.SOL.SOCKET, std.c.SO.ERROR, &socket_error, &size) != 0 or socket_error != 0) return error.DockerUnavailable;
        }
        return connection;
    }
    pub fn request(self: Client, method: []const u8, path: []const u8, body: []const u8) !Response {
        if (body.len > 262144) return error.DockerControlLimit;
        var connection = try self.connect();
        defer connection.close();
        try sendHead(self.allocator, &connection, method, path, body.len, false);
        try connection.writeAll(body);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.allocator);
        var buffer: [8192]u8 = undefined;
        while (true) {
            const n = try connection.read(&buffer);
            if (n == 0) break;
            if (bytes.items.len + n > 278528) return error.DockerControlLimit;
            try bytes.appendSlice(self.allocator, buffer[0..n]);
        }
        return decodeResponse(self.allocator, bytes.items, 262144);
    }
    pub fn attach(self: Client, id: []const u8) !Connection {
        var connection = try self.connect();
        errdefer connection.close();
        const path = try std.fmt.allocPrint(self.allocator, "/containers/{s}/attach?stream=1&stdin=1&stdout=1&stderr=1", .{id});
        defer self.allocator.free(path);
        try sendHead(self.allocator, &connection, "POST", path, 0, true);
        // Read exactly the header, retaining no unbounded upgraded peer data.
        var header: [16384]u8 = undefined;
        var used: usize = 0;
        while (used < header.len) {
            const n = try connection.read(header[used .. used + 1]);
            if (n == 0) return error.DockerAttach;
            used += 1;
            if (used >= 4 and std.mem.eql(u8, header[used - 4 .. used], "\r\n\r\n")) break;
        }
        if (used == header.len) return error.DockerControlLimit;
        if (try status(header[0..used]) != 101) return error.DockerAttach;
        return connection;
    }
};
pub const Connection = struct {
    fd: c_int,
    bound: Bound,
    pub fn close(self: *Connection) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
    }
    fn ready(self: Connection, events: i16) !void {
        while (true) {
            try self.bound.check();
            var descriptor: std.c.pollfd = .{ .fd = self.fd, .events = events, .revents = 0 };
            const rc = std.c.poll(@ptrCast(&descriptor), 1, 25);
            if (rc < 0) {
                if (std.c.errno(rc) == .INTR) continue;
                return error.DockerUnavailable;
            }
            if (rc == 0) continue;
            if (descriptor.revents & std.c.POLL.NVAL != 0) return error.DockerUnavailable;
            if (descriptor.revents & (events | std.c.POLL.HUP | std.c.POLL.ERR) != 0) return;
        }
    }
    pub fn writeAll(self: *Connection, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.ready(std.c.POLL.OUT);
            const n = std.c.send(self.fd, bytes[offset..].ptr, bytes.len - offset, if (@hasDecl(std.c.MSG, "NOSIGNAL")) std.c.MSG.NOSIGNAL else 0);
            if (n < 0) {
                switch (std.c.errno(n)) {
                    .AGAIN, .INTR => continue,
                    else => return error.DockerUnavailable,
                }
            }
            if (n == 0) return error.DockerUnavailable;
            offset += @intCast(n);
        }
    }
    pub fn read(self: *Connection, buffer: []u8) !usize {
        while (true) {
            try self.ready(std.c.POLL.IN);
            const n = std.c.recv(self.fd, buffer.ptr, buffer.len, 0);
            if (n < 0) {
                switch (std.c.errno(n)) {
                    .AGAIN, .INTR => continue,
                    else => return error.DockerUnavailable,
                }
            }
            return @intCast(n);
        }
    }
    pub fn finishInput(self: *Connection, bytes: []const u8) !void {
        try self.writeAll(bytes);
        if (std.c.shutdown(self.fd, std.c.SHUT.WR) != 0) return error.DockerAttach;
    }
    pub fn capture(self: *Connection, allocator: Allocator, output_cap: usize, diagnostic_cap: usize) !Capture {
        if (output_cap > 1048576 or diagnostic_cap > 65536) return error.InvalidLimits;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var err: std.ArrayList(u8) = .empty;
        errdefer err.deinit(allocator);
        var header: [8]u8 = undefined;
        var header_used: usize = 0;
        var remaining: usize = 0;
        var channel: u8 = 0;
        var buffer: [8192]u8 = undefined;
        while (true) {
            const n = try self.read(&buffer);
            if (n == 0) {
                if (remaining != 0 or header_used != 0) return error.DockerProtocol;
                break;
            }
            var i: usize = 0;
            while (i < n) {
                if (remaining == 0) {
                    const count = @min(8 - header_used, n - i);
                    @memcpy(header[header_used..][0..count], buffer[i..][0..count]);
                    header_used += count;
                    i += count;
                    if (header_used != 8) continue;
                    channel = header[0];
                    if ((channel != 1 and channel != 2) or header[1] != 0 or header[2] != 0 or header[3] != 0) return error.DockerProtocol;
                    remaining = std.mem.readInt(u32, header[4..8], .big);
                    header_used = 0;
                    const used = if (channel == 1) out.items.len else err.items.len;
                    const cap = if (channel == 1) output_cap else diagnostic_cap;
                    if (remaining > cap - used) return if (channel == 1) error.OutputLimit else error.DiagnosticLimit;
                    if (remaining == 0) continue;
                }
                const count = @min(remaining, n - i);
                if (channel == 1) try out.appendSlice(allocator, buffer[i..][0..count]) else try err.appendSlice(allocator, buffer[i..][0..count]);
                i += count;
                remaining -= count;
            }
        }
        return .{ .stdout = try out.toOwnedSlice(allocator), .stderr = try err.toOwnedSlice(allocator) };
    }
};
pub const Capture = struct { stdout: []u8, stderr: []u8 };
fn sendHead(allocator: Allocator, connection: *Connection, method: []const u8, path: []const u8, length: usize, upgrade: bool) !void {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfAny(u8, path, "\r\n\x00") != null) return error.DockerProtocol;
    const head = try std.fmt.allocPrint(allocator, "{s} /v1.45{s} HTTP/1.1\r\nHost: localhost\r\nConnection: {s}\r\n{s}Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{ method, path, if (upgrade) "Upgrade" else "close", if (upgrade) "Upgrade: tcp\r\n" else "", length });
    defer allocator.free(head);
    try connection.writeAll(head);
}
fn status(bytes: []const u8) !u16 {
    if (bytes.len < 12 or !std.mem.startsWith(u8, bytes, "HTTP/1.1 ")) return error.DockerProtocol;
    return std.fmt.parseInt(u16, bytes[9..12], 10) catch error.DockerProtocol;
}
pub fn escape(allocator: Allocator, text: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-_.~", c) != null) try result.append(allocator, c) else {
            const pair = std.fmt.bytesToHex([_]u8{c}, .upper);
            try result.append(allocator, '%');
            try result.appendSlice(allocator, &pair);
        }
    }
    return result.toOwnedSlice(allocator);
}
fn decodeResponse(allocator: Allocator, bytes: []const u8, cap: usize) !Response {
    const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.DockerProtocol;
    if (end > 16384) return error.DockerControlLimit;
    const code = try status(bytes[0..end]);
    const raw = bytes[end + 4 ..];
    var chunked = false;
    var length: ?usize = null;
    var lines = std.mem.splitSequence(u8, bytes[0..end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.DockerProtocol;
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "transfer-encoding")) {
            if (!std.ascii.eqlIgnoreCase(value, "chunked")) return error.DockerProtocol;
            chunked = true;
        }
        if (std.ascii.eqlIgnoreCase(key, "content-length")) {
            if (length != null) return error.DockerProtocol;
            length = std.fmt.parseInt(usize, value, 10) catch return error.DockerProtocol;
        }
    }
    if (chunked and length != null) return error.DockerProtocol;
    if (!chunked) {
        if (raw.len > cap) return error.DockerControlLimit;
        if (length) |n| if (n != raw.len) return error.DockerProtocol;
        return .{ .status = code, .body = try allocator.dupe(u8, raw) };
    }
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var offset: usize = 0;
    while (true) {
        const e = std.mem.indexOfPos(u8, raw, offset, "\r\n") orelse return error.DockerProtocol;
        const token = raw[offset..e];
        const semicolon = std.mem.indexOfScalar(u8, token, ';') orelse token.len;
        const n = std.fmt.parseInt(usize, token[0..semicolon], 16) catch return error.DockerProtocol;
        offset = e + 2;
        if (n == 0) {
            if (offset + 2 != raw.len or !std.mem.eql(u8, raw[offset..], "\r\n")) return error.DockerProtocol;
            break;
        }
        if (n > cap - result.items.len) return error.DockerControlLimit;
        if (n > raw.len - offset or raw.len - offset - n < 2 or !std.mem.eql(u8, raw[offset + n ..][0..2], "\r\n")) return error.DockerProtocol;
        try result.appendSlice(allocator, raw[offset..][0..n]);
        offset += n + 2;
    }
    return .{ .status = code, .body = try result.toOwnedSlice(allocator) };
}
test "Docker socket rejects overlong paths before connection or bound checks" {
    const capacity = @sizeOf(@FieldType(std.c.sockaddr.un, "path"));
    var path: [capacity + 1]u8 = @splat('x');
    path[0] = '/';
    var cancelled = std.atomic.Value(bool).init(true);
    var client: Client = .{
        .allocator = std.testing.allocator,
        .socket_path = path[0 .. capacity - 1],
        .bound = .{ .io = std.testing.io, .deadline_ms = 0, .cancel = &cancelled },
    };
    // The longest representable path passes validation; cancellation prevents I/O.
    try client.validate();
    try std.testing.expectError(error.Cancelled, client.request("GET", "/_ping", ""));
    for ([_][]const u8{ path[0..capacity], &path }) |overlong| {
        client.socket_path = overlong;
        try std.testing.expectError(error.InvalidDockerSocket, client.validate());
        try std.testing.expectError(error.InvalidDockerSocket, client.request("GET", "/_ping", ""));
    }
}

test "docker bounded HTTP and chunked decoding" {
    const allocator = std.testing.allocator;
    const response = try decodeResponse(allocator, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n", 8);
    defer allocator.free(response.body);
    try std.testing.expectEqualStrings("{}", response.body);
    try std.testing.expectError(error.DockerProtocol, decodeResponse(allocator, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n{}", 8));
    try std.testing.expectError(error.DockerControlLimit, decodeResponse(allocator, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", 1));
    _ = &Client.request;
    _ = &Client.attach;
    _ = &Connection.capture;
}
