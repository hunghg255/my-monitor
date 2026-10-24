//! What can be cleaned up on this Windows user account: caches apps make
//! again, old agent sessions, installers left in Downloads, logs and old
//! temporary files, each kind in groups (npm, pip and Go's caches; Claude
//! Code's and Codex's sessions; each installer) of items (what goes: a
//! cache's entries, a file). Scanned on a thread of its own; the items
//! ticked are sent to the Recycle Bin after review. Whole-drive usage is
//! informational and never makes arbitrary folders eligible for deletion.
const std = @import("std");
const storage = @import("win_storage.zig");

const HANDLE = *anyopaque;
const BOOL = c_int;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Kind = enum { caches, package_caches, developer, agent_sessions, installers, logs, temporary };
pub const kinds = std.enums.values(Kind);

pub fn name(k: Kind) []const u8 {
    return switch (k) {
        .caches => "Caches",
        .package_caches => "Package Caches",
        .developer => "Developer",
        .agent_sessions => "Agent Sessions",
        .installers => "Installers",
        .logs => "Logs",
        .temporary => "Temporary Files",
    };
}

pub fn about(k: Kind) []const u8 {
    return switch (k) {
        .caches => "Apps make them again as they need them",
        .package_caches => "Downloads package managers fetch again as they install",
        .developer => "Project dependencies and build caches; reinstall or rebuild",
        .agent_sessions => "Claude Code's and Codex's sessions over a month old",
        .installers => "Installers and disk images left in Downloads",
        .logs => "Apps' logs and crash reports",
        .temporary => "Left by apps, unchanged for three days",
    };
}

pub const Found = struct { bytes: u64 = 0, files: u64 = 0, newest_unix: i64 = 0 };

/// Logical file sizes, with three levels of folders available to inspect.
/// These entries are informational; only the cleanup rules create checkboxes.
pub const Usage = struct {
    path: []const u8,
    found: Found,
    children: []const Usage = &.{},
    protected: bool = false,
    is_dir: bool = true,
};

pub const Drive = struct {
    volume: storage.Volume,
    entries: []const Usage = &.{},
    found: Found = .{},
    skipped: u64 = 0,
    complete: bool = false,
};

pub fn needsReview(k: Kind) bool {
    return k == .agent_sessions or k == .installers;
}

fn driveOf(path: []const u16) u8 {
    if (path.len < 3 or path[1] != ':') return 0;
    const c = fold(path[0]);
    return if (c >= 'a' and c <= 'z') @intCast(c - 32) else 0;
}

/// What a kind would remove, item by item, in its groups.
const Items = struct {
    /// Each item's path, NUL after each.
    paths: std.ArrayList(u16) = .empty,
    /// Where each item's path starts in `paths`, and what it holds.
    starts: std.ArrayList(u32) = .empty,
    found: std.ArrayList(Found) = .empty,
    /// Whether each item goes when the kind is cleaned.
    ticked: std.ArrayList(bool) = .empty,
    groups: std.ArrayList(Group) = .empty,

    fn deinit(it: *Items, gpa: std.mem.Allocator) void {
        it.paths.deinit(gpa);
        it.starts.deinit(gpa);
        it.found.deinit(gpa);
        it.ticked.deinit(gpa);
        it.groups.deinit(gpa);
    }

    /// Groups of the same name, found by different rules (a cache in
    /// three folders), made one: their items moved together, in the order
    /// the groups were first found.
    fn merge(it: *Items, gpa: std.mem.Allocator) void {
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(gpa);
        var merged: std.ArrayList(Group) = .empty;
        defer merged.deinit(gpa);
        for (it.groups.items, 0..) |g, gi| {
            // The first group of this name gathers every one of the name.
            var seen = false;
            if (g.label.len > 0) for (it.groups.items[0..gi]) |e| {
                if (e.drive == g.drive and std.mem.eql(u8, e.label, g.label)) seen = true;
            };
            if (seen) continue;
            var m: Group = .{ .label = g.label, .drive = g.drive, .first = @intCast(order.items.len) };
            for (it.groups.items[gi..], gi..) |o, oi| {
                if (oi != gi and (g.drive != o.drive or g.label.len == 0 or !std.mem.eql(u8, o.label, g.label))) continue;
                for (o.first..o.first + o.count) |i| order.append(gpa, @intCast(i)) catch return;
                m.count += o.count;
                m.found = add(m.found, o.found);
            }
            merged.append(gpa, m) catch return;
        }
        // The items in the merged groups' order.
        const starts = gpa.dupe(u32, it.starts.items) catch return;
        defer gpa.free(starts);
        const found = gpa.dupe(Found, it.found.items) catch return;
        defer gpa.free(found);
        for (order.items, 0..) |from, to| {
            it.starts.items[to] = starts[from];
            it.found.items[to] = found[from];
        }
        it.groups.deinit(gpa);
        it.groups = merged;
        merged = .empty;
    }

    fn clear(it: *Items) void {
        it.paths.clearRetainingCapacity();
        it.starts.clearRetainingCapacity();
        it.found.clearRetainingCapacity();
        it.ticked.clearRetainingCapacity();
        it.groups.clearRetainingCapacity();
    }
};

/// Items of a kind found together: a cache (npm's, Chrome's), an agent's
/// sessions, or one installer or temporary entry. `label` is empty for an
/// item alone, which goes by its file's name.
pub const Group = struct { label: []const u8, drive: u8 = 0, found: Found = .{}, first: u32, count: u32 = 0 };

