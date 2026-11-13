//! Optional private runtime facts, serialized by the engine foreground lock.
const std = @import("std");
const metadata = @import("../metadata.zig");
const storage = @import("store.zig");
const schema = @import("schema.zig");
pub const name = "runtime-verification-v1.json";
const cap = 16384;
pub const Cache = struct {
    pub const Entry = struct { key: [64]u8, version: [3]u32 };
    entries: [64]Entry = undefined,
    count: usize = 0,
    next: usize = 0,
    pub fn find(self: *const Cache, key: [64]u8) ?[3]u32 {
        for (self.entries[0..self.count]) |entry| if (std.mem.eql(u8, &entry.key, &key)) return entry.version;
        return null;
    }
    pub fn remember(self: *Cache, key: [64]u8, version: [3]u32) void {
        if (self.find(key) != null) return;
        self.entries[self.next] = .{ .key = key, .version = version };
        self.next = (self.next + 1) % self.entries.len;
        self.count = @min(self.count + 1, self.entries.len);
    }
    pub fn decode(bytes: []const u8) !Cache {
        if (bytes.len > cap) return error.InvalidCache;
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const root = try schema.parse(arena.allocator(), bytes);
        if (root != .object or root.object.count() != 2) return error.InvalidCache;
        const format = root.object.get("format") orelse return error.InvalidCache;
        const entries = root.object.get("entries") orelse return error.InvalidCache;
        if (format != .string or !std.mem.eql(u8, format.string, "fh.runtime-verification/1") or entries != .array or entries.array.items.len > 64) return error.InvalidCache;
        var result: Cache = .{};
        for (entries.array.items) |entry| {
            if (entry != .object or entry.object.count() != 2) return error.InvalidCache;
            const key_value = entry.object.get("key") orelse return error.InvalidCache;
            const version_value = entry.object.get("version") orelse return error.InvalidCache;
            if (key_value != .string or key_value.string.len != 64 or version_value != .array or version_value.array.items.len != 3) return error.InvalidCache;
            for (key_value.string) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.InvalidCache;
            var version: [3]u32 = undefined;
            for (version_value.array.items, &version) |part, *number| {
                if (part != .integer or part.integer < 0 or part.integer > std.math.maxInt(u32)) return error.InvalidCache;
                number.* = @intCast(part.integer);
            }
            const code = @import("code.zig");
            if (!code.supportedVersion(.python3, version) and !code.supportedVersion(.node, version)) return error.InvalidCache;
            const key: [64]u8 = key_value.string[0..64].*;
            if (result.find(key) != null) return error.InvalidCache;
            result.remember(key, version);
        }
        return result;
    }
    pub fn load(io: std.Io, profile: []const u8) !Cache {
        var dir = try storage.openDirectory(io, profile);
        defer dir.close(io);
        try storage.privateHandle(dir.handle, false);
        var file = try safeFile(io, dir);
        defer file.close(io);
        var buffer: [1024]u8 = undefined;
        var reader = file.reader(io, &buffer);
        const bytes = try reader.interface.allocRemaining(std.heap.c_allocator, .limited(cap));
        defer std.heap.c_allocator.free(bytes);
        return decode(bytes);
    }
    pub fn save(self: *const Cache, io: std.Io, profile: []const u8) !void {
        var dir = try storage.openDirectory(io, profile);
        defer dir.close(io);
        try storage.privateHandle(dir.handle, false);
        // Refuse operator-owned unsafe objects, even when reading was a miss.
        if (safeFile(io, dir)) |file| file.close(io) else |err| if (err != error.FileNotFound) return err;
        const WireEntry = struct { key: []const u8, version: [3]u32 };
        var entries: [64]WireEntry = undefined;
        for (self.entries[0..self.count], entries[0..self.count]) |*entry, *wire| wire.* = .{ .key = &entry.key, .version = entry.version };
        const bytes = try std.json.Stringify.valueAlloc(std.heap.c_allocator, .{ .format = "fh.runtime-verification/1", .entries = entries[0..self.count] }, .{});
        defer std.heap.c_allocator.free(bytes);
        if (bytes.len > cap) return error.InvalidCache;
        var atomic = try dir.createFileAtomic(io, name, .{ .permissions = .fromMode(0o600), .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, bytes);
        try atomic.file.sync(io);
        if (safeFile(io, dir)) |file| file.close(io) else |err| if (err != error.FileNotFound) return err;
        try atomic.replace(io);
        if (metadata.syncDirectory(dir.handle) != 0) return error.CacheSyncFailed;
    }
};
fn safeFile(io: std.Io, dir: std.Io.Dir) !std.Io.File {
    // Stat before opening avoids blocking on an operator FIFO/device.
    if ((try dir.statFile(io, name, .{ .follow_symlinks = false })).kind != .file) return error.UnsafeProfile;
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false });
    errdefer file.close(io);
    try storage.privateHandle(file.handle, true);
    return file;
}
test "code durable audit cache validates complete bounded facts and private atomic roundtrip" {
    var cache: Cache = .{};
    cache.remember(@splat('a'), .{ 3, 12, 1 });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try cache.save(std.testing.io, path);
    const loaded = try Cache.load(std.testing.io, path);
    try std.testing.expectEqual([3]u32{ 3, 12, 1 }, loaded.find(@splat('a')).?);
    try std.testing.expectError(error.InvalidCache, Cache.decode("{\"format\":\"old\",\"entries\":[]}"));
    try std.testing.expectError(error.InvalidCache, Cache.decode(" " ** (cap + 1)));
    try std.testing.expectError(error.DuplicateField, Cache.decode("{\"format\":\"a\",\"format\":\"b\",\"entries\":[]}"));
    try tmp.dir.setFilePermissions(std.testing.io, name, .fromMode(0o644), .{});
    try std.testing.expectError(error.UnsafeProfile, cache.save(std.testing.io, path));
    try std.testing.expectError(error.UnsafeProfile, Cache.load(std.testing.io, path));
}

