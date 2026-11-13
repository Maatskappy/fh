//! Portable loops execution. No terminal, transport, model or runtime ownership.
const std = @import("std");
const json_schema = @import("schema.zig");
pub const Value = std.json.Value;
pub const Limits = struct {
    max_tokens: u64 = 100000,
    max_seconds: u32 = 600,
    max_tool_calls: u32 = 2,
    max_iterations: u32 = 100,
    max_output_bytes: usize = 1048576,
    max_diagnostic_bytes: usize = 65536,
    max_operations: u32 = 1024,
    max_history_bytes: usize = 16 * 1048576,
};
pub const Usage = struct { input_tokens: u64, output_tokens: u64 };
pub const Selection = struct { provider: []const u8 = "codex", model: []const u8 = "gpt-6-luna", reasoning: []const u8 = "medium", fast: bool = true };
pub const Effect = struct { id: []const u8, state: enum { not_applied, applied, unknown }, kind: []const u8 = "external", details: ?Value = null };
pub const Journal = struct {
    context: *anyopaque,
    recordFn: *const fn (*anyopaque, Effect) anyerror!void,
    pub fn record(self: Journal, effect: Effect) !void {
        try self.recordFn(self.context, effect);
    }
};
pub const ModelDispatch = struct {
    context: *anyopaque,
    recordFn: *const fn (*anyopaque) void,
    pub fn record(self: ModelDispatch) void {
        self.recordFn(self.context);
    }
};
pub const CapabilityPort = struct { context: *anyopaque, callFn: *const fn (*anyopaque, std.mem.Allocator, StepRequest, Value) anyerror!Value };
pub const StepRequest = struct {
    run_id: []const u8,
    step_id: []const u8,
    // loops/0.3 section 6: the step's position in the run. Equal to `step_id` at top
    // level; with `iteration` it names one attempt, where `step_id` alone cannot
    // (every element of a map runs the same step).
    path: []const u8 = "",
    iteration: u32,
    definition: Value,
    input: Value,
    selection: Selection,
    response_schema: Value,
    limits: Limits,
    cancel: *const std.atomic.Value(bool),
    deadline_ms: i64,
    journal: Journal,
    // Count provider/transport invocations, including failures after dispatch.
    model_dispatch: ?ModelDispatch = null,
    capability: ?CapabilityPort = null,
};
pub const CodeExecution = struct { artifact_sha256: []const u8, profile: []const u8, engine: []const u8, engine_version: []const u8 };
pub const StepResult = struct { code_execution: ?CodeExecution = null, output: Value = .null, usage: ?Usage = null, failure: ?anyerror = null, tool_calls: u32 = 0, operations: u32 = 1, effects: []const Effect = &.{} };
/// loops/0.3 section 10. Under the agent driver the runner performs code steps only: every
/// `infer` and `decision` step waits for the driving agent's `submit`, and the runner makes no
/// model call. Each operation replays the stored record: settled attempts are read back, never
/// executed again, so `next` and `submit` work across separate processes.
pub const Answer = enum { accepted, rejected, not_ready, conflict };
pub const Submission = struct {
    path: []const u8,
    pass: u32,
    output: Value,
    /// Set when the caller could not read an output at all (not JSON, or too large to load):
    /// the step this names answers `rejected` with this text, exactly as for an invalid output.
    refusal: ?[]const u8 = null,
};
pub const ReadyStep = struct { path: []const u8, step_id: []const u8, pass: u32, kind: []const u8, input: Value, definition: Value };
pub const Agent = struct {
    /// The stored record of the run to continue; null starts a new run.
    record: ?Value = null,
    /// `advance` executes ready code and stores the record. `peek` reads what is ready and
    /// stores nothing. `cancel` stops a waiting run without reading its package.
    op: enum { advance, peek, cancel } = .advance,
    submission: ?Submission = null,
    /// Kept on a new run's record as `agent`: what the caller needs to find the package again.
    context: Value = .null,
};
pub const Request = struct { package_path: []const u8 = "", bindings_id: []const u8 = "", input_source: []const u8 = "inline", input_sha256: []const u8 = "", case_id: ?[]const u8 = null, retry_of: ?[]const u8 = null, run_id: []const u8, manifest: Value, input: Value, package_digest: []const u8 = "", binding_digest: []const u8 = "", selection: Selection = .{}, limits: Limits = .{}, cancel: *const std.atomic.Value(bool), deadline_ms: i64, agent: ?Agent = null };
pub const Ports = struct {
    context: *anyopaque,
    executeFn: *const fn (*anyopaque, std.mem.Allocator, StepRequest) anyerror!StepResult,
    validateFn: *const fn (*anyopaque, ?[]const u8, Value) anyerror!void,
    // Exact, size-checked JSON for this Value; encoded bytes live until return.
    persistFn: *const fn (*anyopaque, Value, []const u8) anyerror!void,
    nowFn: *const fn (*anyopaque) i64,
    finalizeFn: ?*const fn (*anyopaque, std.mem.Allocator, *Value) anyerror!void = null,
    schemaFn: ?*const fn (*anyopaque, []const u8) anyerror!Value = null,
};
pub const Run = struct {
    arena: std.heap.ArenaAllocator,
    record: Value,
    // Agent driver: the steps the agent must perform now, in path order.
    ready: []const ReadyStep = &.{},
    answer: ?Answer = null,
    // The output already committed for the submitted path and pass, on `conflict`.
    committed: ?Value = null,
    // Set by the engine: `ready` as the public `next` list, and a rejection's schema errors.
    next: ?Value = null,
    issues: ?Value = null,
    // Why a submission was rejected before its output could be checked against the schema.
    refusal: ?[]const u8 = null,
    pub fn deinit(self: *Run) void {
        self.arena.deinit();
        self.* = undefined;
    }
};
pub fn get(value: Value, key: []const u8) !Value {
    if (value != .object) return error.InvalidDefinition;
    return value.object.get(key) orelse error.MissingBinding;
}
pub fn text(value: Value) ![]const u8 {
    if (value != .string) return error.InvalidDefinition;
    return value.string;
}
fn object() Value {
    return .{ .object = std.json.ObjectMap{} };
}
fn put(alloc: std.mem.Allocator, value: *Value, key: []const u8, item: Value) !void {
    try value.object.put(alloc, key, item);
}
fn number(n: u64) Value {
    return .{ .integer = @intCast(n) };
}
fn string(s: []const u8) Value {
    return .{ .string = s };
}
fn clone(alloc: std.mem.Allocator, value: Value, limit: usize) !Value {
    const bytes = try std.json.Stringify.valueAlloc(alloc, value, .{});
    if (bytes.len > limit) return error.OutputLimit;
    const parsed = try std.json.parseFromSlice(Value, alloc, bytes, .{ .allocate = .alloc_always });
    return parsed.value;
}
fn decodeSegment(alloc: std.mem.Allocator, segment: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < segment.len) : (i += 1) {
        if (segment[i] != '~') {
            try result.append(alloc, segment[i]);
            continue;
        }
        i += 1;
        if (i >= segment.len or (segment[i] != '0' and segment[i] != '1')) return error.InvalidBinding;
        try result.append(alloc, if (segment[i] == '0') '~' else '/');
    }
    return result.toOwnedSlice(alloc);
}
fn pointer(alloc: std.mem.Allocator, path: []const u8, scope: Value) !Value {
    if (path.len == 0) return scope;
    if (path[0] != '/') return error.InvalidBinding;
    var selected = scope;
    var parts = std.mem.splitScalar(u8, path[1..], '/');
    while (parts.next()) |encoded| {
        const key = try decodeSegment(alloc, encoded);
        selected = switch (selected) {
            .object => |map| map.get(key) orelse return error.MissingBinding,
            .array => |list| blk: {
                if (key.len == 0 or (key.len > 1 and key[0] == '0')) return error.MissingBinding;
                for (key) |c| if (!std.ascii.isDigit(c)) return error.MissingBinding;
                const index = std.fmt.parseInt(usize, key, 10) catch return error.MissingBinding;
                if (index >= list.items.len) return error.MissingBinding;
                break :blk list.items[index];
            },
            else => return error.MissingBinding,
        };
    }
    return selected;
}
pub fn resolve(alloc: std.mem.Allocator, binding: Value, scope: Value) !Value {
    return walk(alloc, binding, scope, 0);
}
fn walk(alloc: std.mem.Allocator, binding: Value, scope: Value, depth: usize) anyerror!Value {
    if (depth > 128) return error.InvalidBinding;
    if (binding == .object) {
        if (binding.object.count() == 1) {
            if (binding.object.get("value")) |literal| return clone(alloc, literal, 1048576);
            if (binding.object.get("from")) |from| if (from == .string) return clone(alloc, try pointer(alloc, from.string, scope), 1048576);
        }
        var out = object();
        var it = binding.object.iterator();
        while (it.next()) |entry| try put(alloc, &out, entry.key_ptr.*, try walk(alloc, entry.value_ptr.*, scope, depth + 1));
        return out;
    }
    if (binding == .array) {
        var out: Value = .{ .array = std.array_list.Managed(Value).init(alloc) };
        for (binding.array.items) |item| try out.array.append(try walk(alloc, item, scope, depth + 1));
        return out;
    }
    return binding;
}
/// Whether a step is of `kind`, at any depth of loops/0.3 branches and map steps.
pub fn hasKind(steps: Value, kind: []const u8) bool {
    if (steps != .array) return false;
    for (steps.array.items) |step| {
        if (step != .object) continue;
        if (step.object.get("kind")) |k| if (k == .string and std.mem.eql(u8, k.string, kind)) return true;
        if (step.object.get("steps")) |inner| if (hasKind(inner, kind)) return true;
        if (step.object.get("branches")) |branches| if (branches == .object) for (branches.object.values()) |branch| if (hasKind(branch, kind)) return true;
    }
    return false;
}
/// Errors that stop the whole run, wherever they happen (loops/0.3 section 3).
/// Every other error fails the step: the run at top level, the branch or element when nested.
fn stops(err: anyerror) bool {
    return switch (err) {
        error.Cancelled, error.TimeLimit, error.TokenLimit, error.ToolLimit, error.OperationLimit, error.IterationLimit, error.OutputLimit, error.HistoryLimit, error.UsageUnavailable, error.UncertainEffect, error.CleanupPending => true,
        else => false,
    };
}
/// What one position in a run can read (loops/0.3 section 4). The root frame is
/// the top-level steps; each branch and each map element gets its own.
const Frame = struct {
    // Step id -> {"output"}: steps completed before the enclosing composite, plus this frame's own.
    steps: *Value,
    // Path prefix for steps in this frame: "", "<parallel>/<branch>/" or "<map>[<index>]/".
    prefix: []const u8 = "",
    item: ?Value = null,
    index: u64 = 0,
    nested: bool = false,
};
const State = struct {
    alloc: std.mem.Allocator,
    request: Request,
    ports: Ports,
    record: Value,
    current: Value,
    carry: ?Value = null,
    tokens: u64 = 0,
    model_request_dispatches: u32 = 0,
    operations: u32 = 0,
    finalized: bool = false,
    tools: u32 = 0,
    uncertain_usage: bool = false,
    active_attempt: ?usize = null,
    failure_step: ?[]const u8 = null,
    // The record could not be stored: no nested failure may absorb this.
    unsaved: bool = false,
    agent: ?Agent = null,
    ready: std.ArrayList(ReadyStep) = .empty,
    answer: ?Answer = null,
    refusal: ?[]const u8 = null,
    // The reason a replayed attempt failed with, while error.ReplayedFailure unwinds to its branch.
    replayed: []const u8 = "",
    fn check(self: *State) !void {
        try self.interrupted();
        if (self.operations >= self.request.limits.max_operations) return error.OperationLimit;
    }
    /// The stops that apply to every position, including one that is only read back.
    fn interrupted(self: *State) !void {
        if (self.request.cancel.load(.acquire)) return error.Cancelled;
        if (self.ports.nowFn(self.ports.context) >= self.request.deadline_ms) return error.TimeLimit;
        if (self.uncertain_usage) return error.UsageUnavailable;
    }
    fn modelDispatched(raw: *anyopaque) void {
        const self: *State = @ptrCast(@alignCast(raw));
        self.model_request_dispatches += 1;
    }
    fn save(self: *State) !void {
        if (self.agent) |agent| if (agent.op == .peek) return;
        const before_finalize = try text(try get(self.record, "status"));
        if (!self.finalized and !std.mem.eql(u8, before_finalize, "running") and !std.mem.eql(u8, before_finalize, "queued")) {
            self.finalized = true;
            if (self.ports.finalizeFn) |finalize| try finalize(self.ports.context, self.alloc, &self.record);
        }
        try put(self.alloc, &self.record, "current", self.current);
        try put(self.alloc, &self.record, "used_tokens", number(self.tokens));
        try put(self.alloc, &self.record, "model_request_dispatches", number(self.model_request_dispatches));
        const status = try text(try get(self.record, "status"));
        // The agent driver never dispatches a model request, so its count of zero is always complete.
        try put(self.alloc, &self.record, "model_request_dispatches_complete", .{ .bool = self.agent != null or (!std.mem.eql(u8, status, "queued") and !std.mem.eql(u8, status, "running")) });
        try put(self.alloc, &self.record, "used_operations", number(self.operations));
        try put(self.alloc, &self.record, "used_tool_calls", number(self.tools));
        try put(self.alloc, &self.record, "usage_unknown", .{ .bool = self.uncertain_usage });
        const encoded = try std.json.Stringify.valueAlloc(self.alloc, self.record, .{});
        defer self.alloc.free(encoded);
        if (encoded.len > self.request.limits.max_history_bytes) return error.HistoryLimit;
        self.ports.persistFn(self.ports.context, self.record, encoded) catch |err| {
            self.unsaved = true;
            return err;
        };
    }
    fn root(self: *State) Frame {
        return .{ .steps = &self.current };
    }
    fn scope(self: *State, frame: *const Frame, with_carry: bool) !Value {
        var out = object();
        try put(self.alloc, &out, "input", self.request.input);
        try put(self.alloc, &out, "steps", frame.steps.*);
        if (with_carry) if (self.carry) |carry| try put(self.alloc, &out, "carry", carry);
        if (frame.item) |item| {
            try put(self.alloc, &out, "item", item);
            try put(self.alloc, &out, "index", number(frame.index));
        }
        return out;
    }
    fn journal(raw: *anyopaque, effect: Effect) !void {
        const self: *State = @ptrCast(@alignCast(raw));
        if (effect.id.len == 0 or effect.id.len > 256 or effect.kind.len > 128) return error.InvalidReceipt;
        var effects = self.record.object.getPtr("effects").?;
        for (effects.array.items) |*prior| {
            if (!std.mem.eql(u8, try text(try get(prior.*, "id")), effect.id)) continue;
            const old = try text(try get(prior.*, "state"));
            if (std.mem.eql(u8, old, "applied") and effect.state != .applied) return error.ReceiptConflict;
            if (effect.details) |details| {
                const previous = try get(prior.*, "details");
                const a = try std.json.Stringify.valueAlloc(self.alloc, previous, .{});
                defer self.alloc.free(a);
                const b = try std.json.Stringify.valueAlloc(self.alloc, details, .{});
                defer self.alloc.free(b);
                if (!std.mem.eql(u8, a, b)) return error.ReceiptConflict;
            }
            try put(self.alloc, prior, "state", string(@tagName(effect.state)));
            try self.save();
            return;
        }
        if (effects.array.items.len >= 1024) return error.HistoryLimit;
        var receipt = object();
        try put(self.alloc, &receipt, "id", string(try self.alloc.dupe(u8, effect.id)));
        try put(self.alloc, &receipt, "kind", string(try self.alloc.dupe(u8, effect.kind)));
        try put(self.alloc, &receipt, "state", string(@tagName(effect.state)));
        if (effect.details) |details| try put(self.alloc, &receipt, "details", try clone(self.alloc, details, self.request.limits.max_diagnostic_bytes));
        try effects.array.append(receipt);
        try self.save();
    }
    fn step(self: *State, definition: Value, frame: *const Frame, iteration: u32, with_carry: bool) anyerror!void {
        const id = try text(try get(definition, "id"));
        self.failure_step = id;
        try self.interrupted();
        const kind = try text(try get(definition, "kind"));
        const path = if (frame.prefix.len == 0) id else try std.mem.concat(self.alloc, u8, &.{ frame.prefix, id });
        // A settled position spends nothing, so it is read back before the operation limit is
        // applied: the outcome must not depend on the order sibling steps were submitted in.
        if (self.agent != null and try self.replay(frame, id, path, iteration)) {
            self.failure_step = null;
            return;
        }
        try self.check();
        if (std.mem.eql(u8, kind, "parallel")) return self.parallel(definition, frame, id, path, iteration, with_carry);
        if (std.mem.eql(u8, kind, "map")) return self.map(definition, frame, id, path, iteration, with_carry);
        const metered = std.mem.eql(u8, kind, "infer") or std.mem.eql(u8, kind, "decision");
        if (metered and self.tokens >= self.request.limits.max_tokens) return error.TokenLimit;
        const bound = try resolve(self.alloc, try get(definition, "input"), try self.scope(frame, with_carry));
        _ = try clone(self.alloc, bound, self.request.limits.max_output_bytes);
        if (self.agent) |agent| {
            if (metered) {
                try self.awaitAgent(agent, definition, frame, id, kind, path, iteration, bound);
                self.failure_step = null;
                return;
            }
            // Reading what is ready executes nothing; `submit` runs the code that became ready.
            if (agent.op == .peek) return error.Pending;
        }
        var attempt = object();
        try put(self.alloc, &attempt, "step_id", string(id));
        try put(self.alloc, &attempt, "path", string(path));
        try put(self.alloc, &attempt, "iteration", number(iteration));
        try put(self.alloc, &attempt, "status", string("running"));
        try put(self.alloc, &attempt, "input", bound);
        const attempts = self.record.object.getPtr("attempts").?;
        if (attempts.array.items.len >= 4096) return error.HistoryLimit;
        self.active_attempt = attempts.array.items.len;
        try attempts.array.append(attempt);
        try self.save();
        try self.check();
        self.operations += 1;
        try self.save();
        var limits = self.request.limits;
        limits.max_tokens -|= self.tokens;
        limits.max_tool_calls -= self.tools;
        limits.max_operations -= self.operations - 1;
        const result = try self.ports.executeFn(self.ports.context, self.alloc, .{ .run_id = self.request.run_id, .step_id = id, .path = path, .iteration = iteration, .definition = definition, .input = bound, .selection = self.request.selection, .response_schema = if (self.ports.schemaFn) |schema| try schema(self.ports.context, id) else .{ .bool = true }, .limits = limits, .cancel = self.request.cancel, .deadline_ms = self.request.deadline_ms, .journal = .{ .context = self, .recordFn = journal }, .model_dispatch = .{ .context = self, .recordFn = modelDispatched } });
        if (result.code_execution) |identity| {
            var metadata = object();
            inline for (.{ "artifact_sha256", "profile", "engine", "engine_version" }) |key| try put(self.alloc, &metadata, key, string(try self.alloc.dupe(u8, @field(identity, key))));
            try put(self.alloc, &self.record.object.getPtr("attempts").?.array.items[self.active_attempt.?], "code_execution", metadata);
        }
        // Retain only the static error identifier, even when unknown usage wins.
        // A nested failure settles its branch and the run goes on, so its cause stays on the attempt.
        if (result.failure) |failure| try put(self.alloc, if (frame.nested) &self.record.object.getPtr("attempts").?.array.items[self.active_attempt.?] else &self.record, "failure_cause", string(@errorName(failure)));
        for (result.effects) |effect| try journal(self, effect);
        if (metered) {
            if (result.usage) |usage| self.tokens = std.math.add(u64, self.tokens, std.math.add(u64, usage.input_tokens, usage.output_tokens) catch return error.TokenLimit) catch return error.TokenLimit else self.uncertain_usage = true;
        } else if (!std.mem.eql(u8, kind, "code")) return error.InvalidDefinition;
        if (result.operations == 0 or result.operations > self.request.limits.max_operations - self.operations + 1) return error.OperationLimit;
        self.operations += result.operations - 1;
        if (result.tool_calls > self.request.limits.max_tool_calls - self.tools) return error.ToolLimit;
        self.tools += result.tool_calls;
        // Cancellation wins over late output; retained effects/accounting survive.
        try self.save();
        if (self.request.cancel.load(.acquire)) return error.Cancelled;
        if (self.ports.nowFn(self.ports.context) >= self.request.deadline_ms) return error.TimeLimit;
        if (self.uncertain_usage) return error.UsageUnavailable;
        if (self.tokens > self.request.limits.max_tokens) return error.TokenLimit;
        if (result.failure) |failure| return failure;
        if (try self.uncertain()) return error.UncertainEffect;
        const output = try clone(self.alloc, result.output, self.request.limits.max_output_bytes);
        try self.ports.validateFn(self.ports.context, id, output);
        var current = object();
        try put(self.alloc, &current, "output", output);
        try put(self.alloc, frame.steps, id, current);
        const stored = &self.record.object.getPtr("attempts").?.array.items[self.active_attempt.?];
        try put(self.alloc, stored, "output", output);
        try put(self.alloc, stored, "status", string("completed"));
        self.active_attempt = null;
        try self.save();
        self.failure_step = null;
    }
    fn attempted(self: *State, path: []const u8, iteration: u32) !?Value {
        for ((try get(self.record, "attempts")).array.items) |attempt| {
            const pass = try get(attempt, "iteration");
            if (pass == .integer and pass.integer == iteration and std.mem.eql(u8, try text(try get(attempt, "path")), path)) return attempt;
        }
        return null;
    }
    /// Agent driver: a position the stored record already settled is read back, not run again.
    fn replay(self: *State, frame: *const Frame, id: []const u8, path: []const u8, iteration: u32) !bool {
        const attempt = try self.attempted(path, iteration) orelse return false;
        const status = try text(try get(attempt, "status"));
        if (std.mem.eql(u8, status, "completed")) {
            var current = object();
            try put(self.alloc, &current, "output", try get(attempt, "output"));
            try put(self.alloc, frame.steps, id, current);
            return true;
        }
        if (std.mem.eql(u8, status, "failed")) {
            self.replayed = try text(try get(try get(attempt, "error"), "reason"));
            return error.ReplayedFailure;
        }
        // An attempt that never settled may have had an effect: it is never run twice.
        return error.UncertainEffect;
    }
    /// Agent driver: an `infer` or `decision` step is settled by the submission that names this
    /// path and pass, or else stays open and is listed as ready.
    fn awaitAgent(self: *State, agent: Agent, definition: Value, frame: *const Frame, id: []const u8, kind: []const u8, path: []const u8, iteration: u32, bound: Value) !void {
        if (agent.submission) |submission| if (agent.op == .advance and self.answer == null and submission.pass == iteration and std.mem.eql(u8, submission.path, path)) {
            // A fault in the submitted value rejects the submission. It never stops the run.
            const encoded = try std.json.Stringify.valueAlloc(self.alloc, submission.output, .{});
            if (submission.refusal) |message| {
                self.refusal = try self.alloc.dupe(u8, message);
            } else if (encoded.len > self.request.limits.max_output_bytes) {
                self.refusal = try std.fmt.allocPrint(self.alloc, "The output is {d} bytes; an output in this run may be at most {d} bytes.", .{ encoded.len, self.request.limits.max_output_bytes });
            }
            const output = if (self.refusal == null) (try std.json.parseFromSlice(Value, self.alloc, encoded, .{ .allocate = .alloc_always })).value else Value.null;
            if (self.refusal != null) {
                self.answer = .rejected;
            } else if (self.ports.validateFn(self.ports.context, id, output)) |_| {
                var attempt = object();
                try put(self.alloc, &attempt, "step_id", string(id));
                try put(self.alloc, &attempt, "path", string(path));
                try put(self.alloc, &attempt, "iteration", number(iteration));
                try put(self.alloc, &attempt, "status", string("completed"));
                try put(self.alloc, &attempt, "input", bound);
                try put(self.alloc, &attempt, "output", output);
                try put(self.alloc, &attempt, "submitted", .{ .bool = true });
                const attempts = self.record.object.getPtr("attempts").?;
                if (attempts.array.items.len >= 4096) return error.HistoryLimit;
                try attempts.array.append(attempt);
                self.operations += 1;
                var current = object();
                try put(self.alloc, &current, "output", output);
                try put(self.alloc, frame.steps, id, current);
                self.answer = .accepted;
                return self.save();
            } else |err| {
                if (err != error.InvalidOutput) return err;
                self.answer = .rejected;
            }
        };
        try self.ready.append(self.alloc, .{ .path = path, .step_id = id, .pass = iteration, .kind = kind, .input = bound, .definition = definition });
        return error.Pending;
    }
    fn uncertain(self: *State) !bool {
        for ((try get(self.record, "effects")).array.items) |effect| if (std.mem.eql(u8, try text(try get(effect, "state")), "unknown")) return true;
        return false;
    }
    /// Runs one branch or map element to its settled result (loops/0.3 section 3).
    /// It fails at its first failed step; a run-level stop is not a result and propagates.
    fn settle(self: *State, steps: Value, frame: *const Frame, iteration: u32, with_carry: bool) anyerror!Value {
        if (steps != .array or steps.array.items.len == 0) return error.InvalidDefinition;
        var result = object();
        for (steps.array.items) |definition| self.step(definition, frame, iteration, with_carry) catch |err| {
            // A step waiting for the agent leaves its branch open: that is not a result.
            if (stops(err) or self.unsaved or err == error.OutOfMemory or err == error.Pending) return err;
            // A failed step may leave an effect unsettled; that stops the run, it does not settle a branch.
            if (try self.uncertain()) return error.UncertainEffect;
            var failure = object();
            try put(self.alloc, &failure, "reason", string(if (err == error.ReplayedFailure) self.replayed else reasonCode(err)));
            if (self.active_attempt) |index| {
                const attempt = &self.record.object.getPtr("attempts").?.array.items[index];
                try put(self.alloc, attempt, "status", string("failed"));
                try put(self.alloc, attempt, "error", failure);
                self.active_attempt = null;
                try self.save();
            }
            try put(self.alloc, &result, "status", string("failed"));
            try put(self.alloc, &result, "error", failure);
            return result;
        };
        const last = try text(try get(steps.array.items[steps.array.items.len - 1], "id"));
        try put(self.alloc, &result, "status", string("completed"));
        try put(self.alloc, &result, "output", try get(try get(frame.steps.*, last), "output"));
        return result;
    }
    // Branches and elements run one at a time, in declared and element order. Each starts
    // from a copy of what the composite could read, so none can read a sibling. Under the
    // agent driver a branch that waits for the agent does not hold the others back: every
    // branch runs as far as it can, so the ready steps of all of them appear together.
    fn parallel(self: *State, definition: Value, frame: *const Frame, id: []const u8, path: []const u8, iteration: u32, with_carry: bool) anyerror!void {
        const branches = try get(definition, "branches");
        if (branches != .object or branches.object.count() == 0) return error.InvalidDefinition;
        var output = object();
        var waiting = false;
        var it = branches.object.iterator();
        while (it.next()) |branch| {
            var visible: Value = .{ .object = try frame.steps.object.clone(self.alloc) };
            const inner: Frame = .{ .steps = &visible, .prefix = try std.fmt.allocPrint(self.alloc, "{s}/{s}/", .{ path, branch.key_ptr.* }), .item = frame.item, .index = frame.index, .nested = true };
            const result = self.settle(branch.value_ptr.*, &inner, iteration, with_carry) catch |err| {
                if (err != error.Pending) return err;
                waiting = true;
                continue;
            };
            try put(self.alloc, &output, branch.key_ptr.*, result);
        }
        if (waiting) return error.Pending;
        try self.complete(frame, id, path, iteration, null, output);
    }
    fn map(self: *State, definition: Value, frame: *const Frame, id: []const u8, path: []const u8, iteration: u32, with_carry: bool) anyerror!void {
        const over = try resolve(self.alloc, try get(definition, "over"), try self.scope(frame, with_carry));
        if (over != .array) return error.InvalidMapInput;
        const steps = try get(definition, "steps");
        var output: Value = .{ .array = std.array_list.Managed(Value).init(self.alloc) };
        var waiting = false;
        for (over.array.items, 0..) |item, index| {
            var visible: Value = .{ .object = try frame.steps.object.clone(self.alloc) };
            const inner: Frame = .{ .steps = &visible, .prefix = try std.fmt.allocPrint(self.alloc, "{s}[{d}]/", .{ path, index }), .item = item, .index = index, .nested = true };
            const result = self.settle(steps, &inner, iteration, with_carry) catch |err| {
                if (err != error.Pending) return err;
                waiting = true;
                continue;
            };
            try output.array.append(result);
        }
        if (waiting) return error.Pending;
        try self.complete(frame, id, path, iteration, over, output);
    }
    /// A composite completes once every branch or element has settled. Later steps
    /// read only its output: the inner frames are dropped here.
    fn complete(self: *State, frame: *const Frame, id: []const u8, path: []const u8, iteration: u32, input: ?Value, output: Value) !void {
        var attempt = object();
        try put(self.alloc, &attempt, "step_id", string(id));
        try put(self.alloc, &attempt, "path", string(path));
        try put(self.alloc, &attempt, "iteration", number(iteration));
        try put(self.alloc, &attempt, "status", string("completed"));
        if (input) |value| try put(self.alloc, &attempt, "input", value);
        try put(self.alloc, &attempt, "output", output);
        const attempts = self.record.object.getPtr("attempts").?;
        if (attempts.array.items.len >= 4096) return error.HistoryLimit;
        try attempts.array.append(attempt);
        var current = object();
        try put(self.alloc, &current, "output", output);
        try put(self.alloc, frame.steps, id, current);
        try self.save();
        self.failure_step = null;
    }
    fn execute(self: *State) !void {
        try self.ports.validateFn(self.ports.context, null, self.request.input);
        const steps = try get(self.request.manifest, "steps");
        if (steps != .array or steps.array.items.len == 0 or steps.array.items.len > 64) return error.InvalidDefinition;
        try put(self.alloc, &self.record, "status", string("running"));
        // Until this operation ends waiting for the agent again, the record is in flight.
        _ = self.record.object.swapRemove("awaiting_driver");
        try self.save();
        const top = self.root();
        if (self.request.manifest.object.get("repeat")) |repeat| {
            const from = try text(try get(repeat, "from"));
            const through = try text(try get(repeat, "through"));
            var first: ?usize = null;
            var last: ?usize = null;
            for (steps.array.items, 0..) |definition, i| {
                const id = try text(try get(definition, "id"));
                if (std.mem.eql(u8, from, id)) first = i;
                if (std.mem.eql(u8, through, id)) last = i;
            }
            if (first == null or last == null or first.? > last.?) return error.InvalidDefinition;
            for (steps.array.items[0..first.?]) |definition| try self.step(definition, &top, 0, false);
            const carry = repeat.object.get("carry");
            if (carry) |declaration| try self.setCarry(try get(declaration, "initial"), 1, false);
            const count = try get(repeat, "max_iterations");
            if (count != .integer or count.integer < 1) return error.InvalidDefinition;
            const limit = @min(@as(u64, @intCast(count.integer)), self.request.limits.max_iterations);
            var iteration: u32 = 1;
            while (true) : (iteration += 1) {
                for (steps.array.items[first.? .. last.? + 1]) |definition| _ = self.current.object.swapRemove(try text(try get(definition, "id")));
                try self.save();
                for (steps.array.items[first.? .. last.? + 1]) |definition| try self.step(definition, &top, iteration, carry != null);
                const ready = try resolve(self.alloc, try get(repeat, "until"), try self.scope(&top, carry != null));
                if (ready != .bool) return error.InvalidUntil;
                if (ready.bool) break;
                if (iteration >= limit) return error.IterationLimit;
                if (carry) |declaration| try self.setCarry(try get(declaration, "next"), iteration + 1, true);
            }
            for (steps.array.items[last.? + 1 ..]) |definition| try self.step(definition, &top, 0, false);
        } else for (steps.array.items) |definition| try self.step(definition, &top, 0, false);
        const output = try clone(self.alloc, try resolve(self.alloc, try get(self.request.manifest, "output"), try self.scope(&top, false)), self.request.limits.max_output_bytes);
        try put(self.alloc, &self.record, "output", output);
        try put(self.alloc, &self.record, "status", string("completed"));
        try self.save();
    }
    fn terminate(self: *State, err: anyerror) !void {
        const alloc = self.alloc;
        const stopped = stops(err);
        if (self.active_attempt) |index| try put(alloc, &self.record.object.getPtr("attempts").?.array.items[index], "status", string("uncertain"));
        _ = self.record.object.swapRemove("output");
        _ = self.record.object.swapRemove("awaiting_driver");
        try put(alloc, &self.record, "status", string(if (stopped) "stopped" else "failed"));
        if (self.failure_step) |id| try put(alloc, &self.record, "failure_step_id", string(id));
        var reason = object();
        try put(alloc, &reason, "reason", string(reasonCode(err)));
        // A static native error identifier, never exception prose or credentials.
        try put(alloc, &reason, "cause", string(@errorName(err)));
        try put(alloc, &self.record, if (stopped) "stop" else "error", reason);
        try self.save();
    }
    fn setCarry(self: *State, binding: Value, iteration: u32, with_carry: bool) !void {
        const top = self.root();
        // Agent driver: a transition the stored record already made is read back, not made twice.
        if (self.agent != null) for ((try get(self.record, "carry_history")).array.items) |made| {
            const pass = try get(made, "for_pass");
            if (pass != .integer or pass.integer != iteration) continue;
            self.carry = try get(made, "value");
            return put(self.alloc, &self.record, "carry", self.carry.?);
        };
        self.carry = try resolve(self.alloc, binding, try self.scope(&top, with_carry));
        try put(self.alloc, &self.record, "carry", self.carry.?);
        var transition = object();
        try put(self.alloc, &transition, "for_pass", number(iteration));
        try put(self.alloc, &transition, "value", self.carry.?);
        try self.record.object.getPtr("carry_history").?.array.append(transition);
        try self.save();
    }
};
fn counted(record: Value, key: []const u8) !u64 {
    const value = try get(record, key);
    if (value != .integer or value.integer < 0) return error.InvalidRunRecord;
    return @intCast(value.integer);
}
pub fn execute(allocator: std.mem.Allocator, request: Request, ports: Ports) !Run {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var owned = request;
    owned.manifest = try clone(alloc, request.manifest, 1048576);
    owned.input = try clone(alloc, request.input, request.limits.max_output_bytes);
    owned.selection = .{ .provider = try alloc.dupe(u8, request.selection.provider), .model = try alloc.dupe(u8, request.selection.model), .reasoning = try alloc.dupe(u8, request.selection.reasoning), .fast = request.selection.fast };
    var state: State = .{ .alloc = alloc, .request = owned, .ports = ports, .record = object(), .current = object(), .agent = request.agent };
    const prior: ?Value = if (request.agent) |agent| agent.record else null;
    if (prior) |stored| {
        // Continue an agent-driven run from its stored record, which holds the run's input.
        state.record = try clone(alloc, stored, request.limits.max_history_bytes);
        const driver = state.record.object.get("driver") orelse return error.NotAgentDriven;
        if (driver != .string or !std.mem.eql(u8, driver.string, "agent")) return error.NotAgentDriven;
        state.request.input = try get(state.record, "input");
        state.tokens = try counted(state.record, "used_tokens");
        state.operations = std.math.cast(u32, try counted(state.record, "used_operations")) orelse return error.InvalidRunRecord;
        state.tools = std.math.cast(u32, try counted(state.record, "used_tool_calls")) orelse return error.InvalidRunRecord;
        state.model_request_dispatches = std.math.cast(u32, try counted(state.record, "model_request_dispatches")) orelse return error.InvalidRunRecord;
    } else {
        if (request.agent) |agent| if (agent.op != .advance or agent.submission != null) return error.InvalidRequest;
        try put(alloc, &state.record, "format", string("fh.native-run/0.1"));
        try put(alloc, &state.record, "run_id", string(try alloc.dupe(u8, request.run_id)));
        try put(alloc, &state.record, "status", string("queued"));
        var selection = object();
        try put(alloc, &selection, "provider", string(owned.selection.provider));
        try put(alloc, &selection, "model", string(owned.selection.model));
        try put(alloc, &selection, "reasoning", string(owned.selection.reasoning));
        // Request policy only; this makes no assertion about delivered service tier.
        try put(alloc, &selection, "requestedFast", .{ .bool = owned.selection.fast });
        try put(alloc, &state.record, "selection", selection);
        try put(alloc, &state.record, "package_digest", string(try alloc.dupe(u8, request.package_digest)));
        try put(alloc, &state.record, "binding_digest", string(try alloc.dupe(u8, request.binding_digest)));
        for ([_]struct { key: []const u8, value: []const u8 }{
            .{ .key = "package_path", .value = request.package_path }, .{ .key = "bindings_id", .value = request.bindings_id },
            .{ .key = "input_source", .value = request.input_source }, .{ .key = "input_sha256", .value = request.input_sha256 },
        }) |item| try put(alloc, &state.record, item.key, string(try alloc.dupe(u8, item.value)));
        try put(alloc, &state.record, "case_id", if (request.case_id) |id| string(try alloc.dupe(u8, id)) else .null);
        try put(alloc, &state.record, "retry_of", if (request.retry_of) |id| string(try alloc.dupe(u8, id)) else .null);
        try put(alloc, &state.record, "root_input", owned.input);
        try put(alloc, &state.record, "attempts", .{ .array = std.array_list.Managed(Value).init(alloc) });
        try put(alloc, &state.record, "effects", .{ .array = std.array_list.Managed(Value).init(alloc) });
        try put(alloc, &state.record, "carry_history", .{ .array = std.array_list.Managed(Value).init(alloc) });
        if (request.agent) |agent| {
            try put(alloc, &state.record, "driver", string("agent"));
            try put(alloc, &state.record, "input", owned.input);
            try put(alloc, &state.record, "agent", try clone(alloc, agent.context, request.limits.max_diagnostic_bytes));
        }
        try state.save();
    }
    const status = try text(try get(state.record, "status"));
    // A terminal run is only read: nothing is ready and nothing more can settle.
    const live = std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "running");
    if (live) {
        if (prior != null and request.agent.?.op == .cancel) try state.terminate(error.Cancelled) else state.execute() catch |err| {
            if (err == error.Pending and state.agent != null) {
                try put(alloc, &state.record, "awaiting_driver", .{ .bool = true });
                try state.save();
            } else try state.terminate(err);
        };
    }
    var run: Run = .{ .arena = arena, .record = state.record, .ready = state.ready.items, .answer = state.answer, .refusal = state.refusal };
    if (request.agent) |agent| if (agent.submission) |submission| if (run.answer == null) {
        // Not ready now. A path and pass the agent already settled answers from what was committed.
        run.answer = .not_ready;
        if (try state.attempted(submission.path, submission.pass)) |attempt| if (attempt.object.get("submitted") != null) {
            const committed = try get(attempt, "output");
            if (submission.refusal == null and json_schema.equal(committed, submission.output)) run.answer = .accepted else {
                run.answer = .conflict;
                run.committed = committed;
            }
        };
    };
    return run;
}
pub fn reasonCode(err: anyerror) []const u8 {
    return switch (err) {
        error.DecisionKeyRequired => "decision_auth_required",
        error.UnsupportedDecisionProvider => "unsupported_decision_provider",
        error.InvalidDecisionPolicy => "invalid_decision_policy",
        error.DecisionHttpFailure => "decision_http_failed",
        error.InvalidDecisionResponse => "invalid_decision_response",
        error.Cancelled => "cancelled",
        error.TimeLimit => "time_limit",
        error.TokenLimit => "token_limit",
        error.ToolLimit => "tool_limit",
        error.OperationLimit => "operation_limit",
        error.IterationLimit => "iteration_limit",
        error.OutputLimit => "output_limit",
        error.HistoryLimit => "history_limit",
        error.UsageUnavailable => "usage_unavailable",
        error.UncertainEffect, error.CleanupPending => "uncertain_effect",
        error.InvalidInput => "invalid_input",
        error.InvalidOutput => "invalid_output",
        error.InvalidUntil => "invalid_until",
        error.MissingBinding => "missing_binding",
        error.InvalidMapInput => "invalid_map_input",
        error.InvalidBinding => "invalid_binding",
        error.CodeExit => "code_exit",
        error.InvalidJson => "invalid_json",
        error.ReceiptConflict => "receipt_conflict",
        else => "execution_failed",
    };
}

