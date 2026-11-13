//! Native-only run records. Never opens, migrates or replays the legacy JS database.
const std = @import("std");
const metadata = @import("../metadata.zig");
const runner = @import("runner.zig");
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    durable_markers: std.AutoHashMapUnmanaged([32]u8, MarkerIdentity) = .empty,
    const MarkerIdentity = struct {
        inode: u64,
        ctime: i96,
        size: u64,
        fn of(stat: std.Io.File.Stat) MarkerIdentity {
            return .{ .inode = stat.inode, .ctime = stat.ctime.nanoseconds, .size = stat.size };
        }
    };
    pub fn init(allocator: std.mem.Allocator, io: std.Io, profile: []const u8) !Store {
        var parent = try openDirectory(io, profile);
        defer parent.close(io);
        try privateHandle(parent.handle, false);
        parent.createDir(io, "native-runs", .fromMode(0o700)) catch |err| if (err != error.PathAlreadyExists) return err;
        const dir = try parent.openDir(io, "native-runs", .{ .iterate = true, .follow_symlinks = false });
        errdefer dir.close(io);
        try privateHandle(dir.handle, false);
        return .{ .allocator = allocator, .io = io, .dir = dir };
    }
    pub fn deinit(self: *Store) void {
        self.durable_markers.deinit(self.allocator);
        self.dir.close(self.io);
        self.* = undefined;
    }
    pub fn lock(self: *Store, id: []const u8) !std.Io.File {
        try validId(id);
        const name = try std.fmt.allocPrint(self.allocator, "{s}.lock", .{id});
        defer self.allocator.free(name);
        const file = self.dir.createFile(self.io, name, .{ .exclusive = true, .read = true, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
            error.PathAlreadyExists => try self.dir.openFile(self.io, name, .{ .mode = .read_write, .follow_symlinks = false }),
            else => return err,
        };
        errdefer file.close(self.io);
        try privateHandle(file.handle, true);
        if (!try file.tryLock(self.io, .exclusive)) return error.RunBusy;
        return file;
    }
    pub fn save(self: *Store, record: runner.Value) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, record, .{});
        defer self.allocator.free(bytes);
        try self.saveEncoded(try runner.text(try runner.get(record, "run_id")), bytes);
    }
    // The runner has already encoded and size-checked this exact record.
    pub fn saveEncoded(self: *Store, id: []const u8, bytes: []const u8) !void {
        try validId(id);
        if (bytes.len > 16 * 1048576) return error.HistoryLimit;
        const name = try std.fmt.allocPrint(self.allocator, "{s}.json", .{id});
        defer self.allocator.free(name);
        // The marker reaches disk before the authoritative record can change.
        // Leave it through every transition, including completion: admission
        // rechecks the final record and retires it without another terminal sync.
        const key = idKey(id);
        const pending = try std.fmt.allocPrint(self.allocator, "{s}.pending", .{id});
        defer self.allocator.free(pending);
        // Another Store may retire or replace this marker between run leases.
        // Reuse synchronization only for the same, still-present file identity.
        const durable = if (self.durable_markers.get(key)) |cached| blk: {
            const stat = self.dir.statFile(self.io, pending, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => return err,
            };
            break :blk stat.kind == .file and std.meta.eql(cached, MarkerIdentity.of(stat));
        } else false;
        if (!durable) {
            var created = true;
            const marker = self.dir.createFile(self.io, pending, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
                error.PathAlreadyExists => blk: {
                    created = false;
                    // Reject special entries before a read-only open can block.
                    if ((try self.dir.statFile(self.io, pending, .{ .follow_symlinks = false })).kind != .file) return error.UnsafeProfile;
                    const existing = try self.dir.openFile(self.io, pending, .{ .follow_symlinks = false });
                    errdefer existing.close(self.io);
                    try privateHandle(existing.handle, true);
                    break :blk existing;
                },
                else => return err,
            };
            defer marker.close(self.io);
            if (created) try marker.writeStreamingAll(self.io, pending_magic) else try self.validateMarker(marker);
            // Sync each new/replaced marker, even if a previous failed save
            // left its directory entry present but not yet durable.
            try marker.sync(self.io);
            if (metadata.syncDirectory(self.dir.handle) != 0) return error.StoreSyncFailed;
            try self.durable_markers.put(self.allocator, key, MarkerIdentity.of(try marker.stat(self.io)));
        }
        try self.writeAtomic(name, bytes);
    }
    fn writeAtomic(self: *Store, name: []const u8, bytes: []const u8) !void {
        var atomic = try self.dir.createFileAtomic(self.io, name, .{ .permissions = .fromMode(0o600), .replace = true });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        if (metadata.syncDirectory(self.dir.handle) != 0) return error.StoreSyncFailed;
    }
    pub fn load(self: *Store, allocator: std.mem.Allocator, id: []const u8) !std.json.Parsed(runner.Value) {
        try validId(id);
        const name = try std.fmt.allocPrint(self.allocator, "{s}.json", .{id});
        defer self.allocator.free(name);
        var file = try self.dir.openFile(self.io, name, .{ .follow_symlinks = false });
        defer file.close(self.io);
        try privateHandle(file.handle, true);
        var buffer: [8192]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        const bytes = try reader.interface.allocRemaining(allocator, .limited(16 * 1048576));
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(runner.Value, allocator, bytes, .{ .allocate = .alloc_always, .duplicate_field_behavior = .@"error" });
        errdefer parsed.deinit();
        if (!std.mem.eql(u8, try runner.text(try runner.get(parsed.value, "format")), "fh.native-run/0.1") or !std.mem.eql(u8, id, try runner.text(try runner.get(parsed.value, "run_id")))) return error.InvalidRunRecord;
        return parsed;
    }
    // Native records have a separate finite ceiling; never GC legacy/operator data.
    pub fn reserve(self: *Store, bytes: u64, ceiling: u64) !void {
        if (bytes > ceiling) return error.DiskLimit;
        var used: u64 = 0;
        var records: usize = 0;
        var entries: usize = 0;
        var iterator = self.dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            entries += 1;
            if (entries > 30001) return error.RegistryLimit;
            const stat = try self.dir.statFile(self.io, entry.name, .{ .follow_symlinks = false });
            if (stat.kind != .file) return error.UnsafeProfile;
            used = std.math.add(u64, used, @max(stat.size, 4096)) catch return error.DiskLimit;
            if (used > ceiling - bytes) return error.DiskLimit;
            if (std.mem.endsWith(u8, entry.name, ".json")) {
                records += 1;
                if (records >= 10000) return error.RegistryLimit;
            }
        }
    }
    // Settled IDs are only admission metadata; full JSON remains authoritative.
    // Every Store save durably marks its ID BEFORE replacing that JSON. A crash
    // at any point leaves a pending marker or an unchanged settled record.
    const pending_magic = "fh.pending/1\n";
    fn validateMarker(self: *Store, marker: std.Io.File) !void {
        var buffer: [pending_magic.len + 1]u8 = undefined;
        var reader = marker.reader(self.io, &buffer);
        const bytes = try reader.interface.take(pending_magic.len);
        if (!std.mem.eql(u8, bytes, pending_magic) or (try marker.stat(self.io)).size != pending_magic.len) return error.InvalidStoreMarker;
    }
    const index_name = "settled.index";
    const index_magic = "fh.settled/1\n";
    const max_records = 10000;
    const Index = std.AutoHashMap([32]u8, void);
    fn readIndex(self: *Store) !Index {
        var result = Index.init(self.allocator);
        errdefer result.deinit();
        // A settled index may be operator-owned: preserve unsafe entries and
        // reject them before opening (in particular, a FIFO without a writer).
        const stat = self.dir.statFile(self.io, index_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return result,
            else => return err,
        };
        if (stat.kind != .file) return error.UnsafeProfile;
        const file = self.dir.openFile(self.io, index_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return result,
            else => return err,
        };
        defer file.close(self.io);
        try privateHandle(file.handle, true);
        var buffer: [8192]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        const bytes = reader.interface.allocRemaining(self.allocator, .limited(index_magic.len + 32 + max_records * 32)) catch |err| switch (err) {
            error.StreamTooLong => return error.InvalidStoreIndex,
            else => return err,
        };
        defer self.allocator.free(bytes);
        // An unrecognized file may be operator-owned. Preserve it and reject;
        // recognized but interrupted/corrupt metadata is safe to rebuild.
        if (!std.mem.startsWith(u8, bytes, index_magic)) return error.InvalidStoreIndex;
        if (bytes.len < index_magic.len + 32) return result;
        const body = bytes[index_magic.len + 32 ..];
        if (body.len % 32 != 0) return result;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
        if (!std.mem.eql(u8, &digest, bytes[index_magic.len..][0..32])) return result;
        var offset: usize = 0;
        while (offset < body.len) : (offset += 32) {
            const entry = try result.getOrPut(body[offset..][0..32].*);
            if (entry.found_existing) {
                result.clearRetainingCapacity();
                return result;
            }
        }
        return result;
    }
    fn idKey(id: []const u8) [32]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
        return digest;
    }
    pub fn requireSettledResources(self: *Store) !void {
        try self.requireResources(false);
    }
    /// Caller holds the foreground lease. Recover abandoned records under their run leases
    /// before applying the unchanged local-resource gate. Never replay or settle effects.
    pub fn recoverAndRequireSettledResources(self: *Store) !void {
        try self.requireResources(true);
    }
    fn requireResources(self: *Store, recover_abandoned: bool) !void {
        var index = try self.readIndex();
        defer index.deinit();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var records: std.ArrayList([]const u8) = .empty;
        var pending = Index.init(alloc);
        var iterator = self.dir.iterate();
        var entries: usize = 0;
        while (try iterator.next(self.io)) |entry| {
            entries += 1;
            if (entries > 30001) return error.RegistryLimit;
            if (std.mem.endsWith(u8, entry.name, ".json")) {
                if (entry.kind != .file) return error.UnsafeProfile;
                if (records.items.len >= max_records) return error.RegistryLimit;
                const id = entry.name[0 .. entry.name.len - 5];
                try validId(id);
                try records.append(alloc, try alloc.dupe(u8, id));
            } else if (std.mem.endsWith(u8, entry.name, ".pending")) {
                const id = entry.name[0 .. entry.name.len - 8];
                try validId(id);
                if (entry.kind != .file) return error.UnsafeProfile;
                try pending.put(idKey(id), {});
            }
        }
        var body: std.ArrayList(u8) = .empty;
        var changed = records.items.len != index.count();
        for (records.items) |id| {
            const key = idKey(id);
            if (!index.contains(key) or pending.contains(key)) {
                // get/recovery takes this same lock. Never retire a marker while
                // recovery might be changing the authoritative record beneath us.
                const lease = self.lock(id) catch |err| switch (err) {
                    error.RunBusy => return if (recover_abandoned) error.RunBusy else self.busy(id),
                    else => return err,
                };
                defer lease.close(self.io);
                var record = try self.load(self.allocator, id);
                defer record.deinit();
                if (recover_abandoned and try self.recoverAbandoned(&record)) try pending.put(key, {});
                try settled(record.value);
                if (pending.contains(key)) {
                    const name = try std.fmt.allocPrint(alloc, "{s}.pending", .{id});
                    const marker = try self.dir.openFile(self.io, name, .{ .follow_symlinks = false });
                    defer marker.close(self.io);
                    try privateHandle(marker.handle, true);
                    try self.validateMarker(marker);
                    try self.dir.deleteFile(self.io, name);
                    _ = self.durable_markers.remove(key);
                    _ = pending.remove(key);
                }
                changed = true;
            }
            try body.appendSlice(alloc, &key);
        }
        // A crash between durable intent and the first record write is not
        // evidence that an effect ran, but cannot authorize automatic replay.
        if (pending.count() != 0) return error.RecoveryRequired;
        if (changed) {
            var bytes: std.ArrayList(u8) = .empty;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(body.items, &digest, .{});
            try bytes.appendSlice(alloc, index_magic);
            try bytes.appendSlice(alloc, &digest);
            try bytes.appendSlice(alloc, body.items);
            try self.writeAtomic(index_name, bytes.items);
        }
    }
    /// Caller owns this run's lease and has re-read its record under that lease.
    /// Preserve effect truth and usage: an interrupted dispatch may have reached its provider.
    pub fn recoverAbandoned(self: *Store, record: *std.json.Parsed(runner.Value)) !bool {
        const status = try runner.text(try runner.get(record.value, "status"));
        if (!std.mem.eql(u8, status, "queued") and !std.mem.eql(u8, status, "running")) return false;
        if (awaitingDriver(record.value)) return false;
        const alloc = record.arena.allocator();
        _ = record.value.object.swapRemove("output");
        try record.value.object.put(alloc, "status", .{ .string = "stopped" });
        var stop: runner.Value = .{ .object = .{} };
        try stop.object.put(alloc, "reason", .{ .string = "recovery_required" });
        try record.value.object.put(alloc, "stop", stop);
        try record.value.object.put(alloc, "recovery_required", .{ .bool = true });
        try record.value.object.put(alloc, "model_request_dispatches_complete", .{ .bool = false });
        if (record.value.object.getPtr("attempts")) |attempts| if (attempts.* == .array) for (attempts.array.items) |*attempt| {
            const state = if (attempt.* == .object) attempt.object.get("status") else null;
            if (state != null and state.? == .string and std.mem.eql(u8, state.?.string, "running")) try attempt.object.put(alloc, "status", .{ .string = "uncertain" });
        };
        try self.save(record.value);
        return true;
    }
    /// Removes the marker of a run whose record was never written: the first save writes the
    /// record before any step runs, so nothing in such a run ran.
    pub fn clearOrphanMarker(self: *Store, id: []const u8) !void {
        try validId(id);
        const record = try std.fmt.allocPrint(self.allocator, "{s}.json", .{id});
        defer self.allocator.free(record);
        if (self.dir.statFile(self.io, record, .{ .follow_symlinks = false })) |_| return error.InvalidRequest else |err| if (err != error.FileNotFound) return err;
        const name = try std.fmt.allocPrint(self.allocator, "{s}.pending", .{id});
        defer self.allocator.free(name);
        if ((try self.dir.statFile(self.io, name, .{ .follow_symlinks = false })).kind != .file) return error.UnsafeProfile;
        const marker = try self.dir.openFile(self.io, name, .{ .follow_symlinks = false });
        defer marker.close(self.io);
        try privateHandle(marker.handle, true);
        try self.validateMarker(marker);
        try self.dir.deleteFile(self.io, name);
        _ = self.durable_markers.remove(idKey(id));
        if (metadata.syncDirectory(self.dir.handle) != 0) return error.StoreSyncFailed;
    }
    /// Why a run whose lock is held cannot be admitted past. An agent-driven run with nothing
    /// in flight is only being read or stopped by another short operation (`next`, `cancel`):
    /// that is busy, and worth a retry. Anything else may be an owner that died mid-operation.
    fn busy(self: *Store, id: []const u8) anyerror {
        const record = self.load(self.allocator, id) catch return error.RecoveryRequired;
        defer record.deinit();
        const driver = if (record.value == .object) record.value.object.get("driver") else null;
        if (driver == null or driver.? != .string or !std.mem.eql(u8, driver.?.string, "agent")) return error.RecoveryRequired;
        settled(record.value) catch return error.RecoveryRequired;
        return error.RunBusy;
    }
};
/// loops/0.3 agent driver: a run that ended its last operation waiting for its agent. It is
/// still `running`, yet no process owns it and none of its work is in flight. The runner
/// clears the mark before an operation does anything, so a crash mid-operation never shows it.
pub fn awaitingDriver(record: runner.Value) bool {
    if (record != .object) return false;
    const status = record.object.get("status") orelse return false;
    const driver = record.object.get("driver") orelse return false;
    const waiting = record.object.get("awaiting_driver") orelse return false;
    return status == .string and std.mem.eql(u8, status.string, "running") and driver == .string and std.mem.eql(u8, driver.string, "agent") and waiting == .bool and waiting.bool;
}
/// An effect that holds the installation: something on this machine whose outcome is unknown.
fn holds(effect: runner.Value) !bool {
    const state = try runner.text(try runner.get(effect, "state"));
    const kind = try runner.text(try runner.get(effect, "kind"));
    return std.mem.eql(u8, state, "unknown") and (std.mem.eql(u8, kind, "code_container") or std.mem.eql(u8, kind, "code_staging") or std.mem.eql(u8, kind, "browser_cleanup") or std.mem.eql(u8, kind, "workspace_command") or std.mem.eql(u8, kind, "workspace_edit"));
}
fn settled(record: runner.Value) !void {
    const status = try runner.text(try runner.get(record, "status"));
    if ((std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "running")) and !awaitingDriver(record)) return error.RecoveryRequired;
    if (record.object.get("effects")) |effects| {
        if (effects != .array) return error.InvalidRunRecord;
        for (effects.array.items) |effect| if (try holds(effect)) return error.RecoveryRequired;
    }
}
/// What stops this installation admitting new work, in enough detail to tell a person what
/// to look at. Strings are owned by the allocator given to `inspect`.
pub const Unsettled = struct {
    run_id: []const u8,
    cause: enum { interrupted, effect, missing_record },
    effect_id: []const u8 = "",
    effect_kind: []const u8 = "",
    step: []const u8 = "",
};
fn describe(arena: std.mem.Allocator, id: []const u8, record: runner.Value) !?Unsettled {
    const status = try runner.text(try runner.get(record, "status"));
    if ((std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "running")) and !awaitingDriver(record)) return .{ .run_id = id, .cause = .interrupted };
    const effects = record.object.get("effects") orelse return null;
    if (effects != .array) return error.InvalidRunRecord;
    for (effects.array.items) |effect| if (try holds(effect)) {
        // The receipt names its step; a record from before it did still names the step it stopped at.
        var step: []const u8 = "";
        if (record.object.get("failure_step_id")) |failed| if (failed == .string) {
            step = failed.string;
        };
        if (effect.object.get("details")) |details| if (details == .object) if (details.object.get("step")) |named| if (named == .string) {
            step = named.string;
        };
        return .{ .run_id = id, .cause = .effect, .effect_id = try arena.dupe(u8, try runner.text(try runner.get(effect, "id"))), .effect_kind = try arena.dupe(u8, try runner.text(try runner.get(effect, "kind"))), .step = try arena.dupe(u8, step) };
    };
    return null;
}
/// The admission question without admission's writes: no directory, lock, index or marker is
/// made or changed, so it answers on a read-only profile. `requireSettledResources` remains
/// the authority when work is admitted; this is for `check` and for the message a refusal
/// carries. Null means nothing is unsettled.
pub fn inspect(arena: std.mem.Allocator, io: std.Io, profile: []const u8) !?Unsettled {
    var parent = try openDirectory(io, profile);
    defer parent.close(io);
    try privateHandle(parent.handle, false);
    const dir = parent.openDir(io, "native-runs", .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var store: Store = .{ .allocator = arena, .io = io, .dir = dir };
    defer store.deinit();
    try privateHandle(dir.handle, false);
    var index = try store.readIndex();
    defer index.deinit();
    var records: std.ArrayList([]const u8) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    var iterator = store.dir.iterate();
    var entries: usize = 0;
    while (try iterator.next(io)) |entry| {
        entries += 1;
        if (entries > 30001) return error.RegistryLimit;
        const suffix: []const u8 = if (std.mem.endsWith(u8, entry.name, ".json")) ".json" else if (std.mem.endsWith(u8, entry.name, ".pending")) ".pending" else continue;
        if (entry.kind != .file) return error.UnsafeProfile;
        const id = entry.name[0 .. entry.name.len - suffix.len];
        try validId(id);
        if (suffix.len == 5) {
            if (records.items.len >= Store.max_records) return error.RegistryLimit;
            try records.append(arena, try arena.dupe(u8, id));
        } else try pending.append(arena, try arena.dupe(u8, id));
    }
    for (records.items) |id| {
        var marked = false;
        for (pending.items) |*waiting| if (std.mem.eql(u8, waiting.*, id)) {
            marked = true;
            waiting.* = "";
        };
        if (index.contains(Store.idKey(id)) and !marked) continue;
        const record = try store.load(arena, id);
        if (try describe(arena, id, record.value)) |found| return found;
    }
    // A marker with no record: the run was reserved and its record never written.
    for (pending.items) |id| if (id.len != 0) return .{ .run_id = id, .cause = .missing_record };
    return null;
}
/// Whether another process holds this lock right now. Makes no file: a lock nobody has ever
/// taken has no file and is not held.
pub fn held(io: std.Io, profile: []const u8, id: []const u8) bool {
    var parent = openDirectory(io, profile) catch return false;
    defer parent.close(io);
    var name: [160]u8 = undefined;
    const path = std.fmt.bufPrint(&name, "native-runs/{s}.lock", .{id}) catch return false;
    const file = parent.openFile(io, path, .{ .follow_symlinks = false }) catch return false;
    defer file.close(io);
    return !(file.tryLock(io, .shared) catch return false);
}
pub fn validId(id: []const u8) !void {
    if (id.len == 0 or id.len > 128) return error.InvalidRunId;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidRunId;
}
pub fn privateHandle(handle: std.posix.fd_t, regular: bool) !void {
    const stat = metadata.fstat(handle) catch return error.UnsafeProfile;
    if (stat.uid != std.c.getuid() or stat.mode & 0o077 != 0 or (regular and stat.nlink != 1)) return error.UnsafeProfile;
    const kind = stat.mode & std.c.S.IFMT;
    const expected: std.c.mode_t = if (regular) std.c.S.IFREG else std.c.S.IFDIR;
    if (kind != expected) return error.UnsafeProfile;
}
/// Why the profile folder itself fails `privateHandle`, in one sentence a person can act on:
/// which folder, who can reach it, and the command that fixes it. Null when the folder is a
/// private folder of this user, so the fault is something inside it. This only describes; the
/// check is `privateHandle` and is unchanged.
pub fn unsafeProfileMessage(allocator: std.mem.Allocator, profile: []const u8) !?[]const u8 {
    const stat = metadata.fstatat(std.c.AT.FDCWD, try allocator.dupeZ(u8, profile), false) catch return null;
    if (stat.mode & std.c.S.IFMT != std.c.S.IFDIR) return try std.fmt.allocPrint(allocator, "The profile path {s} is not a folder, so fh will not use it; set FH_DATA_DIR to a folder only you can use.", .{profile});
    if (stat.uid != std.c.getuid()) return try std.fmt.allocPrint(allocator, "The profile folder {s} belongs to another user, so fh will not use it; set FH_DATA_DIR to a folder you own.", .{profile});
    const loose: u32 = @intCast(stat.mode & 0o077);
    if (loose == 0) return null;
    const who = if (loose & 0o007 != 0) "other users on this computer" else "other members of its group";
    const bits = (loose | loose >> 3) & 0o7;
    const can = if (bits & 0o6 == 0o6) "read and changed" else if (bits & 0o2 != 0) "changed" else if (bits & 0o4 != 0) "read" else "entered";
    // The command is meant to be pasted, so a path the shell would split is quoted.
    var plain = true;
    for (profile) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "/._-+@", c) == null) {
        plain = false;
    };
    const quoted = if (plain) profile else try std.fmt.allocPrint(allocator, "'{s}'", .{try std.mem.replaceOwned(u8, allocator, profile, "'", "'\\''")});
    return try std.fmt.allocPrint(allocator, "The profile folder {s} can be {s} by {s} (its permissions are {o} and fh needs 700), so fh will not use it until you run: chmod 700 {s}", .{ profile, can, who, @as(u32, @intCast(stat.mode & 0o777)), quoted });
}
/// The message for `error.UnsafeProfile`: the folder's own fault when it has one.
pub fn profileRefusal(allocator: std.mem.Allocator, profile: []const u8) ![]const u8 {
    return try unsafeProfileMessage(allocator, profile) orelse
        try std.fmt.allocPrint(allocator, "Something inside the profile folder {s} is not a private file or folder of yours (it is shared with other users, is a link, or belongs to someone else), so fh will not use it.", .{profile});
}
pub fn openDirectory(io: std.Io, path: []const u8) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidProfilePath;
    var parts = std.fs.path.componentIterator(path);
    const root = parts.root() orelse return error.InvalidProfilePath;
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    errdefer dir.close(io);
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part.name, ".") or std.mem.eql(u8, part.name, "..")) return error.InvalidProfilePath;
        const next = try dir.openDir(io, part.name, .{ .iterate = true, .follow_symlinks = false });
        dir.close(io);
        dir = next;
    }
    return dir;
}
test "native store rejects traversal identifiers" {
    try validId("run_ABC-01");
    try std.testing.expectError(error.InvalidRunId, validId("../existing"));
    try std.testing.expectError(error.InvalidRunId, validId("a/b"));
}
test "native store atomic private record roundtrip and owned run lock" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    var path: [4096]u8 = undefined;
    const len = try temporary.dir.realPath(io, &path);
    var store = try Store.init(std.testing.allocator, io, path[0..len]);
    defer store.deinit();
    const lease = try store.lock("run_fixture");
    defer lease.close(io);
    try std.testing.expectError(error.RunBusy, store.lock("run_fixture"));
    const value = try std.json.parseFromSlice(runner.Value, std.testing.allocator, "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"run_fixture\",\"status\":\"completed\",\"output\":{\"verdict\":\"fail\"}}", .{});
    defer value.deinit();
    try store.save(value.value);
    const loaded = try store.load(std.testing.allocator, "run_fixture");
    defer loaded.deinit();
    try std.testing.expectEqualStrings("completed", try runner.text(try runner.get(loaded.value, "status")));
    try std.testing.expectEqualStrings("fail", try runner.text(try runner.get(try runner.get(loaded.value, "output"), "verdict")));
}

