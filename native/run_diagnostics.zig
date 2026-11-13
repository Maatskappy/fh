//! Bounded, static failure guidance and conservative whole-run replay admission.
const std = @import("std");
const Value = std.json.Value;
fn field(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}
fn text(value: Value, key: []const u8) ?[]const u8 {
    const item = field(value, key) orelse return null;
    return if (item == .string) item.string else null;
}
fn is(value: Value, key: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, text(value, key) orelse "", expected);
}
fn boolean(value: Value, key: []const u8, expected: bool) bool {
    const item = field(value, key) orelse return false;
    return item == .bool and item.bool == expected;
}
fn nonnegative(value: Value, key: []const u8) bool {
    const item = field(value, key) orelse return false;
    return item == .integer and item.integer >= 0;
}
fn sorted(alloc: std.mem.Allocator, value: Value, depth: usize) anyerror!Value {
    if (depth > 128) return error.InvalidInput;
    switch (value) {
        .object => |map| {
            var result = Value{ .object = .{} };
            const keys = try alloc.dupe([]const u8, map.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.less);
            for (keys) |key| try result.object.put(alloc, key, try sorted(alloc, map.get(key).?, depth + 1));
            return result;
        },
        .array => |list| {
            var result = Value{ .array = std.array_list.Managed(Value).init(alloc) };
            for (list.items) |item| try result.array.append(try sorted(alloc, item, depth + 1));
            return result;
        },
        .float => |n| if (!std.math.isFinite(n)) return error.InvalidInput,
        .number_string => return error.InvalidInput,
        else => {},
    }
    return value;
}
/// Compact JSON, recursively sorted object keys, preserving array order.
pub fn inputSha256(allocator: std.mem.Allocator, value: Value) ![64]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const bytes = try std.json.Stringify.valueAlloc(alloc, try sorted(alloc, value, 0), .{});
    if (bytes.len > 1048576) return error.InvalidInput;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
pub const Retry = struct { allowed: bool, reason: []const u8, message: []const u8 };
fn refuse(reason: []const u8, guidance_message: []const u8) Retry {
    return .{ .allowed = false, .reason = reason, .message = guidance_message };
}
fn fieldsExactly(value: Value, keys: []const []const u8) bool {
    if (value != .object or value.object.count() != keys.len) return false;
    for (keys) |key| if (!value.object.contains(key)) return false;
    return true;
}
fn integer(value: Value, key: []const u8, expected: i64) bool {
    const item = field(value, key) orelse return false;
    return item == .integer and item.integer == expected;
}
fn strings(value: Value, key: []const u8, expected: []const []const u8) bool {
    const items = field(value, key) orelse return false;
    if (items != .array or items.array.items.len != expected.len) return false;
    for (items.array.items, expected) |item, want| if (item != .string or !std.mem.eql(u8, item.string, want)) return false;
    return true;
}
fn safeAbsolute(path: []const u8) bool {
    return path.len >= 2 and path[0] == '/' and safeRelative(path[1..]);
}
fn safeRelative(path: []const u8) bool {
    if (path.len == 0 or path.len >= 4096) return false;
    for (path) |c| if (c < 32 or c == 127 or c == '\\') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}