pub const Scanner = struct {
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,
    busy: std.atomic.Value(bool) = .init(false),
    scanned: std.atomic.Value(bool) = .init(false),
    /// Files looked at so far.
    seen: std.atomic.Value(u64) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    current_drive: std.atomic.Value(u8) = .init(0),
    drives: [26]Drive = undefined,
    n_drives: usize = 0,
    scope: ?u8 = null,
    analyze: bool = true,
    limited: bool = false,
    results: [kinds.len]Found = @splat(.{}),
    items: [kinds.len]Items = @splat(.{}),
    /// The groups' labels that come from folders' names (`*` in a rule).
    names: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Scanner {
        return .{ .gpa = gpa, .names = .init(gpa) };
    }

    /// Waits for a running scan.
    pub fn deinit(s: *Scanner) void {
        s.cancel();
        if (s.thread) |t| t.join();
        for (&s.items) |*it| it.deinit(s.gpa);
        s.names.deinit();
    }

    /// Starts scanning on a thread of its own (no-op while one runs).
    pub fn start(s: *Scanner) void {
        s.startDrive(null);
    }

    /// Null scans every available local/removable drive, otherwise one letter.
    pub fn startDrive(s: *Scanner, letter: ?u8) void {
        s.begin(letter, true);
    }

    fn begin(s: *Scanner, letter: ?u8, analyze: bool) void {
        if (s.running()) return;
        if (s.thread) |t| t.join();
        s.thread = null;
        for (&s.items) |*it| it.clear();
        _ = s.names.reset(.retain_capacity);
        s.results = @splat(.{});
        s.n_drives = 0;
        s.scope = letter;
        s.analyze = analyze;
        s.limited = false;
        s.scanned.store(false, .release);
        s.stop.store(false, .monotonic);
        s.current_drive.store(0, .monotonic);
        s.seen.store(0, .monotonic);
        s.busy.store(true, .release);
        s.thread = std.Thread.spawn(.{}, run, .{s}) catch {
            s.busy.store(false, .release);
            return;
        };
    }

    pub fn running(s: *const Scanner) bool {
        return s.busy.load(.acquire);
    }

    /// Done at least once, and not running.
    pub fn done(s: *const Scanner) bool {
        return !s.running() and s.scanned.load(.acquire);
    }

    pub fn cancel(s: *Scanner) void {
        s.stop.store(true, .monotonic);
    }

    pub fn foundOn(s: *const Scanner, k: Kind, drive: u8) Found {
        var f: Found = .{};
        for (s.groups(k)) |g| if (g.drive == drive) {
            f = add(f, g.found);
        };
        return f;
    }

    pub fn selectDrive(s: *Scanner, k: Kind, drive: u8, on: bool) void {
        for (s.groups(k)) |g| if (g.drive == drive) {
            @memset(s.ticks(k)[g.first..][0..g.count], on);
        };
    }

    /// Files looked at so far by the running (or last) scan.
    pub fn progress(s: *const Scanner) u64 {
        return s.seen.load(.monotonic);
    }

    /// The results; valid when done.
    pub fn found(s: *const Scanner, k: Kind) Found {
        return s.results[@backingInt(k)];
    }

    /// `k`'s groups; valid when done.
    pub fn groups(s: *const Scanner, k: Kind) []const Group {
        return s.items[@backingInt(k)].groups.items;
    }

    /// What item `i` of `k` holds.
    pub fn item(s: *const Scanner, k: Kind, i: u32) Found {
        return s.items[@backingInt(k)].found.items[i];
    }

    /// Item `i` of `k`'s path, as UTF-8 in `buf`.
    pub fn path(s: *const Scanner, k: Kind, i: u32, buf: []u8) []const u8 {
        const it = &s.items[@backingInt(k)];
        const w = std.mem.sliceTo(it.paths.items[it.starts.items[i]..], 0);
        const fit = if (w.len * 3 > buf.len) w[0 .. buf.len / 3] else w;
        return buf[0..std.unicode.wtf16LeToWtf8(buf, fit)];
    }

    /// Whether each of `k`'s items is ticked, to change; valid when done.
    pub fn ticks(s: *Scanner, k: Kind) []bool {
        return s.items[@backingInt(k)].ticked.items;
    }

    /// What the ticked items of `k` hold.
    pub fn ticked(s: *const Scanner, k: Kind) Found {
        const it = &s.items[@backingInt(k)];
        var f: Found = .{};
        for (it.ticked.items, it.found.items) |on, one| {
            if (on) f = add(f, one);
        }
        return f;
    }

    /// Moves `k`'s ticked items to the Recycle Bin, on the calling thread;
    /// how many bytes went. Scan again for what is left.
    pub fn clean(s: *Scanner, k: Kind) u64 {
        if (s.running()) return 0;
        const it = &s.items[@backingInt(k)];
        var list: std.ArrayList(u16) = .empty;
        defer list.deinit(s.gpa);
        var submitted: std.ArrayList(usize) = .empty;
        defer submitted.deinit(s.gpa);
        for (it.ticked.items, it.starts.items, 0..) |on, at, i| if (on) {
            const path_w = std.mem.sliceTo(it.paths.items[at..], 0);
            if (!recyclablePath(path_w)) continue;
            submitted.append(s.gpa, i) catch return 0;
            list.appendSlice(s.gpa, path_w) catch return 0;
            list.append(s.gpa, 0) catch return 0;
        };
        if (list.items.len == 0) return 0;
        // The list ends with two NULs.
        list.append(s.gpa, 0) catch return 0;
        var op: SHFILEOPSTRUCTW = .{ .pFrom = list.items.ptr };
        _ = SHFileOperationW(&op);
        // Some may be in use: count only what is gone.
        var gone: u64 = 0;
        for (submitted.items) |i| {
            const p: [*:0]const u16 = @ptrCast(it.paths.items[it.starts.items[i]..].ptr);
            if (GetFileAttributesW(p) == INVALID_ATTRIBUTES and (GetLastError() == 2 or GetLastError() == 3)) gone += it.found.items[i].bytes;
        }
        return gone;
    }

    fn run(s: *Scanner) void {
        var sc: Scan = .{ .s = s, .w = .{ .seen = &s.seen, .stop = &s.stop, .now = now() } };
        defer sc.roots.deinit(s.gpa);
        var volumes: [26]storage.Volume = undefined;
        const n = storage.list(&volumes);
        for (volumes[0..n]) |v| {
            if (s.scope) |letter| if (v.letter != letter) continue;
            s.drives[s.n_drives] = .{ .volume = v };
            s.n_drives += 1;
        }
        for (rules) |r| {
            if (sc.w.stopped()) break;
            sc.rule(r);
        }
        if (s.analyze) for (s.drives[0..s.n_drives]) |*d| {
            if (sc.w.stopped()) break;
            s.current_drive.store(d.volume.letter, .monotonic);
            sc.w.path[0..6].* = .{ '\\', '\\', '?', '\\', d.volume.letter, ':' };
            sc.w.len = 6;
            const before = sc.w.skipped;
            const result = sc.usage(0, false, true);
            d.entries = result.entries;
            d.found = result.found;
            d.skipped = sc.w.skipped - before;
            d.complete = !sc.w.stopped();
        };
        for (&s.items) |*it| it.merge(s.gpa);
        s.scanned.store(true, .release);
        s.busy.store(false, .release);
    }
};

