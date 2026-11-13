//! Native saved workspace operations. Host commands are explicit trusted grants,
//! not a sandbox; inference receives data and never chooses executable arguments.
const std = @import("std");
const metadata = @import("../metadata.zig");
const runner = @import("runner.zig");
const bindings = @import("bindings.zig");
const package = @import("package.zig");
const schema = @import("schema.zig");
const storage = @import("store.zig");
const code = @import("code.zig");
const command = @import("../../vendor/fx/src/core/execution/command_runner.zig");
const types = @import("../../vendor/fx/src/core/shared/types.zig");
const Value = runner.Value;
const Allocator = std.mem.Allocator;
pub const runtime = "fh-workspace/1";
pub const Authority = struct { context: *anyopaque, checkFn: *const fn (*anyopaque) anyerror!void };
pub const Policy = struct { handle: []const u8, workspace: []const u8, files: Value, commands: Value, dev: u64, ino: u64 };
const max_file_bytes = 65536;

fn string(v: Value, key: []const u8) ![]const u8 {
    return runner.text(try runner.get(v, key));
}
fn integer(v: Value, key: []const u8) !u64 {
    const n = try runner.get(v, key);
    if (n != .integer or n.integer < 0) return error.InvalidWorkspacePolicy;
    return @intCast(n.integer);
}
fn absolute(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidWorkspacePolicy;
}
fn fields(v: Value, names: []const []const u8) !void {
    if (v != .object) return error.InvalidWorkspaceProgram;
    for (v.object.keys()) |key| {
        var found = false;
        for (names) |name| if (std.mem.eql(u8, name, key)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidWorkspaceProgram;
    }
}
pub fn configured(binding: *bindings.Binding, io: std.Io) !Policy {
    const profile = binding.profile(runtime) catch return error.WorkspaceSetupRequired;
    const resources = try runner.get(profile, "resources");
    if (resources != .array or resources.array.items.len != 1) return error.InvalidWorkspacePolicy;
    const resource = try binding.resource(try runner.text(resources.array.items[0]));
    const value = resource.value;
    if (!std.mem.eql(u8, try string(value, "kind"), "workspace-runtime")) return error.PermissionDenied;
    const workspace = try string(value, "workspace");
    try absolute(workspace);
    const files = try runner.get(value, "files");
    if (files != .array or files.array.items.len > 16) return error.InvalidWorkspacePolicy;
    for (files.array.items, 0..) |file, i| {
        const path = try runner.text(file);
        try package.localPath(path);
        for (files.array.items[0..i]) |prior| if (schema.equal(file, prior)) return error.InvalidWorkspacePolicy;
    }
    const commands = try runner.get(value, "commands");
    if (commands != .object or commands.object.count() > 16) return error.InvalidWorkspacePolicy;
    // Host commands run with the user's environment and credentials, so a grant that registers
    // any must carry the trust `fh setup workspace --trust-host` records. A grant of files
    // alone runs nothing: it is read-only and needs none.
    if (commands.object.count() != 0) {
        const trust = value.object.get("trust") orelse return error.PermissionDenied;
        if (trust != .string or !std.mem.eql(u8, trust.string, "trusted-host-commands")) return error.PermissionDenied;
    }
    for (commands.object.values()) |argv| {
        if (argv != .array or argv.array.items.len == 0 or argv.array.items.len > 32) return error.InvalidWorkspacePolicy;
        for (argv.array.items) |arg| {
            const text = try runner.text(arg);
            if (text.len == 0 or text.len > 4096 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidWorkspacePolicy;
        }
        try absolute(try runner.text(argv.array.items[0]));
        var executable = std.Io.Dir.openFileAbsolute(io, argv.array.items[0].string, .{}) catch return error.WorkspaceCommandUnavailable;
        defer executable.close(io);
        const stat = try executable.stat(io);
        if (stat.kind != .file or stat.permissions.toMode() & 0o111 == 0) return error.WorkspaceCommandUnavailable;
    }
    const policy: Policy = .{ .handle = resource.handle, .workspace = workspace, .files = files, .commands = commands, .dev = try integer(value, "dev"), .ino = try integer(value, "ino") };
    var directory = try openWorkspace(io, policy);
    directory.close(io);
    return policy;
}
fn openWorkspace(io: std.Io, policy: Policy) !std.Io.Dir {
    var directory = storage.openDirectory(io, policy.workspace) catch return error.WorkspaceChanged;
    errdefer directory.close(io);
    const stat = metadata.fstat(directory.handle) catch return error.WorkspaceChanged;
    if (@as(u64, @intCast(stat.dev)) != policy.dev or stat.ino != policy.ino) return error.WorkspaceChanged;
    return directory;
}
pub const Program = struct { apply: bool, command_name: []const u8, fail_on_nonzero: bool };
pub fn program(allocator: Allocator, pkg: *package.Package, step_id: []const u8, policy: Policy) !Program {
    const saved = try pkg.stepCode(step_id);
    const value = try schema.parse(allocator, saved.bytes);
    try fields(value, &.{ "operation", "command" });
    const operation = try string(value, "operation");
    const apply = std.mem.eql(u8, operation, "apply_check");
    if (!apply and !std.mem.eql(u8, operation, "check") and !std.mem.eql(u8, operation, "command")) return error.InvalidWorkspaceProgram;
    const name = try string(value, "command");
    if (!policy.commands.object.contains(name)) return error.PermissionDenied;
    return .{ .apply = apply, .command_name = name, .fail_on_nonzero = std.mem.eql(u8, operation, "command") };
}
/// A step of this runtime always runs a registered command, which a read-only grant has none of.
fn commandGrant(binding: *bindings.Binding, io: std.Io) !Policy {
    const policy = try configured(binding, io);
    if (policy.commands.object.count() == 0) return error.WorkspaceReadOnlyGrant;
    return policy;
}
pub fn preflight(binding: *bindings.Binding, io: std.Io, pkg: *package.Package, step_id: []const u8) !void {
    const policy = try commandGrant(binding, io);
    _ = try program(binding.arena.allocator(), pkg, step_id, policy);
    // Inspect source metadata without running commands or collecting contents.
    var root = try openWorkspace(io, policy);
    defer root.close(io);
    for (policy.files.array.items) |file| {
        var parent = try openParent(io, root, file.string);
        defer parent.dir.close(io);
        var source = try parent.dir.openFile(io, parent.leaf, .{ .follow_symlinks = false });
        defer source.close(io);
        const stat = try source.stat(io);
        if (stat.kind != .file or stat.size > max_file_bytes) return error.WorkspaceFileUnavailable;
    }
}
const Parent = struct { dir: std.Io.Dir, leaf: []const u8 };
fn openParent(io: std.Io, root: std.Io.Dir, path: []const u8) !Parent {
    try package.localPath(path);
    var directory = try root.openDir(io, ".", .{ .follow_symlinks = false });
    errdefer directory.close(io);
    var parts = std.mem.splitScalar(u8, path, '/');
    var leaf = parts.next().?;
    while (parts.next()) |next| {
        const child = try directory.openDir(io, leaf, .{ .follow_symlinks = false });
        directory.close(io);
        directory = child;
        leaf = next;
    }
    return .{ .dir = directory, .leaf = leaf };
}
const Source = struct { bytes: []const u8, permissions: std.Io.File.Permissions };
fn readSource(allocator: Allocator, io: std.Io, parent: Parent) !Source {
    var file = try parent.dir.openFile(io, parent.leaf, .{ .follow_symlinks = false });
    defer file.close(io);
    const before = try file.stat(io);
    if (before.kind != .file or before.size > max_file_bytes) return error.WorkspaceFileUnavailable;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.WorkspaceChanged;
    const after = try file.stat(io);
    if (before.inode != after.inode or before.size != after.size or before.mtime.nanoseconds != after.mtime.nanoseconds or before.ctime.nanoseconds != after.ctime.nanoseconds or !std.unicode.utf8ValidateSlice(bytes)) return error.WorkspaceChanged;
    return .{ .bytes = bytes, .permissions = before.permissions };
}
fn allowed(policy: Policy, path: []const u8) bool {
    for (policy.files.array.items) |file| if (std.mem.eql(u8, path, file.string)) return true;
    return false;
}
fn put(a: Allocator, v: *Value, key: []const u8, item: Value) !void {
    try v.object.put(a, key, item);
}
fn object() Value {
    return .{ .object = .empty };
}
fn str(s: []const u8) Value {
    return .{ .string = s };
}
fn captureFiles(a: Allocator, io: std.Io, root: std.Io.Dir, policy: Policy) !Value {
    var files: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    for (policy.files.array.items) |name| {
        var parent = try openParent(io, root, name.string);
        defer parent.dir.close(io);
        const source = try readSource(a, io, parent);
        var item = object();
        try put(a, &item, "path", name);
        try put(a, &item, "sha256", str(try a.dupe(u8, &code.hash(source.bytes))));
        try put(a, &item, "content", str(source.bytes));
        try files.array.append(item);
    }
    return files;
}
/// One position in the run. A map runs the same step id once per element, so an effect id
/// built from the step id alone would collide across elements: the path names the position.
fn position(request: runner.StepRequest) []const u8 {
    return if (request.path.len != 0) request.path else request.step_id;
}
/// Settles a journalled intent that never happened. If this write fails the receipt stays
/// `unknown`, which is the safe reading, and the caller still reports its own error.
fn notApplied(request: runner.StepRequest, effect: runner.Effect) void {
    var receipt = effect;
    receipt.state = .not_applied;
    request.journal.record(receipt) catch {};
}
/// Everything between a journalled edit and the file being replaced. An error from here
/// means the original is untouched: rename either replaces it or changes nothing.
fn replace(a: Allocator, io: std.Io, parent: Parent, temporary: []const u8, expected: []const u8, request: runner.StepRequest, authority: Authority) !void {
    try checkStop(io, request, authority);
    // Recheck immediately before replacing the original; simultaneous writes
    // by other actors still need external workspace coordination.
    const current = try readSource(a, io, parent);
    if (!std.mem.eql(u8, &code.hash(current.bytes), expected)) return error.WorkspaceChanged;
    try parent.dir.rename(temporary, parent.dir, parent.leaf, io);
}
/// Everything between a journalled command and its spawn.
fn beforeDispatch(io: std.Io, request: runner.StepRequest, authority: Authority, policy: Policy) !void {
    try checkStop(io, request, authority);
    var directory = try openWorkspace(io, policy);
    directory.close(io);
}
fn checkStop(io: std.Io, request: runner.StepRequest, authority: Authority) !void {
    if (request.cancel.load(.acquire)) return error.Cancelled;
    if (std.Io.Clock.awake.now(io).toMilliseconds() >= request.deadline_ms) return error.TimeLimit;
    try authority.checkFn(authority.context);
}
fn applyEdits(a: Allocator, io: std.Io, root: std.Io.Dir, policy: Policy, request: runner.StepRequest, authority: Authority) !void {
    const edits = try runner.get(request.input, "edits");
    if (edits != .array or edits.array.items.len > 16) return error.InvalidWorkspaceEdits;
    // Validate every requested path and baseline before the first side effect.
    for (edits.array.items, 0..) |edit, i| {
        try fields(edit, &.{ "path", "sha256", "content" });
        const path = try string(edit, "path");
        if (!allowed(policy, path)) return error.PermissionDenied;
        const content = try string(edit, "content");
        if (content.len > max_file_bytes) return error.OutputLimit;
        for (edits.array.items[0..i]) |prior| if (std.mem.eql(u8, path, try string(prior, "path"))) return error.InvalidWorkspaceEdits;
        var parent = try openParent(io, root, path);
        defer parent.dir.close(io);
        const source = try readSource(a, io, parent);
        if (!std.mem.eql(u8, &code.hash(source.bytes), try string(edit, "sha256"))) return error.WorkspaceChanged;
    }
    for (edits.array.items, 0..) |edit, i| {
        try checkStop(io, request, authority);
        const path = try string(edit, "path");
        var parent = try openParent(io, root, path);
        defer parent.dir.close(io);
        const source = try readSource(a, io, parent);
        if (!std.mem.eql(u8, &code.hash(source.bytes), try string(edit, "sha256"))) return error.WorkspaceChanged;
        const content = try string(edit, "content");
        var random: [16]u8 = undefined;
        std.Io.random(io, &random);
        const temporary = try std.fmt.allocPrint(a, ".fh-edit-{s}", .{std.fmt.bytesToHex(random, .lower)});
        var target = try parent.dir.createFile(io, temporary, .{ .exclusive = true, .permissions = source.permissions });
        defer target.close(io);
        defer parent.dir.deleteFile(io, temporary) catch {};
        try target.writeStreamingAll(io, content);
        try target.sync(io);
        var details = object();
        try put(a, &details, "path", str(path));
        try put(a, &details, "before_sha256", str(try string(edit, "sha256")));
        try put(a, &details, "after_sha256", str(try a.dupe(u8, &code.hash(content))));
        try put(a, &details, "step", str(position(request)));
        const id = try std.fmt.allocPrint(a, "workspace-edit:{s}:{d}:{d}", .{ position(request), request.iteration, i });
        const effect: runner.Effect = .{ .id = id, .kind = "workspace_edit", .state = .unknown, .details = details };
        try request.journal.record(effect);
        replace(a, io, parent, temporary, try string(edit, "sha256"), request, authority) catch |err| {
            notApplied(request, effect);
            return err;
        };
        // The file is replaced. A failed directory sync leaves its durability, and so the
        // receipt, genuinely unknown.
        if (metadata.syncDirectory(parent.dir.handle) != 0) return error.StoreSyncFailed;
        var receipt = effect;
        receipt.state = .applied;
        try request.journal.record(receipt);
    }
}
fn quote(a: Allocator, input: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.writeByte('\'');
    for (input) |c| if (c == '\'') try out.writer.writeAll("'\\''") else try out.writer.writeByte(c);
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}
const Capture = struct {
    allocator: Allocator,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    cap: usize,
    diagnostic_cap: usize,
    diagnostic_truncated: bool = false,
    stdout_seen: usize = 0,
    stdout_over: bool = false,
    fn chunk(raw: *anyopaque, _: ?types.ToolLifecycleId, stream: command.CommandOutputStream, bytes: []const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(raw));
        if (stream == .stdout) {
            self.stdout_seen +|= bytes.len;
            // Over the cap the command is left to finish, so its exit is known and its receipt
            // can be settled. The step then fails with the output limit: a cut result is never
            // returned as if it were whole.
            if (self.stdout_over or bytes.len > self.cap - self.stdout.items.len) {
                self.stdout_over = true;
                return;
            }
            try self.stdout.appendSlice(self.allocator, bytes);
        } else {
            const count = @min(bytes.len, self.diagnostic_cap - self.stderr.items.len);
            try self.stderr.appendSlice(self.allocator, bytes[0..count]);
            if (count != bytes.len) self.diagnostic_truncated = true;
        }
    }
};
pub fn execute(a: Allocator, io: std.Io, request: runner.StepRequest, pkg: *package.Package, binding: *bindings.Binding, authority: Authority) !runner.StepResult {
    const policy = try commandGrant(binding, io);
    const saved = try program(a, pkg, request.step_id, policy);
    try checkStop(io, request, authority);
    var root = try openWorkspace(io, policy);
    defer root.close(io);
    const operation_count: u32 = if (saved.apply) blk: {
        const edits = try runner.get(request.input, "edits");
        if (edits != .array or edits.array.items.len > 16) return error.InvalidWorkspaceEdits;
        break :blk @intCast(edits.array.items.len + 1);
    } else 1;
    if (operation_count > request.limits.max_operations) return error.OperationLimit;
    if (saved.apply) try applyEdits(a, io, root, policy, request, authority);
    const before = try captureFiles(a, io, root, policy);
    try checkStop(io, request, authority);
    const argv = policy.commands.object.get(saved.command_name).?;
    var shell: std.Io.Writer.Allocating = .init(a);
    defer shell.deinit();
    try shell.writer.writeAll("exec");
    for (argv.array.items) |arg| {
        try shell.writer.writeByte(' ');
        try shell.writer.writeAll(try quote(a, arg.string));
    }
    var details = object();
    try put(a, &details, "workspace", str(policy.workspace));
    try put(a, &details, "handle", str(policy.handle));
    try put(a, &details, "argv", argv);
    try put(a, &details, "package_digest", str(pkg.digest));
    try put(a, &details, "step", str(position(request)));
    const id = try std.fmt.allocPrint(a, "workspace-command:{s}:{d}", .{ position(request), request.iteration });
    const effect: runner.Effect = .{ .id = id, .kind = "workspace_command", .state = .unknown, .details = details };
    try request.journal.record(effect);
    // Nothing is spawned yet: a stop, a revoked grant or a replaced workspace here means the
    // command did not run. From the spawn until the child is reaped with a known exit, the
    // receipt stays `unknown`, because a killed or lost command may have done part of its work.
    beforeDispatch(io, request, authority, policy) catch |err| {
        notApplied(request, effect);
        return err;
    };
    var output: Capture = .{ .allocator = a, .cap = @min(request.limits.max_output_bytes / 2, 65536), .diagnostic_cap = @min(request.limits.max_diagnostic_bytes / 2, 16384) };
    const result = command.executeCommandInEnvironment(.{
        .max_command_output_bytes = 4096,
        .cancel_flag = @constCast(request.cancel),
        .timeout_ms = @intCast(@max(1, request.deadline_ms - std.Io.Clock.awake.now(io).toMilliseconds())),
        .accepted_output_chunk_ctx = &output,
        .on_accepted_output_chunk = Capture.chunk,
    }, a, shell.written(), policy.workspace, .{ .clean = "/bin/bash" }) catch |err| switch (err) {
        error.CancelledBeforeExecution => return error.Cancelled,
        error.TimeoutExpired => return error.TimeLimit,
        else => return err,
    };
    const status = result.command_result orelse return error.UncertainEffect;
    if (status.termination_indeterminate) return error.CleanupPending;
    if (result.cancelled) return error.Cancelled;
    if (status.timed_out) return error.TimeLimit;
    if (status.exit_code == null or status.output_incomplete) return error.UncertainEffect;
    // Reaped with a known exit: the command ran to its end, whatever it printed and whatever
    // stopped the run meanwhile.
    var receipt = effect;
    receipt.state = .applied;
    try request.journal.record(receipt);
    if (output.stdout_over) {
        var cut = object();
        try put(a, &cut, "exit_code", .{ .integer = status.exit_code.? });
        try put(a, &cut, "stdout_bytes", .{ .integer = @intCast(output.stdout_seen) });
        try put(a, &cut, "stdout_limit_bytes", .{ .integer = @intCast(output.cap) });
        try request.journal.record(.{ .id = try std.fmt.allocPrint(a, "workspace-output-limit:{s}:{d}", .{ position(request), request.iteration }), .kind = "workspace_command_output_limit", .state = .applied, .details = cut });
        return .{ .failure = error.OutputLimit, .operations = operation_count };
    }
    try checkStop(io, request, authority);
    var after_dispatch = try openWorkspace(io, policy);
    after_dispatch.close(io);
    if (!std.unicode.utf8ValidateSlice(output.stdout.items) or !std.unicode.utf8ValidateSlice(output.stderr.items)) return error.InvalidCodeResult;
    var value = object();
    try put(a, &value, "passed", .{ .bool = status.exit_code.? == 0 });
    try put(a, &value, "command", str(saved.command_name));
    try put(a, &value, "exit_code", .{ .integer = status.exit_code.? });
    try put(a, &value, "stdout", str(output.stdout.items));
    try put(a, &value, "stderr", str(output.stderr.items));
    try put(a, &value, "diagnostic_truncated", .{ .bool = output.diagnostic_truncated });
    const after = try captureFiles(a, io, root, policy);
    if (!schema.equal(before, after)) return error.WorkspaceChanged;
    try put(a, &value, "files", after);
    if (saved.fail_on_nonzero and status.exit_code.? != 0) {
        var diagnostic = object();
        try put(a, &diagnostic, "exit_code", .{ .integer = status.exit_code.? });
        try put(a, &diagnostic, "stderr", str(output.stderr.items));
        try request.journal.record(.{ .id = try std.fmt.allocPrint(a, "workspace-failure:{s}:{d}", .{ position(request), request.iteration }), .kind = "workspace_command_failure", .state = .applied, .details = diagnostic });
        return .{ .failure = error.WorkspaceCommandFailed, .operations = operation_count };
    }
    return .{ .output = value, .operations = operation_count };
}

test "native workspace saved program only selects registered commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]package.File{ .{ .path = "loop.json", .bytes = "{\"format\":\"loops/0.1\",\"name\":\"test\",\"version\":\"1\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"check\",\"kind\":\"code\",\"runtime\":\"fh-workspace/1\",\"file\":\"check.json\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/check/output\"}}" }, .{ .path = "check.json", .bytes = "{\"operation\":\"check\",\"command\":\"typecheck\"}" } };
    var pkg = try package.fromFiles(a, &files, "loop.json");
    defer pkg.deinit();
    var policy: Policy = .{ .handle = "test", .workspace = "/workspace", .files = .null, .commands = try schema.parse(a, "{}"), .dev = 1, .ino = 1 };
    try std.testing.expectError(error.PermissionDenied, program(a, pkg, "check", policy));
    policy.commands = try schema.parse(a, "{\"typecheck\":[\"/usr/bin/true\"]}");
    try std.testing.expect(!(try program(a, pkg, "check", policy)).apply);
}

