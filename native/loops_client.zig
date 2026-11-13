//! Foreground Loops bridge; fx remains the sole terminal renderer.
const std = @import("std");
pub const host_bridge = @import("host_bridge.zig");
pub const events = host_bridge.events;
const alloc = std.heap.c_allocator;
pub const version = @import("build_options").app_version;
const io_mod = @import("../vendor/fx/src/core/shared/io.zig");
const schema = @import("loops/schema.zig");
const bulk = @import("bulk.zig");
const installed = @import("loops/installed.zig");
const paths = @import("../vendor/fx/src/core/shared/profile_paths.zig");
const help = "fh " ++ version ++ " — native Loops\n\nUsage: fh capture PLAN --cdp ENDPOINT --out DIRECTORY [--token-env NAME] [--json]\n       fh [check PACKAGE | run PACKAGE | retry RUN | runs | get RUN | cancel RUN]\n       fh settle RUN --applied|--not-applied [--effect ID]\n       fh [batch PACKAGE | eval PACKAGE] --cases FILE\n       fh run PACKAGE --driver agent | next RUN | submit RUN --path PATH --pass N --output FILE|-\n       fh run OWNER/REPO/PATH[@REF] [--yes] [--digest HEX]   fetch a package from GitHub, show what it will do, install it and run it\n       fh add SOURCE [--yes] [--digest HEX] | list | remove NAME[@VERSION] | update NAME [--yes] [--digest HEX]\n       fh setup [ai|jev|browser|workspace|runtime] | login codex | logout codex | status | accounts | models\n\nOptions: --input FILE|- --cases FILE --bindings-id ID --after RUN_ID --driver runner|agent\n         --json (one final result) | --events (accepted ID and final result)\n\nPackages: fh add SOURCE installs a package into the profile. SOURCE is a folder, or a GitHub address OWNER/REPO[/PATH][@REF]: PATH is the folder that holds loop.json (default the repository root) and REF is a branch, tag or full commit (default the default branch). GitHub packages are fetched with your own git and its configuration; fh takes no token. add prints the name, version, digest, steps, required capabilities, code files and source, then asks before installing; --yes skips the question, and without a terminal --yes is required. Without --yes and a terminal, add prints the exact command to run next: the same one with --yes --digest HEX. --digest HEX installs only a package with that digest, so what is installed is what was inspected. Nothing in a package is run by add. An installed version never changes: the same name and version with other content is refused until you fh remove it.\nPACKAGE is read by one rule, from its text alone, whatever is in the current directory: text that starts with . or / is a path on this machine; text with no / is an installed NAME or NAME@VERSION; anything else is a GitHub address OWNER/REPO[/PATH][@REF]. SOURCE follows the same rule, without the installed name. To use a folder in the current directory, write ./NAME. When an address is also the relative path of a folder here, check, run, batch and eval refuse and tell you to write ./ for the folder.\nfh run ADDRESS fetches the package as fh add does and prints the same inspection. At a terminal it asks Install and run NAME VERSION? [y/N]; --yes skips the question. Without a terminal it installs and runs only with --yes --digest HEX, and otherwise prints the inspection and the exact command to run next, and installs and runs nothing. A source that is already installed with the same content runs with no question. It is installed exactly as fh add installs it and run as NAME@VERSION, so retry, next and submit work as usual. batch and eval do this once, before any case. fh check ADDRESS fetches and checks, and installs nothing.\nNames and versions are matched exactly, upper and lower case included. NAME alone is the highest installed version when every installed version is dot-separated numbers, otherwise the most recently installed. An installed package is hashed on every load and refused if its files changed.\nfh list shows installed packages; fh update NAME fetches the recorded source again and installs a new version beside the old one. See docs/packages.md.\nSetup: Codex login, Gateway API key or OpenAI-compatible key/endpoint/model; optional Jev key; setup browser registers installed Moli (no download).\nSource runtime: fh setup runtime python3|node --socket /absolute/docker.sock --image IMAGE@sha256:DIGEST --version MAJOR.MINOR.PATCH. Optional installed isolated source runtime; no pull or provider request.\nWorkspace: fh setup workspace GRANT.json [--trust-host] [--bindings-id workspace]. --trust-host is needed only when the grant registers host commands; a grant of files alone gives workspace_read steps read-only access.\nNative fh-workspace/1 steps run exact registered argv and apply hash-guarded source edits; no Python or Docker required.\nNo arguments: first-run setup, then native fx terminal chat when attached to a TTY; help otherwise.\nOrdinary text uses native provider, filesystem, docs and Loop tools.\nA bundled code-only workspace check runs after first paint.\nConversation: /model MODEL [EFFORT] [fast|normal], /effort EFFORT, /fast, /resume.\nLoops: /check /run /retry /runs /get /cancel /settle /next /submit\nPackages: /add SOURCE /list /remove /update; chat never asks, so /add SOURCE only inspects and prints the command that installs it, /add SOURCE --yes --digest HEX. In chat --yes needs --digest, and /update is the same. /run ADDRESS only inspects too, and prints /run ADDRESS --yes --digest HEX. The chat model's own tools never fetch or install a package.\nRuns remain owned in the foreground; interruption cancels accepted work.\nAgent driver: fh makes no model call. Your agent performs each step that next lists and submits its output; submit exits 0 when accepted, 4 for any other answer, and 2 for an error. Error owner_busy means another fh operation is in progress: the requested operation was not started (earlier orphan bookkeeping may have occurred), so retry.\nNative records preserve input identity, failure cause and guarded retry guidance; uncertain effects require inspection.\nRecovery: new work automatically records abandoned runs as stopped under their leases; fh get RUN does this too. Declaration-only check reports interruption without writing. Unknown provider outcomes and incomplete usage remain uncertain and prevent retry. Unresolved local resource or mutation effects still block new work: inspect them, then fh settle RUN --applied or --not-applied records what you found. Retry runs on the provider and model the original run recorded.\nBatch/eval run sequentially in one worker under one package digest and one bindings digest; eval compares supplied labels. A worker failure stops the suite and still prints the report for the cases that ran. input_file stays inside the cases file's directory.\nStatus shows Jev key presence without a provider request; access remains unverified.\nNative Zig application; workspace Loops can invoke registered host tools. No detached execution.\nAgent guidance: adjacent skills/using-fh/SKILL.md and docs/loops.md.\n";
fn output(fd: c_int, text: []const u8) void {
    var offset: usize = 0;
    while (offset < text.len) {
        const n = std.c.write(fd, text[offset..].ptr, text.len - offset);
        if (n <= 0) return;
        offset += @intCast(n);
    }
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(name) else null;
}
fn stringField(v: std.json.Value, name: []const u8) ?[]const u8 {
    const value = field(v, name) orelse return null;
    return if (value == .string) value.string else null;
}
fn obj() std.json.Value {
    return .{ .object = std.json.ObjectMap{} };
}
fn put(v: *std.json.Value, key: []const u8, value: std.json.Value) !void {
    try v.object.put(alloc, key, value);
}
fn str(s: []const u8) std.json.Value {
    return .{ .string = s };
}