const Fixture = struct {
    passes: u32 = 0,
    prefix: u32 = 0,
    suffix: u32 = 0,
    saves: u32 = 0,
    cancelled: ?*std.atomic.Value(bool) = null,
    unknown_effect: bool = false,
    failure: ?anyerror = null,
    dispatch_before_failure: bool = false,
    returned_failure: ?anyerror = null,
    persisted_model_dispatches: i64 = -1,
    persisted_cause: bool = false,
    persisted_failure_cause: bool = false,
    journal_first: bool = false,
    fail_journal: bool = false,
    persisted_effect: bool = false,
    dispatches: usize = 0,
    fn now(_: *anyopaque) i64 {
        return 0;
    }
    fn validate(_: *anyopaque, _: ?[]const u8, _: Value) !void {}
    fn persist(raw: *anyopaque, value: Value, encoded: []const u8) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        const expected = try std.json.Stringify.valueAlloc(std.testing.allocator, value, .{});
        defer std.testing.allocator.free(expected);
        try std.testing.expectEqualStrings(expected, encoded);
        self.saves += 1;
        if (value.object.get("failure_cause")) |cause| self.persisted_failure_cause = std.mem.eql(u8, cause.string, "NativeProviderLoginRequired");
        self.persisted_model_dispatches = (try get(value, "model_request_dispatches")).integer;
        if (value.object.get("effects")) |effects| if (effects.array.items.len != 0) {
            if (self.fail_journal) return error.FixtureStorageFailure;
            self.persisted_effect = true;
        };
        if (value.object.get("error")) |failure| if (failure.object.get("cause")) |cause| {
            self.persisted_cause = std.mem.eql(u8, cause.string, "NativeDispatchFixtureFailure");
        };
    }
    fn executeStep(raw: *anyopaque, alloc: std.mem.Allocator, request: StepRequest) !StepResult {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.dispatch_before_failure) request.model_dispatch.?.record();
        if (self.failure) |failure| return failure;
        if (self.returned_failure) |failure| return .{ .failure = failure };
        if (self.journal_first) {
            try request.journal.record(.{ .id = "physical", .kind = "code_container", .state = .unknown });
            try std.testing.expect(self.persisted_effect);
            self.dispatches += 1;
            try request.journal.record(.{ .id = "physical", .kind = "code_container", .state = .applied });
        }
        if (self.cancelled) |flag| {
            try request.journal.record(.{ .id = "external", .state = .unknown });
            flag.store(true, .release);
        }
        if (self.unknown_effect) try request.journal.record(.{ .id = "unsettled", .state = .unknown });
        var result = request.input;
        if (std.mem.eql(u8, request.step_id, "prefix")) self.prefix += 1;
        if (std.mem.eql(u8, request.step_id, "suffix")) self.suffix += 1;
        if (std.mem.eql(u8, request.step_id, "produce")) {
            self.passes += 1;
            const scope = request.input;
            try std.testing.expect((try get(scope, "steps")).object.get("produce") == null);
            const carry = try get(scope, "carry");
            if (request.iteration == 1) try std.testing.expect((try get(carry, "prior")) == .null) else try std.testing.expectEqualStrings("A", try text(try get(carry, "prior")));
            result = object();
            try put(alloc, &result, "item", string(if (request.iteration == 1) "A" else "B"));
        }
        if (std.mem.eql(u8, request.step_id, "judge")) {
            result = object();
            try put(alloc, &result, "ready", .{ .bool = request.iteration >= 2 });
            try put(alloc, &result, "note", string(if (request.iteration == 1) "change" else "ok"));
        }
        return .{ .output = result, .usage = .{ .input_tokens = 2, .output_tokens = 3 } };
    }
    fn ports(self: *Fixture) Ports {
        return .{ .context = self, .executeFn = executeStep, .validateFn = validate, .persistFn = persist, .nowFn = now };
    }
};
test "native pre-dispatch failure persists its safe cause without claiming token usage" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"steps\":[{\"id\":\"single\",\"kind\":\"infer\",\"input\":{\"value\":false}}],\"output\":{\"from\":\"/steps/single/output\"}}", .{});
    defer parsed.deinit();
    var fixture: Fixture = .{ .failure = error.NativeDispatchFixtureFailure };
    var cancel = std.atomic.Value(bool).init(false);
    var run = try execute(std.testing.allocator, .{ .run_id = "dispatch-failure", .manifest = parsed.value, .input = .null, .cancel = &cancel, .deadline_ms = 1000 }, fixture.ports());
    defer run.deinit();
    try std.testing.expectEqualStrings("failed", try text(try get(run.record, "status")));
    const failure = try get(run.record, "error");
    try std.testing.expectEqualStrings("execution_failed", try text(try get(failure, "reason")));
    try std.testing.expectEqualStrings("NativeDispatchFixtureFailure", try text(try get(failure, "cause")));
    try std.testing.expect(fixture.persisted_cause);
    try std.testing.expectEqual(@as(i64, 0), (try get(run.record, "used_tokens")).integer);
    try std.testing.expectEqual(@as(i64, 0), (try get(run.record, "model_request_dispatches")).integer);
    try std.testing.expectEqual(false, (try get(run.record, "usage_unknown")).bool);
    try std.testing.expect(run.record.object.get("output") == null);
}
test "native failed dispatched request counts once without claiming measured usage" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"steps\":[{\"id\":\"single\",\"kind\":\"infer\",\"input\":{\"value\":false}}],\"output\":{\"from\":\"/steps/single/output\"}}", .{});
    defer parsed.deinit();
    var fixture: Fixture = .{ .failure = error.NativeDispatchFixtureFailure, .dispatch_before_failure = true };
    var cancel = std.atomic.Value(bool).init(false);
    var run = try execute(std.testing.allocator, .{ .run_id = "failed-call", .manifest = parsed.value, .input = .null, .cancel = &cancel, .deadline_ms = 1000 }, fixture.ports());
    defer run.deinit();
    try std.testing.expectEqualStrings("failed", try text(try get(run.record, "status")));
    try std.testing.expectEqual(@as(i64, 1), (try get(run.record, "model_request_dispatches")).integer);
    try std.testing.expectEqual(@as(i64, 1), fixture.persisted_model_dispatches);
    try std.testing.expectEqual(@as(i64, 0), (try get(run.record, "used_tokens")).integer);
}
test "native returned provider failure preserves cause with unknown usage and one dispatch" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"steps\":[{\"id\":\"single\",\"kind\":\"infer\",\"input\":null}],\"output\":{\"from\":\"/steps/single/output\"}}", .{});
    defer parsed.deinit();
    var fixture: Fixture = .{ .returned_failure = error.NativeProviderLoginRequired, .dispatch_before_failure = true };
    var cancel = std.atomic.Value(bool).init(false);
    var run = try execute(std.testing.allocator, .{ .run_id = "rejected-call", .manifest = parsed.value, .input = .null, .cancel = &cancel, .deadline_ms = 1000 }, fixture.ports());
    defer run.deinit();
    try std.testing.expectEqualStrings("stopped", try text(try get(run.record, "status")));
    const stop = try get(run.record, "stop");
    try std.testing.expectEqualStrings("usage_unavailable", try text(try get(stop, "reason")));
    try std.testing.expectEqualStrings("UsageUnavailable", try text(try get(stop, "cause")));
    try std.testing.expect((try get(run.record, "usage_unknown")).bool);
    try std.testing.expectEqual(@as(i64, 0), (try get(run.record, "used_tokens")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try get(run.record, "model_request_dispatches")).integer);
    try std.testing.expectEqual(@as(i64, 1), fixture.persisted_model_dispatches);
    try std.testing.expect(run.record.object.get("output") == null);
    try std.testing.expectEqualStrings("NativeProviderLoginRequired", try text(try get(run.record, "failure_cause")));
    try std.testing.expect(fixture.persisted_failure_cause);
}
test "native bindings preserve RFC6901 escaping, literal data and missing values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const scope = (try std.json.parseFromSlice(Value, alloc, "{\"input\":{\"a/b\":false,\"~1\":0,\"\":null,\"wrapped\":{\"from\":\"/absent\"}}}", .{})).value;
    const binding = (try std.json.parseFromSlice(Value, alloc, "{\"slash\":{\"from\":\"/input/a~1b\"},\"tilde\":{\"from\":\"/input/~01\"},\"empty\":{\"from\":\"/input/\"},\"literal\":{\"value\":{\"from\":\"/absent\"}},\"opaque\":{\"from\":\"/input/wrapped\"}}", .{})).value;
    const result = try resolve(alloc, binding, scope);
    try std.testing.expectEqual(false, (try get(result, "slash")).bool);
    try std.testing.expectEqual(@as(i64, 0), (try get(result, "tilde")).integer);
    try std.testing.expect((try get(result, "empty")) == .null);
    try std.testing.expectEqualStrings("/absent", try text(try get(try get(result, "opaque"), "from")));
    const missing = (try std.json.parseFromSlice(Value, alloc, "{\"from\":\"/input/missing\"}", .{})).value;
    try std.testing.expectError(error.MissingBinding, resolve(alloc, missing, scope));
}
const carry_manifest =
    \\{"format":"loops/0.1","name":"feedback","version":"1","steps":[{"id":"prefix","kind":"code","input":{"value":{"label":"P"}}},{"id":"produce","kind":"infer","input":{"from":""}},{"id":"judge","kind":"code","input":{"item":{"from":"/steps/produce/output/item"},"carry":{"from":"/carry"}}},{"id":"suffix","kind":"code","input":{"item":{"from":"/steps/produce/output/item"},"assessment":{"from":"/steps/judge/output"}}}],"repeat":{"from":"produce","through":"judge","until":{"from":"/steps/judge/output/ready"},"max_iterations":3,"carry":{"initial":{"value":{"prior":null,"note":""}},"next":{"prior":{"from":"/steps/produce/output/item"},"note":{"from":"/steps/judge/output/note"}}}},"output":{"from":"/steps/suffix/output"}}
