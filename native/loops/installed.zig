//! Installed packages: fetch a package, inspect it, install it into the profile and load it
//! by name. Nothing fetched is ever executed: a package is read as data, validated, and
//! copied. Credentials are git's own business; this file never sees one.
const std = @import("std");
const metadata = @import("../metadata.zig");
const package = @import("package.zig");
const schema = @import("schema.zig");
const storage = @import("store.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const lock_name = "packages.lock.json";
pub const directory = "packages";
const lock_version = 1;

pub const Options = struct {
    /// Test seam: fetch a GitHub address from this URL instead of github.com. Never set
    /// from the command line or the environment.
    remote_url: ?[]const u8 = null,
    /// Test seam: extra variables for the git child, so a fixture ignores this machine's
    /// own git configuration.
    environment: []const [2][]const u8 = &.{},
    /// Test seam: counts the file contents asked of the remote.
    fetched: ?*usize = null,
};

// ---------------------------------------------------------------- addresses and names

pub const Github = struct {
    owner: []const u8,
    repo: []const u8,
    /// The folder that holds loop.json, relative to the repository root. Empty is the root.
    path: []const u8 = "",
    /// A branch, tag or full commit. Null is the repository's default branch.
    ref: ?[]const u8 = null,
};

/// `OWNER/REPO[/PATH][@REF]`. Everything after the first `@` is the ref.
pub fn parseGithub(text: []const u8) !Github {
    const at = std.mem.indexOfScalar(u8, text, '@');
    const address = if (at) |i| text[0..i] else text;
    var result: Github = .{ .owner = "", .repo = "" };
    if (at) |i| {
        const ref = text[i + 1 ..];
        // A ref is handed to git as one argument, so it can never read as an option.
        if (ref.len == 0 or ref[0] == '-' or ref[0] == '/' or ref[ref.len - 1] == '/' or std.mem.indexOf(u8, ref, "..") != null) return error.InvalidAddress;
        for (ref) |c| if (c <= ' ' or c == 0x7f or std.mem.indexOfScalar(u8, "~^:?*[\\", c) != null) return error.InvalidAddress;
        result.ref = ref;
    }
    const first = std.mem.indexOfScalar(u8, address, '/') orelse return error.InvalidAddress;
    result.owner = address[0..first];
    const rest = address[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '/');
    result.repo = if (second) |i| rest[0..i] else rest;
    if (result.owner.len == 0 or result.repo.len == 0 or result.repo[0] == '.' or result.repo[0] == '-' or result.owner[0] == '-') return error.InvalidAddress;
    for (result.owner) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return error.InvalidAddress;
    for (result.repo) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.InvalidAddress;
    if (second) |i| {
        result.path = rest[i + 1 ..];
        package.localPath(result.path) catch return error.InvalidAddress;
        if (result.path[0] == '-') return error.InvalidAddress;
    }
    return result;
}

/// What a PACKAGE argument is. One rule decides, from the text alone, for every command
/// that takes a PACKAGE, and it is the rule `fh add` uses for SOURCE:
///
///   starts with `.` or `/`   a path on this machine
///   has no `/`               an installed NAME or NAME@VERSION
///   anything else            a GitHub address, OWNER/REPO[/PATH][@REF]
///
/// What the current directory holds never decides. A folder there is written `./NAME`.
pub const Kind = enum { path, name, address };
pub fn classify(argument: []const u8) Kind {
    if (argument.len == 0 or argument[0] == '.' or argument[0] == '/') return .path;
    return if (std.mem.indexOfScalar(u8, argument, '/') == null) .name else .address;
}

/// A PACKAGE argument that is a GitHub address. Text that is not an address is refused.
/// So is an address that is also the relative path of something in the current directory:
/// both readings exist, and fh does not pick one.
pub fn packageAddress(a: Allocator, io: Io, argument: []const u8, note: *?[]const u8) !Github {
    const text = try legible(a, argument);
    const address = parseGithub(argument) catch return fail(a, note, error.InvalidAddress, "{s} is not a GitHub address, which is written OWNER/REPO[/PATH][@REF]. Nothing was fetched. To use a local folder, write ./{s}.", .{ text, text });
    if (Io.Dir.cwd().statFile(io, argument, .{})) |stat| {
        const what = if (stat.kind == .directory) "folder" else "file";
        return fail(a, note, error.PackageAmbiguous, "{s} reads as a GitHub address and is also a {s} in the current directory, so fh will not guess which you mean: write ./{s} to use the {s}.", .{ text, what, text, what });
    } else |_| {}
    return address;
}

pub const Reference = struct { name: []const u8, version: ?[]const u8 = null };

/// `NAME` or `NAME@VERSION`.
pub fn parseReference(text: []const u8) !Reference {
    const at = std.mem.indexOfScalar(u8, text, '@');
    const result: Reference = .{ .name = if (at) |i| text[0..i] else text, .version = if (at) |i| text[i + 1 ..] else null };
    if (!safeName(result.name)) return error.InvalidPackageReference;
    if (result.version) |version| if (!safeVersion(version)) return error.InvalidPackageReference;
    return result;
}

// A name and a version each become one folder name, so they stay plain.
fn safeSegment(text: []const u8, extra: []const u8) bool {
    if (text.len == 0 or !std.ascii.isAlphanumeric(text[0])) return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, extra, c) == null) return false;
    return true;
}
fn safeName(text: []const u8) bool {
    return safeSegment(text, "._-");
}
fn safeVersion(text: []const u8) bool {
    return safeSegment(text, "._-+");
}

/// Orders two versions made only of dot-separated decimal numbers (`2`, `1.10.0`). Null
/// when either is anything else: a manifest version is a free string, and guessing an
/// order for one would be worse than not having one.
pub fn compareVersions(left: []const u8, right: []const u8) ?std.math.Order {
    var a = std.mem.splitScalar(u8, left, '.');
    var b = std.mem.splitScalar(u8, right, '.');
    var order: std.math.Order = .eq;
    while (true) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) return order;
        const l = number(x orelse "0") orelse return null;
        const r = number(y orelse "0") orelse return null;
        if (order != .eq) continue;
        order = if (l.len != r.len) std.math.order(l.len, r.len) else std.mem.order(u8, l, r);
    }
}
// The digits without leading zeros, so numbers of any size compare by length then text.
fn number(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    var start: usize = 0;
    while (start + 1 < text.len and text[start] == '0') start += 1;
    return text[start..];
}

// ---------------------------------------------------------------- failures

/// Records a plain sentence for the person and returns the error it explains.
fn fail(a: Allocator, note: *?[]const u8, err: anyerror, comptime format: []const u8, arguments: anytype) anyerror {
    note.* = std.fmt.allocPrint(a, format, arguments) catch null;
    return err;
}

/// A plain sentence for an error this module returns without a note of its own.
pub fn explain(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidAddress => "The source is not a GitHub address. Give OWNER/REPO[/PATH][@REF], or a folder path that starts with ./, ../ or /.",
        error.InvalidDigest => "--digest takes the 64 hexadecimal characters of a package digest, as fh add printed them. Nothing was installed.",
        error.DigestRequired => "In chat, --yes needs --digest HEX: the digest the inspection showed. Chat cannot ask you to confirm, so the digest is what ties the install to the package you read about. Nothing was installed. Run the command without --yes to see the digest and the exact command.",
        error.PackageText => "The package uses a control character in a name it would show. Nothing was installed.",
        error.PackageGitFolder => "The package contains a .git folder. A package holds its own files only. Nothing was installed.",
        error.InvalidPackageReference => "A package is named NAME or NAME@VERSION. Run fh list to see what is installed.",
        error.NotAPackageFolder => "A package is a folder that holds loop.json. Give the folder, not a file inside it.",
        error.MissingManifest, error.MissingFile => "No loop.json was found there, so it is not a package. Nothing was installed.",
        error.FileNotFound => "Nothing was found at that path, so there is no package to install.",
        error.PackageSymlink => "The package contains a symbolic link. A package holds regular files only. Nothing was installed.",
        error.PackageFile => "The package contains something that is not a regular file. A package holds regular files only. Nothing was installed.",
        error.PackageLimit => "The package is larger than a package may be. Nothing was installed.",
        error.PackagePath => "The package contains a file name that a package may not use. Nothing was installed.",
        error.UnsafePackageName => "This package cannot be installed under its name. An installed name starts with a letter or digit and uses only letters, digits, dot, underscore and hyphen.",
        error.UnsafePackageVersion => "This package cannot be installed under its version. An installed version starts with a letter or digit and uses only letters, digits, dot, underscore, hyphen and plus.",
        error.GitNotFound => "git was not found on PATH. Install git to add a package from GitHub.",
        error.InvalidPackagesLock => "packages.lock.json in the profile is not a valid lock file. Nothing was changed.",
        error.RunBusy => "Another fh operation is in progress on this installation. Nothing was changed. Retry when it has finished.",
        error.InvalidRequest => "The request was not understood. Use fh help.",
        error.PackageAncestry => "fh could not read the folders above that path, so it cannot tell whether the path is inside the profile's packages folder, and will not load it.",
        error.InvalidManifest, error.UnsupportedDefinition, error.UnsupportedFormat, error.UnsupportedCapability, error.UnsupportedSchema, error.DuplicateStep, error.DuplicateFile, error.InvalidRepeat, error.PackageFormat, error.InvalidJson, error.DuplicateKey => "The package did not pass validation, so nothing was installed. Run fh check on its folder to see what is wrong.",
        else => null,
    };
}

/// Text from a package or a command line, safe to print on one line: a control character
/// is shown as `\xNN`.
fn legible(a: Allocator, text: []const u8) ![]const u8 {
    if (isLegible(text)) return text;
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| if (c < 0x20 or c == 0x7f) try out.print(a, "\\x{x:0>2}", .{c}) else try out.append(a, c);
    return out.items;
}
fn isLegible(text: []const u8) bool {
    for (text) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

pub fn errorCode(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidAddress => "invalid_address",
        error.InvalidDigest => "invalid_digest",
        error.PackageAmbiguous => "package_ambiguous",
        error.PackageAddress => "package_address",
        error.DigestRequired => "digest_required",
        error.PackageDigestMismatch => "package_digest_mismatch",
        error.PackageCaseCollision => "package_case_collision",
        error.InstalledPackagePath => "installed_package_path",
        error.InvalidPackageReference => "invalid_package_reference",
        error.PackageNotInstalled => "package_not_installed",
        error.PackageVersionRequired => "package_version_required",
        error.PackageVersionExists => "package_version_exists",
        error.InstalledPackageChanged => "installed_package_changed",
        error.InstalledPackageMissing => "installed_package_missing",
        error.PackageRenamed => "package_renamed",
        error.GitNotFound => "git_not_found",
        error.GitFetchFailed => "git_fetch_failed",
        error.UnsafePackageName, error.UnsafePackageVersion => "unsafe_package_name",
        error.NotAPackageFolder, error.MissingManifest, error.PackageSymlink, error.PackageFile, error.PackagePath, error.PackageLimit, error.PackageText, error.PackageGitFolder => "not_a_package",
        error.InvalidPackagesLock => "invalid_packages_lock",
        else => null,
    };
}

// ---------------------------------------------------------------- the lock file

fn object() Value {
    return .{ .object = .empty };
}
fn string(text: []const u8) Value {
    return .{ .string = text };
}
fn textOf(value: Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const item = value.object.get(key) orelse return null;
    return if (item == .string) item.string else null;
}

/// The lock's entries, oldest install first. A profile with no lock file has none.
fn readLock(a: Allocator, io: Io, profile: []const u8) ![]Value {
    var dir = storage.openDirectory(io, profile) catch |err| return if (err == error.FileNotFound) &.{} else err;
    defer dir.close(io);
    var file = dir.openFile(io, lock_name, .{ .follow_symlinks = false }) catch |err| return if (err == error.FileNotFound) &.{} else err;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(a, .unlimited);
    const value = schema.parse(a, bytes) catch return error.InvalidPackagesLock;
    if (value != .object) return error.InvalidPackagesLock;
    const version = value.object.get("version") orelse return error.InvalidPackagesLock;
    if (version != .integer or version.integer != lock_version) return error.InvalidPackagesLock;
    const packages = value.object.get("packages") orelse return error.InvalidPackagesLock;
    if (packages != .array) return error.InvalidPackagesLock;
    for (packages.array.items) |entry| {
        if (!safeName(textOf(entry, "name") orelse "") or !safeVersion(textOf(entry, "version") orelse "") or textOf(entry, "digest") == null) return error.InvalidPackagesLock;
        const source = entry.object.get("source") orelse return error.InvalidPackagesLock;
        if (textOf(source, "type") == null) return error.InvalidPackagesLock;
    }
    return packages.array.items;
}

/// Replaces the lock file in one step, mode 0600. The caller holds the foreground lock.
fn writeLock(a: Allocator, io: Io, profile: []const u8, entries: []const Value) !void {
    var root = object();
    try root.object.put(a, "version", .{ .integer = lock_version });
    var packages: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    try packages.array.appendSlice(entries);
    try root.object.put(a, "packages", packages);
    const bytes = try std.json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
    var dir = try storage.openDirectory(io, profile);
    defer dir.close(io);
    var atomic = try dir.createFileAtomic(io, lock_name, .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.writeStreamingAll(io, "\n");
    try atomic.file.sync(io);
    try atomic.replace(io);
    if (metadata.syncDirectory(dir.handle) != 0) return error.StoreSyncFailed;
}

fn findExact(entries: []const Value, name: []const u8, version: []const u8) ?usize {
    for (entries, 0..) |entry, i| if (std.mem.eql(u8, textOf(entry, "name").?, name) and std.mem.eql(u8, textOf(entry, "version").?, version)) return i;
    return null;
}

/// The entry a bare NAME means. When every installed version of the name is dot-separated
/// numbers, the highest; otherwise the one installed most recently.
fn findLatest(entries: []const Value, name: []const u8) ?usize {
    var newest: ?usize = null;
    var highest: ?usize = null;
    var ordered = true;
    for (entries, 0..) |entry, i| {
        if (!std.mem.eql(u8, textOf(entry, "name").?, name)) continue;
        newest = i;
        const version = textOf(entry, "version").?;
        if (compareVersions(version, version) == null) ordered = false;
        if (!ordered) continue;
        if (highest == null or compareVersions(version, textOf(entries[highest.?], "version").?).? != .lt) highest = i;
    }
    return if (ordered) highest else newest;
}

/// A name and a version are matched exactly as written, so NAME never resolves to an entry
/// spelled another way.
fn find(entries: []const Value, reference: Reference) ?usize {
    return if (reference.version) |version| findExact(entries, reference.name, version) else findLatest(entries, reference.name);
}

/// The sentence for a name that is not installed. It says so when the same name is installed
/// in another spelling, and, for a PACKAGE argument, when a folder or file of that name is in
/// the current directory and `./` would mean it.
fn missing(a: Allocator, io: Io, entries: []const Value, argument: []const u8, reference: Reference, local: bool, note: *?[]const u8) anyerror {
    var out: std.ArrayList(u8) = .empty;
    out.print(a, "No installed package is named {s}.", .{argument}) catch return error.OutOfMemory;
    for (entries) |entry| {
        const name = textOf(entry, "name").?;
        const version = textOf(entry, "version").?;
        if (!std.ascii.eqlIgnoreCase(name, reference.name)) continue;
        if (reference.version) |wanted| {
            if (!std.ascii.eqlIgnoreCase(version, wanted)) continue;
        } else if (std.mem.eql(u8, name, reference.name)) continue;
        out.print(a, " {s}@{s} is installed. Names and versions are matched exactly, so write it that way.", .{ name, version }) catch return error.OutOfMemory;
        break;
    }
    if (local) if (Io.Dir.cwd().statFile(io, argument, .{})) |stat| {
        out.print(a, " A {s} of that name is in the current directory. To use it, write ./{s}.", .{ if (stat.kind == .directory) "folder" else "file", argument }) catch return error.OutOfMemory;
    } else |_| {};
    out.appendSlice(a, " Nothing was changed. Run fh list to see what is installed, or fh add SOURCE to install one.") catch return error.OutOfMemory;
    note.* = out.items;
    return error.PackageNotInstalled;
}

fn installedPath(a: Allocator, profile: []const u8, name: []const u8, version: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ profile, directory, name, version });
}

fn timestamp(a: Allocator, io: Io) ![]const u8 {
    const seconds: u64 = @intCast(@max(0, @divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s)));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ day.year, month.month.numeric(), @as(u32, month.day_index) + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() });
}

// ---------------------------------------------------------------- loading by name

/// Loads the package an argument names: a path, or an installed NAME or NAME@VERSION. A
/// GitHub address is refused, because loading never fetches. An installed package is hashed again on every load and refused when it no
/// longer matches its lock entry. `note` receives the sentence that explains a refusal.
pub fn open(owner: Allocator, io: Io, profile: []const u8, argument: []const u8, note: *?[]const u8) !*package.Package {
    var scratch = std.heap.ArenaAllocator.init(owner);
    defer scratch.deinit();
    const a = scratch.allocator();
    var explained: ?[]const u8 = null;
    const pkg = openIn(owner, a, io, profile, argument, &explained) catch |err| {
        if (explained) |message| note.* = owner.dupe(u8, message) catch null;
        return err;
    };
    return pkg;
}

