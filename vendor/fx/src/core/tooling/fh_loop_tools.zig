//! The fh authoring surface. Filesystem descriptors remain native fx tools.
const std = @import("std");
const builtins = @import("../../builtins/tools.zig");
const dispatch = @import("tool_dispatch.zig");
const schemas = @import("model_tool_schema.zig");
const tool_set = @import("tool_set.zig");
const pathing = @import("../workspace/pathing.zig");
const types = @import("../shared/types.zig");
const Allocator = std.mem.Allocator;
const names = [_][]const u8{ "read_file", "glob_files", "grep_files", "write_file", "edit_file", "docs_read", "loop_check", "loop_run", "loop_get", "loop_cancel", "loop_next", "loop_submit" };
const readonly = [_][]const u8{ "read_file", "glob_files", "grep_files", "docs_read", "loop_get", "loop_next" };
const package_properties = [_]schemas.Property{
    .{ .name = "packagePath", .json_type = .string, .bounds = &.{ .min_length = 1, .max_length = 4096 }, .description = "The NAME or NAME@VERSION of a package installed with fh add, or a package directory inside the active workspace. One segment with no slash is always an installed name, whatever the workspace holds. Write a workspace folder as ./NAME: a path starts with a dot or a slash. Anything else with a slash is a GitHub address, which this tool refuses: only the person can fetch and install a package, with /run ADDRESS." },
    .{ .name = "bindingsId", .json_type = .string, .bounds = &.{ .min_length = 1, .max_length = 128 }, .description = "Optional existing installed binding handle; never invent a handle." },
};
const run_properties = package_properties ++ [_]schemas.Property{
    .{ .name = "input", .json_type = .object, .description = "Explicit bounded JSON input validated by the package input schema." },
    .{ .name = "driver", .json_type = .string, .shape = &.{ .enum_values = &.{ "runner", "agent" } }, .description = "Optional. runner (default): fh performs every step. agent: fh makes no model call; you perform each infer and decision step that loop_next lists and send its output with loop_submit." },
};
const run_id_properties = [_]schemas.Property{.{ .name = "runId", .json_type = .string, .bounds = &.{ .min_length = 1, .max_length = 128 }, .description = "Exact durable run ID returned by loop_run." }};
// Settling an uncertain effect is a person's command (fh settle); it has no tool here.
const submit_properties = run_id_properties ++ [_]schemas.Property{
    .{ .name = "path", .json_type = .string, .bounds = &.{ .min_length = 1, .max_length = 4096 }, .description = "Exact step path from loop_next." },
    .{ .name = "pass", .json_type = .integer, .bounds = &.{ .minimum = 0, .maximum = 1048576 }, .description = "Exact pass number from loop_next." },
    .{ .name = "output", .json_type = .object, .description = "The step output as a JSON object satisfying the output_schema that loop_next gave." },
};
const docs_properties = [_]schemas.Property{
    .{ .name = "document", .json_type = .string, .shape = &.{ .enum_values = &.{ "guide", "workspace_guide", "schema", "decision_schema", "parallel_schema", "runtime_schema", "runtime_contract", "wasm_contract", "runtime_guide", "author_skill" } }, .description = "guide: the Loops authoring guide. workspace_guide: native workspace steps. schema: the loops/0.1 manifest schema. decision_schema: loops/0.2. parallel_schema: loops/0.3 (parallel, map, node code, workspace_read). runtime_schema: loops/0.4. runtime_contract: source dependencies. wasm_contract: wasm32-wasi-json/1. runtime_guide: editable source/Wasm examples and rebuild recipe. author_skill: the authoring skill." },
    .{ .name = "offset", .json_type = .integer, .bounds = &.{ .minimum = 0, .maximum = 1048576 } },
    .{ .name = "length", .json_type = .integer, .bounds = &.{ .minimum = 1, .maximum = 32768 } },
};
fn hostTool(comptime name: []const u8, comptime description: []const u8, comptime properties: []const schemas.Property, comptime required: []const []const u8, comptime reads_only: bool) dispatch.Tool {
    return .{ .name = name, .description = description, .model_schema = .{ .name = name, .description = description, .input_schema = .{ .properties = properties, .required = required, .additional_properties = false } }, .executor_kind = .host, .activity_kind = if (reads_only) .read else .command, .requires_approval = !reads_only, .permission_target_kind = .none, .action_label = if (reads_only) "Reading" else "Running", .completed_action_label = if (reads_only) "Read" else "Ran", .decode = struct {
        fn decodeNamed(ctx: dispatch.DispatchContext, arguments: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
            var named = ctx;
            named.tool_call_name = name;
            return decode(named, arguments);
        }
    }.decodeNamed, .validate = validate, .call = call, .reads_only_fn = if (reads_only) yes else no, .irreversible_fn = no };
}
pub const all = [_]dispatch.Tool{
    builtins.read_file,                                                                                                                                                                                                                               builtins.glob_files,                                                                                                                                                                                                                                                                                                                                builtins.grep_files,                                                                                                                                                                                                                                                                     builtins.write_file,                                                                                                                             builtins.edit_file,
    hostTool("docs_read", "Read a bounded slice of the shipped Loops guide, schema or authoring skill. Paths and internal source are not exposed.", &docs_properties, &.{"document"}, true),                                                          hostTool("loop_check", "Validate an exact saved package through the existing Loops service; diagnostics identify files and JSON pointers. Validation may probe an admitted runtime.", &package_properties, &.{"packagePath"}, false),                                                                                                               hostTool("loop_run", "Run an exact saved package with explicit input through the bound Loops runner. Waits for terminal state and returns its durable run ID; use loop_get for authoritative output. Existing child caps apply.", &run_properties, &.{ "packagePath", "input" }, false), hostTool("loop_get", "Get authoritative durable status, output and domain verdict for an exact run ID.", &run_id_properties, &.{"runId"}, true), hostTool("loop_cancel", "Cancel an exact owned durable run ID without discarding its durable record.", &run_id_properties, &.{"runId"}, false),
    hostTool("loop_next", "List every step of an agent-driven run that is ready for you now: path, pass, kind, resolved input, output_schema and instructions or questions. Empty when the run is terminal.", &run_id_properties, &.{"runId"}, true), hostTool("loop_submit", "Submit your output for one ready step of an agent-driven run, using the path and pass from loop_next. Read answer: accepted, rejected (fix the listed issues and submit again), not_ready or conflict. An accepted output may run saved code steps.", &submit_properties, &.{ "runId", "path", "pass", "output" }, false),
};
pub const set: tool_set.ToolSet = .{ .registry = .{ .tools = &all }, .order = &names, .read_only_tool_names = &readonly };
const Input = struct { json: []u8, name: []const u8 };
fn destroy(raw: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(raw));
    alloc.free(input.json);
    alloc.destroy(input);
}
fn decode(ctx: dispatch.DispatchContext, arguments: []const u8) dispatch.DispatchError!dispatch.DecodeResult {
    if (arguments.len > 65536) return error.InvalidToolArguments;
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, arguments, .{ .duplicate_field_behavior = .@"error" }) catch return error.InvalidToolArguments;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolArguments;
    const descriptor = set.registry.lookup(ctx.tool_call_name) orelse return error.InvalidToolArguments;
    try validateArguments(parsed.value.object, descriptor.model_schema.input_schema);
    const input = try ctx.allocator.create(Input);
    errdefer ctx.allocator.destroy(input);
    input.* = .{ .json = try ctx.allocator.dupe(u8, arguments), .name = descriptor.name };
    return .{ .input = .{ .ptr = input, .deinit_fn = destroy } };
}
fn validateArguments(object: std.json.ObjectMap, schema: schemas.ObjectSchema) !void {
    for (schema.required) |key| if (!object.contains(key)) return error.InvalidToolArguments;
    for (object.keys(), object.values()) |key, value| {
        for (schema.properties) |property| {
            if (!std.mem.eql(u8, key, property.name)) continue;
            switch (property.json_type) {
                .string => {
                    if (value != .string or value.string.len == 0 or value.string.len > (if (property.bounds) |bounds| bounds.max_length else 4096)) return error.InvalidToolArguments;
                    if (property.shape) |shape| switch (shape.*) {
                        .enum_values => |options| {
                            for (options) |option| {
                                if (std.mem.eql(u8, option, value.string)) break;
                            } else return error.InvalidToolArguments;
                        },
                        else => {},
                    };
                },
                .integer => {
                    if (value != .integer or value.integer < 0 or value.integer > 1048576) return error.InvalidToolArguments;
                    if (std.mem.eql(u8, key, "length") and (value.integer < 1 or value.integer > 32768)) return error.InvalidToolArguments;
                },
                .object => if (value != .object) return error.InvalidToolArguments,
                else => return error.InvalidToolArguments,
            }
            break;
        } else return error.InvalidToolArguments;
    }
}
fn validate(_: dispatch.DispatchContext, _: dispatch.ToolInput) dispatch.DispatchError!?[]u8 {
    return null;
}
fn call(ctx: dispatch.DispatchContext, input: dispatch.ToolInput) dispatch.DispatchError!dispatch.ToolResult {
    const provider = ctx.host_tool_provider orelse return error.InvalidToolArguments;
    return provider.call(ctx.allocator, input.as(Input).name, input.as(Input).json, ctx.max_tool_result_bytes, ctx.cancel_flag);
}
fn yes(_: dispatch.ToolInput) bool {
    return true;
}
fn no(_: dispatch.ToolInput) bool {
    return false;
}

