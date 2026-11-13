//! wasm32-wasi-json/1: portable bytes only, no inherited WASI capabilities.
const std = @import("std");
const code = @import("code.zig");
const runner = @import("runner.zig");
const Issue = @import("runtime_policy.zig").Issue;
const Diagnostic = struct {
    issue: *Issue,
    path: []const u8,
    expected: []const u8,
    fn reject(self: Diagnostic, reason: []const u8, module: ?[]const u8, field: ?[]const u8, err: anyerror) anyerror {
        // Reuse the existing owned issue bound; do not add a runtime limit.
        var buffer: @FieldType(Issue, "message_buffer") = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.writeAll(reason) catch {};
        for ([_]?[]const u8{ module, field }) |text| if (text) |value| {
            writer.writeByte(' ') catch {};
            std.json.Stringify.value(value, .{ .escape_unicode = true }, &writer) catch {};
        };
        return self.issue.reject(self.path, self.expected, writer.buffered(), err);
    }
};
fn rejected(diagnostic: ?Diagnostic, reason: []const u8, module: ?[]const u8, field: ?[]const u8, err: anyerror) anyerror {
    return if (diagnostic) |d| d.reject(reason, module, field, err) else err;
}
const c = @cImport({
    @cInclude("wasmtime.h");
    @cInclude("wasi.h");
});
pub const runtime = "wasm32-wasi-json/1";
pub const engine_version = "48.0.8";
// Wasmtime stores MVP funcref table slots as native pointers.
const table_elements_limit = code.memory_limit / @sizeOf(usize);
const Allocator = std.mem.Allocator;

