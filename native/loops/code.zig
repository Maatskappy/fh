//! Retained package code only (Python scripts, Node ES modules), through an explicitly installed isolated runtime.
const std = @import("std");
const metadata = @import("../metadata.zig");
const docker = @import("docker.zig");
const runner = @import("runner.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
pub const JournalEffect = runner.Effect;
pub const File = struct { path: []const u8, bytes: []const u8, digest: []const u8 = "" };
pub const Grant = struct { handle: []const u8, source: []const u8, target: []const u8, read_only: bool = true, dev: u64, ino: u64 };
pub const memory_limit = 128 * 1048576;
pub const Runtime = enum { python3, node };
pub const Config = struct { socket_path: []const u8, staging_root: []const u8, image: []const u8, python: []const u8 = "/usr/bin/python3", runtime: Runtime = .python3, node: []const u8 = "/usr/local/bin/node", runtime_handle: []const u8, policy_digest: []const u8 };
/// The loops `runtime: "node"` calling convention: stdin JSON in, one JSON value out.
pub const node_shim_source = @embedFile("node_shim.mjs");
/// Node's arguments after the interpreter path, the same for the container and fixture runs.
pub fn nodeArguments(root: []const u8, entry: []const u8) [6][]const u8 {
    return .{ "--input-type=module", "-e", node_shim_source, "--", root, entry };
}
/// One fixed interpreter path per runtime; an installation cannot point at another binary.
fn interpreter(config: Config) ![]const u8 {
    const path, const fixed = switch (config.runtime) {
        .python3 => .{ config.python, "/usr/bin/python3" },
        .node => .{ config.node, "/usr/local/bin/node" },
    };
    if (!std.mem.eql(u8, path, fixed)) return error.RuntimeUnsupported;
    return path;
}
/// Python 3.10 or later. Node 22.15 or later, or 23.5 or later on 23: the releases
/// with module.registerHooks, which the shim's import check uses. That check is a contract
/// check on imports; the container is the security boundary.
pub fn supportedVersion(runtime: Runtime, version: [3]u32) bool {
    return switch (runtime) {
        .python3 => version[0] == 3 and version[1] >= 10,
        .node => version[0] > 23 or (version[0] == 23 and version[1] >= 5) or (version[0] == 22 and version[1] >= 15),
    };
}
pub const Authority = struct { context: *anyopaque, checkFn: *const fn (*anyopaque) anyerror!void };
pub const CodeRequest = struct { step: runner.StepRequest, files: []const File, entry: []const u8, config: Config, owner_token: []const u8, epoch: u64 = 1, package_digest: []const u8, bound_handles: []const []const u8, grants: []const Grant = &.{}, authority: ?Authority = null };
pub fn hash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
fn object() Value {
    return .{ .object = std.json.ObjectMap{} };
}
fn string(bytes: []const u8) Value {
    return .{ .string = bytes };
}
fn array(allocator: Allocator) Value {
    return .{ .array = std.array_list.Managed(Value).init(allocator) };
}
fn put(allocator: Allocator, value: *Value, key: []const u8, item: Value) !void {
    try value.object.put(allocator, key, item);
}
fn get(value: Value, key: []const u8) !Value {
    return if (value == .object) value.object.get(key) orelse error.DockerProtocol else error.DockerProtocol;
}
fn text(value: Value) ![]const u8 {
    return if (value == .string) value.string else error.DockerProtocol;
}
fn hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    return true;
}
fn safeHandle(value: []const u8) bool {
    if (value.len == 0 or value.len > 1024) return false;
    for (value) |c| if (c < 32 or c == 127 or c == ',') return false;
    return true;
}
pub fn relative(path: []const u8) !void {
    if (path.len == 0 or path.len > 1024 or path[0] == '/') return error.InvalidCodePath;
    for (path) |c| if (c < 32 or c == 127 or c == '\\') return error.InvalidCodePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidCodePath;
}
fn equal(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |x, y| if (!equal(x, y)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!equal(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}
pub fn parse(allocator: Allocator, bytes: []const u8, cap: usize) !Value {
    if (bytes.len > cap or !std.unicode.utf8ValidateSlice(bytes)) return error.InvalidCodeResult;
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (bytes) |c| {
        if (quoted) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') quoted = false;
            continue;
        }
        if (c == '"') {
            quoted = true;
            continue;
        }
        if (c == '{' or c == '[') {
            depth += 1;
            if (depth > 128) return error.InvalidCodeResult;
        }
        if (c == '}' or c == ']') {
            if (depth == 0) return error.InvalidCodeResult;
            depth -= 1;
        }
    }
    const value = std.json.parseFromSliceLeaky(Value, allocator, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error", .max_value_len = cap }) catch return error.InvalidCodeResult;
    try finite(value);
    return value;
}
fn finite(value: Value) !void {
    switch (value) {
        .float => if (!std.math.isFinite(value.float)) return error.InvalidCodeResult,
        .number_string => if (!std.math.isFinite(std.fmt.parseFloat(f64, value.number_string) catch return error.InvalidCodeResult)) return error.InvalidCodeResult,
        .array => for (value.array.items) |item| try finite(item),
        .object => {
            var iterator = value.object.iterator();
            while (iterator.next()) |entry| try finite(entry.value_ptr.*);
        },
        else => {},
    }
}
fn contains(handles: []const []const u8, handle: []const u8) bool {
    for (handles) |item| if (std.mem.eql(u8, item, handle)) return true;
    return false;
}
fn canonical(allocator: Allocator, io: std.Io, path: []const u8) !std.Io.Dir {
    if (path.len == 0 or path[0] != '/' or !safeHandle(path)) return error.PermissionDenied;
    // `iterate` makes this a real read descriptor on Linux. Without it Zig opens O_PATH,
    // which the kernel refuses fchmod on; staging must not depend on libc working around that.
    var directory = try std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false, .iterate = true });
    errdefer directory.close(io);
    const actual = try directory.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, path)) return error.PermissionDenied;
    return directory;
}
fn checkGrants(allocator: Allocator, io: std.Io, request: CodeRequest) !void {
    if (request.grants.len > 16) return error.PermissionDenied;
    for (request.grants, 0..) |grant, index| {
        if (!grant.read_only) return error.ResourceTrackingRequired;
        if (!safeHandle(grant.handle) or !contains(request.bound_handles, grant.handle) or !std.mem.startsWith(u8, grant.target, "/grants/") or grant.target.len > 72) return error.PermissionDenied;
        const leaf = grant.target[8..];
        if (leaf.len == 0 or leaf.len > 64) return error.PermissionDenied;
        for (leaf) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.PermissionDenied;
        for (request.grants[0..index]) |prior| if (std.mem.eql(u8, prior.handle, grant.handle) or std.mem.eql(u8, prior.target, grant.target)) return error.PermissionDenied;
        for ([_][]const u8{ "/etc", "/var", "/private/var", "/proc", "/sys", "/dev", "/System", "/Library" }) |prefix| if (std.mem.eql(u8, grant.source, prefix) or (std.mem.startsWith(u8, grant.source, prefix) and grant.source.len > prefix.len and grant.source[prefix.len] == '/')) return error.PermissionDenied;
        var parts = std.mem.tokenizeScalar(u8, grant.source, '/');
        var components: usize = 0;
        while (parts.next()) |part| {
            components += 1;
            for ([_][]const u8{ ".docker", ".colima", ".aws", ".ssh", ".codex", ".config", ".agents" }) |blocked| if (std.mem.eql(u8, part, blocked)) return error.PermissionDenied;
        }
        if (components == 0 or ((std.mem.startsWith(u8, grant.source, "/Users/") or std.mem.startsWith(u8, grant.source, "/home/")) and components <= 2) or std.mem.eql(u8, grant.source, "/Users") or std.mem.eql(u8, grant.source, "/home")) return error.PermissionDenied;
        var directory = try canonical(allocator, io, grant.source);
        defer directory.close(io);
        const stat = metadata.fstat(directory.handle) catch return error.PermissionDenied;
        if (@as(u64, @intCast(stat.dev)) != grant.dev or stat.ino != grant.ino) return error.PermissionDenied;
    }
}
fn validate(request: CodeRequest) !void {
    try relative(request.entry);
    _ = interpreter(request.config) catch return error.PermissionDenied;
    if (!safeHandle(request.owner_token) or request.epoch == 0 or !hex(request.package_digest) or !hex(request.config.policy_digest) or !safeHandle(request.config.runtime_handle) or !contains(request.bound_handles, request.config.runtime_handle)) return error.PermissionDenied;
    const marker = std.mem.lastIndexOf(u8, request.config.image, "@sha256:") orelse return error.RuntimeUnsupported;
    if (marker == 0 or !hex(request.config.image[marker + 8 ..])) return error.RuntimeUnsupported;
    for (request.config.image[0..marker]) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "./_-", c) == null) return error.RuntimeUnsupported;
    if (request.files.len == 0 or request.files.len > 1024) return error.InvalidSnapshot;
    var total: usize = 0;
    var found = false;
    for (request.files, 0..) |file, index| {
        try relative(file.path);
        if (file.bytes.len > 16 * 1048576 - total) return error.InvalidSnapshot;
        total += file.bytes.len;
        const digest = hash(file.bytes);
        if (file.digest.len != 0 and !std.mem.eql(u8, file.digest, &digest)) return error.SnapshotDigest;
        if (std.mem.eql(u8, file.path, request.entry)) found = true;
        for (request.files[0..index]) |prior| {
            if (std.mem.eql(u8, file.path, prior.path)) return error.InvalidSnapshot;
            const short = if (file.path.len < prior.path.len) file.path else prior.path;
            const long = if (file.path.len < prior.path.len) prior.path else file.path;
            if (std.mem.startsWith(u8, long, short) and long.len > short.len and long[short.len] == '/') return error.InvalidSnapshot;
        }
    }
    if (!found) return error.InvalidSnapshot;
}
fn containerConfig(allocator: Allocator, request: CodeRequest, directory: []const u8, labels: Value) !Value {
    var cmd: std.ArrayList([]const u8) = .empty;
    try cmd.appendSlice(allocator, &.{ "-i", "PATH=/usr/bin:/bin", "LANG=C.UTF-8", try interpreter(request.config) });
    switch (request.config.runtime) {
        .python3 => try cmd.appendSlice(allocator, &.{ "-E", "-s", "-S", "-B", try std.fmt.allocPrint(allocator, "/package/{s}", .{request.entry}) }),
        .node => try cmd.appendSlice(allocator, &nodeArguments("/package", request.entry)),
    }
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{
        .Image = request.config.image,
        .User = "65534:65534",
        .Entrypoint = [_][]const u8{"/usr/bin/env"},
        .Cmd = cmd.items,
        .WorkingDir = "/work",
        .Tty = false,
        .OpenStdin = true,
        .StdinOnce = true,
        .AttachStdin = true,
        .AttachStdout = true,
        .AttachStderr = true,
        .HostConfig = .{
            .NetworkMode = "none",
            .ReadonlyRootfs = true,
            .CapDrop = [_][]const u8{"ALL"},
            .SecurityOpt = [_][]const u8{"no-new-privileges"},
            .LogConfig = .{ .Type = "none", .Config = .{} },
            .RestartPolicy = .{ .Name = "no", .MaximumRetryCount = 0 },
            .AutoRemove = false,
            .Privileged = false,
            .PidMode = "",
            .IpcMode = "private",
            .CgroupnsMode = "private",
            .PidsLimit = 32,
            .Memory = memory_limit,
            .MemorySwap = memory_limit,
            .NanoCpus = 1000000000,
            .Ulimits = [_][]const struct { Name: []const u8, Soft: u32, Hard: u32 }{},
        },
    }, .{});
    var config = try parse(allocator, bytes, 262144);
    try put(allocator, &config, "Labels", labels);
    var host = try get(config, "HostConfig");
    var log_config = try get(host, "LogConfig");
    try put(allocator, &log_config, "Config", object());
    try put(allocator, &host, "LogConfig", log_config);
    var ulimits = array(allocator);
    var core = object();
    try put(allocator, &core, "Name", string("core"));
    try put(allocator, &core, "Soft", .{ .integer = 0 });
    try put(allocator, &core, "Hard", .{ .integer = 0 });
    try ulimits.array.append(core);
    try put(allocator, &host, "Ulimits", ulimits);
    var tmpfs = object();
    try put(allocator, &tmpfs, "/tmp", string("rw,noexec,nosuid,nodev,size=8m"));
    try put(allocator, &tmpfs, "/work", string("rw,noexec,nosuid,nodev,size=8m"));
    try put(allocator, &host, "Tmpfs", tmpfs);
    var mounts = array(allocator);
    var package = object();
    try put(allocator, &package, "Type", string("bind"));
    try put(allocator, &package, "Source", string(directory));
    try put(allocator, &package, "Target", string("/package"));
    try put(allocator, &package, "ReadOnly", .{ .bool = true });
    try mounts.array.append(package);
    for (request.grants) |grant| {
        var mount = object();
        try put(allocator, &mount, "Type", string("bind"));
        try put(allocator, &mount, "Source", string(grant.source));
        try put(allocator, &mount, "Target", string(grant.target));
        try put(allocator, &mount, "ReadOnly", .{ .bool = true });
        try mounts.array.append(mount);
    }
    try put(allocator, &host, "Mounts", mounts);
    try put(allocator, &config, "HostConfig", host);
    return config;
}
const Invocation = struct {
    allocator: Allocator,
    io: std.Io,
    request: CodeRequest,
    client: docker.Client,
    name: []const u8,
    directory: []const u8,
    config: Value,
    input_json: []const u8,
    image_id: []const u8,
    details: Value,
    stage_id: []const u8,
    container_id: []const u8,
    effect_id: []const u8,
    stage_reserved: bool = false,
    container_reserved: bool = false,
    stage_created: bool = false,
    stage_inode: ?u64 = null,
    create_attempted: bool = false,
    create_rejected: bool = false,
    id: ?[]const u8 = null,
    start_attempted: bool = false,
    applied: bool = false,
    directories: std.ArrayList([]const u8) = .empty,
    fn journal(self: *Invocation, id: []const u8, kind: []const u8, state: @FieldType(runner.Effect, "state")) !void {
        try self.request.step.journal.record(.{ .id = id, .kind = kind, .state = state, .details = self.details });
    }
    fn current(self: *Invocation) !void {
        try self.client.bound.check();
        if (self.request.authority) |authority| try authority.checkFn(authority.context);
        try checkGrants(self.allocator, self.io, self.request);
    }
    fn control(self: *Invocation, method: []const u8, path: []const u8, body: []const u8) !Value {
        const response = try self.client.request(method, path, body);
        defer self.allocator.free(response.body);
        if (response.status == 404) return error.DockerNotFound;
        if (response.status != 200 and response.status != 201 and response.status != 204) return error.DockerControlFailed;
        if (response.body.len == 0) return .null;
        return parse(self.allocator, response.body, 262144);
    }
    fn endpoint(self: *Invocation, locator: []const u8, suffix: []const u8) ![]const u8 {
        const escaped = try docker.escape(self.allocator, locator);
        return std.fmt.allocPrint(self.allocator, "/containers/{s}{s}", .{ escaped, suffix });
    }
    fn inspect(self: *Invocation) !Value {
        const info = try self.control("GET", try self.endpoint(self.id orelse self.name, "/json"), "");
        try self.prove(info);
        return info;
    }
    fn prove(self: *Invocation, info: Value) !void {
        const id = try text(try get(info, "Id"));
        if (!hex(id) or (self.id != null and !std.mem.eql(u8, self.id.?, id))) return error.ContainerOwnership;
        const name = try std.fmt.allocPrint(self.allocator, "/{s}", .{self.name});
        if (!std.mem.eql(u8, try text(try get(info, "Name")), name) or !std.mem.eql(u8, try text(try get(info, "Image")), self.image_id)) return error.ContainerOwnership;
        const actual = try get(info, "Config");
        if (!equal(try get(actual, "Labels"), try get(self.config, "Labels"))) return error.ContainerOwnership;
        for ([_][]const u8{ "User", "Entrypoint", "Cmd", "WorkingDir", "Tty", "OpenStdin", "StdinOnce" }) |key| if (!equal(try get(actual, key), try get(self.config, key))) return error.ContainerIsolation;
        const wanted = try get(self.config, "HostConfig");
        const host = try get(info, "HostConfig");
        var it = wanted.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "Mounts")) continue;
            if (!equal(try get(host, entry.key_ptr.*), entry.value_ptr.*)) return error.ContainerIsolation;
        }
        const expected = try get(wanted, "Mounts");
        const mounts = try get(info, "Mounts");
        if (mounts != .array) return error.ContainerIsolation;
        var found: usize = 0;
        var seen: [17]bool = @splat(false);
        for (mounts.array.items) |mount| {
            const kind = try text(try get(mount, "Type"));
            if (std.mem.eql(u8, kind, "tmpfs")) continue;
            var match = false;
            for (expected.array.items, 0..) |want, index| {
                const rw = try get(mount, "RW");
                if (rw != .bool) return error.ContainerIsolation;
                if (std.mem.eql(u8, kind, try text(try get(want, "Type"))) and std.mem.eql(u8, try text(try get(mount, "Source")), try text(try get(want, "Source"))) and std.mem.eql(u8, try text(try get(mount, "Destination")), try text(try get(want, "Target"))) and !rw.bool) {
                    if (seen[index]) return error.ContainerIsolation;
                    seen[index] = true;
                    match = true;
                    break;
                }
            }
            if (!match) return error.ContainerIsolation;
            found += 1;
        }
        if (found != expected.array.items.len) return error.ContainerIsolation;
        const state = try get(info, "State");
        if (try get(state, "Running") != .bool) return error.DockerProtocol;
    }
    fn stage(self: *Invocation) !void {
        var root = try canonical(self.allocator, self.io, self.request.config.staging_root);
        defer root.close(self.io);
        const stat = metadata.fstat(root.handle) catch return error.StagingIdentity;
        if (stat.uid != std.c.getuid() or stat.mode & 0o777 != 0o700) return error.StagingIdentity;
        try self.journal(self.stage_id, "code_staging", .unknown);
        self.stage_reserved = true;
        try root.createDir(self.io, self.name, .fromMode(0o700));
        self.stage_created = true;
        var directory = try root.openDir(self.io, self.name, .{ .follow_symlinks = false });
        defer directory.close(self.io);
        self.stage_inode = (try directory.stat(self.io)).inode;
        try self.directories.append(self.allocator, try self.allocator.dupe(u8, self.directory));
        for (self.request.files) |file| {
            try self.current();
            var parent = directory;
            var parent_owned = false;
            defer if (parent_owned) parent.close(self.io);
            if (std.fs.path.dirname(file.path)) |parents| {
                var parts = std.mem.splitScalar(u8, parents, '/');
                var prefix: std.ArrayList(u8) = .empty;
                defer prefix.deinit(self.allocator);
                while (parts.next()) |part| {
                    if (prefix.items.len != 0) try prefix.append(self.allocator, '/');
                    try prefix.appendSlice(self.allocator, part);
                    parent.createDir(self.io, part, .fromMode(0o700)) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                    const next = try parent.openDir(self.io, part, .{ .follow_symlinks = false });
                    if (parent_owned) parent.close(self.io);
                    parent = next;
                    parent_owned = true;
                    const absolute = try std.fs.path.join(self.allocator, &.{ self.directory, prefix.items });
                    var known = false;
                    for (self.directories.items) |prior| if (std.mem.eql(u8, prior, absolute)) {
                        known = true;
                        break;
                    };
                    if (!known) try self.directories.append(self.allocator, absolute);
                }
            }
            var handle = try parent.createFile(self.io, std.fs.path.basename(file.path), .{ .exclusive = true, .permissions = .fromMode(0o444) });
            defer handle.close(self.io);
            try handle.writeStreamingAll(self.io, file.bytes);
            if (std.c.fchmod(handle.handle, 0o444) != 0) return error.StagingIdentity;
            try handle.sync(self.io);
        }
        for (self.directories.items) |path| {
            var dir = try canonical(self.allocator, self.io, path);
            defer dir.close(self.io);
            if (std.c.fchmod(dir.handle, 0o555) != 0) return error.StagingIdentity;
        }
        try self.verifyStage();
    }
    fn verifyStage(self: *Invocation) !void {
        var directory = try canonical(self.allocator, self.io, self.directory);
        defer directory.close(self.io);
        if (self.stage_inode == null or (try directory.stat(self.io)).inode != self.stage_inode.?) return error.StagingIdentity;
        for (self.request.files) |file| {
            var handle = try directory.openFile(self.io, file.path, .{ .follow_symlinks = false, .resolve_beneath = true });
            defer handle.close(self.io);
            const stat = try handle.stat(self.io);
            const physical = metadata.fstat(handle.handle) catch return error.StagingIdentity;
            if (physical.nlink != 1 or physical.mode & 0o777 != 0o444) return error.StagingIdentity;
            if (stat.kind != .file or stat.size != file.bytes.len) return error.SnapshotDigest;
            var reader = handle.reader(self.io, &.{});
            const bytes = try reader.interface.allocRemaining(self.allocator, .limited(16 * 1048576));
            defer self.allocator.free(bytes);
            if (!std.mem.eql(u8, bytes, file.bytes)) return error.SnapshotDigest;
        }
    }
    fn started(info: Value) !bool {
        return !std.mem.startsWith(u8, try text(try get(try get(info, "State"), "StartedAt")), "0001-");
    }
    fn markExecution(self: *Invocation, info: Value) !void {
        if (!self.applied and try started(info)) {
            try self.journal(self.effect_id, "code_invocation", .applied);
            self.applied = true;
        }
    }
    fn run(self: *Invocation) !runner.StepResult {
        try self.current();
        try self.stage();
        try self.journal(self.container_id, "code_container", .unknown);
        self.container_reserved = true;
        try self.journal(self.effect_id, "code_invocation", .unknown);
        try self.current();
        try self.verifyStage();
        const body = try std.json.Stringify.valueAlloc(self.allocator, self.config, .{});
        self.create_attempted = true;
        const response = try self.client.request("POST", try std.fmt.allocPrint(self.allocator, "/containers/create?name={s}", .{self.name}), body);
        if (response.status != 201) {
            self.create_rejected = response.status >= 400 and response.status < 500;
            return error.DockerControlFailed;
        }
        const created = try parse(self.allocator, response.body, 262144);
        self.id = try text(try get(created, "Id"));
        if (!hex(self.id.?)) return error.DockerProtocol;
        const initial = try self.inspect();
        if ((try get(try get(initial, "State"), "Running")).bool or try started(initial) or !std.mem.eql(u8, try text(try get(try get(initial, "State"), "Status")), "created")) return error.ContainerIsolation;
        try self.current();
        var attachment = try self.client.attach(self.id.?);
        defer attachment.close();
        try self.current();
        try self.verifyStage();
        self.start_attempted = true;
        _ = try self.control("POST", try self.endpoint(self.id.?, "/start"), "");
        try self.markExecution(try self.inspect());
        try attachment.finishInput(self.input_json);
        const capture = try attachment.capture(self.allocator, @min(self.request.step.limits.max_output_bytes, 1048576), @min(self.request.step.limits.max_diagnostic_bytes, 65536));
        const final = try self.inspect();
        try self.markExecution(final);
        const state = try get(final, "State");
        const exit = try get(state, "ExitCode");
        if ((try get(state, "Running")).bool or !try started(final) or exit != .integer) return error.DockerProtocol;
        return .{ .output = try outcome(self.allocator, exit.integer, capture.stdout, @min(self.request.step.limits.max_output_bytes, 1048576)), .usage = null, .operations = 1 };
    }
    fn cleanup(self: *Invocation) !void {
        self.client.bound.cancel = null;
        self.client.bound.gate = null;
        self.client.bound.deadline_ms = self.client.bound.now() + 2000;
        var info: ?Value = null;
        if (self.create_attempted and !self.create_rejected) {
            info = self.inspect() catch |err| switch (err) {
                error.DockerNotFound => if (self.id != null) null else return error.CleanupPending,
                else => return err,
            };
        }
        if (info) |initial| {
            self.id = try text(try get(initial, "Id"));
            var current_info = initial;
            if ((try get(try get(current_info, "State"), "Running")).bool) {
                _ = try self.control("POST", try self.endpoint(self.id.?, "/kill?signal=TERM"), "");
                const until = self.client.bound.now() + 500;
                while (self.client.bound.now() < until) {
                    current_info = try self.inspect();
                    if (!(try get(try get(current_info, "State"), "Running")).bool) break;
                    std.Io.sleep(self.io, .fromMilliseconds(25), .awake) catch {};
                }
                if ((try get(try get(current_info, "State"), "Running")).bool) {
                    _ = try self.control("POST", try self.endpoint(self.id.?, "/kill?signal=KILL"), "");
                    while (true) {
                        current_info = try self.inspect();
                        if (!(try get(try get(current_info, "State"), "Running")).bool) break;
                        std.Io.sleep(self.io, .fromMilliseconds(25), .awake) catch {};
                    }
                }
            }
            try self.markExecution(current_info);
            _ = try self.control("DELETE", try self.endpoint(self.id.?, "?force=false&v=false"), "");
            const confirmation = try self.client.request("GET", try self.endpoint(self.id.?, "/json"), "");
            if (confirmation.status != 404) return error.CleanupPending;
        }
        if (self.container_reserved) try self.journal(self.container_id, "code_container", .not_applied);
        if (!self.start_attempted and self.container_reserved) try self.journal(self.effect_id, "code_invocation", .not_applied);
        if (self.stage_created) {
            var root = try canonical(self.allocator, self.io, self.request.config.staging_root);
            defer root.close(self.io);
            var directory = try root.openDir(self.io, self.name, .{ .follow_symlinks = false });
            defer directory.close(self.io);
            if (self.stage_inode == null or (try directory.stat(self.io)).inode != self.stage_inode.?) return error.StagingIdentity;
            for (self.directories.items) |path| {
                var dir = try canonical(self.allocator, self.io, path);
                defer dir.close(self.io);
                if (std.c.fchmod(dir.handle, 0o700) != 0) return error.StagingIdentity;
            }
            try root.deleteTree(self.io, self.name);
            const gone = root.statFile(self.io, self.name, .{ .follow_symlinks = false });
            if (gone) |_| return error.StagingIdentity else |err| if (err != error.FileNotFound) return err;
        }
        if (self.stage_reserved) try self.journal(self.stage_id, "code_staging", .not_applied);
    }
};
/// What a finished process means for its step: nonzero is `code_exit`, and stdout
/// must be exactly one JSON value.
pub fn outcome(allocator: Allocator, exit: i64, stdout: []const u8, cap: usize) !Value {
    if (exit != 0) return error.CodeExit;
    return parse(allocator, stdout, cap);
}
fn installedImage(allocator: Allocator, client: docker.Client, config: Config) !Value {
    const response = try client.request("GET", try std.fmt.allocPrint(allocator, "/images/{s}/json", .{try docker.escape(allocator, config.image)}), "");
    defer allocator.free(response.body);
    if (response.status == 404) return error.RuntimeUnavailable;
    if (response.status != 200) return error.DockerControlFailed;
    const image = try parse(allocator, response.body, 262144);
    const image_id = try text(try get(image, "Id"));
    const digest = if (std.mem.startsWith(u8, image_id, "sha256:")) image_id[7..] else image_id;
    if (!hex(digest)) return error.DockerProtocol;
    const digests = try get(image, "RepoDigests");
    if (digests != .array) return error.RuntimeUnavailable;
    for (digests.array.items) |item| if (item == .string and std.mem.eql(u8, item.string, config.image)) return image;
    return error.RuntimeUnavailable;
}
/// Availability of an already-installed pinned image; never pulls or probes code.
/// The caller checks declared profile/version/modules and registered bindings.
pub fn preflight(allocator: Allocator, io: std.Io, config: Config, cancel: *const std.atomic.Value(bool), deadline_ms: i64) !void {
    _ = try interpreter(config);
    if (!hex(config.policy_digest) or !safeHandle(config.runtime_handle)) return error.RuntimeUnsupported;
    const marker = std.mem.lastIndexOf(u8, config.image, "@sha256:") orelse return error.RuntimeUnsupported;
    if (marker == 0 or !hex(config.image[marker + 8 ..])) return error.RuntimeUnsupported;
    for (config.image[0..marker]) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "./_-", c) == null) return error.RuntimeUnsupported;
    const client: docker.Client = .{ .allocator = allocator, .socket_path = config.socket_path, .bound = .{ .io = io, .deadline_ms = @min(deadline_ms, std.Io.Clock.awake.now(io).toMilliseconds() + 30000), .cancel = cancel } };
    _ = try installedImage(allocator, client, config);
}
pub const RuntimeAudit = struct { version: [3]u32, cached: bool };
/// Process-local, bounded cache. The caller serializes audit/admission access.
pub const AuditCache = @import("audit_cache.zig").Cache;
pub const AuditRequest = struct {
    step: runner.StepRequest,
    config: Config,
    modules: []const []const u8,
    binding_id: []const u8 = "",
    binding_digest: []const u8 = "",
    owner_token: []const u8,
    bound_handles: []const []const u8,
    authority: ?Authority = null,
    observed_version: ?*?[3]u32 = null,
};
pub const runtime_probe_source =
    "import json,sys\n" ++
    "v=json.load(sys.stdin)\n" ++
    "for name in v['modules']:\n" ++
    " if name.split('.')[0] not in sys.stdlib_module_names: raise ImportError(name)\n" ++
    " __import__(name)\n" ++
    "print(json.dumps({'version':list(sys.version_info[:3]),'stdlib':v['modules']}))\n";