fn openIn(owner: Allocator, a: Allocator, io: Io, profile: []const u8, argument: []const u8, note: *?[]const u8) !*package.Package {
    if (classify(argument) == .address) {
        // Loading never fetches. An address is fetched, shown and installed by `admit`, which
        // needs the person; what reaches here is refused.
        _ = try packageAddress(a, io, argument, note);
        const text = try legible(a, argument);
        return fail(a, note, error.PackageAddress, "{s} is a GitHub address, and it has not been fetched: nothing here may fetch or install a package. A person runs fh run {s}, or /run {s} in chat, which shows what the package holds before it installs and runs it. For a local folder, write ./{s}.", .{ text, text, text, text });
    }
    if (classify(argument) == .path) {
        // Asked before anything is read, so the refusal names the rule and not a missing file.
        if (Io.Dir.cwd().statFile(io, argument, .{})) |stat| {
            const folder = if (stat.kind == .directory) argument else std.fs.path.dirname(argument) orelse ".";
            if (Io.Dir.cwd().realPathFileAlloc(io, folder, a)) |root| {
                _ = try lockedRoot(a, io, profile, root, if (stat.kind == .directory) "loop.json" else std.fs.path.basename(argument), note);
            } else |_| {}
        } else |_| {}
        const pkg = try package.load(owner, io, argument);
        errdefer pkg.deinit();
        // Asked again of what was actually loaded: links and `..` are resolved in `root`.
        if (try lockedRoot(a, io, profile, pkg.root, pkg.manifest_path, note)) |entry| try verify(a, pkg, entry, note);
        return pkg;
    }
    const reference = parseReference(argument) catch return fail(a, note, error.InvalidPackageReference, "{s} is not a package name. A package is named NAME or NAME@VERSION, and a path starts with ./, ../ or /. Run fh list to see what is installed.", .{try legible(a, argument)});
    const entries = try readLock(a, io, profile);
    const index = find(entries, reference) orelse return missing(a, io, entries, argument, reference, true, note);
    const name = textOf(entries[index], "name").?;
    const version = textOf(entries[index], "version").?;
    const pkg = package.load(owner, io, try installedPath(a, profile, name, version)) catch |err| switch (err) {
        error.FileNotFound => return fail(a, note, error.InstalledPackageMissing, "The installed files for {s}@{s} are missing from the profile. Run fh remove {s}@{s}, then add it again.", .{ name, version, name, version }),
        error.PackageSymlink, error.PackageFile, error.PackagePath, error.PackageLimit, error.InvalidManifest, error.MissingFile, error.InvalidJson, error.DuplicateKey, error.UnsupportedDefinition, error.UnsupportedFormat => return fail(a, note, error.InstalledPackageChanged, "The installed files for {s}@{s} were changed after it was installed and are no longer a valid package ({s}), so fh will not run it. Run fh remove {s}@{s}, then add it again.", .{ name, version, @errorName(err), name, version }),
        else => return err,
    };
    errdefer pkg.deinit();
    try verify(a, pkg, entries[index], note);
    return pkg;
}

/// What the lock says about a package folder. Null when `root`, a path with links and `..`
/// already resolved, is outside `<profile>/packages`. Inside it, only an installed package's
/// own folder `NAME/VERSION` with its `loop.json` loads, and the answer is its lock entry.
/// Everything else in there is refused: a folder above or below a package, another manifest
/// beside `loop.json`, and the folders an install or a fetch works in.
fn lockedRoot(a: Allocator, io: Io, profile: []const u8, root: []const u8, manifest: []const u8, note: *?[]const u8) !?Value {
    const refused = "{s} is inside the profile's packages folder and is not an installed package's own folder, so fh will not load it. Name the installed package instead, as NAME or NAME@VERSION. Run fh list to see what is installed.";
    const below = try belowPackages(a, io, profile, root) orelse return null;
    // The folders between the packages folder and `root` are the last parts of its path.
    var start = root.len;
    for (0..below) |_| start = std.mem.lastIndexOfScalar(u8, root[0..start], '/') orelse return fail(a, note, error.InstalledPackagePath, refused, .{try legible(a, root)});
    var parts = std.mem.splitScalar(u8, if (below == 0) "" else root[start + 1 ..], '/');
    const name = parts.next().?;
    const version = parts.next() orelse "";
    if (parts.next() != null or !safeName(name) or !safeVersion(version) or !std.mem.eql(u8, manifest, "loop.json")) return fail(a, note, error.InstalledPackagePath, refused, .{try legible(a, if (std.mem.eql(u8, manifest, "loop.json")) root else try std.fs.path.join(a, &.{ root, manifest }))});
    const entries = try readLock(a, io, profile);
    const index = findExact(entries, name, version) orelse return fail(a, note, error.PackageNotInstalled, "The folder for {s}@{s} is in the profile, but packages.lock.json has no entry for it, so fh will not run it. Install it again with fh add.", .{ name, version });
    return entries[index];
}

/// How many folders `root` is below `<profile>/packages`: 0 for the packages folder itself,
/// 2 for a package's own folder. Null when it is outside, or when there is no packages folder.
///
/// Asked of the folders themselves, not of the text of their paths. One folder has more than
/// one resolved path: macOS reaches the data volume at `/System/Volumes/Data` as well, and
/// realpath(3) keeps that prefix. So this climbs `..` from `root` to the top of the filesystem
/// and compares each folder with the packages folder by device and inode. A folder that cannot
/// be read on the way up is an error, never an answer of outside.
fn belowPackages(a: Allocator, io: Io, profile: []const u8, root: []const u8) !?usize {
    const packages_path = try std.fs.path.join(a, &.{ profile, directory });
    const packages = (try identityAt(std.c.AT.FDCWD, try a.dupeZ(u8, packages_path))) orelse return null;
    var dir = try Io.Dir.openDirAbsolute(io, root, .{});
    defer dir.close(io);
    var up: std.ArrayList(u8) = .empty;
    var current = (try identityAt(dir.handle, ".")) orelse return error.PackageAncestry;
    var depth: usize = 0;
    while (true) : (depth += 1) {
        if (current.dev == packages.dev and current.ino == packages.ino) return depth;
        try up.appendSlice(a, if (depth == 0) ".." else "/..");
        const parent = (try identityAt(dir.handle, try a.dupeZ(u8, up.items))) orelse return error.PackageAncestry;
        // The top of the filesystem is its own parent.
        if (parent.dev == current.dev and parent.ino == current.ino) break;
        current = parent;
    }
    // The same question of the text, kept as a second way to be inside and never the only one.
    const resolved = Io.Dir.realPathFileAbsoluteAlloc(io, packages_path, a) catch return null;
    if (!std.mem.startsWith(u8, root, resolved) or (root.len != resolved.len and root[resolved.len] != '/')) return null;
    return if (root.len == resolved.len) 0 else std.mem.count(u8, root[resolved.len..], "/");
}

/// Which file a path names: two paths with the same answer are the same file, however each
/// is spelled. Links are followed. Linux distinguishes absence from unavailable metadata;
/// macOS retains its existing null-on-error behavior.
const Identity = struct { dev: @FieldType(metadata.Metadata, "dev"), ino: @FieldType(metadata.Metadata, "ino") };
fn identityAt(dir: std.c.fd_t, path: [*:0]const u8) error{PackageAncestry}!?Identity {
    const stat = metadata.fstatat(dir, path, true) catch |err| {
        if (@import("builtin").os.tag == .linux and err != error.FileNotFound) return error.PackageAncestry;
        return null;
    };
    return .{ .dev = stat.dev, .ino = stat.ino };
}

fn verify(a: Allocator, pkg: *package.Package, entry: Value, note: *?[]const u8) !void {
    const expected = textOf(entry, "digest").?;
    if (std.mem.eql(u8, expected, pkg.digest)) return;
    const name = textOf(entry, "name").?;
    const version = textOf(entry, "version").?;
    return fail(a, note, error.InstalledPackageChanged, "The installed files for {s}@{s} do not match what was installed, so fh will not run it. The lock file records digest {s}. The files on disk now have digest {s}. Run fh remove {s}@{s}, then add it again.", .{ name, version, expected, pkg.digest, name, version });
}

// ---------------------------------------------------------------- fetching from GitHub

pub const GitStep = union(enum) {
    init,
    remote: []const u8,
    fetch: []const u8,
    resolve,
    tree: struct { commit: []const u8, path: []const u8 },
    blobs: []const []const u8,
    blob: []const u8,
};

// Every git call carries these. Hooks, submodules, LFS smudge and credential prompts are
// off; git's own configuration stays the one place a credential can come from.
const git_safety = [_][]const u8{
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.fsmonitor=false",
    "-c", "core.askPass=",
    "-c", "credential.interactive=false",
    "-c", "fetch.recurseSubmodules=false",
    "-c", "submodule.recurse=false",
    "-c", "filter.lfs.smudge=",
    "-c", "filter.lfs.process=",
    "-c", "filter.lfs.required=false",
    "-c", "gc.auto=0",
    "-c", "maintenance.auto=false",
    // Every object received is checked, so a tree with a `.git` entry never arrives.
    "-c", "fetch.fsckObjects=true",
};
const git_environment = [_][2][]const u8{ .{ "GIT_TERMINAL_PROMPT", "0" }, .{ "GIT_ASKPASS", "" }, .{ "GIT_LFS_SKIP_SMUDGE", "1" } };
// A repository the caller happens to be standing in must not leak into the fetch, and
// neither may configuration or object rewriting handed down through the environment. The
// person's own git configuration files stay in force: their URL rewrites, proxy, ssh and
// credential helper are how a private repository is reached.
const git_cleared = [_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_SHALLOW_FILE", "GIT_GRAFT_FILE", "GIT_REPLACE_REF_BASE", "GIT_NO_REPLACE_OBJECTS", "GIT_PREFIX", "GIT_IMPLICIT_WORK_TREE", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS" };
const git_cleared_prefixes = [_][]const u8{ "GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_" };

/// The exact argv of one fetch step. `repository` is a private, empty directory.
///
/// The fetch is the smallest that works: one commit deep, no blobs, then only the blobs
/// under the package path. Nothing is ever checked out, so no filter, hook or link from
/// the fetched tree can act, and the bytes installed are the bytes the commit holds.
/// The repository is always named with `--git-dir`, which git accepts when the person has
/// set `safe.bareRepository=explicit`, and nothing after `--end-of-options` reads as an option.
pub fn gitArgv(a: Allocator, repository: []const u8, step: GitStep) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, "git");
    try argv.appendSlice(a, &git_safety);
    if (step == .blobs) try argv.appendSlice(a, &.{ "-c", "fetch.negotiationAlgorithm=noop" });
    if (step != .init) try argv.append(a, try std.fmt.allocPrint(a, "--git-dir={s}", .{repository}));
    switch (step) {
        .init => try argv.appendSlice(a, &.{ "init", "--quiet", "--bare", "--template=", "--end-of-options", repository }),
        .remote => |url| try argv.appendSlice(a, &.{ "remote", "add", "--end-of-options", "origin", url }),
        .fetch => |ref| try argv.appendSlice(a, &.{ "fetch", "--quiet", "--depth", "1", "--no-tags", "--no-recurse-submodules", "--filter=blob:none", "--end-of-options", "origin", ref }),
        .resolve => try argv.appendSlice(a, &.{ "rev-parse", "--verify", "--quiet", "--end-of-options", "FETCH_HEAD^{commit}" }),
        .tree => |tree| try argv.appendSlice(a, &.{ "ls-tree", "-r", "-z", "--end-of-options", if (tree.path.len == 0) try std.fmt.allocPrint(a, "{s}^{{tree}}", .{tree.commit}) else try std.fmt.allocPrint(a, "{s}:{s}", .{ tree.commit, tree.path }) }),
        .blobs => |ids| {
            try argv.appendSlice(a, &.{ "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--filter=blob:none", "--end-of-options", "origin" });
            try argv.appendSlice(a, ids);
        },
        .blob => |id| try argv.appendSlice(a, &.{ "cat-file", "--end-of-options", "blob", id }),
    }
    return argv.toOwnedSlice(a);
}

/// The longest listing a package inside its bounds can have: `max_files` records of
/// `<mode> blob <id>\t<path>\0`, with a SHA-256 id and the longest path a package may hold.
const listing_limit = package.max_files * ("100644 blob ".len + 64 + "\t".len + std.fs.max_path_bytes + "\x00".len);

pub fn githubUrl(a: Allocator, address: Github) ![]const u8 {
    return std.fmt.allocPrint(a, "https://github.com/{s}/{s}.git", .{ address.owner, address.repo });
}

fn hexId(text: []const u8) bool {
    if (text.len != 40 and text.len != 64) return false;
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

const Git = struct {
    a: Allocator,
    io: Io,
    repository: []const u8,
    environment: *const std.process.Environ.Map,
    what: []const u8,
    note: *?[]const u8,
    fn run(self: Git, step: GitStep, limit: Io.Limit) ![]const u8 {
        const result = std.process.run(self.a, self.io, .{ .argv = try gitArgv(self.a, self.repository, step), .environ_map = self.environment, .stdout_limit = limit }) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            error.StreamTooLong => return error.PackageLimit,
            else => return err,
        };
        if (result.term == .exited and result.term.exited == 0) return result.stdout;
        const said = std.mem.trim(u8, result.stderr, " \t\r\n");
        return fail(self.a, self.note, error.GitFetchFailed, "git could not fetch {s}. Nothing was installed. git said: {s}", .{ self.what, if (said.len == 0) "nothing" else said });
    }
};

/// This process's environment, for a child that needs a few variables changed.
fn inherited(a: Allocator) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(a);
    var count: usize = 0;
    while (std.c.environ[count] != null) count += 1;
    const entries: []const [*:0]const u8 = @ptrCast(std.c.environ[0..count]);
    try map.putPosixBlock(.{ .slice = entries });
    return map;
}

/// Turns this process's environment into the one every git child gets.
fn gitEnvironment(environment: *std.process.Environ.Map, options: Options) !void {
    for (git_cleared) |name| _ = environment.swapRemove(name);
    var index: usize = 0;
    while (index < environment.count()) {
        const name = environment.keys()[index];
        for (git_cleared_prefixes) |prefix| {
            if (std.mem.startsWith(u8, name, prefix)) break;
        } else {
            index += 1;
            continue;
        }
        // The last variable moves into this place, so the same index is looked at again.
        _ = environment.swapRemove(name);
    }
    for (git_environment) |pair| try environment.put(pair[0], pair[1]);
    for (options.environment) |pair| try environment.put(pair[0], pair[1]);
}

const fetch_prefix = ".fetch-";

/// Removes the `.fetch-*` folders an interrupted fetch left in `<profile>/packages`. Every
/// add and update starts here. Like `.installing`, a folder is removed only under the
/// foreground lock; when a run holds that lock the folders wait for the next add. A fetch
/// that is still running holds a lock on its own folder, and that folder is left alone.
pub fn sweepFetches(a: Allocator, io: Io, profile: []const u8) !void {
    var packages = storage.openDirectory(io, try std.fs.path.join(a, &.{ profile, directory })) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer packages.close(io);
    var left: std.ArrayList([]const u8) = .empty;
    var it = packages.iterate();
    while (try it.next(io)) |entry| if (std.mem.startsWith(u8, entry.name, fetch_prefix)) try left.append(a, try a.dupe(u8, entry.name));
    if (left.items.len == 0) return;
    var registry = try storage.Store.init(a, io, profile);
    defer registry.deinit();
    const foreground = registry.lock("foreground") catch |err| {
        if (err == error.RunBusy) return;
        return err;
    };
    defer foreground.close(io);
    for (left.items) |name| {
        // Opened for iteration so that Linux gives a real descriptor: flock refuses an O_PATH one.
        var folder = packages.openDir(io, name, .{ .follow_symlinks = false, .iterate = true }) catch continue;
        defer folder.close(io);
        if (std.c.flock(folder.handle, std.c.LOCK.EX | std.c.LOCK.NB) != 0) continue;
        try packages.deleteTree(io, name);
    }
}

const Fetched = struct { files: []const package.File, commit: []const u8 };