/// Free bytes on the system drive.
pub fn freeSpace() u64 {
    var free: u64 = 0;
    _ = GetDiskFreeSpaceExW(&systemDrive(), null, null, &free);
    return free;
}

pub fn totalSpace() u64 {
    var total: u64 = 0;
    _ = GetDiskFreeSpaceExW(&systemDrive(), null, &total, null);
    return total;
}

/// "C:\", where Windows is.
fn systemDrive() [3:0]u16 {
    var w: [260]u16 = undefined;
    if (GetWindowsDirectoryW(&w, w.len) < 3) return L("C:\\").*;
    return .{ w[0], w[1], w[2] };
}

/// How a rule finds its items under the directories its path matches.
const How = enum {
    /// Each entry in it: a cache keeps its folder.
    contents,
    /// Each file under it, at any depth, unchanged for a month.
    old_files,
    /// Each file in it with one of the rule's extensions.
    by_ext,
    /// Each entry in it that, with all it holds, is unchanged for three days.
    stale,
};

const Rule = struct {
    kind: Kind,
    how: How,
    /// With %VARS% and `*` segments, each matching any directory.
    path: [:0]const u16,
    exts: []const []const u8 = &.{},
    /// The group its items go in: a name, "*" for the folder its path's
    /// `*` matched, or "" for each item alone.
    group: []const u8 = "",
};

fn rl(kind: Kind, how: How, comptime group: []const u8, comptime path: []const u8) Rule {
    return .{ .kind = kind, .how = how, .group = group, .path = L(path) };
}

const installer_exts: []const []const u8 = &.{ ".exe", ".msi", ".msix", ".msixbundle", ".appx", ".iso" };

const rules = blk: {
    @setEvalBranchQuota(100_000);
    var r: []const Rule = &.{};
    for ([_][2][]const u8{ .{ "Chrome", "Google\\Chrome" }, .{ "Edge", "Microsoft\\Edge" }, .{ "Brave", "BraveSoftware\\Brave-Browser" } }) |b| {
        for ([_][]const u8{ "Cache", "Code Cache", "GPUCache", "Service Worker\\CacheStorage" }) |c|
            r = r ++ .{rl(.caches, .contents, b[0], "%LOCALAPPDATA%\\" ++ b[1] ++ "\\User Data\\*\\" ++ c)};
    }
    r = r ++ .{
        rl(.caches, .contents, "Internet cache", "%LOCALAPPDATA%\\Microsoft\\Windows\\INetCache"),
        rl(.caches, .contents, "Shader cache", "%LOCALAPPDATA%\\D3DSCache"),
        rl(.caches, .contents, "*", "%APPDATA%\\*\\Cache"),
        rl(.caches, .contents, "*", "%APPDATA%\\*\\Code Cache"),
        rl(.caches, .contents, "*", "%APPDATA%\\*\\GPUCache"),
        rl(.caches, .contents, "Code", "%APPDATA%\\Code\\CachedData"),
        rl(.caches, .contents, "Spotify", "%LOCALAPPDATA%\\Spotify\\Data"),
        rl(.package_caches, .contents, "npm", "%LOCALAPPDATA%\\npm-cache"),
        rl(.package_caches, .contents, "Yarn", "%LOCALAPPDATA%\\Yarn\\Cache"),
        rl(.package_caches, .contents, "pnpm", "%LOCALAPPDATA%\\pnpm-cache"),
        rl(.package_caches, .contents, "pnpm", "%LOCALAPPDATA%\\pnpm\\store"),
        rl(.package_caches, .contents, "pip", "%LOCALAPPDATA%\\pip\\cache"),
        rl(.package_caches, .contents, "Go", "%LOCALAPPDATA%\\go-build"),
        rl(.package_caches, .contents, "Go", "%USERPROFILE%\\go\\pkg\\mod\\cache\\download"),
        rl(.package_caches, .contents, "Zig", "%LOCALAPPDATA%\\zig"),
        rl(.package_caches, .contents, "Cargo", "%USERPROFILE%\\.cargo\\registry\\cache"),
        rl(.package_caches, .contents, "Bun", "%USERPROFILE%\\.bun\\install\\cache"),
        rl(.package_caches, .contents, "NuGet", "%LOCALAPPDATA%\\NuGet\\v3-cache"),
        rl(.package_caches, .contents, "Gradle", "%USERPROFILE%\\.gradle\\caches"),
        rl(.developer, .contents, "VS Code extensions", "%APPDATA%\\Code\\CachedExtensionVSIXs"),
        rl(.developer, .contents, "TypeScript", "%LOCALAPPDATA%\\Microsoft\\TypeScript"),
        rl(.developer, .contents, "Visual Studio", "%LOCALAPPDATA%\\Microsoft\\VisualStudio\\*\\ComponentModelCache"),
        rl(.developer, .contents, "IntelliCode logs", "%LOCALAPPDATA%\\Temp\\VSFeedbackIntelliCodeLogs"),
        rl(.agent_sessions, .old_files, "Claude Code", "%USERPROFILE%\\.claude\\projects"),
        rl(.agent_sessions, .old_files, "Codex", "%USERPROFILE%\\.codex\\sessions"),
        Rule{ .kind = .installers, .how = .by_ext, .path = L("%USERPROFILE%\\Downloads"), .exts = installer_exts },
        rl(.logs, .contents, "Crash dumps", "%LOCALAPPDATA%\\CrashDumps"),
        rl(.logs, .contents, "Error reports", "%LOCALAPPDATA%\\Microsoft\\Windows\\WER\\ReportArchive"),
        rl(.logs, .contents, "Error reports", "%LOCALAPPDATA%\\Microsoft\\Windows\\WER\\ReportQueue"),
        Rule{ .kind = .logs, .how = .by_ext, .group = "Temporary logs", .path = L("%TEMP%"), .exts = &.{".log"} },
        // Last: it leaves out what the rules above took.
        rl(.temporary, .stale, "", "%TEMP%"),
    };
    break :blk r[0..r.len].*;
};

