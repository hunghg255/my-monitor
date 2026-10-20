//! The details beside a table, of what is selected: a process (its icon,
//! name and owner; Quit and Force Quit; its CPU and memory over the last
//! samples; its figures; its parent) or an installed app (Open, Uninstall,
//! its folder; whether it runs, and with what; its figures; its path).
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const ui = myzig.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const table = @import("view_table.zig");
const app_mod = @import("app.zig");
const sample = @import("sample.zig");
const App = app_mod.App;
const wa = if (builtin.os.tag == .windows) @import("win_apps.zig") else struct {};

pub const width = 300;

/// The panel, with an edge on its left; the caller fills it, then ends it.
fn box(c: *ui.Context, k: theme.Colors) kit.Open {
    const outer = ui.div(c).row().w(width).hFull();
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.separator }, .none, null);
    return .{ .outer = outer, .inner = ui.div(c).column().grow().w(0).hFull().scrollY().bg(k.sidebar).p(16).gap(6) };
}

/// Its head: an icon, a name, a line under it, and a button closing it.
fn head(c: *ui.Context, a: *App, k: theme.Colors, bundle: []const u8, name: []const u8, under: []const u8) bool {
    const r = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer r.end();
    kit.icon(c, a, k, bundle, 40);
    {
        const t = ui.div(c).column().grow().w(0).gap(2).clip();
        defer t.end();
        ui.text(c, name, .{ .size = 15, .weight = .bold, .color = k.text });
        ui.text(c, under, .{ .size = 11.5, .color = k.secondary });
    }
    ui.key(c, "close");
    const x = ui.div(c).row().w(26).h(26).center().rounded(6).hover(k.hover).control();
    defer x.end();
    kit.glyph(c, .close, 12, k.secondary);
    return x.clicked();
}

/// A wide button; whether it was clicked.
fn action(c: *ui.Context, k: theme.Colors, text: []const u8, color: ui.Color) bool {
    ui.key(c, text);
    const d = ui.div(c).row().grow().w(0).h(32).center().rounded(6).bg(k.page).border(k.separator).hover(k.hover).control();
    defer d.end();
    ui.text(c, text, .{ .size = 13, .color = color });
    return d.clicked();
}

fn section(c: *ui.Context, k: theme.Colors, name: []const u8) void {
    const d = ui.div(c).row().wFull().pt(12).pb(2);
    defer d.end();
    ui.text(c, name, .{ .size = 11, .weight = .semibold, .color = k.secondary });
}

/// A part's figure over its graph in a tinted card.
fn graph(c: *ui.Context, a: *App, k: theme.Colors, name: []const u8, value: []const u8, color: ui.Color, values: []const f32, unit: kit.Unit, scale: ?f32) void {
    const d = ui.div(c).column().wFull().gap(8).p(12).rounded(10).bg(color.alpha(0.1));
    defer d.end();
    {
        const r = ui.div(c).row().wFull();
        defer r.end();
        ui.text(c, name, .{ .size = 12, .weight = .semibold, .color = color });
        ui.spacer(c);
        ui.text(c, value, .{ .size = 12, .weight = .semibold, .color = k.text });
    }
    kit.dots(c, k, a, &.{.{ .values = values, .color = color, .name = name, .unit = unit }}, scale, 40, false, null, color);
}

/// "Sep 21, 18:28 · 28d 13h ago".
fn started(c: *ui.Context, at: i64, now_s: i64) []const u8 {
    if (at <= 0 or builtin.os.tag != .windows) return "–";
    const t = @import("win_machine.zig").local(at);
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var b: [32]u8 = undefined;
    return c.print("{s} {d}, {d:0>2}:{d:0>2} · {s} ago", .{ months[(t.month -| 1) % 12], t.day, t.hour, t.minute, model.uptime(&b, @intCast(@max(0, now_s - at))) });
}

fn now() i64 {
    if (builtin.os.tag != .windows) return 0;
    return @import("cleanup_win.zig").now();
}

/// The selected process's details; nothing when none is selected.
pub fn process(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!a.panel) return;
    const pid = a.selected orelse return;
    const p = a.find(pid) orelse return;
    const d = box(c, k);
    defer d.end();
    const gap = ui.div(c).row().h(4);
    gap.end();
    if (head(c, a, k, p.bundle, p.name, if (p.user.len > 0) c.print("PID {d} · {s}", .{ p.pid, p.user }) else c.print("PID {d}", .{p.pid}))) a.selected = null;
    {
        const r = ui.div(c).row().wFull().gap(8);
        defer r.end();
        const may = !App.untouchable(p.pid);
        if (action(c, k, "Quit", if (may) k.text else k.tertiary) and may) a.confirm = p.pid;
        if (action(c, k, "Force Quit", if (may) k.red else k.tertiary) and may) a.quit(p.pid, true);
    }
    const cpu = a.sel_cpu.slice();
    graph(c, a, k, "CPU", c.print("{d:.1}%", .{p.cpu}), k.blue, cpu, .percent, @max(100, kit.peak(cpu, cpu.len)));
    graph(c, a, k, "Memory", kit.bytes(c, p.memory), k.green, a.sel_memory.slice(), .bytes, null);
    section(c, k, "DETAILS");
    var b: [2][32]u8 = undefined;
    kit.line(c, k, "CPU time", table.cpuTime(c, p.cpu_time_ns), null);
    kit.line(c, k, "Threads", c.print("{s}", .{model.count(&b[0], p.threads)}), null);
    kit.line(c, k, "GPU", c.print("{d:.1}%", .{p.gpu}), null);
    kit.line(c, k, "Private memory", kit.bytes(c, p.memory), null);
    if (p.virtual > 0) kit.line(c, k, "Virtual memory", kit.bytes(c, p.virtual), null);
    kit.line(c, k, "Disk", c.print("{s} · {s}", .{ kit.rate(c, a, p.disk_rate), kit.bytes(c, p.disk_read + p.disk_written) }), null);
    kit.line(c, k, "Started", started(c, p.started, now()), null);
    kit.line(c, k, "State", "Running", null);
    if (p.bundle.len > 0) {
        section(c, k, "PATH");
        ui.text(c, p.bundle, .{ .size = 11.5, .mono = true, .color = k.secondary, .wrap = true });
    }
    if (a.find(p.ppid)) |parent| {
        section(c, k, "PARENT");
        ui.key(c, "parent");
        const r = ui.div(c).row().wFull().h(30).gap(8).itemsCenter().px(6).rounded(6).hover(k.hover).control();
        defer r.end();
        if (r.clicked()) a.selected = parent.pid;
        kit.appName(c, a, k, parent.bundle, parent.name, 0);
        ui.text(c, c.print("{d}", .{parent.pid}), .{ .size = 11, .color = k.tertiary });
    }
}