/// True when a packagePath is an installed NAME or NAME@VERSION and not a workspace path:
/// one plain segment, starting with a letter or digit, of letters, digits, dot, underscore
/// and hyphen (a version may also use plus). The answer comes from the text alone, so a
/// folder or link of that name in the workspace cannot take the place of an installed
/// package. A name reaches the Loop engine as typed and can only load from the profile's
/// installed packages. Anything with a leading dot or slash is a path and keeps the
/// workspace check. Anything else with a slash is a GitHub address: see `githubAddress`.
pub fn installedName(argument: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, argument, '@');
    if (!plainSegment(if (at) |i| argument[0..i] else argument, "._-")) return false;
    if (at) |i| if (!plainSegment(argument[i + 1 ..], "._-+")) return false;
    return true;
}
/// True when a packagePath is a GitHub address, OWNER/REPO[/PATH][@REF]: it has a slash and
/// does not start with a dot or a slash. This is the rule fh uses for every PACKAGE, and it
/// reads the text alone. A tool refuses one: fetching and installing a package is for the
/// person, with /run ADDRESS, and a folder in the workspace is written ./NAME.
pub fn githubAddress(argument: []const u8) bool {
    return argument.len != 0 and argument[0] != '.' and argument[0] != '/' and std.mem.indexOfScalar(u8, argument, '/') != null;
}
fn plainSegment(text: []const u8, extra: []const u8) bool {
    if (text.len == 0 or !std.ascii.isAlphanumeric(text[0])) return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, extra, c) == null) return false;
    return true;
}