test "native store finite admission budget preserves existing records" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.setPermissions(io, .fromMode(0o700));
    var path: [4096]u8 = undefined;
    const len = try temporary.dir.realPath(io, &path);
    var store = try Store.init(std.testing.allocator, io, path[0..len]);
    defer store.deinit();
    try store.reserve(8192, 16384);
    try store.dir.writeFile(io, .{ .sub_path = "evidence", .data = "kept" });
    try std.testing.expectError(error.DiskLimit, store.reserve(13000, 16384));
    try std.testing.expectEqual(@as(u64, 4), (try store.dir.statFile(io, "evidence", .{})).size);
}

const TestStore = struct {
    temporary: std.testing.TmpDir,
    store: Store,
    fn init() !TestStore {
        const io = std.testing.io;
        var temporary = std.testing.tmpDir(.{});
        errdefer temporary.cleanup();
        try temporary.dir.setPermissions(io, .fromMode(0o700));
        var path: [4096]u8 = undefined;
        const len = try temporary.dir.realPath(io, &path);
        return .{ .temporary = temporary, .store = try Store.init(std.testing.allocator, io, path[0..len]) };
    }
    fn deinit(self: *TestStore) void {
        self.store.deinit();
        self.temporary.cleanup();
    }
    fn record(self: *TestStore, id: []const u8, status: []const u8, effects: []const u8, legacy: bool) !void {
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"format\":\"fh.native-run/0.1\",\"run_id\":\"{s}\",\"status\":\"{s}\",\"effects\":{s}}}", .{ id, status, effects });
        defer std.testing.allocator.free(bytes);
        if (legacy) {
            const name = try std.fmt.allocPrint(std.testing.allocator, "{s}.json", .{id});
            defer std.testing.allocator.free(name);
            try self.store.dir.writeFile(self.store.io, .{ .sub_path = name, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
        } else try self.store.saveEncoded(id, bytes);
    }
    fn marker(self: *TestStore, name: []const u8, bytes: []const u8) !void {
        try self.store.dir.writeFile(self.store.io, .{ .sub_path = name, .data = bytes, .flags = .{ .permissions = .fromMode(0o600) } });
    }
};

test "native store migrates large completed history then admits with bounded memory" {
    var fixture = try TestStore.init();
    defer fixture.deinit();
    const alloc = std.testing.allocator;
    const payload = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(payload);
    @memset(payload, 'x');
    for (0..64) |i| {
        const id = try std.fmt.allocPrint(alloc, "old_{d}", .{i});
        defer alloc.free(id);
        const name = try std.fmt.allocPrint(alloc, "{s}.json", .{id});
        defer alloc.free(name);
        const bytes = try std.fmt.allocPrint(alloc, "{{\"format\":\"fh.native-run/0.1\",\"run_id\":\"{s}\",\"status\":\"completed\",\"output\":\"{s}\"}}", .{ id, payload });
        defer alloc.free(bytes);
        try fixture.marker(name, bytes);
    }
    try fixture.marker("operator-evidence", "retained");
    try fixture.store.requireSettledResources();
    // 16 MiB of old JSON cannot even load one record with this allocator.
    // Reopening the Store also proves the index survives process-local state.
    var tiny: [64 * 1024]u8 = undefined;
    var bounded = std.heap.FixedBufferAllocator.init(&tiny);
    var path: [4096]u8 = undefined;
    const len = try fixture.temporary.dir.realPath(fixture.store.io, &path);
    var reopened = try Store.init(bounded.allocator(), fixture.store.io, path[0..len]);
    defer reopened.deinit();
    try reopened.requireSettledResources();
    const original = try fixture.store.load(alloc, "old_0");
    defer original.deinit();
    try std.testing.expectEqualStrings(payload, try runner.text(try runner.get(original.value, "output")));
    try std.testing.expectEqual(@as(u64, 8), (try fixture.store.dir.statFile(fixture.store.io, "operator-evidence", .{})).size);
    try std.testing.expectError(error.DiskLimit, fixture.store.reserve(1, 16 * 1048576));
}

test "native store pending writes invalidate settled index and retain uncertain effects" {
    var fixture = try TestStore.init();
    defer fixture.deinit();
    try fixture.record("run", "completed", "[]", true);
    try fixture.store.requireSettledResources();
    for ([_][]const u8{ "queued", "running" }) |status| {
        try fixture.record("run", status, "[]", false);
        try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
    }
    for ([_][]const u8{ "code_container", "code_staging", "workspace_command", "workspace_edit" }) |kind| {
        const effects = try std.fmt.allocPrint(std.testing.allocator, "[{{\"kind\":\"{s}\",\"state\":\"unknown\"}}]", .{kind});
        defer std.testing.allocator.free(effects);
        try fixture.record("run", "stopped", effects, false);
        try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
        _ = try fixture.store.dir.statFile(fixture.store.io, "run.pending", .{});
    }
    try fixture.record("run", "completed", "[]", false);
    const lease = try fixture.store.lock("run");
    try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
    lease.close(fixture.store.io);
    try fixture.store.requireSettledResources();
    try std.testing.expectError(error.FileNotFound, fixture.store.dir.statFile(fixture.store.io, "run.pending", .{}));
    // A new, unindexed record is detected even if it came from an older binary.
    try fixture.record("legacy_new", "running", "[]", true);
    try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
}

test "native store interrupted writes and corrupt indexes recover from authoritative records" {
    var fixture = try TestStore.init();
    defer fixture.deinit();
    try fixture.record("run", "completed", "[]", true);
    try fixture.store.requireSettledResources();
    // Crash after intent but before record replacement retains original truth.
    try fixture.marker("run.pending", Store.pending_magic);
    try fixture.store.requireSettledResources();
    // Crash after record replacement but before index refresh cannot hide work.
    try fixture.record("run", "running", "[]", false);
    try fixture.marker("interrupted-index.tmp", "partial replacement");
    try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
    try fixture.record("run", "completed", "[]", false);
    try fixture.store.requireSettledResources();
    // Invalid index falls back to a bounded full scan, not presumed settlement.
    try fixture.marker(Store.index_name, Store.index_magic ++ "interrupted");
    try fixture.record("legacy_new", "running", "[]", true);
    try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
    try fixture.record("legacy_new", "completed", "[]", true);
    try fixture.store.requireSettledResources();
    var index = try fixture.store.readIndex();
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 2), index.count());
    // A marker without a first authoritative record remains fail closed.
    try fixture.marker("unwritten.pending", Store.pending_magic);
    try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
    const record = try fixture.store.load(std.testing.allocator, "run");
    defer record.deinit();
    try std.testing.expectEqualStrings("completed", try runner.text(try runner.get(record.value, "status")));
}

