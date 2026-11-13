//! One native, bounded evaluation at the official TypeSafe endpoint.
const std = @import("std");
const runner = @import("runner.zig");
const package = @import("package.zig");
const bindings = @import("bindings.zig");
const schema = @import("schema.zig");
const types = @import("decision_types.zig");
const io_mod = @import("../../vendor/fx/src/core/shared/io.zig");
const gateway = @import("../../vendor/fx/src/gateway/client.zig");
const http_pool = @import("../../vendor/fx/src/core/shared/http_pool.zig");
const Allocator = std.mem.Allocator;
const Value = runner.Value;
pub const endpoint = "https://api.typesafe.ai/v1/systemone";
pub const TransportRequest = struct { body: []const u8, key: []const u8, cancel: *const std.atomic.Value(bool), deadline_ms: i64, max_output_bytes: usize };
pub const Response = struct { status: u16, body: []u8 };
pub const Context = struct {
    transport_scope: ?*http_pool.Scope = null,
    context: ?*anyopaque = null,
    secretFn: ?*const fn (*anyopaque, Allocator, []const u8) anyerror!?[]u8 = null,
    transportFn: ?*const fn (*anyopaque, Allocator, TransportRequest) anyerror!Response = null,
    nowFn: ?*const fn (*anyopaque) i64 = null,
    fn now(self: *Context) i64 {
        return if (self.nowFn) |f| f(self.context.?) else std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds();
    }
};
pub const Policy = struct { model: []const u8 = "jev-1.13.0", env: []const u8 = "TYPESAFE_API_KEY" };
pub fn policy(binding: *bindings.Binding) !Policy {
    return policyConfiguration(binding.configuration);
}
pub fn policyConfiguration(configuration: Value) !Policy {
    if (configuration != .object) return error.InvalidDecisionPolicy;
    var result: Policy = .{};
    if (configuration.object.get("decision")) |v| {
        if (v == .null) return result;
        if (v != .object) return error.InvalidDecisionPolicy;
        var it = v.object.iterator();
        while (it.next()) |entry| if (!std.mem.eql(u8, entry.key_ptr.*, "provider") and !std.mem.eql(u8, entry.key_ptr.*, "model") and !std.mem.eql(u8, entry.key_ptr.*, "apiKeyEnv")) return error.InvalidDecisionPolicy;
        if (v.object.get("provider")) |p| if (!std.mem.eql(u8, try runner.text(p), "typesafe")) return error.UnsupportedDecisionProvider;
        if (v.object.get("model")) |m| result.model = try runner.text(m);
        if (v.object.get("apiKeyEnv")) |e| result.env = try runner.text(e);
        if (result.model.len == 0 or result.model.len > 256 or result.env.len == 0 or result.env.len > 128) return error.InvalidDecisionPolicy;
        for (result.model) |c| if (c < 33 or c > 126) return error.InvalidDecisionPolicy;
        @import("../credentials.zig").validateEnvironment(result.env) catch return error.InvalidDecisionPolicy;
    }
    return result;
}
pub fn selection(binding: *bindings.Binding) !runner.Selection {
    return .{ .provider = "typesafe", .model = (try policy(binding)).model, .reasoning = "none", .fast = false };
}
pub fn preflight(_: *anyopaque, definition: Value, _: *package.Package, binding: *bindings.Binding) !void {
    try types.validateQuestions(try runner.get(definition, "questions"));
    _ = try policy(binding);
}
fn check(ctx: *Context, request: runner.StepRequest) !void {
    if (request.cancel.load(.acquire)) return error.Cancelled;
    if (ctx.now() >= request.deadline_ms) return error.TimeLimit;
    if (request.limits.max_tokens == 0) return error.TokenLimit;
}
fn object(alloc: Allocator, fields: anytype) !Value {
    var v: Value = .{ .object = .{} };
    inline for (fields) |field| try v.object.put(alloc, field[0], field[1]);
    return v;
}
fn secret(alloc: Allocator, name: []const u8) !?[]u8 {
    return @import("../credentials.zig").load(alloc, name);
}
fn wipeFree(alloc: Allocator, bytes: []u8) void {
    @memset(bytes, 0);
    alloc.free(bytes);
}
pub fn execute(raw: *anyopaque, alloc: Allocator, request: runner.StepRequest, _: *package.Package, binding: *bindings.Binding) !runner.StepResult {
    const ctx: *Context = @ptrCast(@alignCast(raw));
    try check(ctx, request);
    const p = try policy(binding);
    const questions = try runner.get(request.definition, "questions");
    try types.validateQuestions(questions);
    if (request.input != .string and request.input != .object and request.input != .array) return error.InvalidDecisionState;
    const wire = try object(alloc, .{ .{ "state", request.input }, .{ "model", Value{ .string = p.model } }, .{ "questions", questions } });
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try std.json.Stringify.value(wire, .{}, &encoded.writer);
    if (encoded.written().len > request.limits.max_output_bytes) return error.OutputLimit;
    try check(ctx, request);
    const key = (if (ctx.secretFn) |f| try f(ctx.context.?, alloc, p.env) else try secret(alloc, p.env)) orelse return error.DecisionKeyRequired;
    defer wipeFree(alloc, key);
    if (key.len == 0) return error.DecisionKeyRequired;
    if (key.len > 8192) return error.InvalidTypeSafeApiKey;
    for (key) |c| if (c < 33 or c > 126) return error.InvalidTypeSafeApiKey;
    try check(ctx, request);
    const details = try object(alloc, .{ .{ "provider", Value{ .string = "typesafe" } }, .{ "model", Value{ .string = p.model } } });
    // The path names one position: a map runs the same step id once per element.
    const id = try std.fmt.allocPrint(alloc, "{s}:{d}:decision", .{ if (request.path.len != 0) request.path else request.step_id, request.iteration });
    const effect: runner.Effect = .{ .id = id, .state = .unknown, .kind = "decision_request", .details = details };
    try request.journal.record(effect);
    const transport_request: TransportRequest = .{ .body = encoded.written(), .key = key, .cancel = request.cancel, .deadline_ms = request.deadline_ms, .max_output_bytes = request.limits.max_output_bytes };
    if (request.model_dispatch) |dispatch| dispatch.record();
    const response = (if (ctx.transportFn) |f| f(ctx.context.?, alloc, transport_request) else post(alloc, transport_request, ctx.transport_scope, endpoint)) catch |err| return .{ .failure = safeFailure(err) };
    defer alloc.free(response.body);
    if (response.body.len > request.limits.max_output_bytes) return .{ .failure = error.OutputLimit };
    const parsed = schema.parse(alloc, response.body) catch {
        request.journal.record(.{ .id = id, .state = .applied, .kind = "decision_request", .details = details }) catch |err| return .{ .failure = err };
        return .{ .failure = error.InvalidDecisionResponse };
    };
    const measured_usage = readUsage(parsed) catch null;
    // Persisted JSON counters are signed integers. Include tokens already
    // consumed by earlier steps when admitting untrusted usage metadata.
    const previously_used = binding.limits.max_tokens -| request.limits.max_tokens;
    const headroom = @as(u64, std.math.maxInt(i64)) -| previously_used;
    const usage = if (measured_usage) |u| if (u.input_tokens + u.output_tokens <= headroom) measured_usage else null else null;
    request.journal.record(.{ .id = id, .state = .applied, .kind = "decision_request", .details = details }) catch |err| return .{ .usage = usage, .failure = err };
    if (response.status != 200) return .{ .usage = usage, .failure = error.DecisionHttpFailure };
    if (usage == null) return .{ .failure = error.DecisionUsageUnknown };
    validateAnswers(questions, parsed) catch return .{ .usage = usage, .failure = error.InvalidDecisionResponse };
    check(ctx, request) catch |err| return .{ .usage = usage, .failure = err };
    const output = try object(alloc, .{ .{ "model", try runner.get(parsed, "model") }, .{ "answers", try runner.get(parsed, "answers") } });
    return .{ .output = output, .usage = usage };
}
fn safeFailure(err: anyerror) anyerror {
    return switch (err) {
        error.Cancelled => error.Cancelled,
        error.Timeout, error.TimeLimit => error.TimeLimit,
        error.StreamTooLong => error.OutputLimit,
        else => error.DecisionDeliveryUnknown,
    };
}
fn readUsage(v: Value) !runner.Usage {
    const u = try runner.get(v, "usage");
    const i = try runner.get(u, "input_tokens");
    const o = try runner.get(u, "output_tokens");
    if (i != .integer or o != .integer or i.integer < 0 or o.integer < 0) return error.InvalidDecisionUsage;
    const input: u64 = @intCast(i.integer);
    const output: u64 = @intCast(o.integer);
    const total = std.math.add(u64, input, output) catch return error.InvalidDecisionUsage;
    if (total > std.math.maxInt(i64)) return error.InvalidDecisionUsage;
    return .{ .input_tokens = input, .output_tokens = output };
}
fn number(v: Value) !f64 {
    const n: f64 = switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        else => return error.InvalidDecisionResponse,
    };
    if (!std.math.isFinite(n)) return error.InvalidDecisionResponse;
    return n;
}
fn probability(v: Value) !f64 {
    const n = try number(v);
    if (n < 0 or n > 1) return error.InvalidDecisionResponse;
    return n;
}
pub fn validateAnswers(questions: Value, v: Value) !void {
    if ((try runner.text(try runner.get(v, "model"))).len == 0) return error.InvalidDecisionResponse;
    const answers = try runner.get(v, "answers");
    if (answers != .object or answers.object.count() != questions.object.count()) return error.InvalidDecisionResponse;
    var it = questions.object.iterator();
    while (it.next()) |entry| {
        const q = entry.value_ptr.*;
        const a = try runner.get(answers, entry.key_ptr.*);
        const kind = try runner.text(try runner.get(q, "type"));
        if (!std.mem.eql(u8, kind, try runner.text(try runner.get(a, "type")))) return error.InvalidDecisionResponse;
        if (std.mem.eql(u8, kind, "noul")) {
            _ = try probability(try runner.get(a, "noul"));
            continue;
        }
        _ = try probability(try runner.get(a, "confidence"));
        const criteria = try runner.get(q, "criteria");
        const probs = try runner.get(a, "probabilities");
        if (probs != .object) return error.InvalidDecisionResponse;
        var sum: f64 = 0;
        var weighted: f64 = 0;
        if (std.mem.eql(u8, kind, "choice")) {
            if (probs.object.count() != criteria.object.count()) return error.InvalidDecisionResponse;
            const chosen = try runner.text(try runner.get(a, "choice"));
            if (!criteria.object.contains(chosen)) return error.InvalidDecisionResponse;
            var options = criteria.object.iterator();
            const selected = try probability(try runner.get(probs, chosen));
            while (options.next()) |option| {
                const p = try probability(try runner.get(probs, option.key_ptr.*));
                sum += p;
                if (p > selected + 0.000001) return error.InvalidDecisionResponse;
            }
        } else {
            const legend = try runner.get(a, "legend");
            if (legend != .object or legend.object.count() != criteria.array.items.len or probs.object.count() != criteria.array.items.len) return error.InvalidDecisionResponse;
            for (criteria.array.items, 0..) |description, index| {
                var buf: [4]u8 = undefined;
                const key = try std.fmt.bufPrint(&buf, "{d}", .{index});
                const label = try runner.text(try runner.get(legend, key));
                if (description == .string and !std.mem.eql(u8, label, description.string)) return error.InvalidDecisionResponse;
                const p = try probability(try runner.get(probs, key));
                sum += p;
                weighted += p * @as(f64, @floatFromInt(index));
            }
            const score = try number(try runner.get(a, "score"));
            if (score < 0 or score > @as(f64, @floatFromInt(criteria.array.items.len - 1)) or @abs(score - weighted) > 0.0001) return error.InvalidDecisionResponse;
        }
        if (@abs(sum - 1) > 0.0001) return error.InvalidDecisionResponse;
    }
}
fn post(alloc: Allocator, request: TransportRequest, scope: ?*http_pool.Scope, url: []const u8) !Response {
    const cancel: *std.atomic.Value(bool) = @constCast(request.cancel);
    const deadline: std.Io.Clock.Timestamp = .{ .clock = .awake, .raw = .{ .nanoseconds = @as(i96, request.deadline_ms) * std.time.ns_per_ms } };
    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.key});
    defer wipeFree(alloc, auth);
    const pool = if (scope) |owner| owner.acquire(url, &.{ "jev", request.key }) else null;
    defer if (pool != null) scope.?.release();
    var local_client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer local_client.deinit();
    var operation: gateway.PostOperation = .{ .client = if (pool) |p| p.clientFor(url) else &local_client, .uri = try std.Uri.parse(url), .authorization = auth, .keep_alive = pool != null };
    var opened = try gateway.openBoundedPost(alloc, cancel, deadline, &operation);
    defer opened.deinit(alloc);
    const http = &opened.request.?;
    var reusable = false;
    defer if (!reusable) {
        if (http.connection) |connection| connection.closing = true;
    };
    var watch: gateway.CancelWatch = .{};
    defer watch.stop();
    if (http.connection) |connection| try watch.start(cancel, deadline, connection.stream_writer.stream);
    if (cancel.load(.acquire)) return error.Cancelled;
    if (std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds() >= request.deadline_ms) return error.TimeLimit;
    http.transfer_encoding = .{ .content_length = request.body.len };
    var buffer: [8192]u8 = undefined;
    var body = try http.sendBodyUnflushed(&buffer);
    try body.writer.writeAll(request.body);
    try body.end();
    if (http.connection) |connection| try connection.flush();
    var response = try http.receiveHead(&.{});
    var transfer: [8192]u8 = undefined;
    const bytes = try response.reader(&transfer).allocRemaining(alloc, .limited(request.max_output_bytes));
    errdefer alloc.free(bytes);
    watch.stop();
    if (cancel.load(.acquire)) return error.Cancelled;
    if (std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds() >= request.deadline_ms) return error.TimeLimit;
    reusable = true;
    if (pool) |p| p.noteActivity();
    return .{ .status = @intFromEnum(response.head.status), .body = bytes };
}
const Fixture = struct {
    dispatches: usize = 0,
    response: []const u8 = valid_response,
    calls: usize = 0,
    secrets: usize = 0,
    effects: usize = 0,
    status: u16 = 200,
    transport_failure: bool = false,
    late: bool = false,
    clock: i64 = 10,
    const questions = "{\"urgent\":{\"type\":\"noul\",\"instructions\":\"Urgent?\"},\"route\":{\"type\":\"choice\",\"instructions\":\"Route\",\"criteria\":{\"yes\":null,\"no\":null}},\"rating\":{\"type\":\"score\",\"instructions\":\"Rate\",\"criteria\":[\"Calm\",\"Angry\"]}}";
    const valid_response = "{\"model\":\"jev-1.13.0\",\"answers\":{\"urgent\":{\"type\":\"noul\",\"noul\":0.9},\"route\":{\"type\":\"choice\",\"choice\":\"yes\",\"probabilities\":{\"yes\":0.8,\"no\":0.2},\"confidence\":0.6},\"rating\":{\"type\":\"score\",\"score\":0.3,\"probabilities\":{\"0\":0.7,\"1\":0.3},\"legend\":{\"0\":\"Calm\",\"1\":\"Angry\"},\"confidence\":0.4}},\"usage\":{\"input_tokens\":42,\"output_tokens\":12}}";
    fn dispatched(raw: *anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.dispatches += 1;
    }
    fn now(raw: *anyopaque) i64 {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        return self.clock;
    }
    fn key(raw: *anyopaque, alloc: Allocator, name: []const u8) !?[]u8 {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.secrets += 1;
        try std.testing.expectEqualStrings("TYPESAFE_API_KEY", name);
        return try alloc.dupe(u8, "fixture-secret");
    }
    fn send(raw: *anyopaque, alloc: Allocator, wire_request: TransportRequest) !Response {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try std.testing.expect(self.effects == 1);
        try std.testing.expectEqualStrings("fixture-secret", wire_request.key);
        const wire = try std.json.parseFromSliceLeaky(Value, alloc, wire_request.body, .{});
        try std.testing.expectEqualStrings("jev-1.13.0", (try runner.get(wire, "model")).string);
        try std.testing.expectEqualStrings("complete state", (try runner.get(wire, "state")).object.get("content").?.string);
        try std.testing.expectEqual(@as(usize, 3), (try runner.get(wire, "questions")).object.count());
        if (self.transport_failure) return error.SocketFailure;
        if (self.late) self.clock = 100;
        return .{ .status = self.status, .body = try alloc.dupe(u8, self.response) };
    }
    fn journal(raw: *anyopaque, effect: runner.Effect) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.effects += 1;
        try std.testing.expectEqualStrings("decision_request", effect.kind);
        try std.testing.expectEqualStrings("typesafe", (try runner.get(effect.details.?, "provider")).string);
        try std.testing.expect(effect.details.?.object.get("state") == null);
    }
    fn request(self: *Fixture, alloc: Allocator, cancel: *const std.atomic.Value(bool)) !runner.StepRequest {
        const q = try std.json.parseFromSliceLeaky(Value, alloc, questions, .{});
        return .{ .run_id = "fixture", .step_id = "decide", .iteration = 0, .definition = try object(alloc, .{.{ "questions", q }}), .input = try std.json.parseFromSliceLeaky(Value, alloc, "{\"content\":\"complete state\"}", .{}), .selection = .{}, .response_schema = .null, .limits = .{}, .cancel = cancel, .deadline_ms = 100, .journal = .{ .context = self, .recordFn = journal }, .model_dispatch = .{ .context = self, .recordFn = dispatched } };
    }
    fn context(self: *Fixture) Context {
        return .{ .context = self, .secretFn = key, .transportFn = send, .nowFn = now };
    }
};
test "native decision constructs official complete wire and preserves all primitives and usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var binding = try bindings.fromBytes(alloc, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\"}}}", "local");
    defer binding.deinit();
    var pkg: package.Package = undefined;
    var fixture: Fixture = .{};
    var ctx = fixture.context();
    var cancel: std.atomic.Value(bool) = .init(false);
    const req = try fixture.request(alloc, &cancel);
    try preflight(&ctx, req.definition, &pkg, &binding);
    try std.testing.expectEqual(@as(usize, 0), fixture.secrets);
    const result = try execute(&ctx, alloc, req, &pkg, &binding);
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqual(@as(u64, 42), result.usage.?.input_tokens);
    try std.testing.expectEqual(@as(usize, 3), (try runner.get(result.output, "answers")).object.count());
    try std.testing.expect(result.output.object.get("usage") == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}