pub fn fastpath(raw: []const [*:0]const u8) !bool {
    if (raw.len == 1 and std.c.isatty(0) == 0) {
        output(1, help);
        return true;
    }
    if (raw.len >= 2) {
        const command = std.mem.span(raw[1]);
        if (eql(command, "help") or eql(command, "--help") or eql(command, "-h")) {
            output(1, help);
            return true;
        }
        if (eql(command, "--version") or eql(command, "-v")) {
            output(1, "fh " ++ version ++ "\n");
            return true;
        }
        for (raw[2..]) |argument| if (eql(std.mem.span(argument), "--help") or eql(std.mem.span(argument), "-h")) {
            output(1, help);
            return true;
        };
    }
    return false;
}
pub fn environment() !void {
    if (std.c.getenv("FH_DATA_DIR")) |value| if (!std.fs.path.isAbsolute(std.mem.span(value))) {
        output(2, "FH_DATA_DIR must be an absolute private directory.\n");
        return error.InvalidProfilePath;
    };
}
pub fn identityCommand(_: []const [*:0]const u8) ?u8 {
    return null;
}
pub fn allows_cli(_: []const [*:0]const u8) bool {
    return true;
}
const slash_names = [_][]const u8{ "/run", "/check", "/runs", "/get", "/cancel", "/retry", "/login", "/status", "/help", "/clear", "/version", "/quit", "/exit" };
pub fn slash_specs(comptime Spec: type) [slash_names.len]Spec {
    var result: [slash_names.len]Spec = undefined;
    inline for (slash_names, 0..) |name, i| result[i] = .{ .kind = if (eql(name, "/clear")) .clear_screen else if (eql(name, "/quit") or eql(name, "/exit")) .quit else if (eql(name, "/version")) .version else .help, .command = name, .help_entry = name, .completion_description = name[1..], .presentation_category = .general, .show_in_welcome = i < 5 };
    return result;
}
pub const InferenceDisplay = struct {
    model: []const u8 = "gpt-6-luna",
    reasoning: []const u8 = "medium",
    fast: bool = true,
    owned: bool = false,
};
fn displaySettings(value: std.json.Value) !InferenceDisplay {
    var result: InferenceDisplay = .{};
    if (value != .object) return error.InvalidProfile;
    if (field(value, "modelByComplexity")) |mapping| {
        result.model = stringField(mapping, "medium") orelse return error.InvalidProfile;
    } else if (field(value, "model")) |_| result.model = stringField(value, "model") orelse return error.InvalidProfile;
    if (field(value, "reasoning")) |_| result.reasoning = stringField(value, "reasoning") orelse return error.InvalidProfile;
    var valid_reasoning = false;
    for ([_][]const u8{ "none", "minimal", "low", "medium", "high", "xhigh" }) |effort| if (eql(effort, result.reasoning)) {
        valid_reasoning = true;
    };
    if (!valid_reasoning or result.model.len == 0 or result.model.len > 256) return error.InvalidProfile;
    for (result.model) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "._:/-", byte) == null) {
        return error.InvalidProfile;
    };
    if (field(value, "serviceTier")) |_| {
        const tier = stringField(value, "serviceTier") orelse return error.InvalidProfile;
        if (!eql(tier, "priority") and !eql(tier, "default")) return error.InvalidProfile;
        result.fast = eql(tier, "priority");
    }
    result.model = try alloc.dupe(u8, result.model);
    errdefer alloc.free(result.model);
    result.reasoning = try alloc.dupe(u8, result.reasoning);
    result.owned = true;
    return result;
}
pub fn idleInferenceDisplay() InferenceDisplay {
    return .{};
}
// Commands the chat and the CLI share; the CLI adds batch and eval.
const commands = [_][]const u8{ "check", "run", "runs", "get", "cancel", "retry", "settle", "next", "submit", "add", "list", "remove", "update" };
fn packageCommand(method: []const u8) bool {
    return eql(method, "add") or eql(method, "list") or eql(method, "remove") or eql(method, "update");
}
const Command = struct {
    method: []const u8,
    params: std.json.Value,
    json: bool = false,
    stream_events: bool = false,
};
fn absolute(path: []const u8) ![]const u8 {
    const cwd = try std.process.currentPathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(cwd);
    return std.fs.path.resolve(alloc, &.{ cwd, path });
}
fn parse(args: []const []const u8, interactive: bool) !Command {
    if (args.len == 0) return error.Usage;
    const method = args[0];
    var allowed = false;
    for (commands ++ [_][]const u8{ "batch", "eval" }) |name| if (eql(name, method)) {
        allowed = true;
    };
    if (!allowed) return error.Usage;
    var command: Command = .{ .method = method, .params = obj() };
    var position: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--json")) {
            command.json = true;
            continue;
        }
        if (eql(arg, "--events")) {
            command.stream_events = true;
            continue;
        }
        if (eql(method, "settle") and (eql(arg, "--applied") or eql(arg, "--not-applied"))) {
            // Exactly one outcome: it is what the person found, never a default.
            if (command.params.object.contains("outcome")) return error.Usage;
            try put(&command.params, "outcome", str(if (eql(arg, "--applied")) "applied" else "not_applied"));
            continue;
        }
        // run, batch and eval take these two only for a GitHub address: checked below, once
        // the PACKAGE is known, because a flag may come before it.
        const installs = eql(method, "add") or eql(method, "update") or eql(method, "run") or eql(method, "batch") or eql(method, "eval");
        if (installs and eql(arg, "--yes")) {
            try put(&command.params, "yes", .{ .bool = true });
            continue;
        }
        if (installs and eql(arg, "--digest")) {
            i += 1;
            if (i >= args.len or command.params.object.contains("digest")) return error.Usage;
            try put(&command.params, "digest", str(args[i]));
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            if (packageCommand(method)) return error.Usage;
            i += 1;
            if (i >= args.len) return error.Usage;
            const value = args[i];
            const submitting = eql(method, "submit");
            const key: []const u8 = if (eql(arg, "--input") and eql(method, "run")) "inputFile" else if (eql(arg, "--cases") and (eql(method, "batch") or eql(method, "eval"))) "casesFile" else if (eql(arg, "--driver") and eql(method, "run")) "driver" else if (eql(arg, "--output") and submitting) "outputFile" else if (eql(arg, "--path") and submitting) "path" else if (eql(arg, "--effect") and eql(method, "settle")) "effect" else if (eql(arg, "--pass") and submitting) "pass" else if (eql(arg, "--bindings-id") and !eql(method, "retry")) "bindingsId" else if (eql(arg, "--after") and eql(method, "runs")) "after" else return error.Usage;
            if (command.params.object.contains(key)) return error.Usage;
            if (eql(key, "driver") and !eql(value, "agent") and !eql(value, "runner")) return error.Usage;
            if (eql(key, "pass")) {
                try put(&command.params, key, .{ .integer = std.fmt.parseInt(u32, value, 10) catch return error.Usage });
                continue;
            }
            const file = eql(key, "inputFile") or eql(key, "outputFile");
            if (file and eql(value, "-")) {
                if (interactive) return error.Usage;
                var input: std.ArrayList(u8) = .empty;
                var buffer: [8192]u8 = undefined;
                while (true) {
                    const n = std.c.read(0, &buffer, buffer.len);
                    if (n < 0) return error.InputFailed;
                    if (n == 0) break;
                    if (input.items.len + @as(usize, @intCast(n)) > 1024 * 1024) return error.InputLimit;
                    try input.appendSlice(alloc, buffer[0..@intCast(n)]);
                }
                try put(&command.params, key[0 .. key.len - "File".len], try schema.parse(alloc, input.items));
                if (eql(key, "inputFile")) try put(&command.params, "inputSource", str("stdin"));
            } else try put(&command.params, key, str(if (file or eql(key, "casesFile")) try absolute(value) else value));
        } else {
            if (position > 0) return error.Usage;
            position += 1;
            const key: []const u8 = if (eql(method, "run") or eql(method, "check") or eql(method, "batch") or eql(method, "eval")) "packagePath" else if (eql(method, "add")) "source" else if (eql(method, "remove") or eql(method, "update")) "package" else if (eql(method, "get") or eql(method, "cancel") or eql(method, "retry") or eql(method, "settle") or eql(method, "next") or eql(method, "submit")) "runId" else return error.Usage;
            // Only a path is resolved here. An installed name and a GitHub address travel as
            // they were typed. What is in the current directory is never consulted.
            try put(&command.params, key, str(if (eql(key, "packagePath") and installed.classify(arg) == .path) try absolute(arg) else arg));
        }
    }
    if (command.json and command.stream_events) return error.Usage;
    const fetching = if (stringField(command.params, "packagePath")) |package_argument| !eql(method, "check") and installed.classify(package_argument) == .address else false;
    if (!eql(method, "add") and !eql(method, "update") and !fetching and (command.params.object.contains("yes") or command.params.object.contains("digest"))) return error.Usage;
    // Chat cannot ask a question, so the worker insists there that --yes carries a digest.
    if (interactive and (eql(method, "add") or eql(method, "update") or fetching)) try put(&command.params, "chat", .{ .bool = true });
    // What was typed, without the two confirmation flags: the command to run next is this
    // with --yes and the inspected digest added.
    if (fetching) try put(&command.params, "nextCommand", str(try typed(args, interactive)));
    if (!eql(method, "runs") and !eql(method, "list") and position != 1) return error.Usage;
    if ((eql(method, "batch") or eql(method, "eval")) and !command.params.object.contains("casesFile")) return error.Usage;
    if (eql(method, "settle") and !command.params.object.contains("outcome")) return error.Usage;
    if (command.stream_events and !eql(method, "run") and !eql(method, "retry") and !eql(method, "batch") and !eql(method, "eval")) return error.Usage;
    if (eql(method, "submit") and (!command.params.object.contains("path") or !command.params.object.contains("pass") or command.params.object.contains("output") == command.params.object.contains("outputFile"))) return error.Usage;
    return command;
}
fn typed(args: []const []const u8, interactive: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, if (interactive) "/" else "fh ");
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], "--yes")) continue;
        if (eql(args[i], "--digest")) {
            i += 1;
            continue;
        }
        if (i != 0) try out.append(alloc, ' ');
        // Chat splits on spaces and has no quoting, so its words go back as they came.
        try out.appendSlice(alloc, if (interactive) args[i] else try installed.shellWord(alloc, args[i]));
    }
    return out.toOwnedSlice(alloc);
}