test "native store rejects oversized saves before altering original record or intent" {
    var fixture = try TestStore.init();
    defer fixture.deinit();
    try fixture.record("run", "completed", "[]", false);
    try fixture.store.requireSettledResources();
    const oversized = try std.testing.allocator.alloc(u8, 16 * 1048576 + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.HistoryLimit, fixture.store.saveEncoded("run", oversized));
    try std.testing.expectError(error.FileNotFound, fixture.store.dir.statFile(fixture.store.io, "run.pending", .{}));
    const record = try fixture.store.load(std.testing.allocator, "run");
    defer record.deinit();
    try std.testing.expectEqualStrings("completed", try runner.text(try runner.get(record.value, "status")));
}

test "native store preserves operator metadata collisions and enforces registry ceiling" {
    var fixture = try TestStore.init();
    defer fixture.deinit();
    try fixture.record("run", "completed", "[]", true);
    try fixture.marker(Store.index_name, "operator evidence");
    try std.testing.expectError(error.InvalidStoreIndex, fixture.store.requireSettledResources());
    try std.testing.expectEqual(@as(u64, 17), (try fixture.store.dir.statFile(fixture.store.io, Store.index_name, .{})).size);
    try fixture.marker("run.pending", "operator evidence");
    try std.testing.expectError(error.InvalidStoreMarker, fixture.record("run", "running", "[]", false));
    const original = try fixture.store.load(std.testing.allocator, "run");
    defer original.deinit();
    try std.testing.expectEqualStrings("completed", try runner.text(try runner.get(original.value, "status")));
    for (0..9999) |i| {
        const name = try std.fmt.allocPrint(std.testing.allocator, "ceiling_{d}.json", .{i});
        defer std.testing.allocator.free(name);
        try fixture.marker(name, "");
    }
    try std.testing.expectError(error.RegistryLimit, fixture.store.reserve(1, std.math.maxInt(u64)));
}

