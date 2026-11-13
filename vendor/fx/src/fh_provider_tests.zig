test "fh provider focused fixtures" {
    _ = @import("fh_loop_infer.zig");
    _ = @import("gateway/fh_host.zig");
    _ = @import("core/cli/cli_surface.zig");
    _ = @import("core/app/fh_startup.zig");
    _ = @import("core/tooling/fh_loop_tools.zig");
    _ = @import("core/tooling/tool_runtime.zig");
}

test "fh native Codex request retains selection and original provider with curated tools" {
    const std = @import("std");
    const codex = @import("gateway/openai_codex.zig");
    const providers = @import("builtins/providers.zig");
    const types = @import("core/shared/types.zig");
    const curated = @import("core/tooling/fh_loop_tools.zig");
    const alloc = std.testing.allocator;
    try std.testing.expect(providers.native.codex.agent_stream.?.stream_fn == codex.agent_stream_provider.stream_fn);
    var functions: [curated.all.len]@import("core/tooling/model_tool_schema.zig").FunctionSchema = undefined;
    for (curated.all, 0..) |tool, index| functions[index] = tool.model_schema;
    const body = try codex.buildRequest(alloc, .{ .model = "gpt-6-luna", .messages = &.{.{ .role = .user, .content = "hi" }}, .tool_choice = .auto, .provider_options = .{ .reasoning = types.ReasoningEffort.literal("medium"), .fast = true }, .tools = .{ .registry = curated.set.registry, .advertised_names = curated.set.order, .advertised_functions = &functions } });
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("gpt-6-luna", parsed.value.object.get("model").?.string);
    try std.testing.expectEqualStrings("medium", parsed.value.object.get("reasoning").?.object.get("effort").?.string);
    try std.testing.expectEqualStrings("priority", parsed.value.object.get("service_tier").?.string);
    const tools = parsed.value.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 12), tools.len);
    for (tools, curated.set.order) |tool, name| {
        try std.testing.expectEqualStrings("function", tool.object.get("type").?.string);
        try std.testing.expectEqualStrings(name, tool.object.get("name").?.string);
    }
}
