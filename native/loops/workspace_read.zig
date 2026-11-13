//! loops/0.3 `workspace_read`: list, search and read the files a registered
//! workspace grant already lets the runner transmit. Read only. The grant is the
//! installation's existing `workspace` resource; this file adds no second model.
const std = @import("std");
const metadata = @import("../metadata.zig");
const runner = @import("runner.zig");
const bindings = @import("bindings.zig");
const package = @import("package.zig");
const schema = @import("schema.zig");
const storage = @import("store.zig");
const Value = runner.Value;
const Allocator = std.mem.Allocator;

pub const capability = "workspace_read";
/// The logical resource name `fh setup workspace` registers on a binding.
pub const resource_name = "workspace";
pub const Authority = struct { context: *anyopaque, checkFn: *const fn (*anyopaque) anyerror!void };
/// `files` is the grant's exact allowlist. Nothing outside it is ever opened.
pub const Policy = struct { workspace: []const u8, files: []const Value, dev: u64, ino: u64 };

pub fn required(definition: Value) bool {
    const requires = if (definition == .object) definition.object.get("requires") orelse return false else return false;
    if (requires != .array) return false;
    for (requires.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, capability)) return true;
    return false;
}
fn field(value: Value, key: []const u8) !Value {
    return runner.get(value, key) catch error.InvalidWorkspacePolicy;
}
fn identity(value: Value, key: []const u8) !u64 {
    const n = try field(value, key);
    if (n != .integer or n.integer < 0) return error.InvalidWorkspacePolicy;
    return @intCast(n.integer);
}
/// Resolve the binding's workspace grant. A binding without one cannot run a
/// `workspace_read` step: the package's request is never its own authorization.
pub fn configured(binding: *bindings.Binding, io: std.Io) !Policy {
    const resource = binding.resource(resource_name) catch return error.WorkspaceSetupRequired;
    const value = resource.value;
    const kind = try field(value, "kind");
    if (kind != .string or !std.mem.eql(u8, kind.string, "workspace-runtime")) return error.PermissionDenied;
    const workspace = try field(value, "workspace");
    if (workspace != .string or !std.fs.path.isAbsolute(workspace.string) or std.mem.indexOfScalar(u8, workspace.string, 0) != null) return error.InvalidWorkspacePolicy;
    const files = try field(value, "files");
    if (files != .array) return error.InvalidWorkspacePolicy;
    for (files.array.items, 0..) |file, i| {
        if (file != .string) return error.InvalidWorkspacePolicy;
        package.localPath(file.string) catch return error.InvalidWorkspacePolicy;
        for (files.array.items[0..i]) |prior| if (std.mem.eql(u8, prior.string, file.string)) return error.InvalidWorkspacePolicy;
    }
    const policy: Policy = .{ .workspace = workspace.string, .files = files.array.items, .dev = try identity(value, "dev"), .ino = try identity(value, "ino") };
    var root = try openRoot(io, policy);
    root.close(io);
    return policy;
}
/// The granted directory itself, by the identity recorded at registration. A
/// replaced or re-pointed path is a different workspace, not this grant.
fn openRoot(io: std.Io, policy: Policy) !std.Io.Dir {
    var directory = storage.openDirectory(io, policy.workspace) catch return error.WorkspaceChanged;
    errdefer directory.close(io);
    const stat = metadata.fstat(directory.handle) catch return error.WorkspaceChanged;
    if (@as(u64, @intCast(stat.dev)) != policy.dev or @as(u64, @intCast(stat.ino)) != policy.ino) return error.WorkspaceChanged;
    return directory;
}
/// What the model is told when a read is its own mistake, so it can correct itself. Every
/// other error (cancellation, deadline, revoked authority, a changed workspace, an operation
/// or argument name that does not exist) fails the step.
pub fn answer(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.WorkspacePathRefused => "That path is not a file this run may read. Use a path exactly as list_files returns it.",
        error.WorkspaceFileMissing => "That file does not exist in the workspace.",
        error.WorkspaceFileNotText => "That file is not UTF-8 text, so it cannot be returned.",
        error.WorkspaceFileChanged => "That file changed while it was being read. Read it again.",
        error.WorkspaceArgumentRefused => "An argument is missing or not usable. path and query must be text that is not empty; offset and limit must be whole numbers, zero or more. Correct it and call again.",
        else => null,
    };
}
fn str(value: []const u8) Value {
    return .{ .string = value };
}
fn object() Value {
    return .{ .object = .empty };
}
fn put(a: Allocator, value: *Value, key: []const u8, item: Value) !void {
    try value.object.put(a, key, item);
}
fn count(n: usize) Value {
    return .{ .integer = @intCast(n) };
}
fn only(operation: Value, allowed: []const []const u8) !void {
    if (operation != .object) return error.InvalidWorkspaceOperation;
    for (operation.object.keys()) |key| {
        var found = false;
        for (allowed) |name| if (std.mem.eql(u8, name, key)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidWorkspaceOperation;
    }
}
fn optionalText(operation: Value, key: []const u8) !?[]const u8 {
    const value = operation.object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return error.WorkspaceArgumentRefused;
    return value.string;
}
fn optionalCount(operation: Value, key: []const u8) !?usize {
    const value = operation.object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return error.WorkspaceArgumentRefused;
    return std.math.cast(usize, value.integer) orelse error.WorkspaceArgumentRefused;
}
fn lineEnd(bytes: []const u8, start: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |i| i + 1 else bytes.len;
}

pub const Resource = struct {
    io: std.Io,
    policy: Policy,
    authority: Authority,

    fn granted(self: *const Resource, path: []const u8) bool {
        for (self.policy.files) |file| if (std.mem.eql(u8, file.string, path)) return true;
        return false;
    }
    /// The one way a file is opened. A path must be a plain relative path, be on
    /// the grant's list, and reach a regular file without crossing any symlink.
    pub fn open(self: *const Resource, root: std.Io.Dir, path: []const u8) !std.Io.File {
        package.localPath(path) catch return error.WorkspacePathRefused;
        if (!self.granted(path)) return error.WorkspacePathRefused;
        var directory = try root.openDir(self.io, ".", .{ .follow_symlinks = false });
        defer directory.close(self.io);
        var parts = std.mem.splitScalar(u8, path, '/');
        var leaf = parts.next().?;
        while (parts.next()) |next| {
            const child = directory.openDir(self.io, leaf, .{ .follow_symlinks = false }) catch |err| return refusal(err);
            directory.close(self.io);
            directory = child;
            leaf = next;
        }
        // Look before opening: a FIFO or device under a granted name must not block or be read.
        const link = directory.statFile(self.io, leaf, .{ .follow_symlinks = false }) catch |err| return refusal(err);
        if (link.kind != .file) return error.WorkspacePathRefused;
        return self.openSame(directory, leaf, link.inode);
    }
    /// Opens `leaf` only if it is still the regular file that was looked at. The open never
    /// waits: a name swapped for a FIFO after the look returns at once and is refused here,
    /// where a blocking open would hang past the step's deadline for want of a writer.
    fn openSame(self: *const Resource, directory: std.Io.Dir, leaf: []const u8, inode: std.Io.File.INode) !std.Io.File {
        const fd = std.posix.openat(directory.handle, leaf, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0) catch |err| return refusal(err);
        var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        errdefer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file or stat.inode != inode) return error.WorkspacePathRefused;
        return file;
    }
    fn refusal(err: anyerror) anyerror {
        return switch (err) {
            error.FileNotFound => error.WorkspaceFileMissing,
            error.SymLinkLoop, error.NotDir, error.IsDir => error.WorkspacePathRefused,
            else => err,
        };
    }
    /// The whole file. Nothing is cut here; a result too large to hand the
    /// model is refused loudly by the caller, never shortened.
    fn content(self: *const Resource, a: Allocator, root: std.Io.Dir, path: []const u8) ![]const u8 {
        var file = try self.open(root, path);
        defer file.close(self.io);
        const before = try file.stat(self.io);
        const bytes = try a.alloc(u8, std.math.cast(usize, before.size) orelse return error.OutOfMemory);
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.WorkspaceFileChanged;
        const after = try file.stat(self.io);
        if (after.size != before.size or after.mtime.nanoseconds != before.mtime.nanoseconds) return error.WorkspaceFileChanged;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.WorkspaceFileNotText;
        return bytes;
    }
    fn stop(self: *const Resource, request: runner.StepRequest) !void {
        if (request.cancel.load(.acquire)) return error.Cancelled;
        if (std.Io.Clock.awake.now(self.io).toMilliseconds() >= request.deadline_ms) return error.TimeLimit;
    }
    fn list(self: *const Resource, a: Allocator, request: runner.StepRequest, root: std.Io.Dir, operation: Value) !Value {
        try only(operation, &.{"op"});
        var files: Value = .{ .array = std.array_list.Managed(Value).init(a) };
        for (self.policy.files) |granted_file| {
            try self.stop(request);
            var entry = object();
            try put(a, &entry, "path", granted_file);
            if (self.open(root, granted_file.string)) |opened| {
                var file = opened;
                defer file.close(self.io);
                try put(a, &entry, "bytes", .{ .integer = @intCast((try file.stat(self.io)).size) });
            } else |err| try put(a, &entry, "unavailable", str(answer(err) orelse return err));
            try files.array.append(entry);
        }
        var result = object();
        try put(a, &result, "files", files);
        return result;
    }
    fn read(self: *const Resource, a: Allocator, root: std.Io.Dir, operation: Value) !Value {
        try only(operation, &.{ "op", "path", "offset", "limit" });
        const path = try optionalText(operation, "path") orelse return error.WorkspaceArgumentRefused;
        const offset = try optionalCount(operation, "offset") orelse 0;
        const limit = try optionalCount(operation, "limit");
        const bytes = try self.content(a, root, path);
        var total: usize = std.mem.count(u8, bytes, "\n");
        if (bytes.len != 0 and bytes[bytes.len - 1] != '\n') total += 1;
        var start: usize = 0;
        var skipped: usize = 0;
        while (skipped < offset and start < bytes.len) : (skipped += 1) start = lineEnd(bytes, start);
        var end = if (limit == null) bytes.len else start;
        var taken: usize = if (limit == null) total - skipped else 0;
        if (limit) |wanted| while (taken < wanted and end < bytes.len) : (taken += 1) {
            end = lineEnd(bytes, end);
        };
        var result = object();
        try put(a, &result, "path", str(path));
        try put(a, &result, "bytes", count(bytes.len));
        try put(a, &result, "total_lines", count(total));
        try put(a, &result, "offset", count(skipped));
        try put(a, &result, "lines", count(taken));
        try put(a, &result, "content", str(bytes[start..end]));
        return result;
    }
    fn search(self: *const Resource, a: Allocator, request: runner.StepRequest, root: std.Io.Dir, operation: Value) !Value {
        try only(operation, &.{ "op", "query", "path" });
        const query = try optionalText(operation, "query") orelse return error.WorkspaceArgumentRefused;
        const single = try optionalText(operation, "path");
        if (single) |path| if (!self.granted(path)) return error.WorkspacePathRefused;
        var matches: Value = .{ .array = std.array_list.Managed(Value).init(a) };
        var skipped: Value = .{ .array = std.array_list.Managed(Value).init(a) };
        for (self.policy.files) |granted_file| {
            if (single) |path| if (!std.mem.eql(u8, path, granted_file.string)) continue;
            try self.stop(request);
            const bytes = self.content(a, root, granted_file.string) catch |err| {
                var entry = object();
                try put(a, &entry, "path", granted_file);
                try put(a, &entry, "reason", str(answer(err) orelse return err));
                try skipped.array.append(entry);
                continue;
            };
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            var number: usize = 0;
            while (lines.next()) |line| {
                number += 1;
                if (std.mem.indexOf(u8, line, query) == null) continue;
                var entry = object();
                try put(a, &entry, "path", granted_file);
                try put(a, &entry, "line", count(number));
                try put(a, &entry, "text", str(line));
                try matches.array.append(entry);
            }
        }
        var result = object();
        try put(a, &result, "matches", matches);
        try put(a, &result, "skipped", skipped);
        return result;
    }
    /// `runner.CapabilityPort` entry. `operation` is `{op:"list"}`,
    /// `{op:"search",query,path?}` or `{op:"read",path,offset?,limit?}`. There is
    /// no operation that writes, creates, deletes or executes.
    pub fn call(raw: *anyopaque, a: Allocator, request: runner.StepRequest, operation: Value) !Value {
        const self: *Resource = @ptrCast(@alignCast(raw));
        try self.stop(request);
        try self.authority.checkFn(self.authority.context);
        if (operation != .object) return error.InvalidWorkspaceOperation;
        const op = operation.object.get("op") orelse return error.InvalidWorkspaceOperation;
        if (op != .string) return error.InvalidWorkspaceOperation;
        var root = try openRoot(self.io, self.policy);
        defer root.close(self.io);
        const result = if (std.mem.eql(u8, op.string, "list")) self.list(a, request, root, operation) else if (std.mem.eql(u8, op.string, "read")) self.read(a, root, operation) else if (std.mem.eql(u8, op.string, "search")) self.search(a, request, root, operation) else return error.InvalidWorkspaceOperation;
        return result catch |err| {
            var refused = object();
            try put(a, &refused, "error", str(answer(err) orelse return err));
            return refused;
        };
    }
};

