//! Owned in-process Loop thread. fx remains the sole terminal renderer.
const std = @import("std");
const io_mod = @import("../vendor/fx/src/core/shared/io.zig");
const decision = @import("loops/decision.zig");
const infer = @import("../vendor/fx/src/fh_loop_infer.zig");
const workspace_agent = @import("loops/workspace_agent.zig");
const self_exe = @import("../vendor/fx/src/core/shared/self_exe.zig");
pub const engine = @import("loops/engine.zig");
pub const events = @import("loops_events.zig");
const alloc = std.heap.c_allocator;
/// The bundled file behind each document name the chat docs_read tool advertises. A name
/// outside this list reads nothing: the model never supplies a path.
pub fn documentPath(document: []const u8) ?[]const u8 {
    const eql = std.mem.eql;
    return if (eql(u8, document, "guide")) "docs/loops.md" else if (eql(u8, document, "workspace_guide")) "docs/workspace-loops.md" else if (eql(u8, document, "schema")) "lib/packages/loops-contract/loop-0.1.schema.json" else if (eql(u8, document, "decision_schema")) "lib/packages/loops-contract/loop-0.2.schema.json" else if (eql(u8, document, "parallel_schema")) "lib/packages/loops-contract/loop-0.3.schema.json" else if (eql(u8, document, "runtime_schema")) "lib/packages/loops-contract/loop-0.4.schema.json" else if (eql(u8, document, "runtime_contract")) "docs/contracts/loops-0.4.md" else if (eql(u8, document, "wasm_contract")) "docs/contracts/wasm32-wasi-json-1.md" else if (eql(u8, document, "runtime_guide")) "docs/code-runtimes.md" else if (eql(u8, document, "author_skill")) "skills/author-loop/SKILL.md" else null;
}
pub const Mailbox = struct {
    owner: *Bridge,
    request_id: u64,
    params: []u8,
    method: []u8,
    frames: std.ArrayList(events.Decoded) = .empty,
    control: std.atomic.Value(bool) = .init(false),
    sent: bool = false,
    terminal: bool = false,
    released: bool = false,
    direct: bool = false,
    failure: ?anyerror = null,
    pub fn id(self: *Mailbox) u64 {
        return self.request_id;
    }
    pub fn take(self: *Mailbox) !?events.Decoded {
        self.owner.lock();
        defer self.owner.unlock();
        if (self.failure) |failure| {
            self.failure = null;
            return failure;
        }
        return if (self.frames.items.len == 0) null else self.frames.orderedRemove(0);
    }
};
pub const Bridge = struct {
    closed: bool = false,
    ready: bool = false,
    next_id: u64 = 1,
    guard: std.atomic.Value(bool) = .init(false),
    mailboxes: [8]?*Mailbox = .{null} ** 8,
    direct_frames: std.ArrayList(events.Decoded) = .empty,
    thread: ?std.Thread = null,
    active: ?*Mailbox = null,
    options: ?engine.Options = null,
    owned_profile: ?[]u8 = null,
    infer_context: infer.Context = .{},
    decision_context: decision.Context = .{},
    active_run: ?[]u8 = null,
    audit_cache: @import("loops/code.zig").AuditCache = .{},
    fn lock(self: *Bridge) void {
        while (self.guard.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Bridge) void {
        self.guard.store(false, .release);
    }
    pub fn configure(self: *Bridge, options: engine.Options) !void {
        self.lock();
        defer self.unlock();
        if (self.ready or self.closed) return error.WorkerBusy;
        self.options = options;
    }
    pub fn start(self: *Bridge) !void {
        self.lock();
        defer self.unlock();
        if (self.closed) return error.WorkerDisconnected;
        if (self.ready) return;
        if (self.options == null) {
            const profile = if (std.c.getenv("FH_DATA_DIR")) |path| try alloc.dupe(u8, std.mem.span(path)) else blk: {
                const home = std.c.getenv("HOME") orelse return error.MissingHome;
                break :blk try std.fs.path.join(alloc, &.{ std.mem.span(home), ".fh" });
            };
            self.owned_profile = profile;
            self.options = .{ .io = io_mod.getIo(), .profile = profile };
        }
        if (self.options.?.inferFn == null) {
            self.options.?.infer_context = &self.infer_context;
            // workspace_read steps take the agent host; every other infer step keeps fx's path.
            self.options.?.inferFn = workspace_agent.execute;
            self.options.?.inferPreflightFn = workspace_agent.preflight;
        }
        if (self.options.?.decisionFn == null) {
            self.options.?.decision_context = &self.decision_context;
            self.options.?.decisionFn = decision.execute;
            self.options.?.decisionPreflightFn = decision.preflight;
        }
        if (self.options.?.resolveSelectionFn == null) self.options.?.resolveSelectionFn = infer.defaultSelection;
        if (self.options.?.audit_cache == null) self.options.?.audit_cache = &self.audit_cache;
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        self.ready = true;
    }
    fn submitOwned(self: *Bridge, method: []const u8, params: std.json.Value, direct: bool) !*Mailbox {
        try self.start();
        const bytes = try std.json.Stringify.valueAlloc(alloc, params, .{});
        errdefer alloc.free(bytes);
        if (bytes.len > engine.Engine.input_limit + 16 * 1024) return error.RequestLimit;
        const owned_method = try alloc.dupe(u8, method);
        errdefer alloc.free(owned_method);
        const mailbox = try alloc.create(Mailbox);
        errdefer alloc.destroy(mailbox);
        self.lock();
        defer self.unlock();
        if (self.closed) return error.WorkerDisconnected;
        for (&self.mailboxes) |*slot| if (slot.* == null) {
            if (self.next_id >= 9007199254740991) return error.RequestIdExhausted;
            mailbox.* = .{ .owner = self, .request_id = self.next_id, .method = owned_method, .params = bytes, .direct = direct };
            self.next_id += 1;
            slot.* = mailbox;
            if (std.mem.eql(u8, method, "loopTool")) if (engine.optionalString(params, "name")) |name| if (std.mem.eql(u8, name, "loop_cancel")) {
                if (params.object.get("arguments")) |arguments| if (engine.optionalString(arguments, "runId")) |target| if (self.active_run) |id| if (std.mem.eql(u8, id, target)) if (self.active) |active| active.control.store(true, .release);
            };
            if (!std.mem.eql(u8, method, "startupCheck")) if (self.active) |active| if (std.mem.eql(u8, active.method, "startupCheck")) active.control.store(true, .release);
            return mailbox;
        };
        return error.RequestLimit;
    }
    pub fn submit(self: *Bridge, _: std.json.Value) !*Mailbox {
        _ = self;
        return error.UnsupportedHostMethod;
    }
    pub fn submitMethod(self: *Bridge, method: []const u8, params: std.json.Value) !*Mailbox {
        if (!std.mem.eql(u8, method, "loopTool") and !std.mem.eql(u8, method, "startupCheck")) return error.UnsupportedHostMethod;
        return self.submitOwned(method, params, false);
    }
    pub fn send(self: *Bridge, method: []const u8, params: std.json.Value) !u64 {
        if (std.mem.eql(u8, method, "cancel")) {
            self.lock();
            if (engine.optionalString(params, "runId")) |target| if (self.active_run) |id| if (std.mem.eql(u8, id, target)) if (self.active) |active| active.control.store(true, .release);
            self.unlock();
        }
        return (try self.submitOwned(method, params, true)).id();
    }
    /// Cancels a queued or active request even before a durable run ID exists.
    pub fn cancelRequest(self: *Bridge, id: u64) void {
        self.lock();
        defer self.unlock();
        for (self.mailboxes) |slot| if (slot) |mailbox| {
            if (mailbox.request_id == id and !mailbox.terminal) {
                mailbox.control.store(true, .release);
                return;
            }
        };
    }
    pub fn cancel(self: *Bridge, mailbox: *Mailbox) void {
        self.lock();
        defer self.unlock();
        mailbox.control.store(true, .release);
    }
    pub fn release(self: *Bridge, mailbox: *Mailbox) void {
        self.lock();
        defer self.unlock();
        mailbox.released = true;
        if (!mailbox.terminal) mailbox.control.store(true, .release);
    }
    pub fn shutdown(self: *Bridge) void {
        self.lock();
        defer self.unlock();
        self.closed = true;
        for (self.mailboxes) |slot| if (slot) |mailbox| {
            mailbox.control.store(true, .release);
            mailbox.failure = error.WorkerDisconnected;
        };
    }
    fn free(mailbox: *Mailbox) void {
        for (mailbox.frames.items) |*frame| frame.deinit();
        mailbox.frames.deinit(alloc);
        alloc.free(mailbox.params);
        alloc.free(mailbox.method);
        alloc.destroy(mailbox);
    }
    pub fn next(self: *Bridge) !?events.Decoded {
        self.lock();
        defer self.unlock();
        for (&self.mailboxes) |*slot| if (slot.*) |mailbox| if (mailbox.terminal and (mailbox.direct or mailbox.released)) {
            slot.* = null;
            free(mailbox);
        };
        return if (self.direct_frames.items.len == 0) null else self.direct_frames.orderedRemove(0);
    }
    pub fn deinit(self: *Bridge) void {
        self.shutdown();
        if (self.thread) |thread| thread.join();
        for (self.mailboxes) |slot| if (slot) |mailbox| free(mailbox);
        for (self.direct_frames.items) |*frame| frame.deinit();
        self.direct_frames.deinit(alloc);
        if (self.owned_profile) |profile| alloc.free(profile);
        if (self.active_run) |id| alloc.free(id);
        self.* = .{};
    }
    fn push(self: *Bridge, mailbox: *Mailbox, value: std.json.Value, failed: bool) !void {
        var envelope: std.json.Value = .{ .object = .{} };
        defer envelope.object.deinit(alloc);
        try envelope.object.put(alloc, "id", .{ .integer = @intCast(mailbox.request_id) });
        try envelope.object.put(alloc, if (failed) "error" else "result", value);
        const bytes = try std.json.Stringify.valueAlloc(alloc, envelope, .{});
        defer alloc.free(bytes);
        var decoded = try events.decode(alloc, bytes);
        errdefer decoded.deinit();
        self.lock();
        defer self.unlock();
        if (mailbox.released) {
            decoded.deinit();
            return;
        }
        if (mailbox.direct) {
            if (self.direct_frames.items.len >= 64) return error.RequestLimit;
            try self.direct_frames.append(alloc, decoded);
        } else {
            if (mailbox.frames.items.len >= 8) return error.RequestLimit;
            try mailbox.frames.append(alloc, decoded);
        }
    }
    const Work = struct { bridge: *Bridge, mailbox: *Mailbox, service: ?*engine.Engine = null, failure_detail: ?std.json.Value = null, accepted_run: bool = false };
    fn accepted(raw: *anyopaque, id: []const u8, pkg: *@import("loops/package.zig").Package, inference: bool) !void {
        const work: *Work = @ptrCast(@alignCast(raw));
        work.accepted_run = true;
        const copied_id = try alloc.dupe(u8, id);
        work.bridge.lock();
        if (work.bridge.active_run) |old| alloc.free(old);
        work.bridge.active_run = copied_id;
        work.bridge.unlock();
        if (!work.mailbox.direct) return;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var value: std.json.Value = .{ .object = .{} };
        try value.object.put(a, "run_id", .{ .string = id });
        var presentation: std.json.Value = .{ .object = .{} };
        try presentation.object.put(a, "loop", pkg.manifest.object.get("name").?);
        const selection = work.service.?.options.selection;
        try presentation.object.put(a, "funding", .{ .string = if (!inference) "code-only" else if (engine.hasInference(pkg.manifest) and engine.hasDecision(pkg.manifest)) "mixed-providers" else if (std.mem.eql(u8, selection.provider, "codex")) "chatgpt-plan" else selection.provider });
        try presentation.object.put(a, "provider", .{ .string = selection.provider });
        try presentation.object.put(a, "model", .{ .string = selection.model });
        try presentation.object.put(a, "reasoning", .{ .string = selection.reasoning });
        try presentation.object.put(a, "serviceTier", .{ .string = if (selection.fast) "priority" else "default" });
        try value.object.put(a, "presentation", presentation);
        try work.bridge.push(work.mailbox, value, false);
    }
    fn worker(self: *Bridge) void {
        while (true) {
            self.lock();
            var job: ?*Mailbox = null;
            if (!self.closed) for (self.mailboxes) |slot| if (slot) |mailbox| if (!mailbox.sent and !mailbox.terminal) {
                job = mailbox;
                if (!std.mem.eql(u8, mailbox.method, "startupCheck")) break;
            };
            if (job) |mailbox| {
                mailbox.sent = true;
                self.active = mailbox;
            }
            const closed = self.closed;
            self.unlock();
            if (closed) return;
            const mailbox = job orelse {
                std.Io.sleep(self.options.?.io, .fromMilliseconds(2), .awake) catch {};
                continue;
            };
            var arena = std.heap.ArenaAllocator.init(alloc);
            const a = arena.allocator();
            var work: Work = .{ .bridge = self, .mailbox = mailbox };
            process(&work, a) catch |err| {
                var detail: std.json.Value = .{ .object = .{} };
                detail.object.put(a, "code", .{ .string = engine.errorCode(err) }) catch {};
                // A profile others can reach is the first thing a new person can get wrong, and
                // every command meets it: say which folder and the command that fixes it.
                const message = if (err == error.UnsafeProfile) engine.storage.profileRefusal(a, self.options.?.profile) catch @errorName(err) else @errorName(err);
                detail.object.put(a, "message", .{ .string = message }) catch {};
                if (err == error.UnsafeProfile) detail.object.put(a, "cause", .{ .string = @errorName(err) }) catch {};
                if (work.failure_detail) |diagnostic| detail = diagnostic;
                self.push(mailbox, detail, true) catch |failed| {
                    self.lock();
                    mailbox.failure = failed;
                    self.unlock();
                };
            };
            arena.deinit();
            self.lock();
            mailbox.terminal = true;
            self.active = null;
            if (self.active_run) |id| alloc.free(id);
            self.active_run = null;
            self.unlock();
        }
    }
    fn process(work: *Work, allocator: std.mem.Allocator) !void {
        const self = work.bridge;
        const mailbox = work.mailbox;
        if (mailbox.control.load(.acquire)) return error.Cancelled;
        const params = try @import("loops/schema.zig").parseBounded(allocator, mailbox.params, engine.Engine.input_limit + 16 * 1024);
        var service: engine.Engine = .{ .options = self.options.? };
        work.service = &service;
        var method: []const u8 = mailbox.method;
        var arguments = params;
        // A person's own command may fetch a GitHub address. A chat tool call never may: the
        // model cannot fetch or install a package, whatever arguments it writes.
        service.addresses = !std.mem.eql(u8, method, "loopTool");
        if (std.mem.eql(u8, method, "loopTool")) {
            const name = try engine.requiredString(params, "name");
            arguments = try engine.runner.get(params, "arguments");
            if (params.object.get("selection")) |selection| {
                service.options.resolveSelectionFn = null;
                service.options.selection = .{ .provider = try engine.requiredString(selection, "provider"), .model = try engine.requiredString(selection, "model"), .reasoning = try engine.requiredString(selection, "reasoning"), .fast = switch (try engine.runner.get(selection, "fast")) {
                    .bool => |fast| fast,
                    else => return error.InvalidRequest,
                } };
            }
            if (std.mem.eql(u8, name, "docs_read")) {
                try self.push(mailbox, try self.readDocs(allocator, arguments), false);
                return;
            }
            method = if (std.mem.eql(u8, name, "loop_run")) "run" else if (std.mem.eql(u8, name, "loop_check")) "check" else if (std.mem.eql(u8, name, "loop_get")) "get" else if (std.mem.eql(u8, name, "loop_cancel")) "cancel" else if (std.mem.eql(u8, name, "loop_next")) "next" else if (std.mem.eql(u8, name, "loop_submit")) "submit" else return error.UnsupportedHostMethod;
        }
        if (std.mem.eql(u8, method, "check")) {
            const checked = service.check(allocator, arguments) catch |err| {
                // An unsettled installation is the one check failure a person must act on
                // elsewhere, so it carries the run, the step and the command that settles it.
                // A package refusal names the package and what to do about it.
                if (err == error.RecoveryRequired or err == error.RunBusy or service.package_note != null) work.failure_detail = try service.errorDetail(allocator, err);
                return err;
            };
            try self.push(mailbox, checked, false);
            return;
        }
        if (std.mem.eql(u8, method, "add") or std.mem.eql(u8, method, "list") or std.mem.eql(u8, method, "remove") or std.mem.eql(u8, method, "update")) {
            const answered = service.packages(allocator, method, arguments) catch |err| {
                work.failure_detail = try service.errorDetail(allocator, err);
                return err;
            };
            try self.push(mailbox, answered, false);
            return;
        }
        if (std.mem.eql(u8, method, "settle")) {
            const settled = service.settle(allocator, arguments) catch |err| {
                work.failure_detail = try service.errorDetail(allocator, err);
                return err;
            };
            try self.push(mailbox, settled, false);
            return;
        }
        if (std.mem.eql(u8, method, "run") or std.mem.eql(u8, method, "retry")) {
            const Scope = @import("../vendor/fx/src/core/shared/http_pool.zig").Scope;
            var infer_scope = Scope.init(alloc);
            defer infer_scope.deinit();
            var decision_scope = Scope.init(alloc);
            defer decision_scope.deinit();
            self.infer_context.transport_scope = &infer_scope;
            self.decision_context.transport_scope = &decision_scope;
            defer self.infer_context.transport_scope = null;
            defer self.decision_context.transport_scope = null;
            // loops/0.3 agent driver: the run returns as soon as it waits for its agent, with the
            // steps to perform. There is no foreground run to follow, so no acceptance frame.
            // A retry is always a new runner-driven run.
            const retrying = std.mem.eql(u8, method, "retry");
            // `run ADDRESS`: fetch it and, only with the digest that was inspected, install it.
            // Then the run is of the installed NAME@VERSION. Nobody can be asked from here, so
            // without that digest the answer is the inspection and the command to send next.
            if (!retrying) if (service.admit(allocator, arguments) catch |err| {
                work.failure_detail = try service.errorDetail(allocator, err);
                try work.failure_detail.?.object.put(allocator, "model_request_dispatches", .{ .integer = 0 });
                try work.failure_detail.?.object.put(allocator, "model_request_dispatches_complete", .{ .bool = true });
                return err;
            }) |admitted| {
                const package_name = engine.optionalString(admitted, "package") orelse {
                    try self.push(mailbox, admitted, false);
                    return;
                };
                try arguments.object.put(allocator, "packagePath", .{ .string = package_name });
            };
            const agent_driven = if (retrying) false else if (engine.optionalString(arguments, "driver")) |driver| std.mem.eql(u8, driver, "agent") else false;
            const hooks: ?engine.Hooks = if (agent_driven) null else .{ .context = work, .acceptedFn = accepted };
            const result = if (retrying) service.retry(allocator, arguments, &mailbox.control, hooks) else service.run(allocator, arguments, &mailbox.control, hooks);
            var run = result catch |err| {
                work.failure_detail = try service.errorDetail(allocator, err);
                // Before durable acceptance the runner cannot have dispatched.
                // After acceptance a persistence error may hide a count.
                if (!work.accepted_run) {
                    try work.failure_detail.?.object.put(allocator, "model_request_dispatches", .{ .integer = 0 });
                    try work.failure_detail.?.object.put(allocator, "model_request_dispatches_complete", .{ .bool = true });
                }
                return err;
            };
            defer run.deinit();
            if (agent_driven) try self.push(mailbox, try engine.agentResult(allocator, run), false) else if (!mailbox.direct) try self.push(mailbox, try engine.publicResult(allocator, run.record), false);
            return;
        }
        if (std.mem.eql(u8, method, "next") or std.mem.eql(u8, method, "submit")) {
            const submitting = std.mem.eql(u8, method, "submit");
            if (submitting) {
                // A submission may execute code: a cancel for this run must reach it.
                const id = try alloc.dupe(u8, try engine.requiredString(arguments, "runId"));
                self.lock();
                if (self.active_run) |old| alloc.free(old);
                self.active_run = id;
                self.unlock();
            }
            var run = (if (submitting) service.submit(allocator, arguments, &mailbox.control) else service.next(allocator, try engine.requiredString(arguments, "runId"))) catch |err| {
                work.failure_detail = try service.errorDetail(allocator, err);
                return err;
            };
            defer run.deinit();
            try self.push(mailbox, try engine.agentResult(allocator, run), false);
            return;
        }
        if (std.mem.eql(u8, method, "get")) {
            const result = try service.get(allocator, try engine.requiredString(arguments, "runId"));
            defer result.deinit();
            try self.push(mailbox, try engine.publicResult(allocator, result.value), false);
            return;
        }
        if (std.mem.eql(u8, method, "startupCheck")) {
            try self.push(mailbox, try service.startup(allocator, try engine.requiredString(arguments, "workspaceRoot"), try self.assets(allocator), &mailbox.control), false);
            return;
        }
        if (std.mem.eql(u8, method, "runs")) {
            try self.push(mailbox, try service.list(allocator, engine.optionalString(arguments, "after")), false);
            return;
        }
        if (std.mem.eql(u8, method, "cancel")) {
            try self.push(mailbox, try service.cancel(allocator, try engine.requiredString(arguments, "runId")), false);
            return;
        }
        return error.UnsupportedHostMethod;
    }
    fn assets(_: *Bridge, allocator: std.mem.Allocator) ![]const u8 {
        const path = try self_exe.pathForPeerReexec(allocator);
        return allocator.dupe(u8, std.fs.path.dirname(path) orelse return error.AssetUnavailable);
    }
    fn readDocs(self: *Bridge, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
        const document = try engine.requiredString(params, "document");
        const relative = documentPath(document) orelse return error.InvalidRequest;
        const path = try std.fs.path.join(allocator, &.{ try self.assets(allocator), relative });
        var file = try std.Io.Dir.openFileAbsolute(self.options.?.io, path, .{ .follow_symlinks = false });
        defer file.close(self.options.?.io);
        if ((try file.stat(self.options.?.io)).kind != .file) return error.InvalidRequest;
        var buffer: [8192]u8 = undefined;
        var reader = file.reader(self.options.?.io, &buffer);
        const bytes = try reader.interface.allocRemaining(allocator, .limited(1048576));
        const offset: usize = if (params.object.get("offset")) |v| if (v == .integer and v.integer >= 0 and v.integer <= 1048576) @intCast(v.integer) else return error.InvalidRequest else 0;
        const length: usize = if (params.object.get("length")) |v| if (v == .integer and v.integer > 0 and v.integer <= 32768) @intCast(v.integer) else return error.InvalidRequest else 32768;
        var begin = @min(offset, bytes.len);
        while (begin < bytes.len and bytes[begin] & 0xc0 == 0x80) begin += 1;
        var end = @min(begin + length, bytes.len);
        while (end > begin and end < bytes.len and bytes[end] & 0xc0 == 0x80) end -= 1;
        var value: std.json.Value = .{ .object = .{} };
        try value.object.put(allocator, "content", .{ .string = bytes[begin..end] });
        try value.object.put(allocator, "complete", .{ .bool = end == bytes.len });
        return value;
    }
};
