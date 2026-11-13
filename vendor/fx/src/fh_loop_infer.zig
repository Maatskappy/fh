//! A portable infer step uses the same native fx provider as chat, with no
//! conversation history, project context, caller tools, or second orchestrator.
const std = @import("std");
const runner = @import("../../../native/loops/runner.zig");
const package = @import("../../../native/loops/package.zig");
const bindings = @import("../../../native/loops/bindings.zig");
const schema = @import("../../../native/loops/schema.zig");
const stream = @import("core/agent/stream_provider.zig");
const credentials = @import("core/auth/credentials.zig");
const types = @import("core/shared/types.zig");
const io_mod = @import("core/shared/io.zig");
const model_provider = @import("core/config/model_provider.zig");

pub const Context = struct {
    transport_scope: ?*@import("core/shared/http_pool.zig").Scope = null,
    provider: ?stream.Provider = null,
    credential_context: ?*anyopaque = null,
    credentialFn: *const fn (?*anyopaque, std.mem.Allocator, model_provider.ProviderId) anyerror!credentials.Credential = resolveCredential,
    io: ?std.Io = null,
};

/// Read native fx's local selection only when a validated package needs infer.
/// Caller owns the three copied strings; no credential/catalog/provider work.
pub fn defaultSelection(allocator: std.mem.Allocator, workspace: []const u8) !runner.Selection {
    const config = @import("core/config/config_runtime.zig");
    var settings = try config.loadMergedSettings(allocator, workspace);
    defer settings.deinit(allocator);
    const override = if (config.providerEnvOverride()) |name| model_provider.parse(name) orelse return error.InvalidSelection else null;
    const selected = try config.selectProviderModel(@import("builtins/gateway.zig").default_model, &settings, override, config.modelEnvOverride());
    return selectionFromSettings(allocator, &settings, selected);
}

fn selectionFromSettings(allocator: std.mem.Allocator, settings: *const @import("core/config/config_runtime.zig").Settings, selected: model_provider.ProviderSelection) !runner.Selection {
    const provider = try allocator.dupe(u8, selected.provider.label());
    errdefer allocator.free(provider);
    const model = try allocator.dupe(u8, selected.model);
    errdefer allocator.free(model);
    const effort = settings.effort orelse types.ReasoningEffort.literal("medium");
    const reasoning = try allocator.dupe(u8, effort.label());
    return .{ .provider = provider, .model = model, .reasoning = reasoning, .fast = settings.fast_mode orelse true };
}

fn resolveCredential(_: ?*anyopaque, allocator: std.mem.Allocator, provider: model_provider.ProviderId) !credentials.Credential {
    var settings = try @import("core/config/config_runtime.zig").loadMergedSettings(allocator, ".");
    defer settings.deinit(allocator);
    const resolution = try credentials.resolveForProvider(allocator, @import("builtins/gateway.zig").oauth_transport_provider, @import("core/hosts/native.zig").secret_store, .refresh_if_needed, provider, if (provider == .gateway) settings.credential_source else null);
    return resolution.credential orelse error.NativeProviderLoginRequired;
}

pub fn selectedProvider(selection: runner.Selection) !model_provider.ProviderId {
    var provider = model_provider.parse(selection.provider) orelse return error.InvalidSelection;
    if (provider == .configured) {
        var registry = try @import("core/config/config_runtime.zig").loadConfiguredProviders(std.heap.c_allocator);
        defer registry.deinit(std.heap.c_allocator);
        provider = try provider.bind(registry);
        if (selection.fast or (!std.mem.eql(u8, selection.reasoning, "none") and !std.mem.eql(u8, selection.reasoning, "auto"))) return error.UnsupportedInferenceProviderOption;
    }
    return provider;
}

fn validateDefinition(definition: runner.Value) !void {
    if (definition != .object) return error.InvalidDefinition;
    if (definition.object.get("requires")) |requires| {
        if (requires != .array) return error.InvalidDefinition;
        // A declaration alone is not an executable adapter grant.
        if (requires.array.items.len != 0 and (requires.array.items.len != 1 or requires.array.items[0] != .string or !std.mem.eql(u8, requires.array.items[0].string, "browser"))) return error.UnsupportedInferenceCapability;
    }
    _ = try runner.text(try runner.get(definition, "instructions"));
}

fn validateWireSchema(value: runner.Value) anyerror!void {
    switch (value) {
        .object => |map| {
            // Package validation can resolve retained companion documents, but
            // the provider sees only this schema. Never send unresolved refs.
            if (map.contains("$ref")) return error.UnsupportedInferenceSchema;
            for (map.values()) |child| try validateWireSchema(child);
        },
        .array => |items| for (items.items) |child| try validateWireSchema(child),
        else => {},
    }
}