const day_s = 24 * 60 * 60;

/// A path being walked (with \\?\, so long paths work) and what it found.
const Walker = struct {
    path: [32768]u16 = undefined,
    len: usize = 0,
    seen: *std.atomic.Value(u64),
    stop: ?*std.atomic.Value(bool) = null,
    skipped: u64 = 0,
    now: i64,

    fn stopped(w: *const Walker) bool {
        return if (w.stop) |s| s.load(.monotonic) else false;
    }

    /// Adds `\name`; false (and nothing added) when too long.
    fn push(w: *Walker, part: []const u16) bool {
        if (w.len + 1 + part.len + 3 > w.path.len) {
            w.skipped += 1;
            return false;
        }
        w.path[w.len] = '\\';
        @memcpy(w.path[w.len + 1 ..][0..part.len], part);
        w.len += 1 + part.len;
        return true;
    }

    /// The path without \\?\.
    fn shown(w: *const Walker) []const u16 {
        return w.path[4..w.len];
    }

    /// The size, files and newest change of the directory at the path, all
    /// it holds.
    fn tally(w: *Walker) Found {
        var t: Found = .{};
        if (w.stopped()) return t;
        var l = Lister.open(w) orelse return t;
        defer l.close();
        const mark = w.len;
        while (l.next()) |d| {
            if (w.stopped()) break;
            defer w.len = mark;
            if (w.push(d.nameSlice())) t = add(t, w.entry(d));
        }
        return t;
    }

    /// Entry `d`, at the path, with all it holds.
    fn entry(w: *Walker, d: *const FIND_DATA) Found {
        var t: Found = .{ .newest_unix = unix(d.ftLastWriteTime) };
        if (d.dir()) {
            t = add(t, w.tally());
        } else {
            _ = w.seen.fetchAdd(1, .monotonic);
            t.bytes = d.size();
            t.files = 1;
        }
        return t;
    }
};

fn add(a: Found, b: Found) Found {
    return .{ .bytes = a.bytes + b.bytes, .files = a.files + b.files, .newest_unix = @max(a.newest_unix, b.newest_unix) };
}

/// The entries of the directory at a walker's path; never `.`, `..` or
/// reparse points (junctions, symlinks), which are not followed.
const Lister = struct {
    h: HANDLE,
    d: FIND_DATA = .{},
    fresh: bool = true,
    w: *Walker,

    fn open(w: *Walker) ?Lister {
        if (w.len + 3 > w.path.len) return null;
        w.path[w.len..][0..3].* = .{ '\\', '*', 0 };
        var l: Lister = .{ .h = undefined, .w = w };
        const h = FindFirstFileExW(@ptrCast(&w.path), FindExInfoBasic, &l.d, 0, null, FIND_FIRST_EX_LARGE_FETCH);
        if (h == INVALID_HANDLE) {
            if (GetLastError() != 2) w.skipped += 1;
            return null;
        }
        l.h = h.?;
        return l;
    }

    fn next(l: *Lister) ?*const FIND_DATA {
        while (true) {
            if (l.w.stopped()) return null;
            if (!l.fresh and FindNextFileW(l.h, &l.d) == 0) {
                if (GetLastError() != 18) l.w.skipped += 1;
                return null;
            }
            l.fresh = false;
            const n = l.d.nameSlice();
            const dots = std.mem.eql(u16, n, L(".")) or std.mem.eql(u16, n, L(".."));
            if (dots) continue;
            if (l.d.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | 0x1000) != 0) {
                l.w.skipped += 1;
                continue;
            }
            return &l.d;
        }
    }

    fn close(l: *Lister) void {
        _ = FindClose(l.h);
    }
};