/// Both admission and execution use the native canonical resolver. No grant can
/// expand the five curated filesystem tools or package tools beyond this root.
pub fn validateWorkspaceCall(alloc: Allocator, root: []const u8, tool: types.ToolCall) !void {
    if (!std.mem.eql(u8, tool.name, "write_file") and !std.mem.eql(u8, tool.name, "edit_file") and !std.mem.eql(u8, tool.name, "loop_run") and !std.mem.eql(u8, tool.name, "loop_check")) return;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, tool.arguments_json, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolArguments;
    const key = if (std.mem.startsWith(u8, tool.name, "loop_")) "packagePath" else "path";
    const path = parsed.value.object.get(key) orelse return error.InvalidToolArguments;
    if (path != .string) return error.InvalidToolArguments;
    if (std.mem.eql(u8, key, "packagePath")) {
        if (installedName(path.string)) return;
        if (githubAddress(path.string)) return error.FhGithubAddressNeedsThePerson;
        // What is left is a path, and a path starts with a dot or a slash.
        if (path.string.len == 0 or (path.string[0] != '.' and path.string[0] != '/')) return error.InvalidToolArguments;
    }
    var path_arena = std.heap.ArenaAllocator.init(alloc);
    defer path_arena.deinit();
    const resolved = try pathing.resolveWorkspacePath(path_arena.allocator(), root, path.string, if (std.mem.eql(u8, tool.name, "write_file")) .create else .existing);
    if (!pathing.pathInside(root, resolved)) return error.FhOutsideWorkspace;
}

