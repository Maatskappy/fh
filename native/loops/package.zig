const std = @import("std");
const schema = @import("schema.zig");
const decision_types = @import("decision_types.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
pub const File = struct { path: []const u8, bytes: []const u8 };
/// The package size bounds. Installing a package reuses these: it adds none of its own.
pub const max_files = 1024;
pub const max_bytes = 16 * 1024 * 1024;
const Descriptor = struct { value: Value, document: []const u8, definition: Value = .null };
const Format = enum { v1, v2, v3, v4 };
pub const Package = struct {
    owner: Allocator,
    arena: std.heap.ArenaAllocator,
    manifest: Value = .null,
    digest: []const u8 = "",
    files: []const File = &.{},
    root: []const u8 = "",
    manifest_path: []const u8 = "loop.json",
    registry: schema.Registry = undefined,
    input_schema: Descriptor = undefined,
    // Leaf steps (code, infer, decision) by id, at any depth; ids are unique package-wide.
    steps: std.StringHashMapUnmanaged(Descriptor) = .{},
    // The same leaf definitions, depth first in declaration order.
    leaves: []const Value = &.{},
    validation_error: schema.Diagnostic = .{},

    pub fn deinit(self: *Package) void {
        const owner = self.owner;
        self.arena.deinit();
        owner.destroy(self);
    }
    pub fn validateInput(self: *Package, input: Value) !void {
        self.registry.validate(self.input_schema.value, self.input_schema.document, input) catch |err| {
            self.validation_error = self.registry.diagnostic;
            return err;
        };
    }
    pub fn validateStepOutput(self: *Package, id: []const u8, output: Value) !void {
        const d = self.steps.get(id) orelse return error.UnknownStep;
        self.registry.validate(d.value, d.document, output) catch |err| {
            self.validation_error = self.registry.diagnostic;
            return err;
        };
    }
    pub fn stepSchema(self: *const Package, id: []const u8) !Value {
        return (self.steps.get(id) orelse return error.UnknownStep).value;
    }
    pub fn file(self: *const Package, path: []const u8) !File {
        try localPath(path);
        for (self.files) |f| if (std.mem.eql(u8, f.path, path)) return f;
        return error.MissingFile;
    }
    pub fn stepCode(self: *const Package, id: []const u8) !File {
        const d = self.steps.get(id) orelse return error.UnknownStep;
        return self.file((schema.get(d.definition, "file") orelse return error.NotCode).string);
    }
    /// The step as an adapter reads it: loops/0.3 `instructions: {"file"}` becomes
    /// that package file's exact text. Any other step is returned unchanged.
    pub fn resolved(self: *const Package, alloc: Allocator, step: Value) !Value {
        const instructions = schema.get(step, "instructions") orelse return step;
        if (instructions != .object) return step;
        const path = schema.string(schema.get(instructions, "file") orelse return error.InvalidManifest) orelse return error.InvalidManifest;
        var copy: Value = .{ .object = try step.object.clone(alloc) };
        try copy.object.put(alloc, "instructions", .{ .string = (try self.file(path)).bytes });
        return copy;
    }
    fn descriptor(self: *Package, value: Value) !Descriptor {
        if (value == .string) {
            try localPath(value.string);
            for (self.registry.documents) |doc| if (std.mem.eql(u8, doc.path, value.string)) {
                try self.registry.check(doc.value, doc.path);
                return .{ .value = doc.value, .document = doc.path };
            };
            return error.MissingFile;
        }
        try self.registry.check(value, self.manifest_path);
        return .{ .value = value, .document = self.manifest_path };
    }
};
pub fn localPath(path: []const u8) !void {
    if (path.len == 0 or path.len > std.fs.max_path_bytes or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\\x00:#?") != null or !std.unicode.utf8ValidateSlice(path)) return error.PackagePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return error.PackagePath;
}
fn nonempty(value: Value) ![]const u8 {
    const s = schema.string(value) orelse return error.InvalidManifest;
    if (std.mem.trim(u8, s, " \t\r\n").len == 0) return error.InvalidManifest;
    return s;
}
fn required(value: Value, key: []const u8) !Value {
    return schema.get(value, key) orelse error.InvalidManifest;
}
fn fields(value: Value, allowed: []const []const u8) !void {
    if (value != .object) return error.InvalidManifest;
    for (value.object.keys()) |key| {
        var found = false;
        for (allowed) |a| if (std.mem.eql(u8, a, key)) {
            found = true;
            break;
        };
        if (!found) return error.UnsupportedDefinition;
    }
}
fn shape(value: Value) !Value {
    try fields(value, &.{"schema"});
    return required(value, "schema");
}
// loops/0.3 section 4: a path joins ids and branch names with these delimiters.
fn pathSegment(value: Value) ![]const u8 {
    const s = try nonempty(value);
    if (std.mem.indexOfAny(u8, s, "/[]") != null) return error.InvalidManifest;
    return s;
}
const Walk = struct {
    self: *Package,
    format: Format,
    ids: std.StringHashMapUnmanaged(void) = .{},
    leaves: std.ArrayList(Value) = .empty,
    // Recursion depth is bounded by schema.parse, which rejects documents nested past its limit.
    fn list(walk: *Walk, steps: Value) anyerror!void {
        if (steps != .array or steps.array.items.len == 0) return error.InvalidManifest;
        for (steps.array.items) |step| try walk.one(step);
    }
    fn one(walk: *Walk, step: Value) anyerror!void {
        const self = walk.self;
        const a = self.arena.allocator();
        const composite = (walk.format == .v3 or walk.format == .v4);
        const kind = try nonempty(try required(step, "kind"));
        const id = if (composite) try pathSegment(try required(step, "id")) else try nonempty(try required(step, "id"));
        if ((try walk.ids.getOrPut(a, id)).found_existing) return error.DuplicateStep;
        if (composite and std.mem.eql(u8, kind, "parallel")) {
            try fields(step, &.{ "id", "kind", "branches" });
            const branches = try required(step, "branches");
            if (branches != .object or branches.object.count() == 0) return error.InvalidManifest;
            var it = branches.object.iterator();
            while (it.next()) |branch| {
                _ = try pathSegment(.{ .string = branch.key_ptr.* });
                try walk.list(branch.value_ptr.*);
            }
            return;
        }
        if (composite and std.mem.eql(u8, kind, "map")) {
            try fields(step, &.{ "id", "kind", "over", "steps" });
            _ = try required(step, "over");
            return walk.list(try required(step, "steps"));
        }
        if (std.mem.eql(u8, kind, "code")) {
            try fields(step, &.{ "id", "kind", "input", "output", "requires", "runtime", "file" });
            _ = try nonempty(try required(step, "runtime"));
            const code = try nonempty(try required(step, "file"));
            _ = try self.file(code);
        } else if (std.mem.eql(u8, kind, "infer")) {
            try fields(step, &.{ "id", "kind", "input", "output", "requires", "instructions", "complexity" });
            const instructions = try required(step, "instructions");
            if (composite and instructions == .object) {
                // loops/0.3 section 9: a package-local file, read as UTF-8 and used verbatim.
                try fields(instructions, &.{"file"});
                const prompt = try self.file(try nonempty(try required(instructions, "file")));
                if (!std.unicode.utf8ValidateSlice(prompt.bytes)) return error.InvalidManifest;
            } else _ = try nonempty(instructions);
            if (schema.get(step, "complexity")) |v| {
                const s = try nonempty(v);
                if (!std.mem.eql(u8, s, "low") and !std.mem.eql(u8, s, "medium") and !std.mem.eql(u8, s, "high")) return error.InvalidManifest;
            }
        } else if (std.mem.eql(u8, kind, "decision") and walk.format != .v1) {
            try fields(step, &.{ "id", "kind", "input", "output", "requires", "questions" });
            try decision_types.validateQuestions(try required(step, "questions"));
            if (schema.get(step, "requires")) |list_value| if (list_value != .array or list_value.array.items.len != 0) return error.UnsupportedCapability;
        } else return error.UnsupportedDefinition;
        if (schema.get(step, "requires")) |list_value| {
            if (list_value != .array) return error.InvalidManifest;
            for (list_value.array.items, 0..) |v, i| {
                const s = try nonempty(v);
                // workspace_read arrived in loops/0.3, on infer steps only.
                const workspace_read = std.mem.eql(u8, s, "workspace_read") and (walk.format == .v3 or walk.format == .v4) and std.mem.eql(u8, kind, "infer");
                if (!workspace_read and !std.mem.eql(u8, s, "browser") and !std.mem.eql(u8, s, "computer") and !std.mem.eql(u8, s, "web_search")) return error.UnsupportedCapability;
                for (list_value.array.items[0..i]) |p| if (schema.equal(p, v)) return error.InvalidManifest;
            }
        }
        _ = try required(step, "input");
        var descriptor = try self.descriptor(try shape(try required(step, "output")));
        descriptor.definition = step;
        try self.steps.put(a, id, descriptor);
        try walk.leaves.append(a, step);
    }
};
fn validateManifest(self: *Package) !void {
    const a = self.arena.allocator();
    const m = self.manifest;
    const name = try nonempty(try required(m, "format"));
    const format: Format = if (std.mem.eql(u8, name, "loops/0.1")) .v1 else if (std.mem.eql(u8, name, "loops/0.2")) .v2 else if (std.mem.eql(u8, name, "loops/0.3")) .v3 else if (std.mem.eql(u8, name, "loops/0.4")) .v4 else return error.UnsupportedFormat;
    if (format == .v4) try fields(m, &.{ "format", "name", "version", "description", "inputs", "steps", "output", "repeat", "dependencies" }) else try fields(m, &.{ "format", "name", "version", "description", "inputs", "steps", "output", "repeat" });
    _ = try nonempty(try required(m, "name"));
    _ = try nonempty(try required(m, "version"));
    if (schema.get(m, "description")) |v| if (v != .string) return error.InvalidManifest;
    self.input_schema = try self.descriptor(try shape(try required(m, "inputs")));
    const steps = try required(m, "steps");
    if (steps != .array or steps.array.items.len == 0 or steps.array.items.len > 64) return error.InvalidManifest;
    var walk: Walk = .{ .self = self, .format = format };
    try walk.list(steps);
    self.leaves = try walk.leaves.toOwnedSlice(a);
    if (format == .v4) try @import("dependencies.zig").validate(m, self.leaves);
    _ = try required(m, "output");
    if (schema.get(m, "repeat")) |repeat| {
        try fields(repeat, &.{ "from", "through", "until", "max_iterations", "carry" });
        const from = try nonempty(try required(repeat, "from"));
        const through = try nonempty(try required(repeat, "through"));
        var start: ?usize = null;
        var end: ?usize = null;
        for (steps.array.items, 0..) |step, i| {
            const id = (try required(step, "id")).string;
            if (std.mem.eql(u8, id, from)) start = i;
            if (std.mem.eql(u8, id, through)) end = i;
        }
        if (start == null or end == null or start.? > end.?) return error.InvalidRepeat;
        const n = try required(repeat, "max_iterations");
        if (n != .integer or n.integer < 1) return error.InvalidRepeat;
        _ = try required(repeat, "until");
        if (schema.get(repeat, "carry")) |carry| {
            try fields(carry, &.{ "initial", "next" });
            _ = try required(carry, "initial");
            _ = try required(carry, "next");
        }
    }
}
fn initialize(owner: Allocator) !*Package {
    const self = try owner.create(Package);
    self.* = .{ .owner = owner, .arena = std.heap.ArenaAllocator.init(owner) };
    return self;
}
pub fn fromFiles(owner: Allocator, files: []const File, manifest_path: []const u8) !*Package {
    var self = try initialize(owner);
    errdefer self.deinit();
    const a = self.arena.allocator();
    try localPath(manifest_path);
    if (!std.mem.endsWith(u8, manifest_path, ".json")) return error.PackageFormat;
    self.manifest_path = try a.dupe(u8, manifest_path);
    if (files.len == 0 or files.len > max_files) return error.PackageLimit;
    var retained = try a.alloc(File, files.len);
    var total: usize = 0;
    for (files, 0..) |f, i| {
        try localPath(f.path);
        total += f.bytes.len;
        if (total > max_bytes) return error.PackageLimit;
        retained[i] = .{ .path = try a.dupe(u8, f.path), .bytes = try a.dupe(u8, f.bytes) };
    }
    std.mem.sort(File, retained, {}, struct {
        fn less(_: void, l: File, r: File) bool {
            return std.mem.order(u8, l.path, r.path) == .lt;
        }
    }.less);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var docs: std.ArrayList(schema.Document) = .empty;
    for (retained, 0..) |f, i| {
        if (i > 0 and std.mem.eql(u8, retained[i - 1].path, f.path)) return error.DuplicateFile;
        var sizes: [16]u8 = undefined;
        std.mem.writeInt(u64, sizes[0..8], f.path.len, .big);
        std.mem.writeInt(u64, sizes[8..16], f.bytes.len, .big);
        hash.update(&sizes);
        hash.update(f.path);
        hash.update(f.bytes);
        if (std.mem.endsWith(u8, f.path, ".json")) {
            const value = try schema.parse(a, f.bytes);
            if (std.mem.eql(u8, f.path, manifest_path)) self.manifest = value else try docs.append(a, .{ .path = f.path, .value = value });
        }
    }
    if (self.manifest == .null) return error.MissingFile;
    self.files = retained;
    self.digest = try a.dupe(u8, &std.fmt.bytesToHex(hash.finalResult(), .lower));
    self.registry = .{ .alloc = a, .documents = try docs.toOwnedSlice(a) };
    try validateManifest(self);
    return self;
}
const Observed = struct { path: []const u8, stat: std.Io.File.Stat };
fn same(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.kind == b.kind and a.size == b.size and a.permissions.toMode() == b.permissions.toMode() and a.mtime.nanoseconds == b.mtime.nanoseconds and a.ctime.nanoseconds == b.ctime.nanoseconds;
}
const Snapshot = struct {
    alloc: Allocator,
    io: std.Io,
    files: std.ArrayList(File) = .empty,
    observed: std.ArrayList(Observed) = .empty,
    bytes: usize = 0,
    directories: usize = 0,
    // Installing copies a package folder, never the repository it may sit in.
    skip_git: bool = false,
    fn walk(self: *Snapshot, dir: std.Io.Dir, relative: []const u8, depth: usize) anyerror!void {
        if (depth > 128 or self.directories >= 1025) return error.PackageLimit;
        self.directories += 1;
        const before = try dir.stat(self.io);
        try self.observed.append(self.alloc, .{ .path = relative, .stat = before });
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (self.skip_git and depth == 0 and std.ascii.eqlIgnoreCase(entry.name, ".git")) continue;
            try localPath(entry.name);
            const path = if (relative.len == 0) try self.alloc.dupe(u8, entry.name) else try std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ relative, entry.name });
            const stat = try dir.statFile(self.io, entry.name, .{ .follow_symlinks = false });
            switch (stat.kind) {
                .directory => {
                    var child = try dir.openDir(self.io, entry.name, .{ .iterate = true, .follow_symlinks = false });
                    defer child.close(self.io);
                    if (!same(stat, try child.stat(self.io))) return error.PackageChanged;
                    try self.walk(child, path, depth + 1);
                },
                .file => {
                    if (self.files.items.len >= max_files or stat.size > max_bytes - self.bytes) return error.PackageLimit;
                    var f = try dir.openFile(self.io, entry.name, .{ .follow_symlinks = false });
                    defer f.close(self.io);
                    if (!same(stat, try f.stat(self.io))) return error.PackageChanged;
                    const bytes = try self.alloc.alloc(u8, @intCast(stat.size));
                    if (try f.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.PackageChanged;
                    if (!same(stat, try f.stat(self.io)) or !same(stat, try dir.statFile(self.io, entry.name, .{ .follow_symlinks = false }))) return error.PackageChanged;
                    self.bytes += bytes.len;
                    try self.files.append(self.alloc, .{ .path = path, .bytes = bytes });
                    try self.observed.append(self.alloc, .{ .path = path, .stat = stat });
                },
                .sym_link => return error.PackageSymlink,
                else => return error.PackageFile,
            }
        }
        if (!same(before, try dir.stat(self.io))) return error.PackageChanged;
    }
};
pub fn load(owner: Allocator, io: std.Io, path: []const u8) !*Package {
    return loadFolder(owner, io, path, false);
}
/// The package folder as it would be installed: the same snapshot and validation as `load`,
/// without a top-level `.git` in any case. The installer refuses one at any other depth.
pub fn loadForInstall(owner: Allocator, io: std.Io, path: []const u8) !*Package {
    return loadFolder(owner, io, path, true);
}
fn loadFolder(owner: Allocator, io: std.Io, path: []const u8, skip_git: bool) !*Package {
    var scratch = std.heap.ArenaAllocator.init(owner);
    defer scratch.deinit();
    const a = scratch.allocator();
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link) return error.PackageSymlink;
    const directory = stat.kind == .directory;
    if (!directory and (stat.kind != .file or !std.mem.endsWith(u8, path, ".json"))) return error.PackageFormat;
    const root_path = if (directory) path else std.fs.path.dirname(path) orelse ".";
    if ((try std.Io.Dir.cwd().statFile(io, root_path, .{ .follow_symlinks = false })).kind == .sym_link) return error.PackageSymlink;
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, root_path, a);
    var dir = try std.Io.Dir.openDirAbsolute(io, canonical, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var snapshot = Snapshot{ .alloc = a, .io = io, .skip_git = skip_git };
    try snapshot.walk(dir, "", 0);
    for (snapshot.observed.items) |entry| {
        const after = if (entry.path.len == 0) try dir.stat(io) else try dir.statFile(io, entry.path, .{ .follow_symlinks = false });
        if (!same(entry.stat, after)) return error.PackageChanged;
    }
    const self = try fromFiles(owner, snapshot.files.items, if (directory) "loop.json" else std.fs.path.basename(path));
    self.root = self.arena.allocator().dupe(u8, canonical) catch |err| {
        self.deinit();
        return err;
    };
    return self;
}