fn structuredSchema(value: runner.Value) bool {
    if (value != .object) return false;
    const kind = value.object.get("type") orelse return false;
    return kind == .string and std.mem.eql(u8, kind.string, "object");
}

pub fn preflight(_: *anyopaque, definition: runner.Value, pkg: *package.Package, binding: *bindings.Binding, selection: runner.Selection) !void {
    try validateDefinition(definition);
    if (@import("../../../native/loops/browser.zig").required(definition)) _ = try @import("../../../native/loops/browser.zig").configuredPath(binding.arena.allocator(), io_mod.getIo(), binding);
    _ = try selectedProvider(selection);
    try validateWireSchema(try pkg.stepSchema(try runner.text(try runner.get(definition, "id"))));
}

pub fn execute(raw: *anyopaque, allocator: std.mem.Allocator, request: runner.StepRequest, _: *package.Package, _: *bindings.Binding) !runner.StepResult {
    const context: *Context = @ptrCast(@alignCast(raw));
    return invoke(context, allocator, request);
}

const Gate = struct {
    io: std.Io,
    request: runner.StepRequest,
    fn check(self: *const Gate) !void {
        if (self.request.cancel.load(.acquire)) return error.Cancelled;
        if (std.Io.Clock.awake.now(self.io).toMilliseconds() >= self.request.deadline_ms) return error.TimeLimit;
        if (self.request.limits.max_tokens == 0) return error.TokenLimit;
    }
    fn admit(raw: *anyopaque) !void {
        const self: *Gate = @ptrCast(@alignCast(raw));
        try self.check();
    }
    fn ignore(_: *anyopaque, _: stream.Event) void {}
};

pub fn measured(completed: stream.Completed) ?runner.Usage {
    const usage = if (completed.usage == .exact) completed.completion.usage else completed.final_token_usage orelse return null;
    return .{ .input_tokens = usage.input_tokens orelse return null, .output_tokens = usage.output_tokens orelse return null };
}

fn failed(usage: ?runner.Usage, failure: anyerror) runner.StepResult {
    // The runner persists actual usage before rejecting late/invalid output.
    return .{ .output = .null, .usage = usage, .failure = failure };
}

