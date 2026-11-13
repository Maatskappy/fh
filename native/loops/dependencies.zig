//! Source-language requirements. Execution contracts are deliberately not languages.
const std = @import("std");
const schema = @import("schema.zig");
const Value = std.json.Value;
pub fn source(runtime: []const u8) bool {
    return !std.mem.eql(u8, runtime, "fh-workspace/1") and !std.mem.eql(u8, runtime, "wasm32-wasi-json/1");
}
pub fn version(text: []const u8) ![3]u32 {
    var parts = std.mem.splitScalar(u8, text, '.');
    var result: [3]u32 = undefined;
    for (&result) |*part| {
        const digits = parts.next() orelse return error.InvalidDependencies;
        if (digits.len == 0) return error.InvalidDependencies;
        for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidDependencies;
        part.* = std.fmt.parseInt(u32, digits, 10) catch return error.InvalidDependencies;
    }
    if (parts.next() != null) return error.InvalidDependencies;
    return result;
}
pub fn atLeast(actual: [3]u32, minimum: [3]u32) bool {
    for (actual, minimum) |a, m| {
        if (a != m) return a > m;
    }
    return true;
}
fn only(value: Value, keys: []const []const u8) !void {
    if (value != .object) return error.InvalidDependencies;
    for (value.object.keys()) |key| {
        for (keys) |allowed| if (std.mem.eql(u8, key, allowed)) break else {} else return error.InvalidDependencies;
    }
}
fn nonempty(value: Value) !void {
    if (value != .string or std.mem.trim(u8, value.string, " \t\r\n").len == 0) return error.InvalidDependencies;
}
pub fn runtimes(manifest: Value) ?Value {
    const deps = schema.get(manifest, "dependencies") orelse return null;
    return schema.get(deps, "runtimes");
}
pub fn validate(manifest: Value, leaves: []const Value) !void {
    const deps = schema.get(manifest, "dependencies") orelse return error.InvalidDependencies;
    try only(deps, &.{"runtimes"});
    const entries = runtimes(manifest) orelse return error.InvalidDependencies;
    if (entries != .object) return error.InvalidDependencies;
    var it = entries.object.iterator();
    while (it.next()) |entry| {
        try nonempty(.{ .string = entry.key_ptr.* });
        if (!source(entry.key_ptr.*)) return error.InvalidDependencies;
        try only(entry.value_ptr.*, &.{ "min_version", "modules" });
        const minimum = schema.get(entry.value_ptr.*, "min_version") orelse return error.InvalidDependencies;
        try nonempty(minimum);
        _ = try version(minimum.string);
        const modules = schema.get(entry.value_ptr.*, "modules") orelse return error.InvalidDependencies;
        if (modules != .array) return error.InvalidDependencies;
        for (modules.array.items, 0..) |module, i| {
            try nonempty(module);
            for (modules.array.items[0..i]) |prior| if (schema.equal(module, prior)) return error.InvalidDependencies;
        }
    }
    for (leaves) |step| {
        const runtime = schema.get(step, "runtime") orelse continue;
        if (source(runtime.string) and !entries.object.contains(runtime.string)) return error.UndeclaredRuntime;
    }
}