fn check(io: std.Io, cancel: *const std.atomic.Value(bool), deadline: i64) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
    if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.TimeLimit;
}
fn engineNew() !*c.wasm_engine_t {
    const config = c.wasm_config_new() orelse return error.OutOfMemory;
    c.wasmtime_config_epoch_interruption_set(config, true);
    inline for (.{ "threads", "tail_call", "function_references", "gc", "simd", "relaxed_simd", "multi_memory", "memory64", "wide_arithmetic", "branch_hinting", "exceptions", "custom_page_sizes", "stack_switching", "component_model" }) |feature| {
        @field(c, "wasmtime_config_wasm_" ++ feature ++ "_set")(config, false);
    }
    c.wasmtime_config_wasm_reference_types_set(config, true);
    c.wasmtime_config_wasm_bulk_memory_set(config, true);
    c.wasmtime_config_wasm_multi_value_set(config, true);
    return c.wasm_engine_new_with_config(config) orelse error.OutOfMemory;
}
fn name(value: [*c]const c.wasm_name_t) []const u8 {
    return value.*.data[0..value.*.size];
}
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn signature(ty: ?*const c.wasm_externtype_t, params: []const u8, results: []const u8) bool {
    if (c.wasm_externtype_kind(ty) != c.WASM_EXTERN_FUNC) return false;
    const ft = c.wasm_externtype_as_functype_const(ty);
    const p = c.wasm_functype_params(ft).*;
    const r = c.wasm_functype_results(ft).*;
    if (p.size != params.len or r.size != results.len) return false;
    for (params, 0..) |kind, i| if (c.wasm_valtype_kind(p.data[i]) != kind) return false;
    for (results, 0..) |kind, i| if (c.wasm_valtype_kind(r.data[i]) != kind) return false;
    return true;
}
fn interfaces(module: *c.wasmtime_module_t, diagnostic: ?Diagnostic) !void {
    var imports: c.wasm_importtype_vec_t = undefined;
    c.wasmtime_module_imports(module, &imports);
    defer c.wasm_importtype_vec_delete(&imports);
    for (imports.data[0..imports.size]) |item| {
        const m = name(c.wasm_importtype_module(item));
        if (!same(m, "wasi_snapshot_preview1")) return rejected(diagnostic, "unsupported import module", m, name(c.wasm_importtype_name(item)), error.WasmImport);
        const n = name(c.wasm_importtype_name(item));
        const params: []const u8 = if (same(n, "fd_seek")) &.{ c.WASM_I32, c.WASM_I64, c.WASM_I32, c.WASM_I32 } else if (same(n, "fd_read") or same(n, "fd_write")) &([_]u8{c.WASM_I32} ** 4) else if (same(n, "args_get") or same(n, "args_sizes_get") or same(n, "environ_get") or same(n, "environ_sizes_get") or same(n, "fd_fdstat_get")) &([_]u8{c.WASM_I32} ** 2) else if (same(n, "fd_close") or same(n, "proc_exit")) &.{c.WASM_I32} else return rejected(diagnostic, "unsupported import", m, n, error.WasmImport);
        if (!signature(c.wasm_importtype_type(item), params, if (same(n, "proc_exit")) &.{} else &.{c.WASM_I32})) return rejected(diagnostic, "import signature differs from profile", m, n, error.WasmImport);
    }
    var exports: c.wasm_exporttype_vec_t = undefined;
    c.wasmtime_module_exports(module, &exports);
    defer c.wasm_exporttype_vec_delete(&exports);
    var start = false;
    var memory = false;
    for (exports.data[0..exports.size]) |item| {
        const n = name(c.wasm_exporttype_name(item));
        const ty = c.wasm_exporttype_type(item);
        if (same(n, "_start")) {
            if (!signature(ty, &.{}, &.{})) return rejected(diagnostic, "_start must be a function () -> ()", null, null, error.WasmEntrypoint);
            start = true;
        }
        if (same(n, "memory")) {
            if (c.wasm_externtype_kind(ty) != c.WASM_EXTERN_MEMORY) return rejected(diagnostic, "memory export is not a linear memory", null, null, error.WasmMemory);
            memory = true;
        }
    }
    if (!start) return rejected(diagnostic, "missing _start: () -> () export", null, null, error.WasmEntrypoint);
    if (!memory) return rejected(diagnostic, "missing memory export", null, null, error.WasmMemory);
}
// Wasmtime validates the entire binary first. Inspect only declaration envelopes,
// including unexported tables/memories, before linking or running any guest code.
const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,
    fn byte(self: *Cursor) !u8 {
        if (self.at >= self.bytes.len) return error.InvalidWasm;
        defer self.at += 1;
        return self.bytes[self.at];
    }
    fn uleb(self: *Cursor) !u32 {
        var n: u32 = 0;
        for (0..5) |i| {
            const b = try self.byte();
            if (i == 4 and b > 15) return error.InvalidWasm;
            n |= @as(u32, b & 127) << @as(u5, @intCast(i * 7));
            if (b & 128 == 0) return n;
        }
        return error.InvalidWasm;
    }
};
fn envelope(bytes: []const u8) !void {
    var all: Cursor = .{ .bytes = bytes, .at = 8 };
    while (all.at < bytes.len) {
        const id = try all.byte();
        const size = try all.uleb();
        if (size > bytes.len - all.at) return error.InvalidWasm;
        var section: Cursor = .{ .bytes = bytes[all.at..][0..size] };
        all.at += size;
        if (id == 4) {
            const count = try section.uleb();
            if (count > 1) return error.WasmTable;
            if (count == 1) {
                if (try section.byte() != 0x70) return error.WasmTable;
                if (try section.uleb() > 1) return error.WasmTable;
                if (try section.uleb() > table_elements_limit) return error.WasmTable;
            }
        }
        if (id == 5) {
            if (try section.uleb() != 1) return error.WasmMemory;
            const flags = try section.uleb();
            if (flags > 1) return error.WasmMemory;
            if (@as(u64, try section.uleb()) * 65536 > code.memory_limit) return error.WasmMemory;
        }
    }
}
const Prepared = struct {
    engine: *c.wasm_engine_t,
    module: *c.wasmtime_module_t,
    linker: *c.wasmtime_linker_t,
    pre: *c.wasmtime_instance_pre_t,
    fn deinit(self: Prepared) void {
        c.wasmtime_instance_pre_delete(self.pre);
        c.wasmtime_linker_delete(self.linker);
        c.wasmtime_module_delete(self.module);
        c.wasm_engine_delete(self.engine);
    }
};
fn prepare(bytes: []const u8, io: std.Io, cancel: *const std.atomic.Value(bool), deadline: i64, diagnostic: ?Diagnostic) !Prepared {
    try check(io, cancel, deadline);
    const engine = try engineNew();
    errdefer c.wasm_engine_delete(engine);
    var module: ?*c.wasmtime_module_t = null;
    const failure = c.wasmtime_module_new(engine, bytes.ptr, bytes.len, &module);
    if (failure) |err| {
        defer c.wasmtime_error_delete(err);
        var message: c.wasm_name_t = undefined;
        c.wasmtime_error_message(err, &message);
        defer c.wasm_name_delete(&message);
        try check(io, cancel, deadline);
        return rejected(diagnostic, "invalid module or unsupported feature", name(&message), null, error.InvalidWasm);
    }
    errdefer c.wasmtime_module_delete(module.?);
    try check(io, cancel, deadline);
    try interfaces(module.?, diagnostic);
    envelope(bytes) catch |err| return rejected(diagnostic, switch (err) {
        error.WasmMemory => "memory declaration must be one unshared wasm32 memory, initial size <= 128 MiB",
        error.WasmTable => "table declaration must be at most one funcref table within the profile element limit",
        else => "invalid module declaration envelope",
    }, null, null, err);
    const linker = c.wasmtime_linker_new(engine) orelse return error.OutOfMemory;
    errdefer c.wasmtime_linker_delete(linker);
    if (c.wasmtime_linker_define_wasi(linker)) |err| {
        c.wasmtime_error_delete(err);
        return rejected(diagnostic, "WASI linker initialization failed", null, null, error.WasmImport);
    }
    var pre: ?*c.wasmtime_instance_pre_t = null;
    if (c.wasmtime_linker_instantiate_pre(linker, module, &pre)) |err| {
        c.wasmtime_error_delete(err);
        return rejected(diagnostic, "imports cannot be linked to the profile signatures", null, null, error.WasmImport);
    }
    errdefer c.wasmtime_instance_pre_delete(pre.?);
    try check(io, cancel, deadline);
    return .{ .engine = engine, .module = module.?, .linker = linker, .pre = pre.? };
}
pub fn preflight(bytes: []const u8, io: std.Io, cancel: *const std.atomic.Value(bool), deadline: i64) !void {
    const prepared = try prepare(bytes, io, cancel, deadline, null);
    defer prepared.deinit();
}
pub fn preflightDiagnostic(bytes: []const u8, io: std.Io, cancel: *const std.atomic.Value(bool), deadline: i64, issue: *Issue, path: []const u8, expected: []const u8) !void {
    const prepared = try prepare(bytes, io, cancel, deadline, .{ .issue = issue, .path = path, .expected = expected });
    defer prepared.deinit();
}
const Stream = struct {
    alloc: Allocator,
    max: usize,
    bytes: std.ArrayList(u8) = .empty,
    overflow: bool = false,
    oom: bool = false,
    fn write(raw: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) isize {
        const self: *Stream = @ptrCast(@alignCast(raw.?));
        if (len > self.max - self.bytes.items.len) {
            self.overflow = true;
            return -1;
        }
        self.bytes.appendSlice(self.alloc, data[0..len]) catch {
            self.oom = true;
            return -1;
        };
        return @intCast(len);
    }
};
const Watcher = struct {
    engine: *c.wasm_engine_t,
    io: std.Io,
    cancel: *const std.atomic.Value(bool),
    deadline: i64,
    done: std.atomic.Value(bool) = .init(false),
    fn run(self: *Watcher) void {
        while (!self.done.load(.acquire)) {
            check(self.io, self.cancel, self.deadline) catch {
                c.wasmtime_engine_increment_epoch(self.engine);
                return;
            };
            std.Io.sleep(self.io, .fromMilliseconds(25), .awake) catch {};
        }
    }
};
fn guestResult(err: ?*c.wasmtime_error_t, trap: ?*c.wasm_trap_t) !void {
    defer if (err) |e| c.wasmtime_error_delete(e);
    defer if (trap) |t| c.wasm_trap_delete(t);
    if (err) |e| {
        var status: c_int = undefined;
        if (c.wasmtime_error_exit_status(e, &status)) {
            if (status == 0) return;
            return error.CodeExit;
        }
        return error.WasmTrap;
    }
    if (trap != null) return error.WasmTrap;
}
fn invoke(alloc: Allocator, io: std.Io, request: runner.StepRequest, bytes: []const u8) !runner.Value {
    const prepared = try prepare(bytes, io, request.cancel, request.deadline_ms, null);
    defer prepared.deinit();
    var stdout: Stream = .{ .alloc = alloc, .max = request.limits.max_output_bytes };
    defer stdout.bytes.deinit(alloc);
    var stderr: Stream = .{ .alloc = alloc, .max = request.limits.max_diagnostic_bytes };
    defer stderr.bytes.deinit(alloc);
    const store = c.wasmtime_store_new(prepared.engine, null, null) orelse return error.OutOfMemory;
    defer c.wasmtime_store_delete(store);
    c.wasmtime_store_limiter(store, code.memory_limit, table_elements_limit, 1, 1, 1);
    const context = c.wasmtime_store_context(store);
    c.wasmtime_context_set_epoch_deadline(context, 1);
    const input = try std.json.Stringify.valueAlloc(alloc, request.input, .{});
    defer alloc.free(input);
    if (input.len > request.limits.max_output_bytes) return error.OutputLimit;
    const wasi = c.wasi_config_new() orelse return error.OutOfMemory;
    var argv = [_][*c]const u8{"fh-wasm"};
    if (!c.wasi_config_set_argv(wasi, 1, &argv)) {
        c.wasi_config_delete(wasi);
        return error.OutOfMemory;
    }
    var input_vec: c.wasm_byte_vec_t = undefined;
    c.wasm_byte_vec_new(&input_vec, input.len, input.ptr);
    c.wasi_config_set_stdin_bytes(wasi, &input_vec);
    c.wasi_config_set_stdout_custom(wasi, Stream.write, &stdout, null);
    c.wasi_config_set_stderr_custom(wasi, Stream.write, &stderr, null);
    if (c.wasmtime_context_set_wasi(context, wasi)) |err| {
        c.wasmtime_error_delete(err);
        return error.WasmTrap;
    }
    var watcher: Watcher = .{ .engine = prepared.engine, .io = io, .cancel = request.cancel, .deadline = request.deadline_ms };
    const thread = try std.Thread.spawn(.{}, Watcher.run, .{&watcher});
    defer {
        watcher.done.store(true, .release);
        thread.join();
    }
    try check(io, request.cancel, request.deadline_ms);
    var instance: c.wasmtime_instance_t = undefined;
    var trap: ?*c.wasm_trap_t = null;
    const instantiate_error = c.wasmtime_instance_pre_instantiate(prepared.pre, context, &instance, &trap);
    const instantiated = instantiate_error == null and trap == null;
    var failure: ?anyerror = null;
    guestResult(instantiate_error, trap) catch |err| {
        failure = err;
    };
    if (instantiated) {
        var start: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_instance_export_get(context, &instance, "_start", 6, &start)) return error.WasmEntrypoint;
        defer c.wasmtime_extern_delete(&start);
        trap = null;
        const call_error = c.wasmtime_func_call(context, &start.of.func, null, 0, null, 0, &trap);
        guestResult(call_error, trap) catch |err| {
            failure = err;
        };
    }
    try check(io, request.cancel, request.deadline_ms);
    if (stdout.overflow or stderr.overflow) return error.OutputLimit;
    if (stdout.oom or stderr.oom) return error.OutOfMemory;
    if (failure) |err| return err;
    return code.parse(alloc, stdout.bytes.items, request.limits.max_output_bytes);
}
pub fn execute(alloc: Allocator, io: std.Io, request: runner.StepRequest, bytes: []const u8) !runner.StepResult {
    const identity: runner.CodeExecution = .{ .artifact_sha256 = try alloc.dupe(u8, &code.hash(bytes)), .profile = runtime, .engine = "wasmtime", .engine_version = engine_version };
    // Stream buffers and parse scratch must not accumulate in the run's arena.
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    const output = invoke(temporary, io, request, bytes) catch |err| return .{ .failure = err, .code_execution = identity };
    const serialized = std.json.Stringify.valueAlloc(temporary, output, .{}) catch |err| return .{ .failure = err, .code_execution = identity };
    const retained = code.parse(alloc, serialized, request.limits.max_output_bytes) catch |err| return .{ .failure = err, .code_execution = identity };
    return .{ .output = retained, .code_execution = identity };
}

