//! Native foreground Loop service. Package/binding data never grants authority.
const std = @import("std");
const metadata = @import("../metadata.zig");
pub const runner = @import("runner.zig");
const package = @import("package.zig");
const installed = @import("installed.zig");
const schema = @import("schema.zig");
const bindings = @import("bindings.zig");
pub const storage = @import("store.zig");
const wasm = @import("wasm.zig");
const code = @import("code.zig");
const dependencies = @import("dependencies.zig");
const runtime_policy = @import("runtime_policy.zig");
const workspace_runtime = @import("workspace_runtime.zig");
const browser = @import("browser.zig");
pub const diagnostics = @import("../run_diagnostics.zig");
const workspace_read = @import("workspace_read.zig");
pub const ExecuteFn = *const fn (*anyopaque, std.mem.Allocator, runner.StepRequest, *package.Package, *bindings.Binding) anyerror!runner.StepResult;
pub const PreflightFn = *const fn (*anyopaque, runner.Value, *package.Package, *bindings.Binding) anyerror!void;
pub const InferPreflightFn = *const fn (*anyopaque, runner.Value, *package.Package, *bindings.Binding, runner.Selection) anyerror!void;
pub const Options = struct {
    io: std.Io,
    profile: []const u8,
    selection: runner.Selection = .{},
    resolveSelectionFn: ?*const fn (std.mem.Allocator, []const u8) anyerror!runner.Selection = null,
    infer_context: ?*anyopaque = null,
    inferFn: ?ExecuteFn = null,
    inferPreflightFn: ?InferPreflightFn = null,
    decision_context: ?*anyopaque = null,
    decisionFn: ?ExecuteFn = null,
    decisionPreflightFn: ?PreflightFn = null,
    code_context: ?*anyopaque = null,
    codeFn: ?ExecuteFn = null,
    codePreflightFn: ?PreflightFn = null,
    audit_cache: ?*code.AuditCache = null,
    deadline_ms: ?i64 = null,
    expected_digest: ?[]const u8 = null,
    /// Test seam for fetching a GitHub address. Never set from the command line.
    packages: installed.Options = .{},
};
pub const Hooks = struct { context: *anyopaque, acceptedFn: *const fn (*anyopaque, []const u8, *package.Package, bool) anyerror!void };
pub const Engine = struct {
    options: Options,
    audit_cache: code.AuditCache = .{},
    input_size: ?u64 = null,
    runtime_issue: runtime_policy.Issue = .{},
    /// The sentence that explains the last package refusal: a name that is not installed,
    /// or an installed package whose files no longer match its lock entry.
    package_note: ?[]const u8 = null,
    /// True only for a request a person typed. A chat tool call never fetches an address.
    addresses: bool = false,
    /// The sentence for an input the package's schema refused: where it failed, what the
    /// schema is, and how to supply input.
    input_note: ?[]const u8 = null,
    input_schema: ?runner.Value = null,
    input_pointer: ?[]const u8 = null,
    pub const input_limit = 1048576;
    /// A PACKAGE argument is a path, or an installed NAME or NAME@VERSION. An installed
    /// package is hashed again on every load and refused when it has changed. A GitHub
    /// address is refused: loading never fetches.
    fn loadPackage(self: *Engine, allocator: std.mem.Allocator, argument: []const u8) !*package.Package {
        self.package_note = null;
        self.runtime_issue = .{};
        return installed.open(allocator, self.options.io, self.options.profile, argument, &self.package_note);
    }
    /// `fh run ADDRESS`, before the run: fetch the GitHub address a PACKAGE names, and
    /// install it only when the request carries the digest that was inspected. Null when
    /// the PACKAGE is not an address. Otherwise the answer of `installed.admit`: its
    /// `package` is what to run, and `confirmation_required` means nothing was installed and
    /// nothing may run. Nobody can be asked from here, so `--yes` always needs `--digest`.
    pub fn admit(self: *Engine, allocator: std.mem.Allocator, params: runner.Value) !?runner.Value {
        const argument = try requiredString(params, "packagePath");
        if (installed.classify(argument) != .address) return null;
        self.package_note = null;
        if (!self.addresses) return self.unfetched(allocator, argument);
        var request: installed.RunRequest = .{ .argument = argument, .next = optionalString(params, "nextCommand") };
        if (params.object.get("yes")) |value| request.yes = value == .bool and value.bool;
        if (params.object.get("digest")) |value| request.digest = if (value == .string) value.string else return error.InvalidDigest;
        return installed.admit(allocator, self.options.io, self.options.profile, request, self.options.packages, &self.package_note) catch |err| {
            if (self.package_note == null) self.package_note = installed.explain(err);
            return err;
        };
    }
    /// Refuses a GitHub address where nothing may fetch one, through the loader's own words.
    fn unfetched(self: *Engine, allocator: std.mem.Allocator, argument: []const u8) anyerror {
        const pkg = installed.open(allocator, self.options.io, self.options.profile, argument, &self.package_note) catch |err| return err;
        pkg.deinit();
        return error.PackageAddress;
    }
    /// The package a `check` names. A GitHub address is fetched and checked as it was
    /// fetched: nothing is installed.
    fn checkPackage(self: *Engine, allocator: std.mem.Allocator, argument: []const u8) !*package.Package {
        if (installed.classify(argument) != .address or !self.addresses) return self.loadPackage(allocator, argument);
        self.package_note = null;
        return installed.fetchPackage(allocator, self.options.io, self.options.profile, argument, self.options.packages, &self.package_note);
    }
    /// Records why the package's input schema refused the input. The schema is given whole:
    /// it is the only exact statement of what the package requires. Everything is copied,
    /// because the package is freed before the error is reported.
    fn explainInput(self: *Engine, allocator: std.mem.Allocator, pkg: *package.Package, supplied: bool) !void {
        const pointer = if (pkg.validation_error.path.len == 0) "/" else pkg.validation_error.path;
        const required_schema = try schema.parse(allocator, try std.json.Stringify.valueAlloc(allocator, pkg.input_schema.value, .{}));
        self.input_pointer = try allocator.dupe(u8, pointer);
        self.input_schema = required_schema;
        self.input_note = try std.fmt.allocPrint(allocator, "{s}: at {s}, {s} The input must match this schema: {s} Write the input as JSON in a file and pass it with --input FILE, or pass --input - to read it from standard input.", .{ if (supplied) "The input does not match this package's input schema" else "No input was supplied, and this package's input schema does not accept an empty object", pointer, pkg.validation_error.message, try std.json.Stringify.valueAlloc(allocator, required_schema, .{}) });
    }
    /// `add`, `list`, `remove` and `update` for installed packages.
    pub fn packages(self: *Engine, allocator: std.mem.Allocator, method: []const u8, params: runner.Value) !runner.Value {
        self.runtime_issue = .{};
        self.package_note = null;
        return installed.command(allocator, self.options.io, self.options.profile, method, params, .{}, &self.package_note) catch |err| {
            if (self.package_note == null) self.package_note = installed.explain(err);
            return err;
        };
    }
    pub fn errorDetail(self: *Engine, allocator: std.mem.Allocator, err: anyerror) !runner.Value {
        var detail = object();
        try put(allocator, &detail, "code", string(errorCode(err)));
        if (err == error.InvalidInput and self.input_size != null) {
            try put(allocator, &detail, "model_request_dispatches", .{ .integer = 0 });
            try put(allocator, &detail, "model_request_dispatches_complete", .{ .bool = true });
            const hint = "Use a smaller JSON input. If splitting a snapshot, track which files each part covers.";
            try put(allocator, &detail, "observed_bytes", .{ .integer = @intCast(self.input_size.?) });
            try put(allocator, &detail, "limit_bytes", .{ .integer = input_limit });
            try put(allocator, &detail, "hint", string(hint));
            try put(allocator, &detail, "message", string(try std.fmt.allocPrint(allocator, "Input file has {d} bytes; limit is {d} bytes. {s}", .{ self.input_size.?, input_limit, hint })));
        } else if (self.runtime_issue.message_len != 0) {
            try put(allocator, &detail, "path", string(try allocator.dupe(u8, self.runtime_issue.path())));
            try put(allocator, &detail, "message", string(try allocator.dupe(u8, self.runtime_issue.message())));
        } else if (err == error.InvalidInput and self.input_note != null) {
            try put(allocator, &detail, "model_request_dispatches", .{ .integer = 0 });
            try put(allocator, &detail, "model_request_dispatches_complete", .{ .bool = true });
            try put(allocator, &detail, "message", string(self.input_note.?));
            try put(allocator, &detail, "pointer", string(self.input_pointer.?));
            try put(allocator, &detail, "input_schema", self.input_schema.?);
        } else if (self.package_note) |message| {
            try put(allocator, &detail, "message", string(message));
        } else if (err == error.RecoveryRequired) {
            try self.recoveryDetail(allocator, &detail);
        } else if (agentMessage(err)) |message| {
            try put(allocator, &detail, "message", string(message));
        } else if (err == error.UnsafeProfile) {
            try put(allocator, &detail, "message", string(try storage.profileRefusal(allocator, self.options.profile)));
        } else if (err == error.BrowserSetupRequired) {
            try put(allocator, &detail, "message", string("Installed Moli is missing or not executable. Install Moli 1.1.13, then run fh setup browser [--binary /absolute/path/to/moli]."));
        } else try put(allocator, &detail, "message", string(diagnostics.failureMessage(@errorName(err))));
        try put(allocator, &detail, "cause", string(@errorName(err)));
        try put(allocator, &detail, "diagnostic", try diagnostics.errorDiagnostic(allocator, err));
        return detail;
    }
    /// Explain read-only interruption findings and unresolved local effects accurately.
    fn recoveryDetail(self: *Engine, allocator: std.mem.Allocator, detail: *runner.Value) !void {
        const found = (storage.inspect(allocator, self.options.io, self.options.profile) catch null) orelse
            return put(allocator, detail, "message", string(diagnostics.failureMessage("RecoveryRequired")));
        var unsettled = object();
        try put(allocator, &unsettled, "run_id", string(found.run_id));
        const message = switch (found.cause) {
            .interrupted => try std.fmt.allocPrint(allocator, "Run {s} appears interrupted. Declaration-only check leaves it unchanged. New work automatically records abandoned runs as stopped under their leases; fh get {s} also records the interruption. Unresolved local resource or mutation effects still block independent work: inspect those effects before using fh settle {s} --applied or fh settle {s} --not-applied. Unknown provider outcomes and incomplete usage remain uncertain and prevent retry.", .{ found.run_id, found.run_id, found.run_id, found.run_id }),
            .missing_record => try std.fmt.allocPrint(allocator, "Run {s} was reserved but its record was never written, so nothing in it ran. Run fh settle {s} --not-applied to clear it. Until then fh will not start new work on this installation.", .{ found.run_id, found.run_id }),
            .effect => blk: {
                const kinds = [_][3][]const u8{
                    .{ "workspace_command", "a workspace command", "the workspace, and anything that command changes outside it, to see whether the command ran" },
                    .{ "workspace_edit", "a workspace file edit", "the file in the workspace to see whether it was replaced" },
                    .{ "browser_cleanup", "a browser shutdown", "whether the browser this run started is still running, and stop it if so" },
                };
                var what: []const u8 = "an isolated code container";
                var look: []const u8 = "the container runtime for a container or staging directory this run left behind, and remove it if so";
                for (kinds) |kind| if (std.mem.eql(u8, kind[0], found.effect_kind)) {
                    what = kind[1];
                    look = kind[2];
                };
                try put(allocator, &unsettled, "effect", string(found.effect_id));
                try put(allocator, &unsettled, "step", string(found.step));
                const at = if (found.step.len != 0) try std.fmt.allocPrint(allocator, " at step {s}", .{found.step}) else "";
                break :blk try std.fmt.allocPrint(allocator, "Run {s} has {s}{s} whose outcome was never recorded (effect {s}), so fh will not start new work on this installation. Inspect {s}. Then record what you found: fh settle {s} --applied if it took effect, or fh settle {s} --not-applied if it did not.", .{ found.run_id, what, at, found.effect_id, look, found.run_id, found.run_id });
            },
        };
        try put(allocator, detail, "unsettled", unsettled);
        try put(allocator, detail, "message", string(message));
    }
    pub fn check(self: *Engine, allocator: std.mem.Allocator, params: runner.Value) !runner.Value {
        self.runtime_issue = .{};
        const original_selection = self.options.selection;
        defer self.options.selection = original_selection;
        var pkg = try self.checkPackage(allocator, try requiredString(params, "packagePath"));
        defer pkg.deinit();
        if (hasInference(pkg.manifest)) {
            // A fetched package has no folder of its own yet. Its settings are read from where
            // it would be installed.
            if (self.options.resolveSelectionFn) |resolve| self.options.selection = try resolve(pkg.arena.allocator(), if (pkg.root.len != 0) pkg.root else try std.fs.path.join(pkg.arena.allocator(), &.{ self.options.profile, installed.directory }));
        }
        var binding = try bindings.load(allocator, self.options.io, self.options.profile, optionalString(params, "bindingsId") orelse "local");
        defer binding.deinit();
        if (hasDecision(pkg.manifest) and !hasInference(pkg.manifest)) self.options.selection = try @import("decision.zig").selection(&binding);
        // Declaration-only checks must work with read-only profile access.
        // Only the isolated code probe needs durable dispatch/cleanup receipts.
        var needs_probe = if (dependencies.runtimes(pkg.manifest)) |entries| entries.object.count() != 0 else false;
        if (self.options.codeFn == null and self.options.codePreflightFn == null) {
            // Every leaf step, including those inside loops/0.3 branches and map steps.
            for (pkg.leaves) |step| {
                if (std.mem.eql(u8, try requiredString(step, "kind"), "code") and !std.mem.eql(u8, try requiredString(step, "runtime"), workspace_runtime.runtime) and !std.mem.eql(u8, try requiredString(step, "runtime"), wasm.runtime)) needs_probe = true;
            }
        }
        var store: ?storage.Store = null;
        defer if (store) |*owned| owned.deinit();
        var foreground: ?std.Io.File = null;
        defer if (foreground) |file| file.close(self.options.io);
        if (needs_probe) {
            store = try storage.Store.init(allocator, self.options.io, self.options.profile);
            foreground = try store.?.lock("foreground");
            try store.?.recoverAndRequireSettledResources();
            try store.?.reserve(64 * 1048576, 1024 * 1048576);
        } else if (try storage.inspect(pkg.arena.allocator(), self.options.io, self.options.profile)) |found| {
            // Report admission bookkeeping without performing it: no lock or write here.
            // Mutation admission can recover orphans; a live owner is busy.
            return if (found.cause == .interrupted and (storage.held(self.options.io, self.options.profile, "foreground") or storage.held(self.options.io, self.options.profile, found.run_id))) error.RunBusy else error.RecoveryRequired;
        }
        var cancel_flag = std.atomic.Value(bool).init(false);
        var result = object();
        try put(allocator, &result, "ok", .{ .bool = true });
        self.preflight(pkg, &binding, &cancel_flag, self.options.deadline_ms orelse std.Io.Clock.awake.now(self.options.io).toMilliseconds() + 2000, if (store) |*owned| owned else null, false) catch |err| {
            try put(allocator, &result, "ok", .{ .bool = false });
            var issues: runner.Value = .{ .array = std.array_list.Managed(runner.Value).init(allocator) };
            var issue = object();
            try put(allocator, &issue, "code", string(errorCode(err)));
            try put(allocator, &issue, "cause", string(@errorName(err)));
            const message: []const u8 = switch (err) {
                error.BrowserSetupRequired => "Installed Moli is unavailable. Run fh setup browser [--binary /absolute/path/to/moli].",
                error.WorkspaceSetupRequired => "This package needs a registered workspace, and this binding has no workspace grant. Run fh setup workspace GRANT.json, adding --trust-host only if the grant registers host commands, then check and run with --bindings-id workspace.",
                error.WorkspaceReadOnlyGrant => agentMessage(err).?,
                error.WorkspaceChanged => "The registered workspace directory is missing or is no longer the one that was registered, or a repair baseline changed. Inspect current files and register the intended workspace before retrying; earlier effects may already have occurred.",
                error.WorkspaceCommandUnavailable => "A registered workspace command is missing or not executable. Inspect the grant's absolute executable path; check never installs tools.",
                error.RuntimeUnavailable, error.DockerUnavailable => "Configured isolated runtime is unavailable. Check that its Docker-compatible daemon is running and its pinned image is installed, then retry fh check.",
                error.UnsupportedRuntime, error.RuntimeUnbound, error.RuntimeUnsupported => try std.fmt.allocPrint(allocator, "This installation cannot provide a code runtime this package declares ({s}). Register a matching available runtime profile with a supported version and an installed pinned image in installation.json, then retry fh check.", .{try declaredRuntimes(allocator, pkg.manifest)}),
                else => "Native declaration preflight rejected this package.",
            };
            if (self.runtime_issue.message_len != 0) {
                try put(allocator, &issue, "path", string(try allocator.dupe(u8, self.runtime_issue.path())));
                try put(allocator, &issue, "message", string(try allocator.dupe(u8, self.runtime_issue.message())));
            } else try put(allocator, &issue, "message", string(message));
            try issues.array.append(issue);
            try put(allocator, &result, "issues", issues);
            return result;
        };
        try put(allocator, &result, "package_digest", string(try allocator.dupe(u8, pkg.digest)));
        return result;
    }
    /// `agent_driven`: the driving agent performs every infer and decision step with its own
    /// model and its own capabilities (loops/0.3 section 10), so this installation needs no
    /// provider, browser or workspace for them. Every code step is checked exactly as for a
    /// runner-driven run.
    fn preflight(self: *Engine, pkg: *package.Package, binding: *bindings.Binding, cancel_flag: *const std.atomic.Value(bool), deadline_ms: i64, store: ?*storage.Store, agent_driven: bool) !void {
        self.runtime_issue = .{};
        const alloc = binding.arena.allocator();
        // Validate every source profile and declared minimum before any adapter/model callback.
        if (dependencies.runtimes(pkg.manifest)) |entries| {
            var requirements = entries.object.iterator();
            while (requirements.next()) |entry| {
                const profile = try runtime_policy.validate(alloc, binding.configuration, binding.registered, entry.key_ptr.*, &self.runtime_issue);
                try runtime_policy.minimum(alloc, entry.key_ptr.*, entry.value_ptr.*, profile.version, false, &self.runtime_issue);
            }
        }
        if (self.options.codeFn == null and self.options.codePreflightFn == null) for (pkg.leaves) |step| {
            const runtime = optionalString(step, "runtime") orelse continue;
            if (dependencies.source(runtime)) _ = try runtime_policy.validate(alloc, binding.configuration, binding.registered, runtime, &self.runtime_issue);
        };
        // Validate every portable artifact before any adapter callback, regardless of leaf order.
        for (pkg.leaves) |step| if (std.mem.eql(u8, optionalString(step, "runtime") orelse "", wasm.runtime)) {
            const id = try requiredString(step, "id");
            const artifact = try std.json.Stringify.valueAlloc(alloc, try requiredString(step, "file"), .{ .escape_unicode = true });
            const filename = try std.json.Stringify.valueAlloc(alloc, std.fs.path.basename(try requiredString(step, "file")), .{ .escape_unicode = true });
            // Put the profile and filename before the optional full path, which the issue
            // formatter abbreviates within its existing bound after preserving the reason.
            const display = if (std.mem.eql(u8, filename, artifact)) artifact else try std.fmt.allocPrint(alloc, "{s}; path {s}", .{ filename, artifact });
            const expected = try std.fmt.allocPrint(alloc, "{s}; supported imports/signatures and module resources (see docs/contracts/wasm32-wasi-json-1.md); artifact {s}", .{ wasm.runtime, display });
            try wasm.preflightDiagnostic((try pkg.stepCode(id)).bytes, self.options.io, cancel_flag, deadline_ms, &self.runtime_issue, try std.fmt.allocPrint(alloc, "steps.{s}.file", .{id}), expected);
        };
        try binding.assertDeclarations(pkg.manifest, agent_driven);
        if (dependencies.runtimes(pkg.manifest)) |entries| {
            var requirements = entries.object.iterator();
            while (requirements.next()) |entry| {
                var step = object();
                try put(alloc, &step, "id", string("runtime_requirement"));
                try put(alloc, &step, "kind", string("code"));
                try put(alloc, &step, "runtime", string(entry.key_ptr.*));
                const actual = try self.auditRuntime(binding, step, entry.value_ptr.*, cancel_flag, deadline_ms, store orelse return error.RuntimeUnbound);
                try runtime_policy.minimum(alloc, entry.key_ptr.*, entry.value_ptr.*, actual, true, &self.runtime_issue);
            }
        }
        var audited_runtime: ?[]const u8 = null;
        // Every leaf step, including those inside loops/0.3 branches and map steps.
        for (pkg.leaves) |step| {
            if (std.mem.eql(u8, try requiredString(step, "kind"), "code")) {
                if (std.mem.eql(u8, optionalString(step, "runtime") orelse "", wasm.runtime)) continue;
                if (self.options.codePreflightFn) |callback| try callback(self.options.code_context orelse self, step, pkg, binding) else if (self.options.codeFn == null) {
                    const runtime = try requiredString(step, "runtime");
                    if (cancel_flag.load(.acquire)) return error.Cancelled;
                    if (std.Io.Clock.awake.now(self.options.io).toMilliseconds() >= deadline_ms) return error.TimeLimit;
                    var authority: Authority = .{ .engine = self, .binding_id = try requiredString(binding.registered, "id"), .digest = binding.digest };
                    try Authority.check(&authority);
                    if (std.mem.eql(u8, runtime, workspace_runtime.runtime)) {
                        try workspace_runtime.preflight(binding, self.options.io, pkg, try requiredString(step, "id"));
                        continue;
                    }
                    // Keep each step's policy/grant checks after requirements audited its runtime.
                    const requirement_audited = if (dependencies.runtimes(pkg.manifest)) |entries| entries.object.contains(runtime) else false;
                    if (requirement_audited or (audited_runtime != null and std.mem.eql(u8, audited_runtime.?, runtime))) {
                        _ = try self.codePolicy(binding, step);
                    } else {
                        _ = try self.auditRuntime(binding, step, .null, cancel_flag, deadline_ms, store orelse return error.RuntimeUnbound);
                        audited_runtime = runtime;
                    }
                }
            }
        }
        for (pkg.leaves) |step| {
            if (std.mem.eql(u8, try requiredString(step, "kind"), "code")) continue;
            if (agent_driven) {
                continue;
            } else if (std.mem.eql(u8, try requiredString(step, "kind"), "decision")) {
                if (self.options.decisionFn == null) return error.UnsupportedDecision;
                if (self.options.decisionPreflightFn) |callback| try callback(self.options.decision_context orelse self, step, pkg, binding);
            } else {
                if (self.options.inferFn == null) return error.UnsupportedInference;
                if (workspace_read.required(step)) _ = try workspace_read.configured(binding, self.options.io);
                if (self.options.inferPreflightFn) |callback| try callback(self.options.infer_context orelse self, try pkg.resolved(pkg.arena.allocator(), step), pkg, binding, self.options.selection);
            }
        }
    }
    fn auditRuntime(self: *Engine, binding: *bindings.Binding, step: runner.Value, requirement: runner.Value, cancel_flag: *const std.atomic.Value(bool), deadline_ms: i64, store: *storage.Store) ![3]u32 {
        const alloc = binding.arena.allocator();
        const policy = try self.codePolicy(binding, step);
        const profile = try binding.profile(try requiredString(step, "runtime"));
        const declared_modules = try runner.get(profile, runtime_policy.moduleKey(policy.config.runtime));
        if (declared_modules != .array or declared_modules.array.items.len > 64) return error.InvalidBindings;
        var module_list: std.ArrayList([]const u8) = .empty;
        for (declared_modules.array.items) |module| try module_list.append(alloc, try runner.text(module));
        if (schema.get(requirement, "modules")) |required_modules| for (required_modules.array.items) |module| {
            const name = try runner.text(module);
            var found = false;
            for (module_list.items) |existing| if (std.mem.eql(u8, existing, name)) {
                found = true;
                break;
            };
            if (!found) try module_list.append(alloc, name);
        };
        const modules = module_list.items;
        var authority: Authority = .{ .engine = self, .binding_id = try requiredString(binding.registered, "id"), .digest = binding.digest };
        var observed_version: ?[3]u32 = null;
        var audit: code.AuditRequest = .{ .observed_version = &observed_version, .step = .{ .run_id = "runtime-audit-cache", .step_id = "runtime_audit", .iteration = 0, .definition = step, .input = .null, .selection = self.options.selection, .response_schema = .{ .bool = true }, .limits = binding.limits, .cancel = cancel_flag, .deadline_ms = @min(deadline_ms, std.Io.Clock.awake.now(self.options.io).toMilliseconds() + 2000), .journal = .{ .context = self, .recordFn = noProbe } }, .config = policy.config, .modules = modules, .binding_id = authority.binding_id, .binding_digest = binding.digest, .owner_token = "runtime-audit-cache", .bound_handles = policy.handles, .authority = .{ .context = &authority, .checkFn = Authority.check } };
        const cache = self.options.audit_cache orelse &self.audit_cache;
        _ = code.socketIdentity(alloc, self.options.io, policy.config.socket_path) catch |err| return self.runtime_issue.reject("docker.socketPath", "existing Docker-compatible Unix socket", "socket unavailable", err);
        const runtime_name = try requiredString(step, "runtime");
        const prepared = code.prepareAudit(alloc, self.options.io, audit) catch |err| {
            if (err != error.RuntimeUnavailable and err != error.DockerUnavailable and err != error.RuntimeUnsupported) return err;
            const path = if (err == error.DockerUnavailable) "docker.socketPath" else if (err == error.RuntimeUnavailable) try std.fmt.allocPrint(alloc, "runtimeProfiles.{s}.image", .{runtime_name}) else if (requirement != .null) try std.fmt.allocPrint(alloc, "dependencies.runtimes.{s}.modules", .{runtime_name}) else try std.fmt.allocPrint(alloc, "runtimeProfiles.{s}.{s}", .{ runtime_name, runtime_policy.moduleKey(policy.config.runtime) });
            return self.runtime_issue.reject(path, "reachable Docker socket and already installed pinned image; fixed interpreter with declared standard/builtin modules", "runtime unavailable (no pull attempted)", err);
        };
        if (cache.find(prepared.key)) |version| return version;
        // Foreground ownership serializes this one bounded file across CLI processes.
        var durable = code.AuditCache.load(self.options.io, self.options.profile) catch code.AuditCache{};
        if (durable.find(prepared.key)) |version| {
            cache.remember(prepared.key, version);
            return version;
        }
        var random: [16]u8 = undefined;
        std.Io.random(self.options.io, &random);
        const id = try std.fmt.allocPrint(alloc, "probe_{s}", .{std.fmt.bytesToHex(random, .lower)});
        const lease = try store.lock(id);
        defer lease.close(self.options.io);
        var probe: Probe = .{ .alloc = alloc, .store = store, .record = object() };
        try put(alloc, &probe.record, "format", string("fh.native-run/0.1"));
        try put(alloc, &probe.record, "run_id", string(id));
        try put(alloc, &probe.record, "status", string("running"));
        try put(alloc, &probe.record, "effects", .{ .array = std.array_list.Managed(runner.Value).init(alloc) });
        try store.save(probe.record);
        audit.step.run_id = id;
        audit.owner_token = id;
        audit.step.journal = .{ .context = &probe, .recordFn = Probe.effect };
        const audited = code.auditPrepared(alloc, self.options.io, audit, cache, prepared) catch |err| {
            try put(alloc, &probe.record, "status", string("failed"));
            try put(alloc, &probe.record, "reason", string(errorCode(err)));
            try store.save(probe.record);
            if (err != error.RuntimeUnavailable and err != error.DockerUnavailable and err != error.RuntimeUnsupported and err != error.CodeExit) return err;
            const runtime = try requiredString(step, "runtime");
            if (observed_version) |actual| {
                if (requirement != .null) try runtime_policy.minimum(alloc, runtime, requirement, actual, true, &self.runtime_issue);
                const path = try std.fmt.allocPrint(alloc, "runtimeProfiles.{s}.version", .{runtime});
                const available = try std.fmt.allocPrint(alloc, "{d}.{d}.{d} (probed interpreter)", .{ actual[0], actual[1], actual[2] });
                return self.runtime_issue.reject(path, "supported interpreter version inside the pinned image", available, err);
            }
            const path = if (requirement != .null) try std.fmt.allocPrint(alloc, "dependencies.runtimes.{s}.modules", .{runtime}) else try std.fmt.allocPrint(alloc, "runtimeProfiles.{s}", .{runtime});
            const expected = if (requirement != .null) try std.json.Stringify.valueAlloc(alloc, try runner.get(requirement, "modules"), .{}) else try std.json.Stringify.valueAlloc(alloc, declared_modules, .{});
            return self.runtime_issue.reject(path, try std.fmt.allocPrint(alloc, "fixed interpreter with available standard/builtin modules {s}", .{expected}), "fixed runtime probe failed; interpreter/module unavailable", err);
        };
        try put(alloc, &probe.record, "status", string("completed"));
        try put(alloc, &probe.record, "cached", .{ .bool = audited.cached });
        try store.save(probe.record);
        try Authority.check(&authority);
        durable.remember(prepared.key, audited.version);
        durable.save(self.options.io, self.options.profile) catch {};
        return audited.version;
    }
    fn declaredRuntimes(allocator: std.mem.Allocator, manifest: runner.Value) ![]const u8 {
        var names: std.ArrayList(u8) = .empty;
        for ((try runner.get(manifest, "steps")).array.items) |step| {
            if (!std.mem.eql(u8, try requiredString(step, "kind"), "code")) continue;
            const runtime = try requiredString(step, "runtime");
            var listed = std.mem.splitSequence(u8, names.items, ", ");
            const seen = while (listed.next()) |name| {
                if (std.mem.eql(u8, name, runtime)) break true;
            } else false;
            if (seen) continue;
            if (names.items.len != 0) try names.appendSlice(allocator, ", ");
            try names.appendSlice(allocator, runtime);
        }
        return names.toOwnedSlice(allocator);
    }
    fn noProbe(_: *anyopaque, _: runner.Effect) !void {
        return error.NoProbeOwner;
    }
    const CodePolicy = struct { config: code.Config, grants: []const code.Grant, handles: []const []const u8 };
    fn codePolicy(self: *Engine, binding: *bindings.Binding, step: runner.Value) !CodePolicy {
        const alloc = binding.arena.allocator();
        const checked = try runtime_policy.validate(alloc, binding.configuration, binding.registered, try requiredString(step, "runtime"), &self.runtime_issue);
        const profile = checked.value;
        const runtime = checked.runtime;
        if (profile.object.get("writableResources")) |writable| {
            const path = try std.fmt.allocPrint(alloc, "runtimeProfiles.{s}.writableResources", .{try requiredString(step, "runtime")});
            if (writable != .array) return self.runtime_issue.reject(path, "array", "wrong type", error.InvalidBindings);
            if (writable.array.items.len != 0) return self.runtime_issue.reject(path, "tracked writable resources", "unsupported writable grants", error.ResourceTrackingRequired);
        }
        const docker = try runner.get(binding.configuration, "docker");
        const socket_path = try requiredString(docker, "socketPath");
        var staging: []const u8 = undefined;
        if (optionalString(docker, "stagingRoot")) |explicit| staging = explicit else if (@import("builtin").os.tag == .macos) {
            const parent = try std.fmt.allocPrint(alloc, "/private/tmp/fh-code-{d}", .{std.c.getuid()});
            try privateDirectory(self.options.io, parent);
            const parent_profile = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ parent, code.hash(self.options.profile) });
            try privateDirectory(self.options.io, parent_profile);
            staging = try std.fmt.allocPrint(alloc, "{s}/staging", .{parent_profile});
        } else staging = try std.fmt.allocPrint(alloc, "{s}/staging", .{self.options.profile});
        try privateDirectory(self.options.io, staging);
        var handles: std.ArrayList([]const u8) = .empty;
        var grants: std.ArrayList(code.Grant) = .empty;
        var runtime_handle: ?[]const u8 = null;
        for ((try runner.get(profile, "resources")).array.items) |resource_name| {
            const logical = try runner.text(resource_name);
            const resource = try binding.resource(logical);
            try handles.append(alloc, resource.handle);
            const kind = try requiredString(resource.value, "kind");
            if (std.mem.eql(u8, kind, "runtime")) {
                if (runtime_handle != null) return error.InvalidBindings;
                runtime_handle = resource.handle;
                continue;
            }
            if (!std.mem.eql(u8, kind, "directory") or !std.mem.eql(u8, try requiredString(resource.value, "mode"), "ro")) return error.PermissionDenied;
            const path = try requiredString(resource.value, "path");
            var dir = try storage.openDirectory(self.options.io, path);
            defer dir.close(self.options.io);
            const stat = metadata.fstat(dir.handle) catch return error.PermissionDenied;
            const target = optionalString(resource.value, "target") orelse try std.fmt.allocPrint(alloc, "/grants/{s}", .{logical});
            try grants.append(alloc, .{ .handle = resource.handle, .source = path, .target = target, .read_only = true, .dev = @intCast(stat.dev), .ino = @intCast(stat.ino) });
        }
        return .{ .config = .{ .socket_path = socket_path, .staging_root = staging, .image = try requiredString(profile, "image"), .python = optionalString(profile, "python") orelse "/usr/bin/python3", .runtime = runtime, .node = optionalString(profile, "node") orelse "/usr/local/bin/node", .runtime_handle = runtime_handle orelse return error.RuntimeUnbound, .policy_digest = try requiredString(binding.registered, "policyDigest") }, .grants = try grants.toOwnedSlice(alloc), .handles = try handles.toOwnedSlice(alloc) };
    }
    fn nativeCode(self: *Engine, allocator: std.mem.Allocator, request: runner.StepRequest, pkg: *package.Package, binding: *bindings.Binding) !runner.StepResult {
        if (std.mem.eql(u8, try requiredString(request.definition, "runtime"), wasm.runtime)) {
            var authority: Authority = .{ .engine = self, .binding_id = try requiredString(binding.registered, "id"), .digest = binding.digest };
            try Authority.check(&authority);
            return wasm.execute(allocator, self.options.io, request, (try pkg.stepCode(request.step_id)).bytes);
        }
        if (std.mem.eql(u8, try requiredString(request.definition, "runtime"), workspace_runtime.runtime)) {
            var authority: Authority = .{ .engine = self, .binding_id = try requiredString(binding.registered, "id"), .digest = binding.digest };
            return workspace_runtime.execute(allocator, self.options.io, request, pkg, binding, .{ .context = &authority, .checkFn = Authority.check });
        }
        const policy = try self.codePolicy(binding, request.definition);
        const entry = try pkg.stepCode(request.step_id);
        const files = try allocator.alloc(code.File, pkg.files.len);
        for (pkg.files, files) |file, *retained| retained.* = .{ .path = file.path, .bytes = file.bytes };
        var authority: Authority = .{ .engine = self, .binding_id = try requiredString(binding.registered, "id"), .digest = binding.digest };
        return code.execute(allocator, self.options.io, .{ .step = request, .files = files, .entry = entry.path, .config = policy.config, .owner_token = request.run_id, .package_digest = pkg.digest, .bound_handles = policy.handles, .grants = policy.grants, .authority = .{ .context = &authority, .checkFn = Authority.check } });
    }
    pub fn run(self: *Engine, allocator: std.mem.Allocator, params: runner.Value, cancel_flag: *std.atomic.Value(bool), hooks: ?Hooks) !runner.Run {
        self.runtime_issue = .{};
        return self.runNew(allocator, params, cancel_flag, hooks, null, null, null);
    }
    /// Explicit new whole run, guarded by immutable attribution and durable evidence.
    pub fn retry(self: *Engine, allocator: std.mem.Allocator, params: runner.Value, cancel_flag: *std.atomic.Value(bool), hooks: ?Hooks) !runner.Run {
        self.runtime_issue = .{};
        const id = try requiredString(params, "runId");
        var store = try storage.Store.init(allocator, self.options.io, self.options.profile);
        defer store.deinit();
        // Read directly: get's orphan recovery must not rewrite the original run.
        const original = blk: {
            const lease = store.lock(id) catch |err| switch (err) {
                error.RunBusy => return error.RetryActiveRun,
                else => return err,
            };
            defer lease.close(self.options.io);
            break :blk try store.load(allocator, id);
        };
        defer original.deinit();
        const guidance = diagnostics.retryGuidance(original.value);
        if (!guidance.allowed) return retryError(guidance.reason);
        const input = try runner.get(original.value, "root_input");
        const hash = try diagnostics.inputSha256(allocator, input);
        if (!std.mem.eql(u8, &hash, try requiredString(original.value, "input_sha256"))) return error.RetryInvalidInput;
        var arguments = object();
        try put(original.arena.allocator(), &arguments, "packagePath", try runner.get(original.value, "package_path"));
        try put(original.arena.allocator(), &arguments, "bindingsId", try runner.get(original.value, "bindings_id"));
        try put(original.arena.allocator(), &arguments, "input", input);
        try put(original.arena.allocator(), &arguments, "inputSource", try runner.get(original.value, "input_source"));
        try put(original.arena.allocator(), &arguments, "expectedPackageDigest", try runner.get(original.value, "package_digest"));
        if (original.value.object.get("case_id")) |case_id| if (case_id == .string) try put(original.arena.allocator(), &arguments, "caseId", case_id);
        // A retry is the same run again: same package, same bindings, and the provider, model,
        // effort and tier the original recorded, not whatever the installation selects today.
        const recorded = original.value.object.get("selection") orelse return error.RetryMissingAttribution;
        const fast = if (recorded == .object) recorded.object.get("requestedFast") orelse return error.RetryMissingAttribution else return error.RetryMissingAttribution;
        if (fast != .bool) return error.RetryMissingAttribution;
        const pinned: runner.Selection = .{ .provider = optionalString(recorded, "provider") orelse return error.RetryMissingAttribution, .model = optionalString(recorded, "model") orelse return error.RetryMissingAttribution, .reasoning = optionalString(recorded, "reasoning") orelse return error.RetryMissingAttribution, .fast = fast.bool };
        return self.runNew(allocator, arguments, cancel_flag, hooks, id, try requiredString(original.value, "binding_digest"), pinned);
    }
    fn runNew(self: *Engine, allocator: std.mem.Allocator, params: runner.Value, cancel_flag: *std.atomic.Value(bool), hooks: ?Hooks, retry_of: ?[]const u8, expected_binding: ?[]const u8, pinned: ?runner.Selection) !runner.Run {
        self.input_size = null;
        self.input_note = null;
        const original_selection = self.options.selection;
        defer self.options.selection = original_selection;
        var pkg = try self.loadPackage(allocator, try requiredString(params, "packagePath"));
        defer pkg.deinit();
        if (self.options.expected_digest) |expected| if (!std.mem.eql(u8, expected, pkg.digest)) return error.PackageChanged;
        if (params.object.get("expectedPackageDigest")) |expected| {
            if (expected != .string) return error.InvalidRequest;
            if (!std.mem.eql(u8, expected.string, pkg.digest)) return error.PackageChanged;
        }
        // The driver belongs to this run, never to the package (loops/0.3 section 10).
        const agent_driven = if (params.object.get("driver")) |driver| blk: {
            if (driver != .string) return error.InvalidDriver;
            if (std.mem.eql(u8, driver.string, "agent")) break :blk true;
            if (!std.mem.eql(u8, driver.string, "runner")) return error.InvalidDriver;
            break :blk false;
        } else false;
        var parsed_input: ?std.json.Parsed(runner.Value) = null;
        defer if (parsed_input) |input| input.deinit();
        var input = params.object.get("input") orelse object();
        if (optionalString(params, "inputFile")) |path| {
            if (params.object.contains("input")) return error.InvalidInput;
            parsed_input = try self.readJsonFile(allocator, path);
            input = parsed_input.?.value;
        }
        const input_hash = try diagnostics.inputSha256(allocator, input);
        if (params.object.get("inputSource")) |value| if (value != .string) return error.InvalidRequest;
        const input_source = optionalString(params, "inputFile") orelse optionalString(params, "inputSource") orelse "inline";
        if (input_source.len == 0 or input_source.len > 4096) return error.InvalidRequest;
        const case_id = optionalString(params, "caseId");
        if (params.object.get("caseId")) |value| if (value != .string or value.string.len == 0 or value.string.len > 256) return error.InvalidRequest;
        // Crucially, no adapter/auth/runtime preflight occurs for invalid input.
        pkg.validateInput(input) catch {
            try self.explainInput(allocator, pkg, params.object.contains("input") or params.object.contains("inputFile"));
            return error.InvalidInput;
        };
        // An agent is shown each output schema on its own, so it must not point outside itself.
        if (agent_driven) for (pkg.leaves) |step| {
            if (!std.mem.eql(u8, try requiredString(step, "kind"), "code") and !selfContained(try pkg.stepSchema(try requiredString(step, "id")))) return error.UnsupportedPackage;
        };
        if (pinned) |selection| {
            self.options.selection = selection;
        } else if (hasInference(pkg.manifest) and !agent_driven) {
            if (self.options.resolveSelectionFn) |resolve| self.options.selection = try resolve(pkg.arena.allocator(), pkg.root);
        }
        const bindings_id = optionalString(params, "bindingsId") orelse "local";
        var binding = try bindings.load(allocator, self.options.io, self.options.profile, bindings_id);
        defer binding.deinit();
        if (expected_binding) |expected| if (!std.mem.eql(u8, expected, binding.digest)) return error.BindingChanged;
        // A batch pins the bindings its first case ran under, as it pins the package.
        if (params.object.get("expectedBindingDigest")) |expected| {
            if (expected != .string) return error.InvalidRequest;
            if (!std.mem.eql(u8, expected.string, binding.digest)) return error.BindingChanged;
        }
        if (hasDecision(pkg.manifest) and !hasInference(pkg.manifest) and !agent_driven) {
            const decided = try @import("decision.zig").selection(&binding);
            if (pinned) |selection| {
                if (!std.mem.eql(u8, selection.provider, decided.provider) or !std.mem.eql(u8, selection.model, decided.model)) return error.RetrySelectionUnavailable;
            } else self.options.selection = decided;
        }
        var store = try storage.Store.init(allocator, self.options.io, self.options.profile);
        defer store.deinit();
        // One installation foreground owner; crash releases lock, not effect truth.
        const foreground = try store.lock("foreground");
        defer foreground.close(self.options.io);
        try store.recoverAndRequireSettledResources();
        try store.reserve(64 * 1048576, 1024 * 1048576);
        const deadline_ms = self.options.deadline_ms orelse std.Io.Clock.awake.now(self.options.io).toMilliseconds() + @as(i64, binding.limits.max_seconds) * 1000;
        self.preflight(pkg, &binding, cancel_flag, deadline_ms, &store, agent_driven) catch |err| {
            // The recorded provider is gone or no longer the one that was used. A retry never
            // moves to another model by itself.
            if (pinned != null) switch (err) {
                error.InvalidSelection, error.UnknownConfiguredProvider, error.ConfiguredProviderChanged, error.UnsupportedInferenceProvider, error.UnsupportedInferenceProviderOption => return error.RetrySelectionUnavailable,
                else => {},
            };
            return err;
        };
        if (cancel_flag.load(.acquire)) return error.Cancelled;
        var random: [16]u8 = undefined;
        std.Io.random(self.options.io, &random);
        const id = try std.fmt.allocPrint(allocator, "run_{s}", .{std.fmt.bytesToHex(random, .lower)});
        defer allocator.free(id);
        const lease = try store.lock(id);
        defer lease.close(self.options.io);
        var watcher: Watcher = .{ .io = self.options.io, .dir = store.dir, .cancel_flag = cancel_flag, .name = try std.fmt.allocPrint(allocator, "{s}.cancel", .{id}) };
        defer allocator.free(watcher.name);
        const watching = try std.Thread.spawn(.{}, Watcher.watch, .{&watcher});
        defer {
            watcher.done.set(self.options.io);
            watching.join();
        }
        var authority: Authority = .{ .engine = self, .binding_id = try requiredString(binding.registered, "id"), .digest = binding.digest };
        // Capabilities serve the infer steps the runner performs; an agent-driven run has none.
        var resource: ?browser.Resource = null;
        defer if (resource) |*r| r.deinit();
        if (!agent_driven) for (pkg.leaves) |step| if (browser.required(step)) {
            resource = .{ .allocator = pkg.arena.allocator(), .io = self.options.io, .binary = try browser.configuredPath(pkg.arena.allocator(), self.options.io, &binding), .authority = .{ .context = &authority, .checkFn = Authority.check }, .evidence_dir = store.dir };
            break;
        };
        var workspace: ?workspace_read.Resource = null;
        if (!agent_driven) for (pkg.leaves) |step| if (workspace_read.required(step)) {
            workspace = .{ .io = self.options.io, .policy = try workspace_read.configured(&binding, self.options.io), .authority = .{ .context = &authority, .checkFn = Authority.check } };
            break;
        };
        var context: Context = .{ .engine = self, .pkg = pkg, .binding = &binding, .store = &store, .hooks = hooks, .browser_resource = if (resource) |*r| r else null, .workspace_resource = if (workspace) |*w| w else null };
        const package_path = try std.fs.path.join(pkg.arena.allocator(), &.{ pkg.root, pkg.manifest_path });
        var request: runner.Request = .{ .package_path = package_path, .bindings_id = try requiredString(binding.registered, "id"), .input_source = input_source, .input_sha256 = &input_hash, .case_id = case_id, .retry_of = retry_of, .run_id = id, .manifest = pkg.manifest, .input = input, .package_digest = pkg.digest, .binding_digest = binding.digest, .selection = self.options.selection, .limits = binding.limits, .cancel = cancel_flag, .deadline_ms = deadline_ms };
        if (!agent_driven) return runner.execute(allocator, request, context.ports());
        // What a later `next` or `submit`, in another process, needs to find this package again.
        var location = object();
        try put(pkg.arena.allocator(), &location, "packagePath", string(package_path));
        try put(pkg.arena.allocator(), &location, "bindingsId", string(bindings_id));
        request.agent = .{ .context = location };
        var driven = try runner.execute(allocator, request, context.ports());
        errdefer driven.deinit();
        try describe(&driven, pkg, &context);
        return driven;
    }
    /// loops/0.3 `next`: every step the driving agent must perform now, in path order. Reads
    /// the stored record and changes nothing, except to honour a cancel that is waiting for
    /// this run: then the run stops here and nothing is ready.
    pub fn next(self: *Engine, allocator: std.mem.Allocator, id: []const u8) !runner.Run {
        self.runtime_issue = .{};
        var never = std.atomic.Value(bool).init(false);
        return self.advance(allocator, id, null, &never);
    }
    /// loops/0.3 `submit`: one output for the path and pass `next` gave. An accepted output
    /// advances the run and executes the code steps that became ready.
    pub fn submit(self: *Engine, allocator: std.mem.Allocator, params: runner.Value, cancel_flag: *std.atomic.Value(bool)) !runner.Run {
        self.runtime_issue = .{};
        self.input_size = null;
        const id = try requiredString(params, "runId");
        const path = optionalString(params, "path") orelse return error.InvalidSubmission;
        const pass = params.object.get("pass") orelse return error.InvalidSubmission;
        if (pass != .integer) return error.InvalidSubmission;
        var parsed_output: ?std.json.Parsed(runner.Value) = null;
        defer if (parsed_output) |output| output.deinit();
        var output = params.object.get("output");
        // A file that holds no usable output is a fault in what was submitted, not in the run:
        // the step it names answers `rejected` and stays open (loops/0.3 section 10).
        var refusal_text: ?[]u8 = null;
        defer if (refusal_text) |message| allocator.free(message);
        if (optionalString(params, "outputFile")) |file| {
            if (output != null) return error.InvalidSubmission;
            output = .null;
            // Not being able to open the file at all is the caller's mistake and stays an error.
            if (self.readFileBytes(allocator, file)) |bytes| {
                defer allocator.free(bytes);
                if (parseOwned(allocator, bytes)) |parsed| {
                    parsed_output = parsed;
                    output = parsed.value;
                } else |err| {
                    if (err == error.OutOfMemory) return err;
                    refusal_text = try std.fmt.allocPrint(allocator, "The output file could not be read as one JSON value ({s}).", .{@errorName(err)});
                }
            } else |err| {
                const size = self.input_size orelse return err;
                if (err != error.InvalidInput) return err;
                refusal_text = try std.fmt.allocPrint(allocator, "The output file is {d} bytes; an output file may be at most {d} bytes.", .{ size, input_limit });
                self.input_size = null;
            }
        }
        return self.advance(allocator, id, .{ .path = path, .pass = std.math.cast(u32, pass.integer) orelse return error.InvalidSubmission, .output = output orelse return error.InvalidSubmission, .refusal = refusal_text }, cancel_flag);
    }
    fn advance(self: *Engine, allocator: std.mem.Allocator, id: []const u8, submission: ?runner.Submission, cancel_flag: *std.atomic.Value(bool)) !runner.Run {
        var store = try storage.Store.init(allocator, self.options.io, self.options.profile);
        defer store.deinit();
        // An unknown run is refused before any lock file is made for it.
        (try store.load(allocator, id)).deinit();
        // A submission may execute code, so it owns the installation exactly as `run` does.
        const foreground: ?std.Io.File = if (submission != null) try store.lock("foreground") else null;
        defer if (foreground) |held| held.close(self.options.io);
        if (submission != null) {
            try store.recoverAndRequireSettledResources();
            try store.reserve(64 * 1048576, 1024 * 1048576);
        }
        const lease = try store.lock(id);
        defer lease.close(self.options.io);
        const stored = try store.load(allocator, id);
        defer stored.deinit();
        const record = stored.value;
        if (!agentDriven(record)) return error.NotAgentDriven;
        const status = try requiredString(record, "status");
        var parked: Parked = .{ .engine = self, .store = &store };
        // A cancel that found this run busy left its request behind. It was reported as done,
        // so it is honoured here, before this operation reads or accepts anything.
        const cancelling = storage.awaitingDriver(record) and try cancelRequested(&store, id);
        if (cancelling or (!std.mem.eql(u8, status, "queued") and !std.mem.eql(u8, status, "running"))) {
            // A terminal run needs no package: nothing is ready, and a repeated submission is
            // answered from what the record committed.
            var stop = std.atomic.Value(bool).init(true);
            var ended = try runner.execute(allocator, .{ .run_id = id, .manifest = .null, .input = .null, .cancel = if (cancelling) &stop else cancel_flag, .deadline_ms = 0, .agent = .{ .record = record, .op = if (cancelling) .cancel else .peek, .submission = submission } }, parked.ports());
            errdefer ended.deinit();
            ended.next = .{ .array = std.array_list.Managed(runner.Value).init(ended.arena.allocator()) };
            // Nothing can cancel a run that has ended, so its request has nothing left to do.
            try clearCancel(&store, id);
            return ended;
        }
        // An operation that died part way may have left code running: never continue over it.
        if (!storage.awaitingDriver(record)) return error.RecoveryRequired;
        const location = try runner.get(record, "agent");
        var pkg = try self.loadPackage(allocator, try requiredString(location, "packagePath"));
        defer pkg.deinit();
        if (!std.mem.eql(u8, pkg.digest, try requiredString(record, "package_digest"))) return error.RunPackageChanged;
        var binding = try bindings.load(allocator, self.options.io, self.options.profile, try requiredString(location, "bindingsId"));
        defer binding.deinit();
        if (!std.mem.eql(u8, binding.digest, try requiredString(record, "binding_digest"))) return error.PermissionDenied;
        // The time limit bounds the code each operation executes; the agent's own inference
        // between operations is not the runner's work.
        const deadline_ms = self.options.deadline_ms orelse std.Io.Clock.awake.now(self.options.io).toMilliseconds() + @as(i64, binding.limits.max_seconds) * 1000;
        var context: Context = .{ .engine = self, .pkg = pkg, .binding = &binding, .store = &store };
        var request: runner.Request = .{ .run_id = id, .manifest = pkg.manifest, .input = .null, .limits = binding.limits, .cancel = cancel_flag, .deadline_ms = deadline_ms, .agent = .{ .record = record, .op = .peek } };
        if (submission) |submitted| {
            try self.preflight(pkg, &binding, cancel_flag, deadline_ms, &store, true);
            if (cancel_flag.load(.acquire)) return error.Cancelled;
            context.submitted = submitted.path[if (std.mem.lastIndexOfScalar(u8, submitted.path, '/')) |slash| slash + 1 else 0..];
            request.agent = .{ .record = record, .submission = submitted };
        }
        var watcher: Watcher = .{ .io = self.options.io, .dir = store.dir, .cancel_flag = cancel_flag, .name = try std.fmt.allocPrint(allocator, "{s}.cancel", .{id}) };
        defer allocator.free(watcher.name);
        const watching: ?std.Thread = if (submission != null) try std.Thread.spawn(.{}, Watcher.watch, .{&watcher}) else null;
        defer if (watching) |thread| {
            watcher.done.set(self.options.io);
            thread.join();
        };
        var driven = try runner.execute(allocator, request, context.ports());
        errdefer driven.deinit();
        // The record said the run was waiting. A read that finds otherwise cannot be trusted.
        if (submission == null and !storage.awaitingDriver(driven.record)) return error.RecoveryRequired;
        try describe(&driven, pkg, &context);
        // A cancel that arrived while this submission ran either stopped it or came too late to:
        // once the run has ended its request is spent. A run still waiting keeps it for the
        // next operation to honour.
        if (submission != null and terminalRecord(driven.record)) try clearCancel(&store, id);
        return driven;
    }
    /// An agent-driven run waiting for its agent has no process to signal, so `cancel` stops
    /// it here, under its own lock. False when another process owns the run right now.
    fn stopWaiting(self: *Engine, allocator: std.mem.Allocator, store: *storage.Store, id: []const u8) !bool {
        const lease = store.lock(id) catch |err| switch (err) {
            error.RunBusy => return false,
            else => return err,
        };
        defer lease.close(self.options.io);
        const stored = try store.load(allocator, id);
        defer stored.deinit();
        if (!storage.awaitingDriver(stored.value)) {
            if (terminalRecord(stored.value)) try clearCancel(store, id);
            return false;
        }
        var parked: Parked = .{ .engine = self, .store = store };
        var stop = std.atomic.Value(bool).init(true);
        var stopped = try runner.execute(allocator, .{ .run_id = id, .manifest = .null, .input = .null, .cancel = &stop, .deadline_ms = 0, .agent = .{ .record = stored.value, .op = .cancel } }, parked.ports());
        stopped.deinit();
        try clearCancel(store, id);
        return true;
    }
    /// Reads one bounded JSON file: a run's input or a submission's output.
    fn readJsonFile(self: *Engine, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(runner.Value) {
        const bytes = try self.readFileBytes(allocator, path);
        defer allocator.free(bytes);
        return parseOwned(allocator, bytes);
    }
    fn readFileBytes(self: *Engine, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        // O_NONBLOCK prevents a FIFO open from waiting for a writer; the
        // retained handle must be regular before reading any bytes.
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0);
        var file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
        defer file.close(self.options.io);
        const stat = try file.stat(self.options.io);
        return self.readInputBytes(allocator, file, stat);
    }
    fn parseOwned(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(runner.Value) {
        // Retain strict bounded input without any provider/runtime action.
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        return .{ .arena = arena, .value = try schema.parse(arena.allocator(), bytes) };
    }
    fn readInputBytes(self: *Engine, allocator: std.mem.Allocator, file: std.Io.File, stat: std.Io.File.Stat) ![]u8 {
        if (stat.kind != .file) return error.InvalidInput;
        if (stat.size > input_limit) {
            self.input_size = stat.size;
            return error.InvalidInput;
        }
        var buffer: [8192]u8 = undefined;
        var reader = file.reader(self.options.io, &buffer);
        // Read at most cap+1: one sentinel detects growth after stat without
        // silently truncating the input or opening an unbounded read.
        const bytes = reader.interface.allocRemaining(allocator, .limited(input_limit + 1)) catch |err| {
            if (err == error.StreamTooLong) {
                const grown = try file.stat(self.options.io);
                self.input_size = @max(grown.size, input_limit + 1);
                return error.InvalidInput;
            }
            return err;
        };
        if (bytes.len > input_limit) {
            self.input_size = bytes.len;
            allocator.free(bytes);
            return error.InvalidInput;
        }
        return bytes;
    }
    pub fn get(self: *Engine, allocator: std.mem.Allocator, id: []const u8) !std.json.Parsed(runner.Value) {
        self.runtime_issue = .{};
        var store = try storage.Store.init(allocator, self.options.io, self.options.profile);
        defer store.deinit();
        var result = try store.load(allocator, id);
        errdefer result.deinit();
        const status = try requiredString(result.value, "status");
        if (std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "running")) {
            // Waiting for its agent is not an orphan: nothing is in flight to recover.
            if (storage.awaitingDriver(result.value)) return result;
            try self.recover(allocator, &store, id, &result);
        }
        return result;
    }
    /// Marks a run nothing owns as stopped. `result` was read before the lock was held, so it
    /// only says the run is worth a look: the record judged and saved is the one read under
    /// the lock, and a run found waiting or finished there is returned exactly as stored.
    fn recover(self: *Engine, allocator: std.mem.Allocator, store: *storage.Store, id: []const u8, result: *std.json.Parsed(runner.Value)) !void {
        const lease = store.lock(id) catch |err| switch (err) {
            error.RunBusy => return,
            else => return err,
        };
        defer lease.close(self.options.io);
        const current = try store.load(allocator, id);
        result.deinit();
        result.* = current;
        _ = try store.recoverAbandoned(result);
    }
    /// Records what a person found for an effect fh could not know the outcome of: it took
    /// effect, or it did not. Refused unless the run really has such an effect. Nothing is
    /// executed, and nothing else in the record changes.
    pub fn settle(self: *Engine, allocator: std.mem.Allocator, params: runner.Value) !runner.Value {
        self.runtime_issue = .{};
        const id = try requiredString(params, "runId");
        const outcome = try requiredString(params, "outcome");
        const applied = std.mem.eql(u8, outcome, "applied");
        if (!applied and !std.mem.eql(u8, outcome, "not_applied")) return error.InvalidRequest;
        if (params.object.get("effect")) |named| if (named != .string) return error.InvalidRequest;
        const wanted = optionalString(params, "effect");
        try storage.validId(id);
        var store = try storage.Store.init(allocator, self.options.io, self.options.profile);
        defer store.deinit();
        // The installation's one owner: no run is admitted or advanced while a receipt changes.
        const foreground = try store.lock("foreground");
        defer foreground.close(self.options.io);
        var result = object();
        try put(allocator, &result, "run_id", string(try allocator.dupe(u8, id)));
        // An interrupted run is first recorded as stopped, exactly as `get` does.
        if (self.get(allocator, id)) |current| current.deinit() else |err| {
            if (err != error.FileNotFound) return err;
            // No record at all. A marker without one is a run that was reserved and never
            // started; an id with neither is unknown, and no lock file is made for it.
            const marker = try std.fmt.allocPrint(allocator, "{s}.pending", .{id});
            _ = try store.dir.statFile(self.options.io, marker, .{ .follow_symlinks = false });
            if (applied or wanted != null) return error.NothingToSettle;
            const lease = try store.lock(id);
            defer lease.close(self.options.io);
            try store.clearOrphanMarker(id);
            try put(allocator, &result, "cleared", string("unwritten_run"));
            try put(allocator, &result, "uncertain_effects", .{ .bool = false });
            return result;
        }
        const lease = try store.lock(id);
        defer lease.close(self.options.io);
        const stored = try store.load(allocator, id);
        defer stored.deinit();
        const a = stored.arena.allocator();
        const effects = stored.value.object.getPtr("effects") orelse return error.NothingToSettle;
        if (effects.* != .array) return error.InvalidRunRecord;
        var target: ?*runner.Value = null;
        for (effects.array.items) |*effect| {
            if (!std.mem.eql(u8, try requiredString(effect.*, "state"), "unknown")) continue;
            if (wanted) |name| if (!std.mem.eql(u8, name, try requiredString(effect.*, "id"))) continue;
            // One outcome answers one question: with several open, the person names which.
            if (target != null) return error.SettleEffectRequired;
            target = effect;
        }
        const effect = target orelse return error.NothingToSettle;
        try put(a, effect, "state", string(if (applied) "applied" else "not_applied"));
        try put(a, effect, "settled_by", string("operator"));
        try store.save(stored.value);
        // The answer outlives the stored record it was read from.
        const public = try publicResult(a, stored.value);
        const owned = try std.json.parseFromSliceLeaky(runner.Value, allocator, try std.json.Stringify.valueAlloc(allocator, public, .{}), .{ .allocate = .alloc_always });
        try put(allocator, &result, "effect", string(try allocator.dupe(u8, try requiredString(effect.*, "id"))));
        try put(allocator, &result, "state", string(if (applied) "applied" else "not_applied"));
        try put(allocator, &result, "run_status", try runner.get(owned, "status"));
        try put(allocator, &result, "effects", try runner.get(owned, "effects"));
        try put(allocator, &result, "uncertain_effects", try runner.get(owned, "uncertain_effects"));
        return result;
    }
    pub fn startup(self: *Engine, allocator: std.mem.Allocator, workspace: []const u8, assets: []const u8, cancel_flag: *std.atomic.Value(bool)) !runner.Value {
        self.runtime_issue = .{};
        const deadline = std.Io.Clock.awake.now(self.options.io).toMilliseconds() + 2000;
        const captured = try @import("workspace.zig").capture(allocator, self.options.io, workspace, cancel_flag, deadline);
        if (cancel_flag.load(.acquire)) return startupUnavailable(allocator, "cancelled");
        var options = self.options;
        options.deadline_ms = deadline;
        options.expected_digest = "e0c4c05ad8ea4a9365f98edb956fe440ba1df5a98f404b2792707b2874571c3b";
        options.decisionFn = null;
        options.decisionPreflightFn = null;
        options.inferFn = null;
        options.inferPreflightFn = null;
        var service: Engine = .{ .options = options };
        var params = object();
        try put(allocator, &params, "packagePath", string(try std.fs.path.join(allocator, &.{ assets, "loops/workspace-check" })));
        try put(allocator, &params, "input", captured);
        var run_result = service.run(allocator, params, cancel_flag, null) catch |err| return startupUnavailable(allocator, errorCode(err));
        defer run_result.deinit();
        if (!std.mem.eql(u8, try requiredString(run_result.record, "status"), "completed")) return startupUnavailable(allocator, if (cancel_flag.load(.acquire)) "cancelled" else "check_failed");
        var result = object();
        try put(allocator, &result, "available", .{ .bool = true });
        const output = try std.json.Stringify.valueAlloc(allocator, try runner.get(run_result.record, "output"), .{});
        try put(allocator, &result, "output", try schema.parse(allocator, output));
        try put(allocator, &result, "run_id", string(try allocator.dupe(u8, try requiredString(run_result.record, "run_id"))));
        return result;
    }
    pub fn list(self: *Engine, allocator: std.mem.Allocator, after: ?[]const u8) !runner.Value {
        self.runtime_issue = .{};
        var store = try storage.Store.init(allocator, self.options.io, self.options.profile);
        defer store.deinit();
        var ids: std.ArrayList([]const u8) = .empty;
        var iterator = store.dir.iterate();
        while (try iterator.next(self.options.io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json") or !std.mem.startsWith(u8, entry.name, "run_")) continue;
            if (ids.items.len >= 10000) return error.RegistryLimit;
            try ids.append(allocator, try allocator.dupe(u8, entry.name[0 .. entry.name.len - 5]));
        }
        std.mem.sort([]const u8, ids.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        var runs: runner.Value = .{ .array = std.array_list.Managed(runner.Value).init(allocator) };
        var following: ?[]const u8 = null;
        for (ids.items) |id| {
            if (after) |cursor| if (!std.mem.lessThan(u8, cursor, id)) continue;
            if (runs.array.items.len >= 100) {
                following = try requiredString(runs.array.items[runs.array.items.len - 1], "run_id");
                break;
            }
            const record = try self.get(allocator, id);
            defer record.deinit();
            var summary = object();
            try put(allocator, &summary, "run_id", string(id));
            try put(allocator, &summary, "status", string(try allocator.dupe(u8, try requiredString(record.value, "status"))));
            try runs.array.append(summary);
        }
        var result = object();
        try put(allocator, &result, "runs", runs);
        try put(allocator, &result, "next", if (following) |id| string(id) else .null);
        return result;
    }
    pub fn cancel(self: *Engine, allocator: std.mem.Allocator, id: []const u8) !runner.Value {
        self.runtime_issue = .{};
        const current = try self.get(allocator, id);
        defer current.deinit();
        const status = try requiredString(current.value, "status");
        const active = std.mem.eql(u8, status, "running") or std.mem.eql(u8, status, "queued");
        var store = try storage.Store.init(allocator, self.options.io, self.options.profile);
        defer store.deinit();
        if (active and !(agentDriven(current.value) and try self.stopWaiting(allocator, &store, id))) {
            const name = try std.fmt.allocPrint(allocator, "{s}.cancel", .{id});
            var file = store.dir.createFile(self.options.io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
                error.PathAlreadyExists => try store.dir.openFile(self.options.io, name, .{ .mode = .read_write, .follow_symlinks = false }),
                else => return err,
            };
            defer file.close(self.options.io);
            try storage.privateHandle(file.handle, true);
            try file.sync(self.options.io);
            // Whoever held the run may have let go since. Settle it now if so; otherwise the
            // request stays, and the holder or the run's next operation honours it.
            if (agentDriven(current.value)) _ = try self.stopWaiting(allocator, &store, id);
        }
        var result = object();
        try put(allocator, &result, "run_id", string(try allocator.dupe(u8, id)));
        try put(allocator, &result, "cancelled", .{ .bool = active });
        return result;
    }
};
const Watcher = struct {
    io: std.Io,
    dir: std.Io.Dir,
    cancel_flag: *std.atomic.Value(bool),
    name: []const u8,
    done: std.Io.Event = .unset,
    fn watch(self: *Watcher) void {
        while (!self.done.isSet()) {
            if (self.dir.statFile(self.io, self.name, .{ .follow_symlinks = false })) |_| {
                self.cancel_flag.store(true, .release);
                return;
            } else |err| if (err != error.FileNotFound) {
                self.cancel_flag.store(true, .release);
                return;
            }
            self.done.waitTimeout(self.io, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(25) } }) catch |err| switch (err) {
                error.Timeout => continue,
                error.Canceled => {
                    self.cancel_flag.store(true, .release);
                    return;
                },
            };
        }
    }
};
pub fn publicResult(allocator: std.mem.Allocator, record: runner.Value) !runner.Value {
    var result = object();
    for ([_][]const u8{ "run_id", "status", "driver", "awaiting_driver", "selection", "package_path", "bindings_id", "input_source", "input_sha256", "case_id", "retry_of", "package_digest", "binding_digest", "output", "stop", "error", "failure_cause", "used_tokens", "model_request_dispatches", "model_request_dispatches_complete", "used_operations", "used_tool_calls", "usage_unknown", "recovery_required" }) |key| if (record.object.get(key)) |value| try put(allocator, &result, key, value);
    var executions: runner.Value = .{ .array = std.array_list.Managed(runner.Value).init(allocator) };
    if (record.object.get("attempts")) |attempts| for (attempts.array.items) |attempt| {
        if (attempt.object.get("code_execution")) |identity| {
            var summary = object();
            for ([_][]const u8{ "step_id", "path", "iteration", "status" }) |key| if (attempt.object.get(key)) |value| try put(allocator, &summary, key, value);
            try put(allocator, &summary, "execution", identity);
            try executions.array.append(summary);
        }
    };
    try put(allocator, &result, "code_executions", executions);
    var effects: runner.Value = .{ .array = std.array_list.Managed(runner.Value).init(allocator) };
    var unknown = false;
    var truncated = false;
    if (record.object.get("effects")) |receipts| for (receipts.array.items) |receipt| {
        if (std.mem.eql(u8, try requiredString(receipt, "state"), "unknown")) unknown = true;
        if (effects.array.items.len >= 64) {
            truncated = true;
            continue;
        }
        var summary = object();
        for ([_][]const u8{ "id", "kind", "state" }) |key| try put(allocator, &summary, key, try runner.get(receipt, key));
        try effects.array.append(summary);
    };
    try put(allocator, &result, "effects", effects);
    try put(allocator, &result, "effects_truncated", .{ .bool = truncated });
    try put(allocator, &result, "uncertain_effects", .{ .bool = unknown });
    try put(allocator, &result, "diagnostic", try diagnostics.diagnostic(allocator, record));
    return result;
}
/// The result of an agent-driver operation: the run's public state, the steps the agent must
/// perform now, and for `submit` its answer with the schema errors or the committed output.
pub fn agentResult(allocator: std.mem.Allocator, run: runner.Run) !runner.Value {
    var result = try publicResult(allocator, run.record);
    if (run.answer) |answer| try put(allocator, &result, "answer", string(@tagName(answer)));
    if (run.issues) |issues| try put(allocator, &result, "issues", issues);
    if (run.committed) |committed| try put(allocator, &result, "committed", committed);
    try put(allocator, &result, "next", run.next orelse runner.Value{ .array = std.array_list.Managed(runner.Value).init(allocator) });
    return result;
}
/// Turns the runner's ready steps into the public `next` list, owned by the run: path, kind,
/// pass, resolved input, output schema, and instructions or questions.
fn describe(run: *runner.Run, pkg: *package.Package, context: *const Context) !void {
    const a = run.arena.allocator();
    var steps: runner.Value = .{ .array = std.array_list.Managed(runner.Value).init(a) };
    for (run.ready) |ready| {
        var step = object();
        try put(a, &step, "path", string(ready.path));
        try put(a, &step, "kind", string(ready.kind));
        try put(a, &step, "pass", .{ .integer = ready.pass });
        try put(a, &step, "input", ready.input);
        try put(a, &step, "output_schema", try pkg.stepSchema(ready.step_id));
        if (std.mem.eql(u8, ready.kind, "infer")) {
            try put(a, &step, "instructions", try runner.get(try pkg.resolved(a, ready.definition), "instructions"));
        } else try put(a, &step, "questions", try runner.get(ready.definition, "questions"));
        // The agent performs the step, so the capabilities it declares are the agent's to supply.
        for ([_][]const u8{ "requires", "complexity" }) |key| if (ready.definition.object.get(key)) |declared| try put(a, &step, key, declared);
        try steps.array.append(step);
    }
    // Schemas and instructions belong to the package, which does not outlive this operation.
    run.next = (try std.json.parseFromSliceLeaky(runner.Value, a, try std.json.Stringify.valueAlloc(a, steps, .{}), .{ .allocate = .alloc_always }));
    if (run.answer) |answer| if (answer == .rejected) {
        var issues: runner.Value = .{ .array = std.array_list.Managed(runner.Value).init(a) };
        if (run.refusal) |message| {
            var issue = object();
            try put(a, &issue, "path", string(""));
            try put(a, &issue, "message", string(message));
            try issues.array.append(issue);
        } else if (context.rejection) |diagnostic| {
            var issue = object();
            try put(a, &issue, "path", string(try a.dupe(u8, diagnostic.path)));
            try put(a, &issue, "message", string(try a.dupe(u8, diagnostic.message)));
            try issues.array.append(issue);
        }
        run.issues = issues;
    };
}
/// `<id>.cancel` asks whoever owns the run to stop it. Anything but a plain absence counts as
/// a request, as it does for the watcher of a run in flight.
fn cancelRequested(store: *storage.Store, id: []const u8) !bool {
    const name = try std.fmt.allocPrint(store.allocator, "{s}.cancel", .{id});
    defer store.allocator.free(name);
    _ = store.dir.statFile(store.io, name, .{ .follow_symlinks = false }) catch |err| return err != error.FileNotFound;
    return true;
}
fn clearCancel(store: *storage.Store, id: []const u8) !void {
    const name = try std.fmt.allocPrint(store.allocator, "{s}.cancel", .{id});
    defer store.allocator.free(name);
    store.dir.deleteFile(store.io, name) catch |err| if (err != error.FileNotFound) return err;
}
fn terminalRecord(record: runner.Value) bool {
    const status = optionalString(record, "status") orelse return false;
    return !std.mem.eql(u8, status, "queued") and !std.mem.eql(u8, status, "running");
}
fn agentDriven(record: runner.Value) bool {
    const driver = optionalString(record, "driver") orelse return false;
    return std.mem.eql(u8, driver, "agent");
}
/// Whether a schema can be read on its own: `$ref` only to "#...". Values a schema holds as
/// data (`const`, `enum`, `default`, `examples`) are not references.
fn selfContained(value: runner.Value) bool {
    switch (value) {
        .object => |map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.eql(u8, key, "$ref") and entry.value_ptr.* == .string) {
                    if (!std.mem.startsWith(u8, entry.value_ptr.string, "#")) return false;
                    continue;
                }
                if (std.mem.eql(u8, key, "const") or std.mem.eql(u8, key, "enum") or std.mem.eql(u8, key, "default") or std.mem.eql(u8, key, "examples")) continue;
                if (!selfContained(entry.value_ptr.*)) return false;
            }
            return true;
        },
        .array => |list| {
            for (list.items) |item| if (!selfContained(item)) return false;
            return true;
        },
        else => return true,
    }
}
fn agentMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidDriver => "The driver must be runner or agent.",
        error.NotAgentDriven => "This run is not driven by an agent. Start one with fh run PACKAGE --driver agent, then use next and submit.",
        error.InvalidSubmission => "A submission needs the run, and the path, pass and output of one step that next listed.",
        error.UnsupportedPackage => "An agent is shown each output schema on its own. Every infer and decision output schema must be self-contained, with $ref only to \"#...\", before an agent can drive this package.",
        error.RunPackageChanged => "The package changed after this run started. Restore it, or cancel this run and start a new one.",
        error.RunBusy => "Another fh operation is in progress on this installation or run. The requested operation was not started; earlier orphan bookkeeping may have occurred. Retry when it has finished.",
        error.NothingToSettle => "This run has no uncertain effect to settle. Nothing was changed.",
        error.SettleEffectRequired => "This run has more than one uncertain effect. Name one with --effect ID. fh get RUN lists them. Nothing was changed.",
        error.WorkspaceReadOnlyGrant => "This workspace grant is read-only: it registers no host commands, so an fh-workspace/1 step cannot run with it. Register a grant that lists the commands with fh setup workspace GRANT.json --trust-host, and use that binding.",
        error.RetrySelectionUnavailable => "The provider and model this run used are no longer available on this installation, so retry was refused and nothing ran. Restore that provider, or start a new run with fh run to use the current selection.",
        else => null,
    };
}
/// Ports for a run that executes nothing: a terminal run being read, or a waiting run being stopped.
const Parked = struct {
    engine: *Engine,
    store: *storage.Store,
    fn cast(raw: *anyopaque) *Parked {
        return @ptrCast(@alignCast(raw));
    }
    fn execute(_: *anyopaque, _: std.mem.Allocator, _: runner.StepRequest) !runner.StepResult {
        return error.UnexpectedExecution;
    }
    fn validate(_: *anyopaque, _: ?[]const u8, _: runner.Value) !void {
        return error.UnexpectedExecution;
    }
    fn persist(raw: *anyopaque, value: runner.Value, encoded: []const u8) !void {
        try cast(raw).store.saveEncoded(try requiredString(value, "run_id"), encoded);
    }
    fn now(raw: *anyopaque) i64 {
        return std.Io.Clock.awake.now(cast(raw).engine.options.io).toMilliseconds();
    }
    fn ports(self: *Parked) runner.Ports {
        return .{ .context = self, .executeFn = execute, .validateFn = validate, .persistFn = persist, .nowFn = now };
    }
};
fn startupUnavailable(allocator: std.mem.Allocator, reason: []const u8) !runner.Value {
    var result = object();
    try put(allocator, &result, "available", .{ .bool = false });
    try put(allocator, &result, "reason", string(reason));
    return result;
}
const Probe = struct {
    alloc: std.mem.Allocator,
    store: *storage.Store,
    record: runner.Value,
    fn effect(raw: *anyopaque, receipt: runner.Effect) !void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        const effects = self.record.object.getPtr("effects").?;
        for (effects.array.items) |*old| if (std.mem.eql(u8, try requiredString(old.*, "id"), receipt.id)) {
            if (!std.mem.eql(u8, try requiredString(old.*, "kind"), receipt.kind)) return error.ReceiptConflict;
            if (std.mem.eql(u8, try requiredString(old.*, "state"), "applied") and receipt.state != .applied) return error.ReceiptConflict;
            if (receipt.details) |details| {
                const previous = try runner.get(old.*, "details");
                const a = try std.json.Stringify.valueAlloc(self.alloc, previous, .{});
                const b = try std.json.Stringify.valueAlloc(self.alloc, details, .{});
                if (!std.mem.eql(u8, a, b)) return error.ReceiptConflict;
            }
            try put(self.alloc, old, "state", string(@tagName(receipt.state)));
            try self.store.save(self.record);
            return;
        };
        var value = object();
        try put(self.alloc, &value, "id", string(try self.alloc.dupe(u8, receipt.id)));
        try put(self.alloc, &value, "kind", string(try self.alloc.dupe(u8, receipt.kind)));
        try put(self.alloc, &value, "state", string(@tagName(receipt.state)));
        if (receipt.details) |details| {
            const bytes = try std.json.Stringify.valueAlloc(self.alloc, details, .{});
            if (bytes.len > 65536) return error.InvalidReceipt;
            try put(self.alloc, &value, "details", try schema.parse(self.alloc, bytes));
        }
        if (effects.array.items.len >= 1024) return error.HistoryLimit;
        try effects.array.append(value);
        try self.store.save(self.record);
    }
};
const Context = struct {
    engine: *Engine,
    pkg: *package.Package,
    binding: *bindings.Binding,
    store: *storage.Store,
    hooks: ?Hooks = null,
    notified: bool = false,
    browser_resource: ?*browser.Resource = null,
    workspace_resource: ?*workspace_read.Resource = null,
    // The step a submission names, and why its output was rejected.
    submitted: ?[]const u8 = null,
    rejection: ?schema.Diagnostic = null,
    fn cast(raw: *anyopaque) *Context {
        return @ptrCast(@alignCast(raw));
    }
    fn validate(raw: *anyopaque, id: ?[]const u8, value: runner.Value) !void {
        const self = cast(raw);
        if (id) |step| self.pkg.validateStepOutput(step, value) catch {
            if (self.submitted) |target| if (self.rejection == null and std.mem.eql(u8, target, step)) {
                self.rejection = self.pkg.validation_error;
            };
            return error.InvalidOutput;
        } else self.pkg.validateInput(value) catch return error.InvalidInput;
    }
    fn persist(raw: *anyopaque, value: runner.Value, encoded: []const u8) !void {
        const self = cast(raw);
        try self.store.saveEncoded(try requiredString(value, "run_id"), encoded);
        if (!self.notified) {
            self.notified = true;
            if (self.hooks) |hook| try hook.acceptedFn(hook.context, try requiredString(value, "run_id"), self.pkg, hasInference(self.pkg.manifest) or hasDecision(self.pkg.manifest));
        }
    }
    fn finalize(raw: *anyopaque, alloc: std.mem.Allocator, record: *runner.Value) !void {
        const self = cast(raw);
        const resource = self.browser_resource orelse return;
        const cleanup_error: ?anyerror = if (resource.cleanup()) |_| null else |err| err;
        var receipt = object();
        try put(alloc, &receipt, "id", string("browser-cleanup"));
        try put(alloc, &receipt, "kind", string("browser_cleanup"));
        try put(alloc, &receipt, "state", string(if (cleanup_error == null) "applied" else "unknown"));
        var details = object();
        try put(alloc, &details, "launch_attempted", .{ .bool = resource.launched });
        try put(alloc, &details, "launched", .{ .bool = resource.ready });
        try put(alloc, &details, "reaped", .{ .bool = resource.ready and cleanup_error == null });
        if (resource.startup_ms) |ms| try put(alloc, &details, "cold_start_ms", .{ .integer = ms });
        var timings = runner.Value{ .array = std.array_list.Managed(runner.Value).init(alloc) };
        for (resource.timings.items) |timing| {
            var value = object();
            try put(alloc, &value, "operation_id", string(try std.fmt.allocPrint(alloc, "browser-{d}", .{timing.sequence})));
            try put(alloc, &value, "operation_ms", .{ .integer = timing.operation_ms });
            try timings.array.append(value);
        }
        try put(alloc, &details, "operations", timings);
        try put(alloc, &receipt, "details", details);
        try record.object.getPtr("effects").?.array.append(receipt);
        if (cleanup_error) |err| {
            try put(alloc, record, "cleanup_error", string(@errorName(err)));
            // A cleanup failure must not replace the primary step failure.
            if (std.mem.eql(u8, try requiredString(record.*, "status"), "completed")) {
                try put(alloc, record, "status", string("stopped"));
                _ = record.object.swapRemove("output");
                var reason = object();
                try put(alloc, &reason, "reason", string("uncertain_effect"));
                try put(alloc, &reason, "cause", string("CleanupPending"));
                try put(alloc, record, "stop", reason);
            }
        }
    }
    fn now(raw: *anyopaque) i64 {
        return std.Io.Clock.awake.now(cast(raw).engine.options.io).toMilliseconds();
    }
    fn stepSchema(raw: *anyopaque, id: []const u8) !runner.Value {
        return cast(raw).pkg.stepSchema(id);
    }
    fn execute(raw: *anyopaque, allocator: std.mem.Allocator, request: runner.StepRequest) !runner.StepResult {
        const self = cast(raw);
        const options = self.engine.options;
        if (std.mem.eql(u8, try requiredString(request.definition, "kind"), "code")) {
            if (std.mem.eql(u8, optionalString(request.definition, "runtime") orelse "", wasm.runtime)) return self.engine.nativeCode(allocator, request, self.pkg, self.binding);
            if (options.codeFn) |callback| return callback(options.code_context orelse self, allocator, request, self.pkg, self.binding);
            return self.engine.nativeCode(allocator, request, self.pkg, self.binding);
        }
        if (std.mem.eql(u8, try requiredString(request.definition, "kind"), "decision")) return (options.decisionFn orelse return error.UnsupportedDecision)(options.decision_context orelse self, allocator, request, self.pkg, self.binding);
        var injected = request;
        injected.definition = try self.pkg.resolved(allocator, request.definition);
        if (browser.required(request.definition)) if (self.browser_resource) |resource| {
            injected.capability = .{ .context = resource, .callFn = browser.Resource.call };
        };
        if (workspace_read.required(request.definition)) if (self.workspace_resource) |resource| {
            injected.capability = .{ .context = resource, .callFn = workspace_read.Resource.call };
        };
        return (options.inferFn orelse return error.UnsupportedInference)(options.infer_context orelse self, allocator, injected, self.pkg, self.binding);
    }
    fn ports(self: *Context) runner.Ports {
        return .{ .context = self, .executeFn = execute, .validateFn = validate, .persistFn = persist, .nowFn = now, .schemaFn = stepSchema, .finalizeFn = finalize };
    }
};
const Authority = struct {
    engine: *Engine,
    binding_id: []const u8,
    digest: []const u8,
    fn check(raw: *anyopaque) !void {
        const self: *Authority = @ptrCast(@alignCast(raw));
        var current = try bindings.load(std.heap.c_allocator, self.engine.options.io, self.engine.options.profile, self.binding_id);
        defer current.deinit();
        if (!std.mem.eql(u8, current.digest, self.digest)) return error.PermissionDenied;
    }
};
fn privateDirectory(io: std.Io, path: []const u8) !void {
    std.Io.Dir.createDirAbsolute(io, path, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
    var dir = try storage.openDirectory(io, path);
    defer dir.close(io);
    try storage.privateHandle(dir.handle, false);
}
pub fn hasInference(manifest: runner.Value) bool {
    return runner.hasKind(manifest.object.get("steps").?, "infer");
}
pub fn hasDecision(manifest: runner.Value) bool {
    return runner.hasKind(manifest.object.get("steps").?, "decision");
}
pub fn optionalString(value: runner.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const item = value.object.get(key) orelse return null;
    return if (item == .string) item.string else null;
}
pub fn requiredString(value: runner.Value, key: []const u8) ![]const u8 {
    return optionalString(value, key) orelse error.InvalidRequest;
}
fn object() runner.Value {
    return .{ .object = std.json.ObjectMap{} };
}
fn string(value: []const u8) runner.Value {
    return .{ .string = value };
}
fn put(alloc: std.mem.Allocator, value: *runner.Value, key: []const u8, item: runner.Value) !void {
    try value.object.put(alloc, key, item);
}
fn retryError(reason: []const u8) anyerror {
    const mapping = .{
        .{ "active_run", error.RetryActiveRun },                   .{ "completed_run", error.RetryCompletedRun },
        .{ "missing_attribution", error.RetryMissingAttribution }, .{ "unknown_usage", error.RetryUnknownUsage },
        .{ "unknown_effects", error.RetryUnknownEffects },         .{ "applied_effect", error.RetryAppliedEffect },
        .{ "unknown_effect_kind", error.RetryUnknownEffectKind },  .{ "unverified_isolation", error.RetryUnverifiedIsolation },
        .{ "agent_driven", error.RetryAgentDriven },
    };
    inline for (mapping) |entry| if (std.mem.eql(u8, reason, entry[0])) return entry[1];
    return error.RetryInvalidRecord;
}
pub fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.PermissionDenied => "permission_denied",
        error.WorkspaceSetupRequired => "workspace_setup_required",
        error.InvalidWorkspacePolicy => "invalid_workspace_policy",
        error.WorkspaceCommandUnavailable => "workspace_command_unavailable",
        error.WorkspaceCommandFailed => "workspace_command_failed",
        error.WorkspaceChanged => "workspace_changed",
        error.UnsupportedRuntime, error.RuntimeUnbound, error.RuntimeUnsupported => "unsupported_runtime",
        error.RuntimeUnavailable, error.DockerUnavailable => "runtime_unavailable",
        error.UnsupportedDecision => "unsupported_decision",
        error.DecisionKeyRequired => "decision_auth_required",
        error.UnsupportedDecisionProvider => "unsupported_decision_provider",
        error.InvalidDecisionPolicy => "invalid_decision_policy",
        error.DecisionHttpFailure => "decision_http_failed",
        error.InvalidDecisionResponse => "invalid_decision_response",
        error.UnsupportedInference => "unsupported_inference",
        error.UnsupportedInferenceCapability => "unsupported_capability",
        error.BrowserSetupRequired => "browser_setup_required",
        error.InvalidBrowserConfiguration => "invalid_browser_configuration",
        error.CodexLoginRequired, error.NativeProviderLoginRequired => "auth_required",
        error.UnsupportedInferenceProvider => "unsupported_provider",
        error.UnsupportedInferenceSchema => "unsupported_schema",
        error.RecoveryRequired => "recovery_required",
        error.DiskLimit => "disk_limit",
        error.RegistryLimit => "registry_limit",
        error.ResourceTrackingRequired => "resource_tracking_required",
        error.PackageChanged => "package_changed",
        error.BindingChanged => "binding_changed",
        error.RetryActiveRun => "retry_active_run",
        error.RetryCompletedRun => "retry_completed_run",
        error.RetryMissingAttribution => "retry_missing_attribution",
        error.RetryUnknownUsage => "retry_unknown_usage",
        error.RetryUnknownEffects => "retry_unknown_effects",
        error.RetryAppliedEffect => "retry_applied_effect",
        error.RetryUnknownEffectKind => "retry_unknown_effect_kind",
        error.RetryUnverifiedIsolation => "retry_unverified_isolation",
        error.RetryAgentDriven => "retry_agent_driven",
        error.RetrySelectionUnavailable => "retry_selection_unavailable",
        error.NothingToSettle => "nothing_to_settle",
        error.SettleEffectRequired => "settle_effect_required",
        error.WorkspaceReadOnlyGrant => "workspace_read_only",
        error.RetryInvalidInput => "retry_invalid_input",
        error.RetryInvalidRecord => "retry_invalid_record",
        error.InvalidInput => "invalid_input",
        error.InvalidBindings => "invalid_bindings",
        error.InvalidDependencies, error.UndeclaredRuntime => "invalid_manifest",
        error.InvalidRequest, error.InvalidDriver, error.InvalidSubmission => "invalid_request",
        error.NotAgentDriven => "not_agent_driven",
        error.UnsupportedPackage => "unsupported_package",
        error.RunPackageChanged => "package_changed",
        error.RunBusy => "owner_busy",
        else => installed.errorCode(err) orelse runner.reasonCode(err),
    };
}
const OfflineRuntimeFixture = struct {
    preflight_calls: usize = 0,
    execute_calls: usize = 0,
    provider_preflight_calls: usize = 0,
    provider_dispatch_calls: usize = 0,
    fn preflight(raw: *anyopaque, _: runner.Value, _: *package.Package, _: *bindings.Binding) !void {
        const self: *OfflineRuntimeFixture = @ptrCast(@alignCast(raw));
        self.preflight_calls += 1;
        return error.RuntimeUnavailable;
    }
    fn execute(raw: *anyopaque, _: std.mem.Allocator, _: runner.StepRequest, _: *package.Package, _: *bindings.Binding) !runner.StepResult {
        const self: *OfflineRuntimeFixture = @ptrCast(@alignCast(raw));
        self.execute_calls += 1;
        return error.UnexpectedExecution;
    }
    fn providerPreflight(raw: *anyopaque, _: runner.Value, _: *package.Package, _: *bindings.Binding, _: runner.Selection) !void {
        const self: *OfflineRuntimeFixture = @ptrCast(@alignCast(raw));
        self.provider_preflight_calls += 1;
    }
    fn providerDispatch(raw: *anyopaque, _: std.mem.Allocator, _: runner.StepRequest, _: *package.Package, _: *bindings.Binding) !runner.StepResult {
        const self: *OfflineRuntimeFixture = @ptrCast(@alignCast(raw));
        self.provider_dispatch_calls += 1;
        return error.UnexpectedDispatch;
    }
};
test "native check reports offline runtime cause and recovery with no execution or provider dispatch" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    try temporary.dir.writeFile(io, .{ .sub_path = "loop.json", .data = "{\"format\":\"loops/0.1\",\"name\":\"fixture\",\"version\":\"1\",\"inputs\":{\"schema\":{\"type\":\"object\"}},\"steps\":[{\"id\":\"saved\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"saved.py\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}},{\"id\":\"ask\",\"kind\":\"infer\",\"instructions\":\"Summarize the input.\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/saved/output\"}}" });
    try temporary.dir.writeFile(io, .{ .sub_path = "saved.py", .data = "print('saved bytes')\n" });
    var configuration = try temporary.dir.createFile(io, "installation.json", .{ .permissions = .fromMode(0o600) });
    defer configuration.close(io);
    try configuration.writeStreamingAll(io, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{\"runtime\":\"python\"},\"capabilities\":{}}},\"resources\":{\"python\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"python3\":{\"resources\":[\"runtime\"]}}}");
    var buffer: [4096]u8 = undefined;
    const path_len = try temporary.dir.realPath(io, &buffer);
    const path = buffer[0..path_len];
    var fixture: OfflineRuntimeFixture = .{};
    var engine: Engine = .{ .options = .{ .io = io, .profile = path, .code_context = &fixture, .codeFn = OfflineRuntimeFixture.execute, .codePreflightFn = OfflineRuntimeFixture.preflight, .infer_context = &fixture, .inferFn = OfflineRuntimeFixture.providerDispatch, .inferPreflightFn = OfflineRuntimeFixture.providerPreflight } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var params = object();
    try put(allocator, &params, "packagePath", string(path));
    const result = try engine.check(allocator, params);
    try std.testing.expect(!(try runner.get(result, "ok")).bool);
    const issues = try runner.get(result, "issues");
    const issue = issues.array.items[0];
    try std.testing.expectEqualStrings("runtime_unavailable", (try runner.get(issue, "code")).string);
    try std.testing.expectEqualStrings("RuntimeUnavailable", (try runner.get(issue, "cause")).string);
    try std.testing.expectEqualStrings("Configured isolated runtime is unavailable. Check that its Docker-compatible daemon is running and its pinned image is installed, then retry fh check.", (try runner.get(issue, "message")).string);
    try std.testing.expectEqual(@as(usize, 1), fixture.preflight_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_calls);
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "native-runs", .{ .follow_symlinks = false }));
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_preflight_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.provider_dispatch_calls);
}
const Fixture = struct {
    preflight_calls: usize = 0,
    execute_calls: usize = 0,
    accepted_calls: usize = 0,
    service: ?*Engine = null,
    fn accepted(raw: *anyopaque, id: []const u8, _: *package.Package, _: bool) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        const record = try self.service.?.get(std.testing.allocator, id);
        defer record.deinit();
        try std.testing.expectEqualStrings("queued", try requiredString(record.value, "status"));
        self.accepted_calls += 1;
    }
    fn preflight(raw: *anyopaque, _: runner.Value, _: *package.Package, _: *bindings.Binding) !void {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.preflight_calls += 1;
    }
    fn execute(raw: *anyopaque, allocator: std.mem.Allocator, _: runner.StepRequest, _: *package.Package, _: *bindings.Binding) !runner.StepResult {
        const self: *Fixture = @ptrCast(@alignCast(raw));
        self.execute_calls += 1;
        return .{ .output = try schema.parse(allocator, "{\"verdict\":\"fail\"}") };
    }
};
test "native engine invalid input invokes zero preflight; completed domain fail persists independently" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    try temporary.dir.writeFile(io, .{ .sub_path = "loop.json", .data = "{\"format\":\"loops/0.1\",\"name\":\"fixture\",\"version\":\"1\",\"inputs\":{\"schema\":{\"type\":\"object\",\"required\":[\"count\"]}},\"steps\":[{\"id\":\"saved\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"saved.py\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/saved/output\"}}" });
    try temporary.dir.writeFile(io, .{ .sub_path = "saved.py", .data = "print('saved bytes')\n" });
    var configuration = try temporary.dir.createFile(io, "installation.json", .{ .permissions = .fromMode(0o600) });
    defer configuration.close(io);
    try configuration.writeStreamingAll(io, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{\"runtime\":\"python\"},\"capabilities\":{}}},\"resources\":{\"python\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"python3\":{\"resources\":[\"runtime\"]}}}");
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    const path = buffer[0..length];
    var fixture: Fixture = .{};
    var engine: Engine = .{ .options = .{ .io = io, .profile = path, .code_context = &fixture, .codeFn = Fixture.execute, .codePreflightFn = Fixture.preflight } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var params = object();
    try put(allocator, &params, "packagePath", string(path));
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.InvalidInput, engine.run(allocator, params, &cancel, null));
    try std.testing.expectEqual(@as(usize, 0), fixture.preflight_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_calls);
    try put(allocator, &params, "input", try schema.parse(allocator, "{\"count\":1}"));
    fixture.service = &engine;
    var run = try engine.run(std.testing.allocator, params, &cancel, .{ .context = &fixture, .acceptedFn = Fixture.accepted });
    defer run.deinit();
    const id = try requiredString(run.record, "run_id");
    const final = try engine.get(std.testing.allocator, id);
    defer final.deinit();
    try std.testing.expectEqualStrings("completed", try requiredString(final.value, "status"));
    try std.testing.expectEqualStrings("fail", try requiredString(try runner.get(final.value, "output"), "verdict"));
    try std.testing.expectEqual(@as(i64, 0), (try runner.get(final.value, "model_request_dispatches")).integer);
    try std.testing.expectEqual(@as(usize, 1), fixture.preflight_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.execute_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.accepted_calls);
}