test "package exact retained bytes and malformed input fail before execution" {
    const manifest = "{\"format\":\"loops/0.1\",\"name\":\"counter\",\"version\":\"1\",\"inputs\":{\"schema\":{\"type\":\"integer\"}},\"steps\":[{\"id\":\"one\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"one.py\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/one/output\"}}";
    const pkg = try fromFiles(std.testing.allocator, &.{ .{ .path = "loop.json", .bytes = manifest }, .{ .path = "one.py", .bytes = "saved unchanged" } }, "loop.json");
    defer pkg.deinit();
    try std.testing.expectEqualStrings("saved unchanged", (try pkg.stepCode("one")).bytes);
    try std.testing.expectEqual(@as(usize, 64), pkg.digest.len);
    try std.testing.expectError(error.InvalidValue, pkg.validateInput(.{ .string = "wrong" }));
    try pkg.validateInput(.{ .integer = 3 });
    try std.testing.expectError(error.PackagePath, localPath("../escape.py"));
}
test "filesystem snapshot loads shipped carry package with identical digest" {
    const pkg = try load(std.testing.allocator, std.testing.io, "loops/carry-counter");
    defer pkg.deinit();
    try std.testing.expectEqualStrings("52acdbbf705ef8a7355438045f6d7fa3af40afd14334ac346391a1ae3e248d48", pkg.digest);
    const input = try schema.parse(pkg.arena.allocator(), "{\"start\":0,\"target\":2}");
    try pkg.validateInput(input);
}

