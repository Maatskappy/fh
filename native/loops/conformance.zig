//! Shared protocol fixtures, real saved fixture code and frozen inference only.
//! This is semantic conformance, not a production isolation/provider proof.
const std = @import("std");
const runner = @import("runner.zig");
const package = @import("package.zig");
const schema = @import("schema.zig");
const code = @import("code.zig");
const node_fixture = @import("node_fixture.zig");
const fx_io = @import("../../vendor/fx/src/core/shared/io.zig");
const Value = std.json.Value;
const Fixture = struct {
    pkg: *package.Package,
    responses: []const Value,
    ordinal: usize = 0,
    // loops/0.3 fixtures: one flag per response, set when (path, pass) has claimed it.
    claimed: ?[]bool = null,
    cancel: *std.atomic.Value(bool),
    // loops/0.3 agent-driver fixtures: the runner must never infer, and each operation
    // continues from the last stored record, as a separate process would.
    agent: bool = false,
    stored: ?[]u8 = null,
    saves: usize = 0,
    // This machine has no Node the runtime supports: the node fixture is skipped, loudly.
    node_missing: bool = false,
    fn cast(raw: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(raw));
    }
    fn validate(raw: *anyopaque, id: ?[]const u8, value: Value) !void {
        const self = cast(raw);
        if (id) |s| self.pkg.validateStepOutput(s, value) catch return error.InvalidOutput else self.pkg.validateInput(value) catch return error.InvalidInput;
    }
    fn persist(raw: *anyopaque, _: Value, encoded: []const u8) !void {
        const self = cast(raw);
        if (!self.agent) return;
        if (self.stored) |old| std.testing.allocator.free(old);
        self.stored = null;
        self.stored = try std.testing.allocator.dupe(u8, encoded);
        self.saves += 1;
    }
    fn now(_: *anyopaque) i64 {
        return 0;
    }
    fn stepSchema(raw: *anyopaque, id: []const u8) !Value {
        return cast(raw).pkg.stepSchema(id);
    }
    fn execute(raw: *anyopaque, alloc: std.mem.Allocator, request: runner.StepRequest) !runner.StepResult {
        const self = cast(raw);
        if (std.mem.eql(u8, (try runner.get(request.definition, "kind")).string, "infer")) {
            if (self.agent) return error.UnexpectedInference;
            if (self.claimed) |claimed| return self.frozen(alloc, request, claimed);
            if (self.ordinal >= self.responses.len) return error.UnexpectedInference;
            const selected = self.responses[self.ordinal];
            self.ordinal += 1;
            try std.testing.expectEqualStrings(request.step_id, (try runner.get(selected, "step")).string);
            try std.testing.expectEqual(@as(i64, request.iteration), (try runner.get(selected, "pass")).integer);
            try std.testing.expectEqual(@as(i64, @intCast(self.ordinal)), (try runner.get(selected, "ordinal")).integer);
            const usage = try runner.get(selected, "usage");
            if (selected.object.get("hold")) |held| if (held.bool) {
                self.cancel.store(true, .release);
                return .{ .output = .null, .usage = .{ .input_tokens = @intCast((try runner.get(usage, "input_tokens")).integer), .output_tokens = @intCast((try runner.get(usage, "output_tokens")).integer) } };
            };
            return .{ .output = try runner.get(selected, "output"), .usage = .{ .input_tokens = @intCast((try runner.get(usage, "input_tokens")).integer), .output_tokens = @intCast((try runner.get(usage, "output_tokens")).integer) } };
        }
        // Only the versioned, trusted contract fixtures execute here. The app
        // never uses this adapter: production code stays in isolated Docker.
        const file = try self.pkg.stepCode(request.step_id);
        if (std.mem.eql(u8, (try runner.get(request.definition, "runtime")).string, "node")) {
            const files = try alloc.alloc(code.File, self.pkg.files.len);
            for (self.pkg.files, files) |saved, *retained| retained.* = .{ .path = saved.path, .bytes = saved.bytes };
            const finished = node_fixture.run(alloc, std.testing.io, files, file.path, request.input) catch |err| {
                if (err == error.SkipZigTest) self.node_missing = true;
                return err;
            };
            if (finished.exit != 0) std.debug.print("Fixture Node failed: {s}\n", .{finished.stderr});
            return .{ .output = try code.outcome(alloc, finished.exit, finished.stdout, 1048576) };
        }
        const input = try std.json.Stringify.valueAlloc(alloc, request.input, .{});
        const result = try std.process.run(alloc, fx_io.getIo(), .{
            .argv = &.{ "/usr/bin/python3", "-I", "-c", "import io,sys; sys.stdin=io.StringIO(sys.argv[1]); exec(compile(sys.argv[2],'<saved fixture>','exec'))", input, file.bytes },
            .stdout_limit = .limited(1048576),
            .stderr_limit = .limited(65536),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } },
        });
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("Fixture Python failed: {s}\n", .{result.stderr});
            return error.CodeExit;
        }
        return .{ .output = try schema.parse(alloc, result.stdout) };
    }
    // Frozen inference keyed by path and pass: concurrent order is not defined.
    fn frozen(self: *Fixture, alloc: std.mem.Allocator, request: runner.StepRequest, claimed: []bool) !runner.StepResult {
        const selected = for (self.responses, claimed) |response, *taken| {
            if (taken.* or !std.mem.eql(u8, (try runner.get(response, "path")).string, request.path) or (try runner.get(response, "pass")).integer != request.iteration) continue;
            taken.* = true;
            break response;
        } else {
            std.debug.print("No frozen response for {s} pass {d}\n", .{ request.path, request.iteration });
            return error.UnexpectedInference;
        };
        // The exact text the engine hands the model adapter for this step.
        if (selected.object.get("instructions")) |text| try std.testing.expectEqualStrings(text.string, (try runner.get(try self.pkg.resolved(alloc, request.definition), "instructions")).string);
        const measured = try runner.get(selected, "usage");
        const usage: runner.Usage = .{ .input_tokens = @intCast((try runner.get(measured, "input_tokens")).integer), .output_tokens = @intCast((try runner.get(measured, "output_tokens")).integer) };
        if (selected.object.get("error")) |failure| {
            const reason = (try runner.get(failure, "reason")).string;
            if (!std.mem.eql(u8, reason, "execution_failed")) return error.UnsupportedFixtureReason;
            return .{ .usage = usage, .failure = error.FrozenStepFailure };
        }
        return .{ .output = try runner.get(selected, "output"), .usage = usage };
    }
    fn ports(self: *Fixture) runner.Ports {
        return .{ .context = self, .executeFn = execute, .validateFn = validate, .persistFn = persist, .nowFn = now, .schemaFn = stepSchema };
    }
};
fn obj() Value {
    return .{ .object = .{} };
}
fn put(a: std.mem.Allocator, o: *Value, k: []const u8, v: Value) !void {
    try o.object.put(a, k, v);
}
fn trace(a: std.mem.Allocator, record: Value) !Value {
    var steps: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    for ((try runner.get(record, "attempts")).array.items) |attempt| {
        var step = obj();
        try put(a, &step, "step", try runner.get(attempt, "step_id"));
        try put(a, &step, "pass", try runner.get(attempt, "iteration"));
        try put(a, &step, "input", try runner.get(attempt, "input"));
        if (attempt.object.get("output")) |v| try put(a, &step, "output", v);
        try steps.array.append(step);
    }
    return traced(a, record, steps);
}
fn traced(a: std.mem.Allocator, record: Value, steps: Value) !Value {
    var result = obj();
    var carry: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    for ((try runner.get(record, "carry_history")).array.items) |transition| {
        var value = obj();
        try put(a, &value, "forPass", try runner.get(transition, "for_pass"));
        try put(a, &value, "value", try runner.get(transition, "value"));
        try carry.array.append(value);
    }
    var terminal = obj();
    const status = try runner.get(record, "status");
    try put(a, &terminal, "status", status);
    if (record.object.get("output")) |v| try put(a, &terminal, "output", v) else {
        const reason = record.object.get("stop") orelse try runner.get(record, "error");
        try put(a, &terminal, "reason", try runner.get(reason, "reason"));
    }
    try put(a, &result, "steps", steps);
    try put(a, &result, "carry", carry);
    try put(a, &result, "terminal", terminal);
    return result;
}
test "native shared contract matches all fourteen independent expected traces" {
    const io = std.testing.io;
    var directory = try std.Io.Dir.cwd().openDir(io, "packages/loops-contract/fixtures", .{ .iterate = true });
    defer directory.close(io);
    var it = directory.iterate();
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const bytes = try directory.readFileAlloc(io, entry.name, a, .limited(1048576));
        const fixture = try schema.parse(a, bytes);
        var files: std.ArrayList(package.File) = .empty;
        var fi = (try runner.get(fixture, "packageFiles")).object.iterator();
        while (fi.next()) |f| try files.append(a, .{ .path = f.key_ptr.*, .bytes = f.value_ptr.string });
        const pkg = try package.fromFiles(std.testing.allocator, files.items, (try runner.get(fixture, "manifestPath")).string);
        defer pkg.deinit();
        var cancelled = std.atomic.Value(bool).init(false);
        var ctx = Fixture{ .pkg = pkg, .responses = (try runner.get(try runner.get(fixture, "scenario"), "responses")).array.items, .cancel = &cancelled };
        var run = try runner.execute(std.testing.allocator, .{ .run_id = "contract-fixture", .manifest = pkg.manifest, .input = try runner.get(fixture, "input"), .cancel = &cancelled, .deadline_ms = 1000 }, ctx.ports());
        defer run.deinit();
        const actual = try trace(a, run.record);
        const expected_path = try std.fmt.allocPrint(a, "packages/loops-contract/expected/{s}", .{entry.name});
        const expected = try schema.parse(a, try std.Io.Dir.cwd().readFileAlloc(io, expected_path, a, .limited(1048576)));
        if (!schema.equal(actual, expected)) {
            std.debug.print("Conformance mismatch {s}\nActual: {s}\nExpected: {s}\n", .{ entry.name, try std.json.Stringify.valueAlloc(a, actual, .{}), try std.json.Stringify.valueAlloc(a, expected, .{}) });
            return error.ContractMismatch;
        }
        try std.testing.expectEqual(ctx.responses.len, ctx.ordinal);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 14), count);
}