;
test "native carry exact feedback survives two passes, clears stale region and runs suffix once" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, carry_manifest, .{});
    defer parsed.deinit();
    var fixture: Fixture = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var run = try execute(std.testing.allocator, .{ .run_id = "carry", .manifest = parsed.value, .input = .null, .selection = .{ .provider = "grok", .model = "grok-4", .reasoning = "low", .fast = false }, .cancel = &cancelled, .deadline_ms = 1000 }, fixture.ports());
    defer run.deinit();
    try std.testing.expectEqualStrings("completed", try text(try get(run.record, "status")));
    try std.testing.expectEqual(@as(u32, 2), fixture.passes);
    try std.testing.expectEqual(@as(u32, 1), fixture.prefix);
    try std.testing.expectEqual(@as(u32, 1), fixture.suffix);
    try std.testing.expectEqualStrings("B", try text(try get(try get(run.record, "output"), "item")));
    try std.testing.expectEqual(@as(i64, 10), (try get(run.record, "used_tokens")).integer);
    const selected = try get(run.record, "selection");
    try std.testing.expectEqualStrings("grok", try text(try get(selected, "provider")));
    try std.testing.expectEqualStrings("grok-4", try text(try get(selected, "model")));
    try std.testing.expectEqualStrings("low", try text(try get(selected, "reasoning")));
    try std.testing.expectEqual(false, (try get(selected, "requestedFast")).bool);
}
test "native exhaustion skips next and suffix; cancellation retains unknown effects without output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var manifest = (try std.json.parseFromSlice(Value, alloc, carry_manifest, .{})).value;
    manifest.object.getPtr("repeat").?.object.getPtr("max_iterations").?.* = .{ .integer = 1 };
    manifest.object.getPtr("repeat").?.object.getPtr("carry").?.object.getPtr("next").?.* = (try std.json.parseFromSlice(Value, alloc, "{\"from\":\"/input/absent\"}", .{})).value;
    var fixture: Fixture = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var exhausted = try execute(std.testing.allocator, .{ .run_id = "exhaust", .manifest = manifest, .input = .null, .cancel = &cancelled, .deadline_ms = 1000 }, fixture.ports());
    defer exhausted.deinit();
    try std.testing.expectEqualStrings("stopped", try text(try get(exhausted.record, "status")));
    try std.testing.expectEqualStrings("iteration_limit", try text(try get(try get(exhausted.record, "stop"), "reason")));
    try std.testing.expectEqual(@as(u32, 0), fixture.suffix);
    fixture = .{ .cancelled = &cancelled };
    cancelled.store(false, .release);
    var stopped = try execute(std.testing.allocator, .{ .run_id = "cancel", .manifest = manifest, .input = .null, .cancel = &cancelled, .deadline_ms = 1000 }, fixture.ports());
    defer stopped.deinit();
    try std.testing.expect(stopped.record.object.get("output") == null);
    try std.testing.expectEqualStrings("unknown", try text(try get((try get(stopped.record, "effects")).array.items[0], "state")));
}