/// Test workspace shared with the agent host tests.
pub const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    outside: std.testing.TmpDir,
    resource: Resource = undefined,
    cancel: std.atomic.Value(bool) = .init(false),
    revoked: bool = false,
    fn allow(raw: *anyopaque) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        if (self.revoked) return error.PermissionDenied;
    }
    fn journal(_: *anyopaque, _: runner.Effect) !void {}
    /// A workspace with two granted files, a granted name that is a symlink out
    /// of the root, a granted path under a symlinked directory, and an ungranted file.
    pub fn init(self: *Fixture) !void {
        const io = std.testing.io;
        self.* = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .tmp = std.testing.tmpDir(.{}), .outside = std.testing.tmpDir(.{}) };
        const a = self.arena.allocator();
        try self.outside.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "outside secret\n" });
        const outside = try self.outside.dir.realPathFileAlloc(io, ".", a);
        try self.tmp.dir.createDirPath(io, "src");
        try self.tmp.dir.writeFile(io, .{ .sub_path = "src/a.txt", .data = "alpha\nneedle one\nomega\n" });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "notes.md", .data = "no match here" });
        try self.tmp.dir.writeFile(io, .{ .sub_path = "private.txt", .data = "ungranted needle\n" });
        try self.tmp.dir.symLink(io, try std.fs.path.join(a, &.{ outside, "secret.txt" }), "link.txt", .{});
        try self.tmp.dir.symLink(io, outside, "linked", .{ .is_directory = true });
        const root = try self.tmp.dir.realPathFileAlloc(io, ".", a);
        const stat = try metadata.fstat(self.tmp.dir.handle);
        const installation = try std.fmt.allocPrint(a, "{{\"version\":1,\"bindings\":{{\"workspace\":{{\"id\":\"workspace\",\"capabilities\":{{}},\"resources\":{{\"workspace\":\"workspace-workspace\"}}}}}},\"resources\":{{\"workspace-workspace\":{{\"kind\":\"workspace-runtime\",\"trust\":\"trusted-host-commands\",\"workspace\":{f},\"dev\":{d},\"ino\":{d},\"commands\":{{}},\"files\":[\"src/a.txt\",\"notes.md\",\"link.txt\",\"linked/secret.txt\",\"gone.txt\"]}}}},\"runtimeProfiles\":{{}}}}", .{ std.json.fmt(root, .{}), stat.dev, stat.ino });
        var binding = try bindings.fromBytes(a, installation, "workspace");
        self.resource = .{ .io = io, .policy = try configured(&binding, io), .authority = .{ .context = self, .checkFn = allow } };
    }
    pub fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.outside.cleanup();
        self.arena.deinit();
    }
    pub fn request(self: *Fixture) runner.StepRequest {
        return .{ .run_id = "workspace-test", .step_id = "review", .iteration = 0, .definition = .null, .input = .null, .selection = .{}, .response_schema = .{ .bool = true }, .limits = .{}, .cancel = &self.cancel, .deadline_ms = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() + 10000, .journal = .{ .context = self, .recordFn = journal } };
    }
    fn run(self: *Fixture, operation: []const u8) !Value {
        const a = self.arena.allocator();
        return Resource.call(&self.resource, a, self.request(), try schema.parse(a, operation));
    }
    fn refused(self: *Fixture, operation: []const u8) !void {
        const result = try self.run(operation);
        try std.testing.expectEqual(@as(usize, 1), result.object.count());
        try std.testing.expectEqualStrings(answer(error.WorkspacePathRefused).?, result.object.get("error").?.string);
    }
};