fn stepIndex(steps: Value, id: []const u8) !usize {
    for (steps.array.items, 0..) |step, i| if (std.mem.eql(u8, (try runner.get(step, "id")).string, id)) return i;
    return error.UnknownPath;
}
/// Canonical trace position (loops/0.3 fixtures): phase (before the region, each
/// pass, after it), then declaration order, branches in declared order, elements
/// by index, and a composite after its children.
fn canonicalKey(a: std.mem.Allocator, manifest: Value, path: []const u8, pass: u64) ![]const u64 {
    const top = try runner.get(manifest, "steps");
    var key: std.ArrayList(u64) = .empty;
    try key.append(a, 0);
    var steps = top;
    var rest = path;
    while (true) {
        const end = std.mem.indexOfAny(u8, rest, "/[") orelse rest.len;
        const index = try stepIndex(steps, rest[0..end]);
        try key.append(a, index);
        const step = steps.array.items[index];
        rest = rest[end..];
        if (rest.len == 0) break;
        const close = std.mem.indexOfScalarPos(u8, rest, 1, if (rest[0] == '/') '/' else ']') orelse return error.UnknownPath;
        if (rest[0] == '/') {
            const branches = (try runner.get(step, "branches")).object;
            const branch = branches.getIndex(rest[1..close]) orelse return error.UnknownPath;
            try key.append(a, branch);
            steps = branches.values()[branch];
            rest = rest[close + 1 ..];
        } else {
            try key.append(a, try std.fmt.parseInt(u64, rest[1..close], 10));
            steps = try runner.get(step, "steps");
            if (!std.mem.startsWith(u8, rest[close..], "]/")) return error.UnknownPath;
            rest = rest[close + 2 ..];
        }
    }
    try key.append(a, std.math.maxInt(u64));
    if (manifest.object.get("repeat")) |repeat| {
        const from = try stepIndex(top, (try runner.get(repeat, "from")).string);
        const through = try stepIndex(top, (try runner.get(repeat, "through")).string);
        key.items[0] = if (key.items[1] < from) 0 else if (key.items[1] <= through) pass else std.math.maxInt(u64);
    }
    return key.items;
}
const Positioned = struct {
    key: []const u64,
    step: Value,
    fn before(_: void, l: Positioned, r: Positioned) bool {
        return std.mem.order(u64, l.key, r.key) == .lt;
    }
};
fn trace03(a: std.mem.Allocator, manifest: Value, record: Value) !Value {
    var positioned: std.ArrayList(Positioned) = .empty;
    for ((try runner.get(record, "attempts")).array.items) |attempt| {
        var step = obj();
        const path = try runner.get(attempt, "path");
        const pass = try runner.get(attempt, "iteration");
        try put(a, &step, "path", path);
        try put(a, &step, "pass", pass);
        if (attempt.object.get("input")) |v| try put(a, &step, "input", v);
        if (attempt.object.get("output")) |v| try put(a, &step, "output", v);
        try positioned.append(a, .{ .key = try canonicalKey(a, manifest, path.string, @intCast(pass.integer)), .step = step });
    }
    std.mem.sort(Positioned, positioned.items, {}, Positioned.before);
    var steps: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    for (positioned.items) |entry| try steps.array.append(entry.step);
    return traced(a, record, steps);
}
/// Drives an agent-driver fixture: `next`, `submit` and `cancel` in order, each from the
/// record the last operation stored. Returns the final record.
fn drive(a: std.mem.Allocator, name: []const u8, ctx: *Fixture, fixture: Value, cancelled: *std.atomic.Value(bool)) !Value {
    const manifest = ctx.pkg.manifest;
    var started = try runner.execute(std.testing.allocator, .{ .run_id = "contract-fixture", .manifest = manifest, .input = try runner.get(fixture, "input"), .cancel = cancelled, .deadline_ms = 1000, .agent = .{} }, ctx.ports());
    started.deinit();
    for ((try runner.get(try runner.get(fixture, "scenario"), "ops")).array.items, 0..) |op, index| {
        const record = try schema.parse(a, ctx.stored.?);
        const kind = (try runner.get(op, "op")).string;
        const saves = ctx.saves;
        var request: runner.Request = .{ .run_id = "contract-fixture", .manifest = manifest, .input = .null, .cancel = cancelled, .deadline_ms = 1000 };
        if (std.mem.eql(u8, kind, "next")) {
            request.agent = .{ .record = record, .op = .peek };
            var run = try runner.execute(std.testing.allocator, request, ctx.ports());
            defer run.deinit();
            const expected = (try runner.get(op, "expect")).array.items;
            var matches = expected.len == run.ready.len;
            if (matches) for (expected, run.ready) |want, got| {
                if (!std.mem.eql(u8, want.string, got.path)) matches = false;
            };
            if (!matches) {
                std.debug.print("Conformance 0.3 {s} op {d}: next expected {s}, got", .{ name, index, try std.json.Stringify.valueAlloc(a, try runner.get(op, "expect"), .{}) });
                for (run.ready) |got| std.debug.print(" {s}", .{got.path});
                std.debug.print("\n", .{});
                return error.ContractMismatch;
            }
            // Reading what is ready stores nothing.
            try std.testing.expectEqual(saves, ctx.saves);
        } else if (std.mem.eql(u8, kind, "submit")) {
            request.agent = .{ .record = record, .submission = .{ .path = (try runner.get(op, "path")).string, .pass = @intCast((try runner.get(op, "pass")).integer), .output = try runner.get(op, "output") } };
            var run = try runner.execute(std.testing.allocator, request, ctx.ports());
            defer run.deinit();
            const want = (try runner.get(op, "expect")).string;
            if (!std.mem.eql(u8, want, @tagName(run.answer.?))) {
                std.debug.print("Conformance 0.3 {s} op {d}: submit expected {s}, got {s}\n", .{ name, index, want, @tagName(run.answer.?) });
                return error.ContractMismatch;
            }
            if (run.answer.? == .conflict) try std.testing.expect(run.committed != null);
        } else if (std.mem.eql(u8, kind, "cancel")) {
            request.agent = .{ .record = record, .op = .cancel };
            var run = try runner.execute(std.testing.allocator, request, ctx.ports());
            run.deinit();
        } else return error.UnknownFixtureOp;
    }
    return schema.parse(a, ctx.stored.?);
}
const fixtures_0_3 = "packages/loops-contract/0.3/fixtures";
/// One loops/0.3 fixture against its expected trace. False when the machine cannot run it
/// (the node fixture without a supported Node); every other problem is an error.
fn conform(name: []const u8) !bool {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try schema.parse(a, try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ fixtures_0_3, name }), a, .limited(1048576)));
    var files: std.ArrayList(package.File) = .empty;
    var fi = (try runner.get(fixture, "packageFiles")).object.iterator();
    while (fi.next()) |f| try files.append(a, .{ .path = f.key_ptr.*, .bytes = f.value_ptr.string });
    const pkg = package.fromFiles(std.testing.allocator, files.items, (try runner.get(fixture, "manifestPath")).string) catch |err| {
        std.debug.print("Conformance 0.3 package rejected {s}: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    defer pkg.deinit();
    var cancelled = std.atomic.Value(bool).init(false);
    const scenario = try runner.get(fixture, "scenario");
    const agent = if (scenario.object.get("driver")) |driver| std.mem.eql(u8, driver.string, "agent") else false;
    const responses: []const Value = if (scenario.object.get("responses")) |frozen| frozen.array.items else &.{};
    const claimed = try a.alloc(bool, responses.len);
    @memset(claimed, false);
    var ctx = Fixture{ .pkg = pkg, .responses = responses, .claimed = claimed, .cancel = &cancelled, .agent = agent };
    defer if (ctx.stored) |bytes| std.testing.allocator.free(bytes);
    var record: Value = undefined;
    var run: ?runner.Run = null;
    defer if (run) |*finished| finished.deinit();
    if (agent) record = try drive(a, name, &ctx, fixture, &cancelled) else {
        run = try runner.execute(std.testing.allocator, .{ .run_id = "contract-fixture", .manifest = pkg.manifest, .input = try runner.get(fixture, "input"), .cancel = &cancelled, .deadline_ms = 1000 }, ctx.ports());
        record = run.?.record;
    }
    if (ctx.node_missing) return false;
    const actual = try trace03(a, pkg.manifest, record);
    const expected_path = try std.fmt.allocPrint(a, "packages/loops-contract/0.3/expected/{s}", .{name});
    const expected = try schema.parse(a, try std.Io.Dir.cwd().readFileAlloc(io, expected_path, a, .limited(1048576)));
    if (!schema.equal(actual, expected)) {
        std.debug.print("Conformance 0.3 mismatch {s}\nActual: {s}\nExpected: {s}\n", .{ name, try std.json.Stringify.valueAlloc(a, actual, .{}), try std.json.Stringify.valueAlloc(a, expected, .{}) });
        return error.ContractMismatch;
    }
    for (claimed, responses) |taken, response| if (!taken) {
        std.debug.print("Conformance 0.3 unused response in {s}: {s}\n", .{ name, (try runner.get(response, "path")).string });
        return error.UnusedFrozenResponse;
    };
    return true;
}
// The one fixture that needs a tool the machine may lack. It has its own test so that
// its absence is a visible skip and never hides or weakens the other thirteen.
const node_fixture_name = "node-runtime.json";
test "native loops 0.3 shared contract matches all thirteen local traces, agent driver included, of fourteen fixtures" {
    const io = std.testing.io;
    var directory = try std.Io.Dir.cwd().openDir(io, fixtures_0_3, .{ .iterate = true });
    defer directory.close(io);
    var it = directory.iterate();
    var count: usize = 0;
    var agent_driven: usize = 0;
    var elsewhere: usize = 0;
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (std.mem.eql(u8, entry.name, node_fixture_name)) {
            elsewhere += 1;
            continue;
        }
        try std.testing.expect(try conform(entry.name));
        if (std.mem.startsWith(u8, entry.name, "agent-driver")) agent_driven += 1;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 13), count);
    try std.testing.expectEqual(@as(usize, 4), agent_driven);
    // Fourteen in all: the node fixture is the next test.
    try std.testing.expectEqual(@as(usize, 1), elsewhere);
}
test "native loops 0.3 node runtime fixture matches its expected trace on this machine's Node" {
    if (!try conform(node_fixture_name)) {
        std.debug.print("SKIPPED loops/0.3 fixture {s}: this machine has no Node the runtime supports (22.15 or newer). The other thirteen fixtures are unaffected.\n", .{node_fixture_name});
        return error.SkipZigTest;
    }
}
