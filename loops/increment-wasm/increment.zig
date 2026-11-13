//! Editable authoring source for increment.wasm (Zig 0.16.0).
const std = @import("std");
const a = std.heap.wasm_allocator;
const Iovec = extern struct { base: [*]u8, len: usize };
extern "wasi_snapshot_preview1" fn fd_read(i32, [*]const Iovec, usize, *usize) i32;
extern "wasi_snapshot_preview1" fn fd_write(i32, [*]const Iovec, usize, *usize) i32;
extern "wasi_snapshot_preview1" fn proc_exit(i32) noreturn;
pub export fn _start() void {
    run() catch proc_exit(1);
}
fn run() !void {
    var bytes: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        var n: usize = 0;
        if (fd_read(0, &.{.{ .base = &buffer, .len = buffer.len }}, 1, &n) != 0) return error.Read;
        if (n == 0) break;
        try bytes.appendSlice(a, buffer[0..n]);
    }
    const input = try std.json.parseFromSliceLeaky(struct { number: i32 }, a, bytes.items, .{});
    const output = try std.json.Stringify.valueAlloc(a, .{ .answer = input.number + 1 }, .{});
    var at: usize = 0;
    while (at < output.len) {
        var n: usize = 0;
        if (fd_write(1, &.{.{ .base = @constCast(output[at..].ptr), .len = output.len - at }}, 1, &n) != 0 or n == 0) return error.Write;
        at += n;
    }
}
