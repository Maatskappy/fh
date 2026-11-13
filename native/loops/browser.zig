//! Run-owned local browser. CDP is never package data or a model-discovered endpoint.
const std = @import("std");
const runner = @import("runner.zig");
const schema = @import("schema.zig");
const bindings = @import("bindings.zig");
const ws = @import("../capture/websocket.zig");
const cdp = @import("../capture/cdp.zig");
const capture = @import("../capture/capture.zig");
const command = @import("../../vendor/fx/src/core/execution/command_runner.zig");
const io_mod = @import("../../vendor/fx/src/core/shared/io.zig");
const Value = runner.Value;
const str = capture.str;
const put = capture.put;
const object = capture.object;
pub const Authority = struct { context: *anyopaque, checkFn: *const fn (*anyopaque) anyerror!void };
pub fn installedPath(a: std.mem.Allocator) ![]const u8 {
    const home = io_mod.getenv("HOME") orelse return error.BrowserSetupRequired;
    return std.fmt.allocPrint(a, "{s}/.local/share/fh/browsers/moli-1.1.13/moli", .{home});
}
pub fn validateBinary(io: std.Io, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidBrowserConfiguration;
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return error.BrowserSetupRequired;
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o111 == 0) return error.BrowserSetupRequired;
}
pub fn configuredPath(a: std.mem.Allocator, io: std.Io, binding: *bindings.Binding) ![]const u8 {
    const grant = try runner.get(try runner.get(binding.registered, "capabilities"), "browser");
    if (grant != .string) return error.InvalidBrowserConfiguration;
    const resource = try runner.get(try runner.get(binding.configuration, "resources"), grant.string);
    if (!std.mem.eql(u8, try runner.text(try runner.get(resource, "kind")), "browser") or !std.mem.eql(u8, try runner.text(try runner.get(resource, "adapter")), "moli-cdp/1")) return error.InvalidBrowserConfiguration;
    const path = if (resource.object.get("binary")) |p| try a.dupe(u8, try runner.text(p)) else try installedPath(a);
    try validateBinary(io, path);
    return path;
}
pub fn required(definition: Value) bool {
    const requires = if (definition == .object) definition.object.get("requires") orelse return false else return false;
    if (requires != .array) return false;
    for (requires.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, "browser")) return true;
    return false;
}
const observation_js =
    \\JSON.stringify((()=>{const all=[...document.querySelectorAll('a[href],button,input,textarea,select,[role="button"],[tabindex]')];const visible=e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&getComputedStyle(e).visibility!=='hidden'};return {source:'dom',render_freshness:'not_established',url:location.href,title:document.title,text:(()=>{let t='';const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let n,count=0;while((n=w.nextNode())&&count++<2000&&t.length<16000){let e=n.parentElement,hidden=false;for(let p=e;p;p=p.parentElement){const s=getComputedStyle(p);if(/^(SCRIPT|STYLE|NOSCRIPT)$/.test(p.tagName)||s.display==='none'||s.visibility==='hidden'){hidden=true;break}}if(!hidden)t+=n.textContent+' '}return t.slice(0,16000)})(),focus:{tag:document.activeElement?.tagName,id:document.activeElement?.id},elements:all.map((e,i)=>{const r=e.getBoundingClientRect();return {handle:i,tag:e.tagName,id:e.id,label:(e.getAttribute('aria-label')||e.innerText||e.getAttribute('placeholder')||'').slice(0,200),value:typeof e.value==='string'?e.value.slice(0,1000):null,checked:typeof e.checked==='boolean'?e.checked:null,disabled:!!e.disabled,focused:e===document.activeElement,x:r.x+r.width/2,y:r.y+r.height/2,visible:visible(e)}}).filter(e=>e.visible).slice(0,100)}})())