pub const Client = struct {
    inference_display: InferenceDisplay = .{},
    bridge: host_bridge.Bridge = .{},
    active: bool = false,
    cancel_requested: bool = false,
    poll_id: u64 = 0,
    explicit_cancel_ids: [8]u64 = .{0} ** 8,
    loop_name: []const u8 = "Loop",
    funding: []const u8 = "unknown",
    pending_id: u64 = 0,
    method: []const u8 = "",
    run_id: ?[]const u8 = null,
    // An agent-driven run answers once, with the steps to perform: there is no run to follow.
    driven: bool = false,
    sequence: u64 = 0,
    presentation_owned: bool = false,
    last_get: i64 = 0,
    pub fn setInferenceDisplay(self: *Client, display: InferenceDisplay) void {
        if (self.inference_display.owned) {
            alloc.free(self.inference_display.model);
            alloc.free(self.inference_display.reasoning);
        }
        self.inference_display = display;
    }
    pub fn start(self: *Client) !void {
        try self.bridge.start();
    }
    pub fn send(self: *Client, method: []const u8, params: std.json.Value) !u64 {
        return self.bridge.send(method, params);
    }
    pub fn command(self: *Client, command_value: Command) !void {
        if (self.active) return error.LoopsRunBusy;
        try self.start();
        self.method = command_value.method;
        self.active = true;
        self.cancel_requested = false;
        self.run_id = null;
        self.sequence = 0;
        self.driven = agentDriven(command_value);
        self.pending_id = try self.send(command_value.method, command_value.params);
    }
    pub fn cancel(self: *Client) bool {
        if (!self.active) return false;
        self.cancel_requested = true;
        if (self.run_id) |id| {
            var p = obj();
            defer p.object.deinit(alloc);
            put(&p, "runId", str(id)) catch return true;
            _ = self.send("cancel", p) catch {};
        } else self.bridge.cancelRequest(self.pending_id);
        return true;
    }
    pub fn get(self: *Client) !void {
        if (self.poll_id != 0) return;
        var p = obj();
        defer p.object.deinit(alloc);
        try put(&p, "runId", str(self.run_id orelse return error.MissingRunId));
        self.poll_id = try self.send("get", p);
        self.pending_id = self.poll_id;
    }
    pub fn acceptRun(self: *Client, value: std.json.Value) !void {
        self.run_id = try alloc.dupe(u8, stringField(value, "run_id") orelse return error.InvalidResult);
        if (field(value, "presentation")) |presentation| {
            self.loop_name = try alloc.dupe(u8, stringField(presentation, "loop") orelse return error.InvalidResult);
            self.funding = try alloc.dupe(u8, stringField(presentation, "funding") orelse return error.InvalidResult);
            self.presentation_owned = true;
            self.setInferenceDisplay(if (eql(self.funding, "code-only") or eql(self.funding, "unadmitted")) .{ .model = self.funding, .reasoning = "none", .fast = false } else try displaySettings(presentation));
        }
    }
    pub fn cancelTarget(self: *Client, target: []const u8) !void {
        for (&self.explicit_cancel_ids) |*slot| {
            if (slot.* != 0) continue;
            var p = obj();
            defer p.object.deinit(alloc);
            try put(&p, "runId", str(target));
            slot.* = try self.send("cancel", p);
            return;
        }
        return error.RequestLimit;
    }
    pub fn takeExplicitCancel(self: *Client, id: u64) bool {
        for (&self.explicit_cancel_ids) |*slot| {
            if (slot.* == id) {
                slot.* = 0;
                return true;
            }
        }
        return false;
    }
    pub fn next(self: *Client) !?events.Decoded {
        const decoded = try self.bridge.next();
        if (decoded) |d| if (d.message == .response and d.message.response.id == self.poll_id) {
            self.poll_id = 0;
        };
        return decoded;
    }
    pub fn deinit(self: *Client) void {
        self.bridge.deinit();
        self.finishCommand();
        self.* = .{};
    }
    fn finishCommand(self: *Client) void {
        self.setInferenceDisplay(.{});
        if (self.run_id) |id| alloc.free(id);
        if (self.presentation_owned) {
            alloc.free(self.loop_name);
            alloc.free(self.funding);
        }
        self.presentation_owned = false;
        self.run_id = null;
        self.loop_name = "Loop";
        self.funding = "unknown";
        self.active = false;
        self.poll_id = 0;
        self.pending_id = 0;
    }
};
fn agentDriven(command: Command) bool {
    const driver = stringField(command.params, "driver") orelse return false;
    return eql(command.method, "run") and eql(driver, "agent");
}
/// `run ADDRESS` answered with the inspection: nothing was installed and no run exists.
fn unconfirmed(v: std.json.Value) bool {
    return eql(stringField(v, "status") orelse "", "confirmation_required");
}
/// What a successful answer to a runner-driven `run` or `retry` is: the acceptance of a
/// run to follow, a state to keep waiting on, or the last word.
const RunReply = enum { accepted, waiting, final };
fn runReply(v: std.json.Value, following: bool) RunReply {
    if (unconfirmed(v)) return .final;
    if (!following) return .accepted;
    return if (terminal(v)) .final else .waiting;
}
fn terminal(v: std.json.Value) bool {
    const s = stringField(v, "status") orelse return false;
    return eql(s, "completed") or eql(s, "failed") or eql(s, "stopped");
}
fn exitCode(v: std.json.Value, is_error: bool) u8 {
    if (bulk.isCancelled(v)) return 130;
    if (is_error) return 2;
    if (field(v, "ok")) |ok| if (ok == .bool and !ok.bool) return 2;
    // A submission that did not settle its step: rejected, not_ready or conflict.
    if (stringField(v, "answer")) |answer| if (!eql(answer, "accepted")) return 4;
    if (stringField(v, "status")) |s| {
        if (eql(s, "failed")) return 1;
        if (eql(s, "stopped")) {
            const stop = field(v, "stop") orelse return 3;
            const reason = stringField(stop, "reason") orelse return 3;
            return if (eql(reason, "cancelled")) 130 else 3;
        }
    }
    return 0;
}
test "fh bulk and preaccept cancellation exit with 130" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{\"code\":\"cancelled\"}",
        "{\"status\":\"stopped\",\"stop\":{\"reason\":\"cancelled\"}}",
        "{\"status\":\"stopped\",\"stop\":{\"reason\":\"usage_unavailable\",\"cause\":\"Cancelled\"}}",
    }) |bytes| {
        const value = try @import("loops/code.zig").parse(a, bytes, 1024);
        try std.testing.expectEqual(@as(u8, 130), exitCode(value, true));
        try std.testing.expectEqual(@as(u8, 130), exitCode(value, false));
    }
    try std.testing.expectEqual(@as(u8, 2), exitCode(try @import("loops/code.zig").parse(a, "{\"code\":\"invalid_input\"}", 1024), true));
}
fn modelUsageText(v: std.json.Value) ?[]const u8 {
    const count = field(v, "model_request_dispatches") orelse return null;
    if (count != .integer) return null;
    const complete = field(v, "model_request_dispatches_complete");
    if (complete == null or complete.? != .bool or !complete.?.bool) return "Model request count incomplete.";
    return if (count.integer == 0) "No model requests dispatched." else null;
}
fn emitValue(v: std.json.Value, json: bool, fd: c_int) !void {
    const text = try std.json.Stringify.valueAlloc(alloc, v, .{ .whitespace = if (json) .minified else .indent_2 });
    defer alloc.free(text);
    if (json) output(fd, text) else {
        const clean = try events.display(alloc, text);
        defer alloc.free(clean);
        output(fd, clean);
        if (modelUsageText(v)) |usage| {
            output(fd, "\n");
            output(fd, usage);
        }
    }
    output(fd, "\n");
}
fn directError(json: bool, code: []const u8, message: []const u8) void {
    if (json) {
        var detail = obj();
        defer detail.object.deinit(alloc);
        var envelope = obj();
        defer envelope.object.deinit(alloc);
        put(&detail, "code", str(code)) catch return;
        put(&detail, "message", str(message)) catch return;
        put(&envelope, "error", detail) catch return;
        emitValue(envelope, true, 1) catch {};
    }
    output(2, message);
    output(2, "\n");
}
pub fn direct(raw: []const [*:0]const u8) !?u8 {
    if (try @import("capture/cli.zig").direct(raw)) |code| return code;
    if (raw.len <= 1) return null;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    for (raw[1..]) |a| try argv.append(alloc, std.mem.span(a));
    var wants_json = false;
    for (argv.items) |a| if (eql(a, "--json")) {
        wants_json = true;
    };
    const command_value = parse(argv.items, false) catch {
        directError(wants_json, "invalid_invocation", "Invalid invocation. Use fh help.");
        return 2;
    };
    if (packageCommand(command_value.method)) return try packages(command_value);
    var command_value_admitted = command_value;
    if (command_value.params.object.contains("nextCommand")) {
        // run, batch or eval of a GitHub address: fetch it, show it and install it first, once.
        if (try admitAddress(&command_value_admitted)) |code| return code;
    }
    return try foreground(command_value_admitted);
}
fn foreground(command_value: Command) !?u8 {
    var guard = SigintGuard.install();
    defer guard.deinit();
    var client: Client = .{};
    defer client.deinit();
    const is_bulk = eql(command_value.method, "batch") or eql(command_value.method, "eval");
    var reply: bulk.Reply = undefined;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    if (is_bulk) {
        var refused: bulk.Refused = .{};
        var suite = bulk.loadReporting(alloc, io_mod.getIo(), stringField(command_value.params, "casesFile").?, eql(command_value.method, "eval"), &refused) catch |err| {
            if (err == error.CaseInputOutsideSuite) {
                const named = try events.display(alloc, refused.id());
                defer alloc.free(named);
                const message = try std.fmt.allocPrint(alloc, "Case {s}: input_file must be a relative path inside the directory that holds the cases file. Absolute paths and .. are not allowed.", .{named});
                defer alloc.free(message);
                directError(command_value.json, "invalid_cases", message);
                return 2;
            }
            directError(command_value.json, if (err == error.CasesLimit) "cases_limit" else "invalid_cases", "Cases must be bounded strict JSON with unique IDs, one input or input_file per case, and expect.pointer/value for eval.");
            return 2;
        };
        defer suite.deinit();
        var context: BulkCli = .{ .client = &client, .events = command_value.stream_events };
        defer context.forget();
        reply = bulk.execute(arena.allocator(), suite, stringField(command_value.params, "packagePath").?, stringField(command_value.params, "bindingsId") orelse "local", eql(command_value.method, "eval"), command_value.stream_events, .{ .context = &context, .callFn = BulkCli.call, .eventFn = if (command_value.stream_events) BulkCli.event else null, .cancelledFn = BulkCli.cancelled, .acceptedFn = BulkCli.acceptedRun }) catch |err| {
            directError(command_value.json, host_bridge.engine.errorCode(err), "Batch worker disconnected or report could not be saved. Inspect accepted run IDs before retrying.");
            return 1;
        };
    } else {
        reply = exchange(&client, command_value, arena.allocator(), null, null) catch |err| {
            directError(command_value.json, host_bridge.engine.errorCode(err), "Native foreground worker disconnected. Use fh runs --json to inspect accepted work.");
            return 1;
        };
    }
    if (command_value.stream_events) {
        var final = obj();
        try put(&final, if (reply.is_error) "error" else "result", reply.value);
        try emitValue(final, true, 1);
    } else if (reply.is_error) {
        var final = obj();
        try put(&final, "error", reply.value);
        try emitValue(final, command_value.json, if (command_value.json) 1 else 2);
    } else try emitValue(reply.value, command_value.json, 1);
    if (is_bulk and !reply.is_error and eql(stringField(reply.value, "stop_reason") orelse "", "worker_error")) output(2, "The batch worker failed part way. The report lists every case that ran, with its run ID and verdict. Inspect the last run with fh get before starting more work.\n");
    if (SigintGuard.requested()) return 130;
    if (is_bulk and !reply.is_error) {
        if (eql(stringField(reply.value, "status") orelse "", "stopped")) return if (eql(stringField(reply.value, "stop_reason") orelse "", "cancelled")) 130 else 3;
        const ok = field(reply.value, "ok");
        return if (ok != null and ok.? == .bool and ok.?.bool) 0 else 1;
    }
    return exitCode(reply.value, reply.is_error);
}
/// `add`, `list`, `remove` and `update` from the command line. They need no worker: the
/// only thing they could wait for is the person, who is asked here.
fn packages(command_value: Command) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = io_mod.getIo();
    const method = command_value.method;
    const home = io_mod.getenv("HOME") orelse {
        directError(command_value.json, "invalid_profile", "HOME is not set, so fh cannot find its profile.");
        return 2;
    };
    var root = try paths.openCredentialRoot(home, true);
    root.close();
    const profile = try paths.rootDir(a, home);
    const adding = eql(method, "add") or eql(method, "update");
    const yes = if (field(command_value.params, "yes")) |value| value == .bool and value.bool else false;
    // The question is asked only of a person at a terminal who wants text.
    const asking = adding and !yes and !command_value.json and std.c.isatty(0) != 0 and std.c.isatty(1) != 0;
    // An interrupt stops git, and the fetch then cleans up after itself.
    var guard = SigintGuard.install();
    defer guard.deinit();
    var note: ?[]const u8 = null;
    const result = (if (asking) confirmed(a, io, profile, command_value, &note) else installed.command(a, io, profile, method, command_value.params, .{}, &note)) catch |err| {
        const code = installed.errorCode(err) orelse host_bridge.engine.errorCode(err);
        const message = note orelse installed.explain(err) orelse try std.fmt.allocPrint(a, "fh {s} failed ({s}). Nothing was changed.", .{ method, @errorName(err) });
        if (SigintGuard.requested()) return 130;
        // git's own words are passed on, and may not be text.
        directError(command_value.json, code, events.display(a, message) catch try std.fmt.allocPrint(a, "fh {s} failed ({s}). Nothing was changed.", .{ method, @errorName(err) }));
        return if (installed.errorCode(err) != null or installed.explain(err) != null) 2 else 1;
    };
    const status = stringField(result, "status") orelse "";
    if (SigintGuard.requested() and eql(status, "declined")) return 130;
    if (command_value.json) try emitValue(result, true, 1) else {
        const files_missing = if (field(result, "files_missing")) |value| value == .bool and value.bool else false;
        const text = if (eql(method, "list")) try installed.describeList(a, result) else if (eql(method, "remove")) try std.fmt.allocPrint(a, "Removed {s} {s}.{s}\n", .{ stringField(result, "name").?, stringField(result, "version").?, if (files_missing) " Its files were already missing from the profile, so only its lock entry was removed." else "" }) else try std.fmt.allocPrint(a, "{s}{s}", .{ if (asking and !eql(status, "unchanged")) "" else try installed.describe(a, result), try outcome(a, result, eql(method, "update")) });
        output(1, try events.display(a, text));
    }
    if (eql(status, "confirmation_required")) {
        // The digest ties the install to what was just shown: if the source changes first, it is refused.
        output(2, try events.display(a, try std.fmt.allocPrint(a, "Nothing was installed. To install exactly what is shown above, run:\n  {s}\n", .{stringField(result, "next_command").?})));
        return 2;
    }
    return if (eql(status, "declined")) 1 else 0;
}
/// `fh run ADDRESS`, and `batch` and `eval` of one, before anything runs: fetch the
/// package, show what it holds, and install it once the person agrees or the command
/// carries the digest that was inspected. On success the command is rewritten to name the
/// installed NAME@VERSION and null is returned. Otherwise the exit code.
fn admitAddress(command_value: *Command) !?u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = io_mod.getIo();
    const params = command_value.params;
    const quiet = command_value.json or command_value.stream_events;
    const home = io_mod.getenv("HOME") orelse {
        directError(quiet, "invalid_profile", "HOME is not set, so fh cannot find its profile.");
        return 2;
    };
    var root = try paths.openCredentialRoot(home, true);
    root.close();
    const profile = try paths.rootDir(a, home);
    const attended = std.c.isatty(0) != 0 and std.c.isatty(1) != 0;
    var request: installed.RunRequest = .{ .argument = stringField(params, "packagePath").?, .digest = stringField(params, "digest"), .digest_required = !attended, .next = stringField(params, "nextCommand") };
    if (field(params, "yes")) |value| request.yes = value == .bool and value.bool;
    // The question is asked only of a person at a terminal who wants text.
    var question: Question = .{};
    if (attended and !quiet and !request.yes) request.ask = .{ .context = &question, .askFn = Question.ask };
    var guard = SigintGuard.install();
    defer guard.deinit();
    var note: ?[]const u8 = null;
    const result = installed.admit(a, io, profile, request, .{}, &note) catch |err| {
        const code = installed.errorCode(err) orelse host_bridge.engine.errorCode(err);
        const message = note orelse installed.explain(err) orelse try std.fmt.allocPrint(a, "fh {s} could not fetch the package ({s}). Nothing was installed or run.", .{ command_value.method, @errorName(err) });
        if (SigintGuard.requested()) return 130;
        directError(quiet, code, events.display(a, message) catch try std.fmt.allocPrint(a, "fh {s} could not fetch the package ({s}). Nothing was installed or run.", .{ command_value.method, @errorName(err) }));
        return if (installed.errorCode(err) != null or installed.explain(err) != null) 2 else 1;
    };
    const status = stringField(result, "status").?;
    if (eql(status, "declined")) {
        output(1, "Nothing was installed or run.\n");
        return if (SigintGuard.requested()) 130 else 1;
    }
    if (eql(status, "confirmation_required")) {
        if (quiet) try emitValue(result, true, 1) else output(1, try events.display(a, try installed.describe(a, result)));
        // The digest ties the install to what was just shown: if the source changes first, it is refused.
        output(2, try events.display(a, try std.fmt.allocPrint(a, "Nothing was installed or run. To install and run exactly what is shown above, run:\n  {s}\n", .{stringField(result, "next_command").?})));
        return 2;
    }
    // Installed, already installed with this content, or this very source installed before.
    // A JSON caller gets one final result on standard output, so what happened goes beside it.
    if (!eql(status, "ready")) {
        const happened = try std.fmt.allocPrint(a, "{s}{s} {s} {s}. Running it.\n", .{ if (question.asked or quiet) "" else try installed.describe(a, result), if (eql(status, "installed")) "Installed" else "Already installed with the same content:", stringField(result, "name").?, stringField(result, "version").? });
        output(if (quiet) 2 else 1, try events.display(a, happened));
    }
    try put(&command_value.params, "packagePath", str(try alloc.dupe(u8, stringField(result, "package").?)));
    for ([_][]const u8{ "yes", "digest", "nextCommand", "chat" }) |key| _ = command_value.params.object.orderedRemove(key);
    return null;
}
const Question = struct {
    asked: bool = false,
    /// Shows what was fetched and asks whether to install and run exactly that.
    fn ask(raw: *anyopaque, a: std.mem.Allocator, inspection: std.json.Value) anyerror!bool {
        const self: *Question = @ptrCast(@alignCast(raw));
        self.asked = true;
        output(1, try events.display(a, try installed.describe(a, inspection)));
        return saidYes(a, try std.fmt.allocPrint(a, "Install and run {s} {s}? [y/N] ", .{ stringField(inspection, "name").?, stringField(inspection, "version").? }));
    }
};
/// Asks a yes or no question on the terminal. Anything but y or yes is no.
fn saidYes(a: std.mem.Allocator, question: []const u8) !bool {
    output(2, try events.display(a, question));
    var line: std.ArrayList(u8) = .empty;
    while (true) {
        var byte: [1]u8 = undefined;
        if (std.c.read(0, &byte, 1) <= 0 or byte[0] == '\n' or byte[0] == '\r') break;
        try line.append(a, byte[0]);
    }
    const reply = std.mem.trim(u8, line.items, " \t");
    return std.ascii.eqlIgnoreCase(reply, "y") or std.ascii.eqlIgnoreCase(reply, "yes");
}
fn outcome(a: std.mem.Allocator, result: std.json.Value, updating: bool) ![]const u8 {
    const status = stringField(result, "status").?;
    const name = stringField(result, "name").?;
    const version_text = stringField(result, "version").?;
    if (eql(status, "installed")) return std.fmt.allocPrint(a, "Installed {s} {s}. Run it with fh run {s}.\n", .{ name, version_text, name });
    if (eql(status, "unchanged")) return std.fmt.allocPrint(a, "{s} {s} is {s}. Nothing was changed.\n", .{ name, version_text, if (updating) "up to date" else "already installed with the same content" });
    return if (eql(status, "declined")) "Nothing was installed.\n" else "";
}
/// Fetch once, show what was fetched, ask, and install exactly that.
fn confirmed(a: std.mem.Allocator, io: std.Io, profile: []const u8, command_value: Command, note: *?[]const u8) !std.json.Value {
    const updating = eql(command_value.method, "update");
    var staged = if (updating) try installed.stageUpdate(a, a, io, profile, stringField(command_value.params, "package").?, .{}, note) else try installed.stage(a, a, io, profile, stringField(command_value.params, "source").?, .{}, note);
    defer staged.deinit();
    if (stringField(command_value.params, "digest")) |digest| try installed.expectDigest(a, &staged, digest, note);
    if (try installed.plan(a, io, profile, &staged, note) == .unchanged) return installed.answer(a, &staged, "unchanged");
    output(1, try events.display(a, try installed.describe(a, try installed.inspect(a, &staged))));
    if (!try saidYes(a, try std.fmt.allocPrint(a, "Install {s} {s}? [y/N] ", .{ staged.name(), staged.version() }))) return installed.answer(a, &staged, "declined");
    return installed.answer(a, &staged, if (try installed.commit(a, io, profile, &staged, note) == .install) "installed" else "unchanged");
}
fn attributed(value: std.json.Value, event_name: []const u8, context: ?std.json.Value) !void {
    if (context) |metadata| {
        var envelope = obj();
        defer envelope.object.deinit(alloc);
        try put(&envelope, "event", str(event_name));
        if (field(metadata, "caseId")) |id| try put(&envelope, "case_id", id);
        if (field(metadata, "inputSource")) |source| try put(&envelope, "input_source", source);
        try put(&envelope, "run", value);
        try emitValue(envelope, true, 1);
    } else try emitValue(value, true, 1);
}
/// `accepted` receives the run ID as soon as the worker accepts the run, so a caller still
/// knows which run was in flight if the exchange then fails.
fn exchange(client: *Client, command_value: Command, target: std.mem.Allocator, stream_context: ?std.json.Value, accepted: ?*?[]u8) !bulk.Reply {
    try client.command(command_value);
    defer client.finishCommand();
    var accepted_run = false;
    var cancelled = false;
    var last_get: i64 = 0;
    while (true) {
        if (SigintGuard.requested() and !cancelled) {
            cancelled = true;
            _ = client.cancel();
        }
        var decoded = (try client.next()) orelse {
            std.Io.sleep(io_mod.getIo(), .fromMilliseconds(5), .awake) catch {};
            if (accepted_run and io_mod.milliTimestamp() - last_get > 100) {
                try client.get();
                last_get = io_mod.milliTimestamp();
            }
            continue;
        };
        defer decoded.deinit();
        if (decoded.message == .event) {
            if (command_value.stream_events and accepted_run) try attributed(decoded.json.value, "run_progress", stream_context);
            continue;
        }
        const response = decoded.message.response;
        if (response.id != client.pending_id) continue;
        const value = response.value;
        if ((eql(command_value.method, "run") or eql(command_value.method, "retry")) and !response.is_error and !client.driven) switch (runReply(value, accepted_run)) {
            .final => {},
            .waiting => continue,
            .accepted => {
                try client.acceptRun(value);
                accepted_run = true;
                if (accepted) |slot| slot.* = try alloc.dupe(u8, client.run_id.?);
                if (command_value.stream_events) try attributed(value, "run_accepted", stream_context);
                try client.get();
                last_get = io_mod.milliTimestamp();
                continue;
            },
        };
        const bytes = try std.json.Stringify.valueAlloc(target, value, .{});
        defer target.free(bytes);
        return .{ .value = try @import("loops/code.zig").parse(target, bytes, bulk.max_report_bytes), .is_error = response.is_error };
    }
}
const BulkCli = struct {
    client: *Client,
    events: bool,
    accepted: ?[]u8 = null,
    fn cast(raw: *anyopaque) *BulkCli {
        return @ptrCast(@alignCast(raw));
    }
    fn forget(self: *BulkCli) void {
        if (self.accepted) |id| alloc.free(id);
        self.accepted = null;
    }
    fn call(raw: *anyopaque, a: std.mem.Allocator, method: []const u8, params: std.json.Value) !bulk.Reply {
        const self = cast(raw);
        self.forget();
        return exchange(self.client, .{ .method = method, .params = params, .stream_events = self.events and eql(method, "run") }, a, if (eql(method, "run")) params else null, &self.accepted);
    }
    fn acceptedRun(raw: *anyopaque) ?[]const u8 {
        return cast(raw).accepted;
    }
    fn event(_: *anyopaque, value: std.json.Value) !void {
        try emitValue(value, true, 1);
    }
    fn cancelled(_: *anyopaque) bool {
        return SigintGuard.requested();
    }
};