const DecisionFixture = struct {
    preflight_calls: usize = 0,
    execute_calls: usize = 0,
    fn preflight(raw: *anyopaque, _: runner.Value, _: *package.Package, _: *bindings.Binding) !void {
        const self: *DecisionFixture = @ptrCast(@alignCast(raw));
        self.preflight_calls += 1;
    }
    fn execute(raw: *anyopaque, allocator: std.mem.Allocator, request: runner.StepRequest, _: *package.Package, _: *bindings.Binding) !runner.StepResult {
        const self: *DecisionFixture = @ptrCast(@alignCast(raw));
        self.execute_calls += 1;
        try std.testing.expectEqualStrings("typesafe", request.selection.provider);
        try std.testing.expectEqualStrings("jev-1.13.0", request.selection.model);
        try std.testing.expectEqualStrings("none", request.selection.reasoning);
        try std.testing.expect(!request.selection.fast);
        return .{ .output = try schema.parse(allocator, "{\"model\":\"jev-1.13.0\",\"answers\":{\"ready\":{\"type\":\"noul\",\"noul\":0.9}}}"), .usage = .{ .input_tokens = 12, .output_tokens = 1 } };
    }
    fn noCodex(_: std.mem.Allocator, _: []const u8) !runner.Selection {
        return error.UnexpectedCodexSelection;
    }
};
test "native decision engine rejects invalid input before preflight and skips chat selection" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    const manifest =
        \\{"format":"loops/0.2","name":"decision-fixture","version":"1","inputs":{"schema":{"type":"object","required":["evidence"]}},"steps":[{"id":"decide","kind":"decision","input":{"from":"/input"},"questions":{"ready":{"type":"noul","instructions":"Is the supplied evidence sufficient?"}},"output":{"schema":true}}],"output":{"from":"/steps/decide/output"}}
    ;
    try temporary.dir.writeFile(io, .{ .sub_path = "loop.json", .data = manifest });
    var configuration = try temporary.dir.createFile(io, "installation.json", .{ .permissions = .fromMode(0o600) });
    defer configuration.close(io);
    try configuration.writeStreamingAll(io, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{},\"capabilities\":{}}},\"resources\":{},\"runtimeProfiles\":{}}");
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    const path = buffer[0..length];
    var fixture: DecisionFixture = .{};
    var service: Engine = .{ .options = .{ .io = io, .profile = path, .resolveSelectionFn = DecisionFixture.noCodex, .decision_context = &fixture, .decisionFn = DecisionFixture.execute, .decisionPreflightFn = DecisionFixture.preflight } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var params = object();
    try put(allocator, &params, "packagePath", string(path));
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.InvalidInput, service.run(allocator, params, &cancel, null));
    try std.testing.expectEqual(@as(usize, 0), fixture.preflight_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_calls);
    try temporary.dir.setPermissions(io, .fromMode(0o500));
    defer temporary.dir.setPermissions(io, .fromMode(0o700)) catch {};
    const checked = try service.check(allocator, params);
    try std.testing.expect((try runner.get(checked, "ok")).bool);
    try std.testing.expectEqual(@as(usize, 1), fixture.preflight_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_calls);
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "native-runs", .{ .follow_symlinks = false }));
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    try put(allocator, &params, "input", try schema.parse(allocator, "{\"evidence\":\"42 rows copied\"}"));
    var run = try service.run(std.testing.allocator, params, &cancel, null);
    defer run.deinit();
    const final = try service.get(std.testing.allocator, try requiredString(run.record, "run_id"));
    defer final.deinit();
    try std.testing.expectEqualStrings("completed", try requiredString(final.value, "status"));
    try std.testing.expect(schema.equal(run.record, final.value));
    try std.testing.expectEqual(@as(usize, 2), fixture.preflight_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.execute_calls);
    try std.testing.expectEqual(@as(i64, 13), (try runner.get(final.value, "used_tokens")).integer);
    try std.testing.expectEqualStrings("codex", service.options.selection.provider);
    try std.testing.expectEqualStrings("gpt-6-luna", service.options.selection.model);
}