test "native package rejects symlink companions and unsupported referenced schemas" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "loop.json", .data = "{}" });
    try tmp.dir.symLink(io, "loop.json", "alias.json", .{});
    var path_buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buffer);
    try std.testing.expectError(error.PackageSymlink, load(std.testing.allocator, io, path_buffer[0..n]));
    const manifest = "{\"format\":\"loops/0.1\",\"name\":\"schema\",\"version\":\"1\",\"inputs\":{\"schema\":{\"$ref\":\"unsupported.json\"}},\"steps\":[{\"id\":\"one\",\"kind\":\"infer\",\"instructions\":\"Return JSON\",\"input\":{},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/one/output\"}}";
    try std.testing.expectError(error.UnsupportedSchema, fromFiles(std.testing.allocator, &.{ .{ .path = "loop.json", .bytes = manifest }, .{ .path = "unsupported.json", .bytes = "{\"unevaluatedProperties\":false}" } }, "loop.json"));
}

inline fn testCode(comptime id: []const u8) []const u8 {
    return "{\"id\":\"" ++ id ++ "\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"c.py\",\"input\":{},\"output\":{\"schema\":true}}";
}
fn testPackage(comptime format: []const u8, comptime steps: []const u8, comptime rest: []const u8) !*Package {
    const manifest = "{\"format\":\"loops/" ++ format ++ "\",\"name\":\"n\",\"version\":\"1\",\"inputs\":{\"schema\":true},\"steps\":" ++ steps ++ ",\"output\":{\"value\":null}" ++ rest ++ "}";
    return fromFiles(std.testing.allocator, &.{ .{ .path = "loop.json", .bytes = manifest }, .{ .path = "c.py", .bytes = "" } }, "loop.json");
}
test "native package loops 0.3 composites validate at every depth and stay rejected before 0.3" {
    const nested = "[{\"id\":\"fan\",\"kind\":\"parallel\",\"branches\":{\"left\":[" ++ testCode("a") ++ "],\"right\":[{\"id\":\"each\",\"kind\":\"map\",\"over\":{\"from\":\"/input\"},\"steps\":[" ++ testCode("b") ++ "]}]}}]";
    const pkg = try testPackage("0.3", nested, "");
    defer pkg.deinit();
    try std.testing.expectEqual(@as(usize, 2), pkg.leaves.len);
    try std.testing.expectEqualStrings("c.py", (try pkg.stepCode("b")).path);
    try std.testing.expectError(error.UnknownStep, pkg.stepSchema("fan"));
    try std.testing.expectError(error.UnsupportedDefinition, testPackage("0.2", nested, ""));
    try std.testing.expectError(error.UnsupportedDefinition, testPackage("0.1", nested, ""));
    // Ids are unique across the whole package, composites included.
    try std.testing.expectError(error.DuplicateStep, testPackage("0.3", "[{\"id\":\"fan\",\"kind\":\"parallel\",\"branches\":{\"left\":[" ++ testCode("a") ++ "],\"right\":[" ++ testCode("a") ++ "]}}]", ""));
    try std.testing.expectError(error.DuplicateStep, testPackage("0.3", "[" ++ testCode("a") ++ ",{\"id\":\"a\",\"kind\":\"map\",\"over\":[],\"steps\":[" ++ testCode("b") ++ "]}]", ""));
    // Path delimiters never appear in a 0.3 id or branch name; earlier formats keep their rule.
    inline for (.{ "a/b", "a[0", "a]" }) |id| try std.testing.expectError(error.InvalidManifest, testPackage("0.3", "[" ++ testCode(id) ++ "]", ""));
    const slash = try testPackage("0.1", "[" ++ testCode("a/b") ++ "]", "");
    slash.deinit();
    try std.testing.expectError(error.InvalidManifest, testPackage("0.3", "[{\"id\":\"fan\",\"kind\":\"parallel\",\"branches\":{\"x]\":[" ++ testCode("a") ++ "]}}]", ""));
    try std.testing.expectError(error.InvalidManifest, testPackage("0.3", "[{\"id\":\"fan\",\"kind\":\"parallel\",\"branches\":{}}]", ""));
    try std.testing.expectError(error.InvalidManifest, testPackage("0.3", "[{\"id\":\"fan\",\"kind\":\"parallel\",\"branches\":{\"left\":[]}}]", ""));
    try std.testing.expectError(error.InvalidManifest, testPackage("0.3", "[{\"id\":\"each\",\"kind\":\"map\",\"over\":[],\"steps\":[]}]", ""));
    // The repeat region names top-level steps only.
    try std.testing.expectError(error.InvalidRepeat, testPackage("0.3", nested, ",\"repeat\":{\"from\":\"a\",\"through\":\"a\",\"until\":{\"value\":true},\"max_iterations\":1}"));
    const region = try testPackage("0.3", nested, ",\"repeat\":{\"from\":\"fan\",\"through\":\"fan\",\"until\":{\"value\":true},\"max_iterations\":1}");
    region.deinit();
}
fn testPrompt(comptime format: []const u8, comptime instructions: []const u8, prompt: []const u8) !*Package {
    const manifest = "{\"format\":\"loops/" ++ format ++ "\",\"name\":\"n\",\"version\":\"1\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"ask\",\"kind\":\"infer\",\"instructions\":" ++ instructions ++ ",\"input\":{},\"output\":{\"schema\":true}}],\"output\":{\"value\":null}}";
    return fromFiles(std.testing.allocator, &.{ .{ .path = "loop.json", .bytes = manifest }, .{ .path = "prompts/ask.md", .bytes = prompt } }, "loop.json");
}
test "native package loops 0.3 instructions file is exact package-local UTF-8 text inside the digest" {
    const text = "Exact text.\n  Kept verbatim: \xc3\xa9\n";
    const pkg = try testPrompt("0.3", "{\"file\":\"prompts/ask.md\"}", text);
    defer pkg.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const resolved = try pkg.resolved(arena.allocator(), pkg.leaves[0]);
    try std.testing.expectEqualStrings(text, resolved.object.get("instructions").?.string);
    try std.testing.expectEqualStrings("ask", resolved.object.get("id").?.string);
    // The manifest itself still names the file.
    try std.testing.expect(pkg.leaves[0].object.get("instructions").? == .object);
    const changed = try testPrompt("0.3", "{\"file\":\"prompts/ask.md\"}", "Other text.\n");
    defer changed.deinit();
    try std.testing.expect(!std.mem.eql(u8, pkg.digest, changed.digest));
    try std.testing.expectError(error.MissingFile, testPrompt("0.3", "{\"file\":\"prompts/absent.md\"}", text));
    try std.testing.expectError(error.PackagePath, testPrompt("0.3", "{\"file\":\"../ask.md\"}", text));
    try std.testing.expectError(error.PackagePath, testPrompt("0.3", "{\"file\":\"/etc/hosts\"}", text));
    try std.testing.expectError(error.InvalidManifest, testPrompt("0.3", "{\"file\":\"prompts/ask.md\"}", "\xff\xfe"));
    try std.testing.expectError(error.UnsupportedDefinition, testPrompt("0.3", "{\"file\":\"prompts/ask.md\",\"extra\":1}", text));
    try std.testing.expectError(error.InvalidManifest, testPrompt("0.2", "{\"file\":\"prompts/ask.md\"}", text));
    const plain = try testPrompt("0.3", "\"Inline.\"", text);
    defer plain.deinit();
    try std.testing.expectEqualStrings("Inline.", (try plain.resolved(arena.allocator(), plain.leaves[0])).object.get("instructions").?.string);
}

