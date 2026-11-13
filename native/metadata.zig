const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// Security metadata shared by native profile, package and workspace checks.
pub const Error = error{ MetadataUnavailable, FileNotFound };
pub const Metadata = if (builtin.os.tag == .linux) LinuxMetadata else std.c.Stat;
const LinuxMetadata = struct {
    dev: u64,
    ino: u64,
    uid: u32,
    mode: u32,
    nlink: u32,
    change_time: linux.statx_timestamp,
    pub fn ctime(self: @This()) linux.statx_timestamp {
        return self.change_time;
    }
};
const required: linux.STATX = .{ .TYPE = true, .MODE = true, .NLINK = true, .UID = true, .CTIME = true, .INO = true };

pub fn fstat(handle: std.posix.fd_t) Error!Metadata {
    if (builtin.os.tag == .linux) {
        var raw = std.mem.zeroes(linux.Statx);
        try linuxResult(linux.statx(handle, "", linux.AT.EMPTY_PATH, required, &raw));
        return fromLinux(&raw);
    } else {
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(handle, &stat) != 0) return libcError();
        return stat;
    }
}

pub fn fstatat(dirfd: std.posix.fd_t, path: [*:0]const u8, follow_symlinks: bool) Error!Metadata {
    if (builtin.os.tag == .linux) {
        var raw = std.mem.zeroes(linux.Statx);
        const flags: u32 = linux.AT.NO_AUTOMOUNT | @as(u32, if (follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW);
        try linuxResult(linux.statx(dirfd, path, flags, required, &raw));
        return fromLinux(&raw);
    } else {
        var stat: std.c.Stat = undefined;
        if (std.c.fstatat(dirfd, path, &stat, if (follow_symlinks) 0 else std.c.AT.SYMLINK_NOFOLLOW) != 0) return libcError();
        return stat;
    }
}

fn libcError() Error {
    return if (std.c.errno(-1) == .NOENT) error.FileNotFound else error.MetadataUnavailable;
}
fn linuxResult(result: usize) Error!void {
    switch (linux.errno(result)) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        else => return error.MetadataUnavailable,
    }
}
fn fromLinux(raw: *const linux.Statx) Error!LinuxMetadata {
    const mask: u32 = @bitCast(required);
    if (@as(u32, @bitCast(raw.mask)) & mask != mask) return error.MetadataUnavailable;
    return .{ .dev = linuxDevice(raw.dev_major, raw.dev_minor), .ino = raw.ino, .uid = raw.uid, .mode = raw.mode, .nlink = raw.nlink, .change_time = raw.ctime };
}
/// glibc bits/sysmacros.h and musl sys/sysmacros.h encode 32-bit major/minor
/// numbers in userspace's 64-bit dev_t (not the kernel's internal dev_t).
fn linuxDevice(major: u32, minor: u32) u64 {
    return ((@as(u64, major) & 0x00000fff) << 8) |
        ((@as(u64, major) & 0xfffff000) << 32) |
        (@as(u64, minor) & 0x000000ff) |
        ((@as(u64, minor) & 0xffffff00) << 12);
}

test "native metadata preserves path descriptor identity and symlink semantics" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    const file = try tmp.dir.createFile(io, "file", .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    try tmp.dir.symLink(io, "file", "link", .{});
    const fd = try fstat(file.handle);
    const path = try fstatat(tmp.dir.handle, "file", false);
    const followed = try fstatat(tmp.dir.handle, "link", true);
    const link = try fstatat(tmp.dir.handle, "link", false);
    const dir = try fstat(tmp.dir.handle);
    try std.testing.expectEqual(fd.dev, path.dev);
    try std.testing.expectEqual(fd.ino, path.ino);
    try std.testing.expectEqual(fd.ino, followed.ino);
    try std.testing.expect(link.ino != fd.ino);
    try std.testing.expectEqual(std.c.S.IFLNK, link.mode & std.c.S.IFMT);
    try std.testing.expectEqual(std.c.S.IFREG, fd.mode & std.c.S.IFMT);
    try std.testing.expectEqual(std.c.S.IFDIR, dir.mode & std.c.S.IFMT);
    try std.testing.expectEqual(std.c.getuid(), fd.uid);
    try std.testing.expectEqual(@as(u32, 0o600), fd.mode & 0o777);
    try std.testing.expectEqual(@as(u32, 1), fd.nlink);
    try std.testing.expectEqual(fd.ctime().sec, path.ctime().sec);
    try std.testing.expectEqual(fd.ctime().nsec, path.ctime().nsec);
    try std.testing.expectError(error.FileNotFound, fstatat(tmp.dir.handle, "missing", true));
    try std.testing.expectError(error.MetadataUnavailable, fstat(-1));
    try std.testing.expectError(error.MetadataUnavailable, fstatat(tmp.dir.handle, "file/child", true));
}

