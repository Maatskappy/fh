//! Small setup composition over fx's auth, masked input and settings commits.
const std = @import("std");
const fs_metadata = @import("metadata.zig");
const cli = @import("../vendor/fx/src/core/cli/cli_surface.zig");
const config = @import("../vendor/fx/src/core/config/config_runtime.zig");
const model_provider = @import("../vendor/fx/src/core/config/model_provider.zig");
const definitions = @import("../vendor/fx/src/core/config/configured_provider.zig");
const io_mod = @import("../vendor/fx/src/core/shared/io.zig");
const paths = @import("../vendor/fx/src/core/shared/profile_paths.zig");
const sessions = @import("../vendor/fx/src/core/auth/session_presence.zig");
const keys = @import("credentials.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

fn write(text: []const u8) !void {
    var offset: usize = 0;
    while (offset < text.len) {
        const n = std.c.write(2, text[offset..].ptr, text.len - offset);
        if (n <= 0) return error.OutputFailed;
        offset += @intCast(n);
    }
}
fn prompt(alloc: Allocator, label: []const u8, default: []const u8) ![]u8 {
    try write(label);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    while (input.items.len <= 2048) {
        var byte: [1]u8 = undefined;
        if (try std.posix.read(0, &byte) == 0) return error.SetupCancelled;
        if (byte[0] == '\n' or byte[0] == '\r') {
            const text = std.mem.trim(u8, input.items, " \t");
            return alloc.dupe(u8, if (text.len == 0) default else text);
        }
        if (byte[0] == 3 or byte[0] == 4 or byte[0] == 0x1b) return error.SetupCancelled;
        if (byte[0] < 32 or byte[0] == 127) return error.InvalidSetupInput;
        try input.append(alloc, byte[0]);
    }
    return error.SetupInputTooLong;
}
fn yes(alloc: Allocator, label: []const u8) !bool {
    const text = try prompt(alloc, label, "n");
    defer alloc.free(text);
    if (std.ascii.eqlIgnoreCase(text, "y") or std.ascii.eqlIgnoreCase(text, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(text, "n") or std.ascii.eqlIgnoreCase(text, "no")) return false;
    return error.InvalidSetupChoice;
}
pub fn needed(alloc: Allocator) !bool {
    const home = io_mod.getenv("HOME") orelse return false;
    const file_path = try paths.settingsPath(alloc, home);
    defer alloc.free(file_path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), file_path, .{ .follow_symlinks = false }) catch |err| {
        if (err != error.FileNotFound) return err;
        // An existing OAuth login must never be replaced by first-run setup.
        return sessions.profileFile(paths.chatgpt_auth_file_name, 65536) == .missing and
            sessions.profileFile(paths.grok_auth_file_name, 65536) == .missing and
            sessions.profileFile(paths.auth_file_name, 65536) == .missing and
            gatewaySource() == null;
    };
    file.close(io_mod.getIo());
    return false;
}
fn gatewaySource() ?@import("../vendor/fx/src/core/shared/types.zig").CredentialSource {
    if (io_mod.getenv("AI_GATEWAY_API_KEY")) |key| {
        if (key.len > 0) return .ai_gateway_api_key;
    }
    if (@import("../vendor/fx/src/core/hosts/native.zig").secret_store.presence() == .present) return .stored_key;
    return null;
}
/// A credential-only Gateway installation has no selected model to overwrite.
/// Seed its original Gateway defaults locally, without a login/catalog call.
pub fn preserveExisting(alloc: Allocator) !void {
    const home = io_mod.getenv("HOME") orelse return;
    const settings_path = try paths.settingsPath(alloc, home);
    defer alloc.free(settings_path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), settings_path, .{ .follow_symlinks = false }) catch |err| {
        if (err != error.FileNotFound) return err;
        if (sessions.profileFile(paths.chatgpt_auth_file_name, 65536) == .present or sessions.profileFile(paths.grok_auth_file_name, 65536) == .present) return;
        const source = gatewaySource() orelse return;
        return commit(alloc, .{ .provider = .gateway, .model_preference = .{ .provider = .gateway, .model = @import("../vendor/fx/src/builtins/gateway.zig").default_model }, .credential_source = source, .effort = @import("../vendor/fx/src/core/shared/types.zig").ReasoningEffort.literal("none"), .fast_mode = false });
    };
    file.close(io_mod.getIo());
}
fn commit(alloc: Allocator, patch: config.UserSettingsPatch) !void {
    var attempt = config.attemptUserPreferences(alloc, patch);
    defer attempt.deinit(alloc);
    if (attempt == .failure) return error.SetupSettingsNotSaved;
}
fn saveKey(alloc: Allocator, env: []const u8) !void {
    if (try keys.presence(alloc, env) == .present) {
        if (!try yes(alloc, "Already connected. Replace this key? [y/N] ")) return;
    }
    try write("API key (hidden; Esc cancels): ");
    const key = try cli.readMaskedKey(alloc);
    defer keys.zeroAndFree(alloc, key);
    try write("\n");
    try keys.save(alloc, env, key);
    try write("Key saved locally.\n");
}
fn jev(alloc: Allocator) !void {
    try write("Jev · TypeSafe decision steps\n");
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const policy = try @import("decision_status.zig").loadPolicy(arena.allocator());
    try saveKey(alloc, policy.env);
}
fn object(alloc: Allocator, fields: anytype) !Value {
    var value: Value = .{ .object = .empty };
    inline for (fields) |field| try value.object.put(alloc, field[0], field[1]);
    return value;
}
pub fn compatibleDefinition(alloc: Allocator, name: []const u8, url: []const u8, model: []const u8, env: []const u8) !Value {
    try definitions.validate_id(name);
    try definitions.validate_model_id(model);
    try keys.validateEnvironment(env);
    const auth = try object(alloc, .{ .{ "type", Value{ .string = "bearer" } }, .{ "env", Value{ .string = env } } });
    const metadata = try object(alloc, .{.{ "supports_tool_use", Value{ .bool = true } }});
    const models = try object(alloc, .{.{ model, metadata }});
    const definition = try object(alloc, .{
        .{ "protocol", Value{ .string = "openai-chat-completions" } },
        .{ "base_url", Value{ .string = url } },
        .{ "auth", auth },
        .{ "tool_choice_mode", Value{ .string = "send" } },
        .{ "model_metadata", models },
    });
    const routes = try object(alloc, .{.{ name, definition }});
    var registry = try definitions.Registry.parse(alloc, routes);
    defer registry.deinit(alloc);
    return definition;
}
fn compatible(alloc: Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    try write("OpenAI-compatible API · this endpoint must support chat and tools.\n");
    const name = try prompt(a, "Connection name [api]: ", "api");
    const url = try prompt(a, "API base URL [https://api.openai.com/v1]: ", "https://api.openai.com/v1");
    const model = try prompt(a, "Model ID: ", "");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    const env = try std.fmt.allocPrint(a, "FH_AI_{s}_KEY", .{std.fmt.bytesToHex(digest, .upper)});
    const definition = try compatibleDefinition(a, name, url, model, env);
    // Parse the complete route before collecting or saving a secret.
    try saveKey(alloc, env);
    try commit(alloc, .{
        .configured_provider = .{ .id = name, .definition = definition },
        .provider = model_provider.parse(name).?,
        .model_preference = .{ .provider = model_provider.parse(name).?, .model = model },
        .clear_credential_source = true,
        .effort = @import("../vendor/fx/src/core/shared/types.zig").ReasoningEffort.literal("none"),
        .fast_mode = false,
    });
    try write("AI connection saved. The next chat or infer step uses this route.\n");
}
fn gateway(alloc: Allocator, cfg: cli.Config) !void {
    const env_key = if (io_mod.getenv("AI_GATEWAY_API_KEY")) |key| key.len > 0 else false;
    if (!env_key and cfg.secret_store.presence() != .present) {
        if (cfg.secret_store.isDisabled()) return error.StoredKeysDisabled;
        try write("Vercel AI Gateway key (hidden; Esc cancels): ");
        const key = try cli.readMaskedKey(alloc);
        defer keys.zeroAndFree(alloc, key);
        try write("\n");
        try keys.validateKey(key);
        try cfg.secret_store.store(alloc, key);
    } else try write("Using the existing Gateway key.\n");
    const model = try prompt(alloc, "Gateway model ID [" ++ @import("../vendor/fx/src/builtins/gateway.zig").default_model ++ "]: ", @import("../vendor/fx/src/builtins/gateway.zig").default_model);
    defer alloc.free(model);
    try definitions.validate_model_id(model);
    try commit(alloc, .{ .provider = .gateway, .model_preference = .{ .provider = .gateway, .model = model }, .credential_source = if (env_key) .ai_gateway_api_key else .stored_key, .effort = @import("../vendor/fx/src/core/shared/types.zig").ReasoningEffort.literal("none"), .fast_mode = false });
}
fn ai(alloc: Allocator, cfg: cli.Config) !void {
    try write("AI access\n  1  Codex · sign in with ChatGPT\n  2  Vercel AI Gateway · API key\n  3  OpenAI-compatible API · key, endpoint and model\n  4  Keep current setup\n  5  Skip · use code-only Loops\n");
    const choice = try prompt(alloc, "Choose [1]: ", "1");
    defer alloc.free(choice);
    if (std.mem.eql(u8, choice, "1")) {
        const result = try cli.runIfRequested(alloc, &.{ "login", "codex" }, cfg);
        switch (result) {
            .handled_success => {},
            else => return error.SetupLoginFailed,
        }
        // The original login commits the selected/existing model and account.
    } else if (std.mem.eql(u8, choice, "2")) {
        try gateway(alloc, cfg);
    } else if (std.mem.eql(u8, choice, "3")) {
        try compatible(alloc);
    } else if (std.mem.eql(u8, choice, "4")) {
        try preserveExisting(alloc);
        if (try needed(alloc)) return error.NoCurrentSetup;
    } else if (std.mem.eql(u8, choice, "5")) {
        if (try needed(alloc)) try commit(alloc, .{ .provider = .codex, .model_preference = .{ .provider = .codex, .model = "gpt-6-luna" }, .effort = @import("../vendor/fx/src/core/shared/types.zig").ReasoningEffort.literal("medium"), .fast_mode = true });
    } else return error.InvalidSetupChoice;
}
pub fn setupBrowser(alloc: Allocator, explicit: ?[]const u8) !void {
    const browser = @import("loops/browser.zig");
    const store = @import("loops/store.zig");
    const io = io_mod.getIo();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var directory = try paths.openCredentialRoot(home, true);
    defer directory.close();
    const root = try paths.rootDir(a, home);
    var registry = try store.Store.init(a, io, root);
    defer registry.deinit();
    const lock = try registry.lock("foreground");
    defer lock.close(io);
    var binding = try @import("loops/bindings.zig").load(a, io, root, "local");
    defer binding.deinit();
    const b = binding.arena.allocator();
    var capabilities = binding.registered.object.getPtr("capabilities") orelse return error.InvalidBindings;
    if (capabilities.object.contains("browser")) {
        const configured = try browser.configuredPath(b, io, &binding);
        if (explicit) |path| {
            try browser.validateBinary(io, path);
            if (!std.mem.eql(u8, path, configured)) return error.BrowserResourceAlreadyExists;
        }
        try write("Local browser is already configured; existing grant preserved.\n");
        return;
    }
    const binary = explicit orelse try browser.installedPath(a);
    try browser.validateBinary(io, binary);
    var resources = binding.configuration.object.getPtr("resources") orelse return error.InvalidInstallation;
    const handle = "local-moli-browser";
    if (resources.object.contains(handle)) return error.BrowserResourceAlreadyExists;
    var resource = try object(b, .{ .{ "kind", Value{ .string = "browser" } }, .{ "adapter", Value{ .string = "moli-cdp/1" } } });
    if (explicit) |path| try resource.object.put(b, "binary", .{ .string = try b.dupe(u8, path) });
    try resources.object.put(b, handle, resource);
    try capabilities.object.put(b, "browser", .{ .string = handle });
    // registered is a borrowed JSON map; updating it may reallocate its table.
    var registrations = binding.configuration.object.getPtr("bindings").?;
    try registrations.object.put(b, "local", binding.registered);
    const bytes = try std.json.Stringify.valueAlloc(b, binding.configuration, .{ .whitespace = .indent_2 });
    var atomic = try directory.dir.createFileAtomic(io, "installation.json", .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    if (fs_metadata.syncDirectory(directory.dir.handle) != 0) return error.StoreSyncFailed;
    try write("Local browser configured. The local binding permits HTTP(S) navigation, DOM observation, real mouse/text/keyboard input and private PNG capture in a fresh run-owned Moli. Existing limits are preserved.\n");
}
/// Whether a grant registers host commands. A grant names a workspace and its files, and
/// may name commands: anything else in it is refused.
fn registersCommands(grant: Value) !bool {
    if (grant != .object or !grant.object.contains("workspace") or !grant.object.contains("files")) return error.InvalidWorkspacePolicy;
    for (grant.object.keys()) |key| {
        if (!std.mem.eql(u8, key, "workspace") and !std.mem.eql(u8, key, "files") and !std.mem.eql(u8, key, "commands")) return error.InvalidWorkspacePolicy;
    }
    const commands = grant.object.get("commands") orelse return false;
    if (commands != .object) return error.InvalidWorkspacePolicy;
    return commands.object.count() != 0;
}
/// The resource a grant registers. Host commands run with the user's environment and
/// credentials, so they need `--trust-host` and the resource records that trust. A grant of
/// files alone runs nothing: it needs no trust and records none.
fn workspaceResource(b: Allocator, grant: Value, canonical: []const u8, dev: i64, ino: i64, trust: bool) !Value {
    const runs = try registersCommands(grant);
    if (runs and !trust) return error.WorkspaceTrustRequired;
    var resource = try object(b, .{
        .{ "kind", Value{ .string = "workspace-runtime" } },
        .{ "workspace", Value{ .string = try b.dupe(u8, canonical) } },
        .{ "dev", Value{ .integer = dev } },
        .{ "ino", Value{ .integer = ino } },
        .{ "commands", grant.object.get("commands") orelse Value{ .object = .empty } },
        .{ "files", grant.object.get("files").? },
    });
    if (runs) try resource.object.put(b, "trust", .{ .string = "trusted-host-commands" });
    return resource;
}
pub fn setupWorkspace(alloc: Allocator, grant_path: []const u8, binding_id: []const u8, trust: bool) !void {
    const store = @import("loops/store.zig");
    const workspace = @import("loops/workspace_runtime.zig");
    const io = io_mod.getIo();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    if (binding_id.len == 0 or binding_id.len > 64) return error.InvalidBindings;
    for (binding_id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidBindings;
    var file = try std.Io.Dir.cwd().openFile(io, grant_path, .{ .follow_symlinks = false });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const grant_bytes = try reader.interface.allocRemaining(a, .limited(65536));
    const grant = try @import("loops/schema.zig").parse(a, grant_bytes);
    // Refused before anything is locked or written.
    const runs = try registersCommands(grant);
    if (runs and !trust) return error.WorkspaceTrustRequired;
    const path = try @import("loops/runner.zig").text(try @import("loops/runner.zig").get(grant, "workspace"));
    var workspace_dir = try store.openDirectory(io, path);
    defer workspace_dir.close(io);
    const canonical = try workspace_dir.realPathFileAlloc(io, ".", a);
    const stat = fs_metadata.fstat(workspace_dir.handle) catch return error.InvalidWorkspacePolicy;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var directory = try paths.openCredentialRoot(home, true);
    defer directory.close();
    const root = try paths.rootDir(a, home);
    var registry = try store.Store.init(a, io, root);
    defer registry.deinit();
    const lock = try registry.lock("foreground");
    defer lock.close(io);
    try registry.requireSettledResources();
    var binding = try @import("loops/bindings.zig").load(a, io, root, "local");
    defer binding.deinit();
    const b = binding.arena.allocator();
    var registrations = binding.configuration.object.getPtr("bindings") orelse return error.InvalidInstallation;
    if (registrations.* != .object) return error.InvalidInstallation;
    if (registrations.object.contains(binding_id)) return error.WorkspaceBindingAlreadyExists;
    const handle = try std.fmt.allocPrint(b, "{s}-workspace", .{binding_id});
    var resources = binding.configuration.object.getPtr("resources") orelse return error.InvalidInstallation;
    if (resources.* != .object) return error.InvalidInstallation;
    if (resources.object.contains(handle)) return error.WorkspaceBindingAlreadyExists;
    const resource = try workspaceResource(b, grant, canonical, @intCast(stat.dev), @intCast(stat.ino), trust);
    try resources.object.put(b, handle, resource);
    const registration = try object(b, .{
        .{ "id", Value{ .string = try b.dupe(u8, binding_id) } },
        .{ "capabilities", Value{ .object = .empty } },
        .{ "resources", try object(b, .{.{ "workspace", Value{ .string = handle } }}) },
    });
    try registrations.object.put(b, binding_id, registration);
    const profile = try @import("loops/schema.zig").parse(b, "{\"resources\":[\"workspace\"]}");
    var profiles = binding.configuration.object.getPtr("runtimeProfiles") orelse return error.InvalidInstallation;
    if (profiles.* != .object) return error.InvalidInstallation;
    if (profiles.object.get(workspace.runtime)) |existing| {
        if (!@import("loops/schema.zig").equal(existing, profile)) return error.InvalidWorkspacePolicy;
    } else try profiles.object.put(b, workspace.runtime, profile);
    const bytes = try std.json.Stringify.valueAlloc(b, binding.configuration, .{ .whitespace = .indent_2 });
    var registered = try @import("loops/bindings.zig").fromBytes(a, bytes, binding_id);
    defer registered.deinit();
    _ = try workspace.configured(&registered, io);
    var atomic = try directory.dir.createFileAtomic(io, "installation.json", .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    if (fs_metadata.syncDirectory(directory.dir.handle) != 0) return error.StoreSyncFailed;
    try write(if (runs) "Workspace binding registered. Native operations can run the exact granted commands and replace the listed files. Commands inherit host environment, network and credentials; the workspace is not a sandbox.\n" else "Workspace binding registered read-only. Steps that require workspace_read can list, search and read the listed files. No host commands were registered, so fh-workspace/1 steps cannot run with this binding.\n");
}
fn runtimeArguments(name: []const u8, socket: []const u8, image: []const u8, version: []const u8) !@import("loops/code.zig").Runtime {
    const code = @import("loops/code.zig");
    const runtime = std.meta.stringToEnum(code.Runtime, name) orelse return error.UnsupportedRuntime;
    const parsed = @import("loops/dependencies.zig").version(version) catch return error.UnsupportedRuntime;
    if (!code.supportedVersion(runtime, parsed)) return error.UnsupportedRuntime;
    if (!@import("loops/runtime_policy.zig").socketValid(socket)) return error.InvalidRuntimeSocket;
    if (!@import("loops/runtime_policy.zig").imageValid(image)) return error.InvalidRuntimeImage;
    return runtime;
}
/// Merge only explicitly supplied isolated source authority. Conflicts never replace grants.
fn registerRuntime(binding: *@import("loops/bindings.zig").Binding, name: []const u8, socket: []const u8, image: []const u8, raw_version: []const u8) !bool {
    const policy = @import("loops/runtime_policy.zig");
    const code = @import("loops/code.zig");
    const schema = @import("loops/schema.zig");
    const runtime = try runtimeArguments(name, socket, image, raw_version);
    const a = binding.arena.allocator();
    const logical = try std.fmt.allocPrint(a, "{s}-runtime", .{name});
    const handle = try std.fmt.allocPrint(a, "local-{s}", .{name});
    var resource_names: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    try resource_names.array.append(.{ .string = logical });
    const profile = try object(a, .{
        .{ "available", Value{ .bool = true } },
        .{ "profile", Value{ .string = policy.family(runtime) } },
        .{ "version", Value{ .string = try a.dupe(u8, raw_version) } },
        .{ "image", Value{ .string = try a.dupe(u8, image) } },
        .{ policy.moduleKey(runtime), Value{ .array = std.array_list.Managed(Value).init(a) } },
        .{ "resources", resource_names },
    });
    const resource = try object(a, .{.{ "kind", Value{ .string = "runtime" } }});
    const profiles = binding.configuration.object.get("runtimeProfiles") orelse return error.InvalidInstallation;
    const resources = binding.configuration.object.get("resources") orelse return error.InvalidInstallation;
    const grants = binding.registered.object.get("resources") orelse return error.InvalidBindings;
    if (profiles != .object or resources != .object or grants != .object) return error.InvalidInstallation;
    if (binding.configuration.object.get("docker")) |docker| {
        if (docker != .object) return error.RuntimeRegistrationConflict;
        if (docker.object.get("socketPath")) |existing| {
            if (existing != .string or !std.mem.eql(u8, existing.string, socket)) return error.RuntimeRegistrationConflict;
        } else return error.RuntimeRegistrationConflict;
    }
    if (profiles.object.get(name)) |existing| {
        if (!schema.equal(existing, profile)) return error.RuntimeRegistrationConflict;
        const grant = grants.object.get(logical) orelse return error.RuntimeRegistrationConflict;
        const stored_resource = resources.object.get(handle) orelse return error.RuntimeRegistrationConflict;
        if (grant != .string or !std.mem.eql(u8, grant.string, handle) or !schema.equal(stored_resource, resource) or binding.configuration.object.get("docker") == null or binding.registered.object.get("policyDigest") == null) return error.RuntimeRegistrationConflict;
        return false;
    }
    if (resources.object.contains(handle) or grants.object.contains(logical)) return error.RuntimeRegistrationConflict;
    // Validate all authority conflicts before mutating the in-memory installation.
    if (binding.registered.object.get("policyDigest")) |digest| {
        if (digest != .string or digest.string.len != 64) return error.RuntimeRegistrationConflict;
        for (digest.string) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.RuntimeRegistrationConflict;
    }
    if (!binding.configuration.object.contains("docker")) try binding.configuration.object.put(a, "docker", try object(a, .{.{ "socketPath", Value{ .string = try a.dupe(u8, socket) } }}));
    try binding.configuration.object.getPtr("runtimeProfiles").?.object.put(a, try a.dupe(u8, name), profile);
    try binding.configuration.object.getPtr("resources").?.object.put(a, handle, resource);
    try binding.registered.object.getPtr("resources").?.object.put(a, logical, .{ .string = handle });
    if (!binding.registered.object.contains("policyDigest")) {
        const bytes = try std.json.Stringify.valueAlloc(a, profile, .{});
        try binding.registered.object.put(a, "policyDigest", .{ .string = try a.dupe(u8, &code.hash(bytes)) });
    }
    try binding.configuration.object.getPtr("bindings").?.object.put(a, "local", binding.registered);
    var issue: policy.Issue = .{};
    _ = try policy.validate(a, binding.configuration, binding.registered, name, &issue);
    return true;
}
pub fn setupRuntime(alloc: Allocator, name: []const u8, socket: []const u8, image: []const u8, version: []const u8) !void {
    const store = @import("loops/store.zig");
    const io = io_mod.getIo();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    // Reject bad arguments before creating any profile directory.
    _ = try runtimeArguments(name, socket, image, version);
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var directory = try paths.openCredentialRoot(home, true);
    defer directory.close();
    const root = try paths.rootDir(a, home);
    var registry = try store.Store.init(a, io, root);
    defer registry.deinit();
    const lock = try registry.lock("foreground");
    defer lock.close(io);
    try registry.recoverAndRequireSettledResources();
    var binding = try @import("loops/bindings.zig").load(a, io, root, "local");
    defer binding.deinit();
    if (!try registerRuntime(&binding, name, socket, image, version)) {
        try write("Source runtime already registered; existing authority preserved. Run fh check PACKAGE to verify availability.\n");
        return;
    }
    const bytes = try std.json.Stringify.valueAlloc(a, binding.configuration, .{ .whitespace = .indent_2 });
    var atomic = try directory.dir.createFileAtomic(io, "installation.json", .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    try atomic.replace(io);
    if (std.c.fsync(directory.dir.handle) != 0) return error.StoreSyncFailed;
    try write("Optional isolated source runtime registered. Run fh check PACKAGE to verify the installed image and interpreter. No image pull or provider request was made.\n");
}
const runtime_usage = "Usage: fh setup runtime python3|node --socket /absolute/docker.sock --image IMAGE@sha256:DIGEST --version MAJOR.MINOR.PATCH\n";
pub fn run(alloc: Allocator, args: []const [:0]const u8, cfg: cli.Config) !u8 {
    if (args.len >= 1 and std.mem.eql(u8, args[0], "runtime")) {
        var socket: ?[]const u8 = null;
        var image: ?[]const u8 = null;
        var version: ?[]const u8 = null;
        if (args.len < 2) {
            try write(runtime_usage);
            return 2;
        }
        var i: usize = 2;
        while (i < args.len) : (i += 2) {
            if (i + 1 >= args.len) {
                try write(runtime_usage);
                return 2;
            }
            if (std.mem.eql(u8, args[i], "--socket") and socket == null) socket = args[i + 1] else if (std.mem.eql(u8, args[i], "--image") and image == null) image = args[i + 1] else if (std.mem.eql(u8, args[i], "--version") and version == null) version = args[i + 1] else {
                try write(runtime_usage);
                return 2;
            }
        }
        if (socket == null or image == null or version == null) {
            try write(runtime_usage);
            return 2;
        }
        setupRuntime(alloc, args[1], socket.?, image.?, version.?) catch |err| {
            try write("Source runtime setup failed: ");
            try write(@errorName(err));
            try write(". Existing authority was preserved.\n");
            try write(runtime_usage);
            return 2;
        };
        return 0;
    }
    if (args.len >= 1 and std.mem.eql(u8, args[0], "workspace")) {
        var trust = false;
        var binding_id: []const u8 = "workspace";
        var grant: ?[]const u8 = null;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--trust-host")) trust = true else if (std.mem.eql(u8, args[i], "--bindings-id") and i + 1 < args.len) {
                i += 1;
                binding_id = args[i];
            } else if (!std.mem.startsWith(u8, args[i], "--") and grant == null) grant = args[i] else {
                try write("Usage: fh setup workspace GRANT.json [--trust-host] [--bindings-id workspace]\n");
                return 2;
            }
        }
        if (grant == null) {
            try write("Usage: fh setup workspace GRANT.json [--trust-host] [--bindings-id workspace]\n--trust-host is needed only when the grant registers host commands. A grant of files alone gives workspace_read steps read-only access.\n");
            return 2;
        }
        setupWorkspace(alloc, grant.?, binding_id, trust) catch |err| {
            if (err == error.WorkspaceTrustRequired) {
                try write("This grant registers host commands, so it needs --trust-host: fh setup workspace GRANT.json --trust-host [--bindings-id workspace]\nHost commands have your environment, filesystem, network and credentials. Register only commands and editable files authorized for this task. Nothing was changed.\n");
                return 2;
            }
            try write("Workspace setup failed: ");
            try write(@errorName(err));
            try write(". Existing grants and credentials were preserved.\n");
            return 1;
        };
        return 0;
    }
    if (args.len >= 1 and std.mem.eql(u8, args[0], "browser")) {
        if (args.len != 1 and !(args.len == 3 and std.mem.eql(u8, args[1], "--binary"))) {
            try write("Usage: fh setup browser [--binary /absolute/path/to/moli]\n");
            return 2;
        }
        setupBrowser(alloc, if (args.len == 3) args[2] else null) catch |err| {
            try write("Browser setup failed: ");
            try write(@errorName(err));
            try write(". Install Moli 1.1.13 at ~/.local/share/fh/browsers/moli-1.1.13/moli or use fh setup browser --binary /absolute/path/to/moli. No download was attempted.\n");
            return 1;
        };
        return 0;
    }
    if (args.len > 1 or (args.len == 1 and !std.mem.eql(u8, args[0], "ai") and !std.mem.eql(u8, args[0], "jev"))) {
        try write("Usage: fh setup [ai|jev|browser|workspace|runtime]\n");
        return 2;
    }
    if (std.c.isatty(0) == 0 or std.c.isatty(2) == 0) {
        try write("fh setup needs an interactive terminal. Keys are entered with hidden input.\n");
        return 2;
    }
    try write("𝒇h · Setup\n\n");
    journey(alloc, args, cfg) catch |err| {
        if (err == error.SetupCancelled) {
            try write("\nSetup cancelled. Completed connections were kept. Run fh setup to continue.\n");
            return 130;
        }
        try write("\nSetup could not finish (");
        try write(@errorName(err));
        try write("). Run fh setup to continue.\n");
        return 1;
    };
    try write("\nReady. Run fh to chat, or fh check PACKAGE to inspect a Loop.\n");
    return 0;
}
fn journey(alloc: Allocator, args: []const [:0]const u8, cfg: cli.Config) !void {
    if (args.len == 1 and std.mem.eql(u8, args[0], "jev")) return jev(alloc);
    try ai(alloc, cfg);
    if (args.len == 1) return;
    if (try keys.presence(alloc, "TYPESAFE_API_KEY") == .present) {
        try write("Jev is already connected.\n");
    } else if (try yes(alloc, "Add a Jev key for decision steps? [y/N] ")) {
        try jev(alloc);
    }
    const browser = @import("loops/browser.zig");
    const binary = browser.installedPath(alloc) catch return;
    defer alloc.free(binary);
    browser.validateBinary(io_mod.getIo(), binary) catch return;
    if (try yes(alloc, "Enable the installed local Moli browser for browser Loops? [y/N] ")) try setupBrowser(alloc, null);
}

test "fh onboarding rejects invalid route before requesting a secret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.ReservedProviderId, compatibleDefinition(a, "codex", "https://example.com/v1", "model", "FH_AI_KEY"));
    try std.testing.expectError(error.InsecureBaseUrl, compatibleDefinition(a, "api", "http://example.com/v1", "model", "FH_AI_KEY"));
    const route = try compatibleDefinition(a, "api", "http://127.0.0.1:1234/v1", "fixture-model", "FH_AI_api_KEY");
    try std.testing.expectEqualStrings("openai-chat-completions", route.object.get("protocol").?.string);
}

test "fh onboarding workspace grant needs host trust only when it registers commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = @import("loops/schema.zig").parse;
    // Files only: nothing runs on the host, so no trust is asked for and none is written.
    for ([_][]const u8{ "{\"workspace\":\"/w\",\"files\":[\"a.txt\"]}", "{\"workspace\":\"/w\",\"files\":[\"a.txt\"],\"commands\":{}}" }) |bytes| {
        const reading = try workspaceResource(a, try parse(a, bytes), "/w", 1, 2, false);
        try std.testing.expect(reading.object.get("trust") == null);
        try std.testing.expectEqual(@as(usize, 0), reading.object.get("commands").?.object.count());
        try std.testing.expectEqualStrings("a.txt", reading.object.get("files").?.array.items[0].string);
    }
    const running = try parse(a, "{\"workspace\":\"/w\",\"files\":[],\"commands\":{\"go\":[\"/usr/bin/true\"]}}");
    try std.testing.expectError(error.WorkspaceTrustRequired, workspaceResource(a, running, "/w", 1, 2, false));
    const trusted = try workspaceResource(a, running, "/w", 1, 2, true);
    try std.testing.expectEqualStrings("trusted-host-commands", trusted.object.get("trust").?.string);
    try std.testing.expectError(error.InvalidWorkspacePolicy, workspaceResource(a, try parse(a, "{\"workspace\":\"/w\",\"files\":[],\"extra\":1}"), "/w", 1, 2, true));
    try std.testing.expectError(error.InvalidWorkspacePolicy, workspaceResource(a, try parse(a, "{\"workspace\":\"/w\"}"), "/w", 1, 2, true));
}