test "fh curated descriptors preserve actual prepared filesystem mutations" {
    try std.testing.expectEqual(@as(usize, 12), set.registry.tools.len);
    try std.testing.expect(set.registry.lookup("shell") == null);
    try std.testing.expect(set.registry.lookup("write_file").?.take_file_mutation_input_fn == builtins.write_file.take_file_mutation_input_fn);
    try std.testing.expect(set.registry.lookup("edit_file").?.take_file_mutation_input_fn == builtins.edit_file.take_file_mutation_input_fn);
    try std.testing.expectEqual(dispatch.ExecutorKind.write_file, set.registry.lookup("write_file").?.executor_kind);
    try std.testing.expectEqual(dispatch.ExecutorKind.host, set.registry.lookup("loop_run").?.executor_kind);
}
test "fh host argument schemas reject account policy and arbitrary docs paths" {
    var decision_doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"document\":\"decision_schema\"}", .{});
    defer decision_doc.deinit();
    try validateArguments(decision_doc.value.object, all[5].model_schema.input_schema);
    var parallel_doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"document\":\"parallel_schema\"}", .{});
    defer parallel_doc.deinit();
    try validateArguments(parallel_doc.value.object, all[5].model_schema.input_schema);
    var path_doc = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"document\":\"lib/packages/loops-contract/loop-0.3.schema.json\"}", .{});
    defer path_doc.deinit();
    try std.testing.expectError(error.InvalidToolArguments, validateArguments(path_doc.value.object, all[5].model_schema.input_schema));
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{\"packagePath\":\"x\",\"account\":\"invented\"}", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidToolArguments, validateArguments(parsed.value.object, all[6].model_schema.input_schema));
}
test "fh agent driver tools: run takes a driver, next reads, submit takes one object output and settle has no tool" {
    const alloc = std.testing.allocator;
    const Case = struct { tool: []const u8, arguments: []const u8, valid: bool };
    for ([_]Case{
        .{ .tool = "loop_run", .arguments = "{\"packagePath\":\"x\",\"input\":{},\"driver\":\"agent\"}", .valid = true },
        .{ .tool = "loop_run", .arguments = "{\"packagePath\":\"x\",\"input\":{},\"driver\":\"robot\"}", .valid = false },
        .{ .tool = "loop_next", .arguments = "{\"runId\":\"run_1\"}", .valid = true },
        .{ .tool = "loop_next", .arguments = "{}", .valid = false },
        .{ .tool = "loop_submit", .arguments = "{\"runId\":\"run_1\",\"path\":\"each[0]/judge\",\"pass\":0,\"output\":{\"verdict\":\"ok\"}}", .valid = true },
        .{ .tool = "loop_submit", .arguments = "{\"runId\":\"run_1\",\"path\":\"draft\",\"output\":{}}", .valid = false },
        .{ .tool = "loop_submit", .arguments = "{\"runId\":\"run_1\",\"path\":\"draft\",\"pass\":-1,\"output\":{}}", .valid = false },
        .{ .tool = "loop_submit", .arguments = "{\"runId\":\"run_1\",\"path\":\"draft\",\"pass\":0,\"output\":\"text\"}", .valid = false },
        // A model must not name a file for fh to read as the output.
        .{ .tool = "loop_submit", .arguments = "{\"runId\":\"run_1\",\"path\":\"draft\",\"pass\":0,\"outputFile\":\"/etc/passwd\"}", .valid = false },
        .{ .tool = "loop_submit", .arguments = "{\"runId\":\"run_1\",\"path\":\"draft\",\"pass\":0,\"output\":{},\"outputFile\":\"/etc/passwd\"}", .valid = false },
    }) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.arguments, .{});
        defer parsed.deinit();
        const outcome = validateArguments(parsed.value.object, set.registry.lookup(case.tool).?.model_schema.input_schema);
        if (case.valid) try outcome else try std.testing.expectError(error.InvalidToolArguments, outcome);
    }
    try std.testing.expect(set.registry.lookup("loop_settle") == null);
    try std.testing.expect(!set.registry.lookup("loop_next").?.requires_approval);
    try std.testing.expect(set.registry.lookup("loop_submit").?.requires_approval);
    try std.testing.expectEqual(dispatch.ExecutorKind.host, set.registry.lookup("loop_submit").?.executor_kind);
    try std.testing.expectEqual(names.len, all.len);
    for (names) |name| try std.testing.expect(set.registry.lookup(name) != null);
}