fn invoke(context: *Context, allocator: std.mem.Allocator, request: runner.StepRequest) !runner.StepResult {
    try validateDefinition(request.definition);
    if (@import("../../../native/loops/browser.zig").required(request.definition)) {
        if (request.capability == null) return error.UnsupportedInferenceCapability;
        try validateWireSchema(request.response_schema);
        return @import("fh_browser_agent.zig").invoke(context, allocator, request);
    }
    const provider_id = try selectedProvider(request.selection);
    try validateWireSchema(request.response_schema);
    var gate: Gate = .{ .io = context.io orelse io_mod.getIo(), .request = request };
    try gate.check();
    const input = try std.json.Stringify.valueAlloc(allocator, request.input, .{});
    defer allocator.free(input);
    if (input.len > request.limits.max_output_bytes) return error.InputLimit;
    const step_instructions = try runner.text(try runner.get(request.definition, "instructions"));
    const structured = provider_id != .configured and structuredSchema(request.response_schema);
    const schema_json = if (!structured) try std.json.Stringify.valueAlloc(allocator, request.response_schema, .{}) else null;
    defer if (schema_json) |bytes| allocator.free(bytes);
    const instructions = if (schema_json) |bytes| try std.fmt.allocPrint(allocator, "{s}\n\nReturn exactly one JSON value matching this declared output schema:\n{s}", .{ step_instructions, bytes }) else null;
    defer if (instructions) |bytes| allocator.free(bytes);
    if (instructions) |bytes| if (bytes.len > request.limits.max_output_bytes) return error.InputLimit;
    var credential = try context.credentialFn(context.credential_context, allocator, provider_id);
    defer credential.deinit(allocator);
    try gate.check();
    const deadline = std.Io.Clock.Timestamp.fromNow(gate.io, .{ .clock = .awake, .raw = .fromMilliseconds(request.deadline_ms - std.Io.Clock.awake.now(gate.io).toMilliseconds()) });
    var delivery: stream.DeliveryCertainty = .init();
    var evidence: stream.AttemptEvidence = .{};
    const cancel = @constCast(request.cancel);
    // Own the original configured route for the complete stream lifetime.
    var registry = if (provider_id == .configured) try @import("core/config/config_runtime.zig").loadConfiguredProviders(allocator) else @import("core/config/configured_provider.zig").Registry{};
    defer registry.deinit(allocator);
    const bound_provider = try provider_id.bind(registry);
    var providers = @import("builtins/providers.zig").native;
    providers.definitions = registry.definitions;
    var provider = context.provider orelse providers.select(bound_provider).agent_stream orelse return error.UnsupportedInferenceProvider;
    // Only the native Codex provider accepts this scope context. Configured
    // providers and injected test providers retain their own pointer types.
    if (context.provider == null and provider_id == .codex) provider.context = context.transport_scope;
    const provider_options: @import("core/config/model_capabilities.zig").ResolvedProviderOptions = if (provider_id == .configured) .{} else .{ .reasoning = types.ReasoningEffort.parse(request.selection.reasoning) orelse return error.InvalidSelection, .fast = request.selection.fast };
    if (request.model_dispatch) |dispatch| dispatch.record();
    var result = provider.stream(allocator, .{
        .credential = .{ .direct = .{ .secret_bytes = credential.token, .source = credential.source, .account_id = credential.accountId() } },
        .model = request.selection.model,
        .retry_count = 1,
        .instructions = &.{.{ .role = .system, .content = instructions orelse step_instructions }},
        .messages = &.{.{ .role = .user, .content = input }},
        .tools = .{},
        .tool_choice = .auto,
        // Keep the trusted native reasoning selection. A package complexity
        // hint does not silently change the selected account's request policy.
        .provider_options = provider_options,
        // Codex does not accept max_output_tokens. Keep the actual Loop token
        // meter and native deadline; do not claim a remote generation ceiling.
        .budget = .{ .deadline = deadline, .cancel_flag = cancel },
        .response_format = if (structured) .{ .name = "loop_output", .description = "The bound portable Loop step output.", .schema = request.response_schema } else null,
        .trace_ctx = .{},
        .content_capture_limit = request.limits.max_output_bytes,
        .deadline = deadline,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .events = .{ .context = &gate, .emit_fn = Gate.ignore },
        .admission = .{ .context = &gate, .admit_fn = Gate.admit },
        .cancel_flag = cancel,
    }) catch |err| {
        if (delivery.load() == .possibly_sent) return failed(null, err);
        return err;
    };
    defer result.deinit(allocator);
    const completed = switch (result) {
        .completed => |value| value,
        .failed => |failure| return failed(null, switch (failure.kind) {
            .unauthorized => error.NativeProviderLoginRequired,
            .forbidden => error.NativeProviderAccessDenied,
            .rate_limited => error.NativeProviderRateLimited,
            .invalid_request => error.NativeProviderInvalidRequest,
            .request_too_large => error.NativeProviderRequestTooLarge,
            .server_error => error.NativeProviderServerError,
            .bad_gateway => error.NativeProviderBadGateway,
            .unavailable => error.NativeProviderUnavailable,
            .gateway_timeout => error.NativeProviderGatewayTimeout,
            .provider_error => error.NativeInferenceFailed,
        }),
    };
    const usage = measured(completed);
    if (completed.completion.tool_calls.len != 0) return failed(usage, error.UnadvertisedInferenceTool);
    const content = completed.completion.content orelse return failed(usage, error.InvalidInferenceOutput);
    if (content.len > request.limits.max_output_bytes) return failed(usage, error.OutputLimit);
    const output = schema.parse(allocator, content) catch |err|
        return failed(usage, err);
    return .{ .output = output, .usage = usage };
}