test "native watcher completion before and during wait preserves cancellation polling" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cancel = std.atomic.Value(bool).init(false);
    var watcher: Watcher = .{ .io = io, .dir = tmp.dir, .cancel_flag = &cancel, .name = "run.cancel" };
    watcher.done.set(io);
    watcher.watch();
    try std.testing.expect(!cancel.load(.acquire));
    watcher.done.reset();
    const thread = try std.Thread.spawn(.{}, Watcher.watch, .{&watcher});
    for (0..1000) |_| {
        if (@atomicLoad(std.Io.Event, &watcher.done, .acquire) == .waiting) break;
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch break;
    }
    const was_waiting = @atomicLoad(std.Io.Event, &watcher.done, .acquire) == .waiting;
    watcher.done.set(io);
    thread.join();
    try std.testing.expect(was_waiting);
    try std.testing.expect(!cancel.load(.acquire));
    watcher.done.reset();
    try std.testing.expectError(error.Timeout, watcher.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(1) } }));
    const polling = try std.Thread.spawn(.{}, Watcher.watch, .{&watcher});
    try tmp.dir.writeFile(io, .{ .sub_path = watcher.name, .data = "" });
    polling.join();
    try std.testing.expect(cancel.load(.acquire));
}

test "native watcher canceled wait fails closed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cancel = std.atomic.Value(bool).init(false);
    var watcher: Watcher = .{ .io = io, .dir = tmp.dir, .cancel_flag = &cancel, .name = "absent.cancel" };
    var watching = try std.Io.concurrent(io, Watcher.watch, .{&watcher});
    for (0..1000) |_| {
        if (@atomicLoad(std.Io.Event, &watcher.done, .acquire) == .waiting) break;
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch break;
    }
    const was_waiting = @atomicLoad(std.Io.Event, &watcher.done, .acquire) == .waiting;
    watching.cancel(io);
    try std.testing.expect(was_waiting);
    try std.testing.expect(cancel.load(.acquire));
}