test "package loops 0.4 source declarations cover nested code and preserve 0.3 semantics" {
    const manifest = "{\"format\":\"loops/0.4\",\"name\":\"deps\",\"version\":\"1\",\"dependencies\":{\"runtimes\":{\"node\":{\"min_version\":\"22.15.0\",\"modules\":[\"fs\"]}}},\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"fan\",\"kind\":\"parallel\",\"branches\":{\"left\":[{\"id\":\"one\",\"kind\":\"code\",\"runtime\":\"node\",\"file\":\"main.mjs\",\"input\":null,\"output\":{\"schema\":true}}]}}],\"output\":null}";
    const files = [_]File{ .{ .path = "loop.json", .bytes = manifest }, .{ .path = "main.mjs", .bytes = "export default x=>x;" } };
    var pkg = try fromFiles(std.testing.allocator, &files, "loop.json");
    defer pkg.deinit();
    try std.testing.expectEqual(@as(usize, 1), pkg.leaves.len);
    const a = pkg.arena.allocator();
    const contract = try schema.parse(a, @embedFile("../../packages/loops-contract/loop-0.4.schema.json"));
    var registry: schema.Registry = .{ .alloc = a, .documents = &.{} };
    try registry.check(contract, "loop-0.4.schema.json");
    try registry.validate(contract, "loop-0.4.schema.json", pkg.manifest);
    var missing: Value = .{ .object = try pkg.manifest.object.clone(a) };
    _ = missing.object.swapRemove("dependencies");
    try std.testing.expectError(error.InvalidValue, registry.validate(contract, "loop-0.4.schema.json", missing));
}