/// The same probe as an ES module, so an audit also proves the shim runs in the image.
pub const node_probe_source =
    "export default async ({ modules }) => {\n" ++
    "  for (const name of modules) await import(`node:${name}`);\n" ++
    "  return { version: process.versions.node.split('.').map(Number), stdlib: modules };\n" ++
    "};\n";
const Probe = struct { path: []const u8, source: []const u8 };
fn probe(runtime: Runtime) Probe {
    return switch (runtime) {
        .python3 => .{ .path = "runtime-probe.py", .source = runtime_probe_source },
        .node => .{ .path = "runtime-probe.mjs", .source = node_probe_source },
    };
}
/// Executes only the fixed retained runtime probe, never package code or grants.
/// The caller supplies a durable probe Journal and holds its foreground owner.
pub const PreparedAudit = struct { key: [64]u8, image: Value, socket: [64]u8 };
// Bump when sandbox configuration, invocation, or probe acceptance semantics change.
const audit_semantics = "fh.source-audit/3";
pub fn socketIdentity(allocator: Allocator, io: std.Io, path: []const u8) ![64]u8 {
    const configured = try allocator.dupeZ(u8, path);
    defer allocator.free(configured);
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
        error.FileNotFound => return error.RuntimeUnavailable,
        else => return err,
    };
    defer allocator.free(resolved);
    const endpoint = try allocator.dupeZ(u8, resolved);
    defer allocator.free(endpoint);
    const link = metadata.fstatat(std.c.AT.FDCWD, configured, false) catch return error.RuntimeUnavailable;
    const target = metadata.fstatat(std.c.AT.FDCWD, endpoint, true) catch return error.RuntimeUnavailable;
    if (target.mode & std.c.S.IFMT != std.c.S.IFSOCK) return error.RuntimeUnavailable;
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{ path, resolved, link.dev, link.ino, link.uid, link.mode, link.ctime().sec, link.ctime().nsec, target.dev, target.ino, target.uid, target.mode, target.ctime().sec, target.ctime().nsec }, .{});
    defer allocator.free(bytes);
    return hash(bytes);
}
test "native code missing configured socket is runtime unavailable" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffer: [4096]u8 = undefined;
    const directory_len = try temporary.dir.realPath(io, &buffer);
    const directory = buffer[0..directory_len];
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing.sock", .{directory});
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().realPathFileAlloc(io, path, std.testing.allocator));
    try std.testing.expectError(error.RuntimeUnavailable, socketIdentity(std.testing.allocator, io, path));
}
pub fn prepareAudit(allocator: Allocator, io: std.Io, request: AuditRequest) !PreparedAudit {
    if (request.modules.len > 64) return error.RuntimeUnsupported;
    for (request.modules) |module| {
        if (module.len == 0 or module.len > 64 or (!std.ascii.isLower(module[0]) and module[0] != '_')) return error.RuntimeUnsupported;
        for (module) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and !(request.config.runtime == .node and c == '/')) return error.RuntimeUnsupported;
    }
    const deadline = @min(request.step.deadline_ms, std.Io.Clock.awake.now(io).toMilliseconds() + 2000);
    const client: docker.Client = .{ .allocator = allocator, .socket_path = request.config.socket_path, .bound = .{ .io = io, .deadline_ms = deadline, .cancel = request.step.cancel } };
    try client.bound.check();
    if (request.authority) |authority| try authority.checkFn(authority.context);
    const socket = try socketIdentity(allocator, io, request.config.socket_path);
    // A cache hit still proves the pinned image remains installed.
    const image = try installedImage(allocator, client, request.config);
    const image_id = try text(try get(image, "Id"));
    try client.bound.check();
    if (request.authority) |authority| try authority.checkFn(authority.context);
    if (!std.mem.eql(u8, &socket, &try socketIdentity(allocator, io, request.config.socket_path))) return error.RuntimeUnavailable;
    return .{ .image = image, .socket = socket, .key = try auditIdentity(allocator, request, image_id, socket, audit_semantics, probe(request.config.runtime).source) };
}
fn auditIdentity(allocator: Allocator, request: AuditRequest, image_id: []const u8, socket: [64]u8, semantics: []const u8, probe_source: []const u8) ![64]u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, .{ semantics, hash(probe_source), hash(node_shim_source), socket, image_id, request.config.image, request.config.python, @tagName(request.config.runtime), request.config.node, request.modules, request.config.policy_digest, request.config.runtime_handle, request.binding_id, request.binding_digest, request.bound_handles }, .{});
    defer allocator.free(bytes);
    return hash(bytes);
}
/// Read-only cached availability check; no journal or physical resource effects.
pub fn cachedRuntime(allocator: Allocator, io: std.Io, request: AuditRequest, cache: *AuditCache) !?RuntimeAudit {
    const prepared = try prepareAudit(allocator, io, request);
    if (cache.find(prepared.key)) |version| return .{ .version = version, .cached = true };
    return null;
}
pub fn auditRuntime(allocator: Allocator, io: std.Io, request: AuditRequest, cache: *AuditCache) !RuntimeAudit {
    const prepared = try prepareAudit(allocator, io, request);
    return auditPrepared(allocator, io, request, cache, prepared);
}
/// Only the fixed probe consumes prepared image evidence; public execute always inspects.
pub fn auditPrepared(allocator: Allocator, io: std.Io, request: AuditRequest, cache: *AuditCache, prepared: PreparedAudit) !RuntimeAudit {
    try (docker.Bound{ .io = io, .deadline_ms = request.step.deadline_ms, .cancel = request.step.cancel }).check();
    const fixed = probe(request.config.runtime);
    const current_key = try auditIdentity(allocator, request, try text(try get(prepared.image, "Id")), prepared.socket, audit_semantics, fixed.source);
    if (!std.mem.eql(u8, &prepared.key, &current_key)) return error.RuntimeUnavailable;
    if (!std.mem.eql(u8, &prepared.socket, &try socketIdentity(allocator, io, request.config.socket_path))) return error.RuntimeUnavailable;
    if (request.authority) |authority| try authority.checkFn(authority.context);
    if (cache.find(prepared.key)) |version| return .{ .version = version, .cached = true };
    const deadline = @min(request.step.deadline_ms, std.Io.Clock.awake.now(io).toMilliseconds() + 2000);
    var modules = array(allocator);
    for (request.modules) |module| try modules.array.append(string(module));
    var input = object();
    try put(allocator, &input, "modules", modules);
    var step = request.step;
    step.input = input;
    step.deadline_ms = deadline;
    step.limits.max_seconds = @min(step.limits.max_seconds, 2);
    step.limits.max_output_bytes = @min(step.limits.max_output_bytes, 65536);
    step.limits.max_diagnostic_bytes = @min(step.limits.max_diagnostic_bytes, 4096);
    const result = try executeWithImage(allocator, io, .{ .step = step, .files = &.{.{ .path = fixed.path, .bytes = fixed.source }}, .entry = fixed.path, .config = request.config, .owner_token = request.owner_token, .package_digest = &hash(fixed.source), .bound_handles = request.bound_handles, .authority = request.authority }, prepared.image);
    const actual = try get(result.output, "version");
    if (actual != .array or actual.array.items.len != 3 or !equal(try get(result.output, "stdlib"), modules)) return error.RuntimeUnsupported;
    var version: [3]u32 = undefined;
    for (actual.array.items, &version) |part, *number| {
        if (part != .integer or part.integer < 0 or part.integer > std.math.maxInt(u32)) return error.RuntimeUnsupported;
        number.* = @intCast(part.integer);
    }
    if (request.observed_version) |observed| observed.* = version;
    if (!supportedVersion(request.config.runtime, version)) return error.RuntimeUnsupported;
    try (docker.Bound{ .io = io, .deadline_ms = deadline, .cancel = request.step.cancel }).check();
    if (request.authority) |authority| try authority.checkFn(authority.context);
    if (!std.mem.eql(u8, &prepared.socket, &try socketIdentity(allocator, io, request.config.socket_path))) return error.RuntimeUnavailable;
    cache.remember(prepared.key, version);
    return .{ .version = version, .cached = false };
}
/// Transient transport/staging data ends with this invocation, after owned cleanup.
/// Only validated output escapes into the caller's longer-lived allocation scope.
pub fn execute(allocator: Allocator, io: std.Io, request: CodeRequest) !runner.StepResult {
    return executeWithImage(allocator, io, request, null);
}
fn executeWithImage(allocator: Allocator, io: std.Io, request: CodeRequest, image: ?Value) !runner.StepResult {
    // Independent backing is essential when the caller itself owns an arena.
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    var result = try executeOwned(temporary, io, request, image);
    result.output = try retainOutput(allocator, temporary, result.output, @min(request.step.limits.max_output_bytes, 1048576));
    return result;
}
fn retainOutput(allocator: Allocator, temporary: Allocator, output: Value, cap: usize) !Value {
    const bytes = try std.json.Stringify.valueAlloc(temporary, output, .{});
    return parse(allocator, bytes, cap);
}
fn executeOwned(allocator: Allocator, io: std.Io, request: CodeRequest, prepared_image: ?Value) !runner.StepResult {
    try validate(request);
    try checkGrants(allocator, io, request);
    const input = try std.json.Stringify.valueAlloc(allocator, request.step.input, .{});
    if (input.len > @min(request.step.limits.max_output_bytes, 1048576)) return error.InputLimit;
    const input_json = try std.fmt.allocPrint(allocator, "{s}\n", .{input});
    var authority_gate: docker.Gate = undefined;
    if (request.authority) |authority| authority_gate = .{ .context = authority.context, .checkFn = authority.checkFn };
    const now = std.Io.Clock.awake.now(io).toMilliseconds();
    const deadline = @min(request.step.deadline_ms, now + @as(i64, request.step.limits.max_seconds) * 1000);
    var client: docker.Client = .{ .allocator = allocator, .socket_path = request.config.socket_path, .bound = .{ .io = io, .deadline_ms = deadline, .cancel = request.step.cancel, .gate = if (request.authority != null) &authority_gate else null } };
    try client.validate();
    try client.bound.check();
    if (request.authority) |authority| try authority.checkFn(authority.context);
    const image = prepared_image orelse try installedImage(allocator, client, request.config);
    const image_id = try text(try get(image, "Id"));
    var random: [16]u8 = undefined;
    io.random(&random);
    const attempt = try allocator.dupe(u8, &std.fmt.bytesToHex(random, .lower));
    const owner = try allocator.dupe(u8, &hash(request.owner_token));
    const epoch = try std.fmt.allocPrint(allocator, "{d}", .{request.epoch});
    const name = try std.fmt.allocPrint(allocator, "fh-code-{s}", .{(hash(try std.fmt.allocPrint(allocator, "{s}:{s}:{s}:{d}:{s}", .{ owner, request.step.run_id, request.step.step_id, request.step.iteration, attempt })))[0..40]});
    const directory = try std.fs.path.join(allocator, &.{ request.config.staging_root, name });
    var labels = object();
    const image_config = try get(image, "Config");
    if (image_config != .object) return error.DockerProtocol;
    if (image_config.object.get("Labels")) |existing| if (existing == .object) {
        var it = existing.object.iterator();
        while (it.next()) |entry| try put(allocator, &labels, entry.key_ptr.*, entry.value_ptr.*);
    };
    try put(allocator, &labels, "fasthands.owner", string(owner));
    try put(allocator, &labels, "fasthands.epoch", string(epoch));
    try put(allocator, &labels, "fasthands.attempt", string(attempt));
    const config = try containerConfig(allocator, request, directory, labels);
    var details = object();
    try put(allocator, &details, "container", string(name));
    try put(allocator, &details, "staging", string(directory));
    try put(allocator, &details, "config", config);
    try put(allocator, &details, "image_id", string(image_id));
    try put(allocator, &details, "package_digest", string(request.package_digest));
    try put(allocator, &details, "policy_digest", string(request.config.policy_digest));
    var invocation: Invocation = .{ .allocator = allocator, .io = io, .request = request, .client = client, .name = name, .directory = directory, .config = config, .input_json = input_json, .image_id = image_id, .details = details, .stage_id = try std.fmt.allocPrint(allocator, "staging-{s}", .{attempt}), .container_id = try std.fmt.allocPrint(allocator, "container-{s}", .{attempt}), .effect_id = try std.fmt.allocPrint(allocator, "code-{s}", .{attempt}) };
    var failure: ?anyerror = null;
    const result = invocation.run() catch |err| blk: {
        failure = err;
        break :blk null;
    };
    invocation.cleanup() catch return error.CleanupPending;
    if (failure) |err| return err;
    return result.?;
}
test "code rejects unsafe paths and invalid stdout JSON" {
    try std.testing.expectError(error.InvalidCodePath, relative("../script.py"));
    try std.testing.expectError(error.InvalidCodePath, relative("scripts//run.py"));
    try relative("scripts/run.py");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidCodeResult, parse(allocator, "{\"x\":1,\"x\":2}", 128));
    try std.testing.expectError(error.InvalidCodeResult, parse(allocator, "{} {}", 128));
    try std.testing.expectError(error.InvalidCodeResult, parse(allocator, "\xff", 128));
    try std.testing.expectError(error.InvalidCodeResult, parse(allocator, "{\"x\":1e400}", 128));
    _ = try parse(allocator, "{\"ready\":false}", 128);
    _ = &execute;
    _ = &auditRuntime;
}