fn fetch(a: Allocator, io: Io, profile: []const u8, address: Github, options: Options, note: *?[]const u8) !Fetched {
    var parent = try storage.openDirectory(io, profile);
    defer parent.close(io);
    parent.createDir(io, directory, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
    var packages = try parent.openDir(io, directory, .{ .follow_symlinks = false });
    defer packages.close(io);
    var random: [8]u8 = undefined;
    Io.random(io, &random);
    const scratch = try std.fmt.allocPrint(a, fetch_prefix ++ "{s}", .{std.fmt.bytesToHex(random, .lower)});
    try packages.createDir(io, scratch, .fromMode(0o700));
    defer packages.deleteTree(io, scratch) catch {};
    // Held for the whole fetch, so the sweep in a second fh add leaves this folder alone.
    var held = try packages.openDir(io, scratch, .{ .follow_symlinks = false, .iterate = true });
    defer held.close(io);
    if (std.c.flock(held.handle, std.c.LOCK.EX | std.c.LOCK.NB) != 0) return error.RunBusy;
    var environment = try inherited(a);
    try gitEnvironment(&environment, options);
    const shown = try std.fmt.allocPrint(a, "{s}/{s}{s}{s}", .{ address.owner, address.repo, if (address.ref != null) " at " else "", address.ref orelse "" });
    const git: Git = .{ .a = a, .io = io, .repository = try std.fs.path.join(a, &.{ profile, directory, scratch }), .environment = &environment, .what = shown, .note = note };
    _ = try git.run(.init, .unlimited);
    _ = try git.run(.{ .remote = options.remote_url orelse try githubUrl(a, address) }, .unlimited);
    _ = try git.run(.{ .fetch = address.ref orelse "HEAD" }, .unlimited);
    const revision = std.mem.trim(u8, try git.run(.resolve, .unlimited), " \r\n");
    if (!hexId(revision)) return error.GitFetchFailed;
    const listing = git.run(.{ .tree = .{ .commit = revision, .path = address.path } }, .limited(listing_limit)) catch |err| {
        if (err == error.GitFetchFailed) return fail(a, note, error.MissingManifest, "{s}/{s} has no folder {s} at commit {s}. Nothing was installed.", .{ address.owner, address.repo, if (address.path.len == 0) "at its root" else address.path, revision });
        return err;
    };
    var files: std.ArrayList(package.File) = .empty;
    var ids: std.ArrayList([]const u8) = .empty;
    var manifest = false;
    var records = std.mem.splitScalar(u8, listing, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        // "<mode> <type> <id>\t<path>"
        const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.GitFetchFailed;
        var head = std.mem.splitScalar(u8, record[0..tab], ' ');
        const mode = head.next() orelse return error.GitFetchFailed;
        _ = head.next() orelse return error.GitFetchFailed;
        const id = head.next() orelse return error.GitFetchFailed;
        if (std.mem.eql(u8, mode, "120000")) return error.PackageSymlink;
        if (!std.mem.eql(u8, mode, "100644") and !std.mem.eql(u8, mode, "100755")) return error.PackageFile;
        if (!hexId(id)) return error.GitFetchFailed;
        if (files.items.len >= package.max_files) return error.PackageLimit;
        const path = record[tab + 1 ..];
        try package.localPath(path);
        if (std.mem.eql(u8, path, "loop.json")) manifest = true;
        try files.append(a, .{ .path = path, .bytes = "" });
        try ids.append(a, id);
    }
    if (!manifest) return error.MissingManifest;
    // git cannot say how large a file is before it has fetched it, and GitHub serves no
    // sizes. So the contents arrive in batches, one file and then twice as many each time,
    // and the fetch stops at the first batch that takes the package past its size bound.
    var total: usize = 0;
    var done: usize = 0;
    var batch: usize = 1;
    while (done < ids.items.len) : (batch *= 2) {
        const end = @min(ids.items.len, done + batch);
        _ = try git.run(.{ .blobs = ids.items[done..end] }, .unlimited);
        if (options.fetched) |count| count.* += end - done;
        for (files.items[done..end], ids.items[done..end]) |*file, id| {
            file.bytes = try git.run(.{ .blob = id }, .limited(package.max_bytes - total));
            total += file.bytes.len;
        }
        done = end;
    }
    return .{ .files = files.items, .commit = revision };
}

// ---------------------------------------------------------------- staging and installing

/// A package that has been fetched and validated and is not yet installed.
pub const Staged = struct {
    pkg: *package.Package,
    /// The lock entry's `source`, allocated in the package's arena.
    source: Value,
    pub fn deinit(self: *Staged) void {
        self.pkg.deinit();
    }
    pub fn name(self: *const Staged) []const u8 {
        return self.pkg.manifest.object.get("name").?.string;
    }
    pub fn version(self: *const Staged) []const u8 {
        return self.pkg.manifest.object.get("version").?.string;
    }
};

/// Fetches SOURCE and validates it as a package. SOURCE is a folder only when it starts
/// with `.` or `/`. Anything else is a GitHub address, whatever the current directory holds.
pub fn stage(owner: Allocator, a: Allocator, io: Io, profile: []const u8, source: []const u8, options: Options, note: *?[]const u8) !Staged {
    try sweepFetches(a, io, profile);
    if (source.len != 0 and (source[0] == '.' or source[0] == '/')) return stageFolder(owner, a, io, source, note);
    const address = parseGithub(source) catch {
        const text = try legible(a, source);
        return fail(a, note, error.InvalidAddress, "{s} is not a GitHub address, which is written OWNER/REPO[/PATH][@REF]. Nothing was installed. To add a local folder, write ./{s}.", .{ text, text });
    };
    return stageGithub(owner, a, io, profile, address, options, note);
}

fn stageFolder(owner: Allocator, a: Allocator, io: Io, path: []const u8, note: *?[]const u8) !Staged {
    const stat = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link) return error.PackageSymlink;
    if (stat.kind != .directory) return error.NotAPackageFolder;
    const pkg = try package.loadForInstall(owner, io, path);
    errdefer pkg.deinit();
    var source = object();
    try source.object.put(pkg.arena.allocator(), "type", string("local"));
    try source.object.put(pkg.arena.allocator(), "path", string(pkg.root));
    return checked(a, .{ .pkg = pkg, .source = source }, note);
}

fn stageGithub(owner: Allocator, a: Allocator, io: Io, profile: []const u8, address: Github, options: Options, note: *?[]const u8) !Staged {
    const fetched = try fetch(a, io, profile, address, options, note);
    const pkg = try package.fromFiles(owner, fetched.files, "loop.json");
    errdefer pkg.deinit();
    const p = pkg.arena.allocator();
    var source = object();
    try source.object.put(p, "type", string("github"));
    try source.object.put(p, "repo", string(try std.fmt.allocPrint(p, "{s}/{s}", .{ address.owner, address.repo })));
    try source.object.put(p, "path", string(try p.dupe(u8, address.path)));
    try source.object.put(p, "ref", if (address.ref) |ref| string(try p.dupe(u8, ref)) else .null);
    try source.object.put(p, "commit", string(try p.dupe(u8, fetched.commit)));
    return checked(a, .{ .pkg = pkg, .source = source }, note);
}

/// What a package from either kind of source must also be before it is shown or installed.
fn checked(a: Allocator, staged: Staged, note: *?[]const u8) !Staged {
    if (!safeName(staged.name())) return error.UnsafePackageName;
    if (!safeVersion(staged.version())) return error.UnsafePackageVersion;
    for (staged.pkg.files) |file| {
        // A `.git` at any depth could make a later git command in the installed folder obey it.
        var parts = std.mem.splitScalar(u8, file.path, '/');
        while (parts.next()) |part| if (std.ascii.eqlIgnoreCase(part, ".git")) return fail(a, note, error.PackageGitFolder, "The package contains {s}, which is or is inside a .git entry. A package holds its own files only, never a repository's. Nothing was installed.", .{try legible(a, file.path)});
        if (!isLegible(file.path)) return fail(a, note, error.PackageText, "The package has a file whose name contains a control character: {s}. Nothing was installed.", .{try legible(a, file.path)});
    }
    // Everything the inspection prints from the manifest. A line break in one of these could
    // write a line of its own, such as a false list of what the package requires.
    const inspection = try inspect(a, &staged);
    for (inspection.object.get("steps").?.array.items) |step| {
        var ok = true;
        for ([_][]const u8{ "path", "kind", "runtime", "file" }) |key| ok = ok and isLegible(textOf(step, key) orelse "");
        if (step.object.get("requires")) |requires| for (requires.array.items) |capability| {
            ok = ok and isLegible(capability.string);
        };
        if (!ok) return fail(a, note, error.PackageText, "The package's step {s} has a control character in its id, runtime, file or required capability. Nothing was installed.", .{try legible(a, textOf(step, "path").?)});
    }
    return staged;
}

/// Stages the newest content of an installed package's recorded source, at the ref that
/// was asked for when it was added.
pub fn stageUpdate(owner: Allocator, a: Allocator, io: Io, profile: []const u8, argument: []const u8, options: Options, note: *?[]const u8) !Staged {
    try sweepFetches(a, io, profile);
    const reference = try parseReference(argument);
    const entries = try readLock(a, io, profile);
    const index = find(entries, reference) orelse return missing(a, io, entries, argument, reference, false, note);
    const source = entries[index].object.get("source").?;
    const kind = textOf(source, "type").?;
    var staged = if (std.mem.eql(u8, kind, "local"))
        stageFolder(owner, a, io, textOf(source, "path") orelse return error.InvalidPackagesLock, note) catch |err| return if (err == error.FileNotFound) fail(a, note, err, "{s} was installed from the folder {s}, which no longer exists. Nothing was changed.", .{ reference.name, textOf(source, "path").? }) else err
    else if (std.mem.eql(u8, kind, "github")) blk: {
        const folder: []const u8 = textOf(source, "path") orelse "";
        const ref: ?[]const u8 = textOf(source, "ref");
        const address = parseGithub(try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ textOf(source, "repo") orelse return error.InvalidPackagesLock, if (folder.len != 0) "/" else "", folder, if (ref != null) "@" else "", ref orelse "" })) catch return error.InvalidPackagesLock;
        break :blk try stageGithub(owner, a, io, profile, address, options, note);
    } else return error.InvalidPackagesLock;
    errdefer staged.deinit();
    if (!std.mem.eql(u8, staged.name(), reference.name)) return fail(a, note, error.PackageRenamed, "The source of {s} now holds a package named {s}. Nothing was changed. Add it under its new name with fh add.", .{ reference.name, staged.name() });
    return staged;
}

pub const Plan = enum { install, unchanged };

/// What installing would do. The same name and version with the same digest is already
/// there. With a different digest it is refused: an installed version never changes.
pub fn plan(a: Allocator, io: Io, profile: []const u8, staged: *const Staged, note: *?[]const u8) !Plan {
    return planIn(a, try readLock(a, io, profile), staged, note);
}
fn planIn(a: Allocator, entries: []const Value, staged: *const Staged, note: *?[]const u8) !Plan {
    const name = staged.name();
    const version = staged.version();
    if (findExact(entries, name, version)) |index| {
        const installed = textOf(entries[index], "digest").?;
        if (std.mem.eql(u8, installed, staged.pkg.digest)) return .unchanged;
        return fail(a, note, error.PackageVersionExists, "{s} {s} is already installed with different content, and an installed version never changes. Installed digest {s}. New digest {s}. Nothing was changed. If the source is right, it should be published under a new version. To replace the installed copy anyway, run fh remove {s}@{s} and add it again.", .{ name, version, installed, staged.pkg.digest, name, version });
    }
    // A name and a version are each a folder name, and many file systems ignore case. One
    // spelling of a name is installed at a time, and one spelling of each of its versions,
    // so two entries never share a folder.
    for (entries) |entry| {
        const installed_name = textOf(entry, "name").?;
        const installed_version = textOf(entry, "version").?;
        if (!std.ascii.eqlIgnoreCase(installed_name, name)) continue;
        if (std.mem.eql(u8, installed_name, name) and !std.ascii.eqlIgnoreCase(installed_version, version)) continue;
        return fail(a, note, error.PackageCaseCollision, "{s} {s} is installed, and {s} {s} differs from it only in upper and lower case. On a file system that ignores case the two would share a folder, so fh keeps one spelling at a time. Nothing was changed. To install this one instead, run fh remove {s}@{s} first.", .{ installed_name, installed_version, name, version, installed_name, installed_version });
    }
    return .install;
}

/// Installs under the foreground lock: read-only files written beside their destination and
/// renamed into place, then the lock entry.
pub fn commit(a: Allocator, io: Io, profile: []const u8, staged: *const Staged, note: *?[]const u8) !Plan {
    var registry = try storage.Store.init(a, io, profile);
    defer registry.deinit();
    const foreground = try registry.lock("foreground");
    defer foreground.close(io);
    const entries = try readLock(a, io, profile);
    const decided = try planIn(a, entries, staged, note);
    var parent = try storage.openDirectory(io, profile);
    defer parent.close(io);
    parent.createDir(io, directory, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
    var packages = try parent.openDir(io, directory, .{ .follow_symlinks = false });
    defer packages.close(io);
    const name = staged.name();
    const version = staged.version();
    packages.createDir(io, name, .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
    var home = try packages.openDir(io, name, .{ .follow_symlinks = false });
    defer home.close(io);
    const present = if (home.statFile(io, version, .{ .follow_symlinks = false })) |_| true else |_| false;
    if (decided == .unchanged and present) return .unchanged;
    // A folder here with no lock entry in any spelling (planIn refused the others) is what
    // an interrupted install leaves. Nothing can load it.
    if (present) try home.deleteTree(io, version);
    const scratch = ".installing";
    // Only the holder of the foreground lock writes here, so one left behind is abandoned.
    try packages.deleteTree(io, scratch);
    try packages.createDir(io, scratch, .fromMode(0o700));
    errdefer packages.deleteTree(io, scratch) catch {};
    {
        var target = try packages.openDir(io, scratch, .{ .follow_symlinks = false });
        defer target.close(io);
        for (staged.pkg.files) |file| {
            if (std.fs.path.dirname(file.path)) |folder| _ = try target.createDirPathStatus(io, folder, .fromMode(0o700));
            var out = try target.createFile(io, file.path, .{ .exclusive = true, .permissions = .fromMode(0o400) });
            defer out.close(io);
            try out.writeStreamingAll(io, file.bytes);
            try out.sync(io);
        }
        if (metadata.syncDirectory(target.handle) != 0) return error.StoreSyncFailed;
    }
    try packages.rename(scratch, home, version, io);
    if (metadata.syncDirectory(home.handle) != 0) return error.StoreSyncFailed;
    if (decided == .unchanged) return .unchanged;
    var entry = object();
    try entry.object.put(a, "name", string(name));
    try entry.object.put(a, "version", string(version));
    try entry.object.put(a, "digest", string(staged.pkg.digest));
    try entry.object.put(a, "source", staged.source);
    try entry.object.put(a, "installed_at", string(try timestamp(a, io)));
    var next: std.ArrayList(Value) = .empty;
    try next.appendSlice(a, entries);
    try next.append(a, entry);
    try writeLock(a, io, profile, next.items);
    return .install;
}

// ---------------------------------------------------------------- inspection

fn walkSteps(a: Allocator, steps: Value, prefix: []const u8, out: *Value, capabilities: *Value, code: *Value) !void {
    for (steps.array.items) |step| {
        const id = textOf(step, "id").?;
        const kind = textOf(step, "kind").?;
        const path = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, id });
        var listed = object();
        try listed.object.put(a, "path", string(path));
        try listed.object.put(a, "kind", string(kind));
        if (step.object.get("branches")) |branches| {
            try out.array.append(listed);
            var it = branches.object.iterator();
            while (it.next()) |branch| try walkSteps(a, branch.value_ptr.*, try std.fmt.allocPrint(a, "{s}/{s}/", .{ path, branch.key_ptr.* }), out, capabilities, code);
            continue;
        }
        if (std.mem.eql(u8, kind, "map")) {
            try out.array.append(listed);
            try walkSteps(a, step.object.get("steps").?, try std.fmt.allocPrint(a, "{s}[]/", .{path}), out, capabilities, code);
            continue;
        }
        if (std.mem.eql(u8, kind, "code")) {
            try listed.object.put(a, "runtime", step.object.get("runtime").?);
            try listed.object.put(a, "file", step.object.get("file").?);
            var file = object();
            try file.object.put(a, "file", step.object.get("file").?);
            try file.object.put(a, "runtime", step.object.get("runtime").?);
            var known = false;
            for (code.array.items) |existing| if (schema.equal(existing, file)) {
                known = true;
            };
            if (!known) try code.array.append(file);
        }
        if (step.object.get("requires")) |requires| {
            if (requires.array.items.len != 0) try listed.object.put(a, "requires", requires);
            for (requires.array.items) |capability| {
                var known = false;
                for (capabilities.array.items) |existing| if (schema.equal(existing, capability)) {
                    known = true;
                };
                if (!known) try capabilities.array.append(capability);
            }
        }
        try out.array.append(listed);
    }
}

/// Everything a person needs to decide whether to install: read from the validated
/// manifest, never from running anything.
pub fn inspect(a: Allocator, staged: *const Staged) !Value {
    const manifest = staged.pkg.manifest;
    var result = object();
    try result.object.put(a, "name", manifest.object.get("name").?);
    try result.object.put(a, "version", manifest.object.get("version").?);
    try result.object.put(a, "format", manifest.object.get("format").?);
    try result.object.put(a, "digest", string(staged.pkg.digest));
    try result.object.put(a, "source", staged.source);
    var files: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    for (staged.pkg.files) |file| try files.array.append(string(file.path));
    try result.object.put(a, "files", files);
    var steps: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    var capabilities: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    var code: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    try walkSteps(a, manifest.object.get("steps").?, "", &steps, &capabilities, &code);
    try result.object.put(a, "steps", steps);
    try result.object.put(a, "requires", capabilities);
    try result.object.put(a, "code", code);
    return result;
}

fn sourceText(a: Allocator, source: Value) ![]const u8 {
    if (std.mem.eql(u8, textOf(source, "type") orelse "", "github")) {
        const path = textOf(source, "path") orelse "";
        const ref = textOf(source, "ref");
        return std.fmt.allocPrint(a, "github {s}{s}{s} at commit {s} ({s}{s})", .{ try legible(a, textOf(source, "repo") orelse ""), if (path.len != 0) ", folder " else "", try legible(a, path), try legible(a, textOf(source, "commit") orelse ""), if (ref != null) "asked for " else "default branch", try legible(a, ref orelse "") });
    }
    return std.fmt.allocPrint(a, "local {s}", .{try legible(a, textOf(source, "path") orelse "")});
}

/// The inspection as lines of plain text. A control character in anything a package
/// supplied is printed escaped, so a package cannot write a line of its own.
pub fn describe(a: Allocator, inspection: Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "Package   {s} {s} ({s})\nDigest    {s}\nSource    {s}\nFiles     {d}\nSteps\n", .{ try legible(a, textOf(inspection, "name").?), try legible(a, textOf(inspection, "version").?), try legible(a, textOf(inspection, "format").?), try legible(a, textOf(inspection, "digest").?), try sourceText(a, inspection.object.get("source").?), inspection.object.get("files").?.array.items.len });
    for (inspection.object.get("steps").?.array.items) |step| {
        try out.print(a, "  {s}  {s}", .{ try legible(a, textOf(step, "path").?), try legible(a, textOf(step, "kind").?) });
        if (textOf(step, "runtime")) |runtime| try out.print(a, "  {s}  {s}", .{ try legible(a, runtime), try legible(a, textOf(step, "file").?) });
        if (step.object.get("requires")) |requires| for (requires.array.items) |capability| try out.print(a, "  requires {s}", .{try legible(a, capability.string)});
        try out.append(a, '\n');
    }
    try out.appendSlice(a, "Requires  ");
    const capabilities = inspection.object.get("requires").?.array.items;
    for (capabilities, 0..) |capability, i| try out.print(a, "{s}{s}", .{ if (i == 0) "" else ", ", try legible(a, capability.string) });
    if (capabilities.len == 0) try out.appendSlice(a, "no capabilities");
    try out.appendSlice(a, "\nCode      ");
    const code = inspection.object.get("code").?.array.items;
    for (code, 0..) |file, i| try out.print(a, "{s}{s} ({s})", .{ if (i == 0) "" else ", ", try legible(a, textOf(file, "file").?), try legible(a, textOf(file, "runtime").?) });
    if (code.len == 0) try out.appendSlice(a, "no code files");
    try out.append(a, '\n');
    return out.items;
}