test "native decision rejects cancellation deadline and exhaustion before auth dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var binding = try bindings.fromBytes(alloc, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\"}}}", "local");
    defer binding.deinit();
    var pkg: package.Package = undefined;
    var fixture: Fixture = .{};
    var ctx = fixture.context();
    var cancel: std.atomic.Value(bool) = .init(true);
    var req = try fixture.request(alloc, &cancel);
    try std.testing.expectError(error.Cancelled, execute(&ctx, alloc, req, &pkg, &binding));
    cancel.store(false, .release);
    req.deadline_ms = 10;
    try std.testing.expectError(error.TimeLimit, execute(&ctx, alloc, req, &pkg, &binding));
    req.deadline_ms = 100;
    req.limits.max_tokens = 0;
    try std.testing.expectError(error.TokenLimit, execute(&ctx, alloc, req, &pkg, &binding));
    try std.testing.expectEqual(@as(usize, 0), fixture.secrets);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}
test "native decision meters invalid HTTP and late answers without retrying uncertain delivery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var binding = try bindings.fromBytes(alloc, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\"}}}", "local");
    defer binding.deinit();
    var pkg: package.Package = undefined;
    var cancel: std.atomic.Value(bool) = .init(false);
    inline for (.{ "http", "late", "uncertain", "missing_usage", "malformed", "invalid_answers", "aggregate_overflow" }) |mode| {
        var fixture: Fixture = .{};
        var ctx = fixture.context();
        if (comptime std.mem.eql(u8, mode, "http")) fixture.status = 429;
        if (comptime std.mem.eql(u8, mode, "late")) fixture.late = true;
        if (comptime std.mem.eql(u8, mode, "uncertain")) fixture.transport_failure = true;
        if (comptime std.mem.eql(u8, mode, "missing_usage")) fixture.response = "{\"model\":\"jev-1.13.0\",\"answers\":{}}";
        if (comptime std.mem.eql(u8, mode, "malformed")) fixture.response = "{";
        if (comptime std.mem.eql(u8, mode, "invalid_answers")) fixture.response = "{\"model\":\"jev-1.13.0\",\"answers\":{},\"usage\":{\"input_tokens\":42,\"output_tokens\":12}}";
        var request = try fixture.request(alloc, &cancel);
        if (comptime std.mem.eql(u8, mode, "aggregate_overflow")) {
            fixture.response = "{\"model\":\"jev-1.13.0\",\"answers\":{},\"usage\":{\"input_tokens\":9223372036854775807,\"output_tokens\":0}}";
            request.limits.max_tokens = binding.limits.max_tokens - 1;
        }
        const result = try execute(&ctx, alloc, request, &pkg, &binding);
        try std.testing.expect(result.failure != null);
        try std.testing.expectEqual(@as(usize, 1), fixture.calls);
        try std.testing.expectEqual(@as(usize, 1), fixture.dispatches);
        if (comptime std.mem.eql(u8, mode, "http") or std.mem.eql(u8, mode, "late") or std.mem.eql(u8, mode, "invalid_answers")) try std.testing.expectEqual(@as(u64, 42), result.usage.?.input_tokens) else try std.testing.expect(result.usage == null);
    }
}
test "native decision rejects IDs types options distributions score legend and nonfinite values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const q = try std.json.parseFromSliceLeaky(Value, alloc, Fixture.questions, .{});
    const paths = [_][]const u8{ "id", "type", "option", "probability", "sum", "score", "legend", "nonfinite" };
    for (paths) |mode| {
        var v = try std.json.parseFromSliceLeaky(Value, alloc, Fixture.valid_response, .{});
        var answers = v.object.getPtr("answers").?;
        var choice = answers.object.getPtr("route").?;
        var score = answers.object.getPtr("rating").?;
        if (std.mem.eql(u8, mode, "id")) {
            _ = answers.object.swapRemove("urgent");
        }
        if (std.mem.eql(u8, mode, "type")) try choice.object.put(alloc, "type", .{ .string = "noul" });
        if (std.mem.eql(u8, mode, "option")) try choice.object.put(alloc, "choice", .{ .string = "other" });
        if (std.mem.eql(u8, mode, "probability")) try choice.object.getPtr("probabilities").?.object.put(alloc, "yes", .{ .float = 1.2 });
        if (std.mem.eql(u8, mode, "sum")) try choice.object.getPtr("probabilities").?.object.put(alloc, "no", .{ .float = 0.1 });
        if (std.mem.eql(u8, mode, "score")) try score.object.put(alloc, "score", .{ .float = 0.7 });
        if (std.mem.eql(u8, mode, "legend")) try score.object.getPtr("legend").?.object.put(alloc, "0", .{ .string = "Wrong" });
        if (std.mem.eql(u8, mode, "nonfinite")) try answers.object.getPtr("urgent").?.object.put(alloc, "noul", .{ .float = std.math.inf(f64) });
        try std.testing.expectError(error.InvalidDecisionResponse, validateAnswers(q, v));
    }
}
test "native decision missing configured credential fails actionably without network" {
    const Missing = struct {
        fn key(_: *anyopaque, _: Allocator, _: []const u8) !?[]u8 {
            return null;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var binding = try bindings.fromBytes(alloc, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\"}}}", "local");
    defer binding.deinit();
    var pkg: package.Package = undefined;
    var fixture: Fixture = .{};
    var ctx = fixture.context();
    ctx.secretFn = Missing.key;
    var cancel: std.atomic.Value(bool) = .init(false);
    const req = try fixture.request(alloc, &cancel);
    try preflight(&ctx, req.definition, &pkg, &binding);
    try std.testing.expectError(error.DecisionKeyRequired, execute(&ctx, alloc, req, &pkg, &binding));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.effects);
    try std.testing.expectEqual(@as(usize, 0), fixture.dispatches);
}

const TransportFixture = @import("transport_fixture.zig");
fn testPost(scope: ?*http_pool.Scope, url: []const u8, key: []const u8, cancel: *std.atomic.Value(bool), timeout_ms: i64, max_bytes: usize) !Response {
    return post(std.testing.allocator, .{
        .body = "{\"fixture\":true}",
        .key = key,
        .cancel = cancel,
        .deadline_ms = std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds() + timeout_ms,
        .max_output_bytes = max_bytes,
    }, scope, url);
}
fn testPostSuccess(scope: ?*http_pool.Scope, url: []const u8, key: []const u8) !void {
    var cancel = std.atomic.Value(bool).init(false);
    const response = try testPost(scope, url, key, &cancel, 2000, 4096);
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings(Fixture.valid_response, response.body);
}

test "native Jev pooled requests reuse socket with request-local keys and run ownership" {
    const alloc = std.testing.allocator;
    const replies = [_]TransportFixture.Reply{.{ .body = Fixture.valid_response }} ** 6;
    var server = try TransportFixture.Server.init(&replies);
    defer server.deinit();
    try server.start();
    const url = try server.url(alloc);
    defer alloc.free(url);
    var scope = http_pool.Scope.init(alloc);
    defer scope.deinit();
    try testPostSuccess(&scope, url, "one");
    try testPostSuccess(&scope, url, "one");
    try std.testing.expectEqual(@as(usize, 1), server.accepted.load(.acquire));
    try testPostSuccess(&scope, url, "two");
    try std.testing.expectEqual(@as(usize, 2), server.accepted.load(.acquire));
    try std.testing.expectEqualStrings("Bearer one", server.header(0, "authorization").?);
    try std.testing.expectEqualStrings("Bearer two", server.header(2, "authorization").?);
    scope.deinit();
    var next_run = http_pool.Scope.init(alloc);
    defer next_run.deinit();
    try testPostSuccess(&next_run, url, "two");
    next_run.deinit();
    try testPostSuccess(null, url, "two");
    try testPostSuccess(null, url, "two");
    try std.testing.expectEqual(@as(usize, 5), server.accepted.load(.acquire));
}

test "native Jev endpoint changes and fully read error responses preserve isolation" {
    const alloc = std.testing.allocator;
    const replies = [_]TransportFixture.Reply{.{ .body = Fixture.valid_response }} ** 2;
    var first = try TransportFixture.Server.init(&replies);
    defer first.deinit();
    try first.start();
    const other_replies = [_]TransportFixture.Reply{ .{ .body = "failure", .status = 503 }, .{ .body = Fixture.valid_response } };
    var second = try TransportFixture.Server.init(&other_replies);
    defer second.deinit();
    try second.start();
    const first_url = try first.url(alloc);
    defer alloc.free(first_url);
    const second_url = try second.url(alloc);
    defer alloc.free(second_url);
    var scope = http_pool.Scope.init(alloc);
    defer scope.deinit();
    try testPostSuccess(&scope, first_url, "one");
    var cancel = std.atomic.Value(bool).init(false);
    const response = try testPost(&scope, second_url, "one", &cancel, 2000, 4096);
    defer alloc.free(response.body);
    try std.testing.expectEqual(@as(u16, 503), response.status);
    try std.testing.expectEqualStrings("failure", response.body);
    try testPostSuccess(&scope, second_url, "one");
    try std.testing.expectEqual(@as(usize, 1), first.accepted.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), second.accepted.load(.acquire));
}