test "code cancellation precedes Docker and staging" {
    var cancel = std.atomic.Value(bool).init(true);
    const Fixture = struct {
        fn journal(_: *anyopaque, _: runner.Effect) !void {
            return error.UnexpectedJournal;
        }
    };
    var marker: u8 = 0;
    const request: CodeRequest = .{
        .step = .{ .run_id = "run-cancel", .step_id = "saved", .iteration = 0, .definition = .null, .input = .null, .selection = .{}, .response_schema = .null, .limits = .{}, .cancel = &cancel, .deadline_ms = std.math.maxInt(i64), .journal = .{ .context = &marker, .recordFn = Fixture.journal } },
        .files = &.{.{ .path = "main.py", .bytes = "print('{}')" }},
        .entry = "main.py",
        .config = .{ .socket_path = "/private/tmp/fh-no-docker.sock", .staging_root = "/private/tmp/fh-no-staging", .image = "runtime@sha256:" ++ "a" ** 64, .runtime_handle = "runtime", .policy_digest = "b" ** 64 },
        .owner_token = "test-owner",
        .package_digest = "c" ** 64,
        .bound_handles = &.{"runtime"},
    };
    try std.testing.expectError(error.Cancelled, execute(std.testing.allocator, std.testing.io, request));
}

test "code staging locks and unlocks its folders through real descriptors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(try allocator.dupeZ(u8, root), 0o700));
    {
        // The kernel itself, not libc, must accept fchmod on this handle. Linux refuses it
        // on an O_PATH descriptor; musl hides that by retrying through /proc/self/fd.
        var handle = try canonical(allocator, io, root);
        defer handle.close(io);
        if (@import("builtin").os.tag == .linux) {
            const os = std.os.linux;
            try std.testing.expectEqual(os.E.SUCCESS, os.errno(os.fchmod(handle.handle, 0o700)));
        }
        var entries = handle.iterate();
        try std.testing.expectEqual(null, try entries.next(io));
    }
    const Fixture = struct {
        fn journal(_: *anyopaque, _: runner.Effect) !void {}
    };
    var marker: u8 = 0;
    var cancel = std.atomic.Value(bool).init(false);
    const request: CodeRequest = .{
        .step = .{ .run_id = "run-stage", .step_id = "saved", .iteration = 0, .definition = .null, .input = .null, .selection = .{}, .response_schema = .null, .limits = .{}, .cancel = &cancel, .deadline_ms = std.math.maxInt(i64), .journal = .{ .context = &marker, .recordFn = Fixture.journal } },
        .files = &.{ .{ .path = "main.py", .bytes = "print('{}')" }, .{ .path = "pkg/deep/util.py", .bytes = "x = 1\n" } },
        .entry = "main.py",
        .config = .{ .socket_path = "/private/tmp/fh-no-docker.sock", .staging_root = root, .image = "runtime@sha256:" ++ "a" ** 64, .runtime_handle = "runtime", .policy_digest = "b" ** 64 },
        .owner_token = "test-owner",
        .package_digest = "c" ** 64,
        .bound_handles = &.{"runtime"},
    };
    const name = "fh-code-stage-test";
    var invocation: Invocation = .{ .allocator = allocator, .io = io, .request = request, .client = .{ .allocator = allocator, .socket_path = request.config.socket_path, .bound = .{ .io = io, .deadline_ms = std.math.maxInt(i64), .cancel = &cancel } }, .name = name, .directory = try std.fs.path.join(allocator, &.{ root, name }), .config = .null, .input_json = "", .image_id = "", .details = .null, .stage_id = "staging", .container_id = "container", .effect_id = "code" };
    try invocation.stage();
    for ([_][]const u8{ name, name ++ "/pkg", name ++ "/pkg/deep" }) |folder| {
        const stat = try metadata.fstatat(tmp.dir.handle, try allocator.dupeZ(u8, folder), false);
        try std.testing.expectEqual(@as(u32, 0o555), @as(u32, @intCast(stat.mode & 0o777)));
    }
    const file = try metadata.fstatat(tmp.dir.handle, name ++ "/pkg/deep/util.py", false);
    try std.testing.expectEqual(@as(u32, 0o444), @as(u32, @intCast(file.mode & 0o777)));
    try invocation.cleanup();
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, name, .{ .follow_symlinks = false }));
}