/// One scan: the walker, and the directories rules matched so far.
const Scan = struct {
    s: *Scanner,
    w: Walker,
    /// The folder the rule's `*` matched last, and the group its items go in.
    star: []const u16 = &.{},
    group: []const u8 = "",
    /// Each matched directory, NUL after each.
    roots: std.ArrayList(u16) = .empty,
    usage_count: usize = 0,

    const UsageResult = struct { found: Found = .{}, entries: []const Usage = &.{} };

    /// Walk all files, retaining three levels for browsing. Only recognized
    /// project caches outside protected trees become cleanup candidates.
    fn usage(sc: *Scan, depth: usize, protected: bool, discover: bool) UsageResult {
        const w = &sc.w;
        var result: UsageResult = .{};
        if (w.stopped()) return result;
        // Bound recursion even on a maliciously deep directory tree.
        if (depth >= 128) {
            w.skipped += 1;
            return result;
        }
        var l = Lister.open(w) orelse return result;
        defer l.close();
        var entries: std.ArrayList(Usage) = .empty;
        const arena = sc.s.names.allocator();
        const mark = w.len;
        while (l.next()) |d| {
            defer w.len = mark;
            const n = d.nameSlice();
            const retain = depth < 3 and (depth == 0 or sc.usage_count < 8192);
            if (retain) sc.usage_count += 1 else if (depth < 3) {
                sc.s.limited = true;
            }
            const locked = protected or (depth == 0 and protectedName(n));
            const candidate = discover and !locked and d.dir() and sc.projectCache(n);
            if (!w.push(n)) continue;
            const before = w.skipped;
            var f: Found = .{ .newest_unix = unix(d.ftLastWriteTime) };
            var children: []const Usage = &.{};
            if (d.dir()) {
                const sub = sc.usage(depth + 1, locked, discover and !candidate and !eqlFold(n, L("AppData")) and !eqlFold(n, L(".git")));
                f = add(f, sub.found);
                children = sub.entries;
            } else {
                _ = w.seen.fetchAdd(1, .monotonic);
                f.bytes = d.size();
                f.files = 1;
            }
            result.found = add(result.found, f);
            if (candidate and !w.stopped() and before == w.skipped and !sc.overlaps(w.shown())) {
                sc.group = "Project dependencies / build caches";
                sc.keep(.developer, f);
            }
            if (retain) {
                const path = sc.text(w.shown()) orelse continue;
                entries.append(arena, .{ .path = path, .found = f, .children = children, .protected = locked, .is_dir = d.dir() }) catch {
                    sc.s.limited = true;
                };
            }
        }
        std.mem.sort(Usage, entries.items, {}, struct {
            fn lt(_: void, a: Usage, b: Usage) bool {
                return a.found.bytes > b.found.bytes;
            }
        }.lt);
        result.entries = entries.items;
        return result;
    }

    fn text(sc: *Scan, wide: []const u16) ?[]const u8 {
        const buf = sc.s.names.allocator().alloc(u8, wide.len * 3) catch return null;
        return buf[0..std.unicode.wtf16LeToWtf8(buf, wide)];
    }

    fn projectCache(sc: *Scan, n: []const u16) bool {
        const marker: []const u16 = if (eqlFold(n, L("node_modules"))) L("package.json") else if (eqlFold(n, L(".zig-cache"))) L("build.zig") else return false;
        const mark = sc.w.len;
        defer sc.w.len = mark;
        if (!sc.w.push(marker)) return false;
        sc.w.path[sc.w.len] = 0;
        const attrs = GetFileAttributesW(@ptrCast(&sc.w.path));
        return attrs != INVALID_ATTRIBUTES and attrs & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0;
    }

    fn overlaps(sc: *const Scan, path: []const u16) bool {
        for (sc.s.items) |it| for (it.starts.items) |at| {
            const other = std.mem.sliceTo(it.paths.items[at..], 0);
            if (within(path, other) or within(other, path)) return true;
        };
        return false;
    }

    fn rule(sc: *Scan, r: Rule) void {
        var buf: [4096]u16 = undefined;
        const path = expand(r.path, &buf) orelse return;
        const letter = driveOf(path);
        if (sc.s.scope) |selected| if (selected != letter) return;
        var available = false;
        for (sc.s.drives[0..sc.s.n_drives]) |d| if (d.volume.letter == letter) {
            available = true;
        };
        if (!available) return;
        sc.s.current_drive.store(letter, .monotonic);
        // "C:" then each `\segment`.
        const drive = std.mem.findScalar(u16, path, '\\') orelse return;
        @memcpy(sc.w.path[0..4], L("\\\\?\\"));
        sc.w.len = 4;
        @memcpy(sc.w.path[4..][0..drive], path[0..drive]);
        sc.w.len += drive;
        sc.match(r, path[drive..]);
    }

    /// Walks down `rest` from the walker's path, each `*` taking every
    /// directory there.
    fn match(sc: *Scan, r: Rule, rest: []const u16) void {
        if (sc.w.stopped()) return;
        if (rest.len == 0) return sc.apply(r);
        const end = std.mem.findScalarPos(u16, rest, 1, '\\') orelse rest.len;
        const seg = rest[1..end];
        const mark = sc.w.len;
        defer sc.w.len = mark;
        if (!std.mem.eql(u16, seg, L("*"))) {
            if (sc.w.push(seg)) {
                sc.w.path[sc.w.len] = 0;
                const attrs = GetFileAttributesW(@ptrCast(&sc.w.path));
                if (attrs != INVALID_ATTRIBUTES and attrs & FILE_ATTRIBUTE_REPARSE_POINT == 0) sc.match(r, rest[end..]);
            }
            return;
        }
        var l = Lister.open(&sc.w) orelse return;
        defer l.close();
        while (l.next()) |d| if (d.dir()) {
            sc.w.len = mark;
            sc.star = d.nameSlice();
            if (sc.w.push(d.nameSlice())) sc.match(r, rest[end..]);
        };
    }

    /// Rule `r` on the directory at the walker's path.
    fn apply(sc: *Scan, r: Rule) void {
        const w = &sc.w;
        sc.group = r.group;
        if (std.mem.eql(u8, r.group, "*")) {
            const a = sc.s.names.allocator();
            const buf = a.alloc(u8, sc.star.len * 3) catch return;
            sc.group = buf[0..std.unicode.wtf16LeToWtf8(buf, sc.star)];
        }
        if (r.how == .old_files) return sc.oldFiles(r.kind);
        var l = Lister.open(w) orelse return;
        defer l.close();
        if (r.how != .stale) {
            sc.roots.appendSlice(sc.s.gpa, w.shown()) catch return;
            sc.roots.append(sc.s.gpa, 0) catch return;
        }
        const mark = w.len;
        while (l.next()) |d| {
            defer w.len = mark;
            const n = d.nameSlice();
            switch (r.how) {
                .by_ext => if (d.dir() or !hasExt(n, r.exts)) continue,
                .stale => if (hasExt(n, &.{".log"})) continue,
                else => {},
            }
            if (!w.push(n)) continue;
            if (r.how == .stale and sc.taken(w.shown())) continue;
            const skipped = w.skipped;
            const t = w.entry(d);
            if (w.stopped() or skipped != w.skipped) continue;
            if (r.how == .stale and t.newest_unix > w.now - 3 * day_s) continue;
            sc.keep(r.kind, t);
        }
    }

    /// Each file under the walker's path unchanged for a month.
    fn oldFiles(sc: *Scan, k: Kind) void {
        const w = &sc.w;
        var l = Lister.open(w) orelse return;
        defer l.close();
        const mark = w.len;
        while (l.next()) |d| {
            defer w.len = mark;
            if (!w.push(d.nameSlice())) continue;
            if (d.dir()) {
                sc.oldFiles(k);
            } else {
                _ = w.seen.fetchAdd(1, .monotonic);
                const t: Found = .{ .bytes = d.size(), .files = 1, .newest_unix = unix(d.ftLastWriteTime) };
                if (t.newest_unix < w.now - 30 * day_s) sc.keep(k, t);
            }
        }
    }

    /// Whether `path` is, or holds, a directory an earlier rule took.
    fn taken(sc: *const Scan, path: []const u16) bool {
        var it = std.mem.splitScalar(u16, sc.roots.items, 0);
        while (it.next()) |root| {
            if (root.len < path.len or !eqlFold(root[0..path.len], path)) continue;
            if (root.len == path.len or root[path.len] == '\\') return true;
        }
        return false;
    }

    /// The walker's path as an item of `k`, in the rule's group (the last
    /// one when it has the same name), or a group of its own.
    fn keep(sc: *Scan, k: Kind, t: Found) void {
        // The shell recycling API does not support extended-length paths.
        if (t.files == 0 or sc.w.shown().len >= 260) return;
        const gpa = sc.s.gpa;
        const it = &sc.s.items[@backingInt(k)];
        const index: u32 = @intCast(it.found.items.len);
        const drive = driveOf(sc.w.shown());
        const last = if (it.groups.items.len > 0) &it.groups.items[it.groups.items.len - 1] else null;
        const same = sc.group.len > 0 and last != null and last.?.drive == drive and std.mem.eql(u8, last.?.label, sc.group);
        it.paths.ensureUnusedCapacity(gpa, sc.w.shown().len + 2) catch return;
        it.starts.ensureUnusedCapacity(gpa, 1) catch return;
        it.found.ensureUnusedCapacity(gpa, 1) catch return;
        it.ticked.ensureUnusedCapacity(gpa, 1) catch return;
        it.groups.ensureUnusedCapacity(gpa, 1) catch return;
        it.starts.appendAssumeCapacity(@intCast(it.paths.items.len));
        it.found.appendAssumeCapacity(t);
        it.ticked.appendAssumeCapacity(false);
        it.paths.appendSliceAssumeCapacity(sc.w.shown());
        it.paths.appendAssumeCapacity(0);
        if (!same) it.groups.appendAssumeCapacity(.{ .label = sc.group, .drive = drive, .first = index });
        const g = &it.groups.items[it.groups.items.len - 1];
        g.count += 1;
        g.found = add(g.found, t);
        const f = &sc.s.results[@backingInt(k)];
        f.* = add(f.*, t);
    }
};

