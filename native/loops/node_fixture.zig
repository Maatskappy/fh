//! Runs the node shim on this machine's own Node, for trusted contract fixtures and tests.
//! The app never uses this adapter: production code stays in isolated Docker.
const std = @import("std");
const code = @import("code.zig");
pub const Run = struct { exit: i64, stdout: []const u8, stderr: []const u8 };
fn exitCode(term: std.process.Child.Term) i64 {
    return if (term == .exited) term.exited else -1;
}
/// Writes `files` to a private temporary package directory and calls `entry` through
/// the same shim and arguments the container uses. Pass an arena: results are not freed.
/// Skips the calling test when this machine has no Node the runtime supports.
pub fn run(arena: std.mem.Allocator, io: std.Io, files: []const code.File, entry: []const u8, input: std.json.Value) !Run {
    const found = std.process.run(arena, io, .{ .argv = &.{ "/bin/sh", "-c", "exec node -p process.versions.node" }, .stdout_limit = .limited(256), .stderr_limit = .limited(65536) }) catch return error.SkipZigTest;
    if (exitCode(found.term) != 0) return error.SkipZigTest;
    var version: [3]u32 = undefined;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, found.stdout, " \r\n"), '.');
    for (&version) |*number| number.* = std.fmt.parseInt(u32, parts.next() orelse return error.SkipZigTest, 10) catch return error.SkipZigTest;
    if (!code.supportedVersion(.node, version)) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "package", .fromMode(0o700));
    var package = try temporary.dir.openDir(io, "package", .{});
    defer package.close(io);
    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |parent| try package.createDirPath(io, parent);
        try package.writeFile(io, .{ .sub_path = file.path, .data = file.bytes });
    }
    try temporary.dir.writeFile(io, .{ .sub_path = "input.json", .data = try std.json.Stringify.valueAlloc(arena, input, .{}) });
    const root = try package.realPathFileAlloc(io, ".", arena);
    const input_path = try temporary.dir.realPathFileAlloc(io, "input.json", arena);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "/bin/sh", "-c", "exec node \"$@\" <\"$0\"", input_path });
    try argv.appendSlice(arena, &code.nodeArguments(root, entry));
    const result = try std.process.run(arena, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1048576),
        .stderr_limit = .limited(65536),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } },
    });
    return .{ .exit = exitCode(result.term), .stdout = result.stdout, .stderr = result.stderr };
}