pub fn submit(app: anytype, command_text: []const u8, now_ms: i64) !bool {
    const text = std.mem.trim(u8, command_text, " \t\r\n");
    if (eql(text, "/help")) {
        try app.writeDomainNotice(.{ .topic = "loops", .body = help, .tone = .neutral }, true);
        return true;
    }
    if (eql(text, "/version")) {
        try app.writeDomainNotice(.{ .topic = "loops", .body = "fh " ++ version, .tone = .neutral }, true);
        return true;
    }
    if (eql(text, "/clear") or eql(text, "/quit") or eql(text, "/exit")) return false;
    if (!std.mem.startsWith(u8, text, "/")) return false;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    var words = std.mem.tokenizeAny(u8, text[1..], " \t");
    while (words.next()) |word| try args.append(alloc, word);
    if (args.items.len == 0) return false;
    var domain_command = false;
    for (commands) |name| if (eql(args.items[0], name)) {
        domain_command = true;
    };
    if (!domain_command) return false;
    const cmd = parse(args.items, true) catch {
        try app.writeDomainNotice(.{ .topic = "loops", .body = "Invalid command. Use /help; paths containing spaces can be supplied through the direct CLI.", .tone = .@"error" }, true);
        return true;
    };
    if (eql(cmd.method, "cancel") and app.loops.active) {
        app.loops.cancelTarget(stringField(cmd.params, "runId").?) catch |err| {
            try app.writeDomainNotice(.{ .topic = "cancel", .body = @errorName(err), .tone = .@"error" }, true);
        };
        return true;
    }
    if (!eql(cmd.method, "get") and !eql(cmd.method, "cancel") and (app.worker.isProcessing() or app.worker.queuedPromptCount() != 0 or app.submission.pending != null)) {
        try app.writeDomainNotice(.{ .topic = "loops", .body = "A conversation is in progress. Cancel or finish it before starting another operation.", .tone = .@"error" }, true);
        return true;
    }
    app.loops.command(cmd) catch |err| {
        try app.writeDomainNotice(.{ .topic = "loops", .body = @errorName(err), .tone = .@"error" }, true);
        return true;
    };
    const clean = try events.display(alloc, text);
    defer alloc.free(clean);
    try app.writeUserPromptCardWithSpacing(.{ .text = @constCast(clean) }, app.loops_has_run);
    app.loops_has_run = true;
    app.stream = .{ .active = true, .phase = .running, .turn_started_ms = now_ms };
    app.shell.worker_status.set_api("Loops", .neutral);
    app.shell.render_requests.request(.footer);
    return true;
}
pub fn advance(app: anytype, now_ms: i64) !void {
    if (app.loops.bridge.closed) return;
    if (app.loops.active and app.loops.run_id != null and now_ms - app.loops.last_get > 250) {
        try app.loops.get();
        app.loops.last_get = now_ms;
    }
    var decoded = (app.loops.next() catch |err| {
        app.loops.active = false;
        app.stream = .{};
        _ = app.shell.worker_status.clear();
        try app.writeDomainNotice(.{ .topic = "loops", .body = @errorName(err), .tone = .@"error" }, true);
        app.loops.bridge.shutdown();
        return;
    }) orelse return;
    defer decoded.deinit();
    if (decoded.message == .event) {
        const e = decoded.message.event;
        if (app.loops.run_id) |id| {
            if (!eql(id, e.run_id) or e.sequence <= app.loops.sequence) return;
        } else return;
        app.loops.sequence = e.sequence;
        if (e.kind == .step_started) {
            const label = try std.fmt.allocPrint(alloc, "{s} | {s} | iteration {d} | {s}", .{ app.loops.loop_name, e.step_id.?, e.iteration.?, app.loops.funding });
            defer alloc.free(label);
            const clean = try events.display(alloc, label);
            defer alloc.free(clean);
            app.shell.worker_status.set_api(clean, .neutral);
            app.stream.chunks += 1;
        }
        const notice = if (e.step_id) |step_id|
            try std.fmt.allocPrint(alloc, "Step {s} {s} · iteration {d}", .{ step_id, if (e.kind == .step_started) "started" else "completed", e.iteration.? })
        else
            try std.fmt.allocPrint(alloc, "Run {s} {s}", .{ e.run_id, if (e.kind == .run_started) "started" else "finished" });
        defer alloc.free(notice);
        const clean_notice = try events.display(alloc, notice);
        defer alloc.free(clean_notice);
        try app.writeDomainNotice(.{ .topic = "loops", .body = clean_notice, .tone = .neutral }, true);
        if (e.kind == .run_finished) try app.loops.get();
    } else {
        const r = decoded.message.response;
        if (app.loops.takeExplicitCancel(r.id)) {
            const body = try std.json.Stringify.valueAlloc(alloc, r.value, .{});
            defer alloc.free(body);
            const clean = try events.display(alloc, body);
            defer alloc.free(clean);
            try app.writeDomainNotice(.{ .topic = "cancel", .body = clean, .tone = if (r.is_error) .@"error" else .neutral }, true);
            app.shell.render_requests.request(.transcript);
            return;
        }
        if (r.id != app.loops.pending_id) return;
        if (!r.is_error and eql(app.loops.method, "status")) {
            if (field(r.value, "inference")) |inference| app.loops.setInferenceDisplay(try displaySettings(inference));
        }
        const reply: RunReply = if (!r.is_error and (eql(app.loops.method, "run") or eql(app.loops.method, "retry")) and !app.loops.driven) runReply(r.value, app.loops.run_id != null) else .final;
        if (reply == .accepted) {
            try app.loops.acceptRun(r.value);
            const body = try std.fmt.allocPrint(alloc, "Loop {s} accepted · funding {s}\nRun {s}", .{ app.loops.loop_name, app.loops.funding, app.loops.run_id.? });
            defer alloc.free(body);
            const clean = try events.display(alloc, body);
            defer alloc.free(clean);
            try app.writeDomainNotice(.{ .topic = "loops", .body = clean, .tone = .neutral }, true);
            if (app.loops.cancel_requested) _ = app.loops.cancel();
            return;
        }
        if (reply == .waiting) return;
        const encoded_body = try std.json.Stringify.valueAlloc(alloc, r.value, .{ .whitespace = .indent_2 });
        defer alloc.free(encoded_body);
        const body = if (modelUsageText(r.value)) |usage| try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ encoded_body, usage }) else try alloc.dupe(u8, encoded_body);
        defer alloc.free(body);
        const clean = try events.display(alloc, body);
        defer alloc.free(clean);
        try app.writeDomainNotice(.{ .topic = "loops", .body = clean, .tone = if (r.is_error) .@"error" else .neutral }, true);
        app.loops.active = false;
        app.stream = .{};
        _ = app.shell.worker_status.clear();
    }
    app.shell.render_requests.request(.transcript);
    app.shell.render_requests.request(.footer);
}
var interrupted = std.atomic.Value(bool).init(false);
fn handler(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .seq_cst);
}
pub const SigintGuard = struct {
    previous: [4]std.posix.Sigaction,
    const signals = [_]std.posix.SIG{ .INT, .TERM, .HUP, .PIPE };
    pub fn install() SigintGuard {
        interrupted.store(false, .seq_cst);
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = std.posix.sigemptyset(), .flags = 0 };
        var guard: SigintGuard = undefined;
        for (signals, 0..) |signal, i| std.posix.sigaction(signal, &action, &guard.previous[i]);
        return guard;
    }
    pub fn requested() bool {
        return interrupted.load(.seq_cst);
    }
    pub fn deinit(self: *SigintGuard) void {
        for (signals, 0..) |signal, i| std.posix.sigaction(signal, &self.previous[i], null);
    }
};