test "retained code output survives invocation arena teardown" {
    var caller = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer caller.deinit();
    const retained = blk: {
        var invocation = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer invocation.deinit();
        const output = try parse(invocation.allocator(), "{\"items\":[{\"message\":\"retained\"}],\"ready\":false}", 128);
        break :blk try retainOutput(caller.allocator(), invocation.allocator(), output, 128);
    };
    const items = try get(retained, "items");
    try std.testing.expectEqualStrings("retained", try text(try get(items.array.items[0], "message")));
    try std.testing.expect(!(try get(retained, "ready")).bool);
}

test "code audit identity binds all immutable runtime and probe semantics" {
    const Fixture = struct {
        fn journal(_: *anyopaque, _: runner.Effect) !void {}
    };
    var marker: u8 = 0;
    var cancel = std.atomic.Value(bool).init(false);
    const original: AuditRequest = .{
        .step = .{ .run_id = "run", .step_id = "audit", .iteration = 0, .definition = .null, .input = .null, .selection = .{}, .response_schema = .null, .limits = .{}, .cancel = &cancel, .deadline_ms = std.math.maxInt(i64), .journal = .{ .context = &marker, .recordFn = Fixture.journal } },
        .config = .{ .socket_path = "/socket", .staging_root = "/stage", .image = "image@sha256:" ++ "a" ** 64, .runtime_handle = "runtime", .policy_digest = "b" ** 64 },
        .modules = &.{"json"},
        .owner_token = "owner",
        .bound_handles = &.{"runtime"},
        .binding_id = "local",
        .binding_digest = "c" ** 64,
    };
    const allocator = std.testing.allocator;
    const key = try auditIdentity(allocator, original, "sha256:image", @splat('s'), audit_semantics, runtime_probe_source);
    for (0..13) |change| {
        var request = original;
        var image_id: []const u8 = "sha256:image";
        var socket = [_]u8{'s'} ** 64;
        var semantics: []const u8 = audit_semantics;
        var probe_source: []const u8 = runtime_probe_source;
        switch (change) {
            0 => request.modules = &.{ "json", "math" },
            1 => request.config.image = "another-image",
            2 => request.config.python = "/other/python",
            3 => request.config.runtime_handle = "another-runtime",
            4 => request.config.policy_digest = "another-policy",
            5 => request.binding_id = "another-binding",
            6 => request.binding_digest = "another-digest",
            7 => image_id = "sha256:another-image",
            8 => socket[0] = 't',
            9 => semantics = "another-implementation",
            10 => probe_source = "another-probe",
            11 => request.config.runtime = .node,
            12 => request.config.node = "/other/node",
            else => unreachable,
        }
        try std.testing.expect(!std.mem.eql(u8, &key, &try auditIdentity(allocator, request, image_id, socket, semantics, probe_source)));
    }
    var unrelated = original;
    unrelated.owner_token = "another-owner";
    unrelated.step.run_id = "another-run";
    try std.testing.expectEqual(key, try auditIdentity(allocator, unrelated, "sha256:image", @splat('s'), audit_semantics, runtime_probe_source));
}