test {
    _ = @import("decision_status.zig");
}

test "fh onboarding generic runtime registration is Node-only, merge-safe and idempotent" {
    const bindings = @import("loops/bindings.zig");
    const schema = @import("loops/schema.zig");
    const image = "node@sha256:" ++ "a" ** 64;
    var binding = try bindings.fromBytes(std.testing.allocator, "{\"version\":1,\"limits\":{\"maxTokens\":42},\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{},\"capabilities\":{\"other\":\"keep\"}}},\"resources\":{},\"runtimeProfiles\":{},\"other\":\"preserved\"}", "local");
    defer binding.deinit();
    try std.testing.expect(try registerRuntime(&binding, "node", "/tmp/docker.sock", image, "24.18.0"));
    try std.testing.expect(!try registerRuntime(&binding, "node", "/tmp/docker.sock", image, "24.18.0"));
    try std.testing.expectEqualStrings("preserved", binding.configuration.object.get("other").?.string);
    try std.testing.expectEqual(@as(u64, 42), binding.limits.max_tokens);
    try std.testing.expect(binding.configuration.object.get("runtimeProfiles").?.object.get("python3") == null);
    const before = try std.json.Stringify.valueAlloc(std.testing.allocator, binding.configuration, .{});
    defer std.testing.allocator.free(before);
    try std.testing.expectError(error.RuntimeRegistrationConflict, registerRuntime(&binding, "node", "/tmp/docker.sock", image, "24.19.0"));
    try std.testing.expectError(error.InvalidRuntimeSocket, registerRuntime(&binding, "python3", "relative", image, "3.12.0"));
    try std.testing.expectError(error.UnsupportedRuntime, registerRuntime(&binding, "node", "/tmp/docker.sock", image, "22.14.0"));
    try std.testing.expectError(error.InvalidRuntimeImage, registerRuntime(&binding, "node", "/tmp/docker.sock", "node:latest", "24.18.0"));
    try std.testing.expect(schema.equal(try schema.parse(binding.arena.allocator(), before), binding.configuration));
}