/// `pattern` with its %VARS% expanded (%TEMP% as GetTempPathW has it);
/// null unless that makes a full path.
fn expand(pattern: [:0]const u16, buf: *[4096]u16) ?[]const u16 {
    const temp = L("%TEMP%");
    if (std.mem.startsWith(u16, pattern, temp)) {
        var n = GetTempPathW(buf.len, buf);
        if (n < 3 or n + pattern.len > buf.len) return null;
        if (buf[n - 1] == '\\') n -= 1;
        const rest = pattern[temp.len..];
        @memcpy(buf[n..][0..rest.len], rest);
        return buf[0 .. n + rest.len];
    }
    const n = ExpandEnvironmentStringsW(pattern, buf, buf.len);
    if (n < 4 or n > buf.len or buf[1] != ':') return null;
    return buf[0 .. n - 1];
}

fn hasExt(n: []const u16, exts: []const []const u8) bool {
    for (exts) |e| {
        if (n.len <= e.len) continue;
        for (n[n.len - e.len ..], e) |c, a| {
            if (fold(c) != a) break;
        } else return true;
    }
    return false;
}

fn fold(c: u16) u16 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn eqlFold(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (fold(x) != fold(y)) return false;
    return true;
}

fn within(path: []const u16, root: []const u16) bool {
    return path.len >= root.len and eqlFold(path[0..root.len], root) and (path.len == root.len or path[root.len] == '\\');
}

/// Recheck every ancestor before recycling. A folder may have been replaced
/// by a junction since the scan. SHFileOperation also cannot handle long paths.
fn recyclablePath(path: []const u16) bool {
    if (path.len <= 3 or path.len >= 260 or driveOf(path) == 0 or path[2] != '\\') return false;
    var buf: [260]u16 = undefined;
    @memcpy(buf[0..path.len], path);
    var start: usize = 3;
    for (3..path.len + 1) |end| {
        if (end < path.len and path[end] != '\\') continue;
        const part = path[start..end];
        if (part.len == 0 or eqlFold(part, L(".")) or eqlFold(part, L(".."))) return false;
        if (start == 3 and protectedName(part)) return false;
        buf[end] = 0;
        const attrs = GetFileAttributesW(@ptrCast(&buf));
        if (attrs == INVALID_ATTRIBUTES or attrs & FILE_ATTRIBUTE_REPARSE_POINT != 0) return false;
        if (end < path.len) buf[end] = '\\';
        start = end + 1;
    }
    return true;
}

fn protectedName(n: []const u16) bool {
    for ([_][]const u16{ L("Windows"), L("Windows.old"), L("WindowsApps"), L("WpSystem"), L("Program Files"), L("Program Files (x86)"), L("ProgramData"), L("$Recycle.Bin"), L("System Volume Information"), L("Recovery"), L("Boot"), L("pagefile.sys"), L("hiberfil.sys"), L("swapfile.sys") }) |p| {
        if (eqlFold(n, p)) return true;
    }
    return false;
}

/// FILETIME (100 ns since 1601) as Unix seconds.
fn unix(ft: FILETIME) i64 {
    const t = @as(u64, ft.high) << 32 | ft.low;
    return @as(i64, @intCast(t / 10_000_000)) - 11_644_473_600;
}

/// Now, as Unix seconds.
pub fn now() i64 {
    var ft: FILETIME = .{};
    GetSystemTimeAsFileTime(&ft);
    return unix(ft);
}

const INVALID_HANDLE: ?HANDLE = @ptrFromInt(std.math.maxInt(usize));
const INVALID_ATTRIBUTES = 0xFFFFFFFF;
const FILE_ATTRIBUTE_DIRECTORY = 0x10;
const FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
const FindExInfoBasic = 1;
const FIND_FIRST_EX_LARGE_FETCH = 2;
const FO_DELETE = 3;
const FOF_SILENT = 0x4;
const FOF_NOCONFIRMATION = 0x10;
const FOF_ALLOWUNDO = 0x40;
const FOF_NOERRORUI = 0x400;
const FOF_WANTNUKEWARNING = 0x4000;