test "native retry isolation proof accepts producer config and rejects conflicting Docker channels" {
    const diagnostics = @import("../run_diagnostics.zig");
    const Fixture = struct {
        fn journal(_: *anyopaque, _: runner.Effect) !void {}
        fn guidance(allocator: Allocator, config: Value, state: []const u8) !diagnostics.Retry {
            var record = try parse(allocator, "{\"status\":\"failed\",\"package_path\":\"/package/loop.json\",\"bindings_id\":\"local\",\"input_source\":\"inline\",\"input_sha256\":\"hash\",\"root_input\":{},\"package_digest\":\"package\",\"binding_digest\":\"binding\",\"usage_unknown\":false,\"model_request_dispatches\":0,\"used_tokens\":0,\"model_request_dispatches_complete\":true,\"effects\":[]}", 1048576);
            var receipt = object();
            try put(allocator, &receipt, "id", string("saved-code"));
            try put(allocator, &receipt, "kind", string("code_invocation"));
            try put(allocator, &receipt, "state", string(state));
            var details = object();
            try put(allocator, &details, "config", config);
            try put(allocator, &receipt, "details", details);
            try record.object.getPtr("effects").?.array.append(receipt);
            return diagnostics.retryGuidance(record);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var marker: u8 = 0;
    var cancel = std.atomic.Value(bool).init(false);
    const request: CodeRequest = .{
        .step = .{ .run_id = "run", .step_id = "saved", .iteration = 0, .definition = .null, .input = .null, .selection = .{}, .response_schema = .null, .limits = .{}, .cancel = &cancel, .deadline_ms = 1000, .journal = .{ .context = &marker, .recordFn = Fixture.journal } },
        .files = &.{},
        .entry = "saved.py",
        .config = .{ .socket_path = "/socket", .staging_root = "/stage", .image = "python@sha256:" ++ "a" ** 64, .runtime_handle = "runtime", .policy_digest = "b" ** 64 },
        .owner_token = "owner",
        .package_digest = "c" ** 64,
        .bound_handles = &.{"runtime"},
        .grants = &.{.{ .handle = "source", .source = "/project/src", .target = "/grants/source", .dev = 1, .ino = 2 }},
    };
    const labels = try parse(allocator, "{\"fasthands.owner\":\"owner\",\"fasthands.epoch\":\"1\",\"fasthands.attempt\":\"saved\"}", 1048576);
    // Use the actual production emitter, rather than a partial synthetic proof.
    const config = try containerConfig(allocator, request, "/stage/saved", labels);
    try std.testing.expect((try Fixture.guidance(allocator, config, "applied")).allowed);
    try std.testing.expect((try Fixture.guidance(allocator, config, "not_applied")).allowed);
    try std.testing.expectEqualStrings("unknown_effects", (try Fixture.guidance(allocator, config, "unknown")).reason);
    const baseline = try std.json.Stringify.valueAlloc(allocator, config, .{});
    const additions = [_]struct { key: []const u8, json: []const u8 }{
        .{ .key = "Binds", .json = "[\"/host:/write:rw\"]" },
        .{ .key = "VolumesFrom", .json = "[\"host-container:rw\"]" },
        .{ .key = "Devices", .json = "[{\"PathOnHost\":\"/dev/disk0\",\"PathInContainer\":\"/dev/disk0\",\"CgroupPermissions\":\"rwm\"}]" },
        .{ .key = "DeviceRequests", .json = "[{\"Count\":-1}]" },
        .{ .key = "CapAdd", .json = "[\"SYS_ADMIN\"]" },
        .{ .key = "UTSMode", .json = "\"host\"" },
        .{ .key = "FutureHostChannel", .json = "true" },
    };
    for (additions) |addition| {
        var candidate = try parse(allocator, baseline, 262144);
        const host = candidate.object.getPtr("HostConfig").?;
        try put(allocator, host, addition.key, try parse(allocator, addition.json, 262144));
        try std.testing.expectEqualStrings("unverified_isolation", (try Fixture.guidance(allocator, candidate, "applied")).reason);
    }
    const changes = [_]struct { key: []const u8, json: []const u8 }{
        .{ .key = "PidMode", .json = "\"host\"" },
        .{ .key = "IpcMode", .json = "\"host\"" },
        .{ .key = "CgroupnsMode", .json = "\"host\"" },
        .{ .key = "NetworkMode", .json = "\"host\"" },
        .{ .key = "SecurityOpt", .json = "[\"seccomp=unconfined\"]" },
        .{ .key = "CapDrop", .json = "[]" },
        .{ .key = "Privileged", .json = "true" },
        .{ .key = "Tmpfs", .json = "{\"/tmp\":\"rw,exec,suid,dev\",\"/work\":\"rw,exec,suid,dev\"}" },
    };
    for (changes) |change| {
        var candidate = try parse(allocator, baseline, 262144);
        const host = candidate.object.getPtr("HostConfig").?;
        try put(allocator, host, change.key, try parse(allocator, change.json, 262144));
        try std.testing.expectEqualStrings("unverified_isolation", (try Fixture.guidance(allocator, candidate, "applied")).reason);
    }
    var missing = try parse(allocator, baseline, 262144);
    _ = missing.object.getPtr("HostConfig").?.object.swapRemove("SecurityOpt");
    try std.testing.expectEqualStrings("unverified_isolation", (try Fixture.guidance(allocator, missing, "applied")).reason);
    var writable = try parse(allocator, baseline, 262144);
    const mount = &writable.object.getPtr("HostConfig").?.object.getPtr("Mounts").?.array.items[1];
    try put(allocator, mount, "ReadOnly", .{ .bool = false });
    try std.testing.expectEqualStrings("unverified_isolation", (try Fixture.guidance(allocator, writable, "applied")).reason);
    var extra_config = try parse(allocator, baseline, 262144);
    try put(allocator, &extra_config, "Env", try parse(allocator, "[\"LD_PRELOAD=/grants/source/inject.so\"]", 262144));
    try std.testing.expectEqualStrings("unverified_isolation", (try Fixture.guidance(allocator, extra_config, "applied")).reason);
    // The loops/0.3 node runtime is proven by its own exact argv: the shim, /package and a local entry.
    var node_request = request;
    node_request.config.runtime = .node;
    node_request.entry = "steps/saved.mjs";
    const node_baseline = try std.json.Stringify.valueAlloc(allocator, try containerConfig(allocator, node_request, "/stage/saved", labels), .{});
    try std.testing.expect((try Fixture.guidance(allocator, try parse(allocator, node_baseline, 262144), "applied")).allowed);
    const node_changes = [_]struct { index: usize, text: []const u8 }{
        .{ .index = 3, .text = "/usr/bin/env" },
        .{ .index = 6, .text = "process.exit(0)" },
        .{ .index = 8, .text = "/grants/source" },
        .{ .index = 9, .text = "../saved.mjs" },
    };
    for (node_changes) |change| {
        var candidate = try parse(allocator, node_baseline, 262144);
        candidate.object.getPtr("Cmd").?.array.items[change.index] = string(change.text);
        try std.testing.expectEqualStrings("unverified_isolation", (try Fixture.guidance(allocator, candidate, "applied")).reason);
    }
    try std.testing.expectEqualStrings("agent_driven", diagnostics.retryGuidance(try parse(allocator, "{\"status\":\"failed\",\"driver\":\"agent\"}", 4096)).reason);
}

const node_fixture = @import("node_fixture.zig");
const NodeStep = struct { run: node_fixture.Run, output: anyerror!Value };
fn nodeStep(arena: Allocator, files: []const File, entry: []const u8, input: []const u8) !NodeStep {
    const run = try node_fixture.run(arena, std.testing.io, files, entry, try parse(arena, input, 4096));
    return .{ .run = run, .output = outcome(arena, run.exit, run.stdout, 1048576) };
}
fn expectJson(arena: Allocator, expected: []const u8, step: NodeStep) !void {
    const output = step.output catch |err| {
        std.debug.print("node step failed: {s}\n", .{step.run.stderr});
        return err;
    };
    try std.testing.expectEqualStrings(expected, try std.json.Stringify.valueAlloc(arena, output, .{}));
}
fn expectCodeExit(step: NodeStep, diagnostic: []const u8) !void {
    try std.testing.expectError(error.CodeExit, step.output);
    try std.testing.expectEqualStrings("", step.run.stdout);
    if (std.mem.indexOf(u8, step.run.stderr, diagnostic) == null) {
        std.debug.print("expected diagnostic \"{s}\" in: {s}\n", .{ diagnostic, step.run.stderr });
        return error.TestExpectedEqual;
    }
}

test "code node default export returns its result, sync or async" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectJson(a, "{\"said\":\"HI\"}", try nodeStep(a, &.{.{ .path = "shout.mjs", .bytes = "export default function (input) {\n  return { said: input.word.toUpperCase() }\n}\n" }}, "shout.mjs", "{\"word\":\"hi\"}"));
    // A timer the module leaves running must not hold the step open once it has resolved.
    try expectJson(a, "{\"said\":\"hi\"}", try nodeStep(a, &.{.{ .path = "steps/later.mjs", .bytes = "import { setTimeout as wait } from 'node:timers/promises';\nexport default async ({ word }) => {\n  await wait(5);\n  setInterval(() => {}, 1000);\n  return { said: word };\n};\n" }}, "steps/later.mjs", "{\"word\":\"hi\"}"));
}

test "code node thrown error and rejected promise are code_exit; a returned verdict is success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "export default () => { throw new Error('boom'); };\n" }}, "main.mjs", "{}"), "main.mjs: Error: boom");
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "export default async () => { throw new Error('later'); };\n" }}, "main.mjs", "{}"), "main.mjs: Error: later");
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "export default () => Promise.reject('plain');\n" }}, "main.mjs", "{}"), "main.mjs: plain");
    try expectJson(a, "{\"verdict\":\"fail\"}", try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "export default () => ({ verdict: 'fail' });\n" }}, "main.mjs", "{}"));
}

