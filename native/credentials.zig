//! Named onboarding credentials. Returned values are owned secrets: wipe with zeroAndFree.
const std = @import("std");
const io = @import("../vendor/fx/src/core/shared/io.zig");
const paths = @import("../vendor/fx/src/core/shared/profile_paths.zig");
const keychain = @import("../vendor/fx/src/core/hosts/native_keychain.zig");
pub const zeroAndFree = @import("../vendor/fx/src/core/auth/secret.zig").zeroAndFree;
pub const Presence = @import("../vendor/fx/src/core/hosts/host.zig").SecretStorePresence;

pub fn validateEnvironment(env: []const u8) !void {
    if (env.len == 0 or env.len > 128) return error.InvalidCredentialEnvironment;
    if (!std.ascii.isAlphabetic(env[0]) and env[0] != '_') return error.InvalidCredentialEnvironment;
    for (env) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidCredentialEnvironment;
}

pub fn validateKey(key: []const u8) !void {
    if (key.len == 0 or key.len > 8192) return error.InvalidCredentialKey;
    for (key) |c| if (c < 33 or c > 126) return error.InvalidCredentialKey;
}

fn serviceName(alloc: std.mem.Allocator, env: []const u8) ![]u8 {
    const home = io.getenv("HOME") orelse return error.HomeNotSet;
    const root = try paths.rootDir(alloc, home);
    defer alloc.free(root);
    if (!std.fs.path.isAbsolute(root)) return error.InvalidProfilePath;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(root, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(alloc, "FH_API_KEY_V1_{s}_{s}", .{ hex, env });
}

fn useKeychain() bool {
    return keychain.isAvailable() and !keychain.isDisabled();
}

fn openKeys(create: bool) !io.VerifiedDir {
    const home = io.getenv("HOME") orelse return error.HomeNotSet;
    var root = try paths.openCredentialRoot(home, create);
    defer root.close();
    if (create) return io.openOrCreateVerifiedPrivateDir(&root, "keys");
    const root_stat = try root.dir.stat(io.getIo());
    if (root_stat.permissions.toMode() & 0o777 != 0o700) return error.StoredKeyInsecure;
    var dir: io.VerifiedDir = .{ .dir = try root.dir.openDir(io.getIo(), "keys", .{ .iterate = true, .follow_symlinks = false }) };
    errdefer dir.close();
    const stat = try dir.dir.stat(io.getIo());
    if (stat.permissions.toMode() & 0o777 != 0o700) return error.StoredKeyInsecure;
    return dir;
}

/// Environment overrides take precedence; all returned allocations must be wiped.
pub fn load(alloc: std.mem.Allocator, env: []const u8) !?[]u8 {
    try validateEnvironment(env);
    if (io.getenv(env)) |key| {
        try validateKey(key);
        return try alloc.dupe(u8, key);
    }
    return loadSaved(alloc, env);
}

/// Reads only the profile's saved credential, ignoring environment overrides.
pub fn loadSaved(alloc: std.mem.Allocator, env: []const u8) !?[]u8 {
    try validateEnvironment(env);
    if (useKeychain()) {
        const service = try serviceName(alloc, env);
        defer alloc.free(service);
        const key = keychain.loadNamed(alloc, service) catch |err| switch (err) {
            error.KeychainItemNotFound => return null,
            else => return err,
        };
        if (key) |value| {
            errdefer zeroAndFree(alloc, value);
            try validateKey(value);
        }
        return key;
    }
    var dir = openKeys(false) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();
    return loadFromDir(alloc, &dir, env);
}

pub fn save(alloc: std.mem.Allocator, env: []const u8, key: []const u8) !void {
    try validateEnvironment(env);
    try validateKey(key);
    if (useKeychain()) {
        const service = try serviceName(alloc, env);
        defer alloc.free(service);
        return keychain.storeNamed(service, key);
    }
    var dir = try openKeys(true);
    defer dir.close();
    try io.durableReplaceVerified(alloc, &dir, env, key);
}

/// Metadata only: does not retrieve a stored secret.
pub fn presence(alloc: std.mem.Allocator, env: []const u8) !Presence {
    try validateEnvironment(env);
    if (io.getenv(env)) |key| {
        try validateKey(key);
        return .present;
    }
    return presenceSaved(alloc, env);
}

/// Metadata for the profile's saved credential, ignoring environment overrides.
pub fn presenceSaved(alloc: std.mem.Allocator, env: []const u8) !Presence {
    try validateEnvironment(env);
    if (useKeychain()) {
        const service = try serviceName(alloc, env);
        defer alloc.free(service);
        return keychain.presenceNamed(service);
    }
    var dir = openKeys(false) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer dir.close();
    var file = openPrivateFile(&dir, env) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer file.close(io.getIo());
    return .present;
}

fn openPrivateFile(dir: *io.VerifiedDir, env: []const u8) !std.Io.File {
    var file = try io.openExistingRegularFile(dir.dir, env, .read_only);
    errdefer file.close(io.getIo());
    const stat = try file.stat(io.getIo());
    if (stat.permissions.toMode() & 0o777 != 0o600) return error.StoredKeyInsecure;
    if (stat.size == 0 or stat.size > 8192) return error.InvalidCredentialKey;
    return file;
}

fn loadFromDir(alloc: std.mem.Allocator, dir: *io.VerifiedDir, env: []const u8) !?[]u8 {
    var file = openPrivateFile(dir, env) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io.getIo());
    const key = try io.readFileToEnd(alloc, &file, 8193);
    errdefer zeroAndFree(alloc, key);
    try validateKey(key);
    return key;
}