/// The processes of installed app `ia`: whose program lives in its folder.
pub fn running(a: *App, location: []const u8) struct { count: u32, cpu: f32, memory: u64, first: ?model.Process } {
    var r: @TypeOf(running(a, location)) = .{ .count = 0, .cpu = 0, .memory = 0, .first = null };
    if (location.len < 4) return r;
    const loc = std.mem.trimEnd(u8, location, "\\");
    for (a.sampler.procs.items) |p| {
        if (p.bundle.len <= loc.len or !std.ascii.startsWithIgnoreCase(p.bundle, loc) or p.bundle[loc.len] != '\\') continue;
        r.count += 1;
        r.cpu += p.cpu;
        r.memory += p.memory;
        if (r.first == null or p.memory > r.first.?.memory) r.first = p;
    }
    return r;
}

/// The selected installed app's details; nothing when none is selected.
pub fn installed(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (comptime builtin.os.tag != .windows) return;
    if (!a.panel or !a.installed.done()) return;
    const key = a.app_selected orelse return;
    const ia = find(a, key) orelse return;
    const d = box(c, k);
    defer d.end();
    if (head(c, a, k, ia.icon, ia.name, if (ia.publisher.len > 0) ia.publisher else wa.sourceName(ia.source))) a.app_selected = null;
    {
        const r = ui.div(c).row().wFull().gap(8);
        defer r.end();
        if (action(c, k, "Open", k.text)) _ = wa.open(ia);
        if (action(c, k, "Uninstall", k.red)) a.confirm_uninstall = key;
        ui.key(c, "folder");
        const f = ui.div(c).row().w(40).h(32).center().rounded(6).bg(k.page).border(k.separator).hover(k.hover).control();
        defer f.end();
        if (f.clicked()) _ = wa.showFolder(ia);
        kit.glyph(c, .disk, 15, k.secondary);
    }
    const run = running(a, ia.location);
    if (run.count > 0) {
        ui.key(c, "running");
        const r = ui.div(c).row().wFull().gap(10).itemsCenter().p(12).rounded(10).bg(k.green.alpha(0.12)).hover(k.green.alpha(0.18)).control();
        defer r.end();
        if (r.clicked()) showProcesses(a, run.first.?);
        _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = k.green }, .none, null);
        {
            const t = ui.div(c).column().grow().w(0).gap(2);
            defer t.end();
            ui.text(c, "Running", .{ .size = 12.5, .weight = .semibold, .color = k.green });
            ui.text(c, c.print("{d} process{s} · {d:.1}% CPU · {s}", .{ run.count, if (run.count == 1) "" else "es", run.cpu, kit.bytes(c, run.memory) }), .{ .size = 11, .color = k.secondary });
        }
        kit.glyph(c, .chevron_right, 11, k.secondary);
    }
    section(c, k, "DETAILS");
    kit.line(c, k, "Version", if (ia.version.len > 0) ia.version else "–", null);
    kit.line(c, k, "Size", if (ia.size > 0) kit.bytes(c, ia.size) else "–", null);
    kit.line(c, k, "Source", wa.sourceName(ia.source), null);
    if (ia.package.len > 0) kit.line(c, k, "Package", short(c, ia.package, 30), null);
    if (ia.publisher.len > 0) kit.line(c, k, "Publisher", ia.publisher, null);
    if (ia.location.len > 0) {
        section(c, k, "PATH");
        ui.text(c, ia.location, .{ .size = 11.5, .mono = true, .color = k.secondary, .wrap = true });
    }
}

/// `s`, cut to `n` bytes with an ellipsis when longer.
fn short(c: *ui.Context, s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    return c.print("{s}…", .{s[0..n]});
}

/// The installed app whose name hashes to `key`.
pub fn find(a: *App, key: u64) ?*const wa.App {
    if (comptime builtin.os.tag != .windows) return null;
    for (a.installed.items()) |*ia| if (std.hash.Wyhash.hash(0, ia.name) == key) return ia;
    return null;
}

/// The Processes page, showing only the program of `p`.
pub fn showProcesses(a: *App, p: model.Process) void {
    a.page = .processes;
    a.filter = .all;
    a.showOnly(p);
    a.selected = p.pid;
}
