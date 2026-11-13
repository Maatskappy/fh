// Modified for Fasthands; see patches/fx/README.md for the integration changes.
const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("debug_trace.zig");
const io_mod = @import("io.zig");

/// Long-lived HTTP client wrapper that keeps std's ConnectionPool alive
/// across requests to one product origin. std already implements acquire,
/// release, and thread safety; this wrapper owns the three product concerns
/// std does not: client lifetime, launch warming, and idle staleness.
///
/// Ownership: created by a session/run owner or provider runtime, borrowed by
/// request paths. All methods are safe to call from concurrent request
/// threads (the underlying std pool is internally mutex-guarded).
const default_ttl_ms: i64 = 30_000;

pub const HttpPool = struct {
    client: std.http.Client,
    /// Pooled connections idle longer than this are closed instead of reused.
    /// std's pool has no liveness tracking; a gracefully-idle-closed
    /// connection fails only when the next request reads from it, which lands
    /// in the delivery-ambiguity retry path. Bounding idle age keeps that
    /// rare. One conservative timestamp is enough: the pool only gains free
    /// connections at noteActivity-stamped completions, so when
    /// now - last_activity > ttl every free connection is provably stale.
    ttl_ms: i64 = default_ttl_ms,
    last_activity_ms: std.atomic.Value(i64) = .init(0),
    warm_started: std.atomic.Value(bool) = .init(false),
    warm_done: std.atomic.Value(bool) = .init(false),
    warm_stop: std.atomic.Value(bool) = .init(false),
    warm_thread: ?std.Thread = null,
    deinitialized: bool = false,

    pub const DestroyDisposition = enum {
        /// Pool resources released; caller may free the HttpPool itself.
        destroyed,
    };

    pub fn init(alloc: std.mem.Allocator) HttpPool {
        return .{ .client = .{ .allocator = alloc, .io = io_mod.getIo() } };
    }

    /// The owner joins the bounded warm flight before releasing its client.
    pub fn deinit(self: *HttpPool) DestroyDisposition {
        if (self.deinitialized) return .destroyed;
        self.deinitialized = true;
        self.warm_stop.store(true, .release);
        if (self.warm_thread) |thread| thread.join();
        self.warm_thread = null;
        self.client.deinit();
        return .destroyed;
    }

    pub fn noteActivity(self: *HttpPool) void {
        self.last_activity_ms.store(io_mod.milliTimestamp(), .release);
    }

    /// Free-connection count for observability; owns the std-pool locking so
    /// callers never touch connection_pool internals.
    pub fn freeConnectionCount(self: *HttpPool) usize {
        const io = io_mod.getIo();
        self.client.connection_pool.mutex.lockUncancelable(io);
        defer self.client.connection_pool.mutex.unlock(io);
        return self.client.connection_pool.free_len;
    }

    /// Establishes one connection to the URL's origin and parks it in the
    /// pool. Best-effort: failures are traced, never propagated.
    fn warm(self: *HttpPool, url: []const u8) void {
        const io = io_mod.getIo();
        const uri = std.Uri.parse(url) catch return;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return;
        if (protocol == .tls) {
            // Client.connect skips the TLS preamble that Client.request
            // performs; Tls.create requires ca_bundle loaded and now set.
            self.ensureTlsReady() catch |err| {
                debug_trace.logf("gateway", "pool_warm result=error stage=tls_init err={s}", .{@errorName(err)});
                return;
            };
        }
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = uri.getHost(&host_buf) catch return;
        const port: u16 = uri.port orelse defaultPort(protocol);
        const started = io_mod.milliTimestamp();
        const conn = self.client.connect(host, port, protocol) catch |err| {
            debug_trace.logf("gateway", "pool_warm result=error err={s}", .{@errorName(err)});
            return;
        };
        self.client.connection_pool.release(conn, io);
        self.noteActivity();
        debug_trace.logf("gateway", "pool_warm result=ok elapsed_ms={d}", .{io_mod.milliTimestamp() - started});
    }

    /// Mirrors the cert-bundle preamble of std.http.Client.request so direct
    /// Client.connect calls are safe. Concurrent with real requests by lock.
    fn ensureTlsReady(self: *HttpPool) !void {
        const client = &self.client;
        const io = client.io;
        {
            try client.ca_bundle_lock.lockShared(io);
            defer client.ca_bundle_lock.unlockShared(io);
            if (client.now != null) return;
        }
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(client.allocator);
        const now = std.Io.Clock.real.now(io);
        bundle.rescan(client.allocator, io, now) catch return error.CertificateBundleLoadFailure;
        try client.ca_bundle_lock.lock(io);
        defer client.ca_bundle_lock.unlock(io);
        if (client.now != null) return; // a concurrent request loaded it first
        client.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    }

    /// Best-effort connection-only warmup. Own the URL and join on teardown;
    /// the cancellable I/O race bounds DNS/TCP/TLS work without a generation.
    pub fn warmAsync(self: *HttpPool, url: []const u8) void {
        if (comptime builtin.is_test) return;
        self.startWarm(url);
    }

    fn startWarm(self: *HttpPool, url: []const u8) void {
        if (self.warm_started.swap(true, .acq_rel)) return;
        const owned = self.client.allocator.dupe(u8, url) catch {
            self.warm_started.store(false, .release);
            return;
        };
        self.warm_thread = std.Thread.spawn(.{}, warmThreadMain, .{ self, owned }) catch {
            self.client.allocator.free(owned);
            self.warm_started.store(false, .release);
            return;
        };
    }

    fn warmThreadMain(self: *HttpPool, url: []u8) void {
        defer self.client.allocator.free(url);
        defer self.warm_done.store(true, .release);
        const Event = union(enum) { warm: void, stop: anyerror!void };
        var buffer: [2]Event = undefined;
        var select: std.Io.Select(Event) = .init(io_mod.getIo(), &buffer);
        defer select.cancelDiscard();
        select.concurrent(.stop, waitForWarmStop, .{self}) catch return;
        select.concurrent(.warm, warm, .{ self, url }) catch return;
        _ = select.await() catch return;
    }

    fn waitForWarmStop(self: *HttpPool) !void {
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(500) });
        while (!self.warm_stop.load(.acquire)) {
            if (!std.Io.Clock.Timestamp.compare(.now(io_mod.getIo(), .awake), .lt, deadline)) return;
            try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
        }
    }

    /// Returns the shared client after applying the idle-staleness policy for
    /// this origin. Call once per request, before opening.
    pub fn clientFor(self: *HttpPool, url: []const u8) *std.http.Client {
        self.drainIfStale(url);
        return &self.client;
    }

    fn drainIfStale(self: *HttpPool, url: []const u8) void {
        const last = self.last_activity_ms.load(.acquire);
        if (last == 0) return;
        const now = io_mod.milliTimestamp();
        const idle_ms = now - last;
        if (idle_ms <= self.ttl_ms) return;
        const io = io_mod.getIo();
        const uri = std.Uri.parse(url) catch return;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = uri.getHost(&host_buf) catch return;
        const port: u16 = uri.port orelse defaultPort(protocol);
        const criteria: std.http.Client.ConnectionPool.Criteria = .{
            .host = host,
            .port = port,
            .protocol = protocol,
        };
        var drained: usize = 0;
        while (self.client.connection_pool.findConnection(io, criteria)) |conn| {
            // findConnection moves the connection to the used list; unlink it
            // there before destroying, since destroy does not touch the lists.
            self.client.connection_pool.mutex.lockUncancelable(io);
            self.client.connection_pool.used.remove(&conn.pool_node);
            self.client.connection_pool.mutex.unlock(io);
            conn.destroy(io);
            drained += 1;
        }
        // Refresh the stamp so a run of misses does not re-drain every call.
        self.last_activity_ms.store(now, .release);
        if (drained > 0) {
            debug_trace.logf("gateway", "pool_drain_stale count={d} idle_ms={d} ttl_ms={d}", .{ drained, idle_ms, self.ttl_ms });
        }
    }

    fn defaultPort(protocol: std.http.Client.Protocol) u16 {
        return switch (protocol) {
            .plain => 80,
            .tls => 443,
        };
    }
};