test "fh next and submit parse a run, a path, a pass and one output; run takes a driver" {
    const next = try parse(&.{ "next", "run_1", "--json" }, false);
    try std.testing.expectEqualStrings("run_1", stringField(next.params, "runId").?);
    try std.testing.expect(next.json);
    const submitted = try parse(&.{ "submit", "run_1", "--path", "pair/b/b1", "--pass", "2", "--output", "/tmp/out.json" }, false);
    try std.testing.expectEqualStrings("pair/b/b1", stringField(submitted.params, "path").?);
    try std.testing.expectEqual(@as(i64, 2), field(submitted.params, "pass").?.integer);
    try std.testing.expectEqualStrings("/tmp/out.json", stringField(submitted.params, "outputFile").?);
    try std.testing.expect(!agentDriven(submitted));
    const driven = try parse(&.{ "run", "/tmp/package", "--driver", "agent" }, false);
    try std.testing.expect(agentDriven(driven));
    try std.testing.expect(!agentDriven(try parse(&.{ "run", "/tmp/package" }, false)));
    for ([_][]const []const u8{
        &.{"next"},
        &.{ "next", "run_1", "run_2" },
        &.{ "next", "run_1", "--path", "draft" },
        &.{ "submit", "run_1", "--path", "draft", "--pass", "0" },
        &.{ "submit", "run_1", "--pass", "0", "--output", "/tmp/out.json" },
        &.{ "submit", "run_1", "--path", "draft", "--output", "/tmp/out.json" },
        &.{ "submit", "run_1", "--path", "draft", "--pass", "-1", "--output", "/tmp/out.json" },
        &.{ "submit", "run_1", "--path", "draft", "--pass", "0", "--output", "-" },
        &.{ "run", "/tmp/package", "--driver", "robot" },
        &.{ "get", "run_1", "--driver", "agent" },
    }) |invalid| try std.testing.expectError(error.Usage, parse(invalid, true));
    // Only an accepted submission exits 0.
    var answer = obj();
    try put(&answer, "status", str("running"));
    try put(&answer, "answer", str("rejected"));
    try std.testing.expectEqual(@as(u8, 4), exitCode(answer, false));
    try put(&answer, "answer", str("accepted"));
    try std.testing.expectEqual(@as(u8, 0), exitCode(answer, false));
    try std.testing.expect(std.mem.indexOf(u8, help, "submit RUN --path PATH --pass N --output FILE|-") != null);
    // Busy is an error, not an answer: it exits 2 and is worth a retry, and the help says so.
    var busy = obj();
    try put(&busy, "code", str("owner_busy"));
    try std.testing.expectEqual(@as(u8, 2), exitCode(busy, true));
    try std.testing.expect(std.mem.indexOf(u8, help, "exits 0 when accepted, 4 for any other answer, and 2 for an error") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "owner_busy") != null);
    try std.testing.expect(std.mem.indexOf(u8, help[std.mem.indexOf(u8, help, "Agent driver").?..], "\u{2014}") == null);
}

