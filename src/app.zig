//! mymonitor's state: the sampler, when it last sampled (unless paused), the
//! page shown and the time its graphs span, which processes show (all, the
//! user's, the system's) and in what order, processes grouped as apps, the
//! selection, the inspector and a process to quit once asked.
const std = @import("std");
const model = @import("model.zig");
const sample = @import("sample.zig");
const icons = @import("icons.zig");
const myzig = @import("myzig");
const builtin = @import("builtin");

extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn getuid() c_uint;
extern "c" fn getpid() c_int;

fn sendSignal(pid: c_int, sig: c_int) callconv(.c) c_int {
    if (comptime builtin.os.tag == .windows) return if (sig == 9) sample.os.terminate(pid) else sample.os.close(pid);
    return kill(pid, sig);
}

/// Seconds between samples to choose from, and the first.
pub const intervals = [_]f32{ 0.5, 1, 2, 5 };
pub const default_interval: f32 = 1;

/// Activity Monitor's View menu: which processes the table shows.
pub const Filter = enum {
    all,
    /// The user's programs that have an icon: what they opened.
    apps,
    mine,
    system,

    pub fn title(f: Filter) []const u8 {
        return switch (f) {
            .all => "All Processes",
            .apps => "Apps",
            .mine => "My Processes",
            .system => "System Processes",
        };
    }
};

/// The sidebar's pages.
pub const Page = enum { overview, processes, cpu, memory, gpu, disk, network, energy, apps, cleanup, about };

/// How far back the graphs reach.
pub const Range = enum {
    m1,
    m5,
    m15,
    h1,

    pub fn seconds(r: Range) f32 {
        return switch (r) {
            .m1 => 60,
            .m5 => 300,
            .m15 => 900,
            .h1 => 3600,
        };
    }

    /// Samples across the range, taken every `interval` seconds.
    pub fn samples(r: Range, interval: f32) usize {
        return @intFromFloat(r.seconds() / interval);
    }

    pub fn title(r: Range) []const u8 {
        return switch (r) {
            .m1 => "1m",
            .m5 => "5m",
            .m15 => "15m",
            .h1 => "1h",
        };
    }
};

/// An app: its processes together (Chrome and its helpers).
pub const AppRow = struct {
    name: []const u8,
    bundle: []const u8,
    processes: u32 = 0,
    cpu: f32 = 0,
    memory: u64 = 0,
    threads: u32 = 0,
    gpu: f32 = 0,
    disk_rate: f32 = 0,
    /// Its first process, for the inspector.
    pid: i32 = 0,
};

/// The installed apps' columns.
pub const InstalledSort = enum { name, version, publisher, size, installed, source };

/// What a graph's column under the pointer holds: how long ago, and each
/// series' value.
pub const Hover = struct { ago: f32, values: [4]f32 = @splat(0) };

pub const Notify = sample.Notify;

/// The graphs that read out their column under the pointer.
pub const Graph = enum { cpu, memory, gpu, disk, network, battery };

/// A line of the process table: one process; a program's processes
/// together, its first one standing for them, with their figures summed;
/// or one of those, under it.
pub const Line = struct {
    kind: enum { single, group, member } = .single,
    /// How many processes a group holds.
    count: u32 = 1,
    cpu: f32 = 0,
    gpu: f32 = 0,
    memory: u64 = 0,
    threads: u32 = 0,
    time_ns: u64 = 0,
    /// Its program, which names the group (`groupKey`).
    key: u64 = 0,
};

/// The Settings sheet's tabs.
pub const SettingsTab = enum { general, tray };

/// The parts the tray's panel can show, each a tab of it.
pub const TrayPart = enum { cpu, memory, disk, network };