test "native preflight preserves custom callbacks for repeated runtime declarations" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    const path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, path);
    defer store.deinit();
    var pkg = try package.load(std.testing.allocator, io, "loops/carry-counter");
    defer pkg.deinit();
    var binding = try bindings.fromBytes(std.testing.allocator, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{\"runtime\":\"python\"},\"capabilities\":{}}},\"resources\":{\"python\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"python3\":{\"resources\":[\"runtime\"]}}}", "local");
    defer binding.deinit();
    var fixture: Fixture = .{};
    var engine: Engine = .{ .options = .{ .io = io, .profile = path, .code_context = &fixture, .codePreflightFn = Fixture.preflight } };
    var cancel = std.atomic.Value(bool).init(false);
    try engine.preflight(pkg, &binding, &cancel, std.math.maxInt(i64), &store, false);
    try std.testing.expectEqual(@as(usize, 3), fixture.preflight_calls);
}

test "native oversized file input reports bytes before selection preflight and durable creation" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var inputs = std.testing.tmpDir(.{});
    defer inputs.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "loop.json", .data = "{\"format\":\"loops/0.1\",\"name\":\"size\",\"version\":\"1\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"infer\",\"kind\":\"infer\",\"instructions\":\"Use bound input\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/infer/output\"}}" });
    var file = try inputs.dir.createFile(io, "oversize.json", .{});
    defer file.close(io);
    try file.setLength(io, Engine.input_limit + 19);
    var package_buffer: [4096]u8 = undefined;
    const package_length = try temporary.dir.realPath(io, &package_buffer);
    var input_buffer: [4096]u8 = undefined;
    const input_length = try inputs.dir.realPath(io, &input_buffer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input_path = try std.fmt.allocPrint(a, "{s}/oversize.json", .{input_buffer[0..input_length]});
    var params = object();
    try put(a, &params, "packagePath", string(package_buffer[0..package_length]));
    try put(a, &params, "inputFile", string(input_path));
    // Selection throws if reached; no binding/profile even exists.
    var fixture: DecisionFixture = .{};
    var service: Engine = .{ .options = .{ .io = io, .profile = package_buffer[0..package_length], .resolveSelectionFn = DecisionFixture.noCodex, .infer_context = &fixture, .inferPreflightFn = sizePreflight } };
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.InvalidInput, service.run(a, params, &cancel, null));
    const detail = try service.errorDetail(a, error.InvalidInput);
    try std.testing.expectEqual(@as(i64, Engine.input_limit + 19), (try runner.get(detail, "observed_bytes")).integer);
    try std.testing.expectEqual(@as(i64, Engine.input_limit), (try runner.get(detail, "limit_bytes")).integer);
    try std.testing.expectEqualStrings("invalid_input", try requiredString(detail, "code"));
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(detail, "message"), "smaller JSON input") != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.preflight_calls);
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "native-runs", .{}));
}
fn sizePreflight(raw: *anyopaque, _: runner.Value, _: *package.Package, _: *bindings.Binding, _: runner.Selection) !void {
    const fixture: *DecisionFixture = @ptrCast(@alignCast(raw));
    fixture.preflight_calls += 1;
}

test "native file growth after stat remains bounded and reports invalid input" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file = try temporary.dir.createFile(io, "growing.json", .{ .read = true });
    defer file.close(io);
    const stale = try file.stat(io);
    try file.setLength(io, Engine.input_limit + 20);
    var service: Engine = .{ .options = .{ .io = io, .profile = "/unused" } };
    try std.testing.expectError(error.InvalidInput, service.readInputBytes(std.testing.allocator, file, stale));
    try std.testing.expect(service.input_size.? >= Engine.input_limit + 1);
}

test "native admission recovers abandoned model runs without settling or replaying them" {
    var profile: AgentProfile = undefined;
    try profile.init(agent_manifest);
    defer profile.deinit();
    const a = profile.arena.allocator();
    const io = std.testing.io;
    var store = try storage.Store.init(std.testing.allocator, io, profile.buffer[0..profile.length]);
    defer store.deinit();
    // Both a request receipt and an absent receipt leave delivery/accounting uncertain.
    for ([_][]const u8{ "model_request", "decision_request", "" }, 0..) |kind, i| {
        const id = try std.fmt.allocPrint(a, "run_abandoned_{d}", .{i});
        const effects = if (kind.len == 0) "[]" else try std.fmt.allocPrint(a, "[{{\"id\":\"request\",\"kind\":\"{s}\",\"state\":\"unknown\"}}]", .{kind});
        var orphan = try schema.parse(a, try std.fmt.allocPrint(a, "{{\"format\":\"fh.native-run/0.1\",\"run_id\":\"{s}\",\"status\":\"{s}\",\"used_tokens\":7,\"usage_unknown\":true,\"model_request_dispatches\":1,\"model_request_dispatches_complete\":false,\"attempts\":[{{\"status\":\"running\"}}],\"effects\":{s}}}", .{ id, if (i == 0) @as([]const u8, "queued") else "running", effects }));
        for ([_][]const u8{ "package_path", "bindings_id", "input_source", "input_sha256", "package_digest", "binding_digest" }) |key| try put(a, &orphan, key, string("retained"));
        try put(a, &orphan, "root_input", .null);
        try store.save(orphan);
    }
    // Existing empty lock paths have no owner and must not be deleted.
    (try store.lock("foreground")).close(io);
    var admitted = try profile.start("agent");
    defer admitted.deinit();
    try std.testing.expect(storage.awaitingDriver(admitted.record));
    try std.testing.expectEqual(@as(usize, 0), profile.fixture.execute_calls);
    for (0..3) |i| {
        const id = try std.fmt.allocPrint(a, "run_abandoned_{d}", .{i});
        const recovered = try store.load(std.testing.allocator, id);
        defer recovered.deinit();
        const record = recovered.value;
        try std.testing.expectEqualStrings("stopped", try requiredString(record, "status"));
        try std.testing.expect((try runner.get(record, "recovery_required")).bool);
        try std.testing.expect(!(try runner.get(record, "model_request_dispatches_complete")).bool);
        try std.testing.expect((try runner.get(record, "usage_unknown")).bool);
        try std.testing.expectEqual(@as(i64, 1), (try runner.get(record, "model_request_dispatches")).integer);
        try std.testing.expectEqual(@as(i64, 7), (try runner.get(record, "used_tokens")).integer);
        try std.testing.expectEqualStrings("uncertain", try requiredString((try runner.get(record, "attempts")).array.items[0], "status"));
        const effects = (try runner.get(record, "effects")).array.items;
        try std.testing.expectEqual(@as(usize, if (i == 2) 0 else 1), effects.len);
        if (i != 2) {
            try std.testing.expectEqualStrings("unknown", try requiredString(effects[0], "state"));
            try std.testing.expectEqualStrings(if (i == 0) "model_request" else "decision_request", try requiredString(effects[0], "kind"));
        }
        try std.testing.expect(!diagnostics.retryGuidance(record).allowed);
        try std.testing.expectEqualStrings("unknown_usage", diagnostics.retryGuidance(record).reason);
    }
    _ = try store.dir.statFile(io, "foreground.lock", .{ .follow_symlinks = false });
    // A later independent admission preserves the legitimately waiting agent run.
    var another = try profile.start("agent");
    defer another.deinit();
    const waiting = try store.load(std.testing.allocator, try requiredString(admitted.record, "run_id"));
    defer waiting.deinit();
    try std.testing.expect(storage.awaitingDriver(waiting.value));
}