/// The exact argv saved code runs under: python3, or the loops/0.3 node shim over /package.
fn isolatedCommand(command: Value) bool {
    if (command != .array) return false;
    const args = command.array.items;
    for (args) |arg| if (arg != .string) return false;
    const env = [_][]const u8{ "-i", "PATH=/usr/bin:/bin", "LANG=C.UTF-8" };
    if (args.len < env.len + 1) return false;
    for (args[0..env.len], env) |arg, expected| if (!std.mem.eql(u8, arg.string, expected)) return false;
    const rest = args[env.len..];
    if (std.mem.eql(u8, rest[0].string, "/usr/bin/python3")) {
        const flags = [_][]const u8{ "-E", "-s", "-S", "-B" };
        if (rest.len != flags.len + 2) return false;
        for (rest[1 .. 1 + flags.len], flags) |arg, expected| if (!std.mem.eql(u8, arg.string, expected)) return false;
        const entry = rest[rest.len - 1].string;
        return std.mem.startsWith(u8, entry, "/package/") and safeAbsolute(entry);
    }
    if (std.mem.eql(u8, rest[0].string, "/usr/local/bin/node")) {
        const fixed = [_][]const u8{ "--input-type=module", "-e", @embedFile("loops/node_shim.mjs"), "--", "/package" };
        if (rest.len != fixed.len + 2) return false;
        for (rest[1 .. 1 + fixed.len], fixed) |arg, expected| if (!std.mem.eql(u8, arg.string, expected)) return false;
        return safeRelative(rest[rest.len - 1].string);
    }
    return false;
}
fn isolated(receipt: Value) bool {
    const details = field(receipt, "details") orelse return false;
    const config = field(details, "config") orelse return false;
    // Recognize only the complete create-config contract emitted by saved code.
    // Exact key sets reject additive Docker channels, including Binds, devices,
    // VolumesFrom, Env, CapAdd and newly introduced sandbox options.
    if (!fieldsExactly(config, &.{ "Image", "User", "Entrypoint", "Cmd", "WorkingDir", "Tty", "OpenStdin", "StdinOnce", "AttachStdin", "AttachStdout", "AttachStderr", "HostConfig", "Labels" })) return false;
    if (!is(config, "User", "65534:65534") or !is(config, "WorkingDir", "/work") or !strings(config, "Entrypoint", &.{"/usr/bin/env"})) return false;
    if (!boolean(config, "Tty", false)) return false;
    for ([_][]const u8{ "OpenStdin", "StdinOnce", "AttachStdin", "AttachStdout", "AttachStderr" }) |key| if (!boolean(config, key, true)) return false;
    const image = text(config, "Image") orelse return false;
    const digest_at = std.mem.lastIndexOf(u8, image, "@sha256:") orelse return false;
    if (digest_at == 0 or image.len - digest_at - 8 != 64) return false;
    for (image[digest_at + 8 ..]) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    if (!isolatedCommand(field(config, "Cmd") orelse return false)) return false;
    const labels = field(config, "Labels") orelse return false;
    for ([_][]const u8{ "fasthands.owner", "fasthands.epoch", "fasthands.attempt" }) |key| {
        const label = text(labels, key) orelse return false;
        if (label.len == 0) return false;
    }
    const host = field(config, "HostConfig") orelse return false;
    if (!fieldsExactly(host, &.{ "NetworkMode", "ReadonlyRootfs", "CapDrop", "SecurityOpt", "LogConfig", "RestartPolicy", "AutoRemove", "Privileged", "PidMode", "IpcMode", "CgroupnsMode", "PidsLimit", "Memory", "MemorySwap", "NanoCpus", "Ulimits", "Tmpfs", "Mounts" })) return false;
    if (!is(host, "NetworkMode", "none") or !boolean(host, "ReadonlyRootfs", true) or !boolean(host, "Privileged", false) or !boolean(host, "AutoRemove", false)) return false;
    if (!is(host, "PidMode", "") or !is(host, "IpcMode", "private") or !is(host, "CgroupnsMode", "private")) return false;
    if (!strings(host, "CapDrop", &.{"ALL"}) or !strings(host, "SecurityOpt", &.{"no-new-privileges"})) return false;
    if (!integer(host, "PidsLimit", 32) or !integer(host, "Memory", 128 * 1048576) or !integer(host, "MemorySwap", 128 * 1048576) or !integer(host, "NanoCpus", 1000000000)) return false;
    const log = field(host, "LogConfig") orelse return false;
    const log_options = field(log, "Config") orelse return false;
    if (!fieldsExactly(log, &.{ "Type", "Config" }) or !is(log, "Type", "none") or !fieldsExactly(log_options, &.{})) return false;
    const restart = field(host, "RestartPolicy") orelse return false;
    if (!fieldsExactly(restart, &.{ "Name", "MaximumRetryCount" }) or !is(restart, "Name", "no") or !integer(restart, "MaximumRetryCount", 0)) return false;
    const limits = field(host, "Ulimits") orelse return false;
    if (limits != .array or limits.array.items.len != 1) return false;
    const core = limits.array.items[0];
    if (!fieldsExactly(core, &.{ "Name", "Soft", "Hard" }) or !is(core, "Name", "core") or !integer(core, "Soft", 0) or !integer(core, "Hard", 0)) return false;
    const tmpfs = field(host, "Tmpfs") orelse return false;
    if (!fieldsExactly(tmpfs, &.{ "/tmp", "/work" }) or !is(tmpfs, "/tmp", "rw,noexec,nosuid,nodev,size=8m") or !is(tmpfs, "/work", "rw,noexec,nosuid,nodev,size=8m")) return false;
    const mounts = field(host, "Mounts") orelse return false;
    if (mounts != .array or mounts.array.items.len == 0 or mounts.array.items.len > 17) return false;
    for (mounts.array.items, 0..) |mount, index| {
        if (!fieldsExactly(mount, &.{ "Type", "Source", "Target", "ReadOnly" }) or !is(mount, "Type", "bind") or !boolean(mount, "ReadOnly", true)) return false;
        if (!safeAbsolute(text(mount, "Source") orelse "")) return false;
        const target = text(mount, "Target") orelse return false;
        if (index == 0) {
            if (!std.mem.eql(u8, target, "/package")) return false;
        } else {
            if (!std.mem.startsWith(u8, target, "/grants/") or target.len <= 8 or target.len > 72) return false;
            for (target[8..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
        }
        for (mounts.array.items[0..index]) |prior| if (is(prior, "Target", target)) return false;
    }
    return true;
}
/// Evaluates durable evidence only. Engine separately verifies current digests.
pub fn retryGuidance(record: Value) Retry {
    // An agent-driven run made no model call; a retry would start a runner-driven run that does.
    if (is(record, "driver", "agent")) return refuse("agent_driven", "This run is driven by an agent; retry would start a runner-driven run. Start a new run with the agent driver instead.");
    if (is(record, "status", "running") or is(record, "status", "queued")) return refuse("active_run", "Wait for the active run to settle; retry never resumes a step.");
    if (is(record, "status", "completed")) return refuse("completed_run", "Completed runs cannot be retried; use run for a new evaluation.");
    if (!is(record, "status", "failed") and !is(record, "status", "stopped")) return refuse("invalid_record", "Inspect the durable run record before starting another run.");
    for ([_][]const u8{ "package_path", "bindings_id", "input_source", "input_sha256", "package_digest", "binding_digest" }) |key| {
        const item = text(record, key) orelse return refuse("missing_attribution", "This legacy record lacks retained attribution or original input; retry is unavailable.");
        if (item.len == 0) return refuse("missing_attribution", "This legacy record lacks retained attribution or original input; retry is unavailable.");
    }
    if (field(record, "root_input") == null) return refuse("missing_attribution", "This legacy record lacks retained attribution or original input; retry is unavailable.");
    if (!nonnegative(record, "model_request_dispatches") or !nonnegative(record, "used_tokens") or !boolean(record, "usage_unknown", false) or !boolean(record, "model_request_dispatches_complete", true) or boolean(record, "recovery_required", true)) return refuse("unknown_usage", "Usage or dispatch accounting is uncertain; inspect the original run before retrying.");
    const effects = field(record, "effects") orelse return refuse("unknown_effects", "Effect receipts are missing; inspect the original run before retrying.");
    if (effects != .array) return refuse("unknown_effects", "Effect receipts are invalid; inspect the original run before retrying.");
    for (effects.array.items) |receipt| {
        if (is(receipt, "state", "unknown")) return refuse("unknown_effects", "An effect is uncertain. Inspect it before considering retry; fh settle records an outcome supported by your inspection.");
        if (!is(receipt, "state", "applied") and !is(receipt, "state", "not_applied")) return refuse("unknown_effects", "An effect receipt has an unknown state; retry is unavailable.");
        const kind = text(receipt, "kind") orelse return refuse("unknown_effect_kind", "An effect kind is unknown; retry is unavailable.");
        if (std.mem.eql(u8, kind, "decision_request")) continue;
        if (std.mem.eql(u8, kind, "code_staging") or std.mem.eql(u8, kind, "code_container") or std.mem.eql(u8, kind, "code_invocation")) {
            if (!isolated(receipt)) return refuse("unverified_isolation", "Code isolation and read-only grants are not proven; retry is unavailable.");
            continue;
        }
        if (is(receipt, "state", "applied")) return refuse("applied_effect", "An external effect was applied; inspect its outcome before starting new work.");
        return refuse("unknown_effect_kind", "An effect kind is not known to be replayable; retry is unavailable.");
    }
    return .{ .allowed = true, .reason = "new_whole_run", .message = "Explicit retry starts a new whole run with the retained input and unchanged package and bindings; it may incur provider usage." };
}
pub fn failureMessage(cause: []const u8) []const u8 {
    if (std.mem.eql(u8, cause, "PackageChanged")) return "The package digest changed. Inspect the intended package and start a new evaluation explicitly.";
    if (std.mem.eql(u8, cause, "BindingChanged")) return "Installation bindings changed. Inspect the current policy and grants and start a new evaluation explicitly.";
    if (std.mem.startsWith(u8, cause, "Retry")) return "Retry was refused by durable accounting, effect or attribution guards. Inspect fh get for the original run's retry guidance.";
    if (std.mem.eql(u8, cause, "NativeProviderAccessDenied")) return "Provider access was denied. Inspect the configured account and model permissions before starting new work.";
    if (std.mem.eql(u8, cause, "NativeProviderRateLimited")) return "The provider rate limit was reached. Check provider availability and retained accounting before an explicit retry.";
    if (std.mem.eql(u8, cause, "NativeProviderRequestTooLarge") or std.mem.eql(u8, cause, "NativeProviderInvalidRequest")) return "The provider rejected the request. Inspect input size, model configuration and the step schema before starting new work.";
    if (std.mem.eql(u8, cause, "NativeProviderServerError") or std.mem.eql(u8, cause, "NativeProviderBadGateway") or std.mem.eql(u8, cause, "NativeProviderUnavailable") or std.mem.eql(u8, cause, "NativeProviderGatewayTimeout") or std.mem.eql(u8, cause, "DecisionHttpFailure")) return "The provider request failed. Inspect provider availability and retained usage and effects before an explicit retry.";
    if (std.mem.eql(u8, cause, "RuntimeUnavailable") or std.mem.eql(u8, cause, "DockerUnavailable")) return "The isolated runtime is unavailable. Check the configured daemon and installed pinned image, then run fh check.";
    if (std.mem.eql(u8, cause, "WorkspaceChanged")) return "The registered workspace changed. Inspect the current files and prior effects before registering the intended baseline.";
    if (std.mem.eql(u8, cause, "InvalidInput")) return "Input failed validation. Inspect the package input schema and provide JSON within the 1 MiB limit.";

    if (std.mem.eql(u8, cause, "NativeProviderLoginRequired") or std.mem.eql(u8, cause, "CodexLoginRequired")) return "fh has no working AI access (none is set up, or the login has ended), so its own model could not run this step. Run fh setup ai once, then run this again. Or run it with --driver agent, which needs no setup: your own agent performs each step with fh next and fh submit.";
    if (std.mem.eql(u8, cause, "DecisionKeyRequired")) return "Decision credentials are required. Run fh setup decision, then inspect retry eligibility.";
    if (std.mem.eql(u8, cause, "UsageUnavailable")) return "Provider usage is unavailable. Inspect the retained failure cause and accounting before retrying.";
    if (std.mem.eql(u8, cause, "RecoveryRequired")) return "New work records abandoned runs as stopped under their leases; fh get RUN can also record interruption. Unresolved local resource or mutation effects still block independent work: inspect them before recording their outcome with fh settle RUN --applied or --not-applied. Unknown provider outcomes and incomplete usage prevent retry.";
    if (std.mem.eql(u8, cause, "UncertainEffect") or std.mem.eql(u8, cause, "CleanupPending")) return "An effect or interrupted run needs recovery. Inspect what the uncertain effect did, then record the outcome with fh settle RUN --applied or fh settle RUN --not-applied before starting new work.";
    if (std.mem.eql(u8, cause, "InvalidOutput") or std.mem.eql(u8, cause, "InvalidDecisionResponse") or std.mem.eql(u8, cause, "InvalidJson")) return "Step output failed validation. Inspect the step schema and retained package before starting new work.";
    if (std.mem.eql(u8, cause, "CodeExit")) return "Code exited unsuccessfully. Inspect the retained code and runtime configuration before an explicit retry.";
    if (std.mem.eql(u8, cause, "Cancelled")) return "The run was cancelled. Inspect accounting and effects before an explicit retry.";
    if (std.mem.endsWith(u8, cause, "Limit")) return "A configured run limit was reached. Inspect input and package behavior; retry uses the same limits.";
    return "Execution failed. Inspect the durable failure identifier, package, bindings and effects before starting new work.";
}
/// Preaccept or persistence errors carry only native identifiers and static guidance.
pub fn errorDiagnostic(allocator: std.mem.Allocator, err: anyerror) !Value {
    var result = Value{ .object = .{} };
    try result.object.put(allocator, "cause", .{ .string = @errorName(err) });
    try result.object.put(allocator, "step_id", .null);
    try result.object.put(allocator, "message", .{ .string = failureMessage(@errorName(err)) });
    var retry = Value{ .object = .{} };
    try retry.object.put(allocator, "allowed", .{ .bool = false });
    try retry.object.put(allocator, "reason", .{ .string = "inspect_acceptance" });
    try retry.object.put(allocator, "message", .{ .string = "Inspect any accepted run and its receipts. Correct the reported issue before explicitly starting new work." });
    try result.object.put(allocator, "retry", retry);
    return result;
}
pub fn diagnostic(allocator: std.mem.Allocator, record: Value) !Value {
    var result = Value{ .object = .{} };
    var cause: ?[]const u8 = text(record, "failure_cause");
    if (cause == null) {
        if (field(record, "error") orelse field(record, "stop")) |failure| cause = text(failure, "cause");
    }
    const completed = is(record, "status", "completed");
    try result.object.put(allocator, "cause", if (cause) |id| .{ .string = id } else .null);
    var step: Value = if (text(record, "failure_step_id")) |id| .{ .string = id } else .null;
    if (step == .null) if (field(record, "attempts")) |attempts| if (attempts == .array and attempts.array.items.len > 0 and !completed) {
        const last = attempts.array.items[attempts.array.items.len - 1];
        if (!is(last, "status", "completed")) if (text(last, "step_id")) |id| {
            step = .{ .string = id };
        };
    };
    try result.object.put(allocator, "step_id", step);
    try result.object.put(allocator, "message", .{ .string = if (completed) "Run completed." else if (boolean(record, "awaiting_driver", true)) "Run is waiting for its agent. Use next and submit." else failureMessage(cause orelse "") });
    const retry = retryGuidance(record);
    var guidance = Value{ .object = .{} };
    try guidance.object.put(allocator, "allowed", .{ .bool = retry.allowed });
    try guidance.object.put(allocator, "reason", .{ .string = retry.reason });
    try guidance.object.put(allocator, "message", .{ .string = retry.message });
    try result.object.put(allocator, "retry", guidance);
    return result;
}

test "native input canonical hash ignores object key order and whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema = @import("loops/schema.zig");
    const a = try inputSha256(alloc, try schema.parse(alloc, "{\"z\":1,\"a\":{\"b\":2,\"a\":1}}"));
    const b = try inputSha256(alloc, try schema.parse(alloc, " { \"a\":{\"a\":1,\"b\":2},\"z\":1 } "));
    try std.testing.expectEqualStrings(&a, &b);
}

test "native retry guidance admits known provider requests and refuses partial isolation evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema = @import("loops/schema.zig");
    var record = try schema.parse(alloc, "{\"status\":\"failed\",\"package_path\":\"/package/loop.json\",\"bindings_id\":\"local\",\"input_source\":\"inline\",\"input_sha256\":\"hash\",\"root_input\":{},\"package_digest\":\"package\",\"binding_digest\":\"binding\",\"usage_unknown\":false,\"model_request_dispatches\":0,\"used_tokens\":0,\"model_request_dispatches_complete\":true,\"effects\":[]}");
    try record.object.put(alloc, "effects", try schema.parse(alloc, "[{\"id\":\"provider\",\"kind\":\"decision_request\",\"state\":\"applied\"}]"));
    try std.testing.expect(retryGuidance(record).allowed);
    try record.object.put(alloc, "effects", try schema.parse(alloc, "[{\"id\":\"code\",\"kind\":\"code_invocation\",\"state\":\"applied\",\"details\":{\"config\":{\"HostConfig\":{\"NetworkMode\":\"none\",\"ReadonlyRootfs\":true,\"Privileged\":false,\"Mounts\":[{\"ReadOnly\":true}]}}}}]"));
    try std.testing.expectEqualStrings("unverified_isolation", retryGuidance(record).reason);
    try record.object.put(alloc, "effects", try schema.parse(alloc, "[{\"id\":\"missing-proof\",\"kind\":\"code_container\",\"state\":\"not_applied\"}]"));
    try std.testing.expectEqualStrings("unverified_isolation", retryGuidance(record).reason);
    try record.object.put(alloc, "effects", try schema.parse(alloc, "[]"));
    try record.object.put(alloc, "model_request_dispatches_complete", .{ .bool = false });
    try std.testing.expectEqualStrings("unknown_usage", retryGuidance(record).reason);
}
test "native login-required failure names fh setup ai and the agent driver that needs no setup" {
    for ([_][]const u8{ "NativeProviderLoginRequired", "CodexLoginRequired" }) |cause| {
        const message = failureMessage(cause);
        try std.testing.expect(std.mem.indexOf(u8, message, "Run fh setup ai once") != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "--driver agent") != null);
        try std.testing.expect(std.mem.indexOf(u8, message, "needs no setup") != null);
    }
}
test "native diagnostics preserve safe cause with unknown usage and exclude exception prose" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const record = try @import("loops/schema.zig").parse(alloc, "{\"status\":\"stopped\",\"failure_cause\":\"NativeProviderRateLimited\",\"stop\":{\"cause\":\"UsageUnavailable\",\"reason\":\"usage_unavailable\"},\"attempts\":[{\"step_id\":\"judge\",\"exception\":\"synthetic-private-provider-detail\"}],\"usage_unknown\":true}");
    const result = try diagnostic(alloc, record);
    try std.testing.expectEqualStrings("NativeProviderRateLimited", text(result, "cause").?);
    try std.testing.expectEqualStrings("judge", text(result, "step_id").?);
    const bytes = try std.json.Stringify.valueAlloc(alloc, result, .{});
    try std.testing.expect(bytes.len < 1024);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "synthetic-private") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "rate limit") != null);
    try std.testing.expect(!boolean(field(result, "retry").?, "allowed", true));
}