const Fixture = struct {
    dispatches: usize = 0,
    credential_calls: usize = 0,
    provider_calls: usize = 0,
    content: []const u8 = "{\"draft\":\"Bound subject\"}",
    usage: stream.UsageOutcome = .{ .exact = .codex },
    primitive_output: bool = false,
    failure_kind: ?stream.FailureKind = null,
    fn dispatched(raw: *anyopaque) void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.dispatches += 1;
    }
    fn credential(raw: ?*anyopaque, allocator: std.mem.Allocator, provider: model_provider.ProviderId) !credentials.Credential {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.credential_calls += 1;
        try std.testing.expect(provider == .codex);
        return .{ .token = try allocator.dupe(u8, "fixture-only"), .source = .chatgpt_subscription };
    }
    fn provide(raw: ?*anyopaque, _: std.mem.Allocator, model_request: stream.ModelRequest) !stream.Result {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.provider_calls += 1;
        try model_request.admission.admit();
        model_request.delivery.markPossiblySent();
        try std.testing.expectEqualStrings("gpt-6-luna", model_request.model);
        try std.testing.expectEqualStrings("medium", model_request.provider_options.reasoning.?.label());
        try std.testing.expect(model_request.provider_options.fast);
        try std.testing.expectEqual(@as(usize, 1), model_request.instructions.len);
        if (self.primitive_output) {
            try std.testing.expect(std.mem.startsWith(u8, model_request.instructions[0].content.?, "Only the bound subject.\n\nReturn exactly one JSON value"));
            try std.testing.expect(model_request.response_format == null);
        } else {
            try std.testing.expectEqualStrings("Only the bound subject.", model_request.instructions[0].content.?);
            try std.testing.expect(model_request.response_format.?.schema == .object);
        }
        try std.testing.expectEqual(@as(usize, 1), model_request.messages.len);
        try std.testing.expectEqualStrings("{\"subject\":\"blue\"}", model_request.messages[0].content.?);
        try std.testing.expectEqual(@as(usize, 0), model_request.tools.advertised_names.len);
        try std.testing.expectEqual(@as(usize, 0), model_request.tools.selected_dynamic.len);
        try std.testing.expect(model_request.deadline != null);
        if (self.failure_kind) |kind| return .{ .failed = .{ .kind = kind, .detail = @constCast("synthetic-private-provider-detail: fixture-secret"), .diagnostics = .{ .schema = @constCast("synthetic-private-schema"), .request_shape = @constCast("synthetic-private-request") } } };
        return .{ .completed = .{ .completion = .{ .content = @constCast(self.content), .usage = .{ .input_tokens = 21, .output_tokens = 9 } }, .usage = self.usage } };
    }
    fn journal(_: *anyopaque, _: runner.Effect) !void {}
    fn request(allocator: std.mem.Allocator, cancel: *std.atomic.Value(bool), fixture: *Fixture) !runner.StepRequest {
        return .{ .run_id = "fixture", .step_id = "write", .iteration = 0, .definition = try std.json.parseFromSliceLeaky(runner.Value, allocator, "{\"requires\":[],\"instructions\":\"Only the bound subject.\"}", .{}), .input = try std.json.parseFromSliceLeaky(runner.Value, allocator, "{\"subject\":\"blue\"}", .{}), .response_schema = try std.json.parseFromSliceLeaky(runner.Value, allocator, "{\"type\":\"object\"}", .{}), .selection = .{}, .limits = .{}, .cancel = cancel, .deadline_ms = std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds() + 2000, .journal = .{ .context = fixture, .recordFn = journal }, .model_dispatch = .{ .context = fixture, .recordFn = dispatched } };
    }
    fn context(self: *Fixture) Context {
        return .{ .provider = .{ .context = self, .stream_fn = provide }, .credential_context = self, .credentialFn = credential };
    }
};

test "fh native infer uses only bound input and original structured provider contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = .{};
    var context = fixture.context();
    var cancel = std.atomic.Value(bool).init(false);
    const request = try Fixture.request(arena.allocator(), &cancel, &fixture);
    const result = try invoke(&context, arena.allocator(), request);
    try std.testing.expectEqualStrings("Bound subject", result.output.object.get("draft").?.string);
    try std.testing.expectEqual(@as(u64, 21), result.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 9), result.usage.?.output_tokens);
    try std.testing.expectEqual(@as(usize, 1), fixture.provider_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.dispatches);
}