test "fh onboarding adds Node beside existing Python and preserves authority" {
    const bindings = @import("loops/bindings.zig");
    const schema = @import("loops/schema.zig");
    var binding = try bindings.fromBytes(std.testing.allocator, "{\"version\":1,\"docker\":{\"socketPath\":\"/tmp/docker.sock\",\"stagingRoot\":\"/keep/staging\"},\"bindings\":{\"local\":{\"id\":\"local\",\"policyDigest\":\"" ++ "b" ** 64 ++ "\",\"resources\":{\"runtime\":\"python\"},\"capabilities\":{\"browser\":\"keep\"}},\"workspace\":{\"id\":\"workspace\",\"resources\":{},\"capabilities\":{}}},\"resources\":{\"python\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"python3\":{\"resources\":[\"runtime\"]},\"fh-workspace/1\":{\"resources\":[\"workspace\"]}},\"limits\":{\"maxTokens\":42}}", "local");
    defer binding.deinit();
    const a = binding.arena.allocator();
    const before = try schema.parse(a, try std.json.Stringify.valueAlloc(a, binding.configuration, .{}));
    try std.testing.expect(try registerRuntime(&binding, "node", "/tmp/docker.sock", "node@sha256:" ++ "a" ** 64, "24.18.0"));
    for ([_][]const u8{ "docker", "limits" }) |key| try std.testing.expect(schema.equal(before.object.get(key).?, binding.configuration.object.get(key).?));
    for ([_][]const u8{ "python3", "fh-workspace/1" }) |key| try std.testing.expect(schema.equal(before.object.get("runtimeProfiles").?.object.get(key).?, binding.configuration.object.get("runtimeProfiles").?.object.get(key).?));
    try std.testing.expect(schema.equal(before.object.get("bindings").?.object.get("workspace").?, binding.configuration.object.get("bindings").?.object.get("workspace").?));
    try std.testing.expectEqualStrings("b" ** 64, binding.registered.object.get("policyDigest").?.string);
    try std.testing.expectEqualStrings("python", binding.registered.object.get("resources").?.object.get("runtime").?.string);
    try std.testing.expectEqualStrings("keep", binding.registered.object.get("capabilities").?.object.get("browser").?.string);
    try std.testing.expectError(error.RuntimeRegistrationConflict, registerRuntime(&binding, "python3", "/different.sock", "python@sha256:" ++ "a" ** 64, "3.12.0"));
}