test "native admission preserves unknown local effects and never stops live owners" {
    for ([_][]const u8{ "workspace_command", "workspace_edit", "code_container", "code_staging", "browser_cleanup" }) |kind| {
        var profile: AgentProfile = undefined;
        try profile.init(agent_manifest);
        defer profile.deinit();
        const a = profile.arena.allocator();
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, profile.buffer[0..profile.length]);
        defer store.deinit();
        const record = try schema.parse(a, try std.fmt.allocPrint(a, "{{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_local\",\"status\":\"running\",\"attempts\":[{{\"status\":\"running\"}}],\"effects\":[{{\"id\":\"local-effect\",\"kind\":\"{s}\",\"state\":\"unknown\",\"details\":{{\"step\":\"op\"}}}}]}}", .{kind}));
        try store.save(record);
        const effects_before = try std.json.Stringify.valueAlloc(a, try runner.get(record, "effects"), .{});
        {
            const lease = try store.lock("run_local");
            defer lease.close(std.testing.io);
            try std.testing.expectError(error.RunBusy, profile.start("agent"));
            var service = profile.engine();
            const live = try service.get(std.testing.allocator, "run_local");
            defer live.deinit();
            try std.testing.expectEqualStrings("running", try requiredString(live.value, "status"));
            try std.testing.expect(live.value.object.get("recovery_required") == null);
        }
        try std.testing.expectError(error.RecoveryRequired, profile.start("agent"));
        const stopped = try store.load(std.testing.allocator, "run_local");
        defer stopped.deinit();
        try std.testing.expectEqualStrings("stopped", try requiredString(stopped.value, "status"));
        try std.testing.expectEqualStrings(effects_before, try std.json.Stringify.valueAlloc(a, try runner.get(stopped.value, "effects"), .{}));
        try std.testing.expectEqual(@as(usize, 0), profile.fixture.execute_calls);
        try std.testing.expectEqual(@as(usize, 0), profile.fixture.preflight_calls);
    }
}

test "native admission leaves declaration check read only and probe check can recover" {
    var profile: AgentProfile = undefined;
    try profile.init(agent_manifest);
    defer profile.deinit();
    const a = profile.arena.allocator();
    const io = std.testing.io;
    var store = try storage.Store.init(std.testing.allocator, io, profile.buffer[0..profile.length]);
    defer store.deinit();
    try store.save(try schema.parse(a, "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_model\",\"status\":\"running\",\"attempts\":[],\"effects\":[]}"));
    const before = try store.dir.readFileAlloc(io, "run_model.json", a, .limited(1048576));
    var params = object();
    try put(a, &params, "packagePath", string(try std.fs.path.join(a, &.{ profile.buffer[0..profile.length], "package" })));
    var service = profile.engine();
    try store.dir.setPermissions(io, .fromMode(0o500));
    try profile.temporary.dir.setPermissions(io, .fromMode(0o500));
    const declaration = service.check(a, params);
    try profile.temporary.dir.setPermissions(io, .fromMode(0o700));
    try store.dir.setPermissions(io, .fromMode(0o700));
    try std.testing.expectError(error.RecoveryRequired, declaration);
    try std.testing.expectEqualStrings(before, try store.dir.readFileAlloc(io, "run_model.json", a, .limited(1048576)));
    try std.testing.expectError(error.FileNotFound, store.dir.statFile(io, "foreground.lock", .{ .follow_symlinks = false }));
    try std.testing.expectError(error.FileNotFound, store.dir.statFile(io, "run_model.lock", .{ .follow_symlinks = false }));
    try std.testing.expectError(error.FileNotFound, store.dir.statFile(io, "settled.index", .{ .follow_symlinks = false }));
    const detail = try service.errorDetail(a, error.RecoveryRequired);
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(detail, "message"), "automatically records abandoned runs") != null);
    {
        const lease = try store.lock("run_model");
        defer lease.close(io);
        try std.testing.expectError(error.RunBusy, service.check(a, params));
    }
    // No configured runtime or provider is invoked. A probe check owns foreground admission,
    // recovers the predecessor, then reports the intentionally unavailable runtime.
    service.options.codeFn = null;
    service.options.codePreflightFn = null;
    const checked = try service.check(a, params);
    try std.testing.expect(!(try runner.get(checked, "ok")).bool);
    const recovered = try store.load(std.testing.allocator, "run_model");
    defer recovered.deinit();
    try std.testing.expectEqualStrings("stopped", try requiredString(recovered.value, "status"));
    try std.testing.expectEqual(@as(usize, 0), profile.fixture.execute_calls);
    // Probe admission must still refuse unresolved local effects before contacting a runtime.
    try store.save(try schema.parse(a, "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_local\",\"status\":\"running\",\"effects\":[{\"id\":\"stage\",\"kind\":\"code_staging\",\"state\":\"unknown\"}]}"));
    try std.testing.expectError(error.RecoveryRequired, service.check(a, params));
}

test "native orphan recovery leaves model dispatch count incomplete even at zero" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    var store = try storage.Store.init(std.testing.allocator, io, buffer[0..length]);
    defer store.deinit();
    const parsed = try std.json.parseFromSlice(runner.Value, std.testing.allocator, "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_crash\",\"status\":\"running\",\"model_request_dispatches\":0,\"model_request_dispatches_complete\":false,\"attempts\":[{\"status\":\"running\"}]}", .{});
    defer parsed.deinit();
    try store.save(parsed.value);
    var service: Engine = .{ .options = .{ .io = io, .profile = buffer[0..length] } };
    var result = try service.get(std.testing.allocator, "run_crash");
    defer result.deinit();
    try std.testing.expect((try runner.get(result.value, "recovery_required")).bool);
    try std.testing.expect(!(try runner.get(result.value, "model_request_dispatches_complete")).bool);
    try std.testing.expectEqual(@as(i64, 0), (try runner.get(result.value, "model_request_dispatches")).integer);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const public = try publicResult(arena.allocator(), result.value);
    try std.testing.expect(!(try runner.get(public, "model_request_dispatches_complete")).bool);
}

test "native browser cleanup preserves primary failure and cannot publish false success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine: Engine = .{ .options = .{ .io = std.testing.io, .profile = "/unused" } };
    var resource: browser.Resource = .{ .allocator = a, .io = std.testing.io, .binary = "", .authority = undefined, .evidence_dir = undefined, .process_error = error.CleanupPending };
    var context: Context = .{ .engine = &engine, .pkg = undefined, .binding = undefined, .store = undefined, .browser_resource = &resource };
    var failed_record = try schema.parse(a, "{\"status\":\"failed\",\"error\":{\"cause\":\"OriginalStepFailure\"},\"effects\":[]}");
    try Context.finalize(&context, a, &failed_record);
    try std.testing.expectEqualStrings("OriginalStepFailure", (try runner.get(try runner.get(failed_record, "error"), "cause")).string);
    try std.testing.expectEqualStrings("failed", (try runner.get(failed_record, "status")).string);
    try std.testing.expectEqualStrings("CleanupPending", (try runner.get(failed_record, "cleanup_error")).string);
    var success = try schema.parse(a, "{\"status\":\"completed\",\"output\":true,\"effects\":[]}");
    try Context.finalize(&context, a, &success);
    try std.testing.expectEqualStrings("stopped", (try runner.get(success, "status")).string);
    try std.testing.expect(!success.object.contains("output"));
    try std.testing.expectEqualStrings("unknown", (try runner.get((try runner.get(success, "effects")).array.items[0], "state")).string);
}

test "native get public projection preserves safe provider failure alongside unknown usage" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    var store = try storage.Store.init(std.testing.allocator, io, buffer[0..length]);
    defer store.deinit();
    const parsed = try std.json.parseFromSlice(runner.Value, std.testing.allocator, "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_rejected\",\"status\":\"stopped\",\"stop\":{\"reason\":\"usage_unavailable\",\"cause\":\"UsageUnavailable\"},\"usage_unknown\":true,\"model_request_dispatches\":1,\"failure_cause\":\"NativeProviderLoginRequired\"}", .{});
    defer parsed.deinit();
    try store.save(parsed.value);
    var service: Engine = .{ .options = .{ .io = io, .profile = buffer[0..length] } };
    var result = try service.get(std.testing.allocator, "run_rejected");
    defer result.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const public = try publicResult(arena.allocator(), result.value);
    try std.testing.expectEqualStrings("stopped", try requiredString(public, "status"));
    try std.testing.expectEqualStrings("usage_unavailable", try requiredString(try runner.get(public, "stop"), "reason"));
    try std.testing.expect((try runner.get(public, "usage_unknown")).bool);
    try std.testing.expectEqual(@as(i64, 1), (try runner.get(public, "model_request_dispatches")).integer);
    try std.testing.expect(public.object.get("output") == null);
    try std.testing.expectEqualStrings("NativeProviderLoginRequired", try requiredString(public, "failure_cause"));
}

const RetryFixture = struct {
    calls: usize = 0,
    accepted_calls: usize = 0,
    fail: bool = true,
    fn execute(raw: *anyopaque, allocator: std.mem.Allocator, request: runner.StepRequest, _: *package.Package, _: *bindings.Binding) !runner.StepResult {
        const self: *RetryFixture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.fail) return .{ .failure = error.CodeExit };
        return .{ .output = try schema.parse(allocator, try std.json.Stringify.valueAlloc(allocator, request.input, .{})) };
    }
    fn preflight(_: *anyopaque, _: runner.Value, _: *package.Package, _: *bindings.Binding) !void {}
    fn accepted(raw: *anyopaque, _: []const u8, _: *package.Package, _: bool) !void {
        const self: *RetryFixture = @ptrCast(@alignCast(raw));
        self.accepted_calls += 1;
    }
};
fn retryTestPackage(io: std.Io, dir: std.Io.Dir) !void {
    try dir.setPermissions(io, .fromMode(0o700));
    try dir.createDir(io, "package", .fromMode(0o700));
    try dir.writeFile(io, .{ .sub_path = "package/loop.json", .data = "{\"format\":\"loops/0.1\",\"name\":\"retry-fixture\",\"version\":\"1\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"pure\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"pure.py\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/pure/output\"}}" });
    try dir.writeFile(io, .{ .sub_path = "package/pure.py", .data = "print('pure fixture')\n" });
    var installation = try dir.createFile(io, "installation.json", .{ .permissions = .fromMode(0o600) });
    defer installation.close(io);
    try installation.writeStreamingAll(io, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{\"runtime\":\"python\"},\"capabilities\":{}}},\"resources\":{\"python\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"python3\":{\"resources\":[\"runtime\"]}}}");
}
test "native retry creates new whole run with attribution and leaves original unchanged" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try retryTestPackage(io, temporary.dir);
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try temporary.dir.realPath(io, &buffer)];
    var fixture: RetryFixture = .{};
    var service: Engine = .{ .options = .{ .io = io, .profile = path, .code_context = &fixture, .codeFn = RetryFixture.execute, .codePreflightFn = RetryFixture.preflight } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var params = object();
    try put(alloc, &params, "packagePath", string(try std.fs.path.join(alloc, &.{ path, "package" })));
    try put(alloc, &params, "input", try schema.parse(alloc, "{\"z\":2,\"a\":1}"));
    try put(alloc, &params, "inputSource", string("stdin"));
    try put(alloc, &params, "caseId", string("case-a"));
    var cancel_flag = std.atomic.Value(bool).init(false);
    const hooks: Hooks = .{ .context = &fixture, .acceptedFn = RetryFixture.accepted };
    var failed = try service.run(std.testing.allocator, params, &cancel_flag, hooks);
    defer failed.deinit();
    const id = try requiredString(failed.record, "run_id");
    try std.testing.expectEqualStrings("failed", try requiredString(failed.record, "status"));
    const projection = try publicResult(alloc, failed.record);
    try std.testing.expectEqualStrings("stdin", try requiredString(projection, "input_source"));
    try std.testing.expectEqualStrings("case-a", try requiredString(projection, "case_id"));
    try std.testing.expectEqualStrings("local", try requiredString(projection, "bindings_id"));
    const input_hash = try diagnostics.inputSha256(alloc, try schema.parse(alloc, "{\"a\":1,\"z\":2}"));
    try std.testing.expectEqualStrings(&input_hash, try requiredString(projection, "input_sha256"));
    try std.testing.expect(projection.object.get("root_input") == null);
    try std.testing.expect((try runner.get(try runner.get(projection, "diagnostic"), "retry")).object.get("allowed").?.bool);
    const before = try std.json.Stringify.valueAlloc(alloc, failed.record, .{});
    var retry_params = object();
    try put(alloc, &retry_params, "runId", string(id));
    fixture.fail = false;
    var retried = try service.retry(std.testing.allocator, retry_params, &cancel_flag, hooks);
    defer retried.deinit();
    try std.testing.expectEqualStrings("completed", try requiredString(retried.record, "status"));
    try std.testing.expect(!std.mem.eql(u8, id, try requiredString(retried.record, "run_id")));
    try std.testing.expectEqualStrings(id, try requiredString(retried.record, "retry_of"));
    try std.testing.expectEqualStrings("stdin", try requiredString(retried.record, "input_source"));
    try std.testing.expectEqualStrings("case-a", try requiredString(retried.record, "case_id"));
    try std.testing.expect(schema.equal(try runner.get(failed.record, "root_input"), try runner.get(retried.record, "output")));
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(@as(usize, 2), fixture.accepted_calls);
    const original = try service.get(std.testing.allocator, id);
    defer original.deinit();
    try std.testing.expectEqualStrings(before, try std.json.Stringify.valueAlloc(alloc, original.value, .{}));
    const persisted = try service.get(std.testing.allocator, try requiredString(retried.record, "run_id"));
    defer persisted.deinit();
    try std.testing.expect(schema.equal(try publicResult(alloc, retried.record), try publicResult(alloc, persisted.value)));
    try put(alloc, &retry_params, "runId", try runner.get(retried.record, "run_id"));
    try std.testing.expectError(error.RetryCompletedRun, service.retry(std.testing.allocator, retry_params, &cancel_flag, null));
}
test "native retry refuses changed digests uncertainty mutation and legacy evidence before dispatch" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try retryTestPackage(io, temporary.dir);
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try temporary.dir.realPath(io, &buffer)];
    var fixture: RetryFixture = .{};
    var service: Engine = .{ .options = .{ .io = io, .profile = path, .code_context = &fixture, .codeFn = RetryFixture.execute, .codePreflightFn = RetryFixture.preflight } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var params = object();
    try put(alloc, &params, "packagePath", string(try std.fs.path.join(alloc, &.{ path, "package" })));
    try put(alloc, &params, "input", try schema.parse(alloc, "{\"a\":1}"));
    var cancel_flag = std.atomic.Value(bool).init(false);
    try put(alloc, &params, "expectedPackageDigest", string("changed"));
    try std.testing.expectError(error.PackageChanged, service.run(std.testing.allocator, params, &cancel_flag, null));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    _ = params.object.swapRemove("expectedPackageDigest");
    var failed = try service.run(std.testing.allocator, params, &cancel_flag, null);
    defer failed.deinit();
    const id = try requiredString(failed.record, "run_id");
    var retry_params = object();
    try put(alloc, &retry_params, "runId", string(id));
    var store = try storage.Store.init(std.testing.allocator, io, path);
    defer store.deinit();
    const record = try store.load(std.testing.allocator, id);
    defer record.deinit();
    const a = record.arena.allocator();
    var evidence = record.value;
    const expected_input = try runner.get(evidence, "input_sha256");
    try put(a, &evidence, "input_sha256", string("changed"));
    try store.save(evidence);
    try std.testing.expectError(error.RetryInvalidInput, service.retry(std.testing.allocator, retry_params, &cancel_flag, null));
    try put(a, &evidence, "input_sha256", expected_input);
    const expected_binding = try runner.get(evidence, "binding_digest");
    try put(a, &evidence, "binding_digest", string("changed"));
    try store.save(evidence);
    try std.testing.expectError(error.BindingChanged, service.retry(std.testing.allocator, retry_params, &cancel_flag, null));
    try put(a, &evidence, "binding_digest", expected_binding);
    const expected_package = try runner.get(evidence, "package_digest");
    try put(a, &evidence, "package_digest", string("changed"));
    try store.save(evidence);
    try std.testing.expectError(error.PackageChanged, service.retry(std.testing.allocator, retry_params, &cancel_flag, null));
    try put(a, &evidence, "package_digest", expected_package);
    try put(a, &evidence, "usage_unknown", .{ .bool = true });
    try store.save(evidence);
    try std.testing.expectError(error.RetryUnknownUsage, service.retry(std.testing.allocator, retry_params, &cancel_flag, null));
    try put(a, &evidence, "usage_unknown", .{ .bool = false });
    try put(a, &evidence, "effects", try schema.parse(a, "[{\"id\":\"uncertain\",\"kind\":\"decision_request\",\"state\":\"unknown\"}]"));
    try store.save(evidence);
    try std.testing.expectError(error.RetryUnknownEffects, service.retry(std.testing.allocator, retry_params, &cancel_flag, null));
    try put(a, &evidence, "effects", try schema.parse(a, "[{\"id\":\"write\",\"kind\":\"workspace_edit\",\"state\":\"applied\"}]"));
    try store.save(evidence);
    try std.testing.expectError(error.RetryAppliedEffect, service.retry(std.testing.allocator, retry_params, &cancel_flag, null));
    try put(a, &evidence, "effects", try schema.parse(a, "[{\"id\":\"future\",\"kind\":\"future_kind\",\"state\":\"not_applied\"}]"));
    try store.save(evidence);
    try std.testing.expectError(error.RetryUnknownEffectKind, service.retry(std.testing.allocator, retry_params, &cancel_flag, null));
    try put(a, &evidence, "effects", try schema.parse(a, "[]"));
    try put(a, &evidence, "status", string("running"));
    try store.save(evidence);
    try std.testing.expectError(error.RetryActiveRun, service.retry(std.testing.allocator, retry_params, &cancel_flag, null));
    const active = try store.load(std.testing.allocator, id);
    defer active.deinit();
    try std.testing.expectEqualStrings("running", try requiredString(active.value, "status"));
    try put(a, &evidence, "status", string("failed"));
    _ = evidence.object.swapRemove("root_input");
    try store.save(evidence);
    try std.testing.expectError(error.RetryMissingAttribution, service.retry(std.testing.allocator, retry_params, &cancel_flag, null));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}
test "native attribution retains filename and inline source with persisted public equality" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try retryTestPackage(io, temporary.dir);
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try temporary.dir.realPath(io, &buffer)];
    // Keep input separate: retained package snapshots include all root files.
    var inputs = std.testing.tmpDir(.{});
    defer inputs.cleanup();
    try inputs.dir.writeFile(io, .{ .sub_path = "input.json", .data = " { \"a\":1 } " });
    var input_buffer: [4096]u8 = undefined;
    const input_dir = input_buffer[0..try inputs.dir.realPath(io, &input_buffer)];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const filename = try std.fs.path.join(alloc, &.{ input_dir, "input.json" });
    var fixture: RetryFixture = .{ .fail = false };
    var service: Engine = .{ .options = .{ .io = io, .profile = path, .code_context = &fixture, .codeFn = RetryFixture.execute, .codePreflightFn = RetryFixture.preflight } };
    var params = object();
    try put(alloc, &params, "packagePath", string(try std.fs.path.join(alloc, &.{ path, "package" })));
    try put(alloc, &params, "inputFile", string(filename));
    var cancel_flag = std.atomic.Value(bool).init(false);
    var file_run = try service.run(std.testing.allocator, params, &cancel_flag, null);
    defer file_run.deinit();
    try std.testing.expectEqualStrings(filename, try requiredString(file_run.record, "input_source"));
    const persisted = try service.get(std.testing.allocator, try requiredString(file_run.record, "run_id"));
    defer persisted.deinit();
    try std.testing.expect(schema.equal(try publicResult(alloc, file_run.record), try publicResult(alloc, persisted.value)));
    _ = params.object.swapRemove("inputFile");
    try put(alloc, &params, "input", try schema.parse(alloc, "{\"a\":1}"));
    var inline_run = try service.run(std.testing.allocator, params, &cancel_flag, null);
    defer inline_run.deinit();
    try std.testing.expectEqualStrings("inline", try requiredString(inline_run.record, "input_source"));
    try std.testing.expectEqualStrings(try requiredString(file_run.record, "input_sha256"), try requiredString(inline_run.record, "input_sha256"));
}

const CompositeFixture = struct {
    code_preflights: usize = 0,
    infer_preflights: usize = 0,
    code_paths: [2][]const u8 = .{ "", "" },
    code_calls: usize = 0,
    infer_calls: usize = 0,
    const prompt = "Judge the bound item.\nReturn JSON.\n";
    fn cast(raw: *anyopaque) *CompositeFixture {
        return @ptrCast(@alignCast(raw));
    }
    fn codePreflight(raw: *anyopaque, _: runner.Value, _: *package.Package, _: *bindings.Binding) !void {
        cast(raw).code_preflights += 1;
    }
    fn inferPreflight(raw: *anyopaque, definition: runner.Value, _: *package.Package, _: *bindings.Binding, _: runner.Selection) !void {
        try std.testing.expectEqualStrings(prompt, try requiredString(definition, "instructions"));
        cast(raw).infer_preflights += 1;
    }
    fn code(raw: *anyopaque, _: std.mem.Allocator, request: runner.StepRequest, pkg: *package.Package, _: *bindings.Binding) !runner.StepResult {
        const self = cast(raw);
        try std.testing.expectEqualStrings("saved.py", (try pkg.stepCode(request.step_id)).path);
        self.code_paths[self.code_calls] = if (std.mem.eql(u8, request.path, "fan/left/saved")) "fan/left/saved" else if (std.mem.eql(u8, request.path, "each[0]/again")) "each[0]/again" else "unexpected";
        self.code_calls += 1;
        return .{ .output = request.input };
    }
    fn infer(raw: *anyopaque, _: std.mem.Allocator, request: runner.StepRequest, _: *package.Package, _: *bindings.Binding) !runner.StepResult {
        try std.testing.expectEqualStrings(prompt, try requiredString(request.definition, "instructions"));
        try std.testing.expectEqualStrings("fan/right/ask", request.path);
        try std.testing.expectEqualStrings("ask", request.step_id);
        cast(raw).infer_calls += 1;
        return .{ .output = request.input, .usage = .{ .input_tokens = 1, .output_tokens = 1 } };
    }
    fn selection(_: std.mem.Allocator, _: []const u8) !runner.Selection {
        return .{};
    }
};
test "native engine preflights and runs loops 0.3 steps nested in parallel and map with file instructions" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    try temporary.dir.writeFile(io, .{ .sub_path = "loop.json", .data = "{\"format\":\"loops/0.3\",\"name\":\"fixture\",\"version\":\"1\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"fan\",\"kind\":\"parallel\",\"branches\":{\"left\":[{\"id\":\"saved\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"saved.py\",\"input\":{\"value\":1},\"output\":{\"schema\":true}}],\"right\":[{\"id\":\"ask\",\"kind\":\"infer\",\"instructions\":{\"file\":\"ask.md\"},\"input\":{\"value\":2},\"output\":{\"schema\":true}}]}},{\"id\":\"each\",\"kind\":\"map\",\"over\":{\"value\":[5]},\"steps\":[{\"id\":\"again\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"saved.py\",\"input\":{\"from\":\"/item\"},\"output\":{\"schema\":true}}]}],\"output\":{\"fan\":{\"from\":\"/steps/fan/output\"},\"each\":{\"from\":\"/steps/each/output\"}}}" });
    try temporary.dir.writeFile(io, .{ .sub_path = "saved.py", .data = "print('saved bytes')\n" });
    try temporary.dir.writeFile(io, .{ .sub_path = "ask.md", .data = CompositeFixture.prompt });
    var configuration = try temporary.dir.createFile(io, "installation.json", .{ .permissions = .fromMode(0o600) });
    defer configuration.close(io);
    try configuration.writeStreamingAll(io, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{\"runtime\":\"python\"},\"capabilities\":{}}},\"resources\":{\"python\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"python3\":{\"resources\":[\"runtime\"]}}}");
    var buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &buffer);
    const path = buffer[0..length];
    var fixture: CompositeFixture = .{};
    var engine: Engine = .{ .options = .{ .io = io, .profile = path, .resolveSelectionFn = CompositeFixture.selection, .code_context = &fixture, .codeFn = CompositeFixture.code, .codePreflightFn = CompositeFixture.codePreflight, .infer_context = &fixture, .inferFn = CompositeFixture.infer, .inferPreflightFn = CompositeFixture.inferPreflight } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var params = object();
    try put(allocator, &params, "packagePath", string(path));
    var cancel = std.atomic.Value(bool).init(false);
    var run = try engine.run(std.testing.allocator, params, &cancel, null);
    defer run.deinit();
    try std.testing.expectEqualStrings("completed", try requiredString(run.record, "status"));
    try std.testing.expectEqual(@as(usize, 2), fixture.code_preflights);
    try std.testing.expectEqual(@as(usize, 1), fixture.infer_preflights);
    try std.testing.expectEqual(@as(usize, 2), fixture.code_calls);
    try std.testing.expectEqual(@as(usize, 1), fixture.infer_calls);
    try std.testing.expectEqualStrings("fan/left/saved", fixture.code_paths[0]);
    try std.testing.expectEqualStrings("each[0]/again", fixture.code_paths[1]);
    const output = try runner.get(run.record, "output");
    try std.testing.expectEqual(@as(i64, 5), (try runner.get((try runner.get(output, "each")).array.items[0], "output")).integer);
    try std.testing.expectEqual(@as(i64, 2), (try runner.get(try runner.get(try runner.get(output, "fan"), "right"), "output")).integer);
}

test "native check names the node runtime an installation cannot provide, before any execution" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    try temporary.dir.writeFile(io, .{ .sub_path = "loop.json", .data = "{\"format\":\"loops/0.1\",\"name\":\"fixture\",\"version\":\"1\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"shout\",\"kind\":\"code\",\"runtime\":\"node\",\"file\":\"shout.mjs\",\"requires\":[],\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/shout/output\"}}" });
    try temporary.dir.writeFile(io, .{ .sub_path = "shout.mjs", .data = "export default input => input;\n" });
    var configuration = try temporary.dir.createFile(io, "installation.json", .{ .permissions = .fromMode(0o600) });
    defer configuration.close(io);
    try configuration.writeStreamingAll(io, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{\"runtime\":\"python\"},\"capabilities\":{}}},\"resources\":{\"python\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"python3\":{\"resources\":[\"runtime\"]}}}");
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try temporary.dir.realPath(io, &buffer)];
    var engine: Engine = .{ .options = .{ .io = io, .profile = path } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var params = object();
    try put(allocator, &params, "packagePath", string(path));
    const result = try engine.check(allocator, params);
    try std.testing.expect(!(try runner.get(result, "ok")).bool);
    const issue = (try runner.get(result, "issues")).array.items[0];
    try std.testing.expectEqualStrings("unsupported_runtime", (try runner.get(issue, "code")).string);
    try std.testing.expectEqualStrings("RuntimeUnbound", (try runner.get(issue, "cause")).string);
    try std.testing.expectEqualStrings("runtimeProfiles.node", (try runner.get(issue, "path")).string);
    try std.testing.expect(std.mem.indexOf(u8, (try runner.get(issue, "message")).string, "fh setup runtime node --socket /absolute/docker.sock --image IMAGE@sha256:DIGEST --version MAJOR.MINOR.PATCH") != null);
}