test "native workspace_read preflight rejects a binding without a workspace grant" {
    const io = std.testing.io;
    const manifest = "{\"steps\":[{\"id\":\"review\",\"kind\":\"infer\",\"requires\":[\"workspace_read\"],\"instructions\":\"Review\"}]}";
    var local = try bindings.fromBytes(std.testing.allocator, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{},\"capabilities\":{\"workspace_read\":\"self-declared\"}}},\"resources\":{},\"runtimeProfiles\":{}}", "local");
    defer local.deinit();
    // The declaration is a request. Even a capability entry naming it grants nothing without the resource.
    try std.testing.expectError(error.WorkspaceSetupRequired, local.assertDeclarations(try schema.parse(local.arena.allocator(), manifest), false));
    try std.testing.expectError(error.WorkspaceSetupRequired, configured(&local, io));
    // A code step cannot ask for it, and a registered resource of another kind is not a workspace grant.
    try std.testing.expectError(error.UnsupportedInferenceCapability, local.assertDeclarations(try schema.parse(local.arena.allocator(), "{\"steps\":[{\"id\":\"c\",\"kind\":\"code\",\"runtime\":\"python3\",\"requires\":[\"workspace_read\"]}]}"), false));
    var other = try bindings.fromBytes(std.testing.allocator, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{\"workspace\":\"dir\"},\"capabilities\":{}}},\"resources\":{\"dir\":{\"kind\":\"directory\",\"mode\":\"ro\",\"path\":\"/\"}},\"runtimeProfiles\":{}}", "local");
    defer other.deinit();
    try std.testing.expectError(error.PermissionDenied, configured(&other, io));
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const a = fixture.arena.allocator();
    // The same declaration passes once the binding carries the grant, and a moved root is a different workspace.
    const root = try fixture.tmp.dir.realPathFileAlloc(io, ".", a);
    const stat = try metadata.fstat(fixture.tmp.dir.handle);
    for ([_]u64{ 0, 1 }) |drift| {
        const bytes = try std.fmt.allocPrint(a, "{{\"version\":1,\"bindings\":{{\"workspace\":{{\"id\":\"workspace\",\"capabilities\":{{}},\"resources\":{{\"workspace\":\"w\"}}}}}},\"resources\":{{\"w\":{{\"kind\":\"workspace-runtime\",\"workspace\":{f},\"dev\":{d},\"ino\":{d},\"files\":[\"notes.md\"]}}}},\"runtimeProfiles\":{{}}}}", .{ std.json.fmt(root, .{}), stat.dev, @as(u64, @intCast(stat.ino)) + drift });
        var bound = try bindings.fromBytes(a, bytes, "workspace");
        try bound.assertDeclarations(try schema.parse(a, manifest), false);
        if (drift == 0) _ = try configured(&bound, io) else try std.testing.expectError(error.WorkspaceChanged, configured(&bound, io));
    }
}

test "native workspace_read refuses dotdot, absolute, ungranted and symlinked paths" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const a = fixture.arena.allocator();
    const io = std.testing.io;
    const outside = try fixture.outside.dir.realPathFileAlloc(io, ".", a);
    // Dotdot out of the root, and an absolute path to the same outside file.
    try fixture.refused("{\"op\":\"read\",\"path\":\"../secret.txt\"}");
    try fixture.refused("{\"op\":\"read\",\"path\":\"src/../../secret.txt\"}");
    try fixture.refused(try std.fmt.allocPrint(a, "{{\"op\":\"read\",\"path\":{f}}}", .{std.json.fmt(try std.fs.path.join(a, &.{ outside, "secret.txt" }), .{})}));
    try fixture.refused("{\"op\":\"read\",\"path\":\"/etc/hosts\"}");
    // A real file inside the root that the grant does not list.
    try fixture.refused("{\"op\":\"read\",\"path\":\"private.txt\"}");
    try fixture.refused("{\"op\":\"search\",\"query\":\"needle\",\"path\":\"private.txt\"}");
    // Granted names that are a symlink out of the root, as the file and as a parent directory.
    try fixture.refused("{\"op\":\"read\",\"path\":\"link.txt\"}");
    try fixture.refused("{\"op\":\"read\",\"path\":\"linked/secret.txt\"}");
    var root = try openRoot(io, fixture.resource.policy);
    defer root.close(io);
    for ([_][]const u8{ "../secret.txt", "/etc/hosts", "private.txt", "link.txt", "linked/secret.txt" }) |path| try std.testing.expectError(error.WorkspacePathRefused, fixture.resource.open(root, path));
    // Listing and searching never surface the outside file's content or the ungranted file.
    for ([_][]const u8{ "{\"op\":\"list\"}", "{\"op\":\"search\",\"query\":\"secret\"}", "{\"op\":\"search\",\"query\":\"needle\"}" }) |operation| {
        const bytes = try std.json.Stringify.valueAlloc(a, try fixture.run(operation), .{});
        try std.testing.expect(std.mem.indexOf(u8, bytes, "outside secret") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "ungranted") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "private.txt") == null);
    }
}