;
pub const Resource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    binary: []const u8,
    authority: Authority,
    evidence_dir: std.Io.Dir,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    process_error: ?anyerror = null,
    command_line: []const u8 = "",
    deadline_ms: i64 = 0,
    socket: ?ws.Socket = null,
    client: ?cdp.Client = null,
    target: ?[]const u8 = null,
    endpoint: []const u8 = "",
    observation: Value = .null,
    observation_arena: ?std.heap.ArenaAllocator = null,
    sequence: u64 = 0,
    launched: bool = false,
    ready: bool = false,
    cleanup_complete: bool = false,
    evidence_bytes: usize = 0,
    startup_ms: ?i64 = null,
    timings: std.ArrayList(Timing) = .empty,
    pub const Timing = struct { sequence: u64, operation_ms: i64 };
    fn now(self: *Resource) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }
    fn check(self: *Resource, request: runner.StepRequest) !void {
        if (request.cancel.load(.acquire)) return error.Cancelled;
        if (self.now() >= request.deadline_ms) return error.TimeLimit;
        try self.authority.checkFn(self.authority.context);
        if (self.launched and self.done.load(.acquire)) return self.process_error orelse error.BrowserExited;
    }
    fn process(self: *Resource) void {
        defer self.done.store(true, .release);
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const result = command.executeCommandInEnvironment(.{ .max_command_output_bytes = 4096, .cancel_flag = &self.stop, .timeout_ms = @intCast(@max(1, self.deadline_ms - self.now())) }, arena.allocator(), self.command_line, "/", .{ .clean = "/bin/bash" }) catch |err| {
            self.process_error = err;
            return;
        };
        if (result.command_result) |r| if (r.termination_indeterminate) {
            self.process_error = error.CleanupPending;
        };
    }
    pub fn deinit(self: *Resource) void {
        self.cleanup() catch {};
        if (self.observation_arena) |*a| a.deinit();
        self.timings.deinit(self.allocator);
        if (self.target) |s| self.allocator.free(s);
        if (self.command_line.len != 0) self.allocator.free(self.command_line);
        if (self.endpoint.len != 0) self.allocator.free(self.endpoint);
    }
    pub fn cleanup(self: *Resource) !void {
        if (self.cleanup_complete) return;
        // The supervisor terminates the complete owned tree and reaps Moli;
        // closing CDP plus process death also closes every owned target.
        self.stop.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.client) |*c| {
            c.deinit();
            self.client = null;
        }
        if (self.socket) |*s| {
            s.deinit();
            self.socket = null;
        }
        if (self.process_error) |err| if (err == error.CleanupPending) return err;
        self.cleanup_complete = true;
    }
    fn start(self: *Resource, request: runner.StepRequest) !void {
        if (self.client != null) return;
        try self.check(request);
        const started = self.now();
        if (self.launched) return error.BrowserExited; // Never replay uncertain setup.
        try validateBinary(self.io, self.binary);
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var reservation = try address.listen(self.io, .{ .reuse_address = false });
        const port = reservation.socket.address.getPort();
        reservation.deinit(self.io);
        const quoted = try std.mem.replaceOwned(u8, self.allocator, self.binary, "'", "'\\''");
        defer self.allocator.free(quoted);
        self.command_line = try std.fmt.allocPrint(self.allocator, "exec '{s}' serve --host 127.0.0.1 --layout --resource --port {d}", .{ quoted, port });
        self.endpoint = try std.fmt.allocPrint(self.allocator, "ws://127.0.0.1:{d}/devtools/browser/moli-browser", .{port});
        self.deadline_ms = request.deadline_ms;
        try request.journal.record(.{ .id = "browser-process", .kind = "browser_process", .state = .unknown });
        self.launched = true;
        self.thread = try std.Thread.spawn(.{}, process, .{self});
        // Discovery is the successful native WebSocket upgrade followed by CDP,
        // never a fixed startup sleep or model request. Every failed socket closes.
        while (true) {
            try self.check(request);
            self.socket = ws.Socket.init(self.allocator, self.io);
            self.socket.?.connect(self.endpoint, null) catch {
                self.socket.?.deinit();
                self.socket = null;
                try std.Io.sleep(self.io, .fromMilliseconds(5), .awake);
                continue;
            };
            break;
        }
        self.client = .{ .allocator = self.allocator, .socket = &self.socket.? };
        _ = try self.cmd(self.allocator, "Browser.getVersion", object(), false);
        const created = try self.cmd(self.allocator, "Target.createTarget", try params(self.allocator, .{.{ "url", str("about:blank") }}), false);
        self.target = try self.allocator.dupe(u8, try runner.text(try runner.get(created, "targetId")));
        const attached = try self.cmd(self.allocator, "Target.attachToTarget", try params(self.allocator, .{ .{ "targetId", str(self.target.?) }, .{ "flatten", Value{ .bool = true } } }), false);
        self.client.?.session = try self.allocator.dupe(u8, try runner.text(try runner.get(attached, "sessionId")));
        for ([_][]const u8{ "Page.enable", "Runtime.enable" }) |method| _ = try self.cmd(self.allocator, method, object(), true);
        _ = try self.cmd(self.allocator, "Emulation.setDeviceMetricsOverride", try params(self.allocator, .{ .{ "width", Value{ .integer = 800 } }, .{ "height", Value{ .integer = 600 } }, .{ "deviceScaleFactor", Value{ .integer = 1 } }, .{ "mobile", Value{ .bool = false } } }), true);
        self.ready = true;
        self.startup_ms = self.now() - started;
        try request.journal.record(.{ .id = "browser-process", .kind = "browser_process", .state = .applied });
    }
    fn cmd(self: *Resource, a: std.mem.Allocator, method: []const u8, p: Value, session: bool) !Value {
        var reply = try self.client.?.command(method, p, session);
        defer reply.deinit();
        const bytes = try std.json.Stringify.valueAlloc(a, try runner.get(reply.value, "result"), .{});
        defer a.free(bytes);
        return schema.parse(a, bytes);
    }
    fn evaluate(self: *Resource, a: std.mem.Allocator, expression: []const u8) !Value {
        const reply = try self.cmd(a, "Runtime.evaluate", try params(a, .{ .{ "expression", str(expression) }, .{ "returnByValue", Value{ .bool = true } }, .{ "awaitPromise", Value{ .bool = true } } }), true);
        if (reply.object.contains("exceptionDetails")) return error.BrowserEvaluationFailed;
        return runner.get(try runner.get(reply, "result"), "value");
    }
    fn observe(self: *Resource, a: std.mem.Allocator) !Value {
        const result = try self.evaluate(a, observation_js);
        const bytes = try runner.text(result);
        if (bytes.len > 65536) return error.OutputLimit;
        if (self.observation_arena) |*old| old.deinit();
        self.observation_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.observation = try schema.parse(self.observation_arena.?.allocator(), bytes);
        return schema.parse(a, bytes);
    }
    fn element(value: Value, handle: i64) !Value {
        for ((try runner.get(value, "elements")).array.items) |e| if ((try runner.get(e, "handle")).integer == handle) return e;
        return error.StaleBrowserElement;
    }
    fn activate(self: *Resource, a: std.mem.Allocator, handle: i64) !void {
        if (self.observation == .null) return error.BrowserObservationRequired;
        const previous = try element(self.observation, handle);
        const previous_bytes = try std.json.Stringify.valueAlloc(a, previous, .{});
        const previous_url = try a.dupe(u8, try runner.text(try runner.get(self.observation, "url")));
        const fresh = try self.observe(a);
        const e = try element(fresh, handle);
        const current_bytes = try std.json.Stringify.valueAlloc(a, e, .{});
        if (!std.mem.eql(u8, previous_bytes, current_bytes) or !std.mem.eql(u8, previous_url, try runner.text(try runner.get(fresh, "url")))) return error.StaleBrowserElement;
        if ((try runner.get(e, "disabled")).bool) return error.BrowserElementDisabled;
        const x = try runner.get(e, "x");
        const y = try runner.get(e, "y");
        const hit = try self.evaluate(a, try std.fmt.allocPrint(a, "(()=>{{const e=document.querySelectorAll('a[href],button,input,textarea,select,[role=\"button\"],[tabindex]')[{d}];const r=e.getBoundingClientRect();const hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);return hit===e||e.contains(hit)}})()", .{handle}));
        if (hit != .bool or !hit.bool) return error.BrowserElementObscured;
        for ([_][]const u8{ "mousePressed", "mouseReleased" }) |kind| _ = try self.cmd(a, "Input.dispatchMouseEvent", try params(a, .{ .{ "type", str(kind) }, .{ "x", x }, .{ "y", y }, .{ "button", str("left") }, .{ "clickCount", Value{ .integer = 1 } } }), true);
    }
    fn key(self: *Resource, a: std.mem.Allocator, name: []const u8) !void {
        const shift = std.mem.eql(u8, name, "Shift+Tab");
        const key_name = if (shift) "Tab" else if (std.mem.eql(u8, name, "Space")) " " else name;
        const code_name = if (shift) "Tab" else name;
        const number: i64 = if (std.mem.eql(u8, code_name, "Tab")) 9 else if (std.mem.eql(u8, name, "Enter")) 13 else if (std.mem.eql(u8, name, "Space")) 32 else if (std.mem.eql(u8, name, "Escape")) 27 else return error.UnsupportedBrowserKey;
        for ([_][]const u8{ "keyDown", "keyUp" }, 0..) |kind, index| {
            var p = try params(a, .{ .{ "type", str(kind) }, .{ "key", str(key_name) }, .{ "code", str(code_name) }, .{ "windowsVirtualKeyCode", Value{ .integer = number } }, .{ "nativeVirtualKeyCode", Value{ .integer = number } }, .{ "modifiers", Value{ .integer = if (shift) 8 else 0 } } });
            if (index == 0 and (number == 13 or number == 32)) {
                try put(a, &p, "text", str(if (number == 13) "\r" else " "));
                try put(a, &p, "unmodifiedText", str(if (number == 13) "\r" else " "));
            }
            _ = try self.cmd(a, "Input.dispatchKeyEvent", p, true);
        }
    }
    fn perform(self: *Resource, a: std.mem.Allocator, request: runner.StepRequest, operation: Value) !Value {
        try self.check(request);
        const action = try validateOperation(operation);
        try self.start(request);
        try self.check(request);
        const operation_started = self.now();
        self.sequence += 1;
        const id = try std.fmt.allocPrint(a, "browser-{d}", .{self.sequence});
        const artifact_name = if (std.mem.eql(u8, action, "capture")) try std.fmt.allocPrint(a, "{s}-browser-{d}.png", .{ request.run_id, self.sequence }) else null;
        var receipt_details = try params(a, .{.{ "action", str(action) }});
        if (artifact_name) |name| try put(a, &receipt_details, "file", str(name));
        try request.journal.record(.{ .id = id, .kind = "browser_operation", .state = .unknown, .details = receipt_details });
        if (std.mem.eql(u8, action, "navigate")) {
            const url = try runner.text(try runner.get(operation, "url"));
            const navigation = try self.cmd(a, "Page.navigate", try params(a, .{.{ "url", str(url) }}), true);
            if (navigation.object.get("errorText")) |failure| {
                if ((try runner.text(failure)).len != 0) return error.NavigationFailed;
            }
            if (navigation.object.get("isDownload")) |download| {
                if (download == .bool and download.bool) return error.NavigationFailed;
            }
            const frame_id = try runner.text(try runner.get(navigation, "frameId"));
            const loader = navigation.object.get("loaderId");
            // A complete old document is not evidence for the accepted navigation.
            // Cross-document loads are correlated by CDP frame/loader identity;
            // same-document loads omit loaderId and must reach the requested URL.
            const ready_expression = if (loader != null) "document.readyState==='complete'" else try std.fmt.allocPrint(a, "document.readyState==='complete'&&location.href===new URL({s}).href", .{try std.json.Stringify.valueAlloc(a, url, .{})});
            while (true) {
                try self.check(request);
                const tree = try self.cmd(a, "Page.getFrameTree", object(), true);
                const frame = try runner.get(try runner.get(tree, "frameTree"), "frame");
                const matches = std.mem.eql(u8, frame_id, try runner.text(try runner.get(frame, "id"))) and (if (loader) |expected| std.mem.eql(u8, try runner.text(expected), try runner.text(try runner.get(frame, "loaderId"))) else true);
                if (matches) {
                    const ready = try self.evaluate(a, ready_expression);
                    if (ready == .bool and ready.bool) break;
                }
                try std.Io.sleep(self.io, .fromMilliseconds(5), .awake);
            }
        } else if (std.mem.eql(u8, action, "activate")) {
            try self.activate(a, (try runner.get(operation, "handle")).integer);
        } else if (std.mem.eql(u8, action, "type")) {
            const focused = try self.evaluate(a, "(()=>{const e=document.activeElement;return !!e&&!e.disabled&&!e.readOnly&&(e.tagName==='TEXTAREA'||(e.tagName==='INPUT'&&['text','search','url','email','tel','password','number'].includes(e.type)))})()");
            if (focused != .bool or !focused.bool) return error.BrowserInputFocusRequired;
            _ = try self.cmd(a, "Input.insertText", try params(a, .{.{ "text", try runner.get(operation, "text") }}), true);
        } else if (std.mem.eql(u8, action, "key")) {
            try self.key(a, try runner.text(try runner.get(operation, "key")));
        }
        var result = try self.observe(a);
        if (std.mem.eql(u8, action, "capture")) {
            const reply = try self.cmd(a, "Page.captureScreenshot", try params(a, .{.{ "format", str("png") }}), true);
            const encoded = try runner.text(try runner.get(reply, "data"));
            const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
            if (size > 8 * 1048576 or size > 16 * 1048576 - self.evidence_bytes) return error.OutputLimit;
            const png = try a.alloc(u8, size);
            try std.base64.standard.Decoder.decode(png, encoded);
            if (png.len < 24 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return error.InvalidBrowserCapture;
            const name = artifact_name.?;
            var file = try self.evidence_dir.createFile(self.io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, png);
            self.evidence_bytes += size;
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(png, &hash, .{});
            try put(a, &result, "capture", try params(a, .{ .{ "file", str(name) }, .{ "sha256", str(try a.dupe(u8, &std.fmt.bytesToHex(hash, .lower))) }, .{ "bytes", Value{ .integer = @intCast(size) } } }));
        }
        try put(a, &result, "operation_ms", .{ .integer = self.now() - operation_started });
        if (self.sequence == 1) try put(a, &result, "cold_start_ms", .{ .integer = self.startup_ms orelse 0 });
        try request.journal.record(.{ .id = id, .kind = "browser_operation", .state = .applied });
        // Bound retained measurements by the existing receipt capacity. The
        // final cleanup receipt persists them once, without extra action writes.
        if (self.timings.items.len >= 1024) return error.HistoryLimit;
        try self.timings.append(self.allocator, .{ .sequence = self.sequence, .operation_ms = (try runner.get(result, "operation_ms")).integer });
        return result;
    }
    const Work = struct {
        resource: *Resource,
        allocator: std.mem.Allocator,
        request: runner.StepRequest,
        operation: Value,
        done: std.atomic.Value(bool) = .init(false),
        fn run(w: *@This()) anyerror!Value {
            defer w.done.store(true, .release);
            return w.resource.perform(w.allocator, w.request, w.operation);
        }
    };
    pub fn call(raw: *anyopaque, a: std.mem.Allocator, request: runner.StepRequest, operation: Value) !Value {
        const self: *Resource = @ptrCast(@alignCast(raw));
        var work: Work = .{ .resource = self, .allocator = a, .request = request, .operation = operation };
        var future = try self.io.concurrent(Work.run, .{&work});
        while (!work.done.load(.acquire)) {
            if (request.cancel.load(.acquire) or self.now() >= request.deadline_ms) {
                _ = future.cancel(self.io) catch {};
                return if (request.cancel.load(.acquire)) error.Cancelled else error.TimeLimit;
            }
            try std.Io.sleep(self.io, .fromMilliseconds(5), .awake);
        }
        return future.await(self.io);
    }
};
fn params(a: std.mem.Allocator, fields: anytype) !Value {
    var v = object();
    inline for (fields) |pair| try put(a, &v, pair[0], pair[1]);
    return v;
}
pub fn validateOperation(v: Value) ![]const u8 {
    if (v != .object) return error.InvalidBrowserOperation;
    const action = try runner.text(try runner.get(v, "action"));
    const argument: ?[]const u8 = if (std.mem.eql(u8, action, "navigate")) "url" else if (std.mem.eql(u8, action, "activate")) "handle" else if (std.mem.eql(u8, action, "type")) "text" else if (std.mem.eql(u8, action, "key")) "key" else if (std.mem.eql(u8, action, "observe") or std.mem.eql(u8, action, "capture")) null else return error.InvalidBrowserOperation;
    if (v.object.count() != (if (argument != null) @as(usize, 2) else 1)) return error.InvalidBrowserOperation;
    if (argument) |arg| {
        const value = try runner.get(v, arg);
        if (std.mem.eql(u8, arg, "handle")) {
            if (value != .integer or value.integer < 0 or value.integer > 100000) return error.InvalidBrowserOperation;
        } else {
            const bytes = try runner.text(value);
            if (bytes.len > 8192) return error.InvalidBrowserOperation;
            if (std.mem.eql(u8, arg, "url")) try capture.validateUrl(bytes);
            if (std.mem.eql(u8, arg, "key")) {
                for ([_][]const u8{ "Tab", "Shift+Tab", "Enter", "Space", "Escape" }) |key_name| if (std.mem.eql(u8, bytes, key_name)) return action;
                return error.UnsupportedBrowserKey;
            }
        }
    }
    return action;
}
test "native browser rejects unsupported actions and synthetic input before launch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "{\"action\":\"evaluate\"}", "{\"action\":\"navigate\",\"url\":\"file:///etc/passwd\"}", "{\"action\":\"key\",\"key\":\"F12\"}" }) |bytes| {
        const v = try schema.parse(arena.allocator(), bytes);
        if (validateOperation(v)) |_| return error.TestExpectedError else |_| {}
    }
}