/// One chat session or actual Loop run owns this scope. Only transport state
/// persists: each caller retains its own headers, body, callbacks and secrets.
/// The private digest includes the endpoint, credential source/value, account
/// and conversation identity. A concurrent borrower falls back to a local
/// client instead of rotating or destroying a client another request uses.
pub const Scope = struct {
    alloc: std.mem.Allocator,
    pool: ?HttpPool = null,
    identity: ?[32]u8 = null,
    origin: ?[32]u8 = null,
    busy: std.atomic.Value(bool) = .init(false),

    pub fn init(alloc: std.mem.Allocator) Scope {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Scope) void {
        std.debug.assert(!self.busy.load(.acquire));
        if (self.pool) |*pool| _ = pool.deinit();
        self.pool = null;
    }

    fn digest(fields: []const []const u8) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for (fields) |field| {
            const len: u64 = field.len;
            hash.update(std.mem.asBytes(&len));
            hash.update(field);
        }
        return hash.finalResult();
    }

    pub fn acquire(self: *Scope, url: []const u8, fields: []const []const u8) ?*HttpPool {
        if (self.busy.swap(true, .acq_rel)) return null;
        const origin = digest(&.{url});
        const identity = digest(fields);
        if (self.pool != null and ((self.origin != null and !std.mem.eql(u8, &self.origin.?, &origin)) or
            (self.identity != null and !std.mem.eql(u8, &self.identity.?, &identity))))
        {
            _ = self.pool.?.deinit();
            self.pool = null;
        }
        if (self.pool == null) self.pool = HttpPool.init(self.alloc);
        self.origin = origin;
        self.identity = identity;
        return &self.pool.?;
    }

    pub fn release(self: *Scope) void {
        self.busy.store(false, .release);
    }

    pub fn warmAsync(self: *Scope, url: []const u8) void {
        if (self.busy.swap(true, .acq_rel)) return;
        defer self.release();
        if (self.pool != null) return;
        self.pool = HttpPool.init(self.alloc);
        self.origin = digest(&.{url});
        self.pool.?.warmAsync(url);
    }
};