test "code node imports package-local files and built-ins, and nothing outside the package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const twice: File = .{ .path = "lib/twice.mjs", .bytes = "export const twice = n => n * 2;\n" };
    try expectJson(a, "{\"n\":8,\"sep\":\"/\"}", try nodeStep(a, &.{ .{ .path = "main.mjs", .bytes = "import { twice } from './lib/twice.mjs';\nimport path from 'path';\nexport default ({ n }) => ({ n: twice(n), sep: path.posix.sep });\n" }, twice }, "main.mjs", "{\"n\":4}"));
    // The fixture keeps the step input beside the package directory, so ../input.json exists.
    const refused = "is outside the package";
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "import input from '../input.json' with { type: 'json' };\nexport default () => input;\n" }}, "main.mjs", "{}"), refused);
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "export default async () => (await import('../input.json', { with: { type: 'json' } })).default;\n" }}, "main.mjs", "{}"), refused);
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "import { createRequire } from 'node:module';\nexport default () => createRequire(import.meta.url)('../input.json');\n" }}, "main.mjs", "{}"), refused);
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "export default async () => (await import('data:text/javascript,export default 1')).default;\n" }}, "main.mjs", "{}"), refused);
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "import pad from 'left-pad';\nexport default () => pad;\n" }}, "main.mjs", "{}"), "Cannot find package 'left-pad'");
}