test "native Jev deadline cancellation reset and oversized bodies discard pooled connections" {
    const alloc = std.testing.allocator;
    const cases = [_]TransportFixture.Reply{
        .{ .body = "", .mode = .stall },
        .{ .body = "", .mode = .reset },
        .{ .body = "oversized" },
    };
    for (cases, 0..) |bad, index| {
        const replies = [_]TransportFixture.Reply{ bad, .{ .body = Fixture.valid_response } };
        var server = try TransportFixture.Server.init(&replies);
        defer server.deinit();
        try server.start();
        const url = try server.url(alloc);
        defer alloc.free(url);
        var scope = http_pool.Scope.init(alloc);
        defer scope.deinit();
        var cancel = std.atomic.Value(bool).init(false);
        if (testPost(&scope, url, "one", &cancel, 80, if (index == 2) 3 else 4096)) |response| {
            alloc.free(response.body);
            return error.ExpectedTransportFailure;
        } else |_| {}
        try std.testing.expectEqual(@as(usize, 0), scope.pool.?.freeConnectionCount());
        try testPostSuccess(&scope, url, "one");
        try std.testing.expectEqual(@as(usize, 2), server.accepted.load(.acquire));
    }
    const replies = [_]TransportFixture.Reply{ .{ .body = "", .mode = .stall }, .{ .body = Fixture.valid_response } };
    var server = try TransportFixture.Server.init(&replies);
    defer server.deinit();
    try server.start();
    const url = try server.url(alloc);
    defer alloc.free(url);
    var scope = http_pool.Scope.init(alloc);
    defer scope.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    const Canceller = struct {
        fn run(peer: *TransportFixture.Server, flag: *std.atomic.Value(bool)) void {
            var waits: usize = 0;
            while (peer.served.load(.acquire) == 0 and waits < 2000) : (waits += 1) io_mod.sleep(std.time.ns_per_ms);
            flag.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Canceller.run, .{ &server, &cancel });
    defer thread.join();
    if (testPost(&scope, url, "one", &cancel, 2000, 4096)) |response| {
        alloc.free(response.body);
        return error.ExpectedTransportFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 0), scope.pool.?.freeConnectionCount());
    try testPostSuccess(&scope, url, "one");
    try std.testing.expectEqual(@as(usize, 2), server.accepted.load(.acquire));
}