test "code durable audit cache rejects partial duplicate and unsafe entries without overwrite" {
    const io = std.testing.io;
    const a = "a" ** 64;
    const entry = "{\"key\":\"" ++ a ++ "\",\"version\":[3,12,0]}";
    const valid = "{\"format\":\"fh.runtime-verification/1\",\"entries\":[" ++ entry ++ "]}";
    _ = try Cache.decode(valid);
    try std.testing.expectError(error.DocumentLimit, Cache.decode("[" ** 129 ++ "]" ** 129));
    try std.testing.expectError(error.InvalidCache, Cache.decode("{\"format\":\"fh.runtime-verification/1\",\"entries\":[{\"key\":\"" ++ a ++ "\",\"version\":[\"3\",12,0]}]}"));
    try std.testing.expectError(error.InvalidCache, Cache.decode("{\"format\":\"fh.runtime-verification/1\",\"entries\":[" ++ entry ++ "," ++ entry ++ "]}"));
    if (Cache.decode(valid[0 .. valid.len - 1])) |_| return error.AcceptedTruncated else |_| {}
    if (Cache.decode("{\"format\":\"fh.runtime-verification/1\",\"entries\":[],\"extra\":true}")) |_| return error.AcceptedUnknown else |_| {}
    var cache: Cache = .{};
    for (0..65) |i| {
        var key = [_]u8{'a'} ** 64;
        const digits = "0123456789abcdef";
        key[0] = digits[i / 16];
        key[1] = digits[i % 16];
        cache.remember(key, .{ 3, 12, 0 });
    }
    try std.testing.expectEqual(@as(usize, 64), cache.count);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    const path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try tmp.dir.writeFile(io, .{ .sub_path = "operator", .data = "keep" });
    try tmp.dir.symLink(io, "operator", name, .{});
    try std.testing.expectError(error.UnsafeProfile, cache.save(io, path));
    try std.testing.expectError(error.UnsafeProfile, Cache.load(io, path));
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, (try tmp.dir.statFile(io, name, .{ .follow_symlinks = false })).kind);
    try tmp.dir.deleteFile(io, name);
    try tmp.dir.createDir(io, name, .fromMode(0o700));
    try std.testing.expectError(error.UnsafeProfile, cache.save(io, path));
}

test "code durable audit cache interrupted replacement preserves prior success" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    const path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var cache: Cache = .{};
    cache.remember(@splat('a'), .{ 3, 12, 0 });
    try cache.save(io, path);
    {
        var interrupted = try tmp.dir.createFileAtomic(io, name, .{ .permissions = .fromMode(0o600), .replace = true });
        defer interrupted.deinit(io);
        try interrupted.file.writeStreamingAll(io, "{\"format\":");
        try interrupted.file.sync(io);
        const prior = try Cache.load(io, path);
        try std.testing.expectEqual([3]u32{ 3, 12, 0 }, prior.find(@splat('a')).?);
    }
    const prior = try Cache.load(io, path);
    try std.testing.expectEqual(@as(usize, 1), prior.count);
}

test "native runtime cache retains actual Node interpreter version" {
    var cache = try Cache.decode("{\"format\":\"fh.runtime-verification/1\",\"entries\":[{\"key\":\"" ++ "a" ** 64 ++ "\",\"version\":[24,18,0]}]}");
    try std.testing.expectEqual([3]u32{ 24, 18, 0 }, cache.find(@splat('a')).?);
}