const workspace_read = @import("workspace_read.zig");
/// One real workspace directory, a binding that grants it, and a journal that keeps what
/// was recorded. `disturb` runs inside the authority check at call `on_check`, which is how
/// a test gets between a journalled intent and the rename or spawn it guards.
const Bench = struct {
    arena: std.heap.ArenaAllocator,
    temporary: std.testing.TmpDir,
    root: []const u8 = "",
    workspace: []const u8 = "",
    binding: bindings.Binding = undefined,
    pkg: *package.Package = undefined,
    seen: std.ArrayList(Seen) = .empty,
    cancel: std.atomic.Value(bool) = .init(false),
    checks: usize = 0,
    fail_check: usize = 0,
    on_check: usize = 0,
    disturb: enum { none, rewrite_source, replace_workspace } = .none,
    ready: bool = false,
    const original = "before\n";
    const Seen = struct { id: []const u8, kind: []const u8, state: []const u8, details: []const u8 };
    fn init(self: *Bench, operation: []const u8, commands: []const u8, trusted: bool) !void {
        const io = std.testing.io;
        self.* = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .temporary = std.testing.tmpDir(.{}) };
        errdefer self.deinit();
        const a = self.arena.allocator();
        self.root = try self.temporary.dir.realPathFileAlloc(io, ".", a);
        self.workspace = try std.fs.path.join(a, &.{ self.root, "workspace" });
        try self.temporary.dir.createDir(io, "workspace", .fromMode(0o700));
        try self.temporary.dir.writeFile(io, .{ .sub_path = "workspace/source.txt", .data = original });
        var directory = try storage.openDirectory(io, self.workspace);
        defer directory.close(io);
        const stat = try metadata.fstat(directory.handle);
        const installation = try std.fmt.allocPrint(a, "{{\"version\":1,\"bindings\":{{\"workspace\":{{\"id\":\"workspace\",\"capabilities\":{{}},\"resources\":{{\"workspace\":\"grant\"}}}}}},\"resources\":{{\"grant\":{{\"kind\":\"workspace-runtime\",{s}\"workspace\":\"{s}\",\"dev\":{d},\"ino\":{d},\"commands\":{s},\"files\":[\"source.txt\"]}}}},\"runtimeProfiles\":{{\"fh-workspace/1\":{{\"resources\":[\"workspace\"]}}}}}}", .{ if (trusted) "\"trust\":\"trusted-host-commands\"," else "", self.workspace, stat.dev, stat.ino, commands });
        self.binding = try bindings.fromBytes(std.testing.allocator, installation, "workspace");
        errdefer self.binding.deinit();
        const files = try a.alloc(package.File, 2);
        files[0] = .{ .path = "loop.json", .bytes = "{\"format\":\"loops/0.1\",\"name\":\"bench\",\"version\":\"1\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"op\",\"kind\":\"code\",\"runtime\":\"fh-workspace/1\",\"file\":\"op.json\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/op/output\"}}" };
        files[1] = .{ .path = "op.json", .bytes = try std.fmt.allocPrint(a, "{{\"operation\":\"{s}\",\"command\":\"go\"}}", .{operation}) };
        self.pkg = try package.fromFiles(std.testing.allocator, files, "loop.json");
        self.ready = true;
    }
    fn deinit(self: *Bench) void {
        if (self.ready) {
            self.binding.deinit();
            self.pkg.deinit();
        }
        self.temporary.cleanup();
        self.arena.deinit();
    }
    fn record(raw: *anyopaque, effect: runner.Effect) !void {
        const self: *Bench = @ptrCast(@alignCast(raw));
        const a = self.arena.allocator();
        const details = if (effect.details) |value| try std.json.Stringify.valueAlloc(a, value, .{}) else "";
        for (self.seen.items) |*prior| if (std.mem.eql(u8, prior.id, effect.id)) {
            if (std.mem.eql(u8, prior.state, "applied") and effect.state != .applied) return error.ReceiptConflict;
            prior.state = @tagName(effect.state);
            return;
        };
        try self.seen.append(a, .{ .id = try a.dupe(u8, effect.id), .kind = try a.dupe(u8, effect.kind), .state = @tagName(effect.state), .details = details });
    }
    fn authorize(raw: *anyopaque) !void {
        const self: *Bench = @ptrCast(@alignCast(raw));
        const io = std.testing.io;
        self.checks += 1;
        if (self.checks == self.on_check) switch (self.disturb) {
            .none => {},
            .rewrite_source => try self.temporary.dir.writeFile(io, .{ .sub_path = "workspace/source.txt", .data = "someone else\n" }),
            .replace_workspace => {
                try self.temporary.dir.rename("workspace", self.temporary.dir, "moved", io);
                try self.temporary.dir.createDir(io, "workspace", .fromMode(0o700));
            },
        };
        if (self.checks == self.fail_check) return error.PermissionDenied;
    }
    fn run(self: *Bench, input: []const u8, path: []const u8, milliseconds: i64) !runner.StepResult {
        const a = self.arena.allocator();
        return execute(a, std.testing.io, .{ .run_id = "run_bench", .step_id = "op", .path = path, .iteration = 0, .definition = .null, .input = try schema.parse(a, input), .selection = .{}, .response_schema = .{ .bool = true }, .limits = .{}, .cancel = &self.cancel, .deadline_ms = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() + milliseconds, .journal = .{ .context = self, .recordFn = record } }, self.pkg, &self.binding, .{ .context = self, .checkFn = authorize });
    }
    fn edit(self: *Bench) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{{\"edits\":[{{\"path\":\"source.txt\",\"sha256\":\"{s}\",\"content\":\"after\\n\"}}]}}", .{&code.hash(original)});
    }
    fn state(self: *Bench, kind: []const u8) ?Seen {
        var found: ?Seen = null;
        for (self.seen.items) |item| if (std.mem.eql(u8, item.kind, kind)) {
            found = item;
        };
        return found;
    }
    fn source(self: *Bench, name: []const u8) ![]const u8 {
        return self.temporary.dir.readFileAlloc(std.testing.io, name, self.arena.allocator(), .limited(4096));
    }
};
const truthy = "{\"go\":[\"/usr/bin/true\"]}";