test "native final inference settles measured tokens before budget stop and rejects unknown effects" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"steps\":[{\"id\":\"single\",\"kind\":\"infer\",\"input\":{\"value\":false}}],\"output\":{\"from\":\"/steps/single/output\"}}", .{});
    defer parsed.deinit();
    var fixture: Fixture = .{};
    var cancel = std.atomic.Value(bool).init(false);
    var over = try execute(std.testing.allocator, .{ .run_id = "over", .manifest = parsed.value, .input = .null, .cancel = &cancel, .deadline_ms = 1000, .limits = .{ .max_tokens = 4 } }, fixture.ports());
    defer over.deinit();
    try std.testing.expectEqualStrings("token_limit", try text(try get(try get(over.record, "stop"), "reason")));
    try std.testing.expectEqual(@as(i64, 5), (try get(over.record, "used_tokens")).integer);
    try std.testing.expect(over.record.object.get("output") == null);
    var equal = try execute(std.testing.allocator, .{ .run_id = "equal", .manifest = parsed.value, .input = .null, .cancel = &cancel, .deadline_ms = 1000, .limits = .{ .max_tokens = 5 } }, fixture.ports());
    defer equal.deinit();
    try std.testing.expectEqualStrings("completed", try text(try get(equal.record, "status")));
    fixture.unknown_effect = true;
    var uncertain = try execute(std.testing.allocator, .{ .run_id = "uncertain", .manifest = parsed.value, .input = .null, .cancel = &cancel, .deadline_ms = 1000 }, fixture.ports());
    defer uncertain.deinit();
    try std.testing.expectEqualStrings("uncertain_effect", try text(try get(try get(uncertain.record, "stop"), "reason")));
    try std.testing.expect(uncertain.record.object.get("output") == null);
}