test "code node module without a callable default export, or that cannot load or return JSON, fails cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "export default 42;\n" }}, "main.mjs", "{}"), "main.mjs: Error: no default export function");
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "export const run = () => ({});\n" }}, "main.mjs", "{}"), "main.mjs: Error: no default export function");
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "export default (input => {\n" }}, "main.mjs", "{}"), "main.mjs: SyntaxError");
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "export default () => undefined;\n" }}, "main.mjs", "{}"), "output is undefined, which JSON cannot represent");
    try expectCodeExit(try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "export default () => ({ at: new Date(0) });\n" }}, "main.mjs", "{}"), "at is a Date, not plain JSON");
}

test "code node console output joins diagnostics; bytes written straight to stdout are an invalid result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const noisy = try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "console.log('loading');\nprocess.stdout.write('{\"fake\":true}\\n');\nexport default () => {\n  console.log('called');\n  return { ok: true };\n};\n" }}, "main.mjs", "{}");
    try expectJson(a, "{\"ok\":true}", noisy);
    try std.testing.expectEqualStrings("loading\n{\"fake\":true}\ncalled\n", noisy.run.stderr);
    // As with a Python script that prints twice: never a guessed result.
    const raw = try nodeStep(a, &.{.{ .path = "main.mjs", .bytes = "import { writeSync } from 'node:fs';\nexport default () => {\n  writeSync(1, '{\"fake\":true}\\n');\n  return { ok: true };\n};\n" }}, "main.mjs", "{}");
    try std.testing.expectEqual(@as(i64, 0), raw.run.exit);
    try std.testing.expectError(error.InvalidCodeResult, raw.output);
}