test "native workspace edit stopped or changed before its rename is recorded not applied" {
    // The third authority check is the one between the journalled edit and its rename.
    var stopped: Bench = undefined;
    try stopped.init("apply_check", truthy, true);
    defer stopped.deinit();
    stopped.fail_check = 3;
    try std.testing.expectError(error.PermissionDenied, stopped.run(try stopped.edit(), "", 20000));
    try std.testing.expectEqualStrings("not_applied", stopped.state("workspace_edit").?.state);
    try std.testing.expectEqualStrings(Bench.original, try stopped.source("workspace/source.txt"));
    try std.testing.expect(stopped.state("workspace_command") == null);

    var changed: Bench = undefined;
    try changed.init("apply_check", truthy, true);
    defer changed.deinit();
    changed.on_check = 3;
    changed.disturb = .rewrite_source;
    try std.testing.expectError(error.WorkspaceChanged, changed.run(try changed.edit(), "", 20000));
    try std.testing.expectEqualStrings("not_applied", changed.state("workspace_edit").?.state);
    try std.testing.expectEqualStrings("someone else\n", try changed.source("workspace/source.txt"));
}

test "native workspace command stopped before its spawn is recorded not applied" {
    const marking = "{\"go\":[\"/bin/sh\",\"-c\",\"echo ran > marker\"]}";
    // For a check operation the third authority check follows the journalled command.
    var stopped: Bench = undefined;
    try stopped.init("check", marking, true);
    defer stopped.deinit();
    stopped.fail_check = 3;
    try std.testing.expectError(error.PermissionDenied, stopped.run("{}", "", 20000));
    try std.testing.expectEqualStrings("not_applied", stopped.state("workspace_command").?.state);
    try std.testing.expectError(error.FileNotFound, stopped.source("workspace/marker"));

    var moved: Bench = undefined;
    try moved.init("check", marking, true);
    defer moved.deinit();
    moved.on_check = 3;
    moved.disturb = .replace_workspace;
    try std.testing.expectError(error.WorkspaceChanged, moved.run("{}", "", 20000));
    try std.testing.expectEqualStrings("not_applied", moved.state("workspace_command").?.state);
    try std.testing.expectError(error.FileNotFound, moved.source("moved/marker"));
    try std.testing.expectError(error.FileNotFound, moved.source("workspace/marker"));
}