const Test = struct {
    fn journal(_: *anyopaque, _: runner.Effect) !void {
        return error.UnexpectedEffect;
    }
    fn request(cancel: *std.atomic.Value(bool)) runner.StepRequest {
        return .{ .run_id = "wasm", .step_id = "transform", .iteration = 0, .definition = .null, .input = .null, .selection = .{}, .response_schema = .{ .bool = true }, .limits = .{}, .cancel = cancel, .deadline_ms = std.math.maxInt(i64), .journal = .{ .context = cancel, .recordFn = journal } };
    }
};
test "native Wasm retained C and WAT JSON transforms and identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    var request = Test.request(&cancel);
    request.input = try code.parse(a, "{\"n\":4}", 100);
    inline for (.{ "transform", "transform-c", "exit-zero", "growth", "table-growth", "no-capabilities" }) |file| {
        const bytes = @embedFile("fixtures/wasm/" ++ file ++ ".wasm");
        const result = try execute(a, std.testing.io, request, bytes);
        if (result.failure) |err| {
            std.debug.print("{s}: {s}\n", .{ file, @errorName(err) });
            return err;
        }
        try std.testing.expectEqual(@as(i64, 5), (try runner.get(result.output, "n")).integer);
        try std.testing.expectEqualStrings(&code.hash(bytes), result.code_execution.?.artifact_sha256);
        try std.testing.expectEqual(@as(usize, 0), result.effects.len);
    }
}
test "native Wasm preflight rejects unreachable imports signatures corrupt artifacts and envelopes" {
    var cancel = std.atomic.Value(bool).init(false);
    inline for (.{ "random", "clock", "filesystem", "network", "bad-signature", "seek-signature", "memory-import", "wrong-module" }) |file| {
        try std.testing.expectError(error.WasmImport, preflight(@embedFile("fixtures/wasm/" ++ file ++ ".wasm"), std.testing.io, &cancel, std.math.maxInt(i64)));
    }
    inline for (.{ "shared-memory", "memory64", "multi-memory" }) |file| try std.testing.expectError(error.InvalidWasm, preflight(@embedFile("fixtures/wasm/" ++ file ++ ".wasm"), std.testing.io, &cancel, std.math.maxInt(i64)));
    try std.testing.expectError(error.WasmTable, preflight(@embedFile("fixtures/wasm/externref-table.wasm"), std.testing.io, &cancel, std.math.maxInt(i64)));
    try std.testing.expectError(error.WasmEntrypoint, preflight(@embedFile("fixtures/wasm/bad-start.wasm"), std.testing.io, &cancel, std.math.maxInt(i64)));
    try std.testing.expectError(error.WasmMemory, preflight(@embedFile("fixtures/wasm/memory-too-large.wasm"), std.testing.io, &cancel, std.math.maxInt(i64)));
    try std.testing.expectError(error.InvalidWasm, preflight("garbage", std.testing.io, &cancel, std.math.maxInt(i64)));
    const bytes = @embedFile("fixtures/wasm/transform.wasm");
    try std.testing.expectError(error.InvalidWasm, preflight(bytes[0 .. bytes.len - 1], std.testing.io, &cancel, std.math.maxInt(i64)));
    try std.testing.expectError(error.WasmTable, preflight(@embedFile("fixtures/wasm/table-too-large.wasm"), std.testing.io, &cancel, std.math.maxInt(i64)));
    try preflight(@embedFile("fixtures/wasm/hidden-table.wasm"), std.testing.io, &cancel, std.math.maxInt(i64));
    // Linking preflight never executes a start function.
    try preflight(@embedFile("fixtures/wasm/start-loop.wasm"), std.testing.io, &cancel, std.math.maxInt(i64));
}
test "native Wasm traps exits and guest-handled overflow retain identity but no output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var request = Test.request(&cancel);
    inline for (.{ "trap", "oob", "start-trap", "exit", "overflow" }) |file| {
        request.limits.max_output_bytes = 7;
        const result = try execute(arena.allocator(), std.testing.io, request, @embedFile("fixtures/wasm/" ++ file ++ ".wasm"));
        try std.testing.expectEqual(if (same(file, "exit")) error.CodeExit else if (same(file, "overflow")) error.OutputLimit else error.WasmTrap, result.failure.?);
        try std.testing.expect(result.output == .null and result.code_execution != null and result.effects.len == 0);
    }
}
test "native Wasm infinite guest and start execution obey deadline and cancellation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var request = Test.request(&cancel);
    inline for (.{ "loop", "start-loop" }) |file| {
        request.deadline_ms = std.Io.Clock.awake.now(std.testing.io).toMilliseconds() + 100;
        const result = try execute(arena.allocator(), std.testing.io, request, @embedFile("fixtures/wasm/" ++ file ++ ".wasm"));
        try std.testing.expectEqual(error.TimeLimit, result.failure.?);
    }
    cancel.store(true, .release);
    request.deadline_ms = std.math.maxInt(i64);
    const result = try execute(arena.allocator(), std.testing.io, request, @embedFile("fixtures/wasm/loop.wasm"));
    try std.testing.expectEqual(error.Cancelled, result.failure.?);
}