// ---------------------------------------------------------------- commands

/// A copy of `value` that owns every string, so it outlives the package it was read from.
fn clone(a: Allocator, value: Value) Allocator.Error!Value {
    switch (value) {
        .string => |text| return .{ .string = try a.dupe(u8, text) },
        .number_string => |text| return .{ .number_string = try a.dupe(u8, text) },
        .array => |items| {
            var copy = std.array_list.Managed(Value).init(a);
            for (items.items) |item| try copy.append(try clone(a, item));
            return .{ .array = copy };
        },
        .object => |map| {
            var copy = object();
            var it = map.iterator();
            while (it.next()) |entry| try copy.object.put(a, try a.dupe(u8, entry.key_ptr.*), try clone(a, entry.value_ptr.*));
            return copy;
        },
        else => return value,
    }
}

/// The inspection with what happened: `installed`, `unchanged`, `confirmation_required`
/// or, at a terminal, `declined`. Every string in it is a copy owned by `a`, so the answer
/// stays good after the staged package is freed.
pub fn answer(a: Allocator, staged: *const Staged, status: []const u8) !Value {
    var result = try clone(a, try inspect(a, staged));
    try result.object.put(a, "status", string(status));
    return result;
}

pub const Request = struct {
    updating: bool = false,
    /// SOURCE for add, NAME or NAME@VERSION for update.
    argument: []const u8,
    yes: bool = false,
    /// The digest that was inspected. When set, nothing else is installed.
    digest: ?[]const u8 = null,
    /// Chat cannot ask a question, so there `yes` needs `digest`.
    chat: bool = false,
};

/// A digest as `--digest` takes it: the 64 hexadecimal characters fh prints.
pub fn checkDigest(text: []const u8) !void {
    if (text.len != 64) return error.InvalidDigest;
    for (text) |c| if (!std.ascii.isHex(c)) return error.InvalidDigest;
}

/// Refuses a staged package whose digest is not the one that was inspected.
pub fn expectDigest(a: Allocator, staged: *const Staged, expected: []const u8, note: *?[]const u8) !void {
    try checkDigest(expected);
    if (std.ascii.eqlIgnoreCase(expected, staged.pkg.digest)) return;
    return fail(a, note, error.PackageDigestMismatch, "{s} {s} from this source now has digest {s}. --digest asked for {s}. They differ, so this is not the package that was inspected. Nothing was installed. Run the command without --yes to inspect it again.", .{ staged.name(), staged.version(), staged.pkg.digest, expected });
}

/// One word of a command line a person can paste into a shell.
pub fn shellWord(a: Allocator, text: []const u8) ![]const u8 {
    for (text) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_@%+=:,./-", c) == null) break;
    } else if (text.len != 0) return text;
    return std.fmt.allocPrint(a, "'{s}'", .{try std.mem.replaceOwned(u8, a, text, "'", "'\\''")});
}

/// The exact command that installs what was just inspected, and nothing else.
pub fn nextCommand(a: Allocator, request: Request, digest: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}{s} {s} --yes --digest {s}", .{ if (request.chat) "/" else "fh ", if (request.updating) "update" else "add", if (request.chat) request.argument else try shellWord(a, request.argument), digest });
}

/// `fh add` and `fh update` in one call: stage, inspect, and install only when `yes`.
/// Without it the answer is the inspection, `confirmation_required` and the command to run
/// next, which carries the digest that was inspected.
pub fn install(a: Allocator, io: Io, profile: []const u8, request: Request, options: Options, note: *?[]const u8) !Value {
    if (request.digest) |digest| try checkDigest(digest);
    if (request.chat and request.yes and request.digest == null) return error.DigestRequired;
    var staged = if (request.updating) try stageUpdate(a, a, io, profile, request.argument, options, note) else try stage(a, a, io, profile, request.argument, options, note);
    defer staged.deinit();
    if (request.digest) |digest| try expectDigest(a, &staged, digest, note);
    if (try plan(a, io, profile, &staged, note) == .unchanged) return answer(a, &staged, "unchanged");
    if (!request.yes) {
        var asked = try answer(a, &staged, "confirmation_required");
        try asked.object.put(a, "next_command", string(try nextCommand(a, request, textOf(asked, "digest").?)));
        return asked;
    }
    return answer(a, &staged, if (try commit(a, io, profile, &staged, note) == .install) "installed" else "unchanged");
}

pub fn list(a: Allocator, io: Io, profile: []const u8) !Value {
    var packages: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    try packages.array.appendSlice(try readLock(a, io, profile));
    var result = object();
    try result.object.put(a, "packages", packages);
    return result;
}

/// The installed list as lines of plain text: name, version, digest prefix, source.
pub fn describeList(a: Allocator, listed: Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const packages = listed.object.get("packages").?.array.items;
    if (packages.len == 0) try out.appendSlice(a, "No packages are installed. Add one with fh add SOURCE.\n");
    for (packages) |entry| {
        const source = entry.object.get("source").?;
        const digest = textOf(entry, "digest").?;
        const path = textOf(source, "path") orelse "";
        try out.print(a, "{s}  {s}  {s}  ", .{ textOf(entry, "name").?, textOf(entry, "version").?, try legible(a, digest[0..@min(12, digest.len)]) });
        if (std.mem.eql(u8, textOf(source, "type").?, "github")) {
            const revision = textOf(source, "commit") orelse "";
            try out.print(a, "github {s}{s}{s}@{s}\n", .{ try legible(a, textOf(source, "repo") orelse ""), if (path.len != 0) "/" else "", try legible(a, path), try legible(a, revision[0..@min(12, revision.len)]) });
        } else try out.print(a, "{s} {s}\n", .{ try legible(a, textOf(source, "type").?), try legible(a, path) });
    }
    return out.items;
}

/// Removes one installed version. A bare NAME is enough when one version is installed.
/// The name and version are matched exactly as written.
pub fn remove(a: Allocator, io: Io, profile: []const u8, argument: []const u8, note: *?[]const u8) !Value {
    const reference = try parseReference(argument);
    var registry = try storage.Store.init(a, io, profile);
    defer registry.deinit();
    const foreground = try registry.lock("foreground");
    defer foreground.close(io);
    const entries = try readLock(a, io, profile);
    var index: ?usize = null;
    var versions: std.ArrayList(u8) = .empty;
    for (entries, 0..) |entry, i| {
        if (!std.mem.eql(u8, textOf(entry, "name").?, reference.name)) continue;
        if (reference.version) |version| if (!std.mem.eql(u8, textOf(entry, "version").?, version)) continue;
        try versions.print(a, "{s}{s}", .{ if (index == null) "" else ", ", textOf(entry, "version").? });
        if (index != null) index = entries.len else index = i;
    }
    const found = index orelse return missing(a, io, entries, argument, reference, false, note);
    if (found == entries.len) return fail(a, note, error.PackageVersionRequired, "{s} has more than one installed version: {s}. Nothing was changed. Name one, for example fh remove {s}@VERSION.", .{ reference.name, versions.items, reference.name });
    const name = textOf(entries[found], "name").?;
    const version = textOf(entries[found], "version").?;
    // The files go first and the lock entry last. If the files cannot be deleted the entry
    // is still there, the package is refused for not matching its digest, and remove can be
    // run again. Files that are already gone are no reason to keep the entry.
    var files_missing = true;
    if (storage.openDirectory(io, try std.fs.path.join(a, &.{ profile, directory }))) |opened_packages| {
        var packages = opened_packages;
        defer packages.close(io);
        if (packages.openDir(io, name, .{ .follow_symlinks = false })) |opened_home| {
            var home = opened_home;
            defer home.close(io);
            if (home.statFile(io, version, .{ .follow_symlinks = false })) |_| {
                files_missing = false;
            } else |err| if (err != error.FileNotFound) return err;
            try home.deleteTree(io, version);
        } else |err| if (err != error.FileNotFound) return err;
        packages.deleteDir(io, name) catch {};
    } else |err| if (err != error.FileNotFound) return err;
    var next: std.ArrayList(Value) = .empty;
    try next.appendSlice(a, entries[0..found]);
    try next.appendSlice(a, entries[found + 1 ..]);
    try writeLock(a, io, profile, next.items);
    var result = object();
    try result.object.put(a, "status", string("removed"));
    try result.object.put(a, "name", string(name));
    try result.object.put(a, "version", string(version));
    try result.object.put(a, "files_missing", .{ .bool = files_missing });
    return result;
}

/// The four package commands as one call, for the worker the chat commands use.
pub fn command(a: Allocator, io: Io, profile: []const u8, method: []const u8, params: Value, options: Options, note: *?[]const u8) !Value {
    if (std.mem.eql(u8, method, "list")) return list(a, io, profile);
    const adding = std.mem.eql(u8, method, "add");
    if (adding or std.mem.eql(u8, method, "update")) {
        var request: Request = .{ .updating = !adding, .argument = textOf(params, if (adding) "source" else "package") orelse return error.InvalidRequest };
        if (params.object.get("yes")) |value| request.yes = value == .bool and value.bool;
        if (params.object.get("chat")) |value| request.chat = value == .bool and value.bool;
        if (params.object.get("digest")) |value| request.digest = if (value == .string) value.string else return error.InvalidDigest;
        return install(a, io, profile, request, options, note);
    }
    if (std.mem.eql(u8, method, "remove")) return remove(a, io, profile, textOf(params, "package") orelse return error.InvalidRequest, note);
    return error.InvalidRequest;
}


// ---------------------------------------------------------------- running an address

/// Asks the person whether to install what the inspection shows. Only a terminal has one.
pub const Ask = struct { context: *anyopaque, askFn: *const fn (*anyopaque, Allocator, Value) anyerror!bool };

pub const RunRequest = struct {
    /// The GitHub address, as typed.
    argument: []const u8,
    yes: bool = false,
    /// The digest that was inspected. When set, nothing else is installed or run.
    digest: ?[]const u8 = null,
    /// True wherever nobody can be asked: without a terminal, and in chat. There `yes`
    /// installs only with `digest`.
    digest_required: bool = true,
    /// The command that was typed, without `--yes` and `--digest`, for the command to run next.
    next: ?[]const u8 = null,
    ask: ?Ask = null,
};

/// True when a lock entry was installed from exactly the source that was just staged: the
/// same repository, folder and requested ref. The commit is not compared. What it resolved
/// to is compared by digest.
fn sameSource(entry: Value, staged: *const Staged) bool {
    const recorded = entry.object.get("source") orelse return false;
    for ([_][]const u8{ "type", "repo", "path" }) |key| {
        if (!std.mem.eql(u8, textOf(recorded, key) orelse return false, textOf(staged.source, key) orelse return false)) return false;
    }
    const was = textOf(recorded, "ref");
    const now = textOf(staged.source, "ref");
    if (was == null or now == null) return was == null and now == null;
    return std.mem.eql(u8, was.?, now.?);
}

/// The answer to an admission: the inspection, what happened, and the installed
/// `NAME@VERSION` to run when there is one.
fn admitted(a: Allocator, staged: *const Staged, status: []const u8) !Value {
    var result = try answer(a, staged, status);
    try result.object.put(a, "package", string(try std.fmt.allocPrint(a, "{s}@{s}", .{ staged.name(), staged.version() })));
    return result;
}

/// `fh run ADDRESS`, up to the point where there is an installed package to run. It
/// fetches the address and then:
///
///   `ready`                  this exact source is installed with this digest: nothing to ask
///   `installed`, `unchanged` it was confirmed, and installed exactly as `fh add` installs
///   `confirmation_required`  nothing was installed: the inspection, and `next_command`
///   `declined`               the person said no
///
/// The answer has `package`, the installed NAME@VERSION, whenever there is one to run.
/// An install that would be refused (a version that would change, a case collision, a
/// digest that is not the one asked for) is refused here, before anything runs.
pub fn admit(a: Allocator, io: Io, profile: []const u8, request: RunRequest, options: Options, note: *?[]const u8) !Value {
    if (request.digest) |digest| try checkDigest(digest);
    const address = try packageAddress(a, io, request.argument, note);
    try sweepFetches(a, io, profile);
    var staged = try stageGithub(a, a, io, profile, address, options, note);
    defer staged.deinit();
    if (request.digest) |digest| try expectDigest(a, &staged, digest, note);
    const entries = try readLock(a, io, profile);
    const decided = try planIn(a, entries, &staged, note);
    if (decided == .unchanged and sameSource(entries[findExact(entries, staged.name(), staged.version()).?], &staged)) return admitted(a, &staged, "ready");
    // Where nobody can be asked, only the digest ties the install to what was inspected.
    var confirmed = request.yes and (request.digest != null or !request.digest_required);
    if (!confirmed) if (request.ask) |ask| {
        if (!try ask.askFn(ask.context, a, try inspect(a, &staged))) return answer(a, &staged, "declined");
        confirmed = true;
    };
    if (!confirmed) {
        var asked = try answer(a, &staged, "confirmation_required");
        try asked.object.put(a, "next_command", string(try std.fmt.allocPrint(a, "{s} --yes --digest {s}", .{ request.next orelse try std.fmt.allocPrint(a, "fh run {s}", .{try shellWord(a, request.argument)}), staged.pkg.digest })));
        return asked;
    }
    return admitted(a, &staged, if (try commit(a, io, profile, &staged, note) == .install) "installed" else "unchanged");
}

/// Fetches the package at a GitHub address for `fh check`. Nothing is installed.
pub fn fetchPackage(owner: Allocator, io: Io, profile: []const u8, argument: []const u8, options: Options, note: *?[]const u8) !*package.Package {
    var scratch = std.heap.ArenaAllocator.init(owner);
    defer scratch.deinit();
    const a = scratch.allocator();
    var explained: ?[]const u8 = null;
    const staged = fetchIn(owner, a, io, profile, argument, options, &explained) catch |err| {
        if (explained orelse explain(err)) |message| note.* = owner.dupe(u8, message) catch null;
        return err;
    };
    return staged.pkg;
}
fn fetchIn(owner: Allocator, a: Allocator, io: Io, profile: []const u8, argument: []const u8, options: Options, note: *?[]const u8) !Staged {
    const address = try packageAddress(a, io, argument, note);
    try sweepFetches(a, io, profile);
    return stageGithub(owner, a, io, profile, address, options, note);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const test_manifest = "{\"format\":\"loops/0.1\",\"name\":\"counter\",\"version\":\"1.0.0\",\"inputs\":{\"schema\":{\"type\":\"integer\"}},\"steps\":[{\"id\":\"one\",\"kind\":\"code\",\"runtime\":\"python3\",\"file\":\"one.py\",\"requires\":[],\"input\":{\"from\":\"/input\"},\"output\":{\"schema\":true}},{\"id\":\"ask\",\"kind\":\"infer\",\"instructions\":\"Say.\",\"requires\":[\"browser\"],\"input\":{},\"output\":{\"schema\":true}}],\"output\":{\"from\":\"/steps/one/output\"}}";

pub const TestProfile = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8 = "",
    profile: []const u8 = "",
    pub fn init(self: *TestProfile) !void {
        const io = testing.io;
        self.tmp = testing.tmpDir(.{ .iterate = true });
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const a = self.arena.allocator();
        self.root = try self.tmp.dir.realPathFileAlloc(io, ".", a);
        try self.tmp.dir.createDir(io, "profile", .fromMode(0o700));
        self.profile = try std.fs.path.join(a, &.{ self.root, "profile" });
    }
    pub fn deinit(self: *TestProfile) void {
        self.arena.deinit();
        self.tmp.cleanup();
    }
    /// A package folder beside the profile, with its absolute path.
    pub fn folder(self: *TestProfile, name: []const u8, manifest: []const u8, code: []const u8) ![]const u8 {
        const io = testing.io;
        try self.tmp.dir.createDirPath(io, name);
        var dir = try self.tmp.dir.openDir(io, name, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "loop.json", .data = manifest });
        try dir.writeFile(io, .{ .sub_path = "one.py", .data = code });
        return std.fs.path.join(self.arena.allocator(), &.{ self.root, name });
    }
    pub fn add(self: *TestProfile, source: []const u8, note: *?[]const u8) !Value {
        return install(self.arena.allocator(), testing.io, self.profile, .{ .argument = source, .yes = true }, .{}, note);
    }
};

fn versioned(a: Allocator, version: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, test_manifest, "\"version\":\"1.0.0\"", try std.fmt.allocPrint(a, "\"version\":\"{s}\"", .{version}));
}

test "native package address parses owner, repo, folder and ref, and refuses anything git could misread" {
    const plain = try parseGithub("acme/loops");
    try testing.expectEqualStrings("acme", plain.owner);
    try testing.expectEqualStrings("loops", plain.repo);
    try testing.expectEqualStrings("", plain.path);
    try testing.expect(plain.ref == null);
    const full = try parseGithub("acme/loops.kit/tools/triage@feat/next@2");
    try testing.expectEqualStrings("loops.kit", full.repo);
    try testing.expectEqualStrings("tools/triage", full.path);
    try testing.expectEqualStrings("feat/next@2", full.ref.?);
    try testing.expectEqualStrings("v1.2.0", (try parseGithub("acme/loops@v1.2.0")).ref.?);
    const url = try githubUrl(testing.allocator, full);
    defer testing.allocator.free(url);
    try testing.expectEqualStrings("https://github.com/acme/loops.kit.git", url);
    for ([_][]const u8{ "", "acme", "acme/", "/loops", "acme/loops/", "acme/loops//x", "acme/loops/../x", "acme/loops/./x", "acme/loops@", "acme/loops@-upload-pack=x", "acme/loops@a..b", "acme/loops@a b", "acme/loops@a:b", "-acme/loops", "acme/-loops", "acme/..", "ac me/loops", "acme/loops/-x", "https://github.com/acme/loops" }) |bad| try testing.expectError(error.InvalidAddress, parseGithub(bad));
}

