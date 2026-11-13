//! Read-only installation resources/limits. Native fx owns credentials separately.
const std = @import("std");
const runner = @import("runner.zig");
const store = @import("store.zig");
const schema = @import("schema.zig");
pub const Binding = struct {
    arena: std.heap.ArenaAllocator,
    configuration: runner.Value,
    registered: runner.Value,
    limits: runner.Limits,
    digest: []const u8,
    pub fn deinit(self: *Binding) void {
        self.arena.deinit();
    }
    pub fn profile(self: *Binding, runtime: []const u8) !runner.Value {
        const profiles = try runner.get(self.configuration, "runtimeProfiles");
        // An installation with no profile for a declared runtime cannot provide it.
        if (profiles != .object) return error.InvalidDefinition;
        return profiles.object.get(runtime) orelse error.RuntimeUnbound;
    }
    pub fn resource(self: *Binding, logical: []const u8) !struct { handle: []const u8, value: runner.Value } {
        const handle = try runner.text(try runner.get(try runner.get(self.registered, "resources"), logical));
        return .{ .handle = handle, .value = try runner.get(try runner.get(self.configuration, "resources"), handle) };
    }
    /// `agent_driven`: an outside agent performs the run's infer and decision steps and brings
    /// their capabilities itself (loops/0.3 section 10), so this binding is not asked for them.
    /// Code steps always execute here and are checked the same under either driver.
    pub fn assertDeclarations(self: *Binding, manifest: runner.Value, agent_driven: bool) !void {
        return self.assertSteps(try runner.get(manifest, "steps"), agent_driven);
    }
    fn assertSteps(self: *Binding, steps: runner.Value, agent_driven: bool) anyerror!void {
        for (steps.array.items) |step| {
            // loops/0.3 composites declare nothing themselves; their inner steps do.
            if (step.object.get("branches")) |branches| for (branches.object.values()) |branch| try self.assertSteps(branch, agent_driven);
            if (step.object.get("steps")) |inner| try self.assertSteps(inner, agent_driven);
            const kind = try runner.text(try runner.get(step, "kind"));
            const agents = agent_driven and (std.mem.eql(u8, kind, "infer") or std.mem.eql(u8, kind, "decision"));
            if (!agents) if (step.object.get("requires")) |requires| for (requires.array.items) |capability| {
                const name = try runner.text(capability);
                // workspace_read is granted by the binding's registered workspace resource, never by the declaration.
                if (std.mem.eql(u8, name, "workspace_read") and std.mem.eql(u8, try runner.text(try runner.get(step, "kind")), "infer")) {
                    _ = self.resource("workspace") catch return error.WorkspaceSetupRequired;
                    continue;
                }
                if (!std.mem.eql(u8, name, "browser") or !std.mem.eql(u8, try runner.text(try runner.get(step, "kind")), "infer")) return error.UnsupportedInferenceCapability;
                const capabilities = try runner.get(self.registered, "capabilities");
                if (capabilities != .object or capabilities.object.get(name) == null) return error.PermissionDenied;
            };
            if (std.mem.eql(u8, try runner.text(try runner.get(step, "kind")), "code")) {
                const runtime = try runner.text(try runner.get(step, "runtime"));
                if (std.mem.eql(u8, runtime, "wasm32-wasi-json/1")) continue;
                const profile_value = self.profile(runtime) catch |err| {
                    if (std.mem.eql(u8, runtime, "fh-workspace/1")) return error.WorkspaceSetupRequired;
                    return err;
                };
                const resources = try runner.get(profile_value, "resources");
                if (resources != .array or resources.array.items.len == 0) return error.RuntimeUnbound;
                for (resources.array.items) |resource_value| _ = self.resource(try runner.text(resource_value)) catch |err| {
                    if (std.mem.eql(u8, runtime, "fh-workspace/1")) return error.WorkspaceSetupRequired;
                    return err;
                };
            }
        }
    }
};
pub fn fromBytes(allocator: std.mem.Allocator, bytes: []const u8, binding_id: []const u8) !Binding {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    const configuration = try schema.parse(alloc, bytes);
    if ((try runner.get(configuration, "version")) != .integer or (try runner.get(configuration, "version")).integer != 1) return error.InvalidInstallation;
    const registered = try runner.get(try runner.get(configuration, "bindings"), binding_id);
    if (!std.mem.eql(u8, try runner.text(try runner.get(registered, "id")), binding_id)) return error.InvalidBindings;
    var limits: runner.Limits = .{};
    if (configuration.object.get("limits")) |declared| {
        if (declared != .object) return error.InvalidLimits;
        inline for (.{ .{ "maxTokens", "max_tokens" }, .{ "maxSeconds", "max_seconds" }, .{ "maxToolCalls", "max_tool_calls" }, .{ "maxIterations", "max_iterations" }, .{ "maxOutputBytes", "max_output_bytes" }, .{ "maxDiagnosticBytes", "max_diagnostic_bytes" }, .{ "maxOperations", "max_operations" } }) |mapping| {
            if (declared.object.get(mapping[0])) |value| {
                if (value != .integer or value.integer < 0) return error.InvalidLimits;
                @field(limits, mapping[1]) = std.math.cast(@TypeOf(@field(limits, mapping[1])), value.integer) orelse return error.InvalidLimits;
            }
        }
    }
    if (limits.max_seconds == 0 or limits.max_seconds > 86400 or limits.max_iterations == 0 or limits.max_output_bytes == 0 or limits.max_output_bytes > 1048576 or limits.max_diagnostic_bytes > 65536) return error.InvalidLimits;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const digest = try alloc.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
    return .{ .arena = arena, .configuration = configuration, .registered = registered, .limits = limits, .digest = digest };
}
pub fn load(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, binding_id: []const u8) !Binding {
    var dir = try store.openDirectory(io, directory);
    defer dir.close(io);
    try store.privateHandle(dir.handle, false);
    var file = dir.openFile(io, "installation.json", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return fromBytes(allocator, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{},\"capabilities\":{}}},\"resources\":{},\"runtimeProfiles\":{}}", binding_id),
        else => return err,
    };
    defer file.close(io);
    try store.privateHandle(file.handle, true);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(1048576));
    defer allocator.free(bytes);
    return fromBytes(allocator, bytes, binding_id);
}
test "native installation limits preserved and package cannot self-authorize capability" {
    var binding = try fromBytes(std.testing.allocator, "{\"version\":1,\"limits\":{\"maxTokens\":8000,\"maxToolCalls\":2},\"bindings\":{\"local\":{\"id\":\"local\",\"capabilities\":{},\"resources\":{}}},\"resources\":{},\"runtimeProfiles\":{}}", "local");
    defer binding.deinit();
    try std.testing.expectEqual(@as(u64, 8000), binding.limits.max_tokens);
    try std.testing.expectEqual(@as(u32, 2), binding.limits.max_tool_calls);
    const manifest = try schema.parse(binding.arena.allocator(), "{\"steps\":[{\"kind\":\"infer\",\"requires\":[\"browser\"]}]}");
    try std.testing.expectError(error.PermissionDenied, binding.assertDeclarations(manifest, false));
    // An agent that drives the run brings the browser; a code step is this binding's either way.
    try binding.assertDeclarations(manifest, true);
    const code = try schema.parse(binding.arena.allocator(), "{\"steps\":[{\"kind\":\"parallel\",\"branches\":{\"a\":[{\"kind\":\"infer\",\"requires\":[\"workspace_read\"]},{\"kind\":\"code\",\"runtime\":\"python3\"}]}}]}");
    for ([_]bool{ false, true }) |agent_driven| try std.testing.expectError(if (agent_driven) error.RuntimeUnbound else error.WorkspaceSetupRequired, binding.assertDeclarations(code, agent_driven));
    const misplaced = try schema.parse(binding.arena.allocator(), "{\"steps\":[{\"kind\":\"code\",\"runtime\":\"python3\",\"requires\":[\"browser\"]}]}");
    for ([_]bool{ false, true }) |agent_driven| try std.testing.expectError(error.UnsupportedInferenceCapability, binding.assertDeclarations(misplaced, agent_driven));
}

test "native Wasm declarations require no installed source runtime" {
    var binding = try fromBytes(std.testing.allocator, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"capabilities\":{},\"resources\":{}}},\"resources\":{},\"runtimeProfiles\":{}}", "local");
    defer binding.deinit();
    const manifest = try schema.parse(binding.arena.allocator(), "{\"steps\":[{\"kind\":\"code\",\"runtime\":\"wasm32-wasi-json/1\"}]}");
    try binding.assertDeclarations(manifest, false);
    try binding.assertDeclarations(manifest, true);
}
