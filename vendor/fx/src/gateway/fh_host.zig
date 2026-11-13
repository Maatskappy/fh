//! fx-authorized workspace tools call the owned native Loop engine.
const std = @import("std");
const bridge_api = @import("../../../../native/host_bridge.zig");
const dispatch = @import("../core/tooling/tool_dispatch.zig");
const types = @import("../core/shared/types.zig");
const model_provider = @import("../core/config/model_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const Allocator = std.mem.Allocator;

pub const Context = struct {
    bridge: ?*bridge_api.Bridge = null,
    workspace_root: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: model_provider.ProviderId = .codex,
    effort: types.ReasoningEffort = types.ReasoningEffort.literal("medium"),
    fast: bool = true,
    cancelled: ?*std.atomic.Value(bool) = null,
    last_error: ?[]u8 = null,

    pub fn bindTurn(self: *Context, _: u64, workspace: []const u8, provider: model_provider.ProviderId, model: []const u8, effort: types.ReasoningEffort, fast: bool, cancel: *std.atomic.Value(bool)) !void {
        if (self.model != null) return error.FhTurnAlreadyActive;
        self.workspace_root = workspace;
        self.provider = provider;
        self.model = model;
        self.effort = effort;
        self.fast = fast;
        self.cancelled = cancel;
    }
    pub fn finish(self: *Context, _: Allocator, _: bool) !void {
        self.model = null;
        self.workspace_root = null;
        self.cancelled = null;
        if (self.last_error) |detail| std.heap.c_allocator.free(detail);
        self.last_error = null;
    }
    fn trustedSelection(self: *Context, alloc: Allocator) !std.json.Value {
        var selection = object();
        errdefer selection.object.deinit(alloc);
        try selection.object.put(alloc, "provider", string(self.provider.label()));
        try selection.object.put(alloc, "model", string(self.model orelse return error.FhTurnRequired));
        try selection.object.put(alloc, "reasoning", string(self.effort.label()));
        try selection.object.put(alloc, "fast", .{ .bool = self.fast });
        return selection;
    }
    fn rpc(self: *Context, alloc: Allocator, method: []const u8, params: std.json.Value, cancel: ?*std.atomic.Value(bool)) !std.json.Parsed(std.json.Value) {
        const bridge = self.bridge orelse return error.HostBridgeUnavailable;
        if (self.last_error) |detail| std.heap.c_allocator.free(detail);
        self.last_error = null;
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
        const mailbox = try bridge.submitMethod(method, params);
        defer bridge.release(mailbox);
        while (true) {
            if (cancel) |flag| if (flag.load(.acquire)) {
                bridge.cancel(mailbox);
                return error.Cancelled;
            };
            if (try mailbox.take()) |decoded| {
                var owned = decoded;
                defer owned.deinit();
                if (owned.message != .response) return error.InvalidProviderFrame;
                const response = owned.message.response;
                if (response.is_error) {
                    const detail = try std.json.Stringify.valueAlloc(std.heap.c_allocator, response.value, .{});
                    if (detail.len <= 65536) self.last_error = detail else std.heap.c_allocator.free(detail);
                    return error.HostOperationRejected;
                }
                const json = try std.json.Stringify.valueAlloc(alloc, response.value, .{});
                defer alloc.free(json);
                return std.json.parseFromSlice(std.json.Value, alloc, json, .{ .allocate = .alloc_always });
            }
            std.Io.sleep(io_mod.getIo(), .fromMilliseconds(2), .awake) catch {};
        }
    }
    pub fn hostProvider(self: *Context) dispatch.HostToolProvider {
        return .{ .context = self, .call_fn = hostCall };
    }
};
fn object() std.json.Value {
    return .{ .object = std.json.ObjectMap{} };
}
fn string(value: []const u8) std.json.Value {
    return .{ .string = value };
}
fn hostCall(raw: *anyopaque, alloc: Allocator, name: []const u8, arguments: []const u8, maximum: usize, cancel: ?*std.atomic.Value(bool)) dispatch.DispatchError!dispatch.ToolResult {
    const context: *Context = @ptrCast(@alignCast(raw));
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{}) catch return error.InvalidToolArguments;
    defer parsed.deinit();
    var path_arena = std.heap.ArenaAllocator.init(alloc);
    defer path_arena.deinit();
    if (std.mem.eql(u8, name, "loop_check") or std.mem.eql(u8, name, "loop_run")) {
        const root = context.workspace_root orelse return error.InvalidToolArguments;
        if (parsed.value != .object) return error.InvalidToolArguments;
        const path = parsed.value.object.getPtr("packagePath") orelse return error.InvalidToolArguments;
        if (path.* != .string) return error.InvalidToolArguments;
        const loop_tools = @import("../core/tooling/fh_loop_tools.zig");
        // A GitHub address is never fetched or installed for the model, and is never read as
        // a workspace folder either. Only the person can do that, with /run ADDRESS.
        if (loop_tools.githubAddress(path.string)) return .{ .failure = try std.fmt.allocPrint(alloc, "{s} is a GitHub address, and a chat tool cannot fetch or install a package. Only the person can: they run /run {s}, which shows what the package holds before anything is installed. For a folder in the workspace, write ./{s}.", .{ path.string, path.string, path.string }) };
        // One plain segment is an installed NAME or NAME@VERSION whatever the workspace holds.
        // It travels as typed, and the engine loads it from the profile.
        if (!loop_tools.installedName(path.string)) {
            // What is left is a path, and a path starts with a dot or a slash.
            if (path.string.len == 0 or (path.string[0] != '.' and path.string[0] != '/')) return error.InvalidToolArguments;
            const resolved = @import("../core/workspace/pathing.zig").resolveWorkspacePath(path_arena.allocator(), root, path.string, .existing) catch return error.InvalidToolArguments;
            path.* = string(resolved);
        }
    }
    var params = object();
    defer params.object.deinit(alloc);
    var selection = context.trustedSelection(alloc) catch return error.InvalidToolArguments;
    defer selection.object.deinit(alloc);
    try params.object.put(alloc, "name", string(name));
    try params.object.put(alloc, "arguments", parsed.value);
    // The model can write only arguments. Provider/model selection is the
    // immutable native fx job snapshot, outside that model-controlled object.
    try params.object.put(alloc, "selection", selection);
    var result = context.rpc(alloc, "loopTool", params, cancel) catch |err| {
        if (err == error.Cancelled) return error.Cancelled;
        return .{ .failure = if (context.last_error) |detail| try alloc.dupe(u8, detail) else try std.fmt.allocPrint(alloc, "Native Loop tool failed: {s}", .{@errorName(err)}) };
    };
    defer result.deinit();
    const json = try std.json.Stringify.valueAlloc(alloc, result.value, .{});
    if (json.len > maximum) {
        alloc.free(json);
        return .{ .failure = try alloc.dupe(u8, "Loop result exceeds native result limit; use a bounded docs range or loop_get.") };
    }
    return .{ .success = json };
}

