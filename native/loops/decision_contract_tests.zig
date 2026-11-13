const std = @import("std");
const package = @import("package.zig");
const types = @import("decision_types.zig");
const runner = @import("runner.zig");
const Value = std.json.Value;
const primitives =
    \\{"yes":{"type":"noul","instructions":"Ready?","criteria":{"true":{},"false":[]}},"route":{"type":"choice","instructions":{"question":"Route?"},"criteria":{"accept":null,"review":"Ambiguous"}},"quality":{"type":"score","instructions":["Quality?"],"criteria":["Poor",{},[]]}}
;
test "decision contract accepts official primitives and rejects malformed static definitions" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, primitives, .{});
    defer parsed.deinit();
    try types.validateQuestions(parsed.value);
    for ([_][]const u8{
        "{}",                                                                         "[]",                                                                               "{\"x\":{\"type\":\"generate\",\"instructions\":\"?\"}}",
        "{\"x\":{\"type\":\"noul\",\"instructions\":true}}",                          "{\"x\":{\"type\":\"noul\",\"instructions\":\"?\",\"criteria\":{\"maybe\":null}}}", "{\"x\":{\"type\":\"choice\",\"instructions\":\"?\",\"criteria\":{}}}",
        "{\"x\":{\"type\":\"score\",\"instructions\":\"?\",\"criteria\":[\"one\"]}}", "{\"x\":{\"type\":\"score\",\"instructions\":\"?\",\"criteria\":[null,\"two\"]}}",  "{\"x\":{\"type\":\"noul\",\"instructions\":\"?\",\"model\":\"secret\"}}",
    }) |text| {
        const invalid = try std.json.parseFromSlice(Value, std.testing.allocator, text, .{});
        defer invalid.deinit();
        try std.testing.expectError(error.InvalidDecisionQuestions, types.validateQuestions(invalid.value));
    }
}
fn manifest(alloc: std.mem.Allocator, format: []const u8, extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{{\"format\":\"{s}\",\"name\":\"decision\",\"version\":\"1\",\"inputs\":{{\"schema\":true}},\"steps\":[{{\"id\":\"judge\",\"kind\":\"decision\",\"input\":{{\"from\":\"/input\"}},\"output\":{{\"schema\":true}},\"questions\":{s}{s}}}],\"output\":{{\"from\":\"/steps/judge/output\"}}}}", .{ format, primitives, extra });
}
test "package decision is version gated and cannot declare installed configuration or capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const valid = try package.fromFiles(std.testing.allocator, &.{.{ .path = "loop.json", .bytes = try manifest(a, "loops/0.2", "") }}, "loop.json");
    defer valid.deinit();
    try std.testing.expectError(error.UnsupportedDefinition, package.fromFiles(std.testing.allocator, &.{.{ .path = "loop.json", .bytes = try manifest(a, "loops/0.1", "") }}, "loop.json"));
    try std.testing.expectError(error.UnsupportedDefinition, package.fromFiles(std.testing.allocator, &.{.{ .path = "loop.json", .bytes = try manifest(a, "loops/0.2", ",\"model\":\"jev\"") }}, "loop.json"));
    try std.testing.expectError(error.UnsupportedCapability, package.fromFiles(std.testing.allocator, &.{.{ .path = "loop.json", .bytes = try manifest(a, "loops/0.2", ",\"requires\":[\"web_search\"]") }}, "loop.json"));
}
const Fixture = struct {
    calls: u32 = 0,
    missing_usage: bool = false,
    budget: u64 = 10,
    failure: ?anyerror = null,
    fn now(_: *anyopaque) i64 {
        return 0;
    }
    fn persist(_: *anyopaque, _: Value, _: []const u8) !void {}
    fn validate(_: *anyopaque, _: ?[]const u8, _: Value) !void {}
    fn step(raw: *anyopaque, a: std.mem.Allocator, req: runner.StepRequest) !runner.StepResult {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try std.testing.expectEqual(self.budget - (self.calls - 1) * 5, req.limits.max_tokens);
        try std.testing.expectEqual(@as(i64, self.calls - 1), req.input.integer);
        var output: Value = .{ .object = std.json.ObjectMap{} };
        try output.object.put(a, "next", .{ .integer = @intCast(self.calls) });
        try output.object.put(a, "ready", .{ .bool = self.calls == 2 });
        return .{ .output = output, .usage = if (self.missing_usage) null else .{ .input_tokens = 3, .output_tokens = 2 }, .failure = self.failure };
    }
    fn ports(self: *Fixture) runner.Ports {
        return .{ .context = self, .executeFn = step, .validateFn = validate, .persistFn = persist, .nowFn = now };
    }
};
const carry =
    \\{"steps":[{"id":"judge","kind":"decision","input":{"from":"/carry"}}],"repeat":{"from":"judge","through":"judge","until":{"from":"/steps/judge/output/ready"},"max_iterations":3,"carry":{"initial":{"value":0},"next":{"from":"/steps/judge/output/next"}}},"output":{"from":"/steps/judge/output"}}