test "fh workspace writes reject external targets before native admission" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = @import("../shared/io.zig");
    try tmp.dir.createDirPath(io.getIo(), "workspace");
    const root = try io.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    const outside_call: types.ToolCall = .{ .id = "outside", .name = "write_file", .arguments_json = "{\"path\":\"../escape.txt\",\"content\":\"blocked\"}" };
    if (validateWorkspaceCall(alloc, root, outside_call)) |_| return error.TestExpectedDenial else |_| {}
    try validateWorkspaceCall(alloc, root, .{ .id = "inside", .name = "write_file", .arguments_json = "{\"path\":\"inside.txt\",\"content\":\"allowed\"}" });
}
test "fh package tools admit an installed name and keep the workspace check for every path" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = @import("../shared/io.zig");
    try tmp.dir.createDirPath(io.getIo(), "workspace/local-package/inner");
    try tmp.dir.createDirPath(io.getIo(), "outside");
    try tmp.dir.symLink(io.getIo(), "../outside", "workspace/linked", .{});
    try tmp.dir.symLink(io.getIo(), "nowhere", "workspace/dangling", .{});
    const root = try io.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(root);
    const Case = struct { argument: []const u8, name: bool, admitted: bool };
    for ([_]Case{
        // One plain segment is an installed name.
        .{ .argument = "triage", .name = true, .admitted = true },
        .{ .argument = "triage@2.1.0+build", .name = true, .admitted = true },
        // It is a name whatever the workspace holds: a folder, a link or a dangling link of that name changes nothing.
        .{ .argument = "local-package", .name = true, .admitted = true },
        .{ .argument = "linked", .name = true, .admitted = true },
        .{ .argument = "dangling", .name = true, .admitted = true },
        // A workspace folder is named with ./ or a slash, and is checked as a path.
        .{ .argument = "./local-package", .name = false, .admitted = true },
        .{ .argument = "./local-package/inner", .name = false, .admitted = true },
        .{ .argument = "./linked", .name = false, .admitted = false },
        .{ .argument = "./dangling", .name = false, .admitted = false },
        // Paths that are missing or leave the workspace are refused exactly as before.
        .{ .argument = "./triage", .name = false, .admitted = false },
        .{ .argument = "./nested/triage", .name = false, .admitted = false },
        .{ .argument = "../outside", .name = false, .admitted = false },
        .{ .argument = "/etc", .name = false, .admitted = false },
        .{ .argument = "..", .name = false, .admitted = false },
        .{ .argument = ".hidden", .name = false, .admitted = false },
        .{ .argument = "triage@../outside", .name = false, .admitted = false },
        .{ .argument = "-triage", .name = false, .admitted = false },
        .{ .argument = "tri age", .name = false, .admitted = false },
    }) |case| {
        try std.testing.expectEqual(case.name, installedName(case.argument));
        for ([_][]const u8{ "loop_check", "loop_run" }) |tool| {
            const arguments = try std.fmt.allocPrint(alloc, "{{\"packagePath\":\"{s}\",\"input\":{{}}}}", .{case.argument});
            defer alloc.free(arguments);
            const outcome = validateWorkspaceCall(alloc, root, .{ .id = "call", .name = tool, .arguments_json = arguments });
            if (case.admitted) try outcome else if (outcome) |_| return error.TestExpectedDenial else |_| {}
        }
    }
    // Anything else with a slash is a GitHub address, which a tool may never fetch. It is
    // refused by name, and never read as a workspace folder, even when one is spelled that way.
    for ([_][]const u8{ "acme/loops", "acme/loops/tools/triage@v2", "nested/triage", "local-package/inner", "local-package/", "triage@feat/next" }) |address| {
        try std.testing.expect(!installedName(address) and githubAddress(address));
        for ([_][]const u8{ "loop_check", "loop_run" }) |tool| {
            const arguments = try std.fmt.allocPrint(alloc, "{{\"packagePath\":\"{s}\",\"input\":{{}}}}", .{address});
            defer alloc.free(arguments);
            try std.testing.expectError(error.FhGithubAddressNeedsThePerson, validateWorkspaceCall(alloc, root, .{ .id = "call", .name = tool, .arguments_json = arguments }));
        }
    }
    for ([_][]const u8{ "triage", "triage@2", "./a/b", "../a/b", "/a/b", ".hidden", "" }) |other| try std.testing.expect(!githubAddress(other));
    try std.testing.expect(std.mem.indexOf(u8, package_properties[0].description, "GitHub address") != null);
    try std.testing.expect(std.mem.indexOf(u8, package_properties[0].description, "./NAME") != null);
    try std.testing.expect(std.mem.indexOf(u8, package_properties[0].description, "wins over") == null);
    // A name is only ever a package argument: file tools still resolve it as a workspace path.
    if (validateWorkspaceCall(alloc, root, .{ .id = "edit", .name = "edit_file", .arguments_json = "{\"path\":\"triage\"}" })) |_| return error.TestExpectedDenial else |_| {}
}