test "native encoded persistence preserves limits injected failures and effects before dispatch" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"steps\":[{\"id\":\"single\",\"kind\":\"infer\",\"input\":{\"value\":false}}],\"output\":{\"from\":\"/steps/single/output\"}}", .{});
    defer parsed.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var fixture: Fixture = .{ .journal_first = true };
    var request: Request = .{ .run_id = "encoded", .manifest = parsed.value, .input = .null, .cancel = &cancel, .deadline_ms = 1000, .limits = .{ .max_history_bytes = 1 } };
    try std.testing.expectError(error.HistoryLimit, execute(std.testing.allocator, request, fixture.ports()));
    try std.testing.expectEqual(@as(u32, 0), fixture.saves);
    try std.testing.expectEqual(@as(usize, 0), fixture.dispatches);
    request.limits.max_history_bytes = 16 * 1048576;
    fixture.fail_journal = true;
    try std.testing.expectError(error.FixtureStorageFailure, execute(std.testing.allocator, request, fixture.ports()));
    try std.testing.expectEqual(@as(usize, 0), fixture.dispatches);
    fixture.fail_journal = false;
    var run = try execute(std.testing.allocator, request, fixture.ports());
    defer run.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.dispatches);
    try std.testing.expectEqualStrings("completed", try text(try get(run.record, "status")));
}

