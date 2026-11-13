//! Strict saved procedures, owned target lifecycle, and browser evidence.
const std = @import("std");
const ws = @import("websocket.zig");
const cdp_mod = @import("cdp.zig");
pub const Value = std.json.Value;
pub fn object() Value {
    return .{ .object = .{} };
}
pub fn array(a: std.mem.Allocator) Value {
    return .{ .array = std.array_list.Managed(Value).init(a) };
}
pub fn put(a: std.mem.Allocator, v: *Value, k: []const u8, x: Value) !void {
    try v.object.put(a, k, x);
}
pub fn str(s: []const u8) Value {
    return .{ .string = s };
}
pub fn field(v: Value, k: []const u8) ?Value {
    return if (v == .object) v.object.get(k) else null;
}
pub fn text(v: Value) ![]const u8 {
    return if (v == .string) v.string else error.InvalidPlan;
}
pub fn get(v: Value, k: []const u8) !Value {
    return field(v, k) orelse error.InvalidPlan;
}
pub fn clone(a: std.mem.Allocator, v: Value) !Value {
    const bytes = try std.json.Stringify.valueAlloc(a, v, .{});
    return (try std.json.parseFromSlice(Value, a, bytes, .{ .allocate = .alloc_always })).value;
}
fn keys(v: Value, allowed: []const []const u8) !void {
    if (v != .object) return error.InvalidPlan;
    var it = v.object.iterator();
    while (it.next()) |entry| {
        var ok = false;
        for (allowed) |k| if (std.mem.eql(u8, k, entry.key_ptr.*)) {
            ok = true;
            break;
        };
        if (!ok) return error.InvalidPlan;
    }
}
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}
pub fn validateUrl(bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidPlan;
    for (bytes) |c| if (c <= 32 or c == 127) return error.InvalidPlan;
    const uri = std.Uri.parse(bytes) catch return error.InvalidPlan;
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or uri.host == null or uri.user != null or uri.password != null or uri.port == 0) return error.InvalidPlan;
    var host: [std.Io.net.HostName.max_len]u8 = undefined;
    _ = uri.getHost(&host) catch return error.InvalidPlan;
}
pub fn dimension(v: Value) !i64 {
    if (v != .integer or v.integer < 1 or v.integer > 4096) return error.InvalidPlan;
    return v.integer;
}
pub fn validatePlan(v: Value) !void {
    try keys(v, &.{ "version", "url", "viewport", "timeout_ms", "checkpoints", "sources" });
    if (!std.mem.eql(u8, try text(try get(v, "version")), "fh.capture/0.1")) return error.InvalidPlan;
    try validateUrl(try text(try get(v, "url")));
    if (field(v, "timeout_ms")) |t| if (t != .integer or t.integer < 1 or t.integer > 60000) return error.InvalidPlan;
    if (field(v, "viewport")) |vp| {
        try keys(vp, &.{ "width", "height" });
        const w = try dimension(try get(vp, "width"));
        const h = try dimension(try get(vp, "height"));
        if (w * h > 8388608) return error.InvalidPlan;
    }
    const cps = try get(v, "checkpoints");
    if (cps != .array or cps.array.items.len == 0 or cps.array.items.len > 32) return error.InvalidPlan;
    for (cps.array.items, 0..) |cp, i| {
        try keys(cp, &.{ "id", "action", "wait", "evaluate", "screenshot" });
        const id = try text(try get(cp, "id"));
        if (!validId(id)) return error.InvalidPlan;
        for (cps.array.items[0..i]) |prev| if (std.mem.eql(u8, id, try text(try get(prev, "id")))) return error.InvalidPlan;
        for ([_][]const u8{ "action", "wait", "evaluate" }) |k| if (field(cp, k)) |x| {
            const expression = try text(x);
            if (expression.len == 0) return error.InvalidPlan;
        };
        if (field(cp, "screenshot")) |x| if (x != .bool) return error.InvalidPlan;
    }
    if (field(v, "sources")) |sources| {
        if (sources != .array or sources.array.items.len > 16) return error.InvalidPlan;
        for (sources.array.items, 0..) |source, i| {
            const path = try text(source);
            if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPlan;
            for (path) |c| if (c < 32 or c == 127) return error.InvalidPlan;
            for (sources.array.items[0..i]) |p| if (std.mem.eql(u8, path, try text(p))) return error.InvalidPlan;
        }
    }
}
test "native capture strict plans permit page fragments reject unsafe IDs unknown fields and empty checkpoints" {
    const good = "{\"version\":\"fh.capture/0.1\",\"url\":\"https://example.com/#route\",\"checkpoints\":[{\"id\":\"loaded\"}]}";
    var p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, good, .{});
    defer p.deinit();
    try validatePlan(p.value);
    const bad = [_][]const u8{ "{\"version\":\"fh.capture/0.1\",\"url\":\"https://example.com\",\"checkpoints\":[]}", "{\"version\":\"fh.capture/0.1\",\"url\":\"https://example.com\",\"checkpoints\":[{\"id\":\"../x\"}]}", "{\"version\":\"fh.capture/0.1\",\"url\":\"https://example.com\",\"checkpoints\":[{\"id\":\"x\"},{\"id\":\"x\"}]}", "{\"version\":\"fh.capture/0.1\",\"url\":\"https://user:secret@example.com\",\"checkpoints\":[{\"id\":\"x\"}]}", "{\"version\":\"fh.capture/0.1\",\"url\":\"https://example.com\",\"extra\":1,\"checkpoints\":[{\"id\":\"x\"}]}" };
    for (bad) |bytes| {
        var b = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer b.deinit();
        try std.testing.expectError(error.InvalidPlan, validatePlan(b.value));
    }
}