test "warm and drain tolerate malformed urls without touching the pool" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.warm("not a url");
    pool.warm("ftp://unsupported.example");
    _ = pool.clientFor("not a url");
    try std.testing.expectEqual(@as(i64, 0), pool.last_activity_ms.load(.acquire));
}

test "drainIfStale skips within-ttl and never-active pools" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.noteActivity();
    _ = pool.clientFor("https://ai-gateway.vercel.sh/v4/ai/language-model");
    const stamp = pool.last_activity_ms.load(.acquire);
    try std.testing.expect(stamp > 0);
    pool.ttl_ms = 0; // force stale on next call; empty pool drains zero
    _ = pool.clientFor("https://ai-gateway.vercel.sh/v4/ai/language-model");
    try std.testing.expect(pool.last_activity_ms.load(.acquire) >= stamp);
}

test "warmAsync is a no-op in test builds" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.warmAsync("https://127.0.0.1:1/unreachable");
    try std.testing.expect(!pool.warm_started.load(.acquire));
}

test "drain evicts a real parked connection past the TTL" {
    const zio = io_mod.getIo();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(zio, .{ .reuse_address = true });
    defer server.deinit(zio);
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/chat", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();

    // The listen backlog completes the connect without any server accept.
    pool.warm(url);
    try std.testing.expectEqual(@as(usize, 1), pool.freeConnectionCount());

    pool.ttl_ms = 0; // every parked connection is stale immediately
    pool.last_activity_ms.store(io_mod.milliTimestamp() - 1000, .release);
    _ = pool.clientFor(url);
    try std.testing.expectEqual(@as(usize, 0), pool.freeConnectionCount());
}

test "fh pooled warmup performs no request and joins stalled TLS on deadline or cancellation" {
    const Fixture = @import("../../../../../native/loops/transport_fixture.zig");
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |cancel| {
        var server = try Fixture.Server.init(&.{.{ .body = "{}" }});
        defer server.deinit();
        try server.start();
        const url = try std.fmt.allocPrint(alloc, "https://127.0.0.1:{d}/responses", .{server.listener.socket.address.getPort()});
        defer alloc.free(url);
        var pool = HttpPool.init(alloc);
        defer _ = pool.deinit();
        const start = std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds();
        pool.startWarm(url);
        while (server.accepted.load(.acquire) == 0 and !pool.warm_done.load(.acquire)) {
            try std.testing.expect(std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds() - start < 1500);
            io_mod.sleep(std.time.ns_per_ms);
        }
        if (!cancel) while (!pool.warm_done.load(.acquire)) {
            try std.testing.expect(std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds() - start < 1500);
            io_mod.sleep(std.time.ns_per_ms);
        };
        _ = pool.deinit();
        try std.testing.expect(pool.warm_thread == null);
        try std.testing.expect(pool.warm_done.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), server.served.load(.acquire));
        try std.testing.expect(std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds() - start < 1500);
    }
    var server = try Fixture.Server.init(&.{.{ .body = "{}" }});
    defer server.deinit();
    try server.start();
    const url = try server.url(alloc);
    defer alloc.free(url);
    var pool = HttpPool.init(alloc);
    defer _ = pool.deinit();
    pool.startWarm(url);
    while (!pool.warm_done.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 1), pool.freeConnectionCount());
    try std.testing.expectEqual(@as(usize, 0), server.served.load(.acquire));
}