test "native store incomplete migration preserves unfinished records and checksum corruption rescans" {
    var fixture = try TestStore.init();
    defer fixture.deinit();
    try fixture.record("old", "completed", "[]", true);
    try fixture.record("unfinished", "running", "[]", true);
    try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
    try std.testing.expectError(error.FileNotFound, fixture.store.dir.statFile(fixture.store.io, Store.index_name, .{}));
    try fixture.record("unfinished", "stopped", "[{\"kind\":\"code_staging\",\"state\":\"unknown\"}]", true);
    try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
    try fixture.record("unfinished", "completed", "[]", true);
    try fixture.store.requireSettledResources();
    // A recognized index with damaged checksum is rebuilt from authoritative
    // records. An old-binary mutation of a known ID becomes visible on repair.
    try fixture.marker(Store.index_name, Store.index_magic ++ "x" ** 64);
    try fixture.record("old", "running", "[]", true);
    try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
    try fixture.record("old", "completed", "[]", true);
    try fixture.store.requireSettledResources();
    var index = try fixture.store.readIndex();
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 2), index.count());
    try fixture.store.dir.setPermissions(fixture.store.io, .fromMode(0o700));
    const oversized = try std.testing.allocator.alloc(u8, Store.index_magic.len + 32 + Store.max_records * 32 + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try fixture.marker(Store.index_name, oversized);
    try std.testing.expectError(error.InvalidStoreIndex, fixture.store.requireSettledResources());
}