test "fh settle takes a run and exactly one outcome, and help names it" {
    const applied = try parse(&.{ "settle", "run_1", "--applied", "--json" }, false);
    try std.testing.expectEqualStrings("settle", applied.method);
    try std.testing.expectEqualStrings("run_1", stringField(applied.params, "runId").?);
    try std.testing.expectEqualStrings("applied", stringField(applied.params, "outcome").?);
    try std.testing.expect(applied.json);
    const refused = try parse(&.{ "settle", "run_1", "--not-applied", "--effect", "workspace-command:publish:0" }, false);
    try std.testing.expectEqualStrings("not_applied", stringField(refused.params, "outcome").?);
    try std.testing.expectEqualStrings("workspace-command:publish:0", stringField(refused.params, "effect").?);
    for ([_][]const []const u8{
        &.{ "settle", "run_1" },
        &.{ "settle", "--applied" },
        &.{ "settle", "run_1", "--applied", "--not-applied" },
        &.{ "settle", "run_1", "--applied", "--applied" },
        &.{ "settle", "run_1", "--applied", "--events" },
        &.{ "get", "run_1", "--applied" },
        &.{ "run", "/tmp/package", "--not-applied" },
    }) |invalid| try std.testing.expectError(error.Usage, parse(invalid, false));
    try std.testing.expect(std.mem.indexOf(u8, help, "settle RUN --applied|--not-applied") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "fh setup workspace GRANT.json [--trust-host]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help["fh 0.3.1 ".len + 3 ..], "\u{2014}") == null);
}

test "fh package commands parse a source, a name and --yes, and a PACKAGE that is not a path stays a name" {
    const add = try parse(&.{ "add", "acme/loops/tools/triage@v2", "--yes", "--json" }, false);
    try std.testing.expectEqualStrings("add", add.method);
    try std.testing.expectEqualStrings("acme/loops/tools/triage@v2", stringField(add.params, "source").?);
    try std.testing.expect(field(add.params, "yes").?.bool and add.json);
    try std.testing.expect(field((try parse(&.{ "add", "./folder" }, false)).params, "yes") == null);
    try std.testing.expectEqualStrings("triage@2", stringField((try parse(&.{ "remove", "triage@2" }, false)).params, "package").?);
    try std.testing.expectEqualStrings("triage", stringField((try parse(&.{ "update", "triage", "--yes" }, true)).params, "package").?);
    try std.testing.expectEqualStrings("list", (try parse(&.{ "list", "--json" }, false)).method);
    for ([_][]const u8{ "add", "list", "remove", "update" }) |method| try std.testing.expect(packageCommand(method));
    try std.testing.expect(!packageCommand("run"));
    for ([_][]const []const u8{
        &.{"add"},
        &.{ "add", "a/b", "c/d" },
        &.{ "add", "a/b", "--token", "secret" },
        &.{ "add", "a/b", "--bindings-id", "local" },
        &.{ "list", "triage" },
        &.{ "list", "--yes" },
        &.{"remove"},
        &.{ "remove", "triage", "--yes" },
        &.{"update"},
        &.{ "update", "triage", "--events" },
    }) |invalid| try std.testing.expectError(error.Usage, parse(invalid, false));
    // One rule decides what a PACKAGE argument is, for every command that takes one.
    for ([_][]const u8{ "check", "run", "batch", "eval" }) |method| {
        const cases: []const []const u8 = if (eql(method, "batch") or eql(method, "eval")) &.{ "--cases", "/tmp/cases.json" } else &.{};
        const named = try parse(try std.mem.concat(alloc, []const u8, &.{ &.{ method, "triage@2" }, cases }), false);
        try std.testing.expectEqualStrings("triage@2", stringField(named.params, "packagePath").?);
        const bare = try parse(try std.mem.concat(alloc, []const u8, &.{ &.{ method, "no-such-folder-here" }, cases }), false);
        try std.testing.expectEqualStrings("no-such-folder-here", stringField(bare.params, "packagePath").?);
        // A folder named loops is in the checkout the tests run from. Bare, it is still a name.
        try std.testing.expectEqualStrings("loops", stringField((try parse(try std.mem.concat(alloc, []const u8, &.{ &.{ method, "loops" }, cases }), false)).params, "packagePath").?);
        for ([_][]const u8{ "./triage", "../triage", "./nested/triage", "/tmp/triage", ".triage" }) |path| {
            const pathed = try parse(try std.mem.concat(alloc, []const u8, &.{ &.{ method, path }, cases }), false);
            try std.testing.expect(std.fs.path.isAbsolute(stringField(pathed.params, "packagePath").?));
        }
        // Anything else is a GitHub address. It travels as typed and is never made a path,
        // whatever is in the current directory: loops/warm-context is a folder in this checkout.
        for ([_][]const u8{ "nested/triage", "acme/loops", "acme/loops/tools/triage@v2", "acme/loops@feat/next", "loops/warm-context", "acme/loops/" }) |address| {
            const addressed = try parse(try std.mem.concat(alloc, []const u8, &.{ &.{ method, address }, cases }), false);
            try std.testing.expectEqualStrings(address, stringField(addressed.params, "packagePath").?);
        }
    }
    for ([_][]const u8{ "fh add SOURCE [--yes] [--digest HEX] | list | remove NAME[@VERSION] | update NAME [--yes] [--digest HEX]", "OWNER/REPO[/PATH][@REF]", "PACKAGE is read by one rule, from its text alone, whatever is in the current directory: text that starts with . or / is a path on this machine; text with no / is an installed NAME or NAME@VERSION; anything else is a GitHub address OWNER/REPO[/PATH][@REF].", "write ./NAME", "fh run OWNER/REPO/PATH[@REF] [--yes] [--digest HEX]", "Install and run NAME VERSION? [y/N]", "/run ADDRESS --yes --digest HEX", "fh takes no token", "docs/packages.md", "/add SOURCE --yes --digest HEX" }) |line| try std.testing.expect(std.mem.indexOf(u8, help, line) != null);
    // --digest ties an install to the package that was inspected.
    const hex = "0123456789abcdef" ** 4;
    const pinned = try parse(&.{ "add", "./folder", "--yes", "--digest", hex }, false);
    try std.testing.expectEqualStrings(hex, stringField(pinned.params, "digest").?);
    try std.testing.expect(field(pinned.params, "chat") == null);
    try std.testing.expectEqualStrings(hex, stringField((try parse(&.{ "update", "triage", "--digest", hex, "--yes" }, false)).params, "digest").?);
    // Chat marks its requests, so the worker can insist on the digest there.
    try std.testing.expect(field((try parse(&.{ "add", "./folder" }, true)).params, "chat").?.bool);
    try std.testing.expect(field((try parse(&.{ "update", "triage" }, true)).params, "chat").?.bool);
    try std.testing.expect(field((try parse(&.{ "remove", "triage" }, true)).params, "chat") == null);
    for ([_][]const []const u8{
        &.{ "add", "./folder", "--digest" },
        &.{ "add", "./folder", "--digest", hex, "--digest", hex },
        &.{ "remove", "triage", "--digest", hex },
        &.{ "list", "--digest", hex },
        &.{ "run", "triage", "--digest", hex },
    }) |invalid| try std.testing.expectError(error.Usage, parse(invalid, false));
    try std.testing.expect(std.mem.indexOf(u8, help["fh 0.3.1 ".len + 3 ..], "\u{2014}") == null);
    var result = obj();
    try put(&result, "status", str("installed"));
    try put(&result, "name", str("triage"));
    try put(&result, "version", str("2"));
    try std.testing.expectEqualStrings("Installed triage 2. Run it with fh run triage.\n", try outcome(alloc, result, false));
    try put(&result, "status", str("unchanged"));
    try std.testing.expectEqualStrings("triage 2 is up to date. Nothing was changed.\n", try outcome(alloc, result, true));
    try std.testing.expectEqualStrings("triage 2 is already installed with the same content. Nothing was changed.\n", try outcome(alloc, result, false));
}

fn workerReply(client: *Client, args: []const []const u8, failed: bool, key: []const u8, contains: []const u8) !void {
    const sent = try parse(args, true);
    const id = try client.send(sent.method, sent.params);
    var waited: usize = 0;
    while (waited < 15000) : (waited += 1) {
        var decoded = (try client.next()) orelse {
            std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake) catch {};
            continue;
        };
        defer decoded.deinit();
        if (decoded.message != .response or decoded.message.response.id != id) continue;
        try std.testing.expectEqual(failed, decoded.message.response.is_error);
        const text = stringField(decoded.message.response.value, key) orelse return error.TestUnexpectedResult;
        if (std.mem.indexOf(u8, text, contains) == null) {
            std.debug.print("expected {s} to contain {s}, found {s}\n", .{ key, contains, text });
            return error.TestUnexpectedResult;
        }
        return;
    }
    return error.TestUnexpectedResult;
}
test "fh run and check of a bare name send the name, never a local folder of that name" {
    // The tests run from the checkout, where ./loops, ./docs and ./build.zig exist.
    for ([_][]const u8{ "run", "check" }) |method| {
        for ([_][]const u8{ "loops", "docs", "build.zig", "loops@3" }) |name| {
            const named = try parse(&.{ method, name, "--json" }, false);
            try std.testing.expectEqualStrings(name, stringField(named.params, "packagePath").?);
            try std.testing.expectEqual(@as(usize, 1), named.params.object.count());
        }
        const local = try parse(&.{ method, "./loops" }, false);
        try std.testing.expect(std.fs.path.isAbsolute(stringField(local.params, "packagePath").?));
        try std.testing.expect(std.mem.endsWith(u8, stringField(local.params, "packagePath").?, "/loops"));
        // Chat follows the same rule.
        try std.testing.expectEqualStrings("loops", stringField((try parse(&.{ method, "loops" }, true)).params, "packagePath").?);
    }
    for ([_][]const u8{ "fh used the local folder", "exists as a path" }) |gone| try std.testing.expect(std.mem.indexOf(u8, help, gone) == null);
}
test "fh docs_read maps every advertised document to a bundled file, and parallel_schema is the loops/0.3 schema" {
    const curated = @import("../vendor/fx/src/core/tooling/fh_loop_tools.zig");
    const advertised = curated.set.registry.lookup("docs_read").?.model_schema.input_schema.properties[0].shape.?.enum_values;
    try std.testing.expectEqual(@as(usize, 10), advertised.len);
    try std.testing.expectEqualStrings("lib/packages/loops-contract/loop-0.3.schema.json", host_bridge.documentPath("parallel_schema").?);
    try std.testing.expectEqualStrings("lib/packages/loops-contract/loop-0.2.schema.json", host_bridge.documentPath("decision_schema").?);
    try std.testing.expectEqualStrings("lib/packages/loops-contract/loop-0.4.schema.json", host_bridge.documentPath("runtime_schema").?);
    try std.testing.expectEqualStrings("docs/code-runtimes.md", host_bridge.documentPath("runtime_guide").?);
    try std.testing.expect(host_bridge.documentPath("loop-0.3.schema.json") == null);
    try std.testing.expect(host_bridge.documentPath("../secrets") == null);
    for (advertised) |document| {
        // The bundle installs packages/ under lib/; every other document keeps its checkout path.
        const bundled = host_bridge.documentPath(document) orelse return error.TestUnexpectedResult;
        const source = if (std.mem.startsWith(u8, bundled, "lib/")) bundled["lib/".len..] else bundled;
        const stat = try std.Io.Dir.cwd().statFile(std.testing.io, source, .{});
        try std.testing.expect(stat.kind == .file and stat.size > 0);
    }
    const schema_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "packages/loops-contract/loop-0.3.schema.json", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(schema_bytes);
    try std.testing.expect(std.mem.indexOf(u8, schema_bytes, "loops/0.3") != null);
}
test "fh chat package commands reach the worker: /add inspects, /add --yes --digest installs what was inspected, a changed package is refused by name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    try tmp.dir.createDir(io, "source", .fromMode(0o700));
    try tmp.dir.writeFile(io, .{ .sub_path = "source/loop.json", .data = "{\"format\":\"loops/0.1\",\"name\":\"chatted\",\"version\":\"3\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"one\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"one.py\",\"input\":{},\"output\":{\"schema\":true}}],\"output\":{\"value\":null}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "source/one.py", .data = "print(1)\n" });
    var buffer: [4096]u8 = undefined;
    const profile = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const source = try std.fs.path.join(alloc, &.{ profile, "source" });
    defer alloc.free(source);
    var client: Client = .{};
    defer client.deinit();
    try client.bridge.configure(.{ .io = io, .profile = profile });
    const inspected = try @import("loops/package.zig").load(alloc, io, source);
    defer inspected.deinit();
    try workerReply(&client, &.{ "add", source }, false, "status", "confirmation_required");
    try workerReply(&client, &.{ "add", source }, false, "next_command", try std.fmt.allocPrint(alloc, "/add {s} --yes --digest {s}", .{ source, inspected.digest }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "packages.lock.json", .{}));
    // Chat cannot ask, so --yes there needs the digest that was inspected.
    try workerReply(&client, &.{ "add", source, "--yes" }, true, "code", "digest_required");
    try workerReply(&client, &.{ "add", source, "--yes" }, true, "message", "--digest");
    try workerReply(&client, &.{ "add", source, "--yes", "--digest", "0123456789abcdef" ** 4 }, true, "code", "package_digest_mismatch");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "packages.lock.json", .{}));
    try workerReply(&client, &.{ "add", source, "--yes", "--digest", inspected.digest }, false, "status", "installed");
    try workerReply(&client, &.{ "add", source, "--yes", "--digest", inspected.digest }, false, "status", "unchanged");
    try workerReply(&client, &.{ "update", "chatted" }, false, "status", "unchanged");
    try workerReply(&client, &.{ "add", "not-an-address" }, true, "message", "write ./not-an-address");
    try tmp.dir.setFilePermissions(io, "packages/chatted/3/one.py", .fromMode(0o600), .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "packages/chatted/3/one.py", .data = "print(2)\n" });
    try workerReply(&client, &.{ "check", "chatted" }, true, "message", "The installed files for chatted@3 do not match what was installed");
    try workerReply(&client, &.{ "run", "chatted@3" }, true, "code", "installed_package_changed");
    try workerReply(&client, &.{ "remove", "chatted" }, false, "status", "removed");
    try workerReply(&client, &.{ "check", "chatted" }, true, "code", "package_not_installed");
}