// Deterministic code/provider fixtures exercise the real binding runner, infer
// adapter and Codex wire builder; they do not contact a live model or runtime.
const WarmLoopFixture = struct {
    pkg: *package.Package,
    prepare_calls: usize = 0,
    assess_calls: usize = 0,
    provider_calls: usize = 0,
    credential_calls: usize = 0,
    const instructions = "Use all prepared task, rules and evidence. Revise the prior draft using feedback. Return only the declared draft object.";
    const input = "{\"task\":\"Explain the migration\",\"rules\":[\"Cite evidence\",\"Avoid unsupported claims\"],\"evidence\":[\"42 rows copied\",\"checksum matched\"],\"ambient\":\"Unbound caller history must stay out\"}";
    const prepared = "{\"task\":\"Explain the migration\",\"rules\":[\"Cite evidence\",\"Avoid unsupported claims\"],\"evidence\":[\"42 rows copied\",\"checksum matched\"],\"prepared\":\"2 facts ready\"}";
    const manifest =
        \\{"format":"loops/0.1","name":"warm-fixture","version":"1",
        \\"inputs":{"schema":{"type":"object","required":["task","rules","evidence"],"properties":{"task":{"type":"string"},"rules":{"type":"array","items":{"type":"string"}},"evidence":{"type":"array","items":{"type":"string"}}}}},
        \\"steps":[
        \\{"id":"prepare","kind":"code","runtime":"fixture","file":"prepare.zig","input":{"task":{"from":"/input/task"},"rules":{"from":"/input/rules"},"evidence":{"from":"/input/evidence"}},"output":{"schema":"prepared.json"}},
        \\{"id":"write","kind":"infer","instructions":"Use all prepared task, rules and evidence. Revise the prior draft using feedback. Return only the declared draft object.","input":{"context":{"from":"/steps/prepare/output"},"prior":{"from":"/carry/draft"},"feedback":{"from":"/carry/feedback"}},"output":{"schema":"draft.json"}},
        \\{"id":"assess","kind":"code","runtime":"fixture","file":"assess.zig","input":{"from":"/steps/write/output"},"output":{"schema":{"type":"object","required":["accepted","feedback"],"properties":{"accepted":{"type":"boolean"},"feedback":{"type":"string"}},"additionalProperties":false}}}],
        \\"repeat":{"from":"write","through":"assess","until":{"from":"/steps/assess/output/accepted"},"max_iterations":2,"carry":{"initial":{"value":{"draft":null,"feedback":""}},"next":{"draft":{"from":"/steps/write/output"},"feedback":{"from":"/steps/assess/output/feedback"}}}},
        \\"output":{"from":"/steps/write/output"}}
    ;
    fn credential(raw: ?*anyopaque, alloc: std.mem.Allocator, provider: model_provider.ProviderId) !credentials.Credential {
        const self: *WarmLoopFixture = @ptrCast(@alignCast(raw.?));
        self.credential_calls += 1;
        try std.testing.expect(provider == .codex);
        return .{ .token = try alloc.dupe(u8, "fixture-only"), .source = .chatgpt_subscription };
    }
    fn provide(raw: ?*anyopaque, alloc: std.mem.Allocator, request: stream.ModelRequest) !stream.Result {
        const self: *WarmLoopFixture = @ptrCast(@alignCast(raw.?));
        self.provider_calls += 1;
        try std.testing.expect(self.provider_calls <= 2);
        try request.admission.admit();
        const body = try @import("gateway/openai_codex.zig").buildRequest(alloc, request.data());
        defer alloc.free(body);
        const wire = try schema.parse(alloc, body);
        try std.testing.expectEqualStrings(instructions, (try runner.get(wire, "instructions")).string);
        try std.testing.expectEqualStrings("gpt-6-luna", (try runner.get(wire, "model")).string);
        try std.testing.expectEqualStrings("medium", (try runner.get(try runner.get(wire, "reasoning"), "effort")).string);
        try std.testing.expectEqualStrings("priority", (try runner.get(wire, "service_tier")).string);
        try std.testing.expect(wire.object.get("tools") == null);
        const format = try runner.get(try runner.get(wire, "text"), "format");
        try std.testing.expect((try runner.get(format, "strict")).bool);
        try std.testing.expect(schema.equal(try self.pkg.stepSchema("write"), try runner.get(format, "schema")));
        const messages = (try runner.get(wire, "input")).array.items;
        try std.testing.expectEqual(@as(usize, 1), messages.len);
        try std.testing.expectEqualStrings("user", (try runner.get(messages[0], "role")).string);
        const content = (try runner.get(messages[0], "content")).array.items;
        try std.testing.expectEqual(@as(usize, 1), content.len);
        const bound = try schema.parse(alloc, (try runner.get(content[0], "text")).string);
        try std.testing.expectEqual(@as(usize, 3), bound.object.count());
        try std.testing.expect(schema.equal(try schema.parse(alloc, prepared), try runner.get(bound, "context")));
        const prior = try runner.get(bound, "prior");
        if (self.provider_calls == 1) {
            try std.testing.expect(prior == .null);
            try std.testing.expectEqualStrings("", (try runner.get(bound, "feedback")).string);
        } else {
            try std.testing.expect(schema.equal(try schema.parse(alloc, "{\"draft\":\"Unproven claim\"}"), prior));
            try std.testing.expectEqualStrings("Cite both prepared facts", (try runner.get(bound, "feedback")).string);
        }
        request.delivery.markPossiblySent();
        const output = if (self.provider_calls == 1) "{\"draft\":\"Unproven claim\"}" else "{\"draft\":\"42 rows copied; checksum matched\"}";
        return .{ .completed = .{ .completion = .{ .content = @constCast(output), .usage = .{ .input_tokens = 21, .output_tokens = 9 } }, .usage = .{ .exact = .codex } } };
    }
    fn step(raw: *anyopaque, alloc: std.mem.Allocator, request: runner.StepRequest) !runner.StepResult {
        const self: *WarmLoopFixture = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, request.step_id, "prepare")) {
            self.prepare_calls += 1;
            const bytes = try std.json.Stringify.valueAlloc(alloc, request.input, .{});
            defer alloc.free(bytes);
            var output = try schema.parse(alloc, bytes);
            try output.object.put(alloc, "prepared", .{ .string = "2 facts ready" });
            return .{ .output = output };
        }
        if (std.mem.eql(u8, request.step_id, "write")) {
            var context: Context = .{ .provider = .{ .context = self, .stream_fn = provide }, .credential_context = self, .credentialFn = credential };
            return invoke(&context, alloc, request);
        }
        try std.testing.expectEqualStrings("assess", request.step_id);
        self.assess_calls += 1;
        const draft = (try runner.get(request.input, "draft")).string;
        const accepted = std.mem.eql(u8, draft, "42 rows copied; checksum matched");
        if (!accepted) try std.testing.expectEqualStrings("Unproven claim", draft);
        return .{ .output = try schema.parse(alloc, if (accepted) "{\"accepted\":true,\"feedback\":\"\"}" else "{\"accepted\":false,\"feedback\":\"Cite both prepared facts\"}") };
    }
    fn validate(raw: *anyopaque, id: ?[]const u8, value: runner.Value) !void {
        const self: *WarmLoopFixture = @ptrCast(@alignCast(raw));
        if (id) |step_id| try self.pkg.validateStepOutput(step_id, value) else try self.pkg.validateInput(value);
    }
    fn outputSchema(raw: *anyopaque, id: []const u8) !runner.Value {
        const self: *WarmLoopFixture = @ptrCast(@alignCast(raw));
        return self.pkg.stepSchema(id);
    }
    fn persist(_: *anyopaque, _: runner.Value, _: []const u8) !void {}
    fn now(_: *anyopaque) i64 {
        return std.Io.Clock.awake.now(io_mod.getIo()).toMilliseconds();
    }
    fn ports(self: *WarmLoopFixture) runner.Ports {
        return .{ .context = self, .executeFn = step, .validateFn = validate, .persistFn = persist, .nowFn = now, .schemaFn = outputSchema };
    }
};

