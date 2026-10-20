//! The process table, as Task Manager's: a program's processes together
//! under a line of their sums (a chevron opens it, a pill counts them),
//! each with its program's icon; the columns under a header that sorts
//! when clicked; % CPU warm when busy and hot when very busy; striped rows
//! built only as they come into view (`ui.list`), the selection tinted
//! with the system's blue. A click selects, Ctrl-click marks a process to
//! quit with others (Shift-click a run of them), a double click shows its
//! details, a right-click its menu.
//! Rows are keyed by pid, so the selection follows a process as it moves
//! through the table.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

pub const row_h = 26;
const header_h = 30;
const pad = 10;

const Column = struct { title: []const u8, key: model.Sort, width: ?f32 = null, right: bool = true };

pub const columns = [_]Column{
    .{ .title = "Name", .key = .name, .right = false },
    .{ .title = "% CPU", .key = .cpu, .width = 80 },
    .{ .title = "% GPU", .key = .gpu, .width = 72 },
    .{ .title = "Memory", .key = .memory, .width = 92 },
    .{ .title = "Threads", .key = .threads, .width = 76 },
    .{ .title = "CPU Time", .key = .time, .width = 92 },
    .{ .title = "PID", .key = .pid, .width = 72 },
    .{ .title = "User", .key = .user, .width = 120, .right = false },
};

fn cell(c: *ui.Context, col: Column, h: f32) ui.Div {
    var d = ui.div(c).row().h(h).itemsCenter().px(pad).clip();
    d = if (col.width) |w| d.w(w) else d.grow().w(0);
    if (col.right) d = d.justifyEnd();
    return d;
}

/// The 1-point divider between the header's columns.
fn divider(c: *ui.Context, color: ?ui.Color) void {
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .background = color }, .none, null);
}