test "native store reused across run leases recreates intent retired by another store" {
    var fixture = try TestStore.init();
    defer fixture.deinit();
    const io = fixture.store.io;
    var path: [4096]u8 = undefined;
    const len = try fixture.temporary.dir.realPath(io, &path);
    var other = try Store.init(std.testing.allocator, io, path[0..len]);
    defer other.deinit();
    {
        const lease = try fixture.store.lock("reused");
        defer lease.close(io);
        try fixture.record("reused", "completed", "[]", false);
    }
    try other.requireSettledResources();
    try std.testing.expectError(error.FileNotFound, other.dir.statFile(io, "reused.pending", .{}));
    {
        const lease = try fixture.store.lock("reused");
        defer lease.close(io);
        try fixture.record("reused", "running", "[]", false);
    }
    try std.testing.expectError(error.RecoveryRequired, other.requireSettledResources());
    _ = try other.dir.statFile(io, "reused.pending", .{});
    // Existence alone is not enough: replacement must invalidate the cache too.
    try fixture.store.writeAtomic("reused.pending", "operator evidence");
    {
        const lease = try fixture.store.lock("reused");
        defer lease.close(io);
        try std.testing.expectError(error.InvalidStoreMarker, fixture.record("reused", "completed", "[]", false));
    }
    const unchanged = try other.load(std.testing.allocator, "reused");
    defer unchanged.deinit();
    try std.testing.expectEqualStrings("running", try runner.text(try runner.get(unchanged.value, "status")));
}