pub const Network = struct {
    allocator: std.mem.Allocator,
    records: Value,
    dropped: usize = 0,
    bodies_bytes: usize = 0,
    events_bytes: usize = 0,
    events_omitted: usize = 0,
    pub fn init(a: std.mem.Allocator) Network {
        return .{ .allocator = a, .records = array(a) };
    }
    pub fn current(n: *Network, session: []const u8, id: []const u8) ?*Value {
        var i = n.records.array.items.len;
        while (i > 0) {
            i -= 1;
            const r = &n.records.array.items[i];
            if (std.mem.eql(u8, session, text(get(r.*, "session_id") catch continue) catch continue) and std.mem.eql(u8, id, text(get(r.*, "request_id") catch continue) catch continue)) return r;
        }
        return null;
    }
    pub fn event(n: *Network, packet: Value, now: i64) !void {
        const method = text(field(packet, "method") orelse return) catch return;
        if (!std.mem.startsWith(u8, method, "Network.")) return;
        const session = text(field(packet, "sessionId") orelse return) catch return;
        const p = field(packet, "params") orelse return;
        const encoded = try std.json.Stringify.valueAlloc(std.heap.c_allocator, p, .{});
        defer std.heap.c_allocator.free(encoded);
        if (encoded.len > 65536 or encoded.len > 4 * 1048576 - n.events_bytes) {
            n.events_omitted += 1;
            return;
        }
        n.events_bytes += encoded.len;
        const id = text(field(p, "requestId") orelse return) catch return;
        const r = n.current(session, id);
        if (std.mem.eql(u8, method, "Network.requestWillBeSent")) {
            var hop: i64 = 0;
            if (r) |old| {
                hop = (try get(old.*, "redirect_hop")).integer + 1;
                if (field(p, "redirectResponse")) |response| {
                    try put(n.allocator, old, "response", try clone(n.allocator, response));
                    try put(n.allocator, old, "headers_ms", .{ .integer = now });
                    try put(n.allocator, old, "end_ms", .{ .integer = now });
                    try put(n.allocator, old, "state", str("finished"));
                    try put(n.allocator, old, "body_state", str("omitted_redirect"));
                    try put(n.allocator, old, "headers_complete", .{ .bool = true });
                }
            }
            if (n.records.array.items.len == 512) {
                n.dropped += 1;
                return;
            }
            const request = field(p, "request") orelse return error.CdpProtocol;
            var record = object();
            try put(n.allocator, &record, "session_id", str(try n.allocator.dupe(u8, session)));
            try put(n.allocator, &record, "request_id", str(try n.allocator.dupe(u8, id)));
            try put(n.allocator, &record, "redirect_hop", .{ .integer = hop });
            try put(n.allocator, &record, "url", try clone(n.allocator, field(request, "url") orelse .null));
            try put(n.allocator, &record, "method", try clone(n.allocator, field(request, "method") orelse .null));
            try put(n.allocator, &record, "start_ms", .{ .integer = now });
            try put(n.allocator, &record, "headers_ms", .null);
            try put(n.allocator, &record, "end_ms", .null);
            try put(n.allocator, &record, "state", str("pending"));
            try put(n.allocator, &record, "body_state", str("pending"));
            try put(n.allocator, &record, "headers_complete", .{ .bool = false });
            for ([_][]const u8{ "timestamp", "wallTime", "frameId", "loaderId", "type" }) |key| if (field(p, key)) |v| try put(n.allocator, &record, key, try clone(n.allocator, v));
            try n.records.array.append(record);
            return;
        }
        const record = r orelse return;
        if (std.mem.eql(u8, (try get(record.*, "body_state")).string, "omitted_redirect")) return;
        if (std.mem.eql(u8, method, "Network.responseReceived")) {
            try put(n.allocator, record, "headers_ms", .{ .integer = now });
            try put(n.allocator, record, "response", try clone(n.allocator, field(p, "response") orelse .null));
            try put(n.allocator, record, "headers_complete", .{ .bool = true });
        } else if (std.mem.eql(u8, method, "Network.loadingFinished")) {
            try put(n.allocator, record, "end_ms", .{ .integer = now });
            try put(n.allocator, record, "state", str("finished"));
            try put(n.allocator, record, "body_state", str("awaiting_retrieval"));
            if (field(p, "encodedDataLength")) |v| try put(n.allocator, record, "encoded_data_length", v);
        } else if (std.mem.eql(u8, method, "Network.loadingFailed")) {
            try put(n.allocator, record, "end_ms", .{ .integer = now });
            try put(n.allocator, record, "state", str("failed"));
            try put(n.allocator, record, "body_state", str("failed"));
            try put(n.allocator, record, "failure", try clone(n.allocator, field(p, "errorText") orelse str("loading_failed")));
        }
    }
};
test "native capture redirect identity distinguishes empty finished failed and pending requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var n = Network.init(a);
    const packets = [_][]const u8{ "{\"sessionId\":\"s\",\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"a\",\"request\":{\"url\":\"http://x/a\",\"method\":\"GET\"}}}", "{\"sessionId\":\"s\",\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"a\",\"redirectResponse\":{\"status\":302},\"request\":{\"url\":\"http://x/b\",\"method\":\"GET\"}}}", "{\"sessionId\":\"s\",\"method\":\"Network.responseReceived\",\"params\":{\"requestId\":\"a\",\"response\":{\"status\":204,\"headers\":{}}}}", "{\"sessionId\":\"s\",\"method\":\"Network.loadingFinished\",\"params\":{\"requestId\":\"a\",\"encodedDataLength\":0}}", "{\"sessionId\":\"s\",\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"b\",\"request\":{\"url\":\"http://x/fail\",\"method\":\"GET\"}}}", "{\"sessionId\":\"s\",\"method\":\"Network.loadingFailed\",\"params\":{\"requestId\":\"b\",\"errorText\":\"disconnected\"}}", "{\"sessionId\":\"s\",\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"c\",\"request\":{\"url\":\"http://x/pending\",\"method\":\"GET\"}}}" };
    for (packets, 0..) |bytes, i| {
        var p = try std.json.parseFromSlice(Value, a, bytes, .{});
        try n.event(p.value, @intCast(i));
        p.deinit();
    }
    try std.testing.expectEqual(@as(usize, 4), n.records.array.items.len);
    try std.testing.expectEqual(@as(i64, 0), (try get(n.records.array.items[0], "redirect_hop")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try get(n.records.array.items[1], "redirect_hop")).integer);
    try std.testing.expectEqualStrings("finished", try text(try get(n.records.array.items[1], "state")));
    try std.testing.expectEqualStrings("awaiting_retrieval", try text(try get(n.records.array.items[1], "body_state")));
    try std.testing.expectEqualStrings("failed", try text(try get(n.records.array.items[2], "state")));
    try std.testing.expectEqualStrings("pending", try text(try get(n.records.array.items[3], "state")));
}

