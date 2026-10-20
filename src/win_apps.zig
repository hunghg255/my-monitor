//! The apps installed on Windows, as Settings › Apps lists them: programs
//! from the registry's Uninstall keys, and this user's Microsoft Store
//! apps from the package repository, each read from its manifest. Read on
//! a thread of its own; then what the registry didn't size is sized by
//! walking its folder.
const std = @import("std");
const icons = @import("win_icons.zig");

const HANDLE = *anyopaque;
const BOOL = c_int;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Source = enum { store, installer, other };

pub fn sourceName(s: Source) []const u8 {
    return switch (s) {
        .store => "Microsoft Store",
        .installer => "Windows Installer",
        .other => "–",
    };
}

pub const App = struct {
    name: []const u8,
    version: []const u8,
    publisher: []const u8,
    /// Where it lives: the install location, or the package's folder ("" when unknown).
    location: []const u8,
    /// Its icon: a program "path" (or "path,index") for an installer's app, a PNG for a Store app ("" when none).
    icon: []const u8,
    /// What uninstalls it (an installer's command line; "" for a Store app).
    uninstall: []const u8,
    /// A Store app's package full name and family name, and its application's id ("" otherwise).
    package: []const u8,
    family: []const u8,
    app_id: []const u8,
    /// Bytes on disk (the registry's estimate, else the folder's size); 0 when unknown.
    size: u64 = 0,
    /// When it was installed, Unix seconds (0 when unknown): InstallDate (yyyymmdd) or the folder's creation time.
    installed: i64 = 0,
    source: Source = .other,
};

/// Apps and the arena owning their strings.
const Set = struct {
    arena: std.heap.ArenaAllocator,
    apps: std.ArrayList(App) = .empty,

    fn deinit(s: *Set, gpa: std.mem.Allocator) void {
        s.apps.deinit(gpa);
        s.arena.deinit();
    }
};

pub const List = struct {
    gpa: std.mem.Allocator,
    /// The apps shown, and those a load fills on its thread; the main
    /// thread takes the new ones when the load is done (`take`), so the
    /// old stay readable meanwhile.
    shown: Set,
    next: Set,
    thread: ?std.Thread = null,
    busy: std.atomic.Value(bool) = .init(false),
    loaded: std.atomic.Value(bool) = .init(false),
    fresh: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator) List {
        return .{ .gpa = gpa, .shown = .{ .arena = .init(gpa) }, .next = .{ .arena = .init(gpa) } };
    }

    /// Waits for a running load.
    pub fn deinit(l: *List) void {
        if (l.thread) |t| t.join();
        l.shown.deinit(l.gpa);
        l.next.deinit(l.gpa);
    }

    /// Reads the list again on a thread of its own (no-op while one runs):
    /// first the entries, then sizes the registry didn't give (walking
    /// folders, skipping reparse points). The apps read before stay until
    /// then.
    pub fn start(l: *List) void {
        if (l.running()) return;
        if (l.thread) |t| t.join();
        l.thread = null;
        _ = l.take();
        l.next.apps.clearRetainingCapacity();
        _ = l.next.arena.reset(.retain_capacity);
        l.busy.store(true, .release);
        l.thread = std.Thread.spawn(.{}, run, .{l}) catch {
            l.busy.store(false, .release);
            return;
        };
    }

    pub fn running(l: *const List) bool {
        return l.busy.load(.acquire);
    }

    /// Loaded at least once.
    pub fn done(l: *const List) bool {
        return l.loaded.load(.acquire);
    }

    /// Shows what a finished load read (on the main thread, as it reads
    /// `items`); whether there was something new.
    pub fn take(l: *List) bool {
        if (!l.fresh.swap(false, .acq_rel)) return false;
        std.mem.swap(Set, &l.shown, &l.next);
        return true;
    }

    /// The apps, by name; valid until the next `take`.
    pub fn items(l: *const List) []const App {
        return l.shown.apps.items;
    }

    fn run(l: *List) void {
        var ld: Loader = .{ .l = l, .out = &l.next, .a = l.next.arena.allocator() };
        defer ld.seen.deinit(l.gpa);
        ld.dirs();
        for (uninstall_keys) |u| ld.each(u.root, u.path, Loader.installer);
        // Each Store package of this user.
        ld.each(HKEY_CURRENT_USER, packages_key, Loader.package);
        std.mem.sort(App, l.next.apps.items, {}, byName);
        ld.sizes();
        l.fresh.store(true, .release);
        l.loaded.store(true, .release);
        l.busy.store(false, .release);
    }
};

fn byName(_: void, a: App, b: App) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

const uninstall_keys = [_]struct { root: HANDLE, path: [*:0]const u16 }{
    .{ .root = HKEY_LOCAL_MACHINE, .path = L("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall") },
    .{ .root = HKEY_LOCAL_MACHINE, .path = L("SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall") },
    .{ .root = HKEY_CURRENT_USER, .path = L("SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall") },
};

const packages_key = L("Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\CurrentVersion\\AppModel\\Repository\\Packages");