test "native workspace command over the stdout cap is recorded applied and fails with the output limit" {
    var bench: Bench = undefined;
    try bench.init("check", "{\"go\":[\"/bin/sh\",\"-c\",\"/usr/bin/head -c 70000 /dev/zero | /usr/bin/tr '\\\\0' x; exit 3\"]}", true);
    defer bench.deinit();
    const result = try bench.run("{}", "", 20000);
    try std.testing.expectEqual(@as(?anyerror, error.OutputLimit), result.failure);
    try std.testing.expectEqualStrings("applied", bench.state("workspace_command").?.state);
    // The receipt says what was cut and what the command returned, so nothing is lost silently.
    const limit = bench.state("workspace_command_output_limit").?;
    try std.testing.expectEqualStrings("applied", limit.state);
    try std.testing.expect(std.mem.indexOf(u8, limit.details, "\"exit_code\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, limit.details, "\"stdout_bytes\":70000") != null);
    try std.testing.expect(std.mem.indexOf(u8, limit.details, "\"stdout_limit_bytes\":65536") != null);
}

test "native workspace command killed at its deadline stays unknown" {
    var bench: Bench = undefined;
    try bench.init("check", "{\"go\":[\"/bin/sleep\",\"5\"]}", true);
    defer bench.deinit();
    try std.testing.expectError(error.TimeLimit, bench.run("{}", "", 400));
    try std.testing.expectEqualStrings("unknown", bench.state("workspace_command").?.state);
}

