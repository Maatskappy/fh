//! Controlled HTTP/1.1 peer shared by native provider transport tests.
const std = @import("std");
const io_mod = @import("../../vendor/fx/src/core/shared/io.zig");
pub const Reply = struct {
    body: []const u8,
    status: u16 = 200,
    mode: enum { complete, delayed_tail, endless_tail, stall, close, close_idle, reset } = .complete,
};
pub const Server = struct {
    listener: std.Io.net.Server,
    replies: []const Reply,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    active: ?std.Io.net.Stream = null,
    stopping: std.atomic.Value(bool) = .init(false),
    accepted: std.atomic.Value(usize) = .init(0),
    served: std.atomic.Value(usize) = .init(0),
    headers: [16][4096]u8 = undefined,
    header_lens: [16]usize = @splat(0),
    bodies: [16][8192]u8 = undefined,
    body_lens: [16]usize = @splat(0),
    connections: [16]usize = @splat(0),

    pub fn init(replies: []const Reply) !Server {
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .listener = try address.listen(io_mod.getIo(), .{ .reuse_address = true }), .replies = replies };
    }
    pub fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    pub fn url(self: *Server, alloc: std.mem.Allocator) ![:0]u8 {
        return std.fmt.allocPrintSentinel(alloc, "http://127.0.0.1:{d}/responses", .{self.listener.socket.address.getPort()}, 0);
    }
    pub fn deinit(self: *Server) void {
        const io = io_mod.getIo();
        self.stopping.store(true, .release);
        self.mutex.lockUncancelable(io);
        if (self.active) |stream| stream.shutdown(io, .both) catch {};
        self.mutex.unlock(io);
        const listener = std.Io.net.Stream{ .socket = self.listener.socket };
        listener.shutdown(io, .both) catch {};
        // Darwin's listener shutdown may need a wake connection.
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.listener.socket.address.getPort()) };
        if (address.connect(io, .{ .mode = .stream })) |stream| stream.close(io) else |_| {}
        if (self.thread) |thread| thread.join();
        self.listener.deinit(io);
    }
    pub fn header(self: *Server, index: usize, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.headers[index][0..self.header_lens[index]], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
        return null;
    }
    fn run(self: *Server) void {
        const io = io_mod.getIo();
        while (!self.stopping.load(.acquire) and self.served.load(.acquire) < self.replies.len) {
            const stream = self.listener.accept(io) catch return;
            if (self.stopping.load(.acquire)) {
                stream.close(io);
                return;
            }
            const connection = self.accepted.fetchAdd(1, .acq_rel) + 1;
            self.mutex.lockUncancelable(io);
            self.active = stream;
            self.mutex.unlock(io);
            self.serve(stream, connection) catch {};
            self.mutex.lockUncancelable(io);
            self.active = null;
            stream.close(io);
            self.mutex.unlock(io);
        }
    }
    fn serve(self: *Server, stream: std.Io.net.Stream, connection: usize) !void {
        const io = io_mod.getIo();
        var buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &buffer);
        while (!self.stopping.load(.acquire)) {
            const index = self.served.load(.acquire);
            if (index >= self.replies.len) return;
            var n: usize = 0;
            while (n < self.headers[index].len) {
                self.headers[index][n] = try reader.interface.takeByte();
                n += 1;
                if (std.mem.endsWith(u8, self.headers[index][0..n], "\r\n\r\n")) break;
            } else return error.HeaderTooLarge;
            self.header_lens[index] = n;
            const len = try std.fmt.parseInt(usize, self.header(index, "content-length") orelse "0", 10);
            if (len > self.bodies[index].len) return error.BodyTooLarge;
            try reader.interface.readSliceAll(self.bodies[index][0..len]);
            self.body_lens[index] = len;
            self.connections[index] = connection;
            _ = self.served.fetchAdd(1, .release);
            const reply = self.replies[index];
            if (reply.mode == .reset) {
                const linger: std.posix.linger = .{ .onoff = 1, .linger = 0 };
                std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger)) catch {};
                return;
            }
            if (reply.mode == .stall) {
                _ = reader.interface.takeByte() catch {};
                return;
            }
            var head: [256]u8 = undefined;
            const header_bytes = try std.fmt.bufPrint(&head, "HTTP/1.1 {d} Test\r\nTransfer-Encoding: chunked\r\n{s}\r\n{x}\r\n", .{ reply.status, if (reply.mode == .close) "Connection: close\r\n" else "", reply.body.len });
            try write(stream, header_bytes);
            if (reply.body.len > 0) {
                try write(stream, reply.body);
                try write(stream, "\r\n");
            }
            if (reply.mode == .endless_tail) {
                _ = reader.interface.takeByte() catch {};
                return;
            }
            if (reply.mode == .delayed_tail) {
                try io.sleep(.fromMilliseconds(20), .awake);
                const padding = ":" ** (300 * 1024);
                var chunk: [32]u8 = undefined;
                try write(stream, try std.fmt.bufPrint(&chunk, "{x}\r\n", .{padding.len}));
                try write(stream, padding);
                try write(stream, "\r\n");
            }
            if (reply.body.len > 0) try write(stream, "0\r\n\r\n") else try write(stream, "\r\n");
            if (reply.mode == .close or reply.mode == .close_idle) return;
        }
    }
    fn write(stream: std.Io.net.Stream, bytes: []const u8) !void {
        var buffer: [4096]u8 = undefined;
        var writer = stream.writer(io_mod.getIo(), &buffer);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }
};

pub const Env = struct {
    previous_map: ?*const std.process.Environ.Map,
    previous: ?[:0]u8,
    name: [:0]const u8,
    extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
    extern "c" fn unsetenv([*:0]const u8) c_int;
    pub fn init(name: [:0]const u8, value: [:0]const u8) !Env {
        const prior = if (std.c.getenv(name)) |bytes| try std.testing.allocator.dupeZ(u8, std.mem.span(bytes)) else null;
        if (setenv(name, value, 1) != 0) return error.SetEnvFailed;
        const previous_map = io_mod.environMap();
        io_mod.setRawEnviron(&.{null});
        return .{ .previous_map = previous_map, .previous = prior, .name = name };
    }
    pub fn deinit(self: Env) void {
        if (self.previous_map) |map| io_mod.setEnvironMap(map);
        if (self.previous) |value| {
            _ = setenv(self.name, value, 1);
            std.testing.allocator.free(value);
        } else _ = unsetenv(self.name);
    }
};
