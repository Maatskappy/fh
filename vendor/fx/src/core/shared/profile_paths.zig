// Modified for Fasthands native Loops shell proof.
// See vendor/fx/UPSTREAM.json and patches/fx/0001-loops-shell-proof.patch.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const root_dir_name = if (@hasDecl(@import("build_options"), "loops_shell") and @import("build_options").loops_shell) ".fh" else ".fx";
pub const auth_file_name = "auth.json";
pub const chatgpt_auth_file_name = "chatgpt-auth.json";
pub const grok_auth_file_name = "grok-auth.json";
pub const api_key_file_name = "api-key";
pub const sessions_dir_name = "sessions";
/// Side folders older v2 sessions kept (D27): v1's per-session layout, one
/// folder per session id. A session moves out on its first open (D47).
pub const session_files_dir_name = "session-files";
/// Hosted terminal state of v2 sessions, one folder per session id (D45).
pub const terminal_dir_name = "terminal";
pub const prompt_history_file_name = "history.jsonl";
pub const usage_file_name = "usage.jsonl";
pub const usage_recovery_dir_name = "usage-recovery";
pub const backups_dir_name = "backups";
pub const mcp_credentials_dir_name = "mcp-credentials";
pub const mcp_credentials_file_name = "credentials.json";

const settings_file_name = "settings.json";
const mcp_config_file_name = "mcp.json";
const managed_skills_dir_name = "skills";
const logs_dir_name = "logs";
const trace_log_file_name = "trace.log";
const recordings_dir_name = "recordings";

fn joinProfile(alloc: Allocator, home: []const u8, suffix: []const []const u8) ![]u8 {
    if (comptime @hasDecl(@import("build_options"), "loops_shell") and @import("build_options").loops_shell) {
        if (std.c.getenv("FH_DATA_DIR")) |path| {
            const root = std.mem.span(path);
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(alloc);
            try parts.append(alloc, root);
            try parts.appendSlice(alloc, suffix);
            return std.fs.path.join(alloc, parts.items);
        }
    }
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);
    try parts.appendSlice(alloc, &.{ home, root_dir_name });
    try parts.appendSlice(alloc, suffix);
    return std.fs.path.join(alloc, parts.items);
}

pub fn rootDir(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{});
}

/// Credential storage follows the same isolated profile as sessions/settings.
pub fn openCredentialRoot(home: []const u8, create: bool) !@import("io.zig").VerifiedDir {
    const io_mod = @import("io.zig");
    const alloc = std.heap.c_allocator;
    const root = try rootDir(alloc, home);
    defer alloc.free(root);
    if (!create) return .{ .dir = try io_mod.openDirAbsoluteNoFollow(root, .{ .iterate = true }) };
    const parent_path = std.fs.path.dirname(root) orelse return error.InvalidProfilePath;
    var parent: io_mod.VerifiedDir = .{ .dir = try io_mod.openDirAbsoluteNoFollow(parent_path, .{ .iterate = true }) };
    defer parent.close();
    return io_mod.openOrCreateVerifiedPrivateDir(&parent, std.fs.path.basename(root));
}

pub fn settingsPath(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{settings_file_name});
}

pub fn mcpConfigPath(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{mcp_config_file_name});
}

pub fn mcpCredentialsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{mcp_credentials_dir_name});
}

pub fn mcpCredentialsPath(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{
        mcp_credentials_dir_name,
        mcp_credentials_file_name,
    });
}

pub fn managedSkillsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{managed_skills_dir_name});
}

pub fn authPath(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{auth_file_name});
}

pub fn chatgptAuthPath(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{chatgpt_auth_file_name});
}

pub fn apiKeyPath(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{api_key_file_name});
}

pub fn sessionsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{sessions_dir_name});
}

pub fn promptHistoryPath(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{prompt_history_file_name});
}

pub fn backupsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{backups_dir_name});
}

pub fn logsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{logs_dir_name});
}

pub fn traceLogPath(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{ logs_dir_name, trace_log_file_name });
}

pub const diagnostics_dir_name = "diagnostics";
pub const last_shutdown_report_file_name = "last-shutdown.json";

pub fn lastShutdownReportPath(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{ diagnostics_dir_name, last_shutdown_report_file_name });
}

pub fn recordingsDir(alloc: Allocator, home: []const u8) ![]u8 {
    return joinProfile(alloc, home, &.{recordings_dir_name});
}

test "profile path helpers preserve current default locations" {
    const alloc = std.testing.allocator;

    const root = try rootDir(alloc, "/tmp/fake-home");
    defer alloc.free(root);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx", root);

    const settings = try settingsPath(alloc, "/tmp/fake-home");
    defer alloc.free(settings);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/settings.json", settings);

    const mcp = try mcpConfigPath(alloc, "/tmp/fake-home");
    defer alloc.free(mcp);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/mcp.json", mcp);

    const mcp_credentials_dir = try mcpCredentialsDir(alloc, "/tmp/fake-home");
    defer alloc.free(mcp_credentials_dir);
    try std.testing.expectEqualStrings(
        "/tmp/fake-home/.fx/mcp-credentials",
        mcp_credentials_dir,
    );

    const mcp_credentials = try mcpCredentialsPath(alloc, "/tmp/fake-home");
    defer alloc.free(mcp_credentials);
    try std.testing.expectEqualStrings(
        "/tmp/fake-home/.fx/mcp-credentials/credentials.json",
        mcp_credentials,
    );

    const skills = try managedSkillsDir(alloc, "/tmp/fake-home");
    defer alloc.free(skills);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/skills", skills);

    const auth = try authPath(alloc, "/tmp/fake-home");
    defer alloc.free(auth);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/auth.json", auth);

    const chatgpt_auth = try chatgptAuthPath(alloc, "/tmp/fake-home");
    defer alloc.free(chatgpt_auth);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/chatgpt-auth.json", chatgpt_auth);

    const api_key = try apiKeyPath(alloc, "/tmp/fake-home");
    defer alloc.free(api_key);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/api-key", api_key);

    const sessions = try sessionsDir(alloc, "/tmp/fake-home");
    defer alloc.free(sessions);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/sessions", sessions);

    const history = try promptHistoryPath(alloc, "/tmp/fake-home");
    defer alloc.free(history);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/history.jsonl", history);

    const backups = try backupsDir(alloc, "/tmp/fake-home");
    defer alloc.free(backups);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/backups", backups);

    const logs = try logsDir(alloc, "/tmp/fake-home");
    defer alloc.free(logs);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/logs", logs);

    const trace = try traceLogPath(alloc, "/tmp/fake-home");
    defer alloc.free(trace);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/logs/trace.log", trace);

    const recordings = try recordingsDir(alloc, "/tmp/fake-home");
    defer alloc.free(recordings);
    try std.testing.expectEqualStrings("/tmp/fake-home/.fx/recordings", recordings);
}