test "native store admission tells a busy waiting agent run from an orphan" {
    var fixture = try TestStore.init();
    defer fixture.deinit();
    const io = fixture.store.io;
    try fixture.store.saveEncoded("waiting", "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"waiting\",\"status\":\"running\",\"driver\":\"agent\",\"awaiting_driver\":true,\"effects\":[]}");
    try fixture.store.requireSettledResources();
    try fixture.store.saveEncoded("waiting", "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"waiting\",\"status\":\"running\",\"driver\":\"agent\",\"awaiting_driver\":true,\"effects\":[]}");
    {
        const lease = try fixture.store.lock("waiting");
        defer lease.close(io);
        try std.testing.expectError(error.RunBusy, fixture.store.requireSettledResources());
        // The busy answer retires nothing: the marker is still there for the next admission to check.
        _ = try fixture.store.dir.statFile(io, "waiting.pending", .{});
    }
    try fixture.store.requireSettledResources();
    // In flight (no waiting mark), or not an agent's run at all: busy proves nothing.
    try fixture.store.saveEncoded("waiting", "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"waiting\",\"status\":\"running\",\"driver\":\"agent\",\"effects\":[]}");
    const lease = try fixture.store.lock("waiting");
    defer lease.close(io);
    try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
    try fixture.store.saveEncoded("waiting", "{\"format\":\"fh.native-run/0.1\",\"run_id\":\"waiting\",\"status\":\"running\",\"awaiting_driver\":true,\"effects\":[]}");
    try std.testing.expectError(error.RecoveryRequired, fixture.store.requireSettledResources());
}

test "native private handle rejects permissions hardlinks and wrong type" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(io, .fromMode(0o700));
    const file = try tmp.dir.createFile(io, "private", .{ .permissions = .fromMode(0o600) });
    defer file.close(io);
    try privateHandle(file.handle, true);
    try privateHandle(tmp.dir.handle, false);
    try std.testing.expectError(error.UnsafeProfile, privateHandle(file.handle, false));
    try std.testing.expectError(error.UnsafeProfile, privateHandle(tmp.dir.handle, true));
    try tmp.dir.setFilePermissions(io, "private", .fromMode(0o640), .{});
    try std.testing.expectError(error.UnsafeProfile, privateHandle(file.handle, true));
    try tmp.dir.setFilePermissions(io, "private", .fromMode(0o600), .{});
    try std.testing.expectEqual(@as(c_int, 0), std.c.linkat(tmp.dir.handle, "private", tmp.dir.handle, "alias", 0));
    try std.testing.expectError(error.UnsafeProfile, privateHandle(file.handle, true));
    try tmp.dir.setPermissions(io, .fromMode(0o750));
    try std.testing.expectError(error.UnsafeProfile, privateHandle(tmp.dir.handle, false));
}