test "native failure step attribution identifies binding failure before next attempt" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"steps\":[{\"id\":\"prefix\",\"kind\":\"code\",\"input\":{\"value\":1}},{\"id\":\"next\",\"kind\":\"code\",\"input\":{\"from\":\"/input/missing\"}}],\"output\":{\"from\":\"/steps/next/output\"}}", .{});
    defer parsed.deinit();
    var fixture: Fixture = .{};
    var cancel_flag = std.atomic.Value(bool).init(false);
    var run = try execute(std.testing.allocator, .{ .run_id = "failure_step", .manifest = parsed.value, .input = object(), .cancel = &cancel_flag, .deadline_ms = 1000 }, fixture.ports());
    defer run.deinit();
    try std.testing.expectEqualStrings("failed", try text(try get(run.record, "status")));
    try std.testing.expectEqualStrings("next", try text(try get(run.record, "failure_step_id")));
    try std.testing.expectEqual(@as(usize, 1), (try get(run.record, "attempts")).array.items.len);
    const diagnostic = try @import("../run_diagnostics.zig").diagnostic(run.arena.allocator(), run.record);
    try std.testing.expectEqualStrings("next", try text(try get(diagnostic, "step_id")));
    try std.testing.expectEqualStrings("MissingBinding", try text(try get(diagnostic, "cause")));
}