test "fh native Loop first provider wire is warm from prepared context and actual carry" {
    const pkg = try package.fromFiles(std.testing.allocator, &.{
        .{ .path = "loop.json", .bytes = WarmLoopFixture.manifest },
        .{ .path = "prepare.zig", .bytes = "deterministic preparation fixture" },
        .{ .path = "assess.zig", .bytes = "deterministic assessment fixture" },
        .{ .path = "prepared.json", .bytes = "{\"type\":\"object\",\"required\":[\"task\",\"rules\",\"evidence\",\"prepared\"],\"properties\":{\"task\":{\"type\":\"string\"},\"rules\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"evidence\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"prepared\":{\"type\":\"string\"}},\"additionalProperties\":false}" },
        .{ .path = "draft.json", .bytes = "{\"type\":\"object\",\"required\":[\"draft\"],\"properties\":{\"draft\":{\"type\":\"string\"}},\"additionalProperties\":false}" },
    }, "loop.json");
    defer pkg.deinit();
    var fixture: WarmLoopFixture = .{ .pkg = pkg };
    var cancel = std.atomic.Value(bool).init(false);
    const request: runner.Request = .{ .run_id = "warm-wire", .manifest = pkg.manifest, .input = try schema.parse(pkg.arena.allocator(), WarmLoopFixture.input), .cancel = &cancel, .deadline_ms = WarmLoopFixture.now(&fixture) + 10000 };
    var run = try runner.execute(std.testing.allocator, request, fixture.ports());
    defer run.deinit();
    try std.testing.expectEqualStrings("completed", (try runner.get(run.record, "status")).string);
    try std.testing.expectEqualStrings("42 rows copied; checksum matched", (try runner.get(try runner.get(run.record, "output"), "draft")).string);
    try std.testing.expectEqual(@as(usize, 1), fixture.prepare_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.assess_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.provider_calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.credential_calls);
    try std.testing.expectEqual(@as(i64, 60), (try runner.get(run.record, "used_tokens")).integer);
    try std.testing.expectEqual(@as(i64, 2), (try runner.get(run.record, "model_request_dispatches")).integer);
    try std.testing.expect((try runner.get(run.record, "model_request_dispatches_complete")).bool);
    try std.testing.expectEqual(@as(i64, 0), (try runner.get(run.record, "used_tool_calls")).integer);

    // A missing declared context cannot trigger auth or a setup model request.
    var write_input = pkg.manifest.object.getPtr("steps").?.array.items[1].object.getPtr("input").?;
    try write_input.object.put(pkg.arena.allocator(), "context", try schema.parse(pkg.arena.allocator(), "{\"from\":\"/steps/prepare/output/absent\"}"));
    fixture = .{ .pkg = pkg };
    var missing = try runner.execute(std.testing.allocator, request, fixture.ports());
    defer missing.deinit();
    try std.testing.expectEqualStrings("failed", (try runner.get(missing.record, "status")).string);
    try std.testing.expectEqual(@as(i64, 0), (try runner.get(missing.record, "model_request_dispatches")).integer);
    try std.testing.expectEqualStrings("MissingBinding", (try runner.get(try runner.get(missing.record, "error"), "cause")).string);
    try std.testing.expectEqual(@as(usize, 1), fixture.prepare_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.credential_calls);
}