test "native package argument with no slash and no leading dot is always an installed name, whatever is on disk" {
    const io = testing.io;
    for ([_][]const u8{ "./loops/carry-counter", "./counter", "../counter", ".hidden", "/absolute/missing", "" }) |path| try testing.expectEqual(Kind.path, classify(path));
    // The tests run from the checkout, where ./loops, ./docs and ./build.zig exist. They are names all the same.
    for ([_][]const u8{ "loops", "docs", "build.zig", "counter-that-is-not-a-folder", "counter@1.0.0" }) |name| try testing.expectEqual(Kind.name, classify(name));
    const named = try parseReference("counter@1.0.0+build");
    try testing.expectEqualStrings("counter", named.name);
    try testing.expectEqualStrings("1.0.0+build", named.version.?);
    try testing.expect((try parseReference("counter")).version == null);
    for ([_][]const u8{ "", "@1", "counter@", "a b", "-counter", "counter@../x", "counter@1@2" }) |bad| try testing.expectError(error.InvalidPackageReference, parseReference(bad));

    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    // Not installed: the local folder of that name is never loaded, and the message says how to mean it.
    try testing.expectError(error.PackageNotInstalled, open(a, io, t.profile, "loops", &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "No installed package is named loops.") != null);
    try testing.expect(std.mem.indexOf(u8, note.?, "write ./loops") != null);
    try testing.expect(std.mem.indexOf(u8, note.?, "\u{2014}") == null);
    note = null;
    try testing.expectError(error.PackageNotInstalled, open(a, io, t.profile, "no-such-thing-here", &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "./") == null);
    // Installed: the installed package loads, with the local folder still there.
    const done = try t.add(try t.folder("one", try std.mem.replaceOwned(u8, a, test_manifest, "\"counter\"", "\"loops\""), "print(1)\n"), &note);
    for ([_][]const u8{ "loops", "loops@1.0.0" }) |argument| {
        const pkg = try open(testing.allocator, io, t.profile, argument, &note);
        defer pkg.deinit();
        try testing.expectEqualStrings(textOf(done, "digest").?, pkg.digest);
        try testing.expect(std.mem.startsWith(u8, pkg.root, t.profile));
    }
}

test "native package argument grammar: a leading dot or slash is a path, no slash is an installed name, anything else is a GitHub address" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { text: []const u8, kind: Kind };
    for ([_]Case{
        .{ .text = "./x", .kind = .path },
        .{ .text = "./a/b", .kind = .path },
        .{ .text = "../x", .kind = .path },
        .{ .text = "/abs/x", .kind = .path },
        .{ .text = ".hidden", .kind = .path },
        .{ .text = "", .kind = .path },
        .{ .text = "x", .kind = .name },
        .{ .text = "x@1.0", .kind = .name },
        .{ .text = "build.zig", .kind = .name },
        .{ .text = "a/b", .kind = .address },
        .{ .text = "a/b@main", .kind = .address },
        .{ .text = "a/b/c", .kind = .address },
        .{ .text = "a/b/c/d@v1.2.0", .kind = .address },
        .{ .text = "a/b@feat/next", .kind = .address },
        .{ .text = "a/b/", .kind = .address },
        .{ .text = "x@feat/next", .kind = .address },
        // A folder of this spelling is in the checkout the tests run from. Its text is still an address.
        .{ .text = "loops/warm-context", .kind = .address },
        .{ .text = "loops/warm-context/", .kind = .address },
    }) |case| try testing.expectEqual(case.kind, classify(case.text));

    var note: ?[]const u8 = null;
    const root = try packageAddress(a, io, "acme/loops", &note);
    try testing.expectEqualStrings("acme", root.owner);
    try testing.expectEqualStrings("loops", root.repo);
    try testing.expectEqualStrings("", root.path);
    try testing.expect(root.ref == null);
    const full = try packageAddress(a, io, "acme/loops/tools/triage@feat/next", &note);
    try testing.expectEqualStrings("tools/triage", full.path);
    try testing.expectEqualStrings("feat/next", full.ref.?);
    try testing.expectEqualStrings("v2", (try packageAddress(a, io, "acme/loops@v2", &note)).ref.?);
    // Text that has a slash and is not an address is refused, and the message says how to mean a folder.
    for ([_][]const u8{ "acme/loops/", "acme/loops/tools/", "x@feat/next", "acme/loops/../x", "loops/warm-context/" }) |bad| {
        note = null;
        try testing.expectError(error.InvalidAddress, packageAddress(a, io, bad, &note));
        try testing.expect(std.mem.indexOf(u8, note.?, try std.fmt.allocPrint(a, "write ./{s}.", .{bad})) != null);
    }
    // Both readings exist: the text is an address, and that relative path is in the current
    // directory. Neither is picked.
    for ([_][2][]const u8{ .{ "loops/warm-context", "folder" }, .{ "loops/warm-context/loop.json", "file" } }) |both| {
        note = null;
        try testing.expectError(error.PackageAmbiguous, packageAddress(a, io, both[0], &note));
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} reads as a GitHub address and is also a {s} in the current directory, so fh will not guess which you mean: write ./{s} to use the {s}.", .{ both[0], both[1], both[0], both[1] }), note.?);
        note = null;
        try testing.expectError(error.PackageAmbiguous, open(a, io, "/nonexistent-profile", both[0], &note));
        try testing.expect(std.mem.indexOf(u8, note.?, "fh will not guess") != null);
    }
    try testing.expectEqualStrings("package_ambiguous", errorCode(error.PackageAmbiguous).?);
    // The same text with ./ is the folder, and loads.
    const local = try open(testing.allocator, io, "/nonexistent-profile", "./loops/warm-context", &note);
    local.deinit();
    // An address with nothing of that spelling here is an address. Loading never fetches one.
    note = null;
    try testing.expectError(error.PackageAddress, open(a, io, "/nonexistent-profile", "acme/loops/tools/triage", &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "nothing here may fetch or install a package") != null);
    try testing.expect(std.mem.indexOf(u8, note.?, "\u{2014}") == null);
}

const Answers = struct {
    reply: bool,
    asked: usize = 0,
    fn ask(raw: *anyopaque, _: Allocator, inspection: Value) anyerror!bool {
        const self: *Answers = @ptrCast(@alignCast(raw));
        self.asked += 1;
        try testing.expect(textOf(inspection, "digest") != null);
        return self.reply;
    }
};

test "native package run of a GitHub address inspects first, installs only what was inspected, and asks nothing for a source that is already installed" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var remote: TestRemote = .{ .t = &t };
    try remote.init();
    _ = try t.folder("work/tools/counter", test_manifest, "print(1)\n");
    const first = try remote.push("main");
    var note: ?[]const u8 = null;
    const address = "acme/loops/tools/counter";

    // Nobody to ask and no digest: the inspection, the command to run next, and nothing installed.
    const asked = try admit(a, io, t.profile, .{ .argument = address }, remote.options(), &note);
    try testing.expectEqualStrings("confirmation_required", textOf(asked, "status").?);
    try testing.expectEqualStrings(first, textOf(asked.object.get("source").?, "commit").?);
    const digest = textOf(asked, "digest").?;
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "fh run {s} --yes --digest {s}", .{ address, digest }), textOf(asked, "next_command").?);
    try testing.expect(asked.object.get("package") == null);
    // The command that was typed comes back whole.
    const typed = try admit(a, io, t.profile, .{ .argument = address, .next = "/run acme/loops/tools/counter --driver agent" }, remote.options(), &note);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "/run acme/loops/tools/counter --driver agent --yes --digest {s}", .{digest}), textOf(typed, "next_command").?);
    // --yes alone is not enough where nobody can be asked.
    try testing.expectEqualStrings("confirmation_required", textOf(try admit(a, io, t.profile, .{ .argument = address, .yes = true }, remote.options(), &note), "status").?);
    // A digest that is not the one inspected is refused.
    try testing.expectError(error.PackageDigestMismatch, admit(a, io, t.profile, .{ .argument = address, .yes = true, .digest = "0123456789abcdef" ** 4 }, remote.options(), &note));
    try testing.expectError(error.InvalidDigest, admit(a, io, t.profile, .{ .argument = address, .yes = true, .digest = "abc" }, remote.options(), &note));
    // A person who answers no installs nothing.
    var no: Answers = .{ .reply = false };
    try testing.expectEqualStrings("declined", textOf(try admit(a, io, t.profile, .{ .argument = address, .digest_required = false, .ask = .{ .context = &no, .askFn = Answers.ask } }, remote.options(), &note), "status").?);
    try testing.expectEqual(@as(usize, 1), no.asked);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/" ++ lock_name, .{}));
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages/counter", .{}));

    // The digest that was inspected installs, and the answer names what to run.
    const done = try admit(a, io, t.profile, .{ .argument = address, .yes = true, .digest = digest }, remote.options(), &note);
    try testing.expectEqualStrings("installed", textOf(done, "status").?);
    try testing.expectEqualStrings("counter@1.0.0", textOf(done, "package").?);
    const entry = (try readLock(a, io, t.profile))[0];
    try testing.expectEqualStrings("github", textOf(entry.object.get("source").?, "type").?);
    try testing.expectEqualStrings(digest, textOf(entry, "digest").?);
    {
        const pkg = try open(testing.allocator, io, t.profile, textOf(done, "package").?, &note);
        defer pkg.deinit();
        try testing.expectEqualStrings(digest, pkg.digest);
    }

    // The same source again: nothing to ask, with or without --yes, and nobody is asked.
    var never: Answers = .{ .reply = false };
    for ([_]RunRequest{ .{ .argument = address }, .{ .argument = address, .yes = true }, .{ .argument = address, .digest_required = false, .ask = .{ .context = &never, .askFn = Answers.ask } } }) |request| {
        const again = try admit(a, io, t.profile, request, remote.options(), &note);
        try testing.expectEqualStrings("ready", textOf(again, "status").?);
        try testing.expectEqualStrings("counter@1.0.0", textOf(again, "package").?);
    }
    try testing.expectEqual(@as(usize, 0), never.asked);
    // A digest that is asked for still has to be the one fetched.
    try testing.expectError(error.PackageDigestMismatch, admit(a, io, t.profile, .{ .argument = address, .digest = "0123456789abcdef" ** 4 }, remote.options(), &note));
    // Another ref is another source, even when it resolves to the same commit.
    try testing.expectEqualStrings("confirmation_required", textOf(try admit(a, io, t.profile, .{ .argument = address ++ "@main" }, remote.options(), &note), "status").?);
    try testing.expectEqual(@as(usize, 1), (try readLock(a, io, t.profile)).len);

    // The branch moved and the version did not: refused before anything runs, whatever was confirmed.
    try t.tmp.dir.writeFile(io, .{ .sub_path = "work/tools/counter/one.py", .data = "print(2)\n" });
    _ = try remote.push("main");
    const moved = try stage(a, a, io, t.profile, address, remote.options(), &note);
    for ([_]RunRequest{ .{ .argument = address }, .{ .argument = address, .yes = true, .digest = moved.pkg.digest } }) |request| {
        note = null;
        try testing.expectError(error.PackageVersionExists, admit(a, io, t.profile, request, remote.options(), &note));
        try testing.expect(std.mem.indexOf(u8, note.?, "an installed version never changes") != null);
    }
    try testing.expectEqualStrings("print(1)\n", try t.tmp.dir.readFileAlloc(io, "profile/packages/counter/1.0.0/one.py", a, .unlimited));

    // A new version is new content: it is shown and asked about again, then installs beside the old one.
    try t.tmp.dir.writeFile(io, .{ .sub_path = "work/tools/counter/loop.json", .data = try versioned(a, "1.1.0") });
    _ = try remote.push("main");
    const newer = try admit(a, io, t.profile, .{ .argument = address }, remote.options(), &note);
    try testing.expectEqualStrings("confirmation_required", textOf(newer, "status").?);
    var sure: Answers = .{ .reply = true };
    const accepted = try admit(a, io, t.profile, .{ .argument = address, .digest_required = false, .ask = .{ .context = &sure, .askFn = Answers.ask } }, remote.options(), &note);
    try testing.expectEqualStrings("installed", textOf(accepted, "status").?);
    try testing.expectEqualStrings("counter@1.1.0", textOf(accepted, "package").?);
    try testing.expectEqual(@as(usize, 1), sure.asked);
    try testing.expectEqual(@as(usize, 2), (try readLock(a, io, t.profile)).len);

    // A name that differs only in case from an installed one is refused, as fh add refuses it.
    try t.tmp.dir.writeFile(io, .{ .sub_path = "work/tools/counter/loop.json", .data = try std.mem.replaceOwned(u8, a, test_manifest, "\"counter\"", "\"Counter\"") });
    _ = try remote.push("main");
    try testing.expectError(error.PackageCaseCollision, admit(a, io, t.profile, .{ .argument = address }, remote.options(), &note));
}

test "native package run of a GitHub address asks again when the same content was installed from somewhere else" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var remote: TestRemote = .{ .t = &t };
    try remote.init();
    const folder = try t.folder("work/tools/counter", test_manifest, "print(1)\n");
    _ = try remote.push("main");
    var note: ?[]const u8 = null;
    const local = try t.add(folder, &note);
    try testing.expectEqualStrings("installed", textOf(local, "status").?);
    const address = "acme/loops/tools/counter";
    const asked = try admit(a, io, t.profile, .{ .argument = address }, remote.options(), &note);
    try testing.expectEqualStrings("confirmation_required", textOf(asked, "status").?);
    try testing.expectEqualStrings(textOf(local, "digest").?, textOf(asked, "digest").?);
    const done = try admit(a, io, t.profile, .{ .argument = address, .yes = true, .digest = textOf(asked, "digest").? }, remote.options(), &note);
    try testing.expectEqualStrings("unchanged", textOf(done, "status").?);
    try testing.expectEqualStrings("counter@1.0.0", textOf(done, "package").?);
    // The lock still says where the installed copy came from.
    try testing.expectEqualStrings("local", textOf((try readLock(a, io, t.profile))[0].object.get("source").?, "type").?);
}

test "native package check of a GitHub address fetches the package and installs nothing" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var remote: TestRemote = .{ .t = &t };
    try remote.init();
    const folder = try t.folder("work/tools/counter", test_manifest, "print(1)\n");
    _ = try remote.push("main");
    var note: ?[]const u8 = null;
    const local = try package.load(a, io, folder);
    const fetched = try fetchPackage(testing.allocator, io, t.profile, "acme/loops/tools/counter", remote.options(), &note);
    defer fetched.deinit();
    try testing.expectEqualStrings(local.digest, fetched.digest);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/" ++ lock_name, .{}));
    var packages = try t.tmp.dir.openDir(io, "profile/packages", .{ .iterate = true });
    defer packages.close(io);
    var it = packages.iterate();
    try testing.expect(try it.next(io) == null);
    note = null;
    try testing.expectError(error.MissingManifest, fetchPackage(a, io, t.profile, "acme/loops/tools/absent", remote.options(), &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "acme/loops has no folder tools/absent at commit") != null);
    try testing.expectError(error.PackageAmbiguous, fetchPackage(a, io, t.profile, "loops/warm-context", remote.options(), &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "fh will not guess") != null);
}

test "native package source is a local folder only when it starts with a dot or a slash" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    // ./docs exists in the checkout the tests run from. Bare, it is not a folder and not an address.
    for ([_][]const u8{ "docs", "no-such-thing-here", "counter@1" }) |bare| {
        note = null;
        try testing.expectError(error.InvalidAddress, t.add(bare, &note));
        try testing.expect(std.mem.indexOf(u8, note.?, try std.fmt.allocPrint(a, "write ./{s}", .{bare})) != null);
        try testing.expect(std.mem.indexOf(u8, note.?, "\u{2014}") == null);
    }
    // ./loops/carry-counter exists too. Without a leading dot it is the address of loops/carry-counter on GitHub.
    var remote: TestRemote = .{ .t = &t };
    try remote.init();
    _ = try t.folder("work/tools/counter", test_manifest, "print(1)\n");
    _ = try remote.push("main");
    try testing.expectError(error.MissingManifest, install(a, io, t.profile, .{ .argument = "loops/carry-counter", .yes = true }, remote.options(), &note));
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));
    try testing.expectEqualStrings("installed", textOf(try install(a, io, t.profile, .{ .argument = "./loops/carry-counter", .yes = true }, remote.options(), &note), "status").?);
}