test "native code policy accepts a supported node profile and rejects any other" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try temporary.dir.realPath(io, &buffer)];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var engine: Engine = .{ .options = .{ .io = io, .profile = path } };
    const Case = struct { runtime: []const u8 = "node", profile: []const u8, expected: ?anyerror = error.UnsupportedRuntime };
    const image = "\"image\":\"node@sha256:" ++ "a" ** 64 ++ "\",\"resources\":[\"runtime\"]";
    for ([_]Case{
        .{ .profile = "{\"available\":true,\"version\":\"22.15.0\",\"profile\":\"builtin\",\"builtins\":[\"fs\"]," ++ image ++ "}", .expected = null },
        .{ .profile = "{\"available\":true,\"version\":\"22.15\",\"profile\":\"builtin\",\"builtins\":[\"fs\"]," ++ image ++ "}", .expected = null },
        .{ .profile = "{\"available\":true,\"version\":\"22.15.0\",\"profile\":\"builtin\",\"builtins\":[\"fs\"],\"node\":\"/host/node\"," ++ image ++ "}", .expected = error.RuntimeUnsupported },
        .{ .profile = "{\"available\":true,\"profile\":\"builtin\",\"builtins\":[\"fs\"]," ++ image ++ "}", .expected = error.InvalidBindings },
        .{ .profile = "{\"available\":true,\"version\":\"22.14.0\",\"profile\":\"builtin\",\"builtins\":[\"fs\"]," ++ image ++ "}" },
        .{ .profile = "{\"available\":true,\"version\":\"3.12.3\",\"profile\":\"stdlib\",\"stdlib\":[\"json\"]," ++ image ++ "}" },
        .{ .profile = "{\"available\":false,\"version\":\"22.15.0\",\"profile\":\"builtin\",\"builtins\":[\"fs\"]," ++ image ++ "}" },
        .{ .runtime = "deno", .profile = "{\"available\":true,\"version\":\"22.15.0\",\"profile\":\"builtin\",\"builtins\":[\"fs\"]," ++ image ++ "}" },
    }) |case| {
        const installation = try std.fmt.allocPrint(allocator, "{{\"version\":1,\"docker\":{{\"socketPath\":\"/private/tmp/fh-no-docker.sock\",\"stagingRoot\":\"{s}/staging\"}},\"bindings\":{{\"local\":{{\"id\":\"local\",\"policyDigest\":\"{s}\",\"resources\":{{\"runtime\":\"local-node\"}},\"capabilities\":{{}}}}}},\"resources\":{{\"local-node\":{{\"kind\":\"runtime\"}}}},\"runtimeProfiles\":{{\"{s}\":{s}}}}}", .{ path, "b" ** 64, case.runtime, case.profile });
        var binding = try bindings.fromBytes(std.testing.allocator, installation, "local");
        defer binding.deinit();
        const step = try @import("schema.zig").parse(allocator, try std.fmt.allocPrint(allocator, "{{\"id\":\"shout\",\"kind\":\"code\",\"runtime\":\"{s}\",\"file\":\"shout.mjs\"}}", .{case.runtime}));
        if (case.expected) |expected| {
            try std.testing.expectError(expected, engine.codePolicy(&binding, step));
            continue;
        }
        const policy = try engine.codePolicy(&binding, step);
        try std.testing.expectEqual(code.Runtime.node, policy.config.runtime);
        try std.testing.expectEqualStrings("/usr/local/bin/node", policy.config.node);
        try std.testing.expectEqualStrings("local-node", policy.config.runtime_handle);
    }
}

const agent_manifest =
    \\{"format":"loops/0.3","name":"driven","version":"1","inputs":{"schema":{"type":"object"}},"steps":[
    \\{"id":"draft","kind":"infer","requires":[],"instructions":{"file":"prompt.md"},"input":{"from":"/input"},"output":{"schema":{"type":"object","required":["text"],"properties":{"text":{"type":"string"}},"additionalProperties":false}}},
    \\{"id":"verify","kind":"code","runtime":"python3","file":"saved.py","input":{"from":"/steps/draft/output"},"output":{"schema":true}}],
    \\"output":{"from":"/steps/verify/output"}}
;
const AgentProfile = struct {
    temporary: std.testing.TmpDir,
    buffer: [4096]u8 = undefined,
    length: usize = 0,
    arena: std.heap.ArenaAllocator,
    fixture: Fixture = .{},
    /// A private profile with an installation, and the package beside it in `package/`, so the
    /// stored runs are never part of the package.
    fn init(self: *AgentProfile, manifest: []const u8) !void {
        return self.initWith(manifest, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{\"runtime\":\"python\"},\"capabilities\":{}}},\"resources\":{\"python\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"python3\":{\"resources\":[\"runtime\"]}}}");
    }
    fn initWith(self: *AgentProfile, manifest: []const u8, installation: []const u8) !void {
        const io = std.testing.io;
        self.* = .{ .temporary = std.testing.tmpDir(.{}), .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
        try self.temporary.dir.setPermissions(io, .fromMode(0o700));
        try self.temporary.dir.createDir(io, "package", .fromMode(0o700));
        try self.temporary.dir.writeFile(io, .{ .sub_path = "package/loop.json", .data = manifest });
        try self.temporary.dir.writeFile(io, .{ .sub_path = "package/saved.py", .data = "print('saved bytes')\n" });
        try self.temporary.dir.writeFile(io, .{ .sub_path = "package/prompt.md", .data = "Draft it.\n" });
        try self.temporary.dir.writeFile(io, .{ .sub_path = "package/shared.json", .data = "{\"type\":\"object\"}" });
        var configuration = try self.temporary.dir.createFile(io, "installation.json", .{ .permissions = .fromMode(0o600) });
        defer configuration.close(io);
        try configuration.writeStreamingAll(io, installation);
        self.length = try self.temporary.dir.realPath(io, &self.buffer);
    }
    fn deinit(self: *AgentProfile) void {
        self.arena.deinit();
        self.temporary.cleanup();
    }
    /// A new engine each time, as each CLI invocation is its own process. No model adapter is
    /// configured at all: an agent-driven run must never need one.
    fn engine(self: *AgentProfile) Engine {
        return .{ .options = .{ .io = std.testing.io, .profile = self.buffer[0..self.length], .code_context = &self.fixture, .codeFn = Fixture.execute, .codePreflightFn = Fixture.preflight } };
    }
    fn start(self: *AgentProfile, driver: []const u8) !runner.Run {
        const a = self.arena.allocator();
        var params = object();
        try put(a, &params, "packagePath", string(try std.fs.path.join(a, &.{ self.buffer[0..self.length], "package" })));
        try put(a, &params, "input", try schema.parse(a, "{\"topic\":\"t\"}"));
        try put(a, &params, "driver", string(driver));
        var cancel = std.atomic.Value(bool).init(false);
        var service = self.engine();
        return service.run(std.testing.allocator, params, &cancel, null);
    }
    fn submit(self: *AgentProfile, id: []const u8, path: []const u8, pass: i64, output: []const u8) !runner.Run {
        const a = self.arena.allocator();
        var params = object();
        try put(a, &params, "runId", string(id));
        try put(a, &params, "path", string(path));
        try put(a, &params, "pass", .{ .integer = pass });
        try put(a, &params, "output", try schema.parse(a, output));
        var cancel = std.atomic.Value(bool).init(false);
        var service = self.engine();
        return service.submit(std.testing.allocator, params, &cancel);
    }
};
test "native agent driver runs across separate engines: next, rejected, accepted, repeated and conflicting submissions" {
    var profile: AgentProfile = undefined;
    try profile.init(agent_manifest);
    defer profile.deinit();
    const a = profile.arena.allocator();
    // The runner driver needs a model adapter this installation does not have. The agent driver does not.
    try std.testing.expectError(error.UnsupportedInference, profile.start("runner"));
    try std.testing.expectError(error.InvalidDriver, profile.start("robot"));
    var started = try profile.start("agent");
    defer started.deinit();
    const id = try a.dupe(u8, try requiredString(started.record, "run_id"));
    const first = try agentResult(a, started);
    try std.testing.expectEqualStrings("running", try requiredString(first, "status"));
    try std.testing.expectEqualStrings("agent", try requiredString(first, "driver"));
    const offered = (try runner.get(first, "next")).array.items;
    try std.testing.expectEqual(@as(usize, 1), offered.len);
    try std.testing.expectEqualStrings("draft", try requiredString(offered[0], "path"));
    try std.testing.expectEqualStrings("infer", try requiredString(offered[0], "kind"));
    try std.testing.expectEqual(@as(i64, 0), (try runner.get(offered[0], "pass")).integer);
    try std.testing.expectEqualStrings("t", try requiredString(try runner.get(offered[0], "input"), "topic"));
    try std.testing.expectEqualStrings("Draft it.\n", try requiredString(offered[0], "instructions"));
    try std.testing.expectEqualStrings("object", try requiredString(try runner.get(offered[0], "output_schema"), "type"));
    try std.testing.expectEqual(@as(usize, 0), profile.fixture.execute_calls);

    // Waiting for the agent is not an orphan, and does not hold up the installation's other work.
    var reader = profile.engine();
    const waiting = try reader.get(std.testing.allocator, id);
    defer waiting.deinit();
    try std.testing.expectEqualStrings("running", try requiredString(waiting.value, "status"));
    try std.testing.expect(waiting.value.object.get("recovery_required") == null);
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, profile.buffer[0..profile.length]);
    defer store.deinit();
    try store.requireSettledResources();

    // `next` only reads: it works with read-only profile access and leaves the record as it was.
    const record_name = try std.fmt.allocPrint(a, "native-runs/{s}.json", .{id});
    const before_next = try profile.temporary.dir.readFileAlloc(std.testing.io, record_name, a, .limited(1048576));
    var runs_dir = try profile.temporary.dir.openDir(std.testing.io, "native-runs", .{});
    defer runs_dir.close(std.testing.io);
    try runs_dir.setPermissions(std.testing.io, .fromMode(0o500));
    try profile.temporary.dir.setPermissions(std.testing.io, .fromMode(0o500));
    const again_result = reader.next(std.testing.allocator, id);
    try profile.temporary.dir.setPermissions(std.testing.io, .fromMode(0o700));
    try runs_dir.setPermissions(std.testing.io, .fromMode(0o700));
    var again = try again_result;
    defer again.deinit();
    try std.testing.expectEqualStrings("draft", try requiredString((try runner.get(try agentResult(a, again), "next")).array.items[0], "path"));
    try std.testing.expectEqualStrings(before_next, try profile.temporary.dir.readFileAlloc(std.testing.io, record_name, a, .limited(1048576)));
    // The record keeps the attribution every run has, and an agent-driven run is never retried
    // into a runner-driven one that would call a model.
    try std.testing.expect(std.mem.endsWith(u8, try requiredString(first, "package_path"), "package/loop.json"));
    try std.testing.expectEqualStrings("local", try requiredString(first, "bindings_id"));
    var retry_params = object();
    try put(a, &retry_params, "runId", string(id));
    var retry_cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.RetryAgentDriven, reader.retry(std.testing.allocator, retry_params, &retry_cancel, null));

    var rejected = try profile.submit(id, "draft", 0, "{\"text\":5}");
    defer rejected.deinit();
    const refusal = try agentResult(a, rejected);
    try std.testing.expectEqualStrings("rejected", try requiredString(refusal, "answer"));
    try std.testing.expectEqual(@as(usize, 1), (try runner.get(refusal, "issues")).array.items.len);
    try std.testing.expect((try requiredString((try runner.get(refusal, "issues")).array.items[0], "message")).len != 0);
    try std.testing.expectEqual(@as(usize, 1), (try runner.get(refusal, "next")).array.items.len);
    var early = try profile.submit(id, "verify", 0, "{\"verdict\":\"pass\"}");
    defer early.deinit();
    try std.testing.expectEqual(runner.Answer.not_ready, early.answer.?);
    try std.testing.expectEqual(@as(usize, 0), profile.fixture.execute_calls);

    var accepted = try profile.submit(id, "draft", 0, "{\"text\":\"ok\"}");
    defer accepted.deinit();
    const settled = try agentResult(a, accepted);
    try std.testing.expectEqualStrings("accepted", try requiredString(settled, "answer"));
    try std.testing.expectEqualStrings("completed", try requiredString(settled, "status"));
    try std.testing.expectEqualStrings("fail", try requiredString(try runner.get(settled, "output"), "verdict"));
    try std.testing.expectEqual(@as(usize, 0), (try runner.get(settled, "next")).array.items.len);
    try std.testing.expectEqual(@as(usize, 1), profile.fixture.execute_calls);
    try std.testing.expectEqual(@as(i64, 0), (try runner.get(settled, "model_request_dispatches")).integer);

    var repeated = try profile.submit(id, "draft", 0, "{\"text\":\"ok\"}");
    defer repeated.deinit();
    try std.testing.expectEqual(runner.Answer.accepted, repeated.answer.?);
    var conflicting = try profile.submit(id, "draft", 0, "{\"text\":\"no\"}");
    defer conflicting.deinit();
    const conflict = try agentResult(a, conflicting);
    try std.testing.expectEqualStrings("conflict", try requiredString(conflict, "answer"));
    try std.testing.expectEqualStrings("ok", try requiredString(try runner.get(conflict, "committed"), "text"));
    try std.testing.expectEqual(@as(usize, 1), profile.fixture.execute_calls);
    var finished = try reader.next(std.testing.allocator, id);
    defer finished.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try runner.get(try agentResult(a, finished), "next")).array.items.len);
    const final = try reader.get(std.testing.allocator, id);
    defer final.deinit();
    try std.testing.expectEqualStrings("completed", try requiredString(final.value, "status"));
}
test "native hello example checks on an empty profile and an agent finishes it with two submits and no input" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    var buffer: [4096]u8 = undefined;
    const profile = buffer[0..try temporary.dir.realPath(io, &buffer)];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No installation, no runtime, no browser, no model adapter: what a new person has.
    const Empty = struct {
        fn engine(path: []const u8) Engine {
            return .{ .options = .{ .io = std.testing.io, .profile = path } };
        }
        fn accepts(_: *anyopaque, _: runner.Value, _: *package.Package, _: *bindings.Binding, _: runner.Selection) !void {}
        fn never(_: *anyopaque, _: std.mem.Allocator, _: runner.StepRequest, _: *package.Package, _: *bindings.Binding) anyerror!runner.StepResult {
            return error.ModelCalled;
        }
    };
    var params = object();
    try put(a, &params, "packagePath", string("./loops/hello"));
    // check asks fh's own provider adapter whether it can serve each infer step. That makes no
    // request and needs no login; this stands in for it. The agent-driven run below has none.
    var marker: u8 = 0;
    var checker = Empty.engine(profile);
    checker.options.infer_context = &marker;
    checker.options.inferFn = Empty.never;
    checker.options.inferPreflightFn = Empty.accepts;
    const checked = try checker.check(a, params);
    try std.testing.expect((try runner.get(checked, "ok")).bool);
    const pkg = try package.load(std.testing.allocator, io, "loops/hello");
    defer pkg.deinit();
    try std.testing.expectEqualStrings("loops/0.3", try requiredString(pkg.manifest, "format"));
    try std.testing.expectEqualStrings("hello", try requiredString(pkg.manifest, "name"));
    for (pkg.leaves) |step| {
        try std.testing.expectEqualStrings("infer", try requiredString(step, "kind"));
        try std.testing.expectEqual(@as(usize, 0), (try runner.get(step, "requires")).array.items.len);
    }

    // No --input at all: the CLI sends an empty object.
    try put(a, &params, "input", try schema.parse(a, "{}"));
    try put(a, &params, "driver", string("agent"));
    var cancel = std.atomic.Value(bool).init(false);
    var starter = Empty.engine(profile);
    var started = try starter.run(std.testing.allocator, params, &cancel, null);
    defer started.deinit();
    const first = try agentResult(a, started);
    const id = try a.dupe(u8, try requiredString(first, "run_id"));
    const offered = (try runner.get(first, "next")).array.items;
    try std.testing.expectEqual(@as(usize, 1), offered.len);
    try std.testing.expectEqualStrings("draft", try requiredString(offered[0], "path"));
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(offered[0], "instructions"), "If there is no `topic`") != null);

    const Submit = struct {
        fn step(allocator: std.mem.Allocator, path: []const u8, run_id: []const u8, name: []const u8, output: []const u8) !runner.Run {
            var request = object();
            try put(allocator, &request, "runId", string(run_id));
            try put(allocator, &request, "path", string(name));
            try put(allocator, &request, "pass", .{ .integer = 0 });
            try put(allocator, &request, "output", try schema.parse(allocator, output));
            var flag = std.atomic.Value(bool).init(false);
            var service = Empty.engine(path);
            return service.submit(std.testing.allocator, request, &flag);
        }
    };
    var drafted = try Submit.step(a, profile, id, "draft", "{\"sentence\":\"A loop is a saved recipe.\"}");
    defer drafted.deinit();
    const second = try agentResult(a, drafted);
    try std.testing.expectEqualStrings("accepted", try requiredString(second, "answer"));
    try std.testing.expectEqualStrings("running", try requiredString(second, "status"));
    const then = (try runner.get(second, "next")).array.items;
    try std.testing.expectEqual(@as(usize, 1), then.len);
    try std.testing.expectEqualStrings("check", try requiredString(then[0], "path"));
    // The second step reads the first step's output through its binding.
    try std.testing.expectEqualStrings("A loop is a saved recipe.", try requiredString(try runner.get(then[0], "input"), "sentence"));

    var judged = try Submit.step(a, profile, id, "check", "{\"ok\":true,\"sentence\":\"A loop is a saved recipe.\"}");
    defer judged.deinit();
    const last = try agentResult(a, judged);
    try std.testing.expectEqualStrings("accepted", try requiredString(last, "answer"));
    try std.testing.expectEqualStrings("completed", try requiredString(last, "status"));
    try std.testing.expect((try runner.get(try runner.get(last, "output"), "ok")).bool);
    try std.testing.expectEqualStrings("A loop is a saved recipe.", try requiredString(try runner.get(last, "output"), "sentence"));
    try std.testing.expectEqual(@as(i64, 0), (try runner.get(last, "model_request_dispatches")).integer);
}

test "native unsafe profile error names the folder, who can reach it and the chmod that fixes it" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buffer: [4096]u8 = undefined;
    const profile = buffer[0..try temporary.dir.realPath(io, &buffer)];
    try temporary.dir.setPermissions(io, .fromMode(0o755));
    var service: Engine = .{ .options = .{ .io = io, .profile = profile } };
    var params = object();
    try put(a, &params, "packagePath", string("./loops/hello"));
    // The check itself is unchanged: a folder others can read is still refused.
    try std.testing.expectError(error.UnsafeProfile, service.check(a, params));
    const detail = try service.errorDetail(a, error.UnsafeProfile);
    try std.testing.expectEqualStrings("execution_failed", try requiredString(detail, "code"));
    try std.testing.expectEqualStrings("UnsafeProfile", try requiredString(detail, "cause"));
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "The profile folder {s} can be read by other users on this computer (its permissions are 755 and fh needs 700), so fh will not use it until you run: chmod 700 {s}", .{ profile, profile }),
        try requiredString(detail, "message"),
    );
    try temporary.dir.setPermissions(io, .fromMode(0o770));
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(a, "The profile folder {s} can be read and changed by other members of its group (its permissions are 770 and fh needs 700), so fh will not use it until you run: chmod 700 {s}", .{ profile, profile }),
        (try storage.unsafeProfileMessage(a, profile)).?,
    );
    // A private folder is not the problem; the message never blames it.
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    try std.testing.expectEqual(null, try storage.unsafeProfileMessage(a, profile));
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(try service.errorDetail(a, error.UnsafeProfile), "message"), "chmod 700") == null);
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(try service.errorDetail(a, error.UnsafeProfile), "message"), profile) != null);
}

test "native agent driver cancel stops a waiting run; a changed package or an interrupted operation is refused" {
    var profile: AgentProfile = undefined;
    try profile.init(agent_manifest);
    defer profile.deinit();
    const a = profile.arena.allocator();
    const io = std.testing.io;
    var started = try profile.start("agent");
    defer started.deinit();
    const id = try a.dupe(u8, try requiredString(started.record, "run_id"));
    var service = profile.engine();

    try profile.temporary.dir.writeFile(io, .{ .sub_path = "package/saved.py", .data = "print('other bytes')\n" });
    try std.testing.expectError(error.RunPackageChanged, profile.submit(id, "draft", 0, "{\"text\":\"ok\"}"));
    try std.testing.expectError(error.RunPackageChanged, service.next(std.testing.allocator, id));
    try std.testing.expectEqual(@as(usize, 0), profile.fixture.execute_calls);
    // Cancelling needs neither the package nor a live process.
    const cancelled = try service.cancel(a, id);
    try std.testing.expect((try runner.get(cancelled, "cancelled")).bool);
    const stopped = try service.get(std.testing.allocator, id);
    defer stopped.deinit();
    try std.testing.expectEqualStrings("stopped", try requiredString(stopped.value, "status"));
    try std.testing.expectEqualStrings("cancelled", try requiredString(try runner.get(stopped.value, "stop"), "reason"));
    try std.testing.expect(stopped.value.object.get("recovery_required") == null);
    var after = try service.next(std.testing.allocator, id);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.next.?.array.items.len);
    var late = try profile.submit(id, "draft", 0, "{\"text\":\"ok\"}");
    defer late.deinit();
    try std.testing.expectEqual(runner.Answer.not_ready, late.answer.?);
    try std.testing.expect(!(try runner.get(try service.cancel(a, id), "cancelled")).bool);

    // A record left mid-operation (no waiting mark) is never continued. Submission admission
    // records interruption, then reports not_ready without replaying its step.
    var store = try storage.Store.init(std.testing.allocator, io, profile.buffer[0..profile.length]);
    defer store.deinit();
    var crashed = try schema.parse(a, try std.json.Stringify.valueAlloc(a, started.record, .{}));
    try put(a, &crashed, "run_id", string("run_midway"));
    _ = crashed.object.swapRemove("awaiting_driver");
    try store.save(crashed);
    try std.testing.expectError(error.RecoveryRequired, service.next(std.testing.allocator, "run_midway"));
    try std.testing.expectError(error.RecoveryRequired, store.requireSettledResources());
    var interrupted = try profile.submit("run_midway", "draft", 0, "{\"text\":\"ok\"}");
    defer interrupted.deinit();
    try std.testing.expectEqual(runner.Answer.not_ready, interrupted.answer.?);
    try std.testing.expectEqualStrings("stopped", try requiredString(interrupted.record, "status"));
    try std.testing.expect((try runner.get(interrupted.record, "recovery_required")).bool);
    try std.testing.expectEqual(@as(usize, 0), profile.fixture.execute_calls);
    // A run the runner drives has no next or submit.
    const plain = try schema.parse(a, "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_plain\",\"status\":\"completed\",\"attempts\":[],\"effects\":[]}");
    try store.save(plain);
    try std.testing.expectError(error.NotAgentDriven, service.next(std.testing.allocator, "run_plain"));
}
test "native agent driver refuses a package whose agent-facing output schema points outside itself" {
    var profile: AgentProfile = undefined;
    const manifest = try std.mem.replaceOwned(u8, std.testing.allocator, agent_manifest, "\"output\":{\"schema\":{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"text\":{\"type\":\"string\"}},\"additionalProperties\":false}}", "\"output\":{\"schema\":{\"$ref\":\"shared.json\"}}");
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(!std.mem.eql(u8, manifest, agent_manifest));
    try profile.init(manifest);
    defer profile.deinit();
    try std.testing.expectError(error.UnsupportedPackage, profile.start("agent"));
    try std.testing.expectEqual(@as(usize, 0), profile.fixture.preflight_calls);
    var service = profile.engine();
    const detail = try service.errorDetail(profile.arena.allocator(), error.UnsupportedPackage);
    try std.testing.expectEqualStrings("unsupported_package", try requiredString(detail, "code"));
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(detail, "message"), "\u{2014}") == null);
}
test "native get reloads under the run lock and never replaces a newer record with a stale orphan verdict" {
    var profile: AgentProfile = undefined;
    try profile.init(agent_manifest);
    defer profile.deinit();
    const a = profile.arena.allocator();
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, profile.buffer[0..profile.length]);
    defer store.deinit();
    var service = profile.engine();
    // What `get` read before it held the lock: a submit in flight, so no waiting mark.
    const midway = try schema.parse(a, "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_race\",\"status\":\"running\",\"driver\":\"agent\",\"attempts\":[],\"effects\":[]}");
    for ([_][]const u8{
        // The submit finished in that window: its accepted attempt is stored and the run waits again.
        "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_race\",\"status\":\"running\",\"driver\":\"agent\",\"awaiting_driver\":true,\"attempts\":[{\"path\":\"draft\",\"iteration\":0,\"status\":\"completed\",\"output\":{\"text\":\"ok\"},\"submitted\":true}],\"effects\":[]}",
        "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_race\",\"status\":\"completed\",\"driver\":\"agent\",\"output\":{\"verdict\":\"pass\"},\"attempts\":[{\"path\":\"draft\",\"iteration\":0,\"status\":\"completed\",\"output\":{\"text\":\"ok\"},\"submitted\":true}],\"effects\":[]}",
    }) |newer| {
        try store.save(midway);
        var result = try store.load(std.testing.allocator, "run_race");
        defer result.deinit();
        try store.save(try schema.parse(a, newer));
        try service.recover(std.testing.allocator, &store, "run_race", &result);
        const kept = try store.load(std.testing.allocator, "run_race");
        defer kept.deinit();
        for ([_]runner.Value{ result.value, kept.value }) |record| {
            try std.testing.expect(!std.mem.eql(u8, "stopped", try requiredString(record, "status")));
            try std.testing.expect(record.object.get("recovery_required") == null);
            try std.testing.expect(record.object.get("stop") == null);
            try std.testing.expectEqual(@as(usize, 1), (try runner.get(record, "attempts")).array.items.len);
        }
        try std.testing.expectEqualStrings(try requiredString(schema.parse(a, newer) catch unreachable, "status"), try requiredString(kept.value, "status"));
    }
    // A run nothing owns and nothing settled is still reported as an orphan.
    try store.save(midway);
    const orphan = try service.get(std.testing.allocator, "run_race");
    defer orphan.deinit();
    try std.testing.expect((try runner.get(orphan.value, "recovery_required")).bool);
}
test "native agent driver cancel under a busy run lock is honoured by the next operation and leaves no cancel file" {
    const io = std.testing.io;
    var profile: AgentProfile = undefined;
    try profile.init(agent_manifest);
    defer profile.deinit();
    const a = profile.arena.allocator();
    var store = try storage.Store.init(std.testing.allocator, io, profile.buffer[0..profile.length]);
    defer store.deinit();
    var service = profile.engine();
    for ([_]bool{ false, true }) |submitting| {
        var started = try profile.start("agent");
        defer started.deinit();
        const id = try a.dupe(u8, try requiredString(started.record, "run_id"));
        const request = try std.fmt.allocPrint(a, "{s}.cancel", .{id});
        {
            // Another process holds the run for a `next` while the cancel arrives.
            const lease = try store.lock(id);
            defer lease.close(io);
            try std.testing.expect((try runner.get(try service.cancel(a, id), "cancelled")).bool);
        }
        // The cancel was reported as done, so the run accepts nothing more.
        var after = if (submitting) try profile.submit(id, "draft", 0, "{\"text\":\"ok\"}") else try service.next(std.testing.allocator, id);
        defer after.deinit();
        if (submitting) try std.testing.expectEqual(runner.Answer.not_ready, after.answer.?);
        try std.testing.expectEqualStrings("stopped", try requiredString(after.record, "status"));
        try std.testing.expectEqualStrings("cancelled", try requiredString(try runner.get(after.record, "stop"), "reason"));
        try std.testing.expectEqual(@as(usize, 0), after.next.?.array.items.len);
        try std.testing.expectEqual(@as(usize, 0), profile.fixture.execute_calls);
        try std.testing.expectError(error.FileNotFound, store.dir.statFile(io, request, .{}));
        const stored = try service.get(std.testing.allocator, id);
        defer stored.deinit();
        try std.testing.expectEqualStrings("stopped", try requiredString(stored.value, "status"));
    }
    // A request left by a busy cancel is settled by the next cancel, which also removes it.
    var started = try profile.start("agent");
    defer started.deinit();
    const id = try a.dupe(u8, try requiredString(started.record, "run_id"));
    const request = try std.fmt.allocPrint(a, "{s}.cancel", .{id});
    {
        const lease = try store.lock(id);
        defer lease.close(io);
        _ = try service.cancel(a, id);
        _ = try store.dir.statFile(io, request, .{});
    }
    try std.testing.expect((try runner.get(try service.cancel(a, id), "cancelled")).bool);
    try std.testing.expectError(error.FileNotFound, store.dir.statFile(io, request, .{}));
    const stopped = try service.get(std.testing.allocator, id);
    defer stopped.deinit();
    try std.testing.expectEqualStrings("cancelled", try requiredString(try runner.get(stopped.value, "stop"), "reason"));
}
const small_output_installation = "{\"version\":1,\"limits\":{\"maxOutputBytes\":64},\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{\"runtime\":\"python\"},\"capabilities\":{}}},\"resources\":{\"python\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"python3\":{\"resources\":[\"runtime\"]}}}";
test "native agent driver rejects an oversized or unreadable submission and leaves the step open" {
    const io = std.testing.io;
    var profile: AgentProfile = undefined;
    try profile.initWith(agent_manifest, small_output_installation);
    defer profile.deinit();
    const a = profile.arena.allocator();
    var started = try profile.start("agent");
    defer started.deinit();
    const id = try a.dupe(u8, try requiredString(started.record, "run_id"));
    const long = try std.fmt.allocPrint(a, "{{\"text\":\"{s}\"}}", .{"x" ** 100});
    var oversized = try profile.submit(id, "draft", 0, long);
    defer oversized.deinit();
    const refusal = try agentResult(a, oversized);
    try std.testing.expectEqualStrings("rejected", try requiredString(refusal, "answer"));
    try std.testing.expectEqualStrings("running", try requiredString(refusal, "status"));
    try std.testing.expect((try runner.get(refusal, "awaiting_driver")).bool);
    try std.testing.expectEqual(@as(i64, 0), (try runner.get(refusal, "used_operations")).integer);
    try std.testing.expectEqualStrings("draft", try requiredString((try runner.get(refusal, "next")).array.items[0], "path"));
    const issue = try requiredString((try runner.get(refusal, "issues")).array.items[0], "message");
    try std.testing.expect(std.mem.indexOf(u8, issue, try std.fmt.allocPrint(a, "{d} bytes", .{long.len})) != null);
    try std.testing.expect(std.mem.indexOf(u8, issue, "64 bytes") != null);

    // An output file that is not JSON, or is larger than any output may be, is about the value too.
    try profile.temporary.dir.writeFile(io, .{ .sub_path = "broken.json", .data = "{\"text\":" });
    const huge = try a.alloc(u8, Engine.input_limit + 1);
    @memset(huge, ' ');
    try profile.temporary.dir.writeFile(io, .{ .sub_path = "huge.json", .data = huge });
    for ([_][]const u8{ "broken.json", "huge.json" }) |name| {
        var params = object();
        try put(a, &params, "runId", string(id));
        try put(a, &params, "path", string("draft"));
        try put(a, &params, "pass", .{ .integer = 0 });
        try put(a, &params, "outputFile", string(try std.fs.path.join(a, &.{ profile.buffer[0..profile.length], name })));
        var cancel = std.atomic.Value(bool).init(false);
        var service = profile.engine();
        var unreadable = try service.submit(std.testing.allocator, params, &cancel);
        defer unreadable.deinit();
        const answer = try agentResult(a, unreadable);
        try std.testing.expectEqualStrings("rejected", try requiredString(answer, "answer"));
        try std.testing.expectEqualStrings("running", try requiredString(answer, "status"));
        try std.testing.expect((try requiredString((try runner.get(answer, "issues")).array.items[0], "message")).len != 0);
        try std.testing.expectEqual(@as(usize, 1), (try runner.get(answer, "next")).array.items.len);
    }
    try std.testing.expectEqual(@as(usize, 0), profile.fixture.execute_calls);
    var accepted = try profile.submit(id, "draft", 0, "{\"text\":\"ok\"}");
    defer accepted.deinit();
    try std.testing.expectEqual(runner.Answer.accepted, accepted.answer.?);
    try std.testing.expectEqualStrings("completed", try requiredString(accepted.record, "status"));
}
test "native admission answers busy, not recovery, while another operation holds a waiting agent run" {
    const io = std.testing.io;
    var profile: AgentProfile = undefined;
    try profile.init(agent_manifest);
    defer profile.deinit();
    const a = profile.arena.allocator();
    var store = try storage.Store.init(std.testing.allocator, io, profile.buffer[0..profile.length]);
    defer store.deinit();
    var other = try profile.start("agent");
    defer other.deinit();
    var held = try profile.start("agent");
    defer held.deinit();
    const other_id = try a.dupe(u8, try requiredString(other.record, "run_id"));
    {
        // A `next` in another process is reading the newest run, which no admission has
        // looked at since it was stored.
        const lease = try store.lock(try requiredString(held.record, "run_id"));
        defer lease.close(io);
        try std.testing.expectError(error.RunBusy, profile.start("agent"));
        try std.testing.expectError(error.RunBusy, profile.submit(other_id, "draft", 0, "{\"text\":\"ok\"}"));
        try std.testing.expectEqual(@as(usize, 0), profile.fixture.execute_calls);
    }
    var service = profile.engine();
    const detail = try service.errorDetail(a, error.RunBusy);
    try std.testing.expectEqualStrings("owner_busy", try requiredString(detail, "code"));
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(detail, "message"), "in progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(detail, "message"), "requested operation was not started") != null);
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(detail, "message"), "orphan bookkeeping may have occurred") != null);
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(detail, "message"), "Nothing was changed") == null);
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(detail, "message"), "\u{2014}") == null);
    var accepted = try profile.submit(other_id, "draft", 0, "{\"text\":\"ok\"}");
    defer accepted.deinit();
    try std.testing.expectEqual(runner.Answer.accepted, accepted.answer.?);
    // A held lease is still live even when its record was saved mid-operation.
    try store.save(try schema.parse(a, "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_midway\",\"status\":\"running\",\"driver\":\"agent\",\"attempts\":[],\"effects\":[]}"));
    const lease = try store.lock("run_midway");
    defer lease.close(io);
    try std.testing.expectError(error.RunBusy, profile.start("agent"));
}
const capable_manifest =
    \\{"format":"loops/0.3","name":"capable","version":"1","inputs":{"schema":{"type":"object"}},"steps":[
    \\{"id":"draft","kind":"infer","requires":["browser"],"instructions":"Look.","input":{"from":"/input"},"output":{"schema":{"type":"object"}}},
    \\{"id":"read","kind":"infer","requires":["workspace_read"],"instructions":"Read.","input":{"from":"/input"},"output":{"schema":{"type":"object"}}},
    \\{"id":"verify","kind":"code","runtime":"python3","file":"saved.py","input":{"from":"/steps/draft/output"},"output":{"schema":true}}],
    \\"output":{"from":"/steps/verify/output"}}