pub const App = struct {
    sampler: sample.Sampler,
    icons: icons.Icons,
    /// Samples by itself (tests fill it instead).
    live: bool = true,
    last: f64 = -1e9,
    /// Seconds between samples.
    interval: f32 = default_interval,
    tab: model.Tab = .cpu,
    page: Page = .overview,
    range: Range = .m1,
    /// Sampling stopped: the graphs hold still.
    paused: bool = false,
    apps: std.ArrayList(AppRow) = .empty,
    /// Where the filter's menu opens, under its button.
    menu_at: [2]f32 = .{ 0, 0 },
    /// Each graph's column under the pointer, as last drawn.
    hovers: std.EnumArray(Graph, ?Hover) = .initFill(null),
    /// Processes marked to quit together, and the sheet asking first.
    marked: std.AutoArrayHashMapUnmanaged(i32, void) = .empty,
    confirm_marked: bool = false,
    /// What quitting did, shown for a while.
    notice: [120]u8 = undefined,
    notice_len: usize = 0,
    notice_until: f64 = 0,
    /// The clock as the view last saw it.
    now: f64 = 0,
    /// How a signal is sent (tests record instead).
    send: *const fn (pid: c_int, sig: c_int) callconv(.c) c_int = sendSignal,
    filter: Filter = .all,
    sort: model.Sort = .cpu,
    ascending: bool = false,
    query: myzig.ui.TextBuffer = .{},
    /// The table's order: indices into the sample's processes, and what
    /// each line is (a group's first process stands for the group).
    rows: std.ArrayList(u32) = .empty,
    lines: std.ArrayList(Line) = .empty,
    /// Processes of a program together, in groups; and those shown open,
    /// by their program (`groupKey`).
    tree: bool = true,
    open_groups: std.AutoHashMapUnmanaged(u64, void) = .empty,
    dirty: bool = true,
    selected: ?i32 = null,
    /// A process to quit, waiting for the user to confirm; one inspected.
    confirm: ?i32 = null,
    inspect: ?i32 = null,
    /// The View menu (the toolbar's ⋯) is open.
    menu: bool = false,
    /// The keyboard moved the selection: scroll it into view.
    reveal: bool = false,
    /// ⌘F: the search takes the keys.
    find_search: bool = false,
    /// The user running mymonitor: "My Processes".
    uid: u32 = 0,
    /// Light or dark, fixed (tests); else as the system shows.
    dark: ?bool = null,
    /// Drawn again when figures come between samples.
    window: ?*myzig.Window = null,
    /// ps has answered since the last frame.
    fresh: bool = false,
    /// The page the last frame drew.
    drawn: ?Page = null,
    /// The details beside the table of what is selected (a process, an
    /// installed app).
    panel: bool = true,
    /// The selected process's CPU and memory over the last samples, for
    /// its details' graphs.
    sel_pid: ?i32 = null,
    sel_cpu: model.History(240) = .{},
    sel_memory: model.History(240) = .{},
    /// A process's menu (right-click), and the process it is for.
    proc_menu: myzig.ui.Menu = .{},
    menu_pid: i32 = 0,
    /// Programs the table shows alone, or leaves out (`groupKey`).
    only: ?u64 = null,
    hidden: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// The installed apps, the one selected, the one a menu is for, and
    /// the one the sheet asks to uninstall (by their names' hashes, which
    /// outlast reading the list again).
    installed: if (builtin.os.tag == .windows) @import("win_apps.zig").List else void = undefined,
    app_selected: ?u64 = null,
    app_menu: myzig.ui.Menu = .{},
    menu_app: u64 = 0,
    confirm_uninstall: ?u64 = null,
    /// An app being uninstalled: the list is read again every few seconds
    /// until it is gone (or a while has passed).
    uninstalling: ?u64 = null,
    uninstall_at: f64 = 0,
    checked_at: f64 = 0,
    installed_sort: InstalledSort = .name,
    installed_ascending: bool = true,
    /// The sidebar folded to its symbols.
    narrow: bool = false,
    /// Network rates in bits a second, not bytes.
    bits: bool = false,
    /// The Settings sheet, and its tab.
    settings: bool = false,
    settings_tab: SettingsTab = .general,
    /// What the tray's panel shows, and its tab now.
    tray_parts: std.EnumArray(TrayPart, bool) = .init(.{ .cpu = true, .memory = true, .disk = false, .network = false }),
    tray_tab: TrayPart = .cpu,
    /// The app, for opening at login and quitting; null in tests.
    host: ?*myzig.App = null,
    /// Asks for the window to show (the tray's panel), and for the app to
    /// end (its menu).
    on_open: ?Notify = null,
    /// What Cleanup found (and which of it is ticked), and the sheet asking
    /// before it goes to the Recycle Bin.
    cleanup: if (builtin.os.tag == .windows) @import("cleanup_win.zig").Scanner else void = undefined,
    /// Cleanup's kinds and groups shown open.
    clean_open: [26][7]bool = @splat(@splat(false)),
    clean_groups: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Null shows/scans all local drives; otherwise the selected letter.
    clean_drive: ?u8 = null,
    confirm_clean: bool = false,
    cleaned: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) App {
        const uid: u32 = if (comptime builtin.os.tag != .windows) getuid() else sample.os.me_uid;
        var a: App = .{ .sampler = .{ .gpa = gpa, .io = io }, .icons = .{ .gpa = gpa }, .uid = uid };
        if (comptime builtin.os.tag == .windows) {
            a.cleanup = .init(gpa);
            a.installed = .init(gpa);
        }
        return a;
    }

    /// Hears of ps's answers; `a` must stay where it is from now on.
    pub fn listen(a: *App, window: ?*myzig.Window) void {
        a.window = window;
        a.sampler.on_update = .{ .ctx = a, .func = answered };
    }

    fn answered(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.fresh = true;
        if (a.window) |w| w.redraw();
    }

    pub fn deinit(a: *App) void {
        a.rows.deinit(a.sampler.gpa);
        a.lines.deinit(a.sampler.gpa);
        a.open_groups.deinit(a.sampler.gpa);
        a.hidden.deinit(a.sampler.gpa);
        a.clean_groups.deinit(a.sampler.gpa);
        if (comptime builtin.os.tag == .windows) {
            @import("view_cleanup.zig").waitForCleaning();
            a.cleanup.deinit();
            a.installed.deinit();
        }
        a.apps.deinit(a.sampler.gpa);
        a.marked.deinit(a.sampler.gpa);
        a.icons.deinit();
        a.sampler.deinit();
    }

    /// Samples when it is time; returns the seconds until the next.
    pub fn tick(a: *App, now: f64) f32 {
        if (a.paused) {
            if (a.dirty) a.order();
            return 3600;
        }
        const interval = a.interval;
        if (a.live and now - a.last >= interval) {
            a.sampler.sample(now);
            a.last = now;
            a.dirty = true;
            a.follow();
            // The first percentages soon, not a whole interval later.
            if (a.sampler.samples == 1) a.last = now - interval + 0.6;
        }
        a.now = now;
        if (a.fresh) {
            a.fresh = false;
            a.sampler.refill(now);
            a.dirty = true;
        }
        if (a.dirty) a.order();
        return @floatCast(@max(0.05, interval - (now - a.last)));
    }

    /// The selected process's CPU and memory, a sample more.
    fn follow(a: *App) void {
        if (a.sel_pid != a.selected) {
            a.sel_pid = a.selected;
            a.sel_cpu = .{};
            a.sel_memory = .{};
        }
        const pid = a.selected orelse return;
        const p = a.find(pid) orelse return;
        a.sel_cpu.push(p.cpu);
        a.sel_memory.push(@floatFromInt(p.memory));
    }

    /// Shows only the program of `p`, or every one again.
    pub fn showOnly(a: *App, p: ?model.Process) void {
        a.only = if (p) |q| groupKey(q) else null;
        a.dirty = true;
    }

    /// Leaves out the program of `p`.
    pub fn hide(a: *App, p: model.Process) void {
        a.hidden.put(a.sampler.gpa, groupKey(p), {}) catch {};
        a.dirty = true;
    }

    /// The table: shown by the filter, matching the search, in order; a
    /// program's processes together under the first of them, open or not.
    pub fn order(a: *App) void {
        a.dirty = false;
        const gpa = a.sampler.gpa;
        const procs = a.sampler.procs.items;
        model.sort(procs, a.sort, a.ascending);
        a.rows.clearRetainingCapacity();
        a.lines.clearRetainingCapacity();
        const q = std.mem.trim(u8, a.query.text(), " ");
        var shown: std.ArrayList(u32) = .empty;
        defer shown.deinit(gpa);
        for (procs, 0..) |p, i| {
            switch (a.filter) {
                .all => {},
                .apps => if (p.uid != a.uid or !isApp(p.bundle)) continue,
                .mine => if (p.uid != a.uid) continue,
                .system => if (p.uid == a.uid) continue,
            }
            if (q.len > 0 and !matches(p, q)) continue;
            if (a.only) |key| if (groupKey(p) != key) continue;
            if (a.hidden.count() > 0 and a.hidden.contains(groupKey(p))) continue;
            shown.append(gpa, @intCast(i)) catch return;
        }
        if (!a.tree) {
            // Each on its own line, in the table's order.
            for (shown.items) |pi| {
                const p = procs[pi];
                a.rows.append(gpa, pi) catch return;
                a.lines.append(gpa, .{ .key = groupKey(p), .cpu = p.cpu, .gpu = p.gpu, .memory = p.memory, .threads = p.threads, .time_ns = p.cpu_time_ns }) catch return;
            }
            return a.group();
        }
        // Each process's next in its group, in the table's order.
        const none = std.math.maxInt(u32);
        const next = gpa.alloc(u32, shown.items.len) catch return;
        defer gpa.free(next);
        @memset(next, none);
        var tails: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        defer tails.deinit(gpa);
        var heads: std.ArrayList(u32) = .empty;
        defer heads.deinit(gpa);
        for (shown.items, 0..) |pi, at| {
            const gop = tails.getOrPut(gpa, groupKey(procs[pi])) catch return;
            if (gop.found_existing) next[gop.value_ptr.*] = @intCast(at) else heads.append(gpa, @intCast(at)) catch return;
            gop.value_ptr.* = @intCast(at);
        }
        // Each group's sums, then the groups in order by them.
        const Group = struct { head: u32, sum: Line };
        var groups: std.ArrayList(Group) = .empty;
        defer groups.deinit(gpa);
        for (heads.items) |head| {
            var sum: Line = .{ .key = groupKey(procs[shown.items[head]]), .count = 0 };
            var m = head;
            while (m != none) : (m = next[m]) {
                const p = procs[shown.items[m]];
                sum.count += 1;
                sum.cpu += p.cpu;
                sum.gpu += p.gpu;
                sum.memory += p.memory;
                sum.threads += p.threads;
                sum.time_ns += p.cpu_time_ns;
            }
            if (sum.count > 1) sum.kind = .group;
            groups.append(gpa, .{ .head = head, .sum = sum }) catch return;
        }
        const By = struct { key: model.Sort, asc: bool };
        std.mem.sort(Group, groups.items, By{ .key = a.sort, .asc = a.ascending }, struct {
            fn lt(by: By, x: Group, y: Group) bool {
                const o: std.math.Order = switch (by.key) {
                    .cpu => std.math.order(x.sum.cpu, y.sum.cpu),
                    .gpu => std.math.order(x.sum.gpu, y.sum.gpu),
                    .memory => std.math.order(x.sum.memory, y.sum.memory),
                    .threads => std.math.order(x.sum.threads, y.sum.threads),
                    .time => std.math.order(x.sum.time_ns, y.sum.time_ns),
                    // The table's own order: by name, user, pid, disk.
                    else => return x.head < y.head,
                };
                if (o == .eq) return x.head < y.head;
                return (o == .lt) == by.asc;
            }
        }.lt);
        for (groups.items) |g| {
            a.rows.append(gpa, shown.items[g.head]) catch return;
            a.lines.append(gpa, g.sum) catch return;
            if (g.sum.kind != .group or !a.open_groups.contains(g.sum.key)) continue;
            var m = g.head;
            while (m != none) : (m = next[m]) {
                const p = procs[shown.items[m]];
                a.rows.append(gpa, shown.items[m]) catch return;
                a.lines.append(gpa, .{ .kind = .member, .key = g.sum.key, .cpu = p.cpu, .gpu = p.gpu, .memory = p.memory, .threads = p.threads, .time_ns = p.cpu_time_ns }) catch return;
            }
        }
        a.group();
    }

    /// What groups a process with others: its program's path, else its name.
    pub fn groupKey(p: model.Process) u64 {
        return std.hash.Wyhash.hash(0, if (p.bundle.len > 0) p.bundle else p.name);
    }

    /// Opens or closes the group of `key`.
    pub fn toggleGroup(a: *App, key: u64) void {
        if (!a.open_groups.remove(key)) a.open_groups.put(a.sampler.gpa, key, {}) catch {};
        a.dirty = true;
    }

    /// Processes from the same app bundle (on Windows, program), together.
    fn group(a: *App) void {
        const gpa = a.sampler.gpa;
        a.apps.clearRetainingCapacity();
        var at: std.StringHashMapUnmanaged(usize) = .empty;
        defer at.deinit(gpa);
        for (a.sampler.procs.items) |p| {
            // On Windows every program is an app (by its path, else its
            // name), as Task Manager groups them.
            if (p.bundle.len == 0 and builtin.os.tag != .windows) continue;
            // Helpers inside an app count as the outermost app.
            const outer = if (p.bundle.len > 0) outerBundle(p.bundle) else p.name;
            const gop = at.getOrPut(gpa, outer) catch return;
            if (!gop.found_existing) {
                gop.value_ptr.* = a.apps.items.len;
                const name = if (p.bundle.len > 0) std.fs.path.stem(outer) else p.name;
                a.apps.append(gpa, .{ .name = name, .bundle = outer, .pid = p.pid }) catch return;
            }
            const r = &a.apps.items[gop.value_ptr.*];
            r.processes += 1;
            r.cpu += p.cpu;
            r.memory += p.memory;
            r.threads += p.threads;
            r.gpu += p.gpu;
            r.disk_rate += p.disk_rate;
        }
    }

    /// Whether the program at `path` is one the user opened, not one of
    /// the system's own (Windows').
    pub fn isApp(path: []const u8) bool {
        if (path.len == 0) return false;
        if (builtin.os.tag != .windows) return std.mem.indexOf(u8, path, ".app/") != null;
        return !std.ascii.startsWithIgnoreCase(path, "C:\\Windows\\");
    }

    /// The outermost app bundle in `path`: Chrome for its helpers.
    pub fn outerBundle(path: []const u8) []const u8 {
        const end = std.mem.indexOf(u8, path, ".app") orelse return path;
        return path[0 .. end + 4];
    }

    fn matches(p: model.Process, q: []const u8) bool {
        if (contains(p.name, q) or contains(p.user, q)) return true;
        var buf: [16]u8 = undefined;
        const pid = std.fmt.bufPrint(&buf, "{d}", .{p.pid}) catch return false;
        return std.mem.startsWith(u8, pid, q);
    }

    fn contains(s: []const u8, q: []const u8) bool {
        if (q.len > s.len) return false;
        for (0..s.len - q.len + 1) |i| if (std.ascii.eqlIgnoreCase(s[i..][0..q.len], q)) return true;
        return false;
    }

    /// Sorts by `key`; again on the same key turns the order around.
    pub fn sortBy(a: *App, key: model.Sort) void {
        if (a.sort == key) a.ascending = !a.ascending else {
            a.sort = key;
            a.ascending = key == .name or key == .user or key == .pid;
        }
        a.dirty = true;
    }

    /// Shows another tab, sorted by what it is about.
    pub fn show(a: *App, tab: model.Tab) void {
        if (a.tab == tab) return;
        a.tab = tab;
        a.sort = switch (tab) {
            .cpu => .cpu,
            .memory => .memory,
            .disk => .written,
        };
        a.ascending = false;
        a.dirty = true;
    }

    pub fn setFilter(a: *App, f: Filter) void {
        a.filter = f;
        a.menu = false;
        a.dirty = true;
    }

    pub fn find(a: *App, pid: i32) ?model.Process {
        for (a.sampler.procs.items) |p| if (p.pid == pid) return p;
        return null;
    }

    /// The selection moved up or down the table by `by` rows.
    pub fn step(a: *App, by: i32) void {
        const procs = a.sampler.procs.items;
        if (a.rows.items.len == 0) return;
        const last: i32 = @intCast(a.rows.items.len - 1);
        const at: i32 = if (a.selectedRow()) |i| @intCast(i) else -1;
        const next: i32 = if (at < 0) 0 else std.math.clamp(at + by, 0, last);
        a.selected = procs[a.rows.items[@intCast(next)]].pid;
    }

    /// The selected row's place in the table, if it is shown.
    pub fn selectedRow(a: *App) ?usize {
        const pid = a.selected orelse return null;
        const procs = a.sampler.procs.items;
        for (a.rows.items, 0..) |r, i| if (procs[r].pid == pid) return i;
        return null;
    }

    /// Marks `pid` to quit with others, or unmarks it.
    pub fn mark(a: *App, pid: i32) void {
        if (a.marked.swapRemove(pid)) return;
        a.marked.put(a.sampler.gpa, pid, {}) catch {};
    }

    /// Marks every row from the selected one to `pid`'s, as a shift-click.
    pub fn markTo(a: *App, pid: i32) void {
        const procs = a.sampler.procs.items;
        const from = a.selectedRow() orelse return a.mark(pid);
        var to: usize = from;
        for (a.rows.items, 0..) |r, i| if (procs[r].pid == pid) {
            to = i;
        };
        for (a.rows.items[@min(from, to) .. @max(from, to) + 1]) |r| a.marked.put(a.sampler.gpa, procs[r].pid, {}) catch {};
    }

    /// Marks that still name a process, and what they hold together.
    pub fn markedSummary(a: *App) struct { count: usize, cpu: f32, memory: u64, system: usize } {
        var cpu: f32 = 0;
        var memory: u64 = 0;
        var system: usize = 0;
        var n: usize = 0;
        for (a.marked.keys()) |pid| if (a.find(pid)) |p| {
            n += 1;
            cpu += p.cpu;
            memory += p.memory;
            if (p.uid != a.uid) system += 1;
        };
        return .{ .count = n, .cpu = cpu, .memory = memory, .system = system };
    }

    /// Whether quitting `pid` is out of the question: mymonitor itself,
    /// launchd, the kernel (on Windows, Idle and System).
    pub fn untouchable(pid: i32) bool {
        if (comptime builtin.os.tag == .windows) return pid <= 4 or pid == sample.os.currentPid();
        return pid <= 1 or pid == getpid();
    }

    /// Quits every marked process (asks, or with `force` makes it); says
    /// how many did and how many could not be (not the user's).
    pub fn quitMarked(a: *App, force: bool) void {
        var done: usize = 0;
        var refused: usize = 0;
        var i: usize = 0;
        while (i < a.marked.count()) {
            const pid = a.marked.keys()[i];
            if (a.find(pid) == null or untouchable(pid)) {
                a.marked.swapRemoveAt(i);
                continue;
            }
            const ok = a.send(pid, if (force) 9 else 15) == 0;
            if (ok) {
                done += 1;
                a.marked.swapRemoveAt(i);
            } else {
                refused += 1;
                i += 1;
            }
        }
        a.confirm_marked = false;
        a.last = -1e9;
        const verb = if (force) "Force quit" else "Asked";
        const text: anyerror![]u8 = if (refused == 0)
            std.fmt.bufPrint(&a.notice, "{s} {d} process{s} to quit", .{ verb, done, if (done == 1) "" else "es" })
        else
            std.fmt.bufPrint(&a.notice, "{s} {d} to quit · {d} not yours to quit (left marked)", .{ verb, done, refused });
        a.notice_len = if (text) |t| t.len else |_| 0;
        a.notice_until = a.now + 6;
    }

    pub fn noticeText(a: *App) ?[]const u8 {
        if (a.notice_len == 0 or a.now > a.notice_until) return null;
        return a.notice[0..a.notice_len];
    }

    /// Asks process `pid` to quit (SIGTERM), or makes it (SIGKILL).
    pub fn quit(a: *App, pid: i32, force: bool) void {
        if (!untouchable(pid)) _ = a.send(pid, if (force) 9 else 15);
        a.confirm = null;
        a.last = -1e9;
    }
};