test "native package add and update remove fetch folders an interrupted fetch left, under the foreground lock, and leave a running fetch alone" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    const source = try t.folder("source", test_manifest, "print(1)\n");
    try t.tmp.dir.createDirPath(io, "profile/packages/.fetch-0123456789abcdef/objects/pack");
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/.fetch-0123456789abcdef/objects/pack/partial", .data = "half" });
    try t.tmp.dir.createDirPath(io, "profile/packages/.fetch-fedcba9876543210");
    // What a fetch in another process holds for as long as it runs.
    var running = try t.tmp.dir.openDir(io, "profile/packages/.fetch-fedcba9876543210", .{ .iterate = true });
    try testing.expectEqual(@as(c_int, 0), std.c.flock(running.handle, std.c.LOCK.EX | std.c.LOCK.NB));

    // While a run holds the foreground lock nothing is removed.
    {
        var registry = try storage.Store.init(a, io, t.profile);
        defer registry.deinit();
        const foreground = try registry.lock("foreground");
        defer foreground.close(io);
        try sweepFetches(a, io, t.profile);
        _ = try t.tmp.dir.statFile(io, "profile/packages/.fetch-0123456789abcdef/objects/pack/partial", .{});
    }

    // The next add removes the abandoned folder before it does anything else, even when it only inspects.
    const asked = try install(a, io, t.profile, .{ .argument = source }, .{}, &note);
    try testing.expectEqualStrings("confirmation_required", textOf(asked, "status").?);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages/.fetch-0123456789abcdef", .{}));
    _ = try t.tmp.dir.statFile(io, "profile/packages/.fetch-fedcba9876543210", .{});
    try testing.expectEqualStrings("installed", textOf(try t.add(source, &note), "status").?);
    _ = try t.tmp.dir.statFile(io, "profile/packages/.fetch-fedcba9876543210", .{});

    // That fetch dies without cleaning up. The next update removes what it left.
    running.close(io);
    try testing.expectEqualStrings("unchanged", textOf(try install(a, io, t.profile, .{ .updating = true, .argument = "counter" }, .{}, &note), "status").?);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages/.fetch-fedcba9876543210", .{}));
    const pkg = try open(testing.allocator, io, t.profile, "counter", &note);
    pkg.deinit();
}

test "native package versions order only when they are dot-separated numbers" {
    try testing.expectEqual(std.math.Order.gt, compareVersions("1.10.0", "1.9.3").?);
    try testing.expectEqual(std.math.Order.lt, compareVersions("2", "10").?);
    try testing.expectEqual(std.math.Order.eq, compareVersions("1.0", "1.0.0").?);
    try testing.expectEqual(std.math.Order.gt, compareVersions("18446744073709551616000", "18446744073709551615999").?);
    try testing.expect(compareVersions("1.0.0-beta", "1.0.0") == null);
    try testing.expect(compareVersions("v2", "1") == null);
    try testing.expect(compareVersions("1..2", "1") == null);
}

test "native package install from a folder writes read-only files and a private lock entry, and loads by name" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const source = try t.folder("source", test_manifest, "print(1)\n");
    var note: ?[]const u8 = null;
    // Without yes nothing is written: the answer is the inspection.
    const asked = try install(a, io, t.profile, .{ .argument = source }, .{}, &note);
    try testing.expectEqualStrings("confirmation_required", textOf(asked, "status").?);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));
    try testing.expectEqualStrings("counter", textOf(asked, "name").?);
    try testing.expectEqualStrings("loops/0.1", textOf(asked, "format").?);
    try testing.expectEqual(@as(usize, 2), asked.object.get("steps").?.array.items.len);
    try testing.expectEqualStrings("browser", asked.object.get("requires").?.array.items[0].string);
    try testing.expectEqualStrings("python3", textOf(asked.object.get("code").?.array.items[0], "runtime").?);
    const text = try describe(a, asked);
    for ([_][]const u8{ "Package   counter 1.0.0 (loops/0.1)", "  one  code  python3  one.py", "  ask  infer  requires browser", "Requires  browser", "Code      one.py (python3)", "Source    local " }) |line| try testing.expect(std.mem.indexOf(u8, text, line) != null);

    const done = try t.add(source, &note);
    try testing.expectEqualStrings("installed", textOf(done, "status").?);
    const digest = textOf(done, "digest").?;
    const file = try t.tmp.dir.statFile(io, "profile/packages/counter/1.0.0/one.py", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o400), file.permissions.toMode() & 0o777);
    const lock = try t.tmp.dir.statFile(io, "profile/packages.lock.json", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), lock.permissions.toMode() & 0o777);
    const entries = try readLock(a, io, t.profile);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings(digest, textOf(entries[0], "digest").?);
    try testing.expectEqualStrings("local", textOf(entries[0].object.get("source").?, "type").?);
    try testing.expectEqualStrings(source, textOf(entries[0].object.get("source").?, "path").?);
    try testing.expectEqual(@as(usize, 20), textOf(entries[0], "installed_at").?.len);

    // The same content again changes nothing.
    try testing.expectEqualStrings("unchanged", textOf(try t.add(source, &note), "status").?);
    try testing.expectEqual(@as(usize, 1), (try readLock(a, io, t.profile)).len);

    for ([_][]const u8{ "counter", "counter@1.0.0" }) |argument| {
        const pkg = try open(testing.allocator, io, t.profile, argument, &note);
        defer pkg.deinit();
        try testing.expectEqualStrings(digest, pkg.digest);
    }
    try testing.expectError(error.PackageNotInstalled, open(a, io, t.profile, "counter@2.0.0", &note));
    try testing.expectError(error.PackageNotInstalled, open(a, io, t.profile, "absent", &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "No installed package is named absent") != null);
    const listed = try describeList(a, try list(a, io, t.profile));
    try testing.expect(std.mem.startsWith(u8, listed, try std.fmt.allocPrint(a, "counter  1.0.0  {s}  local {s}\n", .{ digest[0..12], source })));
}

test "native package installed version is immutable, and a new version installs alongside" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    const first = try t.add(try t.folder("source", test_manifest, "print(1)\n"), &note);
    // Same name and version, different bytes.
    const changed = try t.folder("changed", test_manifest, "print(2)\n");
    try testing.expectError(error.PackageVersionExists, t.add(changed, &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "counter 1.0.0 is already installed with different content") != null);
    try testing.expect(std.mem.indexOf(u8, note.?, textOf(first, "digest").?) != null);
    try testing.expect(std.mem.indexOf(u8, note.?, "\u{2014}") == null);
    try testing.expectEqual(@as(usize, 1), (try readLock(a, io, t.profile)).len);
    // Refused before any prompt as well.
    try testing.expectError(error.PackageVersionExists, install(a, io, t.profile, .{ .argument = changed }, .{}, &note));

    // Versions that are numbers: the highest wins, whatever the install order.
    _ = try t.add(try t.folder("ten", try versioned(a, "1.10.0"), "print(10)\n"), &note);
    _ = try t.add(try t.folder("nine", try versioned(a, "1.9.0"), "print(9)\n"), &note);
    {
        const pkg = try open(testing.allocator, io, t.profile, "counter", &note);
        defer pkg.deinit();
        try testing.expectEqualStrings("1.10.0", pkg.manifest.object.get("version").?.string);
    }
    // One version that is not a number: the most recently installed wins.
    _ = try t.add(try t.folder("beta", try versioned(a, "0.1-beta"), "print(0)\n"), &note);
    {
        const pkg = try open(testing.allocator, io, t.profile, "counter", &note);
        defer pkg.deinit();
        try testing.expectEqualStrings("0.1-beta", pkg.manifest.object.get("version").?.string);
    }

    // Remove needs a version when several are installed, and then removes exactly one.
    try testing.expectError(error.PackageVersionRequired, remove(a, io, t.profile, "counter", &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "1.0.0, 1.10.0, 1.9.0, 0.1-beta") != null);
    try testing.expectEqual(@as(usize, 4), (try readLock(a, io, t.profile)).len);
    const removed = try remove(a, io, t.profile, "counter@1.0.0", &note);
    try testing.expectEqualStrings("removed", textOf(removed, "status").?);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages/counter/1.0.0", .{}));
    try testing.expectError(error.PackageNotInstalled, open(a, io, t.profile, "counter@1.0.0", &note));
    try testing.expectError(error.PackageNotInstalled, remove(a, io, t.profile, "counter@1.0.0", &note));
    // After removal the changed content installs under the same version.
    try testing.expectEqualStrings("installed", textOf(try t.add(changed, &note), "status").?);
}

test "native package load refuses an installed package whose files changed, naming both digests" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    const done = try t.add(try t.folder("source", test_manifest, "print(1)\n"), &note);
    var installed = try t.tmp.dir.openDir(io, "profile/packages/counter/1.0.0", .{});
    defer installed.close(io);
    try installed.setFilePermissions(io, "one.py", .fromMode(0o600), .{});
    try installed.writeFile(io, .{ .sub_path = "one.py", .data = "print('tampered')\n" });
    const by_path = try std.fs.path.join(a, &.{ t.profile, "packages/counter/1.0.0" });
    for ([_][]const u8{ "counter", "counter@1.0.0", by_path }) |argument| {
        note = null;
        try testing.expectError(error.InstalledPackageChanged, open(testing.allocator, io, t.profile, argument, &note));
        defer testing.allocator.free(note.?);
        try testing.expect(std.mem.indexOf(u8, note.?, "counter@1.0.0") != null);
        try testing.expect(std.mem.indexOf(u8, note.?, try std.fmt.allocPrint(a, "records digest {s}.", .{textOf(done, "digest").?})) != null);
        const now = try package.load(a, io, by_path);
        try testing.expect(std.mem.indexOf(u8, note.?, try std.fmt.allocPrint(a, "now have digest {s}.", .{now.digest})) != null);
        try testing.expect(std.mem.indexOf(u8, note.?, "\u{2014}") == null);
    }
    // An added file changes the digest too.
    try installed.setFilePermissions(io, "one.py", .fromMode(0o400), .{});
    try installed.writeFile(io, .{ .sub_path = "extra.txt", .data = "x" });
    try testing.expectError(error.InstalledPackageChanged, open(a, io, t.profile, "counter", &note));
    // A folder in the profile with no lock entry does not load.
    _ = try remove(a, io, t.profile, "counter", &note);
    try t.tmp.dir.createDirPath(io, "profile/packages/stray/1");
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/stray/1/loop.json", .data = test_manifest });
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/stray/1/one.py", .data = "" });
    try testing.expectError(error.PackageNotInstalled, open(a, io, t.profile, try std.fs.path.join(a, &.{ t.profile, "packages/stray/1" }), &note));
}

test "native package install refuses symlinks, missing manifests, files and unsafe names, and never copies .git" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    const linked = try t.folder("linked", test_manifest, "print(1)\n");
    try t.tmp.dir.symLink(io, "one.py", "linked/alias.py", .{});
    try testing.expectError(error.PackageSymlink, t.add(linked, &note));
    try t.tmp.dir.symLink(io, "linked", "pointer", .{});
    try testing.expectError(error.PackageSymlink, t.add(try std.fs.path.join(a, &.{ t.root, "pointer" }), &note));
    try t.tmp.dir.createDirPath(io, "empty");
    try t.tmp.dir.writeFile(io, .{ .sub_path = "empty/readme.md", .data = "no manifest" });
    try testing.expectError(error.MissingFile, t.add(try std.fs.path.join(a, &.{ t.root, "empty" }), &note));
    const source = try t.folder("source", test_manifest, "print(1)\n");
    try testing.expectError(error.NotAPackageFolder, t.add(try std.fs.path.join(a, &.{ source, "loop.json" }), &note));
    try testing.expectError(error.FileNotFound, t.add(try std.fs.path.join(a, &.{ t.root, "absent" }), &note));
    try testing.expectError(error.UnsafePackageName, t.add(try t.folder("spaced", try std.mem.replaceOwned(u8, a, test_manifest, "\"counter\"", "\"my counter\""), ""), &note));
    try testing.expectError(error.UnsafePackageName, t.add(try t.folder("dotted", try std.mem.replaceOwned(u8, a, test_manifest, "\"counter\"", "\"../counter\""), ""), &note));
    try testing.expectError(error.UnsafePackageVersion, t.add(try t.folder("slashed", try versioned(a, "1/2"), ""), &note));
    try testing.expectError(error.InvalidManifest, t.add(try t.folder("invalid", "{\"format\":\"loops/0.1\"}", ""), &note));
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));
    for ([_]anyerror{ error.PackageSymlink, error.MissingFile, error.NotAPackageFolder, error.UnsafePackageName, error.UnsafePackageVersion, error.InvalidManifest, error.InvalidAddress }) |err| try testing.expect(std.mem.indexOf(u8, explain(err).?, "\u{2014}") == null);

    // A package folder that is itself a repository installs without its .git.
    try t.tmp.dir.createDirPath(io, "source/.git/hooks");
    try t.tmp.dir.writeFile(io, .{ .sub_path = "source/.git/hooks/post-checkout", .data = "#!/bin/sh\n" });
    const done = try t.add(source, &note);
    try testing.expectEqual(@as(usize, 2), done.object.get("files").?.array.items.len);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages/counter/1.0.0/.git", .{}));
    const pkg = try open(testing.allocator, io, t.profile, "counter", &note);
    pkg.deinit();
}

test "native package lock file is strict: a missing file is empty and a malformed one is refused" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    try testing.expectEqual(@as(usize, 0), (try readLock(a, io, t.profile)).len);
    try testing.expectEqual(@as(usize, 0), (try list(a, io, t.profile)).object.get("packages").?.array.items.len);
    var source = object();
    try source.object.put(a, "type", string("github"));
    try source.object.put(a, "repo", string("acme/loops"));
    try source.object.put(a, "path", string("tools/triage"));
    try source.object.put(a, "ref", .null);
    try source.object.put(a, "commit", string("0123456789abcdef0123456789abcdef01234567"));
    var entry = object();
    try entry.object.put(a, "name", string("triage"));
    try entry.object.put(a, "version", string("2"));
    try entry.object.put(a, "digest", string("ab" ** 32));
    try entry.object.put(a, "source", source);
    try entry.object.put(a, "installed_at", string("2026-11-11T00:00:00Z"));
    try writeLock(a, io, t.profile, &.{entry});
    const read = try readLock(a, io, t.profile);
    try testing.expectEqual(@as(usize, 1), read.len);
    try testing.expect(schema.equal(entry, read[0]));
    const listed = try describeList(a, try list(a, io, t.profile));
    try testing.expectEqualStrings("triage  2  abababababab  github acme/loops/tools/triage@0123456789ab\n", listed);
    var buffer: [4096]u8 = undefined;
    const written = try t.tmp.dir.readFile(io, "profile/packages.lock.json", &buffer);
    try testing.expect(std.mem.startsWith(u8, written, "{\n  \"version\": 1,\n  \"packages\": [\n    {\n      \"name\": \"triage\",\n      \"version\": \"2\","));
    for ([_][]const u8{ "", "[]", "{\"version\":2,\"packages\":[]}", "{\"version\":1}", "{\"version\":1,\"packages\":[{\"name\":\"../x\",\"version\":\"1\",\"digest\":\"d\",\"source\":{\"type\":\"local\"}}]}", "{\"version\":1,\"packages\":[{\"name\":\"x\",\"version\":\"1\",\"digest\":\"d\"}]}" }) |bad| {
        try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages.lock.json", .data = bad });
        try testing.expectError(error.InvalidPackagesLock, readLock(a, io, t.profile));
    }
}

test "native package git argv is a shallow blobless fetch with hooks, submodules, LFS and prompts off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const safety = "git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.askPass= -c credential.interactive=false -c fetch.recurseSubmodules=false -c submodule.recurse=false -c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false -c gc.auto=0 -c maintenance.auto=false -c fetch.fsckObjects=true ";
    const revision = "0123456789abcdef0123456789abcdef01234567";
    const cases = [_]struct { step: GitStep, expected: []const u8 }{
        .{ .step = .init, .expected = "init --quiet --bare --template= --end-of-options /r" },
        .{ .step = .{ .remote = "https://github.com/acme/loops.git" }, .expected = "--git-dir=/r remote add --end-of-options origin https://github.com/acme/loops.git" },
        .{ .step = .{ .fetch = "HEAD" }, .expected = "--git-dir=/r fetch --quiet --depth 1 --no-tags --no-recurse-submodules --filter=blob:none --end-of-options origin HEAD" },
        .{ .step = .resolve, .expected = "--git-dir=/r rev-parse --verify --quiet --end-of-options FETCH_HEAD^{commit}" },
        .{ .step = .{ .tree = .{ .commit = revision, .path = "tools/triage" } }, .expected = "--git-dir=/r ls-tree -r -z --end-of-options " ++ revision ++ ":tools/triage" },
        .{ .step = .{ .tree = .{ .commit = revision, .path = "" } }, .expected = "--git-dir=/r ls-tree -r -z --end-of-options " ++ revision ++ "^{tree}" },
        .{ .step = .{ .blobs = &.{ "aa", "bb" } }, .expected = "-c fetch.negotiationAlgorithm=noop --git-dir=/r fetch --quiet --no-tags --no-write-fetch-head --no-recurse-submodules --filter=blob:none --end-of-options origin aa bb" },
        .{ .step = .{ .blob = "aa" }, .expected = "--git-dir=/r cat-file --end-of-options blob aa" },
    };
    for (cases) |case| try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}{s}", .{ safety, case.expected }), try std.mem.join(a, " ", try gitArgv(a, "/r", case.step)));
    // No step relies on git finding the repository from a directory: -C is never used.
    for (cases) |case| for (try gitArgv(a, "/r", case.step)) |arg| try testing.expect(!std.mem.eql(u8, arg, "-C"));
    // No step checks anything out, and none names a credential.
    for (cases) |case| for (try gitArgv(a, "/r", case.step)) |word| {
        try testing.expect(!std.mem.eql(u8, word, "checkout") and !std.mem.eql(u8, word, "clone") and !std.mem.eql(u8, word, "pull"));
        try testing.expect(std.ascii.indexOfIgnoreCase(word, "token") == null and std.ascii.indexOfIgnoreCase(word, "password") == null);
    };
}