const Composite = struct {
    cancel: *std.atomic.Value(bool),
    paths: std.ArrayList([]const u8) = .empty,
    fn now(_: *anyopaque) i64 {
        return 0;
    }
    fn validate(_: *anyopaque, _: ?[]const u8, _: Value) !void {}
    fn persist(_: *anyopaque, _: Value, _: []const u8) !void {}
    fn executeStep(raw: *anyopaque, _: std.mem.Allocator, request: StepRequest) !StepResult {
        const self: *Composite = @ptrCast(@alignCast(raw));
        try self.paths.append(std.testing.allocator, try std.testing.allocator.dupe(u8, request.path));
        if (std.mem.eql(u8, request.step_id, "boom")) return error.CodeExit;
        if (std.mem.eql(u8, request.step_id, "halt")) self.cancel.store(true, .release);
        if (std.mem.eql(u8, request.step_id, "leak")) {
            try request.journal.record(.{ .id = "leak", .state = .unknown });
            return error.CodeExit;
        }
        return .{ .output = request.input };
    }
    fn run(self: *Composite, manifest: []const u8, input: []const u8) !Run {
        const steps = try std.json.parseFromSlice(Value, std.testing.allocator, manifest, .{});
        defer steps.deinit();
        const bound = try std.json.parseFromSlice(Value, std.testing.allocator, input, .{});
        defer bound.deinit();
        return execute(std.testing.allocator, .{ .run_id = "composite", .manifest = steps.value, .input = bound.value, .cancel = self.cancel, .deadline_ms = 1000 }, .{ .context = self, .executeFn = executeStep, .validateFn = validate, .persistFn = persist, .nowFn = now });
    }
    fn deinit(self: *Composite) void {
        for (self.paths.items) |path| std.testing.allocator.free(path);
        self.paths.deinit(std.testing.allocator);
    }
};
fn at(value: Value, comptime path: []const u8) !Value {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return pointer(arena.allocator(), path, value);
}
const nested_manifest =
    \\{"steps":[{"id":"outer","kind":"map","over":{"from":"/input/rows"},"steps":[{"id":"fan","kind":"parallel","branches":{
    \\"x":[{"id":"first","kind":"code","input":{"row":{"from":"/item"},"at":{"from":"/index"}}},{"id":"second","kind":"code","input":{"from":"/steps/first/output/at"}}],
    \\"y":[{"id":"inner","kind":"map","over":{"from":"/item"},"steps":[{"id":"cell","kind":"code","input":{"cell":{"from":"/item"},"at":{"from":"/index"}}}]}]}}]},
    \\{"id":"after","kind":"code","input":{"from":"AFTER"}}],"output":{"from":"/steps/after/output"}}
;
test "native composites nest with paths, item and index scope, own element instances and hidden inner outputs" {
    var cancel = std.atomic.Value(bool).init(false);
    var fixture: Composite = .{ .cancel = &cancel };
    defer fixture.deinit();
    const manifest = try std.mem.replaceOwned(u8, std.testing.allocator, nested_manifest, "AFTER", "/steps/outer/output");
    defer std.testing.allocator.free(manifest);
    var run = try fixture.run(manifest, "{\"rows\":[[10],[20,30]]}");
    defer run.deinit();
    try std.testing.expectEqualStrings("completed", try text(try get(run.record, "status")));
    const expected = [_][]const u8{ "outer[0]/fan/x/first", "outer[0]/fan/x/second", "outer[0]/fan/y/inner[0]/cell", "outer[1]/fan/x/first", "outer[1]/fan/x/second", "outer[1]/fan/y/inner[0]/cell", "outer[1]/fan/y/inner[1]/cell", "after" };
    try std.testing.expectEqual(expected.len, fixture.paths.items.len);
    for (expected, fixture.paths.items) |want, got| try std.testing.expectEqualStrings(want, got);
    const output = try get(run.record, "output");
    // Element 1 reads its own `first`, not element 0's; the inner map's /item and /index shadow the outer ones.
    try std.testing.expectEqual(@as(i64, 1), (try at(output, "/1/output/x/output")).integer);
    try std.testing.expectEqual(@as(i64, 30), (try at(output, "/1/output/y/output/1/output/cell")).integer);
    try std.testing.expectEqual(@as(i64, 1), (try at(output, "/1/output/y/output/1/output/at")).integer);
    // Attempts name positions; a composite follows its children.
    const attempts = (try get(run.record, "attempts")).array.items;
    try std.testing.expectEqualStrings("outer[0]/fan/y/inner", try text(try get(attempts[3], "path")));
    try std.testing.expectEqualStrings("outer[0]/fan", try text(try get(attempts[4], "path")));
    try std.testing.expectEqualStrings("outer", try text(try get(attempts[attempts.len - 2], "path")));
    // The top-level record never holds an inner step.
    try std.testing.expectEqual(@as(usize, 2), (try get(run.record, "current")).object.count());

    var hidden_fixture: Composite = .{ .cancel = &cancel };
    defer hidden_fixture.deinit();
    const hidden_manifest = try std.mem.replaceOwned(u8, std.testing.allocator, nested_manifest, "AFTER", "/steps/first/output");
    defer std.testing.allocator.free(hidden_manifest);
    var hidden = try hidden_fixture.run(hidden_manifest, "{\"rows\":[[10]]}");
    defer hidden.deinit();
    try std.testing.expectEqualStrings("failed", try text(try get(hidden.record, "status")));
    try std.testing.expectEqualStrings("missing_binding", try text(try get(try get(hidden.record, "error"), "reason")));
}
test "native branch failures settle in the composite while a run-level stop inside a branch stops the run" {
    var cancel = std.atomic.Value(bool).init(false);
    var fixture: Composite = .{ .cancel = &cancel };
    defer fixture.deinit();
    var run = try fixture.run(
        \\{"steps":[{"id":"pair","kind":"parallel","branches":{
        \\"a":[{"id":"bad","kind":"map","over":{"value":3},"steps":[{"id":"never","kind":"code","input":{}}]}],
        \\"b":[{"id":"boom","kind":"code","input":{}},{"id":"skipped","kind":"code","input":{}}],
        \\"c":[{"id":"fine","kind":"code","input":{"value":7}}]}}],"output":{"from":"/steps/pair/output"}}
    , "null");
    defer run.deinit();
    try std.testing.expectEqualStrings("completed", try text(try get(run.record, "status")));
    const output = try get(run.record, "output");
    try std.testing.expectEqualStrings("invalid_map_input", try text(try at(output, "/a/error/reason")));
    try std.testing.expectEqualStrings("code_exit", try text(try at(output, "/b/error/reason")));
    try std.testing.expectEqual(@as(i64, 7), (try at(output, "/c/output")).integer);
    try std.testing.expectEqual(@as(usize, 2), fixture.paths.items.len);
    const attempts = (try get(run.record, "attempts")).array.items;
    try std.testing.expectEqualStrings("pair/b/boom", try text(try get(attempts[0], "path")));
    try std.testing.expectEqualStrings("failed", try text(try get(attempts[0], "status")));
    try std.testing.expectEqualStrings("code_exit", try text(try at(attempts[0], "/error/reason")));
    try std.testing.expect(run.record.object.get("failure_cause") == null);

    var stopping: Composite = .{ .cancel = &cancel };
    defer stopping.deinit();
    var stopped = try stopping.run(
        \\{"steps":[{"id":"pair","kind":"parallel","branches":{
        \\"a":[{"id":"halt","kind":"code","input":{}}],
        \\"b":[{"id":"later","kind":"code","input":{}}]}}],"output":{"from":"/steps/pair/output"}}
    , "null");
    defer stopped.deinit();
    try std.testing.expectEqualStrings("stopped", try text(try get(stopped.record, "status")));
    try std.testing.expectEqualStrings("cancelled", try text(try get(try get(stopped.record, "stop"), "reason")));
    try std.testing.expectEqual(@as(usize, 1), stopping.paths.items.len);
    for ((try get(stopped.record, "attempts")).array.items) |attempt| try std.testing.expect(!std.mem.eql(u8, "pair", try text(try get(attempt, "path"))));
    try std.testing.expect(stopped.record.object.get("output") == null);

    cancel.store(false, .release);
    var leaking: Composite = .{ .cancel = &cancel };
    defer leaking.deinit();
    var uncertain = try leaking.run(
        \\{"steps":[{"id":"each","kind":"map","over":{"value":[1,2]},"steps":[{"id":"leak","kind":"code","input":{}}]}],"output":{"from":"/steps/each/output"}}
    , "null");
    defer uncertain.deinit();
    try std.testing.expectEqualStrings("stopped", try text(try get(uncertain.record, "status")));
    try std.testing.expectEqualStrings("uncertain_effect", try text(try get(try get(uncertain.record, "stop"), "reason")));
    try std.testing.expectEqual(@as(usize, 1), leaking.paths.items.len);
}

