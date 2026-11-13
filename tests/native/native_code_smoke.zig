const std = @import("std");
const code = @import("native/loops/code.zig");
const package = @import("native/loops/package.zig");
const runner = @import("native/loops/runner.zig");
// Explicit operator-supplied runtime JSON and private journal only; no profile/auth discovery.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5 or !std.mem.eql(u8, args[1], "--config") or !std.mem.eql(u8, args[3], "--journal")) return error.Usage;
    var config_file = try std.Io.Dir.openFileAbsolute(io, args[2], .{ .follow_symlinks = false });
    defer config_file.close(io);
    if ((try config_file.stat(io)).kind != .file) return error.InvalidConfig;
    var config_reader = config_file.reader(io, &.{});
    const config = try code.parse(allocator, try config_reader.interface.allocRemaining(allocator, .limited(16384)), 16384);
    // A fresh journal path is mandatory; never overwrite an existing proof.
    var journal_file = try std.Io.Dir.createFileAbsolute(io, args[4], .{ .exclusive = true, .permissions = .fromMode(0o600) });
    try journal_file.writeStreamingAll(io, "[]");
    try journal_file.sync(io);
    journal_file.close(io);
    const Context = struct {
        io: std.Io,
        alloc: std.mem.Allocator,
        journal_path: []const u8,
        rows: std.ArrayList(std.json.Value) = .empty,
        fn save(raw: *anyopaque, effect: code.JournalEffect) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const value = try code.parse(self.alloc, try std.json.Stringify.valueAlloc(self.alloc, effect, .{}), 65536);
            var replaced = false;
            for (self.rows.items) |*row| {
                if (std.mem.eql(u8, row.object.get("id").?.string, effect.id)) {
                    row.* = value;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try self.rows.append(self.alloc, value);
            const bytes = try std.json.Stringify.valueAlloc(self.alloc, self.rows.items, .{});
            const parent_path = std.fs.path.dirname(self.journal_path) orelse return error.InvalidJournal;
            var parent = try std.Io.Dir.openDirAbsolute(self.io, parent_path, .{ .follow_symlinks = false });
            defer parent.close(self.io);
            var atomic = try parent.createFileAtomic(self.io, std.fs.path.basename(self.journal_path), .{ .permissions = .fromMode(0o600), .replace = true });
            defer atomic.deinit(self.io);
            try atomic.file.writeStreamingAll(self.io, bytes);
            try atomic.file.sync(self.io);
            try atomic.replace(self.io);
            if (std.c.fsync(parent.handle) != 0) return error.JournalSync;
        }
    };
    var context: Context = .{ .io = io, .alloc = allocator, .journal_path = args[4] };
    var cancel = std.atomic.Value(bool).init(false);
    const source = "import json,sys\nv=json.load(sys.stdin)\nprint(json.dumps({'answer':v['number']+1,'ready':False}))\n";
    const manifest_bytes = "{\"format\":\"loops/0.1\",\"name\":\"native-code-proof\",\"version\":\"0.1.0\",\"inputs\":{\"schema\":{\"type\":\"object\",\"required\":[\"number\"],\"properties\":{\"number\":{\"type\":\"integer\"}},\"additionalProperties\":false}},\"steps\":[{\"id\":\"calculate\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"main.py\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":{\"type\":\"object\",\"required\":[\"answer\",\"ready\"],\"properties\":{\"answer\":{\"type\":\"integer\"},\"ready\":{\"type\":\"boolean\"}},\"additionalProperties\":false}}}],\"output\":{\"from\":\"/steps/calculate/output\"}}\n";
    var pkg = try package.fromFiles(allocator, &.{ .{ .path = "loop.json", .bytes = manifest_bytes }, .{ .path = "main.py", .bytes = source } }, "loop.json");
    defer pkg.deinit();
    const files = try allocator.alloc(code.File, pkg.files.len);
    for (files, pkg.files) |*file, retained| file.* = .{ .path = retained.path, .bytes = retained.bytes };
    const input = try code.parse(allocator, "{\"number\":41}", 256);
    try pkg.validateInput(input);
    const input_scope = try code.parse(allocator, try std.json.Stringify.valueAlloc(allocator, .{ .input = input }, .{}), 4096);
    const bound_input = try runner.resolve(allocator, pkg.manifest.object.get("steps").?.array.items[0].object.get("input").?, input_scope);
    const cfg: code.Config = .{ .socket_path = config.object.get("socket_path").?.string, .staging_root = config.object.get("staging_root").?.string, .image = config.object.get("image").?.string, .python = config.object.get("python").?.string, .runtime_handle = config.object.get("runtime_handle").?.string, .policy_digest = config.object.get("policy_digest").?.string };
    const module_values = config.object.get("stdlib").?.array.items;
    const modules = try allocator.alloc([]const u8, module_values.len);
    for (modules, module_values) |*module, value| module.* = value.string;
    var cache: code.AuditCache = .{};
    const audit_start = std.Io.Clock.awake.now(io).toMilliseconds();
    const audit_request: code.AuditRequest = .{ .step = .{ .run_id = "probe-native-code-smoke", .step_id = "runtime-probe", .iteration = 0, .definition = .null, .input = .null, .selection = .{}, .response_schema = .null, .limits = .{ .max_seconds = 2, .max_output_bytes = 65536, .max_diagnostic_bytes = 4096 }, .cancel = &cancel, .deadline_ms = audit_start + 2000, .journal = .{ .context = &context, .recordFn = Context.save } }, .config = cfg, .modules = modules, .owner_token = "native-code-smoke-owned", .bound_handles = &.{cfg.runtime_handle} };
    const audit = try code.auditRuntime(allocator, io, audit_request, &cache);
    const audit_ms = std.Io.Clock.awake.now(io).toMilliseconds() - audit_start;
    const cache_start = std.Io.Clock.awake.now(io).toMilliseconds();
    const cached = (try code.cachedRuntime(allocator, io, audit_request, &cache)) orelse return error.CacheMiss;
    const cached_ms = std.Io.Clock.awake.now(io).toMilliseconds() - cache_start;
    const start = std.Io.Clock.awake.now(io).toMilliseconds();
    const result = try code.execute(allocator, io, .{
        .step = .{ .run_id = "run-native-code-smoke", .step_id = "calculate", .iteration = 0, .definition = pkg.manifest.object.get("steps").?.array.items[0], .input = bound_input, .selection = .{}, .response_schema = .null, .limits = .{ .max_seconds = 10, .max_output_bytes = 65536, .max_diagnostic_bytes = 4096 }, .cancel = &cancel, .deadline_ms = start + 10000, .journal = .{ .context = &context, .recordFn = Context.save } },
        .files = files,
        .entry = "main.py",
        .config = cfg,
        .owner_token = "native-code-smoke-owned",
        .package_digest = pkg.digest,
        .bound_handles = &.{config.object.get("runtime_handle").?.string},
    });
    try pkg.validateStepOutput("calculate", result.output);
    const output_scope = try code.parse(allocator, try std.json.Stringify.valueAlloc(allocator, .{ .steps = .{ .calculate = .{ .output = result.output } } }, .{}), 4096);
    const bound_output = try runner.resolve(allocator, pkg.manifest.object.get("output").?, output_scope);
    const output = try std.json.Stringify.valueAlloc(allocator, .{ .output = bound_output, .package_digest = pkg.digest, .source_digest = code.hash(source), .python_version = audit.version, .runtime_audit_ms = audit_ms, .cached_audit_ms = cached_ms, .cached = cached.cached, .elapsed_ms = std.Io.Clock.awake.now(io).toMilliseconds() - start, .journal_receipts = context.rows.items.len, .native_unix_http = true, .node_calls = 0, .cli_calls = 0, .effects = context.rows.items, .runtime = cfg }, .{});
    try std.Io.File.stdout().writeStreamingAll(io, try std.fmt.allocPrint(allocator, "{s}\n", .{output}));
}