test "fh native infer accepts omitted requirements and primitive output without a new engine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = .{ .content = "42", .primitive_output = true };
    var context = fixture.context();
    var cancel = std.atomic.Value(bool).init(false);
    var request = try Fixture.request(arena.allocator(), &cancel, &fixture);
    request.definition = try schema.parse(arena.allocator(), "{\"instructions\":\"Only the bound subject.\"}");
    request.response_schema = .{ .bool = true };
    const result = try invoke(&context, arena.allocator(), request);
    try std.testing.expectEqual(@as(i64, 42), result.output.integer);
    try std.testing.expectEqual(@as(u64, 21), result.usage.?.input_tokens);
}

test "fh native infer honors compatible provider routes and rejects unsupported routes and refs before auth" {
    const providers = @import("builtins/providers.zig");
    const codex_id = try selectedProvider(.{});
    const grok_id = try selectedProvider(.{ .provider = "grok" });
    try std.testing.expect(providers.native.select(codex_id).agent_stream.?.stream_fn == @import("gateway/openai_codex.zig").agent_stream_provider.stream_fn);
    try std.testing.expect(providers.native.select(grok_id).agent_stream.?.stream_fn == @import("gateway/xai_grok.zig").agent_stream_provider.stream_fn);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = .{};
    var context = fixture.context();
    var cancel = std.atomic.Value(bool).init(false);
    var request = try Fixture.request(arena.allocator(), &cancel, &fixture);
    request.selection.provider = "local-endpoint";
    try std.testing.expectError(error.UnknownConfiguredProvider, invoke(&context, arena.allocator(), request));
    request.selection.provider = "codex";
    request.response_schema = try schema.parse(arena.allocator(), "{\"$ref\":\"other.json\"}");
    try std.testing.expectError(error.UnsupportedInferenceSchema, invoke(&context, arena.allocator(), request));
    try std.testing.expectEqual(@as(usize, 0), fixture.credential_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.dispatches);
}

test "fh native Loop selection preserves native settings without resolving auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const settings = @import("core/config/config_runtime.zig").Settings{ .effort = types.ReasoningEffort.literal("low"), .fast_mode = false };
    const selected = try selectionFromSettings(arena.allocator(), &settings, .{ .provider = .grok, .model = "explicit-grok" });
    try std.testing.expectEqualStrings("grok", selected.provider);
    try std.testing.expectEqualStrings("explicit-grok", selected.model);
    try std.testing.expectEqualStrings("low", selected.reasoning);
    try std.testing.expect(!selected.fast);
}

test "fh native infer rejects capabilities cancellation and exhausted budget before auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = .{};
    var context = fixture.context();
    var cancel = std.atomic.Value(bool).init(true);
    var request = try Fixture.request(arena.allocator(), &cancel, &fixture);
    try std.testing.expectError(error.Cancelled, invoke(&context, arena.allocator(), request));
    cancel.store(false, .release);
    request.limits.max_tokens = 0;
    try std.testing.expectError(error.TokenLimit, invoke(&context, arena.allocator(), request));
    request.limits.max_tokens = 8000;
    request.deadline_ms = 0;
    try std.testing.expectError(error.TimeLimit, invoke(&context, arena.allocator(), request));
    request.definition = try std.json.parseFromSliceLeaky(runner.Value, arena.allocator(), "{\"requires\":[\"browser\"],\"instructions\":\"No fake adapter.\"}", .{});
    try std.testing.expectError(error.UnsupportedInferenceCapability, invoke(&context, arena.allocator(), request));
    try std.testing.expectEqual(@as(usize, 0), fixture.credential_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.dispatches);
}