test "native workspace effect ids follow the step path so map elements never collide" {
    var bench: Bench = undefined;
    try bench.init("apply_check", truthy, true);
    defer bench.deinit();
    _ = try bench.run(try bench.edit(), "each[0]/op", 20000);
    // The second element runs the same step id and iteration against the file as it now is.
    const again = try std.fmt.allocPrint(bench.arena.allocator(), "{{\"edits\":[{{\"path\":\"source.txt\",\"sha256\":\"{s}\",\"content\":\"last\\n\"}}]}}", .{&code.hash("after\n")});
    _ = try bench.run(again, "each[1]/op", 20000);
    try std.testing.expectEqual(@as(usize, 4), bench.seen.items.len);
    for (bench.seen.items) |item| try std.testing.expectEqualStrings("applied", item.state);
    try std.testing.expectEqualStrings("workspace-edit:each[0]/op:0:0", bench.seen.items[0].id);
    try std.testing.expectEqualStrings("workspace-command:each[1]/op:0", bench.seen.items[3].id);
    try std.testing.expectEqualStrings("last\n", try bench.source("workspace/source.txt"));
}

test "native workspace grant without commands is read-only and refuses a command step" {
    const io = std.testing.io;
    var bench: Bench = undefined;
    try bench.init("check", "{}", false);
    defer bench.deinit();
    // No host command is registered, so no host trust is asked for.
    _ = try configured(&bench.binding, io);
    _ = try workspace_read.configured(&bench.binding, io);
    try std.testing.expectError(error.WorkspaceReadOnlyGrant, preflight(&bench.binding, io, bench.pkg, "op"));
    try std.testing.expectError(error.WorkspaceReadOnlyGrant, bench.run("{}", "", 20000));
    try std.testing.expectEqual(@as(usize, 0), bench.seen.items.len);
    // Host commands still need the trust that setup records.
    var untrusted: Bench = undefined;
    try untrusted.init("check", truthy, false);
    defer untrusted.deinit();
    try std.testing.expectError(error.PermissionDenied, configured(&untrusted.binding, io));
}