pub const Timings = struct { connection_ms: i64 = 0, setup_ms: i64 = 0, navigation_ms: i64 = 0, action_ms: i64 = 0, wait_ms: i64 = 0, dom_ms: i64 = 0, screenshot_ms: i64 = 0, export_ms: i64 = 0, body_ms: i64 = 0, cleanup_ms: i64 = 0 };
pub const Engine = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    plan: Value,
    endpoint: []const u8,
    token: ?[]const u8,
    out: std.Io.Dir,
    deadline_ms: i64,
    socket: ws.Socket,
    cdp: cdp_mod.Client = undefined,
    cdp_initialized: bool = false,
    target: ?[]const u8 = null,
    create_sent: bool = false,
    network: Network,
    result: Value,
    timings: Timings = .{},
    stage: []const u8 = "connection",
    stage_started: i64 = 0,
    pub fn beginStage(e: *Engine, name: []const u8) void {
        e.stage = name;
        e.stage_started = e.now();
    }
    pub fn failureTiming(e: *Engine) void {
        const elapsed = e.now() - e.stage_started;
        if (std.mem.eql(u8, e.stage, "connection")) e.timings.connection_ms += elapsed else if (std.mem.eql(u8, e.stage, "setup")) e.timings.setup_ms += elapsed else if (std.mem.eql(u8, e.stage, "navigation")) e.timings.navigation_ms += elapsed else if (std.mem.eql(u8, e.stage, "action")) e.timings.action_ms += elapsed else if (std.mem.eql(u8, e.stage, "wait")) e.timings.wait_ms += elapsed else if (std.mem.eql(u8, e.stage, "dom")) e.timings.dom_ms += elapsed else if (std.mem.eql(u8, e.stage, "screenshot")) e.timings.screenshot_ms += elapsed;
    }
    pub fn now(e: *Engine) i64 {
        return std.Io.Clock.awake.now(e.io).toMilliseconds();
    }
    fn params(e: *Engine, values: anytype) !Value {
        var p = object();
        inline for (values) |pair| try put(e.allocator, &p, pair[0], pair[1]);
        return p;
    }
    fn command(e: *Engine, method: []const u8, p: Value, session: bool) !std.json.Parsed(Value) {
        return e.cdp.command(method, p, session);
    }
    fn ack(e: *Engine, method: []const u8, p: Value, session: bool) !void {
        var reply = try e.command(method, p, session);
        reply.deinit();
    }
    fn event(raw: *anyopaque, packet: Value) !void {
        const e: *Engine = @ptrCast(@alignCast(raw));
        const session = field(packet, "sessionId");
        if (session) |s| {
            if (e.cdp.session == null or s != .string or !std.mem.eql(u8, s.string, e.cdp.session.?)) return;
        }
        try e.network.event(packet, e.now());
    }
    pub fn run(e: *Engine) !void {
        var started = e.now();
        e.beginStage("connection");
        try e.socket.connect(e.endpoint, e.token);
        e.timings.connection_ms = e.now() - started;
        e.cdp = .{ .allocator = std.heap.c_allocator, .socket = &e.socket, .event_context = e, .event_fn = event };
        e.cdp_initialized = true;
        e.beginStage("setup");
        started = e.now();
        var version = try e.command("Browser.getVersion", object(), false);
        defer version.deinit();
        try put(e.allocator, &e.result, "browser", try clone(e.allocator, try get(version.value, "result")));
        e.create_sent = true;
        var created = try e.command("Target.createTarget", try e.params(.{.{ "url", str("about:blank") }}), false);
        defer created.deinit();
        e.target = try e.allocator.dupe(u8, try text(try get(try get(created.value, "result"), "targetId")));
        var attached = try e.command("Target.attachToTarget", try e.params(.{ .{ "targetId", str(e.target.?) }, .{ "flatten", Value{ .bool = true } } }), false);
        defer attached.deinit();
        e.cdp.session = try e.allocator.dupe(u8, try text(try get(try get(attached.value, "result"), "sessionId")));
        const vp = try get(e.result, "viewport");
        const ids = [_]i64{
            try e.cdp.send("Page.enable", object(), true),                                                                                                                                                                                                   try e.cdp.send("Runtime.enable", object(), true), try e.cdp.send("Network.enable", try e.params(.{ .{ "maxTotalBufferSize", Value{ .integer = 1048576 } }, .{ "maxResourceBufferSize", Value{ .integer = 65536 } } }), true),
            try e.cdp.send("Emulation.setDeviceMetricsOverride", try e.params(.{ .{ "width", try get(vp, "width") }, .{ "height", try get(vp, "height") }, .{ "deviceScaleFactor", Value{ .integer = 1 } }, .{ "mobile", Value{ .bool = false } } }), true),
        };
        for (ids) |id| {
            var reply = try e.cdp.awaitReply(id);
            reply.deinit();
        }
        e.timings.setup_ms = e.now() - started;
        e.beginStage("navigation");
        started = e.now();
        var nav = try e.command("Page.navigate", try e.params(.{.{ "url", try get(e.plan, "url") }}), true);
        defer nav.deinit();
        const navigation = try get(nav.value, "result");
        try put(e.allocator, &e.result, "navigation", try clone(e.allocator, navigation));
        if (field(navigation, "errorText")) |error_text| {
            if (error_text == .string and error_text.string.len > 0) return error.NavigationFailed;
        }
        e.timings.navigation_ms = e.now() - started;
        const checkpoints = (try get(e.plan, "checkpoints")).array.items;
        for (checkpoints) |cp| {
            var receipt = object();
            try put(e.allocator, &receipt, "id", try get(cp, "id"));
            try put(e.allocator, &receipt, "start_ms", .{ .integer = e.now() });
            try put(e.allocator, &receipt, "result", .null);
            try put(e.allocator, &receipt, "screenshot", .null);
            var receipts = &e.result.object.getPtr("checkpoints").?.array;
            try receipts.append(receipt);
            // The result object map can grow when evaluation exceptions are
            // recorded. Keep the separately allocated array item, not a pointer
            // into the map's array-list descriptor, across command processing.
            const checkpoint_receipt = &receipts.items[receipts.items.len - 1];
            e.checkpoint(cp, checkpoint_receipt) catch |err| {
                try put(e.allocator, checkpoint_receipt, "error", str(@errorName(err)));
                try put(e.allocator, checkpoint_receipt, "end_ms", .{ .integer = e.now() });
                return err;
            };
            try put(e.allocator, checkpoint_receipt, "end_ms", .{ .integer = e.now() });
            try e.bodies();
        }
        // A final round trip drains events already emitted after the last capture.
        try e.ack("Runtime.evaluate", try e.params(.{ .{ "expression", str("true") }, .{ "returnByValue", Value{ .bool = true } } }), true);
        try e.bodies();
    }
    fn evaluate(e: *Engine, expression: []const u8, return_value: bool) !Value {
        var reply = try e.command("Runtime.evaluate", try e.params(.{ .{ "expression", str(expression) }, .{ "awaitPromise", Value{ .bool = true } }, .{ "returnByValue", Value{ .bool = return_value } } }), true);
        defer reply.deinit();
        const r = try get(reply.value, "result");
        if (field(r, "exceptionDetails")) |details| {
            try put(e.allocator, &e.result, "evaluation_exception", try clone(e.allocator, details));
            return error.PageEvaluation;
        }
        if (!return_value) return .null;
        const remote = try get(r, "result");
        if (field(remote, "value")) |v| return clone(e.allocator, v);
        return error.EvaluationNotJson;
    }
    fn checkpoint(e: *Engine, cp: Value, receipt: *Value) !void {
        if (field(cp, "action")) |a| {
            e.beginStage("action");
            const t = e.now();
            _ = try e.evaluate(try text(a), false);
            const elapsed = e.now() - t;
            e.timings.action_ms += elapsed;
            try put(e.allocator, receipt, "action_ms", .{ .integer = elapsed });
            try put(e.allocator, receipt, "action_kind", str("page_evaluation"));
        }
        if (field(cp, "wait")) |w| {
            e.beginStage("wait");
            const t = e.now();
            const expression = try text(w);
            const immediate = try e.evaluate(expression, true);
            if (immediate != .bool) return error.PredicateNotBoolean;
            if (!immediate.bool) {
                const remaining = @max(@as(i64, 1), e.deadline_ms - e.now());
                const wrapped = try std.fmt.allocPrint(e.allocator, "new Promise((resolve,reject)=>{{let done=false,raf,timer,observer;const finish=(ok,err)=>{{if(done)return;done=true;cancelAnimationFrame(raf);clearTimeout(timer);observer.disconnect();err?reject(err):resolve(ok)}};const check=()=>{{try{{const value=({s});if(typeof value!=='boolean')throw new Error('fh predicate must be boolean');if(value)finish(true);}}catch(err){{finish(false,err)}}}};const tick=()=>{{check();if(!done)raf=requestAnimationFrame(tick)}};observer=new MutationObserver(check);observer.observe(document,{{subtree:true,childList:true,attributes:true,characterData:true}});timer=setTimeout(()=>finish(false),{d});tick();}})", .{ expression, remaining });
                const value = try e.evaluate(wrapped, true);
                if (value != .bool or !value.bool) return error.PredicateTimeout;
            }
            const elapsed = e.now() - t;
            e.timings.wait_ms += elapsed;
            try put(e.allocator, receipt, "wait_ms", .{ .integer = elapsed });
        }
        if (field(cp, "evaluate")) |x| {
            e.beginStage("dom");
            const t = e.now();
            const value = try e.evaluate(try text(x), true);
            try put(e.allocator, receipt, "result", value);
            const elapsed = e.now() - t;
            e.timings.dom_ms += elapsed;
            try put(e.allocator, receipt, "dom_ms", .{ .integer = elapsed });
        }
        if (field(cp, "screenshot")) |s| if (s.bool) {
            e.beginStage("screenshot");
            const t = e.now();
            e.screenshot(cp, receipt) catch |err| {
                try put(e.allocator, receipt, "screenshot_error", str(@errorName(err)));
                return err;
            };
            const elapsed = e.now() - t;
            e.timings.screenshot_ms += elapsed;
            try put(e.allocator, receipt, "screenshot_ms", .{ .integer = elapsed });
        };
    }
    fn screenshot(e: *Engine, cp: Value, receipt: *Value) !void {
        var reply = try e.command("Page.captureScreenshot", try e.params(.{.{ "format", str("png") }}), true);
        defer reply.deinit();
        const encoded = try text(try get(try get(reply.value, "result"), "data"));
        const len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidScreenshot;
        if (len > 8 * 1024 * 1024) return error.ScreenshotLimit;
        const bytes = try std.heap.c_allocator.alloc(u8, len);
        defer std.heap.c_allocator.free(bytes);
        std.base64.standard.Decoder.decode(bytes, encoded) catch return error.InvalidScreenshot;
        try validatePng(bytes);
        const filename = try std.fmt.allocPrint(e.allocator, "{s}.png", .{try text(try get(cp, "id"))});
        const t = e.now();
        try writePrivate(e.out, e.io, filename, bytes);
        e.timings.export_ms += e.now() - t;
        try put(e.allocator, receipt, "screenshot", str(filename));
    }
    fn bodies(e: *Engine) !void {
        e.beginStage("bodies");
        const start = e.now();
        defer e.timings.body_ms += e.now() - start;
        var i: usize = 0;
        while (i < e.network.records.array.items.len) : (i += 1) {
            // Events can append while awaiting, so never retain pointers across commands.
            const r = e.network.records.array.items[i];
            if (!std.mem.eql(u8, try text(try get(r, "body_state")), "awaiting_retrieval")) continue;
            if (e.network.bodies_bytes == 1048576) {
                try put(e.allocator, &e.network.records.array.items[i], "body_state", str("omitted_total_limit"));
                continue;
            }
            var reply = e.command("Network.getResponseBody", try e.params(.{.{ "requestId", try get(r, "request_id") }}), true) catch |err| {
                try put(e.allocator, &e.network.records.array.items[i], "body_state", str("retrieval_failed"));
                try put(e.allocator, &e.network.records.array.items[i], "body_error", str(@errorName(err)));
                if (err == error.CdpCommand) if (e.cdp.last_error) |detail| try put(e.allocator, &e.network.records.array.items[i], "body_command_error", str(try e.allocator.dupe(u8, detail)));
                if (err != error.CdpCommand) return err;
                continue;
            };
            defer reply.deinit();
            const result = try get(reply.value, "result");
            const raw = try text(try get(result, "body"));
            var decoded: []const u8 = raw;
            var owned: ?[]u8 = null;
            defer if (owned) |b| std.heap.c_allocator.free(b);
            const base64 = try get(result, "base64Encoded");
            if (base64 != .bool) return error.CdpProtocol;
            if (base64.bool) {
                const len = std.base64.standard.Decoder.calcSizeForSlice(raw) catch return error.CdpProtocol;
                owned = try std.heap.c_allocator.alloc(u8, len);
                std.base64.standard.Decoder.decode(owned.?, raw) catch return error.CdpProtocol;
                decoded = owned.?;
            }
            const cap = @min(@as(usize, 65536), 1048576 - e.network.bodies_bytes);
            const retained = decoded[0..@min(decoded.len, cap)];
            const record = &e.network.records.array.items[i];
            try put(e.allocator, record, "body_bytes", .{ .integer = @intCast(decoded.len) });
            if (!std.unicode.utf8ValidateSlice(retained)) {
                const len = std.base64.standard.Encoder.calcSize(retained.len);
                const encoded = try e.allocator.alloc(u8, len);
                _ = std.base64.standard.Encoder.encode(encoded, retained);
                try put(e.allocator, record, "body", str(encoded));
                try put(e.allocator, record, "body_encoding", str("base64"));
            } else {
                try put(e.allocator, record, "body", str(try e.allocator.dupe(u8, retained)));
                try put(e.allocator, record, "body_encoding", str("utf8"));
            }
            e.network.bodies_bytes += retained.len;
            try put(e.allocator, record, "body_state", str(if (retained.len < decoded.len) "truncated" else "retrieved"));
            try put(e.allocator, record, "body_retrieved_ms", .{ .integer = e.now() });
            try put(e.allocator, record, "body_scope", str("browser_decoded"));
        }
    }
    pub fn cleanup(e: *Engine) !void {
        if (e.target) |target| {
            if (!e.cdp_initialized) return error.CleanupUnavailable;
            var reply = try e.command("Target.closeTarget", try e.params(.{.{ "targetId", str(target) }}), false);
            defer reply.deinit();
            const success = field(try get(reply.value, "result"), "success") orelse return error.CdpProtocol;
            if (success != .bool) return error.CdpProtocol;
            if (!success.bool) return error.TargetCleanupRejected;
            try put(e.allocator, &e.result, "target_cleanup", str("closed"));
        } else try put(e.allocator, &e.result, "target_cleanup", str(if (e.create_sent) "unknown_target_creation" else "no_target_created"));
    }
    pub fn deinit(e: *Engine) void {
        if (e.cdp_initialized) e.cdp.deinit();
        e.socket.deinit();
    }
};
pub fn writePrivate(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8) !void {
    var f = try dir.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}