/// A bare repository in the test's temp directory, reached through a file:// URL. Skips
/// when this machine has no git.
pub const TestRemote = struct {
    t: *TestProfile,
    url: []const u8 = "",
    environment: std.process.Environ.Map = undefined,
    fn git(self: *TestRemote, cwd: []const u8, argv: []const []const u8) ![]const u8 {
        const a = self.t.arena.allocator();
        var full: std.ArrayList([]const u8) = .empty;
        try full.appendSlice(a, &.{ "git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", "-C", cwd });
        try full.appendSlice(a, argv);
        const result = std.process.run(a, testing.io, .{ .argv = full.items, .environ_map = &self.environment }) catch return error.SkipZigTest;
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("test git {s} failed: {s}\n", .{ argv[0], result.stderr });
            return error.TestGitFailed;
        }
        return std.mem.trim(u8, result.stdout, " \r\n");
    }
    pub fn init(self: *TestRemote) !void {
        const io = testing.io;
        const a = self.t.arena.allocator();
        self.environment = try inherited(a);
        // The fixture repository ignores this machine's own git configuration.
        try self.environment.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try self.environment.put("GIT_CONFIG_NOSYSTEM", "1");
        try self.t.tmp.dir.createDirPath(io, "work");
        _ = try self.git(self.t.root, &.{ "init", "--quiet", "work" });
        _ = try self.git(self.t.root, &.{ "init", "--quiet", "--bare", "remote.git" });
        const remote = try std.fs.path.join(a, &.{ self.t.root, "remote.git" });
        // What github.com allows: partial fetches, and fetching a named object.
        _ = try self.git(remote, &.{ "config", "uploadpack.allowFilter", "true" });
        _ = try self.git(remote, &.{ "config", "uploadpack.allowAnySHA1InWant", "true" });
        self.url = try std.fmt.allocPrint(a, "file://{s}", .{remote});
    }
    /// Commits the work tree as it stands, pushes it to `branch`, and returns the commit.
    pub fn push(self: *TestRemote, branch: []const u8) ![]const u8 {
        const a = self.t.arena.allocator();
        const work = try std.fs.path.join(a, &.{ self.t.root, "work" });
        _ = try self.git(work, &.{ "add", "--all" });
        _ = try self.git(work, &.{ "commit", "--quiet", "--message", "fixture" });
        _ = try self.git(work, &.{ "push", "--quiet", "--force", self.url, try std.fmt.allocPrint(a, "HEAD:refs/heads/{s}", .{branch}) });
        return self.git(work, &.{ "rev-parse", "HEAD" });
    }
    pub fn options(self: *TestRemote) Options {
        return .{ .remote_url = self.url, .environment = &.{ .{ "GIT_CONFIG_GLOBAL", "/dev/null" }, .{ "GIT_CONFIG_NOSYSTEM", "1" } } };
    }
};

test "native package install from a git remote fetches one folder at an exact commit and executes nothing" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var remote: TestRemote = .{ .t = &t };
    try remote.init();
    _ = try t.folder("work/tools/counter", test_manifest, "print(1)\n");
    try t.tmp.dir.writeFile(io, .{ .sub_path = "work/unrelated.txt", .data = "not part of the package" });
    // A filter and attributes that would rewrite files, or run a program, on checkout.
    try t.tmp.dir.writeFile(io, .{ .sub_path = "work/.gitattributes", .data = "* filter=boom text eol=crlf\n" });
    const first = try remote.push("main");
    var note: ?[]const u8 = null;

    const asked = try install(a, io, t.profile, .{ .argument = "acme/loops/tools/counter" }, remote.options(), &note);
    try testing.expectEqualStrings("confirmation_required", textOf(asked, "status").?);
    try testing.expectEqualStrings("acme/loops", textOf(asked.object.get("source").?, "repo").?);
    try testing.expectEqualStrings("tools/counter", textOf(asked.object.get("source").?, "path").?);
    try testing.expect(asked.object.get("source").?.object.get("ref").? == .null);
    try testing.expectEqualStrings(first, textOf(asked.object.get("source").?, "commit").?);
    try testing.expect(std.mem.indexOf(u8, try describe(a, asked), try std.fmt.allocPrint(a, "Source    github acme/loops, folder tools/counter at commit {s} (default branch)", .{first})) != null);
    try testing.expectEqual(@as(usize, 2), asked.object.get("files").?.array.items.len);

    const done = try install(a, io, t.profile, .{ .argument = "acme/loops/tools/counter", .yes = true }, remote.options(), &note);
    try testing.expectEqualStrings("installed", textOf(done, "status").?);
    // The bytes installed are the bytes committed, whatever attributes the tree carries, so
    // the digest equals the folder's own.
    const local = try package.load(a, io, try std.fs.path.join(a, &.{ t.root, "work/tools/counter" }));
    try testing.expectEqualStrings(local.digest, textOf(done, "digest").?);
    {
        const pkg = try open(testing.allocator, io, t.profile, "counter", &note);
        defer pkg.deinit();
        try testing.expectEqualStrings(local.digest, pkg.digest);
    }
    // Only the package's files were installed, and the fetch left nothing behind.
    var packages = try t.tmp.dir.openDir(io, "profile/packages", .{ .iterate = true });
    defer packages.close(io);
    var it = packages.iterate();
    while (try it.next(io)) |entry| try testing.expectEqualStrings("counter", entry.name);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages/counter/1.0.0/unrelated.txt", .{}));
    const entry = (try readLock(a, io, t.profile))[0];
    try testing.expectEqualStrings("github", textOf(entry.object.get("source").?, "type").?);
    try testing.expectEqualStrings(first, textOf(entry.object.get("source").?, "commit").?);

    // A branch, and the exact commit, both resolve to the commit that was asked for.
    try testing.expectEqualStrings("unchanged", textOf(try install(a, io, t.profile, .{ .argument = "acme/loops/tools/counter@main", .yes = true }, remote.options(), &note), "status").?);
    try testing.expectEqualStrings("unchanged", textOf(try install(a, io, t.profile, .{ .argument = try std.fmt.allocPrint(a, "acme/loops/tools/counter@{s}", .{first}), .yes = true }, remote.options(), &note), "status").?);

    // Update: same version with new bytes is refused; a new version installs alongside.
    try t.tmp.dir.writeFile(io, .{ .sub_path = "work/tools/counter/one.py", .data = "print(2)\n" });
    _ = try remote.push("main");
    try testing.expectError(error.PackageVersionExists, install(a, io, t.profile, .{ .updating = true, .argument = "counter", .yes = true }, remote.options(), &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "an installed version never changes") != null);
    try t.tmp.dir.writeFile(io, .{ .sub_path = "work/tools/counter/loop.json", .data = try versioned(a, "1.1.0") });
    const second = try remote.push("main");
    try testing.expectEqualStrings("confirmation_required", textOf(try install(a, io, t.profile, .{ .updating = true, .argument = "counter" }, remote.options(), &note), "status").?);
    const updated = try install(a, io, t.profile, .{ .updating = true, .argument = "counter", .yes = true }, remote.options(), &note);
    try testing.expectEqualStrings("installed", textOf(updated, "status").?);
    try testing.expectEqualStrings("1.1.0", textOf(updated, "version").?);
    try testing.expectEqualStrings(second, textOf(updated.object.get("source").?, "commit").?);
    try testing.expectEqual(@as(usize, 2), (try readLock(a, io, t.profile)).len);
    try testing.expectEqualStrings("unchanged", textOf(try install(a, io, t.profile, .{ .updating = true, .argument = "counter", .yes = true }, remote.options(), &note), "status").?);
    _ = try t.tmp.dir.statFile(io, "profile/packages/counter/1.0.0/one.py", .{});

    // Not a plain package: a symlink in the folder, a missing folder, a missing ref.
    try t.tmp.dir.symLink(io, "one.py", "work/tools/counter/alias.py", .{});
    _ = try remote.push("linked");
    try testing.expectError(error.PackageSymlink, install(a, io, t.profile, .{ .argument = "acme/loops/tools/counter@linked", .yes = true }, remote.options(), &note));
    try testing.expectError(error.MissingManifest, install(a, io, t.profile, .{ .argument = "acme/loops/tools/absent", .yes = true }, remote.options(), &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "acme/loops has no folder tools/absent at commit") != null);
    try testing.expectError(error.MissingManifest, install(a, io, t.profile, .{ .argument = "acme/loops", .yes = true }, remote.options(), &note));
    try testing.expectError(error.GitFetchFailed, install(a, io, t.profile, .{ .argument = "acme/loops/tools/counter@no-such-branch", .yes = true }, remote.options(), &note));
    try testing.expect(std.mem.startsWith(u8, note.?, "git could not fetch acme/loops at no-such-branch. Nothing was installed. git said: "));
    try testing.expectEqual(@as(usize, 2), (try readLock(a, io, t.profile)).len);
}

test "native package add with a digest installs only that digest, and the inspection gives the command to run next" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    const source = try t.folder("source", test_manifest, "print(1)\n");
    var params = object();
    try params.object.put(a, "source", string(source));
    const asked = try command(a, io, t.profile, "add", params, .{}, &note);
    try testing.expectEqualStrings("confirmation_required", textOf(asked, "status").?);
    const digest = textOf(asked, "digest").?;
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "fh add {s} --yes --digest {s}", .{ source, digest }), textOf(asked, "next_command").?);

    // The folder changes between the inspection and the install. The inspected digest no longer matches.
    try t.tmp.dir.writeFile(io, .{ .sub_path = "source/one.py", .data = "print('swapped')\n" });
    try params.object.put(a, "yes", .{ .bool = true });
    try params.object.put(a, "digest", string(digest));
    try testing.expectError(error.PackageDigestMismatch, command(a, io, t.profile, "add", params, .{}, &note));
    const swapped = (try package.load(a, io, source)).digest;
    try testing.expect(std.mem.indexOf(u8, note.?, digest) != null and std.mem.indexOf(u8, note.?, swapped) != null);
    try testing.expect(std.mem.indexOf(u8, note.?, "Nothing was installed") != null and std.mem.indexOf(u8, note.?, "\u{2014}") == null);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));
    for ([_][]const u8{ "abc", "g" ** 64, "" }) |bad| {
        try params.object.put(a, "digest", string(bad));
        try testing.expectError(error.InvalidDigest, command(a, io, t.profile, "add", params, .{}, &note));
    }
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));

    // Chat cannot ask, so there --yes always carries the digest that was inspected.
    var chat = object();
    try chat.object.put(a, "source", string(source));
    try chat.object.put(a, "chat", .{ .bool = true });
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "/add {s} --yes --digest {s}", .{ source, swapped }), textOf(try command(a, io, t.profile, "add", chat, .{}, &note), "next_command").?);
    try chat.object.put(a, "yes", .{ .bool = true });
    try testing.expectError(error.DigestRequired, command(a, io, t.profile, "add", chat, .{}, &note));
    try testing.expect(std.mem.indexOf(u8, explain(error.DigestRequired).?, "--digest") != null);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));
    try chat.object.put(a, "digest", string(swapped));
    try testing.expectEqualStrings("installed", textOf(try command(a, io, t.profile, "add", chat, .{}, &note), "status").?);
    // --yes alone still installs from the command line.
    try params.object.put(a, "digest", string(swapped));
    try testing.expectEqualStrings("unchanged", textOf(try command(a, io, t.profile, "add", params, .{}, &note), "status").?);

    // Update has the same flag.
    try t.tmp.dir.writeFile(io, .{ .sub_path = "source/loop.json", .data = try versioned(a, "2.0.0") });
    var updating = object();
    try updating.object.put(a, "package", string("counter"));
    const offered = try command(a, io, t.profile, "update", updating, .{}, &note);
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "fh update counter --yes --digest {s}", .{textOf(offered, "digest").?}), textOf(offered, "next_command").?);
    try updating.object.put(a, "yes", .{ .bool = true });
    try updating.object.put(a, "digest", string(swapped));
    try testing.expectError(error.PackageDigestMismatch, command(a, io, t.profile, "update", updating, .{}, &note));
    try updating.object.put(a, "digest", string(textOf(offered, "digest").?));
    try testing.expectEqualStrings("installed", textOf(try command(a, io, t.profile, "update", updating, .{}, &note), "status").?);
}

test "native package add refuses a name or version that differs only in case from an installed one, and the installed files stay" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    const first = try t.add(try t.folder("lower", test_manifest, "print(1)\n"), &note);
    // On a file system that ignores case, packages/Counter/1.0.0 is the folder of counter 1.0.0.
    try testing.expectError(error.PackageCaseCollision, t.add(try t.folder("upper", try std.mem.replaceOwned(u8, a, test_manifest, "\"counter\"", "\"Counter\""), "print(2)\n"), &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "counter 1.0.0") != null and std.mem.indexOf(u8, note.?, "Counter") != null);
    try testing.expect(std.mem.indexOf(u8, note.?, "Nothing was changed") != null and std.mem.indexOf(u8, note.?, "\u{2014}") == null);
    // Another version of the other spelling is refused too: one spelling of a name is installed at a time.
    try testing.expectError(error.PackageCaseCollision, t.add(try t.folder("upper-two", try std.mem.replaceOwned(u8, a, try versioned(a, "2.0.0"), "\"counter\"", "\"Counter\""), "print(2)\n"), &note));
    // Versions: 1.0-rc is installed, 1.0-RC is refused.
    _ = try t.add(try t.folder("rc", try versioned(a, "1.0-rc"), "print(3)\n"), &note);
    try testing.expectError(error.PackageCaseCollision, t.add(try t.folder("RC", try versioned(a, "1.0-RC"), "print(4)\n"), &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "counter 1.0-rc") != null);
    // Refused at inspection as well, before any question.
    try testing.expectError(error.PackageCaseCollision, install(a, io, t.profile, .{ .argument = try std.fs.path.join(a, &.{ t.root, "RC" }) }, .{}, &note));
    try testing.expectEqual(@as(usize, 2), (try readLock(a, io, t.profile)).len);
    {
        const pkg = try open(testing.allocator, io, t.profile, "counter@1.0.0", &note);
        defer pkg.deinit();
        try testing.expectEqualStrings(textOf(first, "digest").?, pkg.digest);
    }
    // A name is looked up exactly as written, so another spelling never resolves to this entry.
    for ([_][]const u8{ "Counter", "Counter@1.0.0", "counter@1.0-RC" }) |other| {
        note = null;
        try testing.expectError(error.PackageNotInstalled, open(a, io, t.profile, other, &note));
        try testing.expect(std.mem.indexOf(u8, note.?, "Names and versions are matched exactly") != null);
        try testing.expectError(error.PackageNotInstalled, remove(a, io, t.profile, other, &note));
        try testing.expectError(error.PackageNotInstalled, install(a, io, t.profile, .{ .updating = true, .argument = other }, .{}, &note));
    }
    try testing.expectEqual(@as(usize, 2), (try readLock(a, io, t.profile)).len);
    _ = try t.tmp.dir.statFile(io, "profile/packages/counter/1.0.0/one.py", .{});
}

test "native package git fetch works when the user's git refuses implicit bare repositories" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var remote: TestRemote = .{ .t = &t };
    try remote.init();
    _ = try t.folder("work/tools/counter", test_manifest, "print(1)\n");
    _ = try remote.push("main");
    // A global configuration that exists only for this test.
    try t.tmp.dir.writeFile(io, .{ .sub_path = "gitconfig", .data = "[safe]\n\tbareRepository = explicit\n" });
    var note: ?[]const u8 = null;
    const done = install(a, io, t.profile, .{ .argument = "acme/loops/tools/counter", .yes = true }, .{ .remote_url = remote.url, .environment = &.{ .{ "GIT_CONFIG_GLOBAL", try std.fs.path.join(a, &.{ t.root, "gitconfig" }) }, .{ "GIT_CONFIG_NOSYSTEM", "1" } } }, &note) catch |err| {
        std.debug.print("{s}: {s}\n", .{ @errorName(err), note orelse "" });
        return err;
    };
    try testing.expectEqualStrings("installed", textOf(done, "status").?);
}

test "native package add refuses control characters in what the inspection shows, and describe escapes them" {
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    // A step id that would print a line of its own.
    const forged = try std.mem.replaceOwned(u8, a, test_manifest, "\"id\":\"one\"", "\"id\":\"one\\nRequires  no capabilities\"");
    const forged_output = try std.mem.replaceOwned(u8, a, forged, "/steps/one/output", "/input");
    try testing.expectError(error.PackageText, t.add(try t.folder("forged", forged_output, "print(1)\n"), &note));
    try testing.expect(std.mem.indexOf(u8, note.?, "step") != null and std.mem.indexOf(u8, note.?, "Nothing was installed") != null and std.mem.indexOf(u8, note.?, "\n") == null);
    try testing.expectError(error.PackageText, t.add(try t.folder("runtime", try std.mem.replaceOwned(u8, a, test_manifest, "\"python3\"", "\"python3\\u001b[2K\""), "print(1)\n"), &note));
    // A file that is in the package and never named by a step is listed too.
    const named = try t.folder("named", test_manifest, "print(1)\n");
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "named/tab\there.txt", .data = "x" });
    try testing.expectError(error.PackageText, t.add(named, &note));
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(testing.io, "profile/packages.lock.json", .{}));

    // Defence in depth: whatever reaches describe is printed on its own line, escaped.
    const asked = try install(a, testing.io, t.profile, .{ .argument = try t.folder("plain", test_manifest, "print(1)\n") }, .{}, &note);
    try asked.object.get("steps").?.array.items[0].object.put(a, "path", string("one\nRequires  no capabilities\x7f\x1b"));
    const text = try describe(a, asked);
    try testing.expect(std.mem.indexOf(u8, text, "  one\\x0aRequires  no capabilities\\x7f\\x1b  code") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\nRequires  "));
}