const FILETIME = extern struct { low: u32 = 0, high: u32 = 0 };

const FIND_DATA = extern struct {
    dwFileAttributes: u32 = 0,
    ftCreationTime: FILETIME = .{},
    ftLastAccessTime: FILETIME = .{},
    ftLastWriteTime: FILETIME = .{},
    nFileSizeHigh: u32 = 0,
    nFileSizeLow: u32 = 0,
    dwReserved0: u32 = 0,
    dwReserved1: u32 = 0,
    cFileName: [260]u16 = @splat(0),
    cAlternateFileName: [14]u16 = @splat(0),

    fn nameSlice(d: *const FIND_DATA) []const u16 {
        return std.mem.sliceTo(&d.cFileName, 0);
    }

    fn dir(d: *const FIND_DATA) bool {
        return d.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0;
    }

    fn size(d: *const FIND_DATA) u64 {
        return @as(u64, d.nFileSizeHigh) << 32 | d.nFileSizeLow;
    }
};

const SHFILEOPSTRUCTW = extern struct {
    hwnd: ?HANDLE = null,
    wFunc: u32 = FO_DELETE,
    /// Paths, NUL after each, then one more.
    pFrom: [*]const u16,
    pTo: ?[*]const u16 = null,
    fFlags: u16 = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI | FOF_WANTNUKEWARNING,
    fAnyOperationsAborted: BOOL = 0,
    hNameMappings: ?*anyopaque = null,
    lpszProgressTitle: ?[*:0]const u16 = null,
};

extern "kernel32" fn FindFirstFileExW(name: [*:0]const u16, level: u32, data: *FIND_DATA, op: u32, filter: ?*anyopaque, flags: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn FindNextFileW(h: HANDLE, data: *FIND_DATA) callconv(.winapi) BOOL;
extern "kernel32" fn FindClose(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn ExpandEnvironmentStringsW(src: [*:0]const u16, dst: [*]u16, n: u32) callconv(.winapi) u32;
extern "kernel32" fn GetTempPathW(n: u32, buf: [*]u16) callconv(.winapi) u32;
extern "kernel32" fn GetWindowsDirectoryW(buf: [*]u16, n: u32) callconv(.winapi) u32;
extern "kernel32" fn GetDiskFreeSpaceExW(dir: [*:0]const u16, avail: ?*u64, total: ?*u64, free: ?*u64) callconv(.winapi) BOOL;
extern "kernel32" fn GetSystemTimeAsFileTime(ft: *FILETIME) callconv(.winapi) void;
extern "shell32" fn SHFileOperationW(op: *SHFILEOPSTRUCTW) callconv(.winapi) c_int;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, sa: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn RemoveDirectoryW(name: [*:0]const u16) callconv(.winapi) BOOL;

test "scan this machine" {
    var s = Scanner.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expect(!s.done());
    const t0 = GetTickCount64();
    s.begin(null, false);
    s.begin(null, false);
    while (!s.done()) Sleep(20);
    const took = GetTickCount64() - t0;
    var all: u64 = 0;
    for (kinds) |k| {
        const f = s.found(k);
        const it = &s.items[@backingInt(k)];
        std.debug.print("{s:<16} {d:>8.1} MB {d:>7} files {d:>6} items  ({s})\n", .{ name(k), @as(f64, @floatFromInt(f.bytes)) / 1e6, f.files, it.found.items.len, about(k) });
        var sum: u64 = 0;
        for (s.groups(k)) |g| {
            sum += g.found.bytes;
            if (g.label.len > 0) std.debug.print("    {s:<20} {d:>8.1} MB {d:>6} items\n", .{ g.label, @as(f64, @floatFromInt(g.found.bytes)) / 1e6, g.count });
        }
        try std.testing.expectEqual(f.bytes, sum);
        all += f.bytes;
    }
    std.debug.print("{d:.1} MB in all, {d} files looked at, in {d} ms; system drive {d:.1} of {d:.1} GB free\n", .{ @as(f64, @floatFromInt(all)) / 1e6, s.progress(), took, @as(f64, @floatFromInt(freeSpace())) / 1e9, @as(f64, @floatFromInt(totalSpace())) / 1e9 });
    try std.testing.expect(totalSpace() > freeSpace() and freeSpace() > 0);
    try std.testing.expect(s.progress() > 0);
}

test "cleanup groups and selection stay on their own drive" {
    var s = Scanner.init(std.testing.allocator);
    defer s.deinit();
    var sc: Scan = .{ .s = &s, .w = .{ .seen = &s.seen, .now = now() }, .group = "npm" };
    const paths = [_][]const u16{ L("C:\\cache\\one"), L("D:\\cache\\two"), L("C:\\cache\\three") };
    for (paths, 0..) |path_w, i| {
        @memcpy(sc.w.path[4..][0..path_w.len], path_w);
        sc.w.len = 4 + path_w.len;
        sc.keep(.package_caches, .{ .bytes = (i + 1) * 10, .files = 1 });
    }
    s.items[@backingInt(Kind.package_caches)].merge(s.gpa);
    try std.testing.expectEqual(@as(usize, 2), s.groups(.package_caches).len);
    try std.testing.expectEqual(@as(u64, 40), s.foundOn(.package_caches, 'C').bytes);
    try std.testing.expectEqual(@as(u64, 20), s.foundOn(.package_caches, 'D').bytes);
    try std.testing.expectEqual(@as(u64, 0), s.ticked(.package_caches).bytes);
    s.selectDrive(.package_caches, 'D', true);
    try std.testing.expectEqual(@as(u64, 20), s.ticked(.package_caches).bytes);
    var buf: [128]u8 = undefined;
    for (s.ticks(.package_caches), 0..) |on, i| if (on) {
        try std.testing.expectEqualStrings("D:\\cache\\two", s.path(.package_caches, @intCast(i), &buf));
    };
    s.selectDrive(.package_caches, 'C', false);
    try std.testing.expectEqual(@as(u64, 20), s.ticked(.package_caches).bytes);
    try std.testing.expect(within(L("c:\\cache\\one"), L("C:\\cache")));
    try std.testing.expect(!within(L("C:\\cache-other"), L("C:\\cache")));
    try std.testing.expect(!recyclablePath(L("C:\\")));
    try std.testing.expect(!recyclablePath(L("C:\\Windows")));
    try std.testing.expect(!recyclablePath(L("C:\\..\\file")));
    try std.testing.expect(needsReview(.agent_sessions) and needsReview(.installers));
}

test "whole drive analysis measures folders but offers only recognized project caches" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "projects/app/node_modules", "projects/zig/.zig-cache", "personal/node_modules", "Windows/app/node_modules" }) |dir| try tmp.dir.createDirPath(io, dir);
    const fixtures = [_][2][]const u8{
        .{ "projects/app/package.json", "{}" },
        .{ "projects/app/node_modules/index.js", "package" },
        .{ "projects/zig/build.zig", "build" },
        .{ "projects/zig/.zig-cache/object", "compiled" },
        .{ "personal/node_modules/notes.txt", "keep personal notes" },
        .{ "Windows/app/package.json", "{}" },
        .{ "Windows/app/node_modules/index.js", "system" },
    };
    var expected: u64 = 0;
    for (fixtures) |file| {
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[1] });
        expected += file[1].len;
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    var s = Scanner.init(gpa);
    defer s.deinit();
    var sc: Scan = .{ .s = &s, .w = .{ .seen = &s.seen, .stop = &s.stop, .now = now() } };
    @memcpy(sc.w.path[0..4], L("\\\\?\\"));
    const plain = if (std.mem.startsWith(u8, root, "\\\\?\\")) root[4..] else root;
    sc.w.len = 4 + try std.unicode.wtf8ToWtf16Le(sc.w.path[4..], plain);
    const result = sc.usage(0, false, true);
    try std.testing.expectEqual(expected, result.found.bytes);
    try std.testing.expectEqual(@as(u64, fixtures.len), result.found.files);
    try std.testing.expectEqual(@as(u64, "package".len + "compiled".len), s.found(.developer).bytes);
    try std.testing.expectEqual(@as(u64, 0), s.ticked(.developer).bytes);
    try std.testing.expectEqual(@as(usize, 3), result.entries.len);
    try std.testing.expect(std.mem.endsWith(u8, result.entries[0].path, "projects"));
    for (result.entries) |entry| if (std.mem.endsWith(u8, entry.path, "Windows")) {
        try std.testing.expect(entry.protected);
        try std.testing.expect(entry.children[0].protected);
    };
    // An already selected subtree cannot become a second overlapping target.
    const path_w = std.mem.sliceTo(s.items[@backingInt(Kind.developer)].paths.items, 0);
    try std.testing.expect(sc.overlaps(path_w));
    s.cancel();
    const stopped = sc.usage(0, false, true);
    try std.testing.expectEqual(@as(u64, 0), stopped.found.bytes);
    try std.testing.expectEqual(@as(usize, 0), stopped.entries.len);
}

