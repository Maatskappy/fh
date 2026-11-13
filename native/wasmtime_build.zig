const std = @import("std");
pub fn dependency(b: *std.Build, target: std.Build.ResolvedTarget) ?*std.Build.Dependency {
    if (target.result.os.tag == .linux and target.result.abi != .gnu) @panic("Official Wasmtime Linux archives require the GNU/glibc ABI (-Dtarget=aarch64-linux-gnu or x86_64-linux-gnu)");
    const name: []const u8 = switch (target.result.os.tag) {
        .macos => switch (target.result.cpu.arch) {
            .aarch64 => "wasmtime_aarch64_macos",
            .x86_64 => "wasmtime_x86_64_macos",
            else => @panic("Wasmtime supports macOS arm64/x86_64"),
        },
        .linux => switch (target.result.cpu.arch) {
            .aarch64 => "wasmtime_aarch64_linux",
            .x86_64 => "wasmtime_x86_64_linux",
            else => @panic("Wasmtime supports Linux arm64/x86_64"),
        },
        else => @panic("Wasmtime build target must be macOS or Linux"),
    };
    return b.lazyDependency(name, .{});
}
pub fn link(module: *std.Build.Module, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget) void {
    module.addIncludePath(dep.path("include"));
    module.addObjectFile(dep.path("lib/libwasmtime.a"));
    if (target.result.os.tag == .linux) for ([_][]const u8{ "pthread", "dl", "m", "unwind" }) |name| module.linkSystemLibrary(name, .{});
}