test "native workspace_read lists, searches and reads granted files without truncation or writes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const a = fixture.arena.allocator();
    const io = std.testing.io;
    const listed = (try fixture.run("{\"op\":\"list\"}")).object.get("files").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), listed.len);
    try std.testing.expectEqualStrings("src/a.txt", listed[0].object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 23), listed[0].object.get("bytes").?.integer);
    try std.testing.expectEqualStrings(answer(error.WorkspacePathRefused).?, listed[2].object.get("unavailable").?.string);
    try std.testing.expectEqualStrings(answer(error.WorkspaceFileMissing).?, listed[4].object.get("unavailable").?.string);
    const found = try fixture.run("{\"op\":\"search\",\"query\":\"needle\"}");
    const matches = found.object.get("matches").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("src/a.txt", matches[0].object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 2), matches[0].object.get("line").?.integer);
    try std.testing.expectEqualStrings("needle one", matches[0].object.get("text").?.string);
    try std.testing.expectEqual(@as(usize, 3), found.object.get("skipped").?.array.items.len);
    const whole = try fixture.run("{\"op\":\"read\",\"path\":\"src/a.txt\"}");
    try std.testing.expectEqualStrings("alpha\nneedle one\nomega\n", whole.object.get("content").?.string);
    try std.testing.expectEqual(@as(i64, 3), whole.object.get("total_lines").?.integer);
    const ranged = try fixture.run("{\"op\":\"read\",\"path\":\"src/a.txt\",\"offset\":1,\"limit\":1}");
    try std.testing.expectEqualStrings("needle one\n", ranged.object.get("content").?.string);
    try std.testing.expectEqual(@as(i64, 1), ranged.object.get("lines").?.integer);
    try std.testing.expectEqual(@as(i64, 3), ranged.object.get("total_lines").?.integer);
    // A file far larger than any chat tool-result default comes back whole, byte for byte.
    const large = try a.alloc(u8, 300000);
    for (large, 0..) |*byte, i| byte.* = if (i % 80 == 79) '\n' else 'a' + @as(u8, @intCast(i % 26));
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "notes.md", .data = large });
    try std.testing.expectEqualStrings(large, (try fixture.run("{\"op\":\"read\",\"path\":\"notes.md\"}")).object.get("content").?.string);
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = "notes.md", .data = "\xff\xfe binary" });
    try std.testing.expectEqualStrings(answer(error.WorkspaceFileNotText).?, (try fixture.run("{\"op\":\"read\",\"path\":\"notes.md\"}")).object.get("error").?.string);
    // No write, delete or execute operation exists, and unknown fields are not ignored.
    for ([_][]const u8{ "{\"op\":\"write\",\"path\":\"src/a.txt\",\"content\":\"x\"}", "{\"op\":\"delete\",\"path\":\"src/a.txt\"}", "{\"op\":\"exec\",\"command\":\"id\"}", "{\"op\":\"read\",\"path\":\"src/a.txt\",\"content\":\"x\"}", "{\"path\":\"src/a.txt\"}" }) |operation| try std.testing.expectError(error.InvalidWorkspaceOperation, fixture.run(operation));
    var check = try fixture.tmp.dir.openFile(io, "src/a.txt", .{});
    defer check.close(io);
    try std.testing.expectEqual(@as(u64, 23), (try check.stat(io)).size);
    // Cancellation and a revoked binding stop a read; they are never an answer for the model.
    fixture.revoked = true;
    try std.testing.expectError(error.PermissionDenied, fixture.run("{\"op\":\"list\"}"));
    fixture.revoked = false;
    fixture.cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, fixture.run("{\"op\":\"list\"}"));
}