test "clean moves a scan's items to the Recycle Bin" {
    const gpa = std.testing.allocator;
    var temp: [4096]u16 = undefined;
    const base = expand(L("%TEMP%"), &temp).?;
    // A fresh directory of our own: its contents are the only items.
    var s = Scanner.init(gpa);
    defer s.deinit();
    var sc: Scan = .{ .s = &s, .w = .{ .seen = &s.seen, .now = now() } };
    defer sc.roots.deinit(gpa);
    @memcpy(sc.w.path[0..4], L("\\\\?\\"));
    @memcpy(sc.w.path[4..][0..base.len], base);
    sc.w.len = 4 + base.len;
    var stamp: [32]u8 = undefined;
    var wide: [32]u16 = undefined;
    const dir_name = try std.fmt.bufPrint(&stamp, "mymonitor-clean-test-{d}", .{GetTickCount64()});
    try std.testing.expect(sc.w.push(wide[0..try std.unicode.wtf8ToWtf16Le(&wide, dir_name)]));
    sc.w.path[sc.w.len] = 0;
    try std.testing.expect(CreateDirectoryW(@ptrCast(&sc.w.path), null) != 0);
    const dir_len = sc.w.len;
    const data = "some bytes to recycle\n";
    const files = [_][]const u16{ L("a.txt"), L("b.bin"), L("sub") };
    for (files, 0..) |f, i| {
        defer sc.w.len = dir_len;
        _ = sc.w.push(f);
        sc.w.path[sc.w.len] = 0;
        if (i == 2) {
            try std.testing.expect(CreateDirectoryW(@ptrCast(&sc.w.path), null) != 0);
            _ = sc.w.push(L("c.txt"));
            sc.w.path[sc.w.len] = 0;
        }
        const h = CreateFileW(@ptrCast(&sc.w.path), 0x40000000, 0, null, 1, 0x80, null);
        try std.testing.expect(h != INVALID_HANDLE);
        // Written once, twice, three times.
        for (0..i + 1) |_| {
            var wrote: u32 = 0;
            try std.testing.expect(WriteFile(h.?, data, data.len, &wrote, null) != 0);
        }
        _ = CloseHandle(h.?);
    }
    sc.apply(.{ .kind = .temporary, .how = .contents, .path = L("") });
    const f = s.found(.temporary);
    std.debug.print("test dir: {d} items, {d} files, {d} bytes\n", .{ s.items[@backingInt(Kind.temporary)].found.items.len, f.files, f.bytes });
    try std.testing.expectEqual(@as(u64, 3), f.files);
    try std.testing.expectEqual(@as(u64, data.len * 6), f.bytes);
    try std.testing.expect(sc.taken(sc.w.shown()));

    // Nothing ticked: nothing goes. Then all of it.
    try std.testing.expectEqual(@as(u64, 0), s.clean(.temporary));
    for (s.ticks(.temporary)) |*on| on.* = true;
    try std.testing.expectEqual(f, s.ticked(.temporary));
    const went = s.clean(.temporary);
    std.debug.print("recycled {d} bytes\n", .{went});
    try std.testing.expectEqual(f.bytes, went);
    sc.w.path[sc.w.len] = 0;
    try std.testing.expect(RemoveDirectoryW(@ptrCast(&sc.w.path)) != 0);
}