test "fh native Loop context snapshots provider selection without a parent RPC" {
    var context: Context = .{};
    var cancel = std.atomic.Value(bool).init(false);
    try context.bindTurn(1, "/fixture/workspace", .grok, "grok-fixture", types.ReasoningEffort.literal("medium"), false, &cancel);
    var selection = try context.trustedSelection(std.testing.allocator);
    defer selection.object.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("grok", selection.object.get("provider").?.string);
    try std.testing.expectEqualStrings("grok-fixture", selection.object.get("model").?.string);
    try std.testing.expectEqualStrings("medium", selection.object.get("reasoning").?.string);
    try std.testing.expect(!selection.object.get("fast").?.bool);
    try std.testing.expectError(error.FhTurnAlreadyActive, context.bindTurn(2, "/other", .codex, "other", .auto, true, &cancel));
    try context.finish(std.testing.allocator, false);
    try std.testing.expect(context.model == null and context.workspace_root == null);
}
test "fh loop_check and loop_run pass an installed package name to the engine and still confine every path to the workspace" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    try tmp.dir.createDir(io, "profile", .fromMode(0o700));
    try tmp.dir.createDirPath(io, "workspace/folder");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.createDir(io, "source", .fromMode(0o700));
    try tmp.dir.writeFile(io, .{ .sub_path = "source/loop.json", .data = "{\"format\":\"loops/0.1\",\"name\":\"chatted\",\"version\":\"3\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"one\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"one.py\",\"input\":{},\"output\":{\"schema\":true}}],\"output\":{\"value\":null}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "source/one.py", .data = "print(1)\n" });
    var buffer: [4096]u8 = undefined;
    const base = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const profile = try std.fs.path.join(alloc, &.{ base, "profile" });
    defer alloc.free(profile);
    const workspace = try std.fs.path.join(alloc, &.{ base, "workspace" });
    defer alloc.free(workspace);
    const source = try std.fs.path.join(alloc, &.{ base, "source" });
    defer alloc.free(source);
    var bridge: bridge_api.Bridge = .{};
    defer bridge.deinit();
    try bridge.configure(.{ .io = io, .profile = profile });
    var context: Context = .{ .bridge = &bridge };
    var cancel = std.atomic.Value(bool).init(false);
    try context.bindTurn(1, workspace, .codex, "fixture-model", types.ReasoningEffort.literal("medium"), false, &cancel);
    defer context.finish(alloc, false) catch {};
    const Step = struct { tool: []const u8, arguments: []const u8, contains: []const u8 };
    const call = struct {
        fn run(ctx: *Context, step: Step) !void {
            // Retire answered requests, as the app's poll does.
            defer _ = ctx.bridge.?.next() catch null;
            const result = hostCall(ctx, std.testing.allocator, step.tool, step.arguments, 65536, null) catch |err| {
                // A path outside the workspace never reaches the engine.
                try std.testing.expectEqualStrings(step.contains, @errorName(err));
                return;
            };
            const text = switch (result) {
                .success => |bytes| bytes,
                .failure => |bytes| bytes,
                else => return error.TestUnexpectedResult,
            };
            defer std.testing.allocator.free(text);
            if (std.mem.indexOf(u8, text, step.contains) == null) {
                std.debug.print("expected {s} for {s}, found {s}\n", .{ step.contains, step.arguments, text });
                return error.TestUnexpectedResult;
            }
        }
    }.run;
    // Before anything is installed the engine, not the path check, answers for a name.
    try call(&context, .{ .tool = "loop_check", .arguments = "{\"packagePath\":\"chatted\"}", .contains = "No installed package is named chatted" });
    try call(&context, .{ .tool = "loop_run", .arguments = "{\"packagePath\":\"chatted@3\",\"input\":{}}", .contains = "package_not_installed" });
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var adding = object();
    try adding.object.put(arena.allocator(), "source", string(source));
    try adding.object.put(arena.allocator(), "yes", .{ .bool = true });
    var installer: bridge_api.engine.Engine = .{ .options = .{ .io = io, .profile = profile } };
    try std.testing.expectEqualStrings("installed", (try installer.packages(arena.allocator(), "add", adding)).object.get("status").?.string);
    // Installed, then changed on disk: only the engine's load by name can say so.
    try tmp.dir.setFilePermissions(io, "profile/packages/chatted/3/one.py", .fromMode(0o600), .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/chatted/3/one.py", .data = "print(2)\n" });
    try call(&context, .{ .tool = "loop_check", .arguments = "{\"packagePath\":\"chatted\"}", .contains = "The installed files for chatted@3 do not match what was installed" });
    try call(&context, .{ .tool = "loop_run", .arguments = "{\"packagePath\":\"chatted@3\",\"input\":{}}", .contains = "installed_package_changed" });
    // A workspace folder is named with ./ and is resolved inside the workspace. Its bare name is an installed name.
    try call(&context, .{ .tool = "loop_check", .arguments = "{\"packagePath\":\"./folder\"}", .contains = "not_a_package" });
    try call(&context, .{ .tool = "loop_check", .arguments = "{\"packagePath\":\"folder\"}", .contains = "No installed package is named folder" });
    // Paths that leave the workspace or do not exist are refused before the engine, as before.
    for ([_][]const u8{ "../outside", "../source", "./chatted", "./nested/chatted", "/etc" }) |path| {
        const arguments = try std.fmt.allocPrint(alloc, "{{\"packagePath\":\"{s}\"}}", .{path});
        defer alloc.free(arguments);
        try call(&context, .{ .tool = "loop_check", .arguments = arguments, .contains = "InvalidToolArguments" });
    }
    // Anything else with a slash is a GitHub address. A tool never fetches or installs one, and
    // never reads it as a workspace folder either, even when a folder of that spelling exists.
    try tmp.dir.createDirPath(io, "workspace/folder/inner");
    for ([_][]const u8{ "acme/loops/tools/triage", "acme/loops@v2", "nested/chatted", "folder/inner", "folder/" }) |address| {
        for ([_][]const u8{ "loop_check", "loop_run" }) |tool| {
            const arguments = try std.fmt.allocPrint(alloc, "{{\"packagePath\":\"{s}\",\"input\":{{}}}}", .{address});
            defer alloc.free(arguments);
            try call(&context, .{ .tool = tool, .arguments = arguments, .contains = "is a GitHub address, and a chat tool cannot fetch or install a package" });
            try call(&context, .{ .tool = tool, .arguments = arguments, .contains = try std.fmt.allocPrint(arena.allocator(), "write ./{s}", .{address}) });
        }
    }
    try call(&context, .{ .tool = "loop_check", .arguments = "{\"packagePath\":\"./folder/inner\"}", .contains = "not_a_package" });
}