;
test "native agent driver leaves infer capabilities to the agent and still checks every code step locally" {
    var profile: AgentProfile = undefined;
    try profile.init(capable_manifest);
    defer profile.deinit();
    const a = profile.arena.allocator();
    // This binding grants neither a browser nor a workspace, so fh's own model could not run it.
    try std.testing.expectError(error.PermissionDenied, profile.start("runner"));
    var started = try profile.start("agent");
    defer started.deinit();
    const offered = (try runner.get(try agentResult(a, started), "next")).array.items;
    try std.testing.expectEqualStrings("browser", (try runner.get(offered[0], "requires")).array.items[0].string);
    try std.testing.expectEqual(@as(usize, 1), profile.fixture.preflight_calls);
    var accepted = try profile.submit(try requiredString(started.record, "run_id"), "draft", 0, "{}");
    defer accepted.deinit();
    try std.testing.expectEqual(runner.Answer.accepted, accepted.answer.?);
    try std.testing.expectEqualStrings("workspace_read", (try runner.get(accepted.next.?.array.items[0], "requires")).array.items[0].string);

    // A code step's runtime is this installation's to provide, whoever drives the run.
    var bare: AgentProfile = undefined;
    try bare.initWith(capable_manifest, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{},\"capabilities\":{}}},\"resources\":{},\"runtimeProfiles\":{}}");
    defer bare.deinit();
    try std.testing.expectError(error.RuntimeUnbound, bare.start("agent"));
    try std.testing.expectEqual(@as(usize, 0), bare.fixture.preflight_calls);
}

/// A private profile whose `workspace` binding grants a real directory, and one package.
const WorkspaceProfile = struct {
    arena: std.heap.ArenaAllocator,
    temporary: std.testing.TmpDir,
    root: []const u8 = "",
    fn init(self: *WorkspaceProfile, manifest: []const u8, operation: []const u8, commands: []const u8) !void {
        const io = std.testing.io;
        self.* = .{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .temporary = std.testing.tmpDir(.{}) };
        errdefer self.deinit();
        const a = self.arena.allocator();
        self.root = try self.temporary.dir.realPathFileAlloc(io, ".", a);
        for ([_][]const u8{ "profile", "workspace", "package" }) |name| try self.temporary.dir.createDir(io, name, .fromMode(0o700));
        try self.temporary.dir.writeFile(io, .{ .sub_path = "workspace/source.txt", .data = "before\n" });
        try self.temporary.dir.writeFile(io, .{ .sub_path = "package/loop.json", .data = manifest });
        try self.temporary.dir.writeFile(io, .{ .sub_path = "package/op.json", .data = operation });
        var directory = try storage.openDirectory(io, try self.path("workspace"));
        defer directory.close(io);
        const stat = try metadata.fstat(directory.handle);
        var installation = try self.temporary.dir.createFile(io, "profile/installation.json", .{ .permissions = .fromMode(0o600) });
        defer installation.close(io);
        try installation.writeStreamingAll(io, try std.fmt.allocPrint(a, "{{\"version\":1,\"bindings\":{{\"local\":{{\"id\":\"local\",\"resources\":{{}},\"capabilities\":{{}}}},\"workspace\":{{\"id\":\"workspace\",\"capabilities\":{{}},\"resources\":{{\"workspace\":\"grant\"}}}}}},\"resources\":{{\"grant\":{{\"kind\":\"workspace-runtime\",\"trust\":\"trusted-host-commands\",\"workspace\":\"{s}\",\"dev\":{d},\"ino\":{d},\"commands\":{s},\"files\":[\"source.txt\"]}}}},\"runtimeProfiles\":{{\"fh-workspace/1\":{{\"resources\":[\"workspace\"]}}}}}}", .{ try self.path("workspace"), stat.dev, stat.ino, commands }));
    }
    fn deinit(self: *WorkspaceProfile) void {
        self.temporary.cleanup();
        self.arena.deinit();
    }
    fn path(self: *WorkspaceProfile, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.root, name });
    }
    fn engine(self: *WorkspaceProfile) !Engine {
        return .{ .options = .{ .io = std.testing.io, .profile = try self.path("profile") } };
    }
    fn params(self: *WorkspaceProfile) !runner.Value {
        const a = self.arena.allocator();
        var value = object();
        try put(a, &value, "packagePath", string(try self.path("package")));
        try put(a, &value, "bindingsId", string("workspace"));
        return value;
    }
    /// A stopped run whose command at step `publish` was never recorded as run or not run.
    fn strand(self: *WorkspaceProfile) !void {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, try self.path("profile"));
        defer store.deinit();
        try store.save(try schema.parse(self.arena.allocator(), "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_stuck\",\"status\":\"stopped\",\"stop\":{\"reason\":\"uncertain_effect\"},\"failure_step_id\":\"publish\",\"attempts\":[{\"step_id\":\"publish\",\"path\":\"publish\",\"iteration\":0,\"status\":\"running\"}],\"effects\":[{\"id\":\"workspace-command:publish:0\",\"kind\":\"workspace_command\",\"state\":\"unknown\"}]}"));
        try store.save(try schema.parse(self.arena.allocator(), "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_done\",\"status\":\"completed\",\"attempts\":[],\"effects\":[{\"id\":\"workspace-command:publish:0\",\"kind\":\"workspace_command\",\"state\":\"applied\"}]}"));
    }
    fn entries(self: *WorkspaceProfile) !usize {
        var directory = try storage.openDirectory(std.testing.io, try self.path("profile/native-runs"));
        defer directory.close(std.testing.io);
        var iterator = directory.iterate();
        var count: usize = 0;
        while (try iterator.next(std.testing.io)) |_| count += 1;
        return count;
    }
    fn lockDown(self: *WorkspaceProfile, read_only: bool) !void {
        for ([_][]const u8{ "profile/native-runs", "profile" }) |name| {
            var directory = try self.temporary.dir.openDir(std.testing.io, name, .{});
            defer directory.close(std.testing.io);
            try directory.setPermissions(std.testing.io, if (read_only) .fromMode(0o500) else .fromMode(0o700));
        }
    }
};
const workspace_check_manifest = "{\"format\":\"loops/0.1\",\"name\":\"checkout\",\"version\":\"1\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"op\",\"kind\":\"code\",\"runtime\":\"fh-workspace/1\",\"file\":\"op.json\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/op/output\"}}";
const workspace_check_operation = "{\"operation\":\"check\",\"command\":\"go\"}";

test "native workspace step inside a map over two elements records one effect per element" {
    var profile: WorkspaceProfile = undefined;
    try profile.init("{\"format\":\"loops/0.3\",\"name\":\"each\",\"version\":\"1\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"each\",\"kind\":\"map\",\"over\":{\"value\":[1,2]},\"steps\":[{\"id\":\"op\",\"kind\":\"code\",\"runtime\":\"fh-workspace/1\",\"file\":\"op.json\",\"input\":{\"from\":\"/item\"},\"output\":{\"schema\":true}}]}],\"output\":{\"from\":\"/steps/each/output\"}}", workspace_check_operation, "{\"go\":[\"/usr/bin/true\"]}");
    defer profile.deinit();
    var service = try profile.engine();
    var cancel = std.atomic.Value(bool).init(false);
    var run = try service.run(std.testing.allocator, try profile.params(), &cancel, null);
    defer run.deinit();
    try std.testing.expectEqualStrings("completed", try requiredString(run.record, "status"));
    const elements = (try runner.get(run.record, "output")).array.items;
    try std.testing.expectEqual(@as(usize, 2), elements.len);
    for (elements) |element| try std.testing.expect((try runner.get(try runner.get(element, "output"), "passed")).bool);
    const effects = (try runner.get(run.record, "effects")).array.items;
    try std.testing.expectEqual(@as(usize, 2), effects.len);
    try std.testing.expectEqualStrings("workspace-command:each[0]/op:0", try requiredString(effects[0], "id"));
    try std.testing.expectEqualStrings("workspace-command:each[1]/op:0", try requiredString(effects[1], "id"));
    for (effects) |effect| try std.testing.expectEqualStrings("applied", try requiredString(effect, "state"));
}

test "native check reports the unsettled effect run would refuse, on a read-only profile too" {
    var profile: WorkspaceProfile = undefined;
    try profile.init(workspace_check_manifest, workspace_check_operation, "{\"go\":[\"/usr/bin/true\"]}");
    defer profile.deinit();
    const a = profile.arena.allocator();
    var service = try profile.engine();
    var cancel = std.atomic.Value(bool).init(false);
    const params = try profile.params();
    // Nothing is stored yet, so a workspace-only check passes and makes no run directory.
    try std.testing.expect((try runner.get(try service.check(a, params), "ok")).bool);
    try std.testing.expectError(error.FileNotFound, profile.temporary.dir.statFile(std.testing.io, "profile/native-runs", .{ .follow_symlinks = false }));
    try profile.strand();
    try std.testing.expectError(error.RecoveryRequired, service.run(std.testing.allocator, params, &cancel, null));
    try std.testing.expectError(error.RecoveryRequired, service.check(a, params));
    // The message names the run and the step, what to look at, and the command that settles it.
    const detail = try service.errorDetail(a, error.RecoveryRequired);
    const message = try requiredString(detail, "message");
    try std.testing.expectEqualStrings("recovery_required", try requiredString(detail, "code"));
    for ([_][]const u8{ "run_stuck", "publish", "fh settle run_stuck --applied", "--not-applied" }) |needle| try std.testing.expect(std.mem.indexOf(u8, message, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "\u{2014}") == null);
    const before = try profile.entries();
    try profile.lockDown(true);
    defer profile.lockDown(false) catch {};
    try std.testing.expectError(error.RecoveryRequired, service.check(a, params));
    try std.testing.expectEqual(before, try profile.entries());
}

test "native settle records an uncertain effect's outcome and refuses a run that has none" {
    var profile: WorkspaceProfile = undefined;
    try profile.init(workspace_check_manifest, workspace_check_operation, "{\"go\":[\"/usr/bin/true\"]}");
    defer profile.deinit();
    const a = profile.arena.allocator();
    try profile.strand();
    var service = try profile.engine();
    var cancel = std.atomic.Value(bool).init(false);
    var request = object();
    try put(a, &request, "runId", string("run_done"));
    try put(a, &request, "outcome", string("applied"));
    try std.testing.expectError(error.NothingToSettle, service.settle(a, request));
    try put(a, &request, "runId", string("run_stuck"));
    try put(a, &request, "outcome", string("maybe"));
    try std.testing.expectError(error.InvalidRequest, service.settle(a, request));
    try put(a, &request, "effect", string("workspace-command:other:0"));
    try put(a, &request, "outcome", string("applied"));
    try std.testing.expectError(error.NothingToSettle, service.settle(a, request));
    _ = request.object.swapRemove("effect");
    try std.testing.expectError(error.RecoveryRequired, service.check(a, try profile.params()));
    const settled = try service.settle(a, request);
    try std.testing.expect(!(try runner.get(settled, "uncertain_effects")).bool);
    try std.testing.expectEqualStrings("applied", try requiredString((try runner.get(settled, "effects")).array.items[0], "state"));
    const stored = try service.get(std.testing.allocator, "run_stuck");
    defer stored.deinit();
    const receipt = (try runner.get(stored.value, "effects")).array.items[0];
    try std.testing.expectEqualStrings("applied", try requiredString(receipt, "state"));
    try std.testing.expectEqualStrings("operator", try requiredString(receipt, "settled_by"));
    // Settling twice is refused: nothing is uncertain any more.
    try std.testing.expectError(error.NothingToSettle, service.settle(a, request));
    // The installation admits work again, and a read-only profile still checks clean.
    var run = try service.run(std.testing.allocator, try profile.params(), &cancel, null);
    defer run.deinit();
    try std.testing.expectEqualStrings("completed", try requiredString(run.record, "status"));
    // A run that was reserved and never written holds the installation too. Nothing in it
    // ran, so the only outcome it accepts is that nothing was applied.
    var marker = try profile.temporary.dir.createFile(std.testing.io, "profile/native-runs/run_ghost.pending", .{ .permissions = .fromMode(0o600) });
    try marker.writeStreamingAll(std.testing.io, "fh.pending/1\n");
    marker.close(std.testing.io);
    try std.testing.expectError(error.RecoveryRequired, service.check(a, try profile.params()));
    const ghost = try requiredString(try service.errorDetail(a, error.RecoveryRequired), "message");
    try std.testing.expect(std.mem.indexOf(u8, ghost, "fh settle run_ghost --not-applied") != null);
    try put(a, &request, "runId", string("run_ghost"));
    try std.testing.expectError(error.NothingToSettle, service.settle(a, request));
    try put(a, &request, "outcome", string("not_applied"));
    _ = try service.settle(a, request);
    try put(a, &request, "runId", string("run_never"));
    try std.testing.expectError(error.FileNotFound, service.settle(a, request));
    try std.testing.expectError(error.FileNotFound, profile.temporary.dir.statFile(std.testing.io, "profile/native-runs/run_never.lock", .{ .follow_symlinks = false }));
    try profile.lockDown(true);
    defer profile.lockDown(false) catch {};
    try std.testing.expect((try runner.get(try service.check(a, try profile.params()), "ok")).bool);
}

var pinned_selection: runner.Selection = .{};
const SelectionFixture = struct {
    fail: bool = true,
    gone: bool = false,
    calls: usize = 0,
    provider: []const u8 = "",
    model: []const u8 = "",
    fn resolve(_: std.mem.Allocator, _: []const u8) !runner.Selection {
        return pinned_selection;
    }
    fn preflight(raw: *anyopaque, _: runner.Value, _: *package.Package, _: *bindings.Binding, selection: runner.Selection) !void {
        const self: *SelectionFixture = @ptrCast(@alignCast(raw));
        if (self.gone and std.mem.eql(u8, selection.provider, "first")) return error.UnknownConfiguredProvider;
    }
    fn infer(raw: *anyopaque, allocator: std.mem.Allocator, request: runner.StepRequest, _: *package.Package, _: *bindings.Binding) !runner.StepResult {
        const self: *SelectionFixture = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.provider = if (std.mem.eql(u8, request.selection.provider, "first")) "first" else "second";
        self.model = if (std.mem.eql(u8, request.selection.model, "model-a")) "model-a" else "model-b";
        if (self.fail) return .{ .failure = error.NativeProviderServerError, .usage = .{ .input_tokens = 0, .output_tokens = 0 } };
        return .{ .output = try schema.parse(allocator, "{\"ok\":true}"), .usage = .{ .input_tokens = 1, .output_tokens = 1 } };
    }
};
test "native retry runs on the recorded selection and refuses when it is no longer available" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    try temporary.dir.createDir(io, "package", .fromMode(0o700));
    try temporary.dir.writeFile(io, .{ .sub_path = "package/loop.json", .data = "{\"format\":\"loops/0.1\",\"name\":\"selected\",\"version\":\"1\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"ask\",\"kind\":\"infer\",\"instructions\":\"Answer.\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/ask/output\"}}" });
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try temporary.dir.realPath(io, &buffer)];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fixture: SelectionFixture = .{};
    var service: Engine = .{ .options = .{ .io = io, .profile = path, .resolveSelectionFn = SelectionFixture.resolve, .infer_context = &fixture, .inferFn = SelectionFixture.infer, .inferPreflightFn = SelectionFixture.preflight } };
    var params = object();
    try put(alloc, &params, "packagePath", string(try std.fs.path.join(alloc, &.{ path, "package" })));
    var cancel_flag = std.atomic.Value(bool).init(false);
    pinned_selection = .{ .provider = "first", .model = "model-a", .reasoning = "low", .fast = false };
    var failed = try service.run(std.testing.allocator, params, &cancel_flag, null);
    defer failed.deinit();
    try std.testing.expectEqualStrings("failed", try requiredString(failed.record, "status"));
    try std.testing.expectEqualStrings("model-a", fixture.model);
    // The installation's default moves on. A retry is the same run again, so it does not.
    pinned_selection = .{ .provider = "second", .model = "model-b", .reasoning = "high", .fast = true };
    fixture.fail = false;
    var retry_params = object();
    try put(alloc, &retry_params, "runId", try runner.get(failed.record, "run_id"));
    var retried = try service.retry(std.testing.allocator, retry_params, &cancel_flag, null);
    defer retried.deinit();
    try std.testing.expectEqualStrings("completed", try requiredString(retried.record, "status"));
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqualStrings("first", fixture.provider);
    try std.testing.expectEqualStrings("model-a", fixture.model);
    const recorded = try runner.get(retried.record, "selection");
    try std.testing.expectEqualStrings("first", try requiredString(recorded, "provider"));
    try std.testing.expectEqualStrings("model-a", try requiredString(recorded, "model"));
    try std.testing.expectEqualStrings("low", try requiredString(recorded, "reasoning"));
    try std.testing.expect(!(try runner.get(recorded, "requestedFast")).bool);
    // A new run still takes the current default.
    var fresh = try service.run(std.testing.allocator, params, &cancel_flag, null);
    defer fresh.deinit();
    try std.testing.expectEqualStrings("model-b", fixture.model);
    // The recorded provider was removed: the retry is refused before any request.
    fixture.gone = true;
    try std.testing.expectError(error.RetrySelectionUnavailable, service.retry(std.testing.allocator, retry_params, &cancel_flag, null));
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    const detail = try service.errorDetail(alloc, error.RetrySelectionUnavailable);
    try std.testing.expectEqualStrings("retry_selection_unavailable", try requiredString(detail, "code"));
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(detail, "message"), "no longer available") != null);
}

