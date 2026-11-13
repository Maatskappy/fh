//! Direct foreground capture; validation precedes credentials and connection.
const std = @import("std");
const capture = @import("capture.zig");
const ws = @import("websocket.zig");
const io_mod = @import("../../vendor/fx/src/core/shared/io.zig");
const schema = @import("../loops/schema.zig");
const Guard = @import("../loops_client.zig").SigintGuard;
const Value = capture.Value;
fn output(fd: c_int, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n <= 0) return;
        offset += @intCast(n);
    }
}
fn digest(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
fn boundedFile(a: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]const u8 {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind != .file or stat.size > limit) return error.InvalidFile;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const opened = try file.stat(io);
    if (opened.kind != .file or opened.inode != stat.inode or opened.size > limit) return error.InvalidFile;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(a, .limited(limit));
}
fn sources(a: std.mem.Allocator, io: std.Io, plan: Value, plan_path: []const u8) !Value {
    var result = capture.array(a);
    if (capture.field(plan, "sources")) |listed| for (listed.array.items) |item| {
        const path = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(plan_path) orelse ".", item.string });
        const bytes = try boundedFile(a, io, path, 4 * 1048576);
        var record = capture.object();
        try capture.put(a, &record, "path", capture.str(path));
        try capture.put(a, &record, "sha256_before", capture.str(try digest(a, bytes)));
        try capture.put(a, &record, "bytes_before", .{ .integer = @intCast(bytes.len) });
        try capture.put(a, &record, "changed", .null);
        try result.array.append(record);
        a.free(bytes);
    };
    return result;
}
fn afterSources(a: std.mem.Allocator, io: std.Io, records: *Value) !void {
    for (records.array.items) |*record| {
        const bytes = boundedFile(a, io, (try capture.get(record.*, "path")).string, 4 * 1048576) catch |err| {
            try capture.put(a, record, "after_error", capture.str(@errorName(err)));
            continue;
        };
        defer a.free(bytes);
        const hash = try digest(a, bytes);
        try capture.put(a, record, "sha256_after", capture.str(hash));
        try capture.put(a, record, "bytes_after", .{ .integer = @intCast(bytes.len) });
        try capture.put(a, record, "changed", .{ .bool = !std.mem.eql(u8, hash, (try capture.get(record.*, "sha256_before")).string) });
    }
}
const Work = struct {
    engine: *capture.Engine,
    done: std.atomic.Value(bool) = .init(false),
    cleanup: bool = false,
    fn run(w: *Work) anyerror!void {
        defer w.done.store(true, .release);
        if (w.cleanup) return w.engine.cleanup();
        return w.engine.run() catch |err| {
            w.engine.failureTiming();
            return err;
        };
    }
};
fn boundedRun(io: std.Io, work: *Work, deadline: i64, observe_signal: bool) !void {
    var future = try io.concurrent(Work.run, .{work});
    while (!work.done.load(.acquire)) {
        if (observe_signal and Guard.requested()) {
            _ = future.cancel(io) catch {};
            return error.CaptureCancelled;
        }
        if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) {
            _ = future.cancel(io) catch {};
            return error.CaptureDeadline;
        }
        // This is cancellation monitoring, never browser readiness or settling.
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    return future.await(io);
}
fn scrub(a: std.mem.Allocator, value: *Value, token: ?[]const u8) !void {
    switch (value.*) {
        .string => |s| if (token) |secret| {
            if (std.mem.indexOf(u8, s, secret) != null) value.* = capture.str(try std.mem.replaceOwned(u8, a, s, secret, "[REDACTED]"));
        },
        .array => |arr| for (arr.items) |*item| try scrub(a, item, token),
        .object => |obj| {
            for (obj.values()) |*item| try scrub(a, item, token);
            // Keys can also contain echoed authorization values.
            if (token) |secret| {
                var replacement = capture.object();
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key = try std.mem.replaceOwned(u8, a, entry.key_ptr.*, secret, "[REDACTED]");
                    try capture.put(a, &replacement, key, entry.value_ptr.*);
                }
                value.* = replacement;
            }
        },
        else => {},
    }
}
fn invoke(a: std.mem.Allocator, raw: []const [*:0]const u8, wants_json: bool, acquired: *bool) !u8 {
    const io = io_mod.getIo();
    if (raw.len < 3) return error.Usage;
    const path = std.mem.span(raw[2]);
    var endpoint: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var env_name: ?[]const u8 = null;
    var json_seen = false;
    var i: usize = 3;
    while (i < raw.len) : (i += 1) {
        const flag = std.mem.span(raw[i]);
        if (std.mem.eql(u8, flag, "--json")) {
            if (json_seen) return error.Usage;
            json_seen = true;
            continue;
        }
        if (i + 1 >= raw.len) return error.Usage;
        i += 1;
        const value = std.mem.span(raw[i]);
        if (std.mem.eql(u8, flag, "--cdp")) {
            if (endpoint != null) return error.Usage;
            endpoint = value;
        } else if (std.mem.eql(u8, flag, "--out")) {
            if (out_path != null) return error.Usage;
            out_path = value;
        } else if (std.mem.eql(u8, flag, "--token-env")) {
            if (env_name != null or value.len == 0 or value.len > 128) return error.Usage;
            for (value, 0..) |c, n| if (!(std.ascii.isAlphabetic(c) or c == '_' or (n != 0 and std.ascii.isDigit(c)))) return error.Usage;
            env_name = value;
        } else return error.Usage;
    }
    const uri = try ws.validateEndpoint(endpoint orelse return error.Usage);
    const output_path = out_path orelse return error.Usage;
    if (output_path.len == 0 or output_path.len > 4096) return error.InvalidOutput;
    for (output_path) |c| if (c < 32 or c == 127) return error.InvalidOutput;
    const plan_bytes = try boundedFile(a, io, path, 1048576);
    const plan = try schema.parse(a, plan_bytes);
    try capture.validatePlan(plan);
    var source_records = try sources(a, io, plan, path);
    const absolute_output = try std.fs.path.resolve(a, &.{ try std.process.currentPathAlloc(io, a), output_path });
    std.Io.Dir.cwd().createDir(io, absolute_output, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
    var dir = try io_mod.openDirAbsoluteNoFollow(absolute_output, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    if (try iterator.next(io) != null) return error.OutputNotEmpty;
    // Reserve the receipt before reading authentication or connecting. Exclusive
    // creation also rejects concurrent invocations sharing an output directory.
    var receipt_file = try dir.createFile(io, "capture.json", .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer receipt_file.close(io);
    acquired.* = true;
    var result = capture.object();
    try capture.put(a, &result, "version", capture.str("fh.capture.result/0.1"));
    try capture.put(a, &result, "status", capture.str("failed"));
    try capture.put(a, &result, "plan_sha256", capture.str(try digest(a, plan_bytes)));
    // The raw endpoint (query may contain credentials) never reaches receipts.
    const sanitized_uri = std.Uri{ .scheme = uri.scheme, .host = uri.host, .port = uri.port, .path = uri.path };
    try capture.put(a, &result, "endpoint", capture.str(try std.fmt.allocPrint(a, "{f}", .{sanitized_uri})));
    try capture.put(a, &result, "browser", .null);
    var viewport = capture.object();
    try capture.put(a, &viewport, "width", .{ .integer = 1280 });
    try capture.put(a, &viewport, "height", .{ .integer = 720 });
    try capture.put(a, &result, "viewport", capture.field(plan, "viewport") orelse viewport);
    try capture.put(a, &result, "checkpoints", capture.array(a));
    try capture.put(a, &result, "freshness", capture.str("not_established"));
    var token: ?[]const u8 = null;
    var failure: ?anyerror = null;
    if (env_name) |name| {
        const terminated = try a.dupeZ(u8, name);
        if (std.c.getenv(terminated)) |value| {
            const secret = std.mem.span(value);
            if (secret.len == 0 or secret.len > 8192) failure = error.InvalidToken else {
                for (secret) |c| if (c <= 32 or c >= 127) {
                    failure = error.InvalidToken;
                    break;
                };
                if (failure == null) token = try a.dupe(u8, secret);
            }
        } else failure = error.MissingToken;
    }
    var guard = Guard.install();
    defer guard.deinit();
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    const timeout = if (capture.field(plan, "timeout_ms")) |t| t.integer else 10000;
    var engine = capture.Engine{ .allocator = a, .io = io, .plan = plan, .endpoint = endpoint.?, .token = token, .out = dir, .deadline_ms = started + timeout, .socket = ws.Socket.init(std.heap.c_allocator, io), .network = capture.Network.init(a), .result = result };
    defer engine.deinit();
    if (failure == null) {
        var work = Work{ .engine = &engine };
        boundedRun(io, &work, engine.deadline_ms, true) catch |err| {
            failure = err;
        };
    }
    if (failure) |err| {
        try capture.put(a, &engine.result, "error", capture.str(@errorName(err)));
        try capture.put(a, &engine.result, "error_stage", capture.str(engine.stage));
        if (engine.cdp_initialized) if (engine.cdp.last_error) |detail| try capture.put(a, &engine.result, "command_error", capture.str(try a.dupe(u8, detail)));
    }
    const cleanup_start = engine.now();
    var cleanup = Work{ .engine = &engine, .cleanup = true };
    // Cleanup is a separately bounded best effort even after primary cancellation.
    boundedRun(io, &cleanup, cleanup_start + 500, false) catch |err| {
        try capture.put(a, &engine.result, "cleanup_error", capture.str(@errorName(err)));
        try capture.put(a, &engine.result, "target_cleanup", capture.str("failed"));
        if (failure == null) {
            failure = err;
            try capture.put(a, &engine.result, "error_stage", capture.str("cleanup"));
        }
    };
    engine.timings.cleanup_ms = engine.now() - cleanup_start;
    if (failure) |err| if (capture.field(engine.result, "error") == null) try capture.put(a, &engine.result, "error", capture.str(@errorName(err)));
    try afterSources(a, io, &source_records);
    try capture.put(a, &engine.result, "sources", source_records);
    var gaps = capture.array(a);
    if (failure != null) try gaps.array.append(capture.str("procedure_failed_or_cancelled"));
    if (engine.network.dropped != 0) try gaps.array.append(capture.str("network_record_limit"));
    if (engine.network.events_omitted != 0) try gaps.array.append(capture.str("network_event_retention_limit"));
    for (engine.network.records.array.items) |record| {
        const body_state = (try capture.get(record, "body_state")).string;
        if (!std.mem.eql(u8, body_state, "retrieved")) {
            try gaps.array.append(capture.str(try std.fmt.allocPrint(a, "response_body_{s}", .{body_state})));
        }
    }
    try capture.put(a, &engine.result, "network", engine.network.records);
    try capture.put(a, &engine.result, "network_receipts_complete", .{ .bool = engine.network.dropped == 0 and engine.network.events_omitted == 0 });
    try capture.put(a, &engine.result, "network_events_omitted", .{ .integer = @intCast(engine.network.events_omitted) });
    try capture.put(a, &engine.result, "network_records_dropped", .{ .integer = @intCast(engine.network.dropped) });
    try capture.put(a, &engine.result, "evidence_complete", .{ .bool = gaps.array.items.len == 0 });
    try capture.put(a, &engine.result, "evidence_gaps", gaps);
    const status = if (failure != null and failure.? == error.CaptureCancelled) "cancelled" else if (failure != null) "failed" else "completed";
    try capture.put(a, &engine.result, "status", capture.str(status));
    try capture.put(a, &engine.result, "start_ms", .{ .integer = started });
    try capture.put(a, &engine.result, "end_ms", .{ .integer = engine.now() });
    const timings = try std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, engine.timings, .{}), .{});
    try capture.put(a, &engine.result, "timings", timings);
    try scrub(a, &engine.result, token);
    const export_started = engine.now();
    const initial_bytes = try std.json.Stringify.valueAlloc(a, engine.result, .{});
    try receipt_file.writePositionalAll(io, initial_bytes, 0);
    engine.timings.export_ms += engine.now() - export_started;
    try capture.put(a, engine.result.object.getPtr("timings").?, "export_ms", .{ .integer = engine.timings.export_ms });
    // This file was exclusively reserved by this invocation. Correct only its
    // timing field; existing artifacts are never opened for replacement.
    const bytes = try std.json.Stringify.valueAlloc(a, engine.result, .{});
    try receipt_file.writePositionalAll(io, bytes, 0);
    try receipt_file.setLength(io, bytes.len);
    if (wants_json) {
        output(1, bytes);
        output(1, "\n");
    } else {
        output(1, status);
        output(1, ": ");
        output(1, absolute_output);
        output(1, "/capture.json\n");
    }
    return if (failure != null and failure.? == error.CaptureCancelled) 130 else if (failure != null) 1 else 0;
}
pub fn direct(raw: []const [*:0]const u8) !?u8 {
    if (raw.len < 2 or !std.mem.eql(u8, std.mem.span(raw[1]), "capture")) return null;
    var wants_json = false;
    for (raw[2..]) |arg| if (std.mem.eql(u8, std.mem.span(arg), "--json")) {
        wants_json = true;
    };
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    var acquired = false;
    return invoke(arena.allocator(), raw, wants_json, &acquired) catch |err| {
        // Error names contain no endpoint, environment value, or saved expression.
        if (wants_json) {
            output(1, "{\"version\":\"fh.capture.result/0.1\",\"status\":\"failed\",\"error\":\"");
            output(1, @errorName(err));
            output(1, "\"}\n");
        }
        output(2, "capture: ");
        output(2, @errorName(err));
        output(2, "\n");
        return if (acquired) 1 else 2;
    };
}
