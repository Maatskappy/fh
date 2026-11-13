//! Bounded, inert startup capture. Discovered code is never read or executed.
const std = @import("std");
const schema = @import("schema.zig");
const storage = @import("store.zig");
const Value = std.json.Value;
fn object() Value {
    return .{ .object = .{} };
}
fn array(a: std.mem.Allocator) Value {
    return .{ .array = std.array_list.Managed(Value).init(a) };
}
fn str(s: []const u8) Value {
    return .{ .string = s };
}
fn put(a: std.mem.Allocator, o: *Value, k: []const u8, v: Value) !void {
    try o.object.put(a, k, v);
}
fn clean(a: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var count: usize = 0;
    while (i < text.len and count < max) : (count += 1) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            try out.append(a, ' ');
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            try out.append(a, ' ');
            i += 1;
            continue;
        };
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or cp == 0x2028 or cp == 0x2029) try out.append(a, ' ') else try out.appendSlice(a, text[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice(a);
}
const Capture = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cancel: *const std.atomic.Value(bool),
    deadline: i64,
    snapshot: Value,
    inventory: usize = 0,
    fn check(self: *Capture) !void {
        if (self.cancel.load(.acquire)) return error.Cancelled;
        if (std.Io.Clock.awake.now(self.io).toMilliseconds() >= self.deadline) return error.TimeLimit;
    }
    fn gap(self: *Capture, message: []const u8) !void {
        self.snapshot.object.getPtr("complete").?.* = .{ .bool = false };
        const gaps = self.snapshot.object.getPtr("gaps").?;
        for (gaps.array.items) |v| if (std.mem.eql(u8, v.string, message)) return;
        if (gaps.array.items.len < 32) try gaps.array.append(str(message));
    }
    fn limited(self: *Capture) !bool {
        const bytes = try std.json.Stringify.valueAlloc(self.alloc, self.snapshot, .{});
        defer self.alloc.free(bytes);
        return bytes.len > 65536;
    }
    fn reference(self: *Capture, dir: std.Io.Dir, name: []const u8) ![]const u8 {
        try self.check();
        @import("package.zig").localPath(name) catch return "unsafe";
        var parts = std.mem.splitScalar(u8, name, '/');
        var current = dir;
        var owned = false;
        defer if (owned) current.close(self.io);
        var part = parts.next() orelse return "unsafe";
        while (parts.next()) |next| {
            try self.check();
            const child = current.openDir(self.io, part, .{ .follow_symlinks = false }) catch |err| return if (err == error.FileNotFound) "missing" else "unsafe";
            if (owned) current.close(self.io);
            current = child;
            owned = true;
            part = next;
        }
        const stat = current.statFile(self.io, part, .{ .follow_symlinks = false }) catch |err| return if (err == error.FileNotFound) "missing" else "unknown";
        try self.check();
        return if (stat.kind == .file) "present" else "unsafe";
    }
    fn files(self: *Capture, dir: std.Io.Dir, entry: *Value, manifest: Value) !void {
        var refs: std.StringHashMapUnmanaged(void) = .{};
        if (schema.get(manifest, "inputs")) |v| if (schema.get(v, "schema")) |s| if (s == .string) {
            try refs.put(self.alloc, s.string, {});
        };
        if (schema.get(manifest, "steps")) |steps| if (steps == .array) for (steps.array.items) |step| {
            if (schema.get(step, "output")) |v| if (schema.get(v, "schema")) |s| if (s == .string) {
                try refs.put(self.alloc, s.string, {});
            };
            if (schema.get(step, "kind")) |k| if (k == .string and std.mem.eql(u8, k.string, "code")) {
                if (schema.get(step, "file")) |s| if (s == .string) {
                    try refs.put(self.alloc, s.string, {});
                };
            };
        };
        var it = refs.keyIterator();
        while (it.next()) |name| {
            if (self.inventory >= 128) {
                entry.object.getPtr("inventoryComplete").?.* = .{ .bool = false };
                try self.gap("Referenced-file inventory limit reached.");
                break;
            }
            self.inventory += 1;
            const state = try self.reference(dir, name.*);
            var f = object();
            try put(self.alloc, &f, "path", str(try clean(self.alloc, name.*, 256)));
            try put(self.alloc, &f, "state", str(state));
            try entry.object.getPtr("files").?.array.append(f);
            if (std.mem.eql(u8, state, "unsafe") or std.mem.eql(u8, state, "unknown")) {
                entry.object.getPtr("inventoryComplete").?.* = .{ .bool = false };
                try self.gap("Some referenced files could not be safely inspected.");
            }
        }
    }
    fn package(self: *Capture, dir: std.Io.Dir, label: []const u8) !void {
        try self.check();
        const stat = dir.statFile(self.io, "loop.json", .{ .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound) return;
            try self.gap("A nearby manifest could not be inspected.");
            return;
        };
        const packages = self.snapshot.object.getPtr("packages").?;
        if (packages.array.items.len >= 16) {
            try self.gap("Nearby package limit reached.");
            return;
        }
        var entry = object();
        try put(self.alloc, &entry, "path", str(try clean(self.alloc, label, 256)));
        try put(self.alloc, &entry, "manifest", .null);
        try put(self.alloc, &entry, "state", str("captured"));
        try put(self.alloc, &entry, "files", array(self.alloc));
        try put(self.alloc, &entry, "inventoryComplete", .{ .bool = true });
        try packages.array.append(entry);
        const saved = &packages.array.items[packages.array.items.len - 1];
        if (stat.kind != .file or stat.size > 8192) {
            saved.object.getPtr("state").?.* = str(if (stat.kind != .file) "unsafe" else "oversized");
            saved.object.getPtr("inventoryComplete").?.* = .{ .bool = false };
            try self.gap("A manifest was unsafe or oversized.");
            return;
        }
        var file = dir.openFile(self.io, "loop.json", .{ .follow_symlinks = false }) catch {
            saved.object.getPtr("state").?.* = str("unreadable");
            try self.gap("A manifest could not be read.");
            return;
        };
        defer file.close(self.io);
        const opened = try file.stat(self.io);
        if (opened.inode != stat.inode or opened.kind != .file or opened.size != stat.size) return error.PackageChanged;
        const bytes = try self.alloc.alloc(u8, @intCast(stat.size));
        const n = try file.readPositionalAll(self.io, bytes, 0);
        try self.check();
        const after = try file.stat(self.io);
        if (n != bytes.len or after.size != stat.size or after.mtime.nanoseconds != stat.mtime.nanoseconds or after.ctime.nanoseconds != stat.ctime.nanoseconds or !std.unicode.utf8ValidateSlice(bytes)) {
            saved.object.getPtr("state").?.* = str("unreadable");
            try self.gap("A manifest changed or was not UTF-8.");
            return;
        }
        saved.object.getPtr("manifest").?.* = str(bytes);
        if (try self.limited()) {
            saved.object.getPtr("manifest").?.* = .null;
            saved.object.getPtr("state").?.* = str("oversized");
            saved.object.getPtr("inventoryComplete").?.* = .{ .bool = false };
            try self.gap("Workspace snapshot byte limit reached.");
            return;
        }
        const parsed = schema.parse(self.alloc, bytes) catch return;
        try self.files(dir, saved, parsed);
    }
    fn walk(self: *Capture, root: []const u8) !void {
        try self.check();
        var dir = try storage.openDirectory(self.io, root);
        defer dir.close(self.io);
        try self.package(dir, ".");
        inline for (.{ "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "README.md", "Makefile", "build.zig" }) |marker| {
            try self.check();
            const state = try self.reference(dir, marker);
            if (std.mem.eql(u8, state, "present")) try self.snapshot.object.getPtr("markers").?.array.append(str(marker));
        }
        var loops = dir.openDir(self.io, "loops", .{ .iterate = true, .follow_symlinks = false }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer loops.close(self.io);
        var it = loops.iterate();
        var entries: usize = 0;
        while (try it.next(self.io)) |entry| {
            try self.check();
            entries += 1;
            if (entries > 64) {
                try self.gap("Nearby directory entry limit reached.");
                break;
            }
            if (entry.kind == .sym_link) {
                try self.gap("A symlink under loops was skipped.");
                continue;
            }
            if (entry.kind != .directory) continue;
            if (self.snapshot.object.getPtr("packages").?.array.items.len >= 16) {
                try self.gap("Nearby package limit reached.");
                break;
            }
            var child = loops.openDir(self.io, entry.name, .{ .follow_symlinks = false }) catch {
                try self.gap("A nearby package could not be opened safely.");
                continue;
            };
            defer child.close(self.io);
            try self.package(child, try std.fmt.allocPrint(self.alloc, "loops/{s}", .{entry.name}));
        }
    }
};
pub fn capture(alloc: std.mem.Allocator, io: std.Io, root: []const u8, cancel: *const std.atomic.Value(bool), deadline_ms: i64) !Value {
    var snapshot = object();
    try put(alloc, &snapshot, "format", str("fh.workspace-snapshot/0.1"));
    try put(alloc, &snapshot, "workspace", str(try clean(alloc, std.fs.path.basename(root), 256)));
    try put(alloc, &snapshot, "markers", array(alloc));
    try put(alloc, &snapshot, "packages", array(alloc));
    try put(alloc, &snapshot, "complete", .{ .bool = true });
    try put(alloc, &snapshot, "gaps", array(alloc));
    var state = Capture{ .alloc = alloc, .io = io, .cancel = cancel, .deadline = @min(deadline_ms, std.Io.Clock.awake.now(io).toMilliseconds() + 20), .snapshot = snapshot };
    state.walk(root) catch |err| {
        try state.gap(switch (err) {
            error.Cancelled => "Workspace capture cancelled.",
            error.TimeLimit => "Workspace capture deadline reached.",
            else => "Workspace directories could not be safely inspected.",
        });
    };
    while (try state.limited()) {
        const packages = state.snapshot.object.getPtr("packages").?;
        if (packages.array.items.len == 0) return error.SnapshotLimit;
        _ = packages.array.pop();
        try state.gap("Workspace snapshot byte limit reached.");
    }
    return state.snapshot;
}
test "native workspace captures inert packages and missing companions without executing code" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "loops/example");
    try tmp.dir.writeFile(io, .{ .sub_path = "loops/example/loop.json", .data = "{\"inputs\":{\"schema\":true},\"steps\":[{\"kind\":\"code\",\"file\":\"missing.py\"}]}" });
    var buffer: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    const value = try capture(arena.allocator(), io, buffer[0..n], &cancel, std.Io.Clock.awake.now(io).toMilliseconds() + 1000);
    const packages = value.object.get("packages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), packages.len);
    const files = packages[0].object.get("files").?.array.items;
    try std.testing.expectEqualStrings("missing", files[0].object.get("state").?.string);
    cancel.store(true, .release);
    const cancelled = try capture(arena.allocator(), io, buffer[0..n], &cancel, std.Io.Clock.awake.now(io).toMilliseconds() + 1000);
    try std.testing.expect(!cancelled.object.get("complete").?.bool);
}