test "code node container runs the shim under the same isolation as python3" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Fixture = struct {
        fn journal(_: *anyopaque, _: runner.Effect) !void {}
    };
    var marker: u8 = 0;
    var cancel = std.atomic.Value(bool).init(false);
    var request: CodeRequest = .{
        .step = .{ .run_id = "run", .step_id = "saved", .iteration = 0, .definition = .null, .input = .null, .selection = .{}, .response_schema = .null, .limits = .{}, .cancel = &cancel, .deadline_ms = std.math.maxInt(i64), .journal = .{ .context = &marker, .recordFn = Fixture.journal } },
        .files = &.{.{ .path = "steps/main.mjs", .bytes = "export default () => ({});\n" }},
        .entry = "steps/main.mjs",
        .config = .{ .socket_path = "/socket", .staging_root = "/stage", .image = "runtime@sha256:" ++ "a" ** 64, .runtime_handle = "runtime", .policy_digest = "b" ** 64 },
        .owner_token = "test-owner",
        .package_digest = "c" ** 64,
        .bound_handles = &.{"runtime"},
    };
    const python = try containerConfig(a, request, "/stage/fh-code-x", object());
    request.config.runtime = .node;
    try validate(request);
    const node = try containerConfig(a, request, "/stage/fh-code-x", object());
    var keys = python.object.iterator();
    while (keys.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "Cmd")) try std.testing.expect(equal(entry.value_ptr.*, try get(node, entry.key_ptr.*)));
    }
    try std.testing.expectEqual(python.object.count(), node.object.count());
    const expected = [_][]const u8{ "-i", "PATH=/usr/bin:/bin", "LANG=C.UTF-8", "/usr/local/bin/node", "--input-type=module", "-e", node_shim_source, "--", "/package", "steps/main.mjs" };
    const cmd = (try get(node, "Cmd")).array.items;
    try std.testing.expectEqual(expected.len, cmd.len);
    for (expected, cmd) |want, actual| try std.testing.expectEqualStrings(want, try text(actual));
    try std.testing.expectEqualStrings("/usr/bin/python3", try text((try get(python, "Cmd")).array.items[3]));
    try std.testing.expectEqualStrings("/package/steps/main.mjs", try text((try get(python, "Cmd")).array.items[8]));
    // An installation cannot name another interpreter, for either runtime.
    request.config.node = "/usr/bin/env";
    try std.testing.expectError(error.PermissionDenied, validate(request));
    try std.testing.expectError(error.RuntimeUnsupported, preflight(a, std.testing.io, request.config, &cancel, std.math.maxInt(i64)));
    for ([_][3]u32{ .{ 22, 15, 0 }, .{ 22, 23, 4 }, .{ 23, 5, 0 }, .{ 24, 0, 0 } }) |version| try std.testing.expect(supportedVersion(.node, version));
    for ([_][3]u32{ .{ 20, 19, 0 }, .{ 22, 14, 9 }, .{ 23, 4, 0 }, .{ 3, 12, 3 } }) |version| try std.testing.expect(!supportedVersion(.node, version));
    try std.testing.expect(supportedVersion(.python3, .{ 3, 12, 3 }) and !supportedVersion(.python3, .{ 3, 9, 0 }));
}

test "native socket identity rejects files and binds configured symlink and target" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Unix socket paths must fit sun_path even when the checkout or TMPDIR is deep.
    // Exclusive creation with private permissions never reuses an existing directory.
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    const root = try std.fmt.allocPrint(a, "/tmp/fh-socket-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
    try std.Io.Dir.createDirAbsolute(io, root, .fromMode(0o700));
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer dir.close(io);
    const path = try std.fs.path.join(a, &.{ root, "socket" });
    const alias = try std.fs.path.join(a, &.{ root, "alias" });
    try dir.writeFile(io, .{ .sub_path = "socket", .data = "ordinary" });
    try std.testing.expectError(error.RuntimeUnavailable, socketIdentity(a, io, path));
    try dir.deleteFile(io, "socket");
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var address: std.c.sockaddr.un = .{ .family = std.c.AF.UNIX, .path = @splat(0) };
    @memcpy(address.path[0..path.len], path);
    const length: std.c.socklen_t = @intCast(@offsetOf(std.c.sockaddr.un, "path") + path.len + 1);
    if (@hasField(std.c.sockaddr.un, "len")) address.len = @intCast(length);
    try std.testing.expectEqual(@as(c_int, 0), std.c.bind(fd, @ptrCast(&address), length));
    try dir.symLink(io, "socket", "alias", .{});
    const before = try socketIdentity(a, io, alias);
    // Keep the old inode alive to make replacement deterministic on every filesystem.
    try dir.rename("alias", dir, "old-alias", io);
    try dir.symLink(io, "socket", "alias", .{});
    const replaced_link = try socketIdentity(a, io, alias);
    try std.testing.expect(!std.mem.eql(u8, &before, &replaced_link));
    try dir.rename("socket", dir, "old-socket", io);
    const second = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    try std.testing.expect(second >= 0);
    defer _ = std.c.close(second);
    try std.testing.expectEqual(@as(c_int, 0), std.c.bind(second, @ptrCast(&address), length));
    const replaced_target = try socketIdentity(a, io, alias);
    try std.testing.expect(!std.mem.eql(u8, &replaced_link, &replaced_target));
}