/// Retain the native permission engine. When no automatic reviewer exists,
/// effectful host tools use its ordinary human approval path.
pub fn effectivePermissionMode(name: []const u8, requested: types.PermissionMode, reviewer_available: bool) types.PermissionMode {
    if (requested != .auto or reviewer_available) return requested;
    const tool = set.registry.lookup(name) orelse return requested;
    return if (tool.executor_kind == .host and tool.requires_approval) .ask else requested;
}
test "fh host effects ask natively without reviewer while explicit modes and FS remain unchanged" {
    try std.testing.expectEqual(types.PermissionMode.ask, effectivePermissionMode("loop_run", .auto, false));
    try std.testing.expectEqual(types.PermissionMode.ask, effectivePermissionMode("loop_check", .ask, false));
    try std.testing.expectEqual(types.PermissionMode.ask, effectivePermissionMode("loop_submit", .auto, false));
    try std.testing.expectEqual(types.PermissionMode.auto, effectivePermissionMode("loop_next", .auto, false));
    try std.testing.expectEqual(types.PermissionMode.yolo, effectivePermissionMode("loop_run", .yolo, false));
    try std.testing.expectEqual(types.PermissionMode.auto, effectivePermissionMode("write_file", .auto, false));
    try std.testing.expectEqual(types.PermissionMode.auto, effectivePermissionMode("docs_read", .auto, false));
    try std.testing.expectEqual(types.PermissionMode.auto, effectivePermissionMode("loop_run", .auto, true));
}