test "native package load refuses every path inside the profile's packages folder except an installed package's own folder" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    const done = try t.add(try t.folder("source", test_manifest, "print(1)\n"), &note);
    const other = test_manifest;
    for ([_][]const u8{ "profile/packages/.installing", "profile/packages/.fetch-0123456789abcdef", "profile/packages/counter/1.0.0/sub", "profile/packages/stray" }) |folder| {
        try t.tmp.dir.createDirPath(io, folder);
        var dir = try t.tmp.dir.openDir(io, folder, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "loop.json", .data = other });
        try dir.writeFile(io, .{ .sub_path = "one.py", .data = "print('not installed')\n" });
    }
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/counter/1.0.0/other.json", .data = other });
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/counter/loop.json", .data = other });
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/counter/one.py", .data = "print('not installed')\n" });
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/loop.json", .data = other });
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/one.py", .data = "print('not installed')\n" });
    // A link outside the profile that leads into it.
    try t.tmp.dir.symLink(io, "profile/packages", "alias", .{});
    for ([_][]const u8{
        "profile/packages",
        "profile/packages/loop.json",
        "profile/packages/.installing",
        "profile/packages/.fetch-0123456789abcdef",
        "profile/packages/stray",
        "profile/packages/counter",
        "profile/packages/counter/1.0.0/sub",
        "profile/packages/counter/1.0.0/other.json",
        "profile/packages/counter/../.installing",
        "profile/packages/counter/1.0.0/../../stray",
        "alias/.installing",
        "alias/counter/1.0.0/sub",
    }) |inside| {
        note = null;
        const outcome = open(a, io, t.profile, try std.fs.path.join(a, &.{ t.root, inside }), &note);
        if (outcome) |_| {
            std.debug.print("{s} loaded\n", .{inside});
            return error.TestExpectedError;
        } else |err| {
            if (err != error.InstalledPackagePath) std.debug.print("{s}: {s}\n", .{ inside, @errorName(err) });
            try testing.expectEqual(error.InstalledPackagePath, err);
        }
        try testing.expect(std.mem.indexOf(u8, note.?, "NAME or NAME@VERSION") != null and std.mem.indexOf(u8, note.?, "\u{2014}") == null);
    }
    // The installed folder itself still loads, and its digest is checked: sub and other.json changed it.
    try testing.expectError(error.InstalledPackageChanged, open(a, io, t.profile, try std.fs.path.join(a, &.{ t.profile, "packages/counter/1.0.0" }), &note));
    try t.tmp.dir.deleteTree(io, "profile/packages/counter/1.0.0/sub");
    try t.tmp.dir.deleteFile(io, "profile/packages/counter/1.0.0/other.json");
    // Its own manifest by file path is the same package: that is how a retry names it.
    for ([_][]const u8{ "profile/packages/counter/1.0.0", "profile/packages/counter/1.0.0/loop.json", "alias/counter/1.0.0", "profile/packages/stray/../counter/1.0.0" }) |root| {
        const pkg = try open(testing.allocator, io, t.profile, try std.fs.path.join(a, &.{ t.root, root }), &note);
        defer pkg.deinit();
        try testing.expectEqualStrings(textOf(done, "digest").?, pkg.digest);
    }
}

test "native package load decides what is inside the profile's packages folder by file identity, not by how the path is spelled" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    const source = try t.folder("source", test_manifest, "print(1)\n");
    // A profile with no packages folder has nothing inside it: an ordinary folder loads.
    {
        const pkg = try open(testing.allocator, io, t.profile, source, &note);
        pkg.deinit();
    }
    const done = try t.add(source, &note);

    // The same folders, reached by a path that is not the profile's own text. On macOS the data
    // volume is also mounted at /System/Volumes/Data, and realpath(3) keeps that prefix. No
    // spelling of this kind exists without privileges elsewhere (a second mount of the folder),
    // so on another system, or where the prefix does not lead here, these cases do not run.
    const alias = try std.fs.path.join(a, &.{ "/System/Volumes/Data", t.root });
    const here = (try identityAt(std.c.AT.FDCWD, try a.dupeZ(u8, t.root))).?;
    const there = (try identityAt(std.c.AT.FDCWD, try a.dupeZ(u8, alias)));
    if (there == null or there.?.dev != here.dev or there.?.ino != here.ino) {
        std.debug.print("SKIPPED: {s} is not another path to the test profile on this system, so the packages folder was not checked through a second spelling\n", .{alias});
        return;
    }
    const locked = try std.fs.path.join(a, &.{ alias, "profile/packages/counter/1.0.0" });
    var wrong = false;
    // Unchanged, the installed folder and its manifest load, as they do by their usual path.
    for ([_][]const u8{ locked, try std.fs.path.join(a, &.{ locked, "loop.json" }) }) |argument| {
        const pkg = try open(testing.allocator, io, t.profile, argument, &note);
        defer pkg.deinit();
        try testing.expectEqualStrings(textOf(done, "digest").?, pkg.digest);
    }
    // A folder with no lock entry.
    try t.tmp.dir.createDirPath(io, "profile/packages/ghost/9");
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/ghost/9/loop.json", .data = test_manifest });
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/ghost/9/one.py", .data = "print('not installed')\n" });
    // An installed file edited in place.
    try t.tmp.dir.setFilePermissions(io, "profile/packages/counter/1.0.0/one.py", .fromMode(0o600), .{});
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/counter/1.0.0/one.py", .data = "print('tampered')\n" });
    // A manifest below an installed package, and one beside its loop.json.
    try t.tmp.dir.createDirPath(io, "profile/packages/counter/1.0.0/sub");
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/counter/1.0.0/sub/loop.json", .data = test_manifest });
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/counter/1.0.0/sub/one.py", .data = "print('not installed')\n" });
    try t.tmp.dir.writeFile(io, .{ .sub_path = "profile/packages/counter/1.0.0/other.json", .data = test_manifest });
    const Case = struct { path: []const u8, expected: anyerror };
    for ([_]Case{
        .{ .path = "profile/packages/counter/1.0.0", .expected = error.InstalledPackageChanged },
        .{ .path = "profile/packages/counter/1.0.0/loop.json", .expected = error.InstalledPackageChanged },
        .{ .path = "profile/packages/ghost/9", .expected = error.PackageNotInstalled },
        .{ .path = "profile/packages/counter/1.0.0/sub", .expected = error.InstalledPackagePath },
        .{ .path = "profile/packages/counter/1.0.0/other.json", .expected = error.InstalledPackagePath },
        .{ .path = "profile/packages/counter", .expected = error.InstalledPackagePath },
        .{ .path = "profile/packages", .expected = error.InstalledPackagePath },
    }) |case| {
        note = null;
        if (open(a, io, t.profile, try std.fs.path.join(a, &.{ alias, case.path }), &note)) |_| {
            std.debug.print("{s}/{s} loaded, expected {s}\n", .{ alias, case.path, @errorName(case.expected) });
            wrong = true;
        } else |err| if (err != case.expected) {
            std.debug.print("{s}/{s}: {s}, expected {s}\n", .{ alias, case.path, @errorName(err), @errorName(case.expected) });
            wrong = true;
        }
    }
    try testing.expect(!wrong);
}

test "native package add refuses a .git folder below the top of a package, in any case, from a folder and from git" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    for ([_][]const u8{ "sub/.git", "sub/deeper/.GIT", "sub/.Git" }, 0..) |hidden, i| {
        const source = try t.folder(try std.fmt.allocPrint(a, "nested-{d}", .{i}), test_manifest, "print(1)\n");
        try t.tmp.dir.createDirPath(io, try std.fmt.allocPrint(a, "nested-{d}/{s}", .{ i, hidden }));
        try t.tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "nested-{d}/{s}/config", .{ i, hidden }), .data = "[core]\n\tfsmonitor = /tmp/run-me\n" });
        note = null;
        try testing.expectError(error.PackageGitFolder, t.add(source, &note));
        try testing.expect(std.mem.indexOf(u8, note.?, hidden) != null and std.mem.indexOf(u8, note.?, "Nothing was installed") != null);
    }
    // A file named .git (what a submodule or a linked worktree leaves) is refused the same way.
    const filed = try t.folder("filed", test_manifest, "print(1)\n");
    try t.tmp.dir.createDirPath(io, "filed/sub");
    try t.tmp.dir.writeFile(io, .{ .sub_path = "filed/sub/.git", .data = "gitdir: /elsewhere\n" });
    try testing.expectError(error.PackageGitFolder, t.add(filed, &note));
    // The top-level .git of a local folder is the repository the package sits in. It is left out, in any case.
    const top = try t.folder("top", test_manifest, "print(1)\n");
    try t.tmp.dir.createDirPath(io, "top/.GIT/hooks");
    try t.tmp.dir.writeFile(io, .{ .sub_path = "top/.GIT/hooks/post-checkout", .data = "#!/bin/sh\n" });
    try testing.expectEqual(@as(usize, 2), (try t.add(top, &note)).object.get("files").?.array.items.len);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages/counter/1.0.0/.GIT", .{}));

    // git itself will not add a .git entry, so the tree is built by hand. The fetch checks every object it receives.
    var remote: TestRemote = .{ .t = &t };
    try remote.init();
    _ = try t.folder("work", test_manifest, "print(1)\n");
    _ = try remote.push("main");
    const work = try std.fs.path.join(a, &.{ t.root, "work" });
    const script = try std.fmt.allocPrint(a,
        \\set -e
        \\cd '{s}'
        \\m=$(git hash-object -w loop.json)
        \\c=$(git hash-object -w one.py)
        \\g=$(printf '100644 blob %s\tconfig\n' "$c" | git mktree)
        \\s=$(printf '040000 tree %s\t.git\n' "$g" | git mktree)
        \\r=$(printf '100644 blob %s\tloop.json\n100644 blob %s\tone.py\n040000 tree %s\tsub\n' "$m" "$c" "$s" | git mktree)
        \\k=$(git -c user.name=t -c user.email=t@example.invalid commit-tree -m fixture "$r")
        \\git push --quiet '{s}' "$k:refs/heads/dotgit"
    , .{ work, remote.url });
    const built = try std.process.run(a, io, .{ .argv = &.{ "sh", "-c", script }, .environ_map = &remote.environment });
    if (built.term != .exited or built.term.exited != 0) {
        std.debug.print("fixture failed: {s}\n", .{built.stderr});
        return error.TestGitFailed;
    }
    try testing.expectEqualStrings("unchanged", textOf(try install(a, io, t.profile, .{ .argument = "acme/loops@main", .yes = true }, remote.options(), &note), "status").?);
    note = null;
    try testing.expectError(error.GitFetchFailed, install(a, io, t.profile, .{ .argument = "acme/loops@dotgit", .yes = true }, remote.options(), &note));
    if (std.mem.indexOf(u8, note.?, "hasDotgit") == null) std.debug.print("git said: {s}\n", .{note.?});
    try testing.expect(std.mem.indexOf(u8, note.?, "hasDotgit") != null);
}

test "native package git child environment drops what would point git at another repository or configuration, and keeps the user's own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    const dropped = [_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_SHALLOW_FILE", "GIT_GRAFT_FILE", "GIT_REPLACE_REF_BASE", "GIT_NO_REPLACE_OBJECTS", "GIT_PREFIX", "GIT_IMPLICIT_WORK_TREE", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_CONFIG_KEY_17", "GIT_CONFIG_VALUE_17", "GIT_CONFIG_PARAMETERS" };
    // Private repositories rely on these, so they stay exactly as the person set them.
    const kept = [_][]const u8{ "HOME", "PATH", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_SSH_COMMAND", "GIT_SSH", "SSH_AUTH_SOCK", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "NO_PROXY", "GIT_SSL_CAINFO", "GIT_CONFIG_KEYRING" };
    for (dropped ++ kept) |name| try environment.put(name, "set-by-the-caller");
    try gitEnvironment(&environment, .{});
    for (dropped) |name| {
        if (environment.contains(name)) std.debug.print("{s} survived\n", .{name});
        try testing.expect(!environment.contains(name));
    }
    for (kept) |name| try testing.expectEqualStrings("set-by-the-caller", environment.get(name).?);
    try testing.expectEqualStrings("0", environment.get("GIT_TERMINAL_PROMPT").?);
    try testing.expectEqualStrings("", environment.get("GIT_ASKPASS").?);
}

/// Overwrites memory as it is freed, so a value that outlives its allocation reads as garbage.
const Poison = struct {
    child: Allocator,
    fn allocator(self: *Poison) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Poison = @ptrCast(@alignCast(raw));
        return self.child.rawAlloc(len, alignment, ret);
    }
    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const self: *Poison = @ptrCast(@alignCast(raw));
        return self.child.rawResize(memory, alignment, new_len, ret);
    }
    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const self: *Poison = @ptrCast(@alignCast(raw));
        return self.child.rawRemap(memory, alignment, new_len, ret);
    }
    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Poison = @ptrCast(@alignCast(raw));
        @memset(memory, 0xaa);
        self.child.rawFree(memory, alignment, ret);
    }
};

test "native package install answer owns its text after the staged package is freed" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    var poison: Poison = .{ .child = t.arena.allocator() };
    const a = poison.allocator();
    var note: ?[]const u8 = null;
    const source = try t.folder("source", test_manifest, "print(1)\n");
    for ([_]bool{ false, true, true }, [_][]const u8{ "confirmation_required", "installed", "unchanged" }) |yes, status| {
        const answered = try install(a, io, t.profile, .{ .argument = source, .yes = yes }, .{}, &note);
        try testing.expectEqualStrings(status, textOf(answered, "status").?);
        try testing.expectEqualStrings("counter", textOf(answered, "name").?);
        try testing.expectEqualStrings("1.0.0", textOf(answered, "version").?);
        try testing.expectEqualStrings("loops/0.1", textOf(answered, "format").?);
        try testing.expectEqual(@as(usize, 64), textOf(answered, "digest").?.len);
        for (textOf(answered, "digest").?) |c| try testing.expect(std.ascii.isHex(c));
        try testing.expectEqualStrings(source, textOf(answered.object.get("source").?, "path").?);
        try testing.expectEqualStrings("loop.json", answered.object.get("files").?.array.items[0].string);
        try testing.expectEqualStrings("one", textOf(answered.object.get("steps").?.array.items[0], "path").?);
        try testing.expectEqualStrings("python3", textOf(answered.object.get("code").?.array.items[0], "runtime").?);
        try testing.expectEqualStrings("browser", answered.object.get("requires").?.array.items[0].string);
    }
}

test "native package remove takes the files before the lock entry, and an entry whose files are already gone is still removed" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var note: ?[]const u8 = null;
    const source = try t.folder("source", test_manifest, "print(1)\n");
    _ = try t.add(source, &note);
    // The files cannot be deleted: the command fails and the entry is still there.
    try t.tmp.dir.setFilePermissions(io, "profile/packages/counter", .fromMode(0o500), .{});
    if (remove(a, io, t.profile, "counter", &note)) |_| return error.TestExpectedError else |_| {}
    try testing.expectEqual(@as(usize, 1), (try readLock(a, io, t.profile)).len);
    try t.tmp.dir.setFilePermissions(io, "profile/packages/counter", .fromMode(0o700), .{});
    // The version folder is gone, then the whole packages folder is gone. Remove still clears the entry and says so.
    try t.tmp.dir.deleteTree(io, "profile/packages/counter/1.0.0");
    const first = try remove(a, io, t.profile, "counter", &note);
    try testing.expectEqualStrings("removed", textOf(first, "status").?);
    try testing.expect(first.object.get("files_missing").?.bool);
    try testing.expectEqual(@as(usize, 0), (try readLock(a, io, t.profile)).len);
    _ = try t.add(source, &note);
    try t.tmp.dir.deleteTree(io, "profile/packages");
    const second = try remove(a, io, t.profile, "counter@1.0.0", &note);
    try testing.expect(second.object.get("files_missing").?.bool);
    try testing.expectEqual(@as(usize, 0), (try readLock(a, io, t.profile)).len);
    // The ordinary case reports nothing missing.
    _ = try t.add(source, &note);
    try testing.expect(!(try remove(a, io, t.profile, "counter", &note)).object.get("files_missing").?.bool);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages/counter", .{}));
}

test "native package git fetch refuses too many files before any content, and stops at the first batch that passes the size bound" {
    const io = testing.io;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var remote: TestRemote = .{ .t = &t };
    try remote.init();
    var note: ?[]const u8 = null;
    var fetched: usize = 0;
    var options = remote.options();
    options.fetched = &fetched;

    // Nine files of a quarter of the size bound each, beside the manifest and its code file.
    _ = try t.folder("work/big", test_manifest, "print(1)\n");
    const quarter = try a.alloc(u8, package.max_bytes / 4);
    @memset(quarter, 'x');
    for (0..9) |i| {
        quarter[0] = '0' + @as(u8, @intCast(i));
        try t.tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "work/big/f{d}.bin", .{i}), .data = quarter });
    }
    // One file more than a package may hold.
    _ = try t.folder("work/many", test_manifest, "print(1)\n");
    for (0..package.max_files - 1) |i| try t.tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "work/many/n{d}.txt", .{i}), .data = "" });
    _ = try remote.push("main");

    try testing.expectError(error.PackageLimit, install(a, io, t.profile, .{ .argument = "acme/loops/many", .yes = true }, options, &note));
    try testing.expectEqual(@as(usize, 0), fetched);
    // Batches of one, two and four files: the fifth file passes the bound, and the last four are never asked for.
    try testing.expectError(error.PackageLimit, install(a, io, t.profile, .{ .argument = "acme/loops/big", .yes = true }, options, &note));
    try testing.expectEqual(@as(usize, 7), fetched);
    try testing.expectError(error.FileNotFound, t.tmp.dir.statFile(io, "profile/packages.lock.json", .{}));
    // Nothing of the fetch is left behind.
    var packages = try t.tmp.dir.openDir(io, "profile/packages", .{ .iterate = true });
    defer packages.close(io);
    var it = packages.iterate();
    try testing.expect((try it.next(io)) == null);
}

test "native Linux unavailable packages root metadata refuses ancestry instead of skipping it" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var t: TestProfile = undefined;
    try t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    // A genuine absent packages root is allowed; an unresolvable one is not.
    try testing.expectEqual(@as(?usize, null), try belowPackages(a, testing.io, t.profile, t.root));
    try t.tmp.dir.symLink(testing.io, "packages", "profile/packages", .{ .is_directory = true });
    try testing.expectError(error.PackageAncestry, belowPackages(a, testing.io, t.profile, t.root));
}
