//! What can be cleaned up on this Windows user account: caches apps make
//! again, old agent sessions, installers left in Downloads, logs and old
//! temporary files. Scanned on a thread of its own; cleaned by moving each
//! item to the Recycle Bin, so nothing is lost for good.
const std = @import("std");

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
        .developer => "Build caches tools make again",
        .agent_sessions => "Claude Code's and Codex's sessions over a month old",
        .installers => "Installers and disk images left in Downloads",
        .logs => "Apps' logs and crash reports",
        .temporary => "Left by apps, unchanged for three days",
    };
}

pub const Found = struct { bytes: u64 = 0, files: u64 = 0, newest_unix: i64 = 0 };

/// What a kind would remove: each item's path (NUL after each) and size.
const Items = struct {
    paths: std.ArrayList(u16) = .empty,
    sizes: std.ArrayList(u64) = .empty,

    fn deinit(it: *Items, gpa: std.mem.Allocator) void {
        it.paths.deinit(gpa);
        it.sizes.deinit(gpa);
    }
};

pub const Scanner = struct {
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,
    busy: std.atomic.Value(bool) = .init(false),
    scanned: std.atomic.Value(bool) = .init(false),
    /// Files looked at so far.
    seen: std.atomic.Value(u64) = .init(0),
    results: [kinds.len]Found = @splat(.{}),
    items: [kinds.len]Items = @splat(.{}),

    pub fn init(gpa: std.mem.Allocator) Scanner {
        return .{ .gpa = gpa };
    }

    /// Waits for a running scan.
    pub fn deinit(s: *Scanner) void {
        if (s.thread) |t| t.join();
        for (&s.items) |*it| it.deinit(s.gpa);
    }

    /// Starts scanning on a thread of its own (no-op while one runs).
    pub fn start(s: *Scanner) void {
        if (s.running()) return;
        if (s.thread) |t| t.join();
        s.thread = null;
        for (&s.items) |*it| {
            it.paths.clearRetainingCapacity();
            it.sizes.clearRetainingCapacity();
        }
        s.results = @splat(.{});
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
        return s.scanned.load(.acquire) and !s.running();
    }

    /// Files looked at so far by the running (or last) scan.
    pub fn progress(s: *const Scanner) u64 {
        return s.seen.load(.monotonic);
    }

    /// The results; valid when done.
    pub fn found(s: *const Scanner, k: Kind) Found {
        return s.results[@backingInt(k)];
    }

    /// Moves `k`'s items to the Recycle Bin, on the calling thread; how many bytes went. Then that kind reads empty until the next scan.
    pub fn clean(s: *Scanner, k: Kind) u64 {
        if (s.running()) return 0;
        const it = &s.items[@backingInt(k)];
        defer {
            it.paths.clearRetainingCapacity();
            it.sizes.clearRetainingCapacity();
            s.results[@backingInt(k)] = .{};
        }
        if (it.sizes.items.len == 0) return 0;
        // The list ends with two NULs.
        it.paths.append(s.gpa, 0) catch return 0;
        var op: SHFILEOPSTRUCTW = .{ .pFrom = it.paths.items.ptr };
        _ = SHFileOperationW(&op);
        // Some may be in use: count only what is gone.
        var gone: u64 = 0;
        var at: usize = 0;
        for (it.sizes.items) |size| {
            const p: [*:0]const u16 = @ptrCast(it.paths.items[at..].ptr);
            at += std.mem.len(p) + 1;
            if (GetFileAttributesW(p) == INVALID_ATTRIBUTES) gone += size;
        }
        return gone;
    }

    fn run(s: *Scanner) void {
        var sc: Scan = .{ .s = s, .w = .{ .seen = &s.seen, .now = now() } };
        defer sc.roots.deinit(s.gpa);
        for (rules) |r| sc.rule(r);
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
};

fn rl(kind: Kind, how: How, comptime path: []const u8) Rule {
    return .{ .kind = kind, .how = how, .path = L(path) };
}

const installer_exts: []const []const u8 = &.{ ".exe", ".msi", ".msix", ".msixbundle", ".appx", ".iso" };

const rules = blk: {
    @setEvalBranchQuota(100_000);
    var r: []const Rule = &.{};
    for ([_][]const u8{ "Google\\Chrome", "Microsoft\\Edge", "BraveSoftware\\Brave-Browser" }) |b| {
        for ([_][]const u8{ "Cache", "Code Cache", "GPUCache", "Service Worker\\CacheStorage" }) |c|
            r = r ++ .{rl(.caches, .contents, "%LOCALAPPDATA%\\" ++ b ++ "\\User Data\\*\\" ++ c)};
    }
    r = r ++ .{
        rl(.caches, .contents, "%LOCALAPPDATA%\\Microsoft\\Windows\\INetCache"),
        rl(.caches, .contents, "%LOCALAPPDATA%\\D3DSCache"),
        rl(.caches, .contents, "%APPDATA%\\*\\Cache"),
        rl(.caches, .contents, "%APPDATA%\\*\\Code Cache"),
        rl(.caches, .contents, "%APPDATA%\\*\\GPUCache"),
        rl(.caches, .contents, "%APPDATA%\\Code\\CachedData"),
        rl(.caches, .contents, "%LOCALAPPDATA%\\Spotify\\Data"),
        rl(.package_caches, .contents, "%LOCALAPPDATA%\\npm-cache"),
        rl(.package_caches, .contents, "%LOCALAPPDATA%\\Yarn\\Cache"),
        rl(.package_caches, .contents, "%LOCALAPPDATA%\\pnpm-cache"),
        rl(.package_caches, .contents, "%LOCALAPPDATA%\\pnpm\\store"),
        rl(.package_caches, .contents, "%LOCALAPPDATA%\\pip\\cache"),
        rl(.package_caches, .contents, "%LOCALAPPDATA%\\go-build"),
        rl(.package_caches, .contents, "%USERPROFILE%\\go\\pkg\\mod\\cache\\download"),
        rl(.package_caches, .contents, "%LOCALAPPDATA%\\zig"),
        rl(.package_caches, .contents, "%USERPROFILE%\\.cargo\\registry\\cache"),
        rl(.package_caches, .contents, "%USERPROFILE%\\.bun\\install\\cache"),
        rl(.package_caches, .contents, "%LOCALAPPDATA%\\NuGet\\v3-cache"),
        rl(.package_caches, .contents, "%USERPROFILE%\\.gradle\\caches"),
        rl(.developer, .contents, "%APPDATA%\\Code\\CachedExtensionVSIXs"),
        rl(.developer, .contents, "%LOCALAPPDATA%\\Microsoft\\TypeScript"),
        rl(.developer, .contents, "%LOCALAPPDATA%\\Microsoft\\VisualStudio\\*\\ComponentModelCache"),
        rl(.developer, .contents, "%LOCALAPPDATA%\\Temp\\VSFeedbackIntelliCodeLogs"),
        rl(.agent_sessions, .old_files, "%USERPROFILE%\\.claude\\projects"),
        rl(.agent_sessions, .old_files, "%USERPROFILE%\\.codex\\sessions"),
        Rule{ .kind = .installers, .how = .by_ext, .path = L("%USERPROFILE%\\Downloads"), .exts = installer_exts },
        rl(.logs, .contents, "%LOCALAPPDATA%\\CrashDumps"),
        rl(.logs, .contents, "%LOCALAPPDATA%\\Microsoft\\Windows\\WER\\ReportArchive"),
        rl(.logs, .contents, "%LOCALAPPDATA%\\Microsoft\\Windows\\WER\\ReportQueue"),
        Rule{ .kind = .logs, .how = .by_ext, .path = L("%TEMP%"), .exts = &.{".log"} },
        // Last: it leaves out what the rules above took.
        rl(.temporary, .stale, "%TEMP%"),
    };
    break :blk r[0..r.len].*;
};

const day_s = 24 * 60 * 60;

/// A path being walked (with \\?\, so long paths work) and what it found.
const Walker = struct {
    path: [32768]u16 = undefined,
    len: usize = 0,
    seen: *std.atomic.Value(u64),
    now: i64,

    /// Adds `\name`; false (and nothing added) when too long.
    fn push(w: *Walker, part: []const u16) bool {
        if (w.len + 1 + part.len + 3 > w.path.len) return false;
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
        var l = Lister.open(w) orelse return t;
        defer l.close();
        const mark = w.len;
        while (l.next()) |d| {
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

    fn open(w: *Walker) ?Lister {
        if (w.len + 3 > w.path.len) return null;
        w.path[w.len..][0..3].* = .{ '\\', '*', 0 };
        var l: Lister = .{ .h = undefined };
        const h = FindFirstFileExW(@ptrCast(&w.path), FindExInfoBasic, &l.d, 0, null, FIND_FIRST_EX_LARGE_FETCH);
        if (h == INVALID_HANDLE) return null;
        l.h = h.?;
        return l;
    }

    fn next(l: *Lister) ?*const FIND_DATA {
        while (true) {
            if (!l.fresh and FindNextFileW(l.h, &l.d) == 0) return null;
            l.fresh = false;
            const n = l.d.nameSlice();
            const dots = std.mem.eql(u16, n, L(".")) or std.mem.eql(u16, n, L(".."));
            if (!dots and l.d.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT == 0) return &l.d;
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
    /// Each matched directory, NUL after each.
    roots: std.ArrayList(u16) = .empty,

    fn rule(sc: *Scan, r: Rule) void {
        var buf: [4096]u16 = undefined;
        const path = expand(r.path, &buf) orelse return;
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
        if (rest.len == 0) return sc.apply(r);
        const end = std.mem.findScalarPos(u16, rest, 1, '\\') orelse rest.len;
        const seg = rest[1..end];
        const mark = sc.w.len;
        defer sc.w.len = mark;
        if (!std.mem.eql(u16, seg, L("*"))) {
            if (sc.w.push(seg)) sc.match(r, rest[end..]);
            return;
        }
        var l = Lister.open(&sc.w) orelse return;
        defer l.close();
        while (l.next()) |d| if (d.dir()) {
            sc.w.len = mark;
            if (sc.w.push(d.nameSlice())) sc.match(r, rest[end..]);
        };
    }

    /// Rule `r` on the directory at the walker's path.
    fn apply(sc: *Scan, r: Rule) void {
        const w = &sc.w;
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
            const t = w.entry(d);
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

    /// The walker's path as an item of `k`.
    fn keep(sc: *Scan, k: Kind, t: Found) void {
        const gpa = sc.s.gpa;
        const it = &sc.s.items[@backingInt(k)];
        it.paths.ensureUnusedCapacity(gpa, sc.w.shown().len + 2) catch return;
        it.sizes.append(gpa, t.bytes) catch return;
        it.paths.appendSliceAssumeCapacity(sc.w.shown());
        it.paths.appendAssumeCapacity(0);
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
    for (a, b) |x, y| if (fold(x) != fold(y)) return false;
    return true;
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
    fFlags: u16 = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI,
    fAnyOperationsAborted: BOOL = 0,
    hNameMappings: ?*anyopaque = null,
    lpszProgressTitle: ?[*:0]const u16 = null,
};

extern "kernel32" fn FindFirstFileExW(name: [*:0]const u16, level: u32, data: *FIND_DATA, op: u32, filter: ?*anyopaque, flags: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn FindNextFileW(h: HANDLE, data: *FIND_DATA) callconv(.winapi) BOOL;
extern "kernel32" fn FindClose(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) u32;
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
    s.start();
    s.start();
    while (!s.done()) Sleep(20);
    const took = GetTickCount64() - t0;
    var all: u64 = 0;
    for (kinds) |k| {
        const f = s.found(k);
        const it = &s.items[@backingInt(k)];
        std.debug.print("{s:<16} {d:>8.1} MB {d:>7} files {d:>6} items  ({s})\n", .{ name(k), @as(f64, @floatFromInt(f.bytes)) / 1e6, f.files, it.sizes.items.len, about(k) });
        var sum: u64 = 0;
        for (it.sizes.items) |b| sum += b;
        try std.testing.expectEqual(f.bytes, sum);
        all += f.bytes;
    }
    std.debug.print("{d:.1} MB in all, {d} files looked at, in {d} ms; system drive {d:.1} of {d:.1} GB free\n", .{ @as(f64, @floatFromInt(all)) / 1e6, s.progress(), took, @as(f64, @floatFromInt(freeSpace())) / 1e9, @as(f64, @floatFromInt(totalSpace())) / 1e9 });
    try std.testing.expect(totalSpace() > freeSpace() and freeSpace() > 0);
    try std.testing.expect(s.progress() > 0);
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
    std.debug.print("test dir: {d} items, {d} files, {d} bytes\n", .{ s.items[@backingInt(Kind.temporary)].sizes.items.len, f.files, f.bytes });
    try std.testing.expectEqual(@as(u64, 3), f.files);
    try std.testing.expectEqual(@as(u64, data.len * 6), f.bytes);
    try std.testing.expect(sc.taken(sc.w.shown()));

    const went = s.clean(.temporary);
    std.debug.print("recycled {d} bytes\n", .{went});
    try std.testing.expectEqual(f.bytes, went);
    try std.testing.expectEqual(Found{}, s.found(.temporary));
    sc.w.path[sc.w.len] = 0;
    try std.testing.expect(RemoveDirectoryW(@ptrCast(&sc.w.path)) != 0);
}