fn agentOp(fixture: *Composite, manifest: Value, agent: Agent, limits: Limits) !Run {
    return execute(std.testing.allocator, .{ .run_id = "agent", .manifest = manifest, .input = .null, .cancel = fixture.cancel, .deadline_ms = 1000, .limits = limits, .agent = agent }, .{ .context = fixture, .executeFn = Composite.executeStep, .validateFn = Composite.validate, .persistFn = Composite.persist, .nowFn = Composite.now });
}
test "native agent driver hands out every ready map element, runs code once across operations and makes no model call" {
    var cancel = std.atomic.Value(bool).init(false);
    var fixture: Composite = .{ .cancel = &cancel };
    defer fixture.deinit();
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator,
        \\{"steps":[{"id":"each","kind":"map","over":{"value":[1,2]},"steps":[{"id":"ask","kind":"infer","input":{"from":"/item"}},{"id":"boom","kind":"code","input":{"from":"/steps/ask/output"}}]},
        \\{"id":"after","kind":"decision","input":{"from":"/steps/each/output"}}],"output":{"from":"/steps/after/output"}}
    , .{});
    defer parsed.deinit();
    var started = try agentOp(&fixture, parsed.value, .{ .context = .{ .string = "where" } }, .{});
    defer started.deinit();
    try std.testing.expectEqualStrings("running", try text(try get(started.record, "status")));
    try std.testing.expect((try get(started.record, "awaiting_driver")).bool);
    try std.testing.expectEqualStrings("agent", try text(try get(started.record, "driver")));
    try std.testing.expectEqualStrings("where", try text(try get(started.record, "agent")));
    try std.testing.expectEqual(@as(usize, 2), started.ready.len);
    try std.testing.expectEqualStrings("each[0]/ask", started.ready[0].path);
    try std.testing.expectEqualStrings("each[1]/ask", started.ready[1].path);
    try std.testing.expectEqual(@as(i64, 2), started.ready[1].input.integer);
    try std.testing.expectEqual(@as(usize, 0), fixture.paths.items.len);

    // The second element first: its code runs and fails, and that settles only its element.
    var second = try agentOp(&fixture, parsed.value, .{ .record = started.record, .submission = .{ .path = "each[1]/ask", .pass = 0, .output = .{ .integer = 20 } } }, .{});
    defer second.deinit();
    try std.testing.expectEqual(Answer.accepted, second.answer.?);
    try std.testing.expectEqual(@as(usize, 1), second.ready.len);
    try std.testing.expectEqualStrings("each[0]/ask", second.ready[0].path);
    var first = try agentOp(&fixture, parsed.value, .{ .record = second.record, .submission = .{ .path = "each[0]/ask", .pass = 0, .output = .{ .integer = 10 } } }, .{});
    defer first.deinit();
    try std.testing.expectEqual(Answer.accepted, first.answer.?);
    try std.testing.expectEqual(@as(usize, 1), first.ready.len);
    try std.testing.expectEqualStrings("after", first.ready[0].path);
    try std.testing.expectEqualStrings("decision", first.ready[0].kind);
    try std.testing.expectEqualStrings("code_exit", try text(try at(first.ready[0].input, "/1/error/reason")));
    // Reading again changes nothing and runs nothing.
    var peeked = try agentOp(&fixture, parsed.value, .{ .record = first.record, .op = .peek }, .{});
    defer peeked.deinit();
    try std.testing.expectEqualStrings("after", peeked.ready[0].path);
    var done = try agentOp(&fixture, parsed.value, .{ .record = first.record, .submission = .{ .path = "after", .pass = 0, .output = .{ .bool = true } } }, .{});
    defer done.deinit();
    try std.testing.expectEqualStrings("completed", try text(try get(done.record, "status")));
    try std.testing.expect(done.record.object.get("awaiting_driver") == null);
    try std.testing.expect((try get(done.record, "output")).bool);
    try std.testing.expectEqual(@as(usize, 0), done.ready.len);
    // Each failing code step ran exactly once, however many operations replayed its branch.
    try std.testing.expectEqual(@as(usize, 2), fixture.paths.items.len);
    try std.testing.expectEqualStrings("each[1]/boom", fixture.paths.items[0]);
    try std.testing.expectEqualStrings("each[0]/boom", fixture.paths.items[1]);
    try std.testing.expectEqual(@as(i64, 0), (try get(done.record, "used_tokens")).integer);
    try std.testing.expectEqual(@as(i64, 0), (try get(done.record, "model_request_dispatches")).integer);
    // A finished run is never cancelled into another state.
    var late = try agentOp(&fixture, parsed.value, .{ .record = done.record, .op = .cancel }, .{});
    defer late.deinit();
    try std.testing.expectEqualStrings("completed", try text(try get(late.record, "status")));
}
test "native agent driver keeps the operation limit across operations and refuses a runner-driven record" {
    var cancel = std.atomic.Value(bool).init(false);
    var fixture: Composite = .{ .cancel = &cancel };
    defer fixture.deinit();
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"steps\":[{\"id\":\"one\",\"kind\":\"infer\",\"input\":{}},{\"id\":\"two\",\"kind\":\"infer\",\"input\":{}}],\"output\":{\"from\":\"/steps/two/output\"}}", .{});
    defer parsed.deinit();
    var started = try agentOp(&fixture, parsed.value, .{}, .{ .max_operations = 1 });
    defer started.deinit();
    var stopped = try agentOp(&fixture, parsed.value, .{ .record = started.record, .submission = .{ .path = "one", .pass = 0, .output = .null } }, .{ .max_operations = 1 });
    defer stopped.deinit();
    try std.testing.expectEqual(Answer.accepted, stopped.answer.?);
    try std.testing.expectEqualStrings("stopped", try text(try get(stopped.record, "status")));
    try std.testing.expectEqualStrings("operation_limit", try text(try get(try get(stopped.record, "stop"), "reason")));
    try std.testing.expectEqual(@as(usize, 0), stopped.ready.len);

    var plain = try fixture.run("{\"steps\":[{\"id\":\"only\",\"kind\":\"code\",\"input\":{}}],\"output\":{\"from\":\"/steps/only/output\"}}", "null");
    defer plain.deinit();
    try std.testing.expectError(error.NotAgentDriven, agentOp(&fixture, parsed.value, .{ .record = plain.record, .op = .peek }, .{}));
}
test "native agent driver settles a parallel in either submission order at the operation limit" {
    var cancel = std.atomic.Value(bool).init(false);
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"steps\":[{\"id\":\"pair\",\"kind\":\"parallel\",\"branches\":{\"a\":[{\"id\":\"one\",\"kind\":\"infer\",\"input\":{}}],\"b\":[{\"id\":\"two\",\"kind\":\"infer\",\"input\":{}}]}}],\"output\":{\"from\":\"/steps/pair/output\"}}", .{});
    defer parsed.deinit();
    for ([_][2][]const u8{ .{ "pair/a/one", "pair/b/two" }, .{ "pair/b/two", "pair/a/one" } }) |order| {
        var fixture: Composite = .{ .cancel = &cancel };
        defer fixture.deinit();
        var started = try agentOp(&fixture, parsed.value, .{}, .{ .max_operations = 2 });
        defer started.deinit();
        var first = try agentOp(&fixture, parsed.value, .{ .record = started.record, .submission = .{ .path = order[0], .pass = 0, .output = .{ .integer = 1 } } }, .{ .max_operations = 2 });
        defer first.deinit();
        try std.testing.expectEqual(Answer.accepted, first.answer.?);
        var second = try agentOp(&fixture, parsed.value, .{ .record = first.record, .submission = .{ .path = order[1], .pass = 0, .output = .{ .integer = 2 } } }, .{ .max_operations = 2 });
        defer second.deinit();
        try std.testing.expectEqual(Answer.accepted, second.answer.?);
        try std.testing.expectEqualStrings("completed", try text(try get(second.record, "status")));
        try std.testing.expectEqual(@as(i64, 2), (try get(second.record, "used_operations")).integer);
    }
    // A position being read back still stops for a cancelled run.
    var fixture: Composite = .{ .cancel = &cancel };
    defer fixture.deinit();
    var started = try agentOp(&fixture, parsed.value, .{}, .{});
    defer started.deinit();
    var first = try agentOp(&fixture, parsed.value, .{ .record = started.record, .submission = .{ .path = "pair/a/one", .pass = 0, .output = .null } }, .{});
    defer first.deinit();
    cancel.store(true, .release);
    var stopped = try agentOp(&fixture, parsed.value, .{ .record = first.record, .submission = .{ .path = "pair/b/two", .pass = 0, .output = .null } }, .{});
    defer stopped.deinit();
    try std.testing.expectEqualStrings("cancelled", try text(try get(try get(stopped.record, "stop"), "reason")));
    try std.testing.expectEqual(Answer.not_ready, stopped.answer.?);
}
test "native agent driver rejects a submission over the output limit without stopping the run or counting an operation" {
    var cancel = std.atomic.Value(bool).init(false);
    var fixture: Composite = .{ .cancel = &cancel };
    defer fixture.deinit();
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"steps\":[{\"id\":\"one\",\"kind\":\"infer\",\"input\":{}}],\"output\":{\"from\":\"/steps/one/output\"}}", .{});
    defer parsed.deinit();
    var started = try agentOp(&fixture, parsed.value, .{}, .{ .max_output_bytes = 16 });
    defer started.deinit();
    var refused = try agentOp(&fixture, parsed.value, .{ .record = started.record, .submission = .{ .path = "one", .pass = 0, .output = .{ .string = "x" ** 40 } } }, .{ .max_output_bytes = 16 });
    defer refused.deinit();
    try std.testing.expectEqual(Answer.rejected, refused.answer.?);
    try std.testing.expectEqualStrings("running", try text(try get(refused.record, "status")));
    try std.testing.expect((try get(refused.record, "awaiting_driver")).bool);
    try std.testing.expectEqual(@as(i64, 0), (try get(refused.record, "used_operations")).integer);
    try std.testing.expectEqual(@as(usize, 1), refused.ready.len);
    try std.testing.expectEqual(@as(usize, 0), (try get(refused.record, "attempts")).array.items.len);
    var accepted = try agentOp(&fixture, parsed.value, .{ .record = refused.record, .submission = .{ .path = "one", .pass = 0, .output = .{ .string = "ok" } } }, .{ .max_output_bytes = 16 });
    defer accepted.deinit();
    try std.testing.expectEqual(Answer.accepted, accepted.answer.?);
    try std.testing.expectEqualStrings("completed", try text(try get(accepted.record, "status")));
}