pub fn validatePng(bytes: []const u8) !void {
    if (bytes.len < 33 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidScreenshot;
    var offset: usize = 8;
    var first = true;
    var data = false;
    while (offset < bytes.len) {
        if (bytes.len - offset < 12) return error.InvalidScreenshot;
        const n = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (n > bytes.len - offset - 12) return error.InvalidScreenshot;
        const kind = bytes[offset + 4 ..][0..4];
        const payload = bytes[offset + 8 ..][0..n];
        const crc = std.mem.readInt(u32, bytes[offset + 8 + n ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[offset + 4 ..][0 .. n + 4]) != crc) return error.InvalidScreenshot;
        if (first) {
            if (!std.mem.eql(u8, kind, "IHDR") or n != 13) return error.InvalidScreenshot;
            const w = std.mem.readInt(u32, payload[0..4], .big);
            const h = std.mem.readInt(u32, payload[4..8], .big);
            if (w == 0 or h == 0 or @as(u64, w) * h > 8388608) return error.InvalidScreenshot;
            first = false;
        }
        if (std.mem.eql(u8, kind, "IDAT")) data = true;
        offset += n + 12;
        if (std.mem.eql(u8, kind, "IEND")) {
            if (n != 0 or offset != bytes.len or !data) return error.InvalidScreenshot;
            return;
        }
    }
    return error.InvalidScreenshot;
}

test "native capture plan limits and endpoint fragments fail before execution" {
    const bad = [_][]const u8{ "{\"version\":\"fh.capture/0.1\",\"url\":\"https://example.com\",\"timeout_ms\":0,\"checkpoints\":[{\"id\":\"x\"}]}", "{\"version\":\"fh.capture/0.1\",\"url\":\"https://example.com\",\"viewport\":{\"width\":4096,\"height\":4096},\"checkpoints\":[{\"id\":\"x\"}]}", "{\"version\":\"fh.capture/0.1\",\"url\":\"https://example.com\",\"checkpoints\":[{\"id\":\"x\",\"screenshot\":1}]}", "{\"version\":\"fh.capture/0.1\",\"url\":\"https://example.com\",\"checkpoints\":[{\"id\":\"x\",\"wait\":\"\"}]}", "{\"version\":\"fh.capture/0.1\",\"url\":\"https://example.com\",\"sources\":[\"x\",\"x\"],\"checkpoints\":[{\"id\":\"x\"}]}" };
    for (bad) |bytes| {
        var p = try std.json.parseFromSlice(Value, std.testing.allocator, bytes, .{});
        defer p.deinit();
        try std.testing.expectError(error.InvalidPlan, validatePlan(p.value));
    }
    try std.testing.expectError(error.InvalidEndpoint, ws.validateEndpoint("ws://localhost/#fragment"));
    try std.testing.expectError(error.InvalidEndpoint, ws.validateEndpoint("wss://user:secret@localhost/"));
    try std.testing.expectError(error.InvalidEndpoint, ws.validateEndpoint("http://localhost/"));
    _ = try ws.validateEndpoint("wss://localhost/path?browser=kitesurf");
}

test "native capture evidence cap marks omitted events and never rewrites redirect record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var n = Network.init(a);
    var packet = try std.json.parseFromSlice(Value, a, "{\"sessionId\":\"s\",\"method\":\"Network.requestWillBeSent\",\"params\":{\"requestId\":\"a\",\"request\":{\"url\":\"http://x\",\"method\":\"GET\"}}}", .{});
    defer packet.deinit();
    try n.event(packet.value, 1);
    n.events_bytes = 4 * 1048576;
    try n.event(packet.value, 2);
    try std.testing.expectEqual(@as(usize, 1), n.events_omitted);
    try std.testing.expectEqual(@as(usize, 1), n.records.array.items.len);
    try std.testing.expectEqualStrings("pending", (try get(n.records.array.items[0], "state")).string);
    try std.testing.expectEqual(@as(i64, 1), (try get(n.records.array.items[0], "start_ms")).integer);
}