test "the table follows the filter, the search and the sort" {
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    a.live = false;
    a.uid = 501;
    try a.sampler.procs.appendSlice(std.testing.allocator, &.{
        .{ .pid = 10, .ppid = 1, .uid = 0, .name = "launchd", .user = "root", .cpu = 1, .known = true },
        .{ .pid = 20, .ppid = 1, .uid = 501, .name = "Safari", .user = "me", .cpu = 30, .known = true, .memory = 5 },
        .{ .pid = 30, .ppid = 1, .uid = 501, .name = "Mail", .user = "me", .cpu = 3, .known = true, .memory = 9 },
    });
    _ = a.tick(0);
    try std.testing.expectEqualStrings("Safari", a.sampler.procs.items[a.rows.items[0]].name);
    a.query.set("ma");
    a.dirty = true;
    _ = a.tick(0);
    try std.testing.expectEqual(@as(usize, 1), a.rows.items.len);
    a.sortBy(.name);
    a.query.set("");
    _ = a.tick(0);
    try std.testing.expectEqualStrings("launchd", a.sampler.procs.items[a.rows.items[0]].name);
    a.setFilter(.mine);
    _ = a.tick(0);
    try std.testing.expectEqual(@as(usize, 2), a.rows.items.len);
    a.setFilter(.system);
    _ = a.tick(0);
    try std.testing.expectEqual(@as(usize, 1), a.rows.items.len);
    a.setFilter(.all);
    a.show(.memory);
    _ = a.tick(0);
    try std.testing.expectEqualStrings("Mail", a.sampler.procs.items[a.rows.items[0]].name);
    a.step(1);
    try std.testing.expectEqual(@as(?i32, 30), a.selected);
    a.step(1);
    try std.testing.expectEqual(@as(?i32, 20), a.selected);
}