test "native workspace_read hands a bad argument back to the model and opens files without blocking" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for ([_][]const u8{ "{\"op\":\"read\",\"path\":\"src/a.txt\",\"offset\":-1}", "{\"op\":\"read\",\"path\":\"src/a.txt\",\"limit\":-3}", "{\"op\":\"search\",\"query\":\"\"}", "{\"op\":\"search\"}", "{\"op\":\"read\",\"path\":\"\"}", "{\"op\":\"read\",\"path\":\"src/a.txt\",\"offset\":\"2\"}" }) |operation| {
        const result = try fixture.run(operation);
        try std.testing.expect(result.object.get("error").?.string.len != 0);
    }
    var root = try openRoot(std.testing.io, fixture.resource.policy);
    defer root.close(std.testing.io);
    var file = try fixture.resource.open(root, "src/a.txt");
    defer file.close(std.testing.io);
    const flags = std.c.fcntl(file.handle, std.c.F.GETFL);
    try std.testing.expect(flags >= 0);
    try std.testing.expect(@as(std.c.O, @bitCast(@as(u32, @intCast(flags)))).NONBLOCK);
    // A granted name that became a FIFO after it was looked at: with no writer a blocking open
    // would never return. This one returns and refuses.
    const mkfifoat = @extern(*const fn (c_int, [*:0]const u8, std.c.mode_t) callconv(.c) c_int, .{ .name = "mkfifoat" });
    try std.testing.expectEqual(@as(c_int, 0), mkfifoat(root.handle, "pipe", 0o600));
    const pipe = try root.statFile(std.testing.io, "pipe", .{ .follow_symlinks = false });
    try std.testing.expectError(error.WorkspacePathRefused, fixture.resource.openSame(root, "pipe", pipe.inode));
}

test "native workspace_read refuses a directory replaced at the granted spelling" {
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const a = fixture.arena.allocator();
    try fixture.tmp.dir.createDir(io, "granted", .fromMode(0o700));
    const original = try fixture.tmp.dir.openDir(io, "granted", .{});
    defer original.close(io);
    const original_metadata = try metadata.fstat(original.handle);
    fixture.resource.policy = .{ .workspace = try std.fs.path.join(a, &.{ try fixture.tmp.dir.realPathFileAlloc(io, ".", a), "granted" }), .files = &.{}, .dev = @intCast(original_metadata.dev), .ino = @intCast(original_metadata.ino) };
    var opened = try openRoot(io, fixture.resource.policy);
    opened.close(io);
    try fixture.tmp.dir.rename("granted", fixture.tmp.dir, "moved-grant", io);
    try fixture.tmp.dir.createDir(io, "granted", .fromMode(0o700));
    try std.testing.expectError(error.WorkspaceChanged, fixture.run("{\"op\":\"list\"}"));
}