/// One load: the list it fills, and what it has seen.
const Loader = struct {
    l: *List,
    out: *Set,
    a: std.mem.Allocator,
    /// Each app taken: an installer's lowercase name and version, a package's family.
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Where Windows is, with its `\`.
    windows: []const u8 = "",
    /// Folders too broad to size as one app's: Program Files and the like.
    shared: [8][]const u8 = @splat(""),

    fn dirs(ld: *Loader) void {
        var w: [260]u16 = undefined;
        const n = GetWindowsDirectoryW(&w, w.len);
        if (n > 0 and n < w.len) ld.windows = std.fmt.allocPrint(ld.a, "{s}\\", .{ld.utf8(w[0..n])}) catch "";
        const vars = [_][*:0]const u16{ L("%ProgramFiles%"), L("%ProgramFiles(x86)%"), L("%ProgramW6432%"), L("%ProgramData%"), L("%USERPROFILE%"), L("%LOCALAPPDATA%"), L("%APPDATA%"), L("%LOCALAPPDATA%\\Programs") };
        for (vars, &ld.shared) |v, *s| {
            var buf: [1024]u16 = undefined;
            const m = ExpandEnvironmentStringsW(v, &buf, buf.len);
            if (m > 1 and m <= buf.len) s.* = ld.utf8(buf[0 .. m - 1]);
        }
    }

    /// Whether `key` is new (and now seen).
    fn fresh(ld: *Loader, key: []const u8) bool {
        const got = ld.seen.getOrPut(ld.l.gpa, key) catch return false;
        return !got.found_existing;
    }

    fn add(ld: *Loader, app: App) void {
        ld.out.apps.append(ld.l.gpa, app) catch {};
    }

    fn utf8(ld: *Loader, w: []const u16) []const u8 {
        const s = std.unicode.wtf16LeToWtf8Alloc(ld.a, w) catch return "";
        return std.mem.trim(u8, s, " \t\r\n");
    }

    /// String value `name` of open key `key` as UTF-8, expanded and trimmed; "" when none.
    fn str(ld: *Loader, key: HANDLE, name: [*:0]const u16) []const u8 {
        var w: [4096]u16 = undefined;
        var size: u32 = @sizeOf(@TypeOf(w));
        if (RegGetValueW(key, null, name, RRF_RT_REG_SZ, null, &w, &size) != 0 or size < 2) return "";
        return ld.utf8(std.mem.sliceTo(w[0 .. size / 2], 0));
    }

    /// Calls `f` with each subkey of `root`'s `path`, opened, and its name.
    fn each(ld: *Loader, root: HANDLE, path: [*:0]const u16, comptime f: fn (*Loader, HANDLE, []const u8) void) void {
        var list: ?HANDLE = null;
        if (RegOpenKeyExW(root, path, 0, KEY_READ | KEY_WOW64_64KEY, &list) != 0) return;
        defer _ = RegCloseKey(list.?);
        var i: u32 = 0;
        while (true) : (i += 1) {
            var name: [256]u16 = undefined;
            var n: u32 = name.len;
            const r = RegEnumKeyExW(list.?, i, &name, &n, null, null, null, null);
            if (r == ERROR_NO_MORE_ITEMS) break;
            if (r != 0) continue;
            name[n] = 0;
            var key: ?HANDLE = null;
            if (RegOpenKeyExW(list.?, @ptrCast(&name), 0, KEY_READ | KEY_WOW64_64KEY, &key) != 0) continue;
            defer _ = RegCloseKey(key.?);
            f(ld, key.?, ld.utf8(name[0..n]));
        }
    }

    /// The program of Uninstall entry `key`, unless Settings hides it (a part of Windows, an update of another, no name) or it was seen.
    fn installer(ld: *Loader, key: HANDLE, _: []const u8) void {
        if (dword(key, L("SystemComponent")) == 1 or has(key, L("ParentKeyName"))) return;
        const name = ld.str(key, L("DisplayName"));
        if (name.len == 0) return;
        const version = ld.str(key, L("DisplayVersion"));
        const id = std.fmt.allocPrint(ld.a, "{s}\x00{s}", .{ name, version }) catch return;
        if (!ld.fresh(std.ascii.lowerString(@constCast(id), id))) return;
        const location = std.mem.trimEnd(u8, std.mem.trim(u8, ld.str(key, L("InstallLocation")), "\""), "\\");
        var app: App = .{
            .name = name,
            .version = version,
            .publisher = ld.str(key, L("Publisher")),
            .location = location,
            .icon = ld.iconPath(ld.str(key, L("DisplayIcon"))),
            .uninstall = ld.str(key, L("UninstallString")),
            .package = "",
            .family = "",
            .app_id = "",
            .size = @as(u64, dword(key, L("EstimatedSize")) orelse 0) * 1024,
            .installed = date(ld.str(key, L("InstallDate"))),
            .source = if (dword(key, L("WindowsInstaller")) == 1) .installer else .other,
        };
        if (app.installed == 0) app.installed = created(location);
        ld.add(app);
    }

    /// DisplayIcon `raw` (`"C:\a.exe",0`, `C:\a.exe,0`, `C:\a.ico`) as "path" or "path,index".
    fn iconPath(ld: *Loader, raw: []const u8) []const u8 {
        var path = raw;
        var index: []const u8 = "";
        if (raw.len > 0 and raw[0] == '"') {
            const end = std.mem.findScalarPos(u8, raw, 1, '"') orelse raw.len;
            path = raw[1..end];
            const rest = std.mem.trim(u8, raw[@min(end + 1, raw.len)..], " ");
            if (rest.len > 0 and rest[0] == ',') index = std.mem.trim(u8, rest[1..], " ");
        } else {
            const split = splitIndex(raw);
            path = split.path;
            index = split.index;
        }
        if (index.len == 0 or std.mem.eql(u8, index, "0")) return path;
        return std.fmt.allocPrint(ld.a, "{s},{s}", .{ path, index }) catch path;
    }

    /// Package `full` (its repository key `key`), unless it is part of Windows, a framework or resources, or has no app in the list.
    fn package(ld: *Loader, key: HANDLE, full: []const u8) void {
        const root = std.mem.trimEnd(u8, ld.str(key, L("PackageRootFolder")), "\\");
        if (root.len == 0 or (ld.windows.len > 0 and std.ascii.startsWithIgnoreCase(root, ld.windows))) return;
        const family = familyName(ld.a, full) orelse return;
        const path = std.fmt.allocPrint(ld.a, "{s}\\AppxManifest.xml", .{root}) catch return;
        var buf: [1024]u16 = undefined;
        const xml = readFile(ld.a, widen(&buf, path) orelse return, 4 << 20) orelse return;
        const m = parseManifest(ld.a, xml) orelse return;
        if (!ld.fresh(std.fmt.allocPrint(ld.a, "\x01{s}", .{family}) catch return)) return;
        var name = ld.resource(ld.str(key, L("DisplayName")), full, m.name);
        if (name.len == 0) name = ld.resource(m.display, full, m.name);
        if (name.len == 0) name = m.name;
        ld.add(.{
            .name = name,
            .version = m.version,
            .publisher = ld.resource(m.publisher, full, m.name),
            .location = root,
            .icon = logoFile(ld.a, root, m.logo),
            .uninstall = "",
            .package = full,
            .family = family,
            .app_id = m.app_id,
            .installed = created(root),
            .source = .store,
        });
    }

    /// `s` resolved when it names a resource ("@{...}" or "ms-resource:...", of package `full` named `pkg`), else `s`; "" when it can't be.
    fn resource(ld: *Loader, s: []const u8, full: []const u8, pkg: []const u8) []const u8 {
        const ms = "ms-resource:";
        const indirect = if (std.mem.startsWith(u8, s, "@"))
            s
        else if (std.ascii.startsWithIgnoreCase(s, ms)) blk: {
            const rest = s[ms.len..];
            if (rest.len == 0) return "";
            // "ms-resource:AppName" is in the package's Resources; "ms-resource://pkg/..." names its package.
            const whole = std.mem.startsWith(u8, rest, "//");
            const dir: []const u8 = if (whole or rest[0] == '/') "" else if (std.mem.findScalar(u8, rest, '/') != null) "/" else "/Resources/";
            break :blk std.fmt.allocPrint(ld.a, "@{{{s}?{s}{s}{s}{s}{s}}}", .{ full, ms, if (whole) "" else "//", if (whole) "" else pkg, dir, rest }) catch return "";
        } else return s;
        var src: [2048]u16 = undefined;
        var out: [1024]u16 = undefined;
        if (SHLoadIndirectString(widen(&src, indirect) orelse return "", &out, out.len, null) != 0) return "";
        return ld.utf8(std.mem.sliceTo(&out, 0));
    }

    /// Sizes each app the registry didn't by its folder's, once a folder.
    fn sizes(ld: *Loader) void {
        var known: std.StringHashMapUnmanaged(u64) = .empty;
        defer known.deinit(ld.l.gpa);
        var w: Walker = .{};
        for (ld.out.apps.items) |*app| {
            if (app.size > 0 or !ld.sizable(app.location)) continue;
            const got = known.getOrPut(ld.l.gpa, app.location) catch continue;
            if (!got.found_existing) {
                got.value_ptr.* = 0;
                if (w.start(app.location)) got.value_ptr.* = w.total();
            }
            app.size = got.value_ptr.*;
        }
    }

    /// Whether folder `dir` is one app's: not a drive, Windows or a folder apps share.
    fn sizable(ld: *const Loader, dir: []const u8) bool {
        if (dir.len <= 3 or dir[1] != ':') return false;
        if (ld.windows.len > 0 and std.ascii.startsWithIgnoreCase(dir, ld.windows)) return false;
        if (ld.windows.len > 1 and std.ascii.eqlIgnoreCase(dir, ld.windows[0 .. ld.windows.len - 1])) return false;
        for (ld.shared) |s| if (std.ascii.eqlIgnoreCase(dir, std.mem.trimEnd(u8, s, "\\"))) return false;
        return true;
    }
};

/// "path,index" split at its index, when what follows the last comma is a number.
fn splitIndex(s: []const u8) struct { path: []const u8, index: []const u8 } {
    const comma = std.mem.findScalarLast(u8, s, ',') orelse return .{ .path = s, .index = "" };
    const index = std.mem.trim(u8, s[comma + 1 ..], " ");
    _ = std.fmt.parseInt(i32, index, 10) catch return .{ .path = s, .index = "" };
    return .{ .path = std.mem.trim(u8, s[0..comma], " \""), .index = index };
}

/// `Name_Version_Arch_ResourceId_PublisherId` as `Name_PublisherId`.
fn familyName(a: std.mem.Allocator, full: []const u8) ?[]const u8 {
    const first = std.mem.findScalar(u8, full, '_') orelse return null;
    const last = std.mem.findScalarLast(u8, full, '_') orelse return null;
    if (last == first) return null;
    return std.fmt.allocPrint(a, "{s}{s}", .{ full[0..first], full[last..] }) catch null;
}

/// What a package's manifest says of it.
const Manifest = struct {
    name: []const u8,
    version: []const u8,
    display: []const u8,
    publisher: []const u8,
    app_id: []const u8,
    /// Relative to the package's folder.
    logo: []const u8,
};

/// Manifest `raw`'s package, when it is an app: not a framework or resources, with an application in the list.
fn parseManifest(a: std.mem.Allocator, raw: []const u8) ?Manifest {
    const xml = uncomment(a, raw) orelse return null;
    if (eqlText(xml, "Framework", "true") or eqlText(xml, "ResourcePackage", "true")) return null;
    const identity = element(xml, 0, "Identity") orelse return null;
    var from: usize = 0;
    while (element(xml, from, "Application")) |app| {
        const end = std.mem.findPos(u8, xml, app.end, "</") orelse xml.len;
        const body_end = std.mem.findPos(u8, xml, app.end, "Application>") orelse end;
        from = body_end;
        const ve = element(xml[0..body_end], app.end, "VisualElements");
        if (ve) |v| if (std.ascii.eqlIgnoreCase(attr(v.text, "AppListEntry") orelse "", "none")) continue;
        const id = attr(app.text, "Id") orelse continue;
        const logo = if (ve) |v| attr(v.text, "Square44x44Logo") else null;
        return .{
            .name = unxml(a, attr(identity.text, "Name") orelse ""),
            .version = unxml(a, attr(identity.text, "Version") orelse ""),
            .display = unxml(a, text(xml, "DisplayName") orelse ""),
            .publisher = unxml(a, text(xml, "PublisherDisplayName") orelse ""),
            .app_id = unxml(a, id),
            .logo = unxml(a, logo orelse text(xml, "Logo") orelse ""),
        };
    }
    return null;
}

/// `xml` without its comments.
fn uncomment(a: std.mem.Allocator, xml: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (std.mem.findPos(u8, xml, at, "<!--")) |i| {
        out.appendSlice(a, xml[at..i]) catch return null;
        at = if (std.mem.findPos(u8, xml, i + 4, "-->")) |e| e + 3 else xml.len;
    }
    out.appendSlice(a, xml[at..]) catch return null;
    return out.items;
}

const Tag = struct {
    /// From `<` to `>`.
    text: []const u8,
    /// Just past it.
    end: usize,
};

/// The first start tag of element `tag` (with any namespace prefix) in `xml` from `from`.
fn element(xml: []const u8, from: usize, tag: []const u8) ?Tag {
    var at = from;
    while (std.mem.findPos(u8, xml, at, tag)) |i| {
        at = i + tag.len;
        if (i == 0 or at >= xml.len) return null;
        if (xml[i - 1] != '<' and xml[i - 1] != ':') continue;
        if (std.mem.findScalar(u8, " \t\r\n/>", xml[at]) == null) continue;
        const lt = std.mem.findScalarLast(u8, xml[0..i], '<') orelse continue;
        if (xml[lt + 1] == '/' or std.mem.findAny(u8, xml[lt + 1 .. i], " \t\r\n>\"=") != null) continue;
        const close = std.mem.findScalarPos(u8, xml, at, '>') orelse return null;
        return .{ .text = xml[lt .. close + 1], .end = close + 1 };
    }
    return null;
}

/// Attribute `name` of start tag `tag`, as written.
fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.findPos(u8, tag, at, name)) |i| {
        at = i + name.len;
        if (at + 1 >= tag.len or tag[at] != '=' or !std.ascii.isWhitespace(tag[i - 1])) continue;
        const q = tag[at + 1];
        if (q != '"' and q != '\'') continue;
        const end = std.mem.findScalarPos(u8, tag, at + 2, q) orelse return null;
        return tag[at + 2 .. end];
    }
    return null;
}

/// The text in the first element `tag`, trimmed.
fn text(xml: []const u8, tag: []const u8) ?[]const u8 {
    const t = element(xml, 0, tag) orelse return null;
    if (std.mem.endsWith(u8, t.text, "/>")) return null;
    const end = std.mem.findScalarPos(u8, xml, t.end, '<') orelse return null;
    return std.mem.trim(u8, xml[t.end..end], " \t\r\n");
}

fn eqlText(xml: []const u8, tag: []const u8, want: []const u8) bool {
    return std.ascii.eqlIgnoreCase(text(xml, tag) orelse return false, want);
}

/// `s` with XML's entities as their characters.
fn unxml(a: std.mem.Allocator, s: []const u8) []const u8 {
    if (std.mem.findScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const entities = [_]struct { []const u8, u8 }{ .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&quot;", '"' }, .{ "&apos;", '\'' } };
    outer: while (i < s.len) {
        if (s[i] == '&') for (entities) |e| if (std.mem.startsWith(u8, s[i..], e[0])) {
            out.append(a, e[1]) catch return s;
            i += e[0].len;
            continue :outer;
        };
        out.append(a, s[i]) catch return s;
        i += 1;
    }
    return out.items;
}

/// The file logo `rel` (in package folder `root`) names: of its scale and size variants, a 32 to 48 px one (the light theme's kind first), else the largest scale, else any, else `rel` itself; "" when none is there.
fn logoFile(a: std.mem.Allocator, root: []const u8, rel: []const u8) []const u8 {
    if (rel.len == 0) return "";
    const plain = std.fmt.allocPrint(a, "{s}\\{s}", .{ root, rel }) catch return "";
    std.mem.replaceScalar(u8, plain, '/', '\\');
    const dot = std.mem.findScalarLast(u8, plain, '.') orelse return "";
    const slash = std.mem.findScalarLast(u8, plain, '\\') orelse return "";
    if (dot < slash) return "";
    const stem = plain[slash + 1 .. dot];
    const ext = plain[dot..];
    const pattern = std.fmt.allocPrint(a, "{s}*{s}", .{ plain[0..dot], ext }) catch return "";
    var buf: [1024]u16 = undefined;
    var d: FIND_DATA = .{};
    const h = FindFirstFileExW(widen(&buf, pattern) orelse return "", FindExInfoBasic, &d, 0, null, 0);
    if (h == INVALID_HANDLE or h == null) return "";
    defer _ = FindClose(h.?);
    var best: []const u8 = "";
    var best_score: i32 = -1;
    while (true) {
        var name: [260 * 3]u8 = undefined;
        const n = name[0..std.unicode.wtf16LeToWtf8(&name, d.nameSlice())];
        const s = logoScore(n, stem, ext);
        if (s > best_score) {
            if (std.fmt.allocPrint(a, "{s}{s}", .{ plain[0 .. slash + 1], n })) |p| {
                best = p;
                best_score = s;
            } else |_| {}
        }
        if (FindNextFileW(h.?, &d) == 0) break;
    }
    return best;
}

/// How good file `name` is as logo `stem`+`ext`: -1 when it isn't one (or is for high contrast or a light theme).
fn logoScore(name: []const u8, stem: []const u8, ext: []const u8) i32 {
    if (name.len < stem.len + ext.len or !std.ascii.startsWithIgnoreCase(name, stem) or !std.ascii.endsWithIgnoreCase(name, ext)) return -1;
    const mid = name[stem.len .. name.len - ext.len];
    if (mid.len == 0) return 1;
    if (mid[0] != '.') return -1;
    var target: i32 = 0;
    var scale: i32 = 0;
    // The light theme's variant first (drawn for light backgrounds), then
    // the plated one, then the plain white one meant for dark ones.
    var form: i32 = 100;
    var it = std.mem.splitScalar(u8, mid[1..], '_');
    while (it.next()) |q| {
        if (std.ascii.startsWithIgnoreCase(q, "targetsize-")) {
            target = std.fmt.parseInt(i32, q["targetsize-".len..], 10) catch return -1;
        } else if (std.ascii.startsWithIgnoreCase(q, "scale-")) {
            scale = std.fmt.parseInt(i32, q["scale-".len..], 10) catch return -1;
        } else if (std.ascii.eqlIgnoreCase(q, "altform-lightunplated")) {
            form = 200;
        } else if (std.ascii.eqlIgnoreCase(q, "altform-unplated")) {
            form = 0;
        } else if (!std.ascii.eqlIgnoreCase(q, "contrast-standard")) return -1;
    }
    if (target >= 32 and target <= 48) return 3000 + form - target;
    if (scale > 0) return 1000 + scale;
    if (target > 0) return 100 + @min(target, 256);
    return 1;
}

/// yyyymmdd as Unix seconds (midnight UTC); 0 when it isn't one.
fn date(s: []const u8) i64 {
    if (s.len != 8) return 0;
    const v = std.fmt.parseInt(u32, s, 10) catch return 0;
    const y: i64 = v / 10000;
    const m: i64 = v / 100 % 100;
    const d: i64 = v % 100;
    if (y < 1980 or m < 1 or m > 12 or d < 1 or d > 31) return 0;
    // Days since 1970 of a proleptic Gregorian date (Howard Hinnant's).
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const doy = @divFloor(153 * @mod(m + 9, 12) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return (era * 146097 + doe - 719468) * 86400;
}

/// When file or folder `path` was made, Unix seconds; 0 when unknown.
fn created(path: []const u8) i64 {
    var buf: [1024]u16 = undefined;
    var data: FILE_ATTRIBUTE_DATA = .{};
    if (path.len == 0 or GetFileAttributesExW(widen(&buf, path) orelse return 0, 0, &data) == 0) return 0;
    return unix(data.ftCreationTime);
}

/// FILETIME (100 ns since 1601) as Unix seconds.
fn unix(ft: FILETIME) i64 {
    const t = @as(u64, ft.high) << 32 | ft.low;
    return @as(i64, @intCast(t / 10_000_000)) - 11_644_473_600;
}

/// A folder being sized, with \\?\ so long paths work.
const Walker = struct {
    path: [32768]u16 = undefined,
    len: usize = 0,

    fn start(w: *Walker, dir: []const u8) bool {
        @memcpy(w.path[0..4], L("\\\\?\\"));
        if (dir.len + 8 > w.path.len) return false;
        w.len = 4 + (std.unicode.wtf8ToWtf16Le(w.path[4..], dir) catch return false);
        for (w.path[4..w.len]) |*c| if (c.* == '/') {
            c.* = '\\';
        };
        return true;
    }

    /// The bytes of every file under the path, not following reparse points.
    fn total(w: *Walker) u64 {
        if (w.len + 3 > w.path.len) return 0;
        w.path[w.len..][0..3].* = .{ '\\', '*', 0 };
        var d: FIND_DATA = .{};
        const h = FindFirstFileExW(@ptrCast(&w.path), FindExInfoBasic, &d, 0, null, FIND_FIRST_EX_LARGE_FETCH);
        if (h == INVALID_HANDLE or h == null) return 0;
        defer _ = FindClose(h.?);
        const mark = w.len;
        var sum: u64 = 0;
        while (true) {
            const n = d.nameSlice();
            const dots = std.mem.eql(u16, n, L(".")) or std.mem.eql(u16, n, L(".."));
            if (!dots and d.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT == 0) {
                if (d.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0) {
                    sum += d.size();
                } else if (mark + 1 + n.len + 3 <= w.path.len) {
                    w.path[mark] = '\\';
                    @memcpy(w.path[mark + 1 ..][0..n.len], n);
                    w.len = mark + 1 + n.len;
                    sum += w.total();
                    w.len = mark;
                }
            }
            if (FindNextFileW(h.?, &d) == 0) break;
        }
        return sum;
    }
};

/// `s` as a NUL-ended UTF-16 string in `buf`; null when it doesn't fit.
fn widen(buf: []u16, s: []const u8) ?[*:0]const u16 {
    // UTF-16 never takes more units than UTF-8 takes bytes.
    if (s.len >= buf.len) return null;
    const n = std.unicode.wtf8ToWtf16Le(buf, s) catch return null;
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

/// File `path`'s bytes, up to `max`; null when it can't be read.
fn readFile(gpa: std.mem.Allocator, path: [*:0]const u16, max: u64) ?[]u8 {
    const h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE or h == null) return null;
    defer _ = CloseHandle(h.?);
    var size: i64 = 0;
    if (GetFileSizeEx(h.?, &size) == 0 or size <= 0 or size > max) return null;
    const out = gpa.alloc(u8, @intCast(size)) catch return null;
    var got: usize = 0;
    while (got < out.len) {
        var n: u32 = 0;
        if (ReadFile(h.?, out[got..].ptr, @intCast(out.len - got), &n, null) == 0 or n == 0) break;
        got += n;
    }
    if (got < out.len) {
        gpa.free(out);
        return null;
    }
    return out;
}

/// An installer's icon as its program's path, without the index.
fn iconFile(icon: []const u8) []const u8 {
    return splitIndex(icon).path;
}

/// Opens `file` with `params` as the shell does; whether it started.
fn shell(file: []const u8, params: ?[]const u8) bool {
    var f: [1024]u16 = undefined;
    var p: [4096]u16 = undefined;
    const pw = if (params) |s| widen(&p, s) orelse return false else null;
    return @intFromPtr(ShellExecuteW(null, null, widen(&f, file) orelse return false, pw, null, SW_SHOWNORMAL)) > 32;
}

/// Opens the app: a Store app through `explorer.exe shell:AppsFolder\<family>!<app_id>`; an installer's app by its icon's program when that is an .exe (not an uninstaller: skip names containing "unins"), else its location's folder. Whether something was started.
pub fn open(a: *const App) bool {
    if (a.source == .store) {
        if (a.family.len == 0 or a.app_id.len == 0) return false;
        var buf: [600]u8 = undefined;
        return shell("explorer.exe", std.fmt.bufPrint(&buf, "shell:AppsFolder\\{s}!{s}", .{ a.family, a.app_id }) catch return false);
    }
    const exe = iconFile(a.icon);
    const base = exe[if (std.mem.findLastAny(u8, exe, "\\/")) |i| i + 1 else 0..];
    if (std.ascii.endsWithIgnoreCase(exe, ".exe") and std.ascii.findIgnoreCase(base, "unins") == null and created(exe) != 0) return shell(exe, null);
    return showFolder(a);
}

/// Starts uninstalling: an installer's app by its uninstall command line (CreateProcessW, as Settings does — it shows its own window), a Store app by opening `ms-settings:appsfeatures`. Whether something was started.
pub fn uninstall(a: *const App) bool {
    if (a.source == .store) return shell("ms-settings:appsfeatures", null);
    if (a.uninstall.len == 0) return false;
    var cmd: [4096]u16 = undefined;
    const line = widen(&cmd, a.uninstall) orelse return false;
    var si: STARTUPINFOW = .{};
    var pi: PROCESS_INFORMATION = .{};
    if (CreateProcessW(null, @constCast(line), null, null, 0, 0, null, null, &si, &pi) != 0) {
        _ = CloseHandle(pi.hThread.?);
        _ = CloseHandle(pi.hProcess.?);
        return true;
    }
    // One that must run as Administrator: the shell asks the user first.
    if (GetLastError() != ERROR_ELEVATION_REQUIRED) return false;
    const s = a.uninstall;
    const end = if (s[0] == '"')
        (std.mem.findScalarPos(u8, s, 1, '"') orelse s.len - 1) + 1
    else if (std.ascii.findIgnoreCase(s, ".exe")) |i| i + 4 else std.mem.findScalar(u8, s, ' ') orelse s.len;
    const rest = std.mem.trim(u8, s[end..], " ");
    return shell(std.mem.trim(u8, s[0..end], "\""), if (rest.len > 0) rest else null);
}

/// Shows its location in File Explorer.
pub fn showFolder(a: *const App) bool {
    if (a.location.len == 0) return false;
    var buf: [1100]u8 = undefined;
    return shell("explorer.exe", std.fmt.bufPrint(&buf, "\"{s}\"", .{a.location}) catch return false);
}

/// Its icon as PNG, `size` px square for an installer's (from its program, win_icons; its first icon, whatever the index), a Store app's PNG file as it is (the UI scales it). Caller frees; null when none.
pub fn iconPng(gpa: std.mem.Allocator, a: *const App, size: u32) ?[]u8 {
    if (a.icon.len == 0) return null;
    if (a.source != .store) return icons.exePng(gpa, iconFile(a.icon), size);
    var buf: [1024]u16 = undefined;
    const png = readFile(gpa, widen(&buf, a.icon) orelse return null, 16 << 20) orelse return null;
    if (std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n")) return png;
    gpa.free(png);
    return null;
}

const HKEY_CURRENT_USER: HANDLE = @ptrFromInt(0x80000001);
const HKEY_LOCAL_MACHINE: HANDLE = @ptrFromInt(0x80000002);
const KEY_READ = 0x20019;
const KEY_WOW64_64KEY = 0x100;
const RRF_RT_REG_SZ = 0x2;
const RRF_RT_REG_DWORD = 0x10;
const RRF_RT_ANY = 0xffff;
const ERROR_NO_MORE_ITEMS = 259;
const ERROR_ELEVATION_REQUIRED = 740;
const INVALID_HANDLE: ?HANDLE = @ptrFromInt(std.math.maxInt(usize));
const GENERIC_READ = 0x80000000;
const FILE_SHARE_READ = 0x1;
const OPEN_EXISTING = 3;
const FILE_ATTRIBUTE_DIRECTORY = 0x10;
const FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
const FindExInfoBasic = 1;
const FIND_FIRST_EX_LARGE_FETCH = 2;
const SW_SHOWNORMAL = 1;

/// DWORD value `name` of open key `key`; null when none.
fn dword(key: HANDLE, name: [*:0]const u16) ?u32 {
    var v: u32 = 0;
    var size: u32 = @sizeOf(u32);
    if (RegGetValueW(key, null, name, RRF_RT_REG_DWORD, null, &v, &size) != 0) return null;
    return v;
}

/// Whether open key `key` has value `name`.
fn has(key: HANDLE, name: [*:0]const u16) bool {
    var size: u32 = 0;
    return RegGetValueW(key, null, name, RRF_RT_ANY, null, null, &size) == 0;
}

const FILETIME = extern struct { low: u32 = 0, high: u32 = 0 };

const FILE_ATTRIBUTE_DATA = extern struct {
    dwFileAttributes: u32 = 0,
    ftCreationTime: FILETIME = .{},
    ftLastAccessTime: FILETIME = .{},
    ftLastWriteTime: FILETIME = .{},
    nFileSizeHigh: u32 = 0,
    nFileSizeLow: u32 = 0,
};

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

    fn size(d: *const FIND_DATA) u64 {
        return @as(u64, d.nFileSizeHigh) << 32 | d.nFileSizeLow;
    }
};

const STARTUPINFOW = extern struct {
    cb: u32 = @sizeOf(STARTUPINFOW),
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: ?HANDLE = null,
    hThread: ?HANDLE = null,
    dwProcessId: u32 = 0,
    dwThreadId: u32 = 0,
};

extern "advapi32" fn RegOpenKeyExW(key: HANDLE, sub: [*:0]const u16, options: u32, access: u32, out: *?HANDLE) callconv(.winapi) i32;
extern "advapi32" fn RegEnumKeyExW(key: HANDLE, i: u32, name: [*]u16, n: *u32, reserved: ?*u32, class: ?[*]u16, class_n: ?*u32, time: ?*FILETIME) callconv(.winapi) i32;
extern "advapi32" fn RegGetValueW(key: HANDLE, sub: ?[*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: *u32) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(key: HANDLE) callconv(.winapi) i32;
extern "shlwapi" fn SHLoadIndirectString(src: [*:0]const u16, out: [*]u16, n: u32, reserved: ?*anyopaque) callconv(.winapi) i32;
extern "shell32" fn ShellExecuteW(hwnd: ?HANDLE, verb: ?[*:0]const u16, file: [*:0]const u16, params: ?[*:0]const u16, dir: ?[*:0]const u16, show: c_int) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: [*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: BOOL, flags: u32, env: ?*anyopaque, dir: ?[*:0]const u16, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetWindowsDirectoryW(buf: [*]u16, n: u32) callconv(.winapi) u32;
extern "kernel32" fn ExpandEnvironmentStringsW(src: [*:0]const u16, dst: [*]u16, n: u32) callconv(.winapi) u32;
extern "kernel32" fn GetFileAttributesExW(name: [*:0]const u16, level: u32, data: *FILE_ATTRIBUTE_DATA) callconv(.winapi) BOOL;
extern "kernel32" fn FindFirstFileExW(name: [*:0]const u16, level: u32, data: *FIND_DATA, op: u32, filter: ?*anyopaque, flags: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn FindNextFileW(h: HANDLE, data: *FIND_DATA) callconv(.winapi) BOOL;
extern "kernel32" fn FindClose(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetFileSizeEx(h: HANDLE, size: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: u32, got: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetTempPathW(n: u32, buf: [*]u16) callconv(.winapi) u32;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;

test "manifest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const app =
        \\<Package><!-- <Logo>not this</Logo> -->
        \\  <Identity Name="Some.App" Publisher="CN=A" Version="1.2.3.0" ProcessorArchitecture="x64" />
        \\  <Properties><DisplayName>ms-resource:AppName</DisplayName>
        \\    <PublisherDisplayName>A &amp; B</PublisherDisplayName><Logo>Assets\Store.png</Logo></Properties>
        \\  <Applications>
        \\    <Application Id="Hidden"><uap:VisualElements AppListEntry="none" Square44x44Logo="x.png"/></Application>
        \\    <Application Id="App" Executable="a.exe">
        \\      <uap:VisualElements DisplayName="A" Square44x44Logo="Assets\Square44x44Logo.png" /></Application>
        \\  </Applications></Package>
    ;
    const m = parseManifest(a, app).?;
    try std.testing.expectEqualStrings("Some.App", m.name);
    try std.testing.expectEqualStrings("1.2.3.0", m.version);
    try std.testing.expectEqualStrings("A & B", m.publisher);
    try std.testing.expectEqualStrings("App", m.app_id);
    try std.testing.expectEqualStrings("Assets\\Square44x44Logo.png", m.logo);
    try std.testing.expect(parseManifest(a, "<Package><Identity Name=\"F\" Version=\"1\"/><Properties><Framework>true</Framework></Properties><Applications><Application Id=\"A\"/></Applications></Package>") == null);
    try std.testing.expect(parseManifest(a, "<Package><Identity Name=\"R\" Version=\"1\"/><Properties><ResourcePackage>true</ResourcePackage></Properties></Package>") == null);
    try std.testing.expect(parseManifest(a, "<Package><Identity Name=\"N\" Version=\"1\"/><Properties><Logo>l.png</Logo></Properties></Package>") == null);
    try std.testing.expectEqualStrings("Microsoft.WindowsCalculator_8wekyb3d8bbwe", familyName(a, "Microsoft.WindowsCalculator_11.2607.0.0_x64__8wekyb3d8bbwe").?);
    try std.testing.expect(logoScore("Logo.targetsize-32.png", "Logo", ".png") > logoScore("Logo.targetsize-32_altform-unplated.png", "Logo", ".png"));
    try std.testing.expect(logoScore("Logo.targetsize-32.png", "Logo", ".png") > logoScore("Logo.scale-400.png", "Logo", ".png"));
    try std.testing.expect(logoScore("Logo.scale-200.png", "Logo", ".png") > logoScore("Logo.png", "Logo", ".png"));
    try std.testing.expect(logoScore("Logo.targetsize-32_altform-lightunplated.png", "Logo", ".png") > logoScore("Logo.targetsize-32.png", "Logo", ".png"));
    try std.testing.expect(logoScore("LogoWide.png", "Logo", ".png") < 0);
    try std.testing.expectEqual(@as(i64, 1705276800), date("20240115"));
    try std.testing.expectEqual(@as(i64, 0), date("2024-1-15"));
}

test "the apps on this machine" {
    const gpa = std.testing.allocator;
    var l = List.init(gpa);
    defer l.deinit();
    try std.testing.expect(!l.done());
    const t0 = GetTickCount64();
    l.start();
    l.start();
    while (l.running()) Sleep(10);
    try std.testing.expect(l.take());
    const took = GetTickCount64() - t0;
    // The entries alone, without the sizes, on this thread.
    var only: List = .init(gpa);
    defer only.deinit();
    const t1 = GetTickCount64();
    var ld: Loader = .{ .l = &only, .out = &only.next, .a = only.next.arena.allocator() };
    defer ld.seen.deinit(gpa);
    ld.dirs();
    for (uninstall_keys) |u| ld.each(u.root, u.path, Loader.installer);
    ld.each(HKEY_CURRENT_USER, packages_key, Loader.package);
    const entries_ms = GetTickCount64() - t1;
    try std.testing.expect(l.done());
    const apps = l.items();
    var n_store: usize = 0;
    var sized: usize = 0;
    for (apps) |a| {
        if (a.source == .store) n_store += 1;
        if (a.size > 0) sized += 1;
    }
    std.debug.print("{d} apps ({d} from the Store, {d} sized) in {d} ms; the entries alone {d} ms\n", .{ apps.len, n_store, sized, took, entries_ms });
    try std.testing.expectEqual(apps.len, only.next.apps.items.len);
    for (apps[0..@min(apps.len, 40)]) |a| {
        std.debug.print("{s} | {s} | {s} | {s} | {d:.1} MB | {d} | {s} | {s}\n", .{ a.name, a.version, a.publisher, sourceName(a.source), @as(f64, @floatFromInt(a.size)) / 1e6, a.installed, a.location, a.icon });
    }
    const want = [_][]const u8{ "ChatGPT", "Claude", "Calculator", "Terminal", "Git", "Node.js", "Python" };
    var found: [want.len]?*const App = @splat(null);
    for (apps) |*a| for (want, &found) |w, *f| {
        if (f.* == null and std.ascii.findIgnoreCase(a.name, w) != null) f.* = a;
    };
    for (want, found) |w, f| {
        const a = f orelse {
            std.debug.print("missing: {s}\n", .{w});
            return error.Missing;
        };
        std.debug.print("{s}: {s} ({s}) family={s} app={s}\n", .{ w, a.name, sourceName(a.source), a.family, a.app_id });
    }
    for (found[0..4]) |f| try std.testing.expect(f.?.source == .store and f.?.app_id.len > 0);
    for (found[4..]) |f| try std.testing.expect(f.?.source != .store and f.?.uninstall.len > 0);

    var icons_n: usize = 0;
    var kept: ?[]u8 = null;
    defer if (kept) |k| gpa.free(k);
    for (found) |f| {
        const png = iconPng(gpa, f.?, 32) orelse {
            std.debug.print("{s}: no icon ({s})\n", .{ f.?.name, f.?.icon });
            continue;
        };
        try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png[0..8]);
        std.debug.print("{s}: {d}-byte PNG\n", .{ f.?.name, png.len });
        icons_n += 1;
        if (kept == null) kept = png else gpa.free(png);
    }
    try std.testing.expect(icons_n >= 4);

    // One to look at.
    var dir: [260]u16 = undefined;
    const n = GetTempPathW(dir.len, &dir);
    const name = L("mymonitor-app-icon.png");
    var path: [300:0]u16 = undefined;
    @memcpy(path[0..n], dir[0..n]);
    @memcpy(path[n..][0..name.len], name);
    path[n + name.len] = 0;
    const h = CreateFileW(&path, 0x40000000, 0, null, 2, 0x80, null);
    try std.testing.expect(h != INVALID_HANDLE and h != null);
    defer _ = CloseHandle(h.?);
    var wrote: u32 = 0;
    try std.testing.expect(WriteFile(h.?, kept.?.ptr, @intCast(kept.?.len), &wrote, null) != 0 and wrote == kept.?.len);
}