test "fh native credential validation rejects unsafe names and values" {
    try std.testing.expectError(error.InvalidCredentialEnvironment, loadSaved(std.testing.allocator, "../BAD"));
    try std.testing.expectError(error.InvalidCredentialEnvironment, presenceSaved(std.testing.allocator, "../BAD"));
    try std.testing.expectError(error.InvalidCredentialEnvironment, load(std.testing.allocator, "../BAD"));
    try std.testing.expectError(error.InvalidCredentialEnvironment, presence(std.testing.allocator, "../BAD"));
    try std.testing.expectError(error.InvalidCredentialEnvironment, save(std.testing.allocator, "../BAD", "fixture-secret"));
    try validateEnvironment("_PROVIDER_KEY2");
    for ([_][]const u8{ "", "2KEY", "../KEY", "KEY-X", "KÉY" }) |env| try std.testing.expectError(error.InvalidCredentialEnvironment, validateEnvironment(env));
    try std.testing.expectError(error.InvalidCredentialEnvironment, validateEnvironment(&([_]u8{'A'} ** 129)));
    try validateKey("test-key!~");
    for ([_][]const u8{ "", "has space", "newline\n", "\x7f", "é" }) |key| try std.testing.expectError(error.InvalidCredentialKey, validateKey(key));
    try std.testing.expectError(error.InvalidCredentialKey, validateKey(&([_]u8{'a'} ** 8193)));
}

test "fh native credential file roundtrip is private and refuses insecure files and links" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir: io.VerifiedDir = .{ .dir = try tmp.dir.openDir(io.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try std.testing.expect((try loadFromDir(std.testing.allocator, &dir, "TEST_KEY")) == null);
    try io.durableReplaceVerified(std.testing.allocator, &dir, "TEST_KEY", "fixture-secret");
    const value = (try loadFromDir(std.testing.allocator, &dir, "TEST_KEY")).?;
    defer zeroAndFree(std.testing.allocator, value);
    try std.testing.expectEqualStrings("fixture-secret", value);
    const stat = try tmp.dir.statFile(io.getIo(), "TEST_KEY", .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    const boundary = [_]u8{'x'} ** 8192;
    try io.durableReplaceVerified(std.testing.allocator, &dir, "TEST_KEY", &boundary);
    const maximum = (try loadFromDir(std.testing.allocator, &dir, "TEST_KEY")).?;
    defer zeroAndFree(std.testing.allocator, maximum);
    try std.testing.expectEqualStrings(&boundary, maximum);
    var file = try tmp.dir.openFile(io.getIo(), "TEST_KEY", .{ .mode = .read_write });
    try file.setPermissions(io.getIo(), .fromMode(0o644));
    file.close(io.getIo());
    try std.testing.expectError(error.StoredKeyInsecure, loadFromDir(std.testing.allocator, &dir, "TEST_KEY"));
    try tmp.dir.symLink(io.getIo(), "TEST_KEY", "LINK_KEY", .{});
    if (loadFromDir(std.testing.allocator, &dir, "LINK_KEY")) |linked| {
        if (linked) |key| zeroAndFree(std.testing.allocator, key);
        return error.TestExpectedError;
    } else |_| {}
    try std.testing.expectError(error.DurablePathUnsafe, io.durableReplaceVerified(std.testing.allocator, &dir, "LINK_KEY", "fixture-secret"));
}