test "native run refuses a binding digest other than the one a batch pinned" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try retryTestPackage(io, temporary.dir);
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try temporary.dir.realPath(io, &buffer)];
    var fixture: RetryFixture = .{ .fail = false };
    var service: Engine = .{ .options = .{ .io = io, .profile = path, .code_context = &fixture, .codeFn = RetryFixture.execute, .codePreflightFn = RetryFixture.preflight } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var params = object();
    try put(alloc, &params, "packagePath", string(try std.fs.path.join(alloc, &.{ path, "package" })));
    var cancel_flag = std.atomic.Value(bool).init(false);
    var first = try service.run(std.testing.allocator, params, &cancel_flag, null);
    defer first.deinit();
    try put(alloc, &params, "expectedBindingDigest", try runner.get(first.record, "binding_digest"));
    var second = try service.run(std.testing.allocator, params, &cancel_flag, null);
    defer second.deinit();
    try put(alloc, &params, "expectedBindingDigest", string("changed"));
    try std.testing.expectError(error.BindingChanged, service.run(std.testing.allocator, params, &cancel_flag, null));
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "native engine installs a package from a folder, checks and runs it by name, and refuses it once its files change" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    try temporary.dir.createDir(io, "source", .fromMode(0o700));
    try temporary.dir.writeFile(io, .{ .sub_path = "source/loop.json", .data = "{\"format\":\"loops/0.1\",\"name\":\"fixture\",\"version\":\"1\",\"inputs\":{\"schema\":{\"type\":\"object\",\"required\":[\"count\"]}},\"steps\":[{\"id\":\"saved\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"saved.py\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/saved/output\"}}" });
    try temporary.dir.writeFile(io, .{ .sub_path = "source/saved.py", .data = "print('saved bytes')\n" });
    var configuration = try temporary.dir.createFile(io, "installation.json", .{ .permissions = .fromMode(0o600) });
    defer configuration.close(io);
    try configuration.writeStreamingAll(io, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{\"runtime\":\"python\"},\"capabilities\":{}}},\"resources\":{\"python\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"python3\":{\"resources\":[\"runtime\"]}}}");
    var buffer: [4096]u8 = undefined;
    const profile = buffer[0..try temporary.dir.realPath(io, &buffer)];
    var fixture: Fixture = .{};
    var engine: Engine = .{ .options = .{ .io = io, .profile = profile, .code_context = &fixture, .codeFn = Fixture.execute, .codePreflightFn = Fixture.preflight } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Adding validates and copies. It runs no code and asks no runtime anything.
    var adding = object();
    try put(allocator, &adding, "source", string(try std.fs.path.join(allocator, &.{ profile, "source" })));
    const inspected = try engine.packages(allocator, "add", adding);
    try std.testing.expectEqualStrings("confirmation_required", try requiredString(inspected, "status"));
    try put(allocator, &adding, "yes", .{ .bool = true });
    const added = try engine.packages(allocator, "add", adding);
    try std.testing.expectEqualStrings("installed", try requiredString(added, "status"));
    try std.testing.expectEqual(@as(usize, 0), fixture.preflight_calls);
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_calls);
    const digest = try requiredString(added, "digest");
    const listed = try engine.packages(allocator, "list", object());
    try std.testing.expectEqualStrings("fixture", try requiredString((try runner.get(listed, "packages")).array.items[0], "name"));

    // The source folder can go: the installed copy is what runs.
    try temporary.dir.deleteTree(io, "source");
    var params = object();
    try put(allocator, &params, "packagePath", string("fixture"));
    const checked = try engine.check(allocator, params);
    try std.testing.expect((try runner.get(checked, "ok")).bool);
    try std.testing.expectEqualStrings(digest, try requiredString(checked, "package_digest"));
    try put(allocator, &params, "packagePath", string("fixture@1"));
    try put(allocator, &params, "input", try schema.parse(allocator, "{\"count\":1}"));
    var cancel = std.atomic.Value(bool).init(false);
    var run = try engine.run(allocator, params, &cancel, null);
    defer run.deinit();
    try std.testing.expectEqualStrings("completed", try requiredString(run.record, "status"));
    try std.testing.expectEqualStrings(digest, try requiredString(run.record, "package_digest"));
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ profile, "packages/fixture/1/loop.json" }), try requiredString(run.record, "package_path"));
    try std.testing.expectEqual(@as(usize, 1), fixture.execute_calls);

    // One changed byte: by name, by version and by path the package no longer loads.
    try temporary.dir.setFilePermissions(io, "packages/fixture/1/saved.py", .fromMode(0o600), .{});
    try temporary.dir.writeFile(io, .{ .sub_path = "packages/fixture/1/saved.py", .data = "print('other bytes')\n" });
    try std.testing.expectError(error.InstalledPackageChanged, engine.run(allocator, params, &cancel, null));
    const detail = try engine.errorDetail(allocator, error.InstalledPackageChanged);
    try std.testing.expectEqualStrings("installed_package_changed", try requiredString(detail, "code"));
    const message = try requiredString(detail, "message");
    try std.testing.expect(std.mem.indexOf(u8, message, "fixture@1") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, digest) != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "The files on disk now have digest ") != null);
    try put(allocator, &params, "packagePath", string("fixture"));
    try std.testing.expectError(error.InstalledPackageChanged, engine.check(allocator, params));
    try put(allocator, &params, "packagePath", string(try std.fs.path.join(allocator, &.{ profile, "packages/fixture/1" })));
    try std.testing.expectError(error.InstalledPackageChanged, engine.check(allocator, params));
    try put(allocator, &params, "packagePath", string("fixture"));
    try std.testing.expectEqual(@as(usize, 1), fixture.execute_calls);

    var removing = object();
    try put(allocator, &removing, "package", string("fixture"));
    try std.testing.expectEqualStrings("removed", try requiredString(try engine.packages(allocator, "remove", removing), "status"));
    try std.testing.expectError(error.PackageNotInstalled, engine.check(allocator, params));
    try std.testing.expectEqualStrings("package_not_installed", try requiredString(try engine.errorDetail(allocator, error.PackageNotInstalled), "code"));
    try std.testing.expectError(error.PackageNotInstalled, engine.packages(allocator, "remove", removing));
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(try engine.errorDetail(allocator, error.PackageNotInstalled), "message"), "No installed package is named fixture") != null);
}

test "native source policy diagnostics identify missing fields without dispatch" {
    const base = "{\"version\":1,\"docker\":{\"socketPath\":\"/tmp/docker.sock\"},\"bindings\":{\"local\":{\"id\":\"local\",\"policyDigest\":\"" ++ "b" ** 64 ++ "\",\"resources\":{\"runtime\":\"node\"},\"capabilities\":{}}},\"resources\":{\"node\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"node\":{\"available\":true,\"profile\":\"builtin\",\"version\":\"24.18.0\",\"image\":\"node@sha256:" ++ "a" ** 64 ++ "\",\"builtins\":[],\"resources\":[\"runtime\"]}}}";
    const Case = struct { field: []const u8, path: []const u8, container: enum { profile, root, grants } = .profile };
    for ([_]Case{
        .{ .field = "version", .path = "runtimeProfiles.node.version" },
        .{ .field = "available", .path = "runtimeProfiles.node.available" },
        .{ .field = "profile", .path = "runtimeProfiles.node.profile" },
        .{ .field = "image", .path = "runtimeProfiles.node.image" },
        .{ .field = "builtins", .path = "runtimeProfiles.node.builtins" },
        .{ .field = "resources", .path = "runtimeProfiles.node.resources" },
        .{ .field = "docker", .path = "docker.socketPath", .container = .root },
        .{ .field = "runtime", .path = "bindings.local.resources.runtime", .container = .grants },
    }) |case| {
        var binding = try bindings.fromBytes(std.testing.allocator, base, "local");
        defer binding.deinit();
        switch (case.container) {
            .profile => _ = binding.configuration.object.getPtr("runtimeProfiles").?.object.getPtr("node").?.object.swapRemove(case.field),
            .root => _ = binding.configuration.object.swapRemove(case.field),
            .grants => _ = binding.registered.object.getPtr("resources").?.object.swapRemove(case.field),
        }
        var issue: runtime_policy.Issue = .{};
        if (runtime_policy.validate(binding.arena.allocator(), binding.configuration, binding.registered, "node", &issue)) |_| return error.AcceptedMissingPolicy else |_| {}
        try std.testing.expectEqualStrings(case.path, issue.path());
        try std.testing.expect(std.mem.indexOf(u8, issue.message(), "expected") != null);
    }
}

test "native source requirements fail before earlier infer adapter preflight" {
    const manifest = "{\"format\":\"loops/0.4\",\"name\":\"requirements\",\"version\":\"1\",\"dependencies\":{\"runtimes\":{\"node\":{\"min_version\":\"25.0.0\",\"modules\":[]}}},\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"first\",\"kind\":\"infer\",\"instructions\":\"never dispatch\",\"input\":null,\"output\":{\"schema\":true}}],\"output\":null}";
    var pkg = try package.fromFiles(std.testing.allocator, &.{.{ .path = "loop.json", .bytes = manifest }}, "loop.json");
    defer pkg.deinit();
    var binding = try bindings.fromBytes(std.testing.allocator, "{\"version\":1,\"docker\":{\"socketPath\":\"/tmp/docker.sock\"},\"bindings\":{\"local\":{\"id\":\"local\",\"policyDigest\":\"" ++ "b" ** 64 ++ "\",\"resources\":{\"runtime\":\"node\"},\"capabilities\":{}}},\"resources\":{\"node\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"node\":{\"available\":true,\"profile\":\"builtin\",\"version\":\"24.18.0\",\"image\":\"node@sha256:" ++ "a" ** 64 ++ "\",\"builtins\":[],\"resources\":[\"runtime\"]}}}", "local");
    defer binding.deinit();
    const Never = struct {
        fn preflight(_: *anyopaque, _: runner.Value, _: *package.Package, _: *bindings.Binding, _: runner.Selection) !void {
            return error.ModelPreflightWasCalled;
        }
    };
    var engine: Engine = .{ .options = .{ .io = std.testing.io, .profile = "/unused", .inferPreflightFn = Never.preflight } };
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.UnsupportedRuntime, engine.preflight(pkg, &binding, &cancel, std.math.maxInt(i64), null, false));
    try std.testing.expectEqualStrings("dependencies.runtimes.node.min_version", engine.runtime_issue.path());
    try std.testing.expect(std.mem.indexOf(u8, engine.runtime_issue.message(), "24.18.0 (configured profile)") != null);
    // A cached/probed version cannot be substituted with the configured claim.
    const requirement = (dependencies.runtimes(pkg.manifest).?).object.get("node").?;
    try std.testing.expectError(error.UnsupportedRuntime, runtime_policy.minimum(binding.arena.allocator(), "node", requirement, .{ 24, 18, 0 }, true, &engine.runtime_issue));
    try std.testing.expect(std.mem.indexOf(u8, engine.runtime_issue.message(), "probed/cached interpreter") != null);
}

const wasm_manifest = "{\"format\":\"loops/0.4\",\"name\":\"portable\",\"version\":\"1\",\"dependencies\":{\"runtimes\":{}},\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"transform\",\"kind\":\"code\",\"runtime\":\"wasm32-wasi-json/1\",\"file\":\"transform.wasm\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"integer\"}},\"required\":[\"n\"]}}}],\"output\":{\"from\":\"/steps/transform/output\"}}";
test "native Wasm install survives source removal and refuses artifact and source mutation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    try tmp.dir.createDir(io, "source", .fromMode(0o700));
    try tmp.dir.writeFile(io, .{ .sub_path = "source/loop.json", .data = wasm_manifest });
    const artifact = @embedFile("fixtures/wasm/transform-c.wasm");
    try tmp.dir.writeFile(io, .{ .sub_path = "source/transform.wasm", .data = artifact });
    try tmp.dir.writeFile(io, .{ .sub_path = "source/transform.c", .data = @embedFile("fixtures/wasm/transform.c") });
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine: Engine = .{ .options = .{ .io = io, .profile = path } };
    var adding = object();
    try put(a, &adding, "source", string(try std.fs.path.join(a, &.{ path, "source" })));
    try put(a, &adding, "yes", .{ .bool = true });
    _ = try engine.packages(a, "add", adding);
    try tmp.dir.deleteTree(io, "source");
    var params = object();
    try put(a, &params, "packagePath", string("portable"));
    try put(a, &params, "input", try schema.parse(a, "{\"n\":4}"));
    try std.testing.expect((try runner.get(try engine.check(a, params), "ok")).bool);
    var cancel = std.atomic.Value(bool).init(false);
    var run = try engine.run(a, params, &cancel, null);
    defer run.deinit();
    try std.testing.expectEqualStrings("completed", try requiredString(run.record, "status"));
    try std.testing.expectEqual(@as(i64, 5), (try runner.get(try runner.get(run.record, "output"), "n")).integer);
    const fetched = try engine.get(a, try requiredString(run.record, "run_id"));
    defer fetched.deinit();
    const public = try publicResult(a, fetched.value);
    try std.testing.expectEqualStrings(&code.hash(artifact), try runner.text(try runner.get(try runner.get((try runner.get(public, "code_executions")).array.items[0], "execution"), "artifact_sha256")));
    try std.testing.expect(public.object.get("attempts") == null and public.object.get("root_input") == null);
    try std.testing.expectEqual(@as(usize, 0), (try runner.get(public, "effects")).array.items.len);
    for ([_][]const u8{ "transform.wasm", "transform.c" }) |file| {
        const installed_path = try std.fs.path.join(a, &.{ "packages/portable/1", file });
        try tmp.dir.setFilePermissions(io, installed_path, .fromMode(0o600), .{});
        try tmp.dir.writeFile(io, .{ .sub_path = installed_path, .data = "changed" });
        try std.testing.expectError(error.InstalledPackageChanged, engine.run(a, params, &cancel, null));
        try tmp.dir.writeFile(io, .{ .sub_path = installed_path, .data = if (std.mem.eql(u8, file, "transform.wasm")) artifact else @embedFile("fixtures/wasm/transform.c") });
    }
}
test "native Wasm invalid later artifact refuses before all inference callbacks" {
    const a = std.testing.allocator;
    const manifest = "{\"format\":\"loops/0.4\",\"name\":\"later\",\"version\":\"1\",\"dependencies\":{\"runtimes\":{}},\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"first\",\"kind\":\"infer\",\"instructions\":\"Never\",\"input\":null,\"output\":{\"schema\":true}},{\"id\":\"later\",\"kind\":\"code\",\"runtime\":\"wasm32-wasi-json/1\",\"file\":\"later.wasm\",\"input\":null,\"output\":{\"schema\":true}}],\"output\":null}";
    const Never = struct {
        fn preflight(_: *anyopaque, _: runner.Value, _: *package.Package, _: *bindings.Binding, _: runner.Selection) !void {
            return error.InferenceWasCalled;
        }
    };
    var engine: Engine = .{ .options = .{ .io = std.testing.io, .profile = "/unused", .inferPreflightFn = Never.preflight } };
    {
        var binding = try bindings.fromBytes(a, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{},\"capabilities\":{}}},\"resources\":{},\"runtimeProfiles\":{}}", "local");
        defer binding.deinit();

        var cancel = std.atomic.Value(bool).init(false);
        inline for (.{ "random", "bad-signature", "bad-start", "memory-too-large" }) |file| {
            var pkg = try package.fromFiles(a, &.{ .{ .path = "loop.json", .bytes = manifest }, .{ .path = "later.wasm", .bytes = @embedFile("fixtures/wasm/" ++ file ++ ".wasm") } }, "loop.json");
            defer pkg.deinit();
            try std.testing.expectError(if (std.mem.eql(u8, file, "bad-start")) error.WasmEntrypoint else if (std.mem.eql(u8, file, "memory-too-large")) error.WasmMemory else error.WasmImport, engine.preflight(pkg, &binding, &cancel, std.math.maxInt(i64), null, false));
            try std.testing.expectEqualStrings("steps.later.file", engine.runtime_issue.path());
            try std.testing.expect(std.mem.indexOf(u8, engine.runtime_issue.message(), "later.wasm") != null);
            try std.testing.expect(std.mem.indexOf(u8, engine.runtime_issue.message(), wasm.runtime) != null);
            if (std.mem.eql(u8, file, "random")) try std.testing.expect(std.mem.indexOf(u8, engine.runtime_issue.message(), "random_get") != null);
        }
    }
    var details = std.heap.ArenaAllocator.init(a);
    defer details.deinit();
    const detail = try engine.errorDetail(details.allocator(), error.WasmMemory);
    try std.testing.expectEqualStrings("steps.later.file", try requiredString(detail, "path"));
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(detail, "message"), "128 MiB") != null);
}

test "native Wasm output schema failure keeps attempt identity and no committed output" {
    var profile: AgentProfile = undefined;
    const bad_schema = try std.mem.replaceOwned(u8, std.testing.allocator, wasm_manifest, "\"type\":\"integer\"", "\"type\":\"string\"");
    defer std.testing.allocator.free(bad_schema);
    try profile.initWith(bad_schema, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{},\"capabilities\":{}}},\"resources\":{},\"runtimeProfiles\":{}}");
    defer profile.deinit();
    try profile.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "package/transform.wasm", .data = @embedFile("fixtures/wasm/constant.wasm") });
    var engine = profile.engine();
    var params = object();
    const a = profile.arena.allocator();
    try put(a, &params, "packagePath", string(try std.fs.path.join(a, &.{ profile.buffer[0..profile.length], "package" })));
    var cancel = std.atomic.Value(bool).init(false);
    var run = try engine.run(a, params, &cancel, null);
    defer run.deinit();
    try std.testing.expectEqualStrings("failed", try requiredString(run.record, "status"));
    try std.testing.expectEqualStrings("InvalidOutput", try requiredString(try runner.get(run.record, "error"), "cause"));
    try std.testing.expect((try runner.get(try runner.get((try runner.get(run.record, "attempts")).array.items[0], "code_execution"), "engine")).string.len > 0);
    try std.testing.expect(run.record.object.get("output") == null);
    // Compute identity cannot make an unrelated unknown external effect replayable.
    const run_alloc = run.arena.allocator();
    const effects = run.record.object.getPtr("effects").?;
    try effects.array.append(try schema.parse(run_alloc, "{\"id\":\"unrelated\",\"kind\":\"external\",\"state\":\"unknown\"}"));
    try std.testing.expectEqualStrings("unknown_effects", diagnostics.retryGuidance(run.record).reason);
    try profile.temporary.dir.writeFile(std.testing.io, .{ .sub_path = "package/transform.wasm", .data = @embedFile("fixtures/wasm/trap.wasm") });
    var trapped = try engine.run(a, params, &cancel, null);
    defer trapped.deinit();
    try std.testing.expectEqualStrings("WasmTrap", try requiredString(trapped.record, "failure_cause"));
    const public = try publicResult(a, trapped.record);
    try std.testing.expectEqualStrings("wasmtime", try requiredString(try runner.get((try runner.get(public, "code_executions")).array.items[0], "execution"), "engine"));
    try std.testing.expect(public.object.get("output") == null);
}

test "native startup executes retained workspace Wasm on an empty profile with no model or source runtime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "profile", .fromMode(0o700));
    try tmp.dir.createDir(io, "workspace", .default_dir);
    var buffer: [4096]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var cwd: [4096]u8 = undefined;
    var current = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer current.close(io);
    const assets = cwd[0..try current.realPath(io, &cwd)];
    var engine: Engine = .{ .options = .{ .io = io, .profile = try std.fs.path.join(a, &.{ root, "profile" }) } };
    var cancel = std.atomic.Value(bool).init(false);
    const result = try engine.startup(a, try std.fs.path.join(a, &.{ root, "workspace" }), assets, &cancel);
    try std.testing.expect((try runner.get(result, "available")).bool);
    const output = try runner.get(result, "output");
    try std.testing.expectEqualStrings("Describe a repeatable task and I can help you create a Loop here.", try requiredString(output, "suggestion"));
    try std.testing.expect((try runner.get(output, "complete")).bool);
    const retained = try engine.get(a, try requiredString(result, "run_id"));
    defer retained.deinit();
    const record = try publicResult(a, retained.value);
    try std.testing.expectEqual(@as(i64, 0), (try runner.get(record, "model_request_dispatches")).integer);
    try std.testing.expect((try runner.get(record, "model_request_dispatches_complete")).bool);
    try std.testing.expectEqual(@as(usize, 0), (try runner.get(record, "effects")).array.items.len);
    const identity = try runner.get((try runner.get(record, "code_executions")).array.items[0], "execution");
    try std.testing.expectEqualStrings(wasm.runtime, try requiredString(identity, "profile"));
    const artifact = try std.Io.Dir.cwd().readFileAlloc(io, "loops/workspace-check/suggest.wasm", a, .unlimited);
    try std.testing.expectEqualStrings(&code.hash(artifact), try requiredString(identity, "artifact_sha256"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "profile/installation.json", .{}));
}

test "native engine checks a GitHub address without installing it, runs it only once it is admitted, and records the installed name and version" {
    const io = std.testing.io;
    var t: installed.TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const allocator = t.arena.allocator();
    var remote: installed.TestRemote = .{ .t = &t };
    try remote.init();
    _ = try t.folder("work/tools/fixture", "{\"format\":\"loops/0.1\",\"name\":\"fixture\",\"version\":\"1\",\"inputs\":{\"schema\":{\"type\":\"object\",\"required\":[\"count\"]}},\"steps\":[{\"id\":\"saved\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"one.py\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/saved/output\"}}", "print('saved bytes')\n");
    _ = try remote.push("main");
    var configuration = try t.tmp.dir.createFile(io, "profile/installation.json", .{ .permissions = .fromMode(0o600) });
    defer configuration.close(io);
    try configuration.writeStreamingAll(io, "{\"version\":1,\"bindings\":{\"local\":{\"id\":\"local\",\"resources\":{\"runtime\":\"python\"},\"capabilities\":{}}},\"resources\":{\"python\":{\"kind\":\"runtime\"}},\"runtimeProfiles\":{\"python3\":{\"resources\":[\"runtime\"]}}}");
    var fixture: Fixture = .{};
    var engine: Engine = .{ .options = .{ .io = io, .profile = t.profile, .code_context = &fixture, .codeFn = Fixture.execute, .codePreflightFn = Fixture.preflight, .packages = remote.options() }, .addresses = true };
    const address = "acme/loops/tools/fixture";
    var params = object();
    try put(allocator, &params, "packagePath", string(address));
    var cancel = std.atomic.Value(bool).init(false);

    // check fetches and reports. Nothing is installed.
    const checked = try engine.check(allocator, params);
    try std.testing.expect((try runner.get(checked, "ok")).bool);
    try std.testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));
    try std.testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages/fixture", .{}));

    // run never fetches by itself: an address that was not admitted is refused.
    try put(allocator, &params, "input", try schema.parse(allocator, "{\"count\":1}"));
    try std.testing.expectError(error.PackageAddress, engine.run(allocator, params, &cancel, null));
    try std.testing.expectEqualStrings("package_address", try requiredString(try engine.errorDetail(allocator, error.PackageAddress), "code"));

    // Admission without a digest only inspects.
    const asked = (try engine.admit(allocator, params)).?;
    try std.testing.expectEqualStrings("confirmation_required", try requiredString(asked, "status"));
    try std.testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));
    try put(allocator, &params, "yes", .{ .bool = true });
    try put(allocator, &params, "digest", string("0123456789abcdef" ** 4));
    try std.testing.expectError(error.PackageDigestMismatch, engine.admit(allocator, params));
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(try engine.errorDetail(allocator, error.PackageDigestMismatch), "message"), "this is not the package that was inspected") != null);
    try std.testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));

    // With the inspected digest it installs, and the run is of the installed name and version.
    try put(allocator, &params, "digest", try runner.get(asked, "digest"));
    const admitted = (try engine.admit(allocator, params)).?;
    try std.testing.expectEqualStrings("installed", try requiredString(admitted, "status"));
    try std.testing.expectEqualStrings("fixture@1", try requiredString(admitted, "package"));
    try std.testing.expectEqual(@as(usize, 0), fixture.execute_calls);
    try put(allocator, &params, "packagePath", try runner.get(admitted, "package"));
    // Address admission must still enter normal run recovery. An earlier model request
    // has an unknown outcome; admitting this independent package cannot settle it.
    var store = try storage.Store.init(std.testing.allocator, io, t.profile);
    defer store.deinit();
    const orphan = try schema.parse(allocator, "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_address_orphan\",\"status\":\"running\",\"used_tokens\":7,\"usage_unknown\":true,\"model_request_dispatches\":1,\"model_request_dispatches_complete\":false,\"attempts\":[{\"status\":\"running\"}],\"effects\":[{\"id\":\"request\",\"kind\":\"model_request\",\"state\":\"unknown\"}]}");
    try store.save(orphan);
    var run = try engine.run(allocator, params, &cancel, null);
    defer run.deinit();
    const recovered = try store.load(std.testing.allocator, "run_address_orphan");
    defer recovered.deinit();
    try std.testing.expectEqualStrings("stopped", try requiredString(recovered.value, "status"));
    try std.testing.expect((try runner.get(recovered.value, "usage_unknown")).bool);
    try std.testing.expect(!(try runner.get(recovered.value, "model_request_dispatches_complete")).bool);
    try std.testing.expectEqual(@as(i64, 7), (try runner.get(recovered.value, "used_tokens")).integer);
    try std.testing.expectEqualStrings("unknown", try requiredString((try runner.get(recovered.value, "effects")).array.items[0], "state"));
    try std.testing.expect(!diagnostics.retryGuidance(recovered.value).allowed);
    try std.testing.expectEqualStrings("completed", try requiredString(run.record, "status"));
    try std.testing.expectEqualStrings(try std.fs.path.join(allocator, &.{ t.profile, "packages/fixture/1/loop.json" }), try requiredString(run.record, "package_path"));
    try std.testing.expectEqualStrings(try requiredString(asked, "digest"), try requiredString(run.record, "package_digest"));
    try std.testing.expectEqual(@as(usize, 1), fixture.execute_calls);
    // The record names the installed package, which is what a retry would load: by that
    // path it is the same package, checked against its lock entry.
    var recorded = object();
    try put(allocator, &recorded, "packagePath", try runner.get(run.record, "package_path"));
    try std.testing.expectEqualStrings(try requiredString(asked, "digest"), try requiredString(try engine.check(allocator, recorded), "package_digest"));

    // The second run of the same source asks nothing.
    var second = object();
    try put(allocator, &second, "packagePath", string(address));
    const ready = (try engine.admit(allocator, second)).?;
    try std.testing.expectEqualStrings("ready", try requiredString(ready, "status"));
    try std.testing.expectEqualStrings("fixture@1", try requiredString(ready, "package"));
    // A name and a path are not addresses: there is nothing to admit.
    for ([_][]const u8{ "fixture", "fixture@1", "./loops/warm-context", "/tmp/x" }) |other| {
        try put(allocator, &second, "packagePath", string(other));
        try std.testing.expect(try engine.admit(allocator, second) == null);
    }

    // A chat tool call may not fetch: check, admission and run all refuse an address.
    engine.addresses = false;
    try put(allocator, &second, "packagePath", string(address));
    try std.testing.expectError(error.PackageAddress, engine.check(allocator, second));
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(try engine.errorDetail(allocator, error.PackageAddress), "message"), "nothing here may fetch or install a package") != null);
    try std.testing.expectError(error.PackageAddress, engine.admit(allocator, second));
    try std.testing.expectError(error.PackageAddress, engine.run(allocator, second, &cancel, null));
    // Both readings: refused before any fetch, by check and by admission alike.
    engine.addresses = true;
    try put(allocator, &second, "packagePath", string("loops/warm-context"));
    try std.testing.expectError(error.PackageAmbiguous, engine.check(allocator, second));
    try std.testing.expect(std.mem.indexOf(u8, try requiredString(try engine.errorDetail(allocator, error.PackageAmbiguous), "message"), "write ./loops/warm-context to use the folder") != null);
    try std.testing.expectError(error.PackageAmbiguous, engine.admit(allocator, second));
    try std.testing.expectError(error.PackageAmbiguous, engine.run(allocator, second, &cancel, null));
}

test "native engine run with a missing required input says what the input schema requires and shows --input" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    const input_schema = "{\"type\":\"object\",\"required\":[\"count\"],\"properties\":{\"count\":{\"type\":\"integer\"}}}";
    try temporary.dir.writeFile(io, .{ .sub_path = "loop.json", .data = "{\"format\":\"loops/0.1\",\"name\":\"fixture\",\"version\":\"1\",\"inputs\":{\"schema\":" ++ input_schema ++ "},\"steps\":[{\"id\":\"saved\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"saved.py\",\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/saved/output\"}}" });
    try temporary.dir.writeFile(io, .{ .sub_path = "saved.py", .data = "print('saved bytes')\n" });
    var buffer: [4096]u8 = undefined;
    const path = buffer[0..try temporary.dir.realPath(io, &buffer)];
    var engine: Engine = .{ .options = .{ .io = io, .profile = path } };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var params = object();
    try put(allocator, &params, "packagePath", string(path));
    var cancel = std.atomic.Value(bool).init(false);
    // No input at all.
    try std.testing.expectError(error.InvalidInput, engine.run(allocator, params, &cancel, null));
    var detail = try engine.errorDetail(allocator, error.InvalidInput);
    try std.testing.expectEqualStrings("invalid_input", try requiredString(detail, "code"));
    try std.testing.expectEqualStrings("No input was supplied, and this package's input schema does not accept an empty object: at /count, Required property is missing. The input must match this schema: " ++ input_schema ++ " Write the input as JSON in a file and pass it with --input FILE, or pass --input - to read it from standard input.", try requiredString(detail, "message"));
    try std.testing.expect(schema.equal(try schema.parse(allocator, input_schema), try runner.get(detail, "input_schema")));
    try std.testing.expectEqualStrings("/count", try requiredString(detail, "pointer"));
    // An input that was supplied and is wrong says where.
    try put(allocator, &params, "input", try schema.parse(allocator, "{\"count\":\"one\"}"));
    try std.testing.expectError(error.InvalidInput, engine.run(allocator, params, &cancel, null));
    detail = try engine.errorDetail(allocator, error.InvalidInput);
    try std.testing.expectEqualStrings("The input does not match this package's input schema: at /count, Value has the wrong type. The input must match this schema: " ++ input_schema ++ " Write the input as JSON in a file and pass it with --input FILE, or pass --input - to read it from standard input.", try requiredString(detail, "message"));
}