test "package loops 0.4 rejects malformed dependencies and undeclared nested sources" {
    const Case = struct { dependencies: []const u8, expected: anyerror = error.InvalidDependencies, runtime: []const u8 = "node" };
    for ([_]Case{
        .{ .dependencies = "null" },
        .{ .dependencies = "{}" },
        .{ .dependencies = "{\"runtimes\":{}}", .expected = error.UndeclaredRuntime },
        .{ .dependencies = "{\"runtimes\":{\"node\":{\"min_version\":\"22.15\",\"modules\":[]}}}" },
        .{ .dependencies = "{\"runtimes\":{\"node\":{\"min_version\":\"22.15.0\",\"modules\":[\"fs\",\"fs\"]}}}" },
        .{ .dependencies = "{\"runtimes\":{\"\":{\"min_version\":\"22.15.0\",\"modules\":[]}}}" },
        .{ .dependencies = "{\"runtimes\":{\"node\":{\"min_version\":\"22.15.0\",\"modules\":[],\"install\":true}}}" },
        .{ .dependencies = "{\"runtimes\":{\"fh-workspace/1\":{\"min_version\":\"1.0.0\",\"modules\":[]}}}" },
    }) |case| {
        const manifest = try std.fmt.allocPrint(std.testing.allocator, "{{\"format\":\"loops/0.4\",\"name\":\"deps\",\"version\":\"1\",\"dependencies\":{s},\"inputs\":{{\"schema\":true}},\"steps\":[{{\"id\":\"each\",\"kind\":\"map\",\"over\":{{\"value\":[]}},\"steps\":[{{\"id\":\"one\",\"kind\":\"code\",\"runtime\":\"{s}\",\"file\":\"main.mjs\",\"input\":null,\"output\":{{\"schema\":true}}}}]}}],\"output\":null}}", .{ case.dependencies, case.runtime });
        defer std.testing.allocator.free(manifest);
        try std.testing.expectError(case.expected, fromFiles(std.testing.allocator, &.{ .{ .path = "loop.json", .bytes = manifest }, .{ .path = "main.mjs", .bytes = "export default x=>x;" } }, "loop.json"));
    }
    for ([_][]const u8{ "fh-workspace/1", "wasm32-wasi-json/1" }) |contract| {
        const manifest = try std.fmt.allocPrint(std.testing.allocator, "{{\"format\":\"loops/0.4\",\"name\":\"deps\",\"version\":\"1\",\"dependencies\":{{\"runtimes\":{{}}}},\"inputs\":{{\"schema\":true}},\"steps\":[{{\"id\":\"one\",\"kind\":\"code\",\"runtime\":\"{s}\",\"file\":\"op.json\",\"input\":null,\"output\":{{\"schema\":true}}}}],\"output\":null}}", .{contract});
        defer std.testing.allocator.free(manifest);
        var pkg = try fromFiles(std.testing.allocator, &.{ .{ .path = "loop.json", .bytes = manifest }, .{ .path = "op.json", .bytes = "{}" } }, "loop.json");
        defer pkg.deinit();
    }
}