test "fh run, batch and eval of a GitHub address take --yes and --digest and carry the command to run next; a name or a path does not" {
    const hex = "0123456789abcdef" ** 4;
    const run = try parse(&.{ "run", "acme/loops/tools/triage@v2", "--input", "/tmp/in put.json", "--driver", "agent", "--json" }, false);
    try std.testing.expectEqualStrings("acme/loops/tools/triage@v2", stringField(run.params, "packagePath").?);
    try std.testing.expectEqualStrings("fh run acme/loops/tools/triage@v2 --input '/tmp/in put.json' --driver agent --json", stringField(run.params, "nextCommand").?);
    try std.testing.expect(field(run.params, "yes") == null and field(run.params, "chat") == null);
    // --yes and --digest are left out of the command to run next: the inspected digest is added to it.
    const pinned = try parse(&.{ "run", "--yes", "acme/loops", "--digest", hex }, false);
    try std.testing.expect(field(pinned.params, "yes").?.bool);
    try std.testing.expectEqualStrings(hex, stringField(pinned.params, "digest").?);
    try std.testing.expectEqualStrings("fh run acme/loops", stringField(pinned.params, "nextCommand").?);
    for ([_][]const u8{ "batch", "eval" }) |method| {
        const bulk_run = try parse(&.{ method, "acme/loops/tools/triage", "--cases", "/tmp/cases.json", "--yes", "--digest", hex }, false);
        try std.testing.expectEqualStrings(hex, stringField(bulk_run.params, "digest").?);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(alloc, "fh {s} acme/loops/tools/triage --cases /tmp/cases.json", .{method}), stringField(bulk_run.params, "nextCommand").?);
    }
    // Chat marks its request and gives the chat form of the command.
    const chat = try parse(&.{ "run", "acme/loops/tools/triage", "--driver", "agent" }, true);
    try std.testing.expect(field(chat.params, "chat").?.bool);
    try std.testing.expectEqualStrings("/run acme/loops/tools/triage --driver agent", stringField(chat.params, "nextCommand").?);
    // A name, a path and check have nothing to install, so the flags are refused there.
    try std.testing.expect(field((try parse(&.{ "run", "triage" }, false)).params, "nextCommand") == null);
    try std.testing.expect(field((try parse(&.{ "check", "acme/loops" }, false)).params, "nextCommand") == null);
    for ([_][]const []const u8{
        &.{ "run", "triage", "--yes" },
        &.{ "run", "triage@2", "--digest", hex },
        &.{ "run", "./folder", "--yes", "--digest", hex },
        &.{ "run", "/tmp/folder", "--yes" },
        &.{ "check", "acme/loops", "--yes" },
        &.{ "check", "acme/loops", "--digest", hex },
        &.{ "run", "acme/loops", "--digest" },
        &.{ "run", "acme/loops", "--digest", hex, "--digest", hex },
        &.{ "retry", "run_1", "--yes" },
        &.{ "batch", "triage", "--cases", "/tmp/cases.json", "--yes" },
    }) |invalid| try std.testing.expectError(error.Usage, parse(invalid, false));
}