pub fn table(c: *ui.Context, a: *App, k: theme.Colors) void {
    const box = ui.div(c).column().wFull().grow().bg(k.page).clip();
    defer box.end();
    {
        const h = ui.div(c).row().wFull().h(header_h).itemsCenter().px(14);
        defer h.end();
        for (columns, 0..) |col, i| {
            if (i > 0) divider(c, k.separator);
            ui.key(c, col.title);
            var d = cell(c, col, header_h).gap(4).control();
            d = d.hover(k.hover);
            defer d.end();
            if (d.clicked()) a.sortBy(col.key);
            const on = a.sort == col.key;
            ui.text(c, col.title, .{ .size = 12, .weight = if (on) .semibold else .regular, .color = if (on) k.text else k.secondary });
            if (on) kit.glyph(c, if (a.ascending) .chevron_up else .chevron_down, 9, k.secondary);
        }
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    const procs = a.sampler.procs.items;
    var rows = ui.list(c, .{ .count = a.rows.items.len, .row_height = row_h, .scroll_to = reveal(c, a), .padding = .{ .left = 14, .right = 14, .top = 4 } });
    while (rows.next()) |i| row(c, a, k, procs[a.rows.items[i]], a.lines.items[i], i);
    rows.end();
    menu(c, a);
}

/// What a right-click on a process offers.
fn menu(c: *ui.Context, a: *App) void {
    const m = ui.menu(c, &a.proc_menu) orelse return;
    defer m.end();
    const p = a.find(a.menu_pid) orelse return a.proc_menu.close();
    const may = !App.untouchable(p.pid);
    if (m.item(c.print("Quit \u{201C}{s}\u{201D}", .{p.name}), .{ .disabled = !may })) {
        a.confirm = p.pid;
        a.proc_menu.close();
    }
    if (m.item("Force Quit", .{ .disabled = !may })) {
        a.quit(p.pid, true);
        a.proc_menu.close();
    }
    m.separator();
    if (m.item("Inspect", .{ .shortcut = "Ctrl+I" })) {
        a.selected = p.pid;
        a.panel = true;
        a.proc_menu.close();
    }
    m.separator();
    if (m.item("Copy PID", .{})) {
        myzig.clipboard.writeText(c.print("{d}", .{p.pid}));
        a.proc_menu.close();
    }
    if (m.item("Copy Path", .{ .disabled = p.bundle.len == 0 })) {
        myzig.clipboard.writeText(p.bundle);
        a.proc_menu.close();
    }
    if (comptime @import("builtin").os.tag == .windows) if (m.item("Copy Command", .{})) {
        var buf: [8192]u8 = undefined;
        myzig.clipboard.writeText(@import("sample.zig").os.commandLine(p.pid, &buf));
        a.proc_menu.close();
    };
    m.separator();
    if (m.item(c.print("Show Only \u{201C}{s}\u{201D}", .{p.name}), .{})) {
        a.showOnly(p);
        a.proc_menu.close();
    }
    if (m.item(c.print("Hide \u{201C}{s}\u{201D}", .{p.name}), .{})) {
        a.hide(p);
        a.proc_menu.close();
    }
}

/// Where the list scrolls so the selection the keyboard moved shows.
fn reveal(c: *ui.Context, a: *App) ?f32 {
    if (!a.reveal) return null;
    a.reveal = false;
    const at = a.selectedRow() orelse return null;
    const id = c.peekId(null);
    const view_h = if (c.rects.get(id)) |r| r.h else return null;
    const scroll = c.scroll.get(id) orelse 0;
    const y = @as(f32, @floatFromInt(at)) * row_h;
    if (y < scroll) return y;
    if (y + row_h > scroll + view_h) return y + row_h - view_h;
    return null;
}

/// "20:19:58", "0:08.07": CPU time as Task Manager writes it.
pub fn cpuTime(c: *ui.Context, ns: u64) []const u8 {
    const cs = ns / 10_000_000;
    const s = cs / 100;
    if (s >= 3600) return c.print("{d}:{d:0>2}:{d:0>2}", .{ s / 3600, (s / 60) % 60, s % 60 });
    return c.print("{d}:{d:0>2}.{d:0>2}", .{ s / 60, s % 60, cs % 100 });
}

/// The color of a % CPU: warm when busy, hot when very busy.
pub fn heat(k: theme.Colors, cpu: f32, normal: ui.Color) ui.Color {
    if (cpu >= 90) return k.hot;
    if (cpu >= 50) return k.warm;
    return normal;
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, p: model.Process, l: app_mod.Line, i: usize) void {
    // Keyed by pid (and a group by its program): the selection and the
    // eased figures follow the process.
    ui.key(c, if (l.kind == .group) c.print("group-{d}", .{l.key}) else c.print("pid-{d}", .{p.pid}));
    const sel = a.selected == p.pid;
    const marked = a.marked.contains(p.pid);
    const bg = if (sel) k.selection else if (marked) k.marked else if (i % 2 == 1) k.stripe else k.page;
    const r = ui.div(c).row().wFull().h(row_h).itemsCenter().rounded(5).bg(bg);
    defer r.end();
    const it = r.interaction();
    if (it.clicked) {
        if (c.input.adding()) a.mark(p.pid) else if (c.input.shift) a.markTo(p.pid) else a.selected = p.pid;
        c.changed = true;
    }
    if (it.double_clicked) a.panel = true;
    // A right-click selects it and opens its menu.
    if (c.input.right_pressed and it.hovered and !a.proc_menu.isOpen()) {
        c.input.right_pressed = false;
        a.selected = p.pid;
        a.menu_pid = p.pid;
        a.proc_menu.openAt(c.input.mouse);
        c.changed = true;
    }
    const text = if (sel) k.on_selection else k.text;
    const muted = k.secondary;
    var buf: [32]u8 = undefined;
    for (columns) |col| {
        const d = cell(c, col, row_h);
        defer d.end();
        switch (col.key) {
            .name => nameCell(c, a, k, p, l, text),
            .cpu => if (p.known or l.kind == .group) {
                ui.text(c, c.print("{d:.1}", .{l.cpu}), .{ .size = 12.5, .weight = if (l.cpu >= 50) .semibold else .regular, .color = heat(k, l.cpu, text) });
            } else dash(c, k),
            .gpu => ui.text(c, c.print("{d:.1}", .{l.gpu}), .{ .size = 12.5, .color = if (l.gpu < 0.05) k.tertiary else text }),
            .memory => if (p.known or l.kind == .group) ui.text(c, c.print("{s}", .{model.bytes(&buf, l.memory)}), .{ .size = 12.5, .color = if (l.memory == 0) k.tertiary else text }) else dash(c, k),
            .threads => ui.text(c, c.print("{s}", .{model.count(&buf, l.threads)}), .{ .size = 12.5, .color = text }),
            .time => if (p.known or l.kind == .group) ui.text(c, cpuTime(c, l.time_ns), .{ .size = 12.5, .color = text }) else dash(c, k),
            .pid => ui.text(c, c.print("{d}", .{p.pid}), .{ .size = 12.5, .color = muted }),
            .user => ui.text(c, p.user, .{ .size = 12.5, .color = muted }),
            else => {},
        }
    }
}

/// Not ours to read.
fn dash(c: *ui.Context, k: theme.Colors) void {
    ui.text(c, "–", .{ .size = 12.5, .color = k.tertiary });
}

fn nameCell(c: *ui.Context, a: *App, k: theme.Colors, p: model.Process, l: app_mod.Line, color: ui.Color) void {
    // The chevron of a group, or room for it; members sit further in.
    if (l.kind == .member) {
        const in = ui.div(c).row().w(22);
        in.end();
    }
    {
        ui.key(c, "open");
        const b = ui.div(c).row().w(22).h(22).center().rounded(4).control();
        defer b.end();
        if (l.kind == .group) {
            if (b.clicked()) a.toggleGroup(l.key);
            kit.glyph(c, if (a.open_groups.contains(l.key)) .chevron_down else .chevron_right, 11, k.secondary);
        }
    }
    kit.icon(c, a, k, p.bundle, 16);
    const gap = ui.div(c).row().w(8);
    gap.end();
    ui.text(c, p.name, .{ .size = 12.5, .color = color });
    if (l.kind == .group) {
        const space = ui.div(c).row().w(6);
        space.end();
        const pill = ui.div(c).row().px(6).py(1).rounded(8).bg(k.well);
        defer pill.end();
        ui.text(c, c.print("{d}", .{l.count}), .{ .size = 10.5, .color = k.secondary });
    }
}