test "native Wasm cancellation interrupts running start and cannot cancel concurrent sibling" {
    const Job = struct {
        bytes: []const u8,
        cancel: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const result = execute(arena.allocator(), std.testing.io, Test.request(&self.cancel), self.bytes) catch |err| {
                self.failure = err;
                self.done.store(true, .release);
                return;
            };
            self.failure = result.failure;
            self.done.store(true, .release);
        }
    };
    inline for (.{ "loop", "start-loop" }) |file| {
        var cancelled: Job = .{ .bytes = @embedFile("fixtures/wasm/" ++ file ++ ".wasm") };
        var sibling: Job = .{ .bytes = @embedFile("fixtures/wasm/finite.wasm") };
        const t1 = try std.Thread.spawn(.{}, Job.run, .{&cancelled});
        defer {
            cancelled.cancel.store(true, .release);
            t1.join();
        }
        const t2 = try std.Thread.spawn(.{}, Job.run, .{&sibling});
        defer {
            sibling.cancel.store(true, .release);
            t2.join();
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake);
        cancelled.cancel.store(true, .release);
        try std.testing.expect(!sibling.done.load(.acquire));
        while (!cancelled.done.load(.acquire) or !sibling.done.load(.acquire)) try std.Io.sleep(std.testing.io, .fromMilliseconds(25), .awake);
        try std.testing.expectEqual(error.Cancelled, cancelled.failure.?);
        try std.testing.expectEqual(@as(?anyerror, null), sibling.failure);
    }
}
test "native Wasm stderr is bounded even when guest ignores the write error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var request = Test.request(&cancel);
    request.limits.max_diagnostic_bytes = 3;
    const result = try execute(arena.allocator(), std.testing.io, request, @embedFile("fixtures/wasm/diagnostic-overflow.wasm"));
    try std.testing.expectEqual(error.OutputLimit, result.failure.?);
}

test "native Wasm canonical output retention failure preserves executed identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    var request = Test.request(&cancel);
    request.limits.max_output_bytes = 6;
    const bytes = @embedFile("fixtures/wasm/retention-overflow.wasm");
    // The actual guest writes valid JSON within the stream limit.
    const guest_output = try invoke(alloc, std.testing.io, request, bytes);
    try std.testing.expectEqual(@as(f64, 1e30), guest_output.array.items[0].float);
    const result = try execute(alloc, std.testing.io, request, bytes);
    try std.testing.expectEqual(error.InvalidCodeResult, result.failure.?);
    try std.testing.expect(result.output == .null);
    try std.testing.expectEqual(@as(usize, 0), result.effects.len);
    try std.testing.expectEqualStrings(&code.hash(bytes), result.code_execution.?.artifact_sha256);
    try std.testing.expectEqualStrings(runtime, result.code_execution.?.profile);
    try std.testing.expectEqualStrings("wasmtime", result.code_execution.?.engine);
    try std.testing.expectEqualStrings(engine_version, result.code_execution.?.engine_version);
}