/// What the worker answers to a chat tool call, as fx's tool host sends one.
fn toolReply(client: *Client, tool: []const u8, package_argument: []const u8) !events.Decoded {
    var arguments = obj();
    try put(&arguments, "packagePath", str(package_argument));
    try put(&arguments, "input", obj());
    var params = obj();
    try put(&params, "name", str(tool));
    try put(&params, "arguments", arguments);
    const mailbox = try client.bridge.submitMethod("loopTool", params);
    defer client.bridge.release(mailbox);
    var waited: usize = 0;
    while (waited < 15000) : (waited += 1) {
        if (try mailbox.take()) |decoded| return decoded;
        std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake) catch {};
    }
    return error.TestUnexpectedResult;
}

test "fh chat /run of a GitHub address only inspects until it carries the inspected digest, /check installs nothing, and a chat tool can never fetch one" {
    const io = std.testing.io;
    var t: installed.TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var remote: installed.TestRemote = .{ .t = &t };
    try remote.init();
    // One infer step: an agent-driven run needs no model, no runtime and no login.
    const folder = try t.folder("work/tools/chatted", "{\"format\":\"loops/0.3\",\"name\":\"chatted\",\"version\":\"3\",\"inputs\":{\"schema\":true},\"steps\":[{\"id\":\"say\",\"kind\":\"infer\",\"instructions\":\"Say.\",\"requires\":[],\"input\":{},\"output\":{\"schema\":{\"type\":\"object\"}}}],\"output\":{\"from\":\"/steps/say/output\"}}", "unused\n");
    _ = try remote.push("main");
    const inspected = try @import("loops/package.zig").load(a, io, folder);
    var client: Client = .{};
    defer client.deinit();
    try client.bridge.configure(.{ .io = io, .profile = t.profile, .packages = remote.options() });
    const address = "acme/loops/tools/chatted";

    // /check fetches and checks. /run inspects and gives the command that installs and runs it.
    try workerReply(&client, &.{ "check", address }, false, "package_digest", inspected.digest);
    try workerReply(&client, &.{ "run", address, "--driver", "agent" }, false, "status", "confirmation_required");
    try workerReply(&client, &.{ "run", address, "--driver", "agent" }, false, "next_command", try std.fmt.allocPrint(a, "/run {s} --driver agent --yes --digest {s}", .{ address, inspected.digest }));
    // Chat cannot ask, so --yes without the digest installs nothing, and a wrong digest is refused.
    try workerReply(&client, &.{ "run", address, "--driver", "agent", "--yes" }, false, "status", "confirmation_required");
    try workerReply(&client, &.{ "run", address, "--driver", "agent", "--yes", "--digest", "0123456789abcdef" ** 4 }, true, "code", "package_digest_mismatch");
    try std.testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));
    try std.testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages/chatted", .{}));

    // A chat tool cannot fetch or install, whatever it is told: the worker refuses the address.
    for ([_][]const u8{ "loop_check", "loop_run" }) |tool| {
        var refused = try toolReply(&client, tool, address);
        defer refused.deinit();
        try std.testing.expect(refused.message.response.is_error);
        try std.testing.expectEqualStrings("package_address", stringField(refused.message.response.value, "code").?);
        try std.testing.expect(std.mem.indexOf(u8, stringField(refused.message.response.value, "message").?, "nothing here may fetch or install a package") != null);
    }
    try std.testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));

    // The inspected digest installs it and starts the run, under its installed name and version.
    try workerReply(&client, &.{ "run", address, "--driver", "agent", "--yes", "--digest", inspected.digest }, false, "package_path", "/packages/chatted/3/loop.json");
    _ = try t.tmp.dir.statFile(io, "profile/packages/chatted/3/loop.json", .{});
    // The same source again runs with no question and no flags.
    try workerReply(&client, &.{ "run", address, "--driver", "agent" }, false, "package_path", "/packages/chatted/3/loop.json");
    // Both readings: refused in one sentence, nothing fetched.
    try workerReply(&client, &.{ "run", "loops/warm-context" }, true, "message", "loops/warm-context reads as a GitHub address and is also a folder in the current directory, so fh will not guess which you mean: write ./loops/warm-context to use the folder.");
    try workerReply(&client, &.{ "check", "loops/warm-context" }, true, "code", "package_ambiguous");
    // A tool still loads what is installed, by name.
    var named = try toolReply(&client, "loop_check", "chatted@3");
    defer named.deinit();
    try std.testing.expect(!named.message.response.is_error);
}