test "native Linux metadata requires every promised field and retains exact values" {
    var raw = std.mem.zeroes(linux.Statx);
    raw.mask = required;
    raw.dev_major = 0xffffffff;
    raw.dev_minor = 0xffffffff;
    raw.ino = 0xfedcba9876543210;
    raw.uid = 0xfedcba98;
    raw.mode = 0o104751;
    raw.nlink = 0xfedcba98;
    raw.ctime.sec = -1234567890123;
    raw.ctime.nsec = 987654321;
    const converted = try fromLinux(&raw);
    try std.testing.expectEqual(@as(u64, 0xffffffffffffffff), converted.dev);
    try std.testing.expectEqual(raw.ino, converted.ino);
    try std.testing.expectEqual(raw.uid, converted.uid);
    try std.testing.expectEqual(raw.mode, converted.mode);
    try std.testing.expectEqual(raw.nlink, converted.nlink);
    try std.testing.expectEqual(raw.ctime.sec, converted.ctime().sec);
    try std.testing.expectEqual(raw.ctime.nsec, converted.ctime().nsec);
    const bits: u32 = @bitCast(required);
    try std.testing.expectEqual(@as(u32, 0x18f), bits);
    for ([_]u32{ 1, 2, 4, 8, 0x80, 0x100 }) |bit| {
        raw.mask = @bitCast(bits & ~bit);
        try std.testing.expectError(error.MetadataUnavailable, fromLinux(&raw));
    }
    raw.mask = linux.STATX.BASIC_STATS;
    _ = try fromLinux(&raw);
}

test "native Linux device uses canonical full width userspace packing" {
    try std.testing.expectEqual(@as(u64, 0), linuxDevice(0, 0));
    try std.testing.expectEqual(@as(u64, 0xfffff), linuxDevice(0xfff, 0xff));
    try std.testing.expectEqual(@as(u64, 0x100000100000), linuxDevice(0x1000, 0x100));
    try std.testing.expectEqual(@as(u64, 0xffffffffffffffff), linuxDevice(0xffffffff, 0xffffffff));
}

test "native Linux metadata distinguishes only absence from unavailable syscalls" {
    try linuxResult(0);
    const absent: usize = @bitCast(-@as(isize, @intFromEnum(linux.E.NOENT)));
    try std.testing.expectError(error.FileNotFound, linuxResult(absent));
    for ([_]linux.E{ .INTR, .NOSYS, .ACCES, .PERM, .BADF, .INVAL, .NOTDIR, .LOOP, .NAMETOOLONG, .NOMEM }) |err| {
        const result: usize = @bitCast(-@as(isize, @intFromEnum(err)));
        try std.testing.expectError(error.MetadataUnavailable, linuxResult(result));
    }
}

/// fsync for a folder handle; 0 on success, like libc. On Linux Zig opens a folder that
/// is not iterated with O_PATH, which fsync refuses (EBADF), so the folder is opened
/// again for reading and that descriptor is synced.
pub fn syncDirectory(fd: std.c.fd_t) c_int {
    if (builtin.os.tag != .linux) return std.c.fsync(fd);
    const again = std.c.openat(fd, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (again < 0) return -1;
    defer _ = std.c.close(again);
    return std.c.fsync(again);
}

test "native directory sync accepts ordinary directory descriptors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(@as(c_int, 0), syncDirectory(tmp.dir.handle));
}
