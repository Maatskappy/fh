//! Pure transformation of an explicit snapshot. Discovered package code stays inert.
const std = @import("std");
const unicode = @import("printable.zig");
const a = std.heap.wasm_allocator;
const V = std.json.Value;
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
    const snapshot = try parse(bytes.items);
    const output = try std.json.Stringify.valueAlloc(a, try suggest(snapshot), .{});
    var at: usize = 0;
    while (at < output.len) {
        var n: usize = 0;
        if (fd_write(1, &.{.{ .base = @constCast(output[at..].ptr), .len = output.len - at }}, 1, &n) != 0 or n == 0) return error.Write;
        at += n;
    }
}
fn get(v: V, key: []const u8) V {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn has(v: V, key: []const u8) bool {
    return v == .object and v.object.contains(key);
}
fn eq(v: V, s: []const u8) bool {
    return v == .string and std.mem.eql(u8, v.string, s);
}
fn str(s: []const u8) V {
    return .{ .string = s };
}
fn object() V {
    return .{ .object = .empty };
}
fn array() V {
    return .{ .array = std.array_list.Managed(V).init(a) };
}
fn put(v: *V, key: []const u8, value: V) !void {
    try v.object.put(a, key, value);
}
fn parse(bytes: []const u8) !V {
    const value = try std.json.parseFromSliceLeaky(V, a, bytes, .{ .duplicate_field_behavior = .@"error", .allocate = .alloc_always });
    // Python preserves arbitrarily large integers, but rejects overflowing floats.
    var pending: std.ArrayList(V) = .empty;
    try pending.append(a, value);
    while (pending.pop()) |v| switch (v) {
        .number_string => |n| if (std.mem.indexOfAny(u8, n, ".eE") != null and !std.math.isFinite(try std.fmt.parseFloat(f64, n))) {
            return error.Nonfinite;
        },
        .array => |arr| try pending.appendSlice(a, arr.items),
        .object => |obj| try pending.appendSlice(a, obj.values()),
        else => {},
    };
    return value;
}
fn clean(text: []const u8, limit: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var iter = (try std.unicode.Utf8View.init(text)).iterator();
    var count: usize = 0;
    while (iter.nextCodepointSlice()) |slice| {
        if (count == limit) break;
        count += 1;
        const cp = try std.unicode.utf8Decode(slice);
        try out.appendSlice(a, if (unicode.printable(cp)) slice else " ");
    }
    return out.items;
}
fn nonblank(v: V) bool {
    if (v != .string) return false;
    var iter = (std.unicode.Utf8View.init(v.string) catch return false).iterator();
    while (iter.nextCodepoint()) |cp| if (!unicode.whitespace(cp)) return true;
    return false;
}
fn essentialStep(step: V, format: []const u8) bool {
    if (!nonblank(get(step, "id"))) return false;
    const kind = get(step, "kind");
    // Composite declarations have no input/output fields of their own.
    if (std.mem.eql(u8, format, "loops/0.3") or std.mem.eql(u8, format, "loops/0.4")) {
        if (eq(kind, "parallel")) return get(step, "branches") == .object;
        if (eq(kind, "map")) return has(step, "over") and get(step, "steps") == .array;
    }
    if (!has(step, "input") or !has(get(step, "output"), "schema")) return false;
    if (eq(kind, "code")) return nonblank(get(step, "file")) and nonblank(get(step, "runtime"));
    if (eq(kind, "infer")) return nonblank(get(step, "instructions")) or (!std.mem.eql(u8, format, "loops/0.1") and !std.mem.eql(u8, format, "loops/0.2") and has(get(step, "instructions"), "file"));
    // Discovery recognizes supported additive declarations; /check owns validation.
    if (!std.mem.eql(u8, format, "loops/0.1") and eq(kind, "decision")) return has(step, "questions");
    return false;
}
fn essential(m: V) bool {
    const format = get(m, "format");
    if (!eq(format, "loops/0.1") and !eq(format, "loops/0.2") and !eq(format, "loops/0.3") and !eq(format, "loops/0.4")) return false;
    if (!nonblank(get(m, "name")) or !nonblank(get(m, "version")) or !has(get(m, "inputs"), "schema") or !has(m, "output")) return false;
    const steps = get(m, "steps");
    if (steps != .array or steps.array.items.len == 0) return false;
    for (steps.array.items) |step| if (!essentialStep(step, format.string)) return false;
    return true;
}
fn gap(gaps: *V, message: []const u8) !void {
    for (gaps.array.items) |v| if (eq(v, message)) return;
    try gaps.array.append(str(message));
}
fn issue(issues: *V, gaps: *V, complete: *bool, path: []const u8, code: []const u8, message: []const u8) !void {
    if (issues.array.items.len >= 8) {
        complete.* = false;
        return gap(gaps, "Additional issues omitted.");
    }
    var entry = object();
    try put(&entry, "path", str(try clean(path, 256)));
    try put(&entry, "code", str(code));
    try put(&entry, "message", str(try clean(message, 256)));
    try issues.array.append(entry);
}
fn suggest(snapshot: V) !V {
    var nearby = array();
    var issues = array();
    var gaps = array();
    for (get(snapshot, "gaps").array.items) |v| try gaps.array.append(str(try clean(v.string, 256)));
    var complete = get(snapshot, "complete").bool;
    for (get(snapshot, "packages").array.items) |package| {
        const path = try clean(get(package, "path").string, 256);
        const raw = get(package, "manifest");
        if (!eq(get(package, "state"), "captured") or raw == .null) {
            complete = false;
            continue;
        }
        const manifest = parse(raw.string) catch {
            try issue(&issues, &gaps, &complete, path, "malformed_json", "loop.json is not strict JSON; use /check for the exact diagnostic.");
            continue;
        };
        if (!essential(manifest)) {
            try issue(&issues, &gaps, &complete, path, "essential_shape", "loop.json is missing an essential Loop declaration; use /check.");
            continue;
        }
        if (nearby.array.items.len < 8) {
            var entry = object();
            try put(&entry, "path", str(path));
            try put(&entry, "name", str(try clean(get(manifest, "name").string, 128)));
            try nearby.array.append(entry);
        } else {
            complete = false;
            try gap(&gaps, "Additional nearby packages omitted.");
        }
        if (!get(package, "inventoryComplete").bool) complete = false;
        for (get(package, "files").array.items) |entry| {
            if (eq(get(entry, "state"), "missing")) {
                try issue(&issues, &gaps, &complete, path, "missing_file", try std.fmt.allocPrint(a, "Referenced package file is missing: {s}", .{try clean(get(entry, "path").string, 128)}));
            } else if (!eq(get(entry, "state"), "present")) complete = false;
        }
    }
    var result = object();
    try put(&result, "suggestion", str(if (issues.array.items.len > 0) "A nearby Loop has an obvious issue. Use /check to inspect it." else if (nearby.array.items.len > 0) "Found nearby Loops. Use /check on a package, then /run when ready." else if (complete) "Describe a repeatable task and I can help you create a Loop here." else "Workspace context is partial. Describe a task or use /check on a known package."));
    try put(&result, "nearbyLoops", nearby);
    try put(&result, "issues", issues);
    try put(&result, "complete", .{ .bool = complete });
    gaps.array.shrinkRetainingCapacity(@min(gaps.array.items.len, 32));
    try put(&result, "gaps", gaps);
    return result;
}