test "fh native infer retains measured usage for invalid output and marks unavailable usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = .{ .content = "invalid JSON" };
    var context = fixture.context();
    var cancel = std.atomic.Value(bool).init(false);
    const request = try Fixture.request(arena.allocator(), &cancel, &fixture);
    const invalid = try invoke(&context, arena.allocator(), request);
    try std.testing.expect(invalid.failure != null);
    try std.testing.expectEqual(@as(u64, 21), invalid.usage.?.input_tokens);
    fixture.content = "{\"draft\":\"first\",\"draft\":\"duplicate\"}";
    const duplicate = try invoke(&context, arena.allocator(), request);
    try std.testing.expect(duplicate.failure != null);
    try std.testing.expectEqual(@as(u64, 9), duplicate.usage.?.output_tokens);
    fixture.content = "{\"draft\":\"Bound subject\"}";
    fixture.usage = .{ .unavailable = .possibly_billed };
    const unavailable = try invoke(&context, arena.allocator(), request);
    try std.testing.expect(unavailable.usage == null);
}

test "fh native direct inference requires original fx threaded bounded HTTP I/O" {
    const gateway = @import("gateway/client.zig");
    const Probe = struct {
        calls: usize = 0,
        const Result = struct {
            pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
        };
        pub fn run(self: *@This()) !Result {
            self.calls += 1;
            return .{};
        }
    };
    defer io_mod.setIo(std.testing.io);
    var fallback: std.Io.Threaded = .init_single_threaded;
    io_mod.setIo(fallback.io());
    var cancel = std.atomic.Value(bool).init(false);
    var probe: Probe = .{};
    const fallback_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(1000) });
    try std.testing.expectError(error.ConcurrencyUnavailable, gateway.runBoundedHttpOperation(Probe.Result, std.testing.allocator, &cancel, fallback_deadline, &probe));
    try std.testing.expectEqual(@as(usize, 0), probe.calls);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    io_mod.setIo(threaded.io());
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(1000) });
    var result = try gateway.runBoundedHttpOperation(Probe.Result, std.testing.allocator, &cancel, deadline, &probe);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "fh native infer unauthorized failure retains only static cause and no provider detail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = .{ .failure_kind = .unauthorized };
    var context = fixture.context();
    var cancel = std.atomic.Value(bool).init(false);
    const request = try Fixture.request(arena.allocator(), &cancel, &fixture);
    const result = try invoke(&context, arena.allocator(), request);
    try std.testing.expectEqual(@as(usize, 1), fixture.provider_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.dispatches);
    try std.testing.expectEqual(@as(usize, 1), fixture.credential_calls);
    try std.testing.expect(result.usage == null);
    try std.testing.expect(result.output == .null);
    try std.testing.expectEqual(error.NativeProviderLoginRequired, result.failure.?);
    const encoded = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .output = result.output, .usage = result.usage, .failure_cause = @errorName(result.failure.?) }, .{});
    try std.testing.expect(std.mem.indexOf(u8, encoded, "synthetic-private") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "fixture-secret") == null);
}

test "fh native infer maps every structured provider failure to its static cause" {
    const cases = [_]struct { kind: stream.FailureKind, cause: anyerror }{
        .{ .kind = .unauthorized, .cause = error.NativeProviderLoginRequired },
        .{ .kind = .forbidden, .cause = error.NativeProviderAccessDenied },
        .{ .kind = .rate_limited, .cause = error.NativeProviderRateLimited },
        .{ .kind = .invalid_request, .cause = error.NativeProviderInvalidRequest },
        .{ .kind = .request_too_large, .cause = error.NativeProviderRequestTooLarge },
        .{ .kind = .server_error, .cause = error.NativeProviderServerError },
        .{ .kind = .bad_gateway, .cause = error.NativeProviderBadGateway },
        .{ .kind = .unavailable, .cause = error.NativeProviderUnavailable },
        .{ .kind = .gateway_timeout, .cause = error.NativeProviderGatewayTimeout },
        .{ .kind = .provider_error, .cause = error.NativeInferenceFailed },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fixture: Fixture = .{ .failure_kind = case.kind };
        var context = fixture.context();
        var cancel = std.atomic.Value(bool).init(false);
        const request = try Fixture.request(arena.allocator(), &cancel, &fixture);
        const result = try invoke(&context, arena.allocator(), request);
        try std.testing.expectEqual(case.cause, result.failure.?);
        try std.testing.expect(result.usage == null);
        try std.testing.expect(result.output == .null);
        try std.testing.expectEqual(@as(usize, 1), fixture.dispatches);
        try std.testing.expectEqual(@as(usize, 1), fixture.provider_calls);
    }
}