;
test "decision carry consumes shared actual token budget and preserves measured usage on failure" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, carry, .{});
    defer parsed.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var fixture: Fixture = .{};
    const request: runner.Request = .{ .run_id = "decision", .manifest = parsed.value, .input = .null, .cancel = &cancel, .deadline_ms = 1000, .limits = .{ .max_tokens = 10 } };
    var run = try runner.execute(std.testing.allocator, request, fixture.ports());
    defer run.deinit();
    try std.testing.expectEqualStrings("completed", (try runner.get(run.record, "status")).string);
    try std.testing.expectEqual(@as(i64, 10), (try runner.get(run.record, "used_tokens")).integer);
    try std.testing.expectEqual(@as(i64, 2), (try runner.get(try runner.get(run.record, "output"), "next")).integer);
    const transitions = (try runner.get(run.record, "carry_history")).array.items;
    try std.testing.expectEqual(@as(usize, 2), transitions.len);
    try std.testing.expectEqual(@as(i64, 1), (try runner.get(transitions[1], "value")).integer);
    fixture = .{ .failure = error.InvalidDecisionResponse };
    var failed = try runner.execute(std.testing.allocator, request, fixture.ports());
    defer failed.deinit();
    try std.testing.expectEqual(@as(i64, 5), (try runner.get(failed.record, "used_tokens")).integer);
    try std.testing.expectEqualStrings("failed", (try runner.get(failed.record, "status")).string);
    try std.testing.expectEqualStrings("invalid_decision_response", (try runner.get(try runner.get(failed.record, "error"), "reason")).string);
    fixture = .{ .missing_usage = true };
    var unknown = try runner.execute(std.testing.allocator, request, fixture.ports());
    defer unknown.deinit();
    try std.testing.expectEqualStrings("usage_unavailable", (try runner.get(try runner.get(unknown.record, "stop"), "reason")).string);
    try std.testing.expectEqual(@as(u32, 1), fixture.calls);
}

test "exhausted shared tokens prevent a decision dispatch after an inference" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator,
        \\{"steps":[{"id":"generate","kind":"infer","input":{"value":0}},{"id":"judge","kind":"decision","input":{"from":"/steps/generate/output/next"}}],"output":{"from":"/steps/judge/output"}}
    , .{});
    defer parsed.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var fixture: Fixture = .{ .budget = 5 };
    var run = try runner.execute(std.testing.allocator, .{ .run_id = "shared", .manifest = parsed.value, .input = .null, .cancel = &cancel, .deadline_ms = 1000, .limits = .{ .max_tokens = 5 } }, fixture.ports());
    defer run.deinit();
    try std.testing.expectEqualStrings("token_limit", (try runner.get(try runner.get(run.record, "stop"), "reason")).string);
    try std.testing.expectEqual(@as(u32, 1), fixture.calls);
    try std.testing.expectEqual(@as(i64, 5), (try runner.get(run.record, "used_tokens")).integer);
    try std.testing.expect(run.record.object.get("output") == null);
}

test "question and primitive counts enforce portable upper bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSlice(Value, a, "{\"type\":\"noul\",\"instructions\":\"?\"}", .{});
    var questions: Value = .{ .object = .{} };
    for (0..64) |i| try questions.object.put(a, try std.fmt.allocPrint(a, "q{d}", .{i}), parsed.value);
    try types.validateQuestions(questions);
    try questions.object.put(a, "extra", parsed.value);
    try std.testing.expectError(error.InvalidDecisionQuestions, types.validateQuestions(questions));
    const choice = (try std.json.parseFromSlice(Value, a, "{\"x\":{\"type\":\"choice\",\"instructions\":\"?\",\"criteria\":{}}}", .{})).value;
    const criteria = choice.object.getPtr("x").?.object.getPtr("criteria").?;
    for (0..255) |i| try criteria.object.put(a, try std.fmt.allocPrint(a, "option{d}", .{i}), .null);
    try types.validateQuestions(choice);
    try criteria.object.put(a, "extra", .null);
    try std.testing.expectError(error.InvalidDecisionQuestions, types.validateQuestions(choice));
    const score = (try std.json.parseFromSlice(Value, a, "{\"x\":{\"type\":\"score\",\"instructions\":\"?\",\"criteria\":[]}}", .{})).value;
    const levels = score.object.getPtr("x").?.object.getPtr("criteria").?;
    for (0..10) |_| try levels.array.append(.{ .string = "level" });
    try types.validateQuestions(score);
    try levels.array.append(.{ .string = "extra" });
    try std.testing.expectError(error.InvalidDecisionQuestions, types.validateQuestions(score));
}
