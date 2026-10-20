//! The Apps page: the installed apps, as Windows' Settings lists them
//! (programs from their installers, and the Microsoft Store's), each with
//! its icon (a green dot when it runs), version, publisher, size, when it
//! was installed and where from; sorted by any of them, searched by name or
//! publisher. A click shows its details beside the list (view_detail.zig),
//! a right-click its menu; uninstalling asks first.
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const ui = myzig.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const procs = @import("view_procs.zig");
const detail = @import("view_detail.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const wa = if (builtin.os.tag == .windows) @import("win_apps.zig") else struct {};

const row_h = 26;

const Column = struct { title: []const u8, by: app_mod.InstalledSort, width: ?f32 = null, right: bool = false };

const columns = [_]Column{
    .{ .title = "Name", .by = .name },
    .{ .title = "Version", .by = .version, .width = 150 },
    .{ .title = "Publisher", .by = .publisher, .width = 180 },
    .{ .title = "Size", .by = .size, .width = 90, .right = true },
    .{ .title = "Installed", .by = .installed, .width = 110 },
    .{ .title = "Source", .by = .source, .width = 130 },
};

fn cell(c: *ui.Context, col: Column, h: f32) ui.Div {
    var d = ui.div(c).row().h(h).itemsCenter().px(10).clip();
    d = if (col.width) |w| d.w(w) else d.grow().w(0);
    if (col.right) d = d.justifyEnd();
    return d;
}

fn keyOf(ia: *const wa.App) u64 {
    return std.hash.Wyhash.hash(0, ia.name);
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (comptime builtin.os.tag != .windows) return;
    const list = &a.installed;
    // Read again each time the page opens: apps come and go elsewhere too.
    if (a.drawn != .apps) list.start();
    _ = list.take();
    if (list.running()) c.frameIn(0.2);
    watch(c, a);
    // The apps shown: matching the search, in order.
    var shown: std.ArrayList(*const wa.App) = .empty;
    var total: u64 = 0;
    if (list.done()) {
        const q = std.mem.trim(u8, a.query.text(), " ");
        for (list.items()) |*ia| {
            if (q.len > 0 and !has(ia.name, q) and !has(ia.publisher, q)) continue;
            shown.append(c.alloc(), ia) catch break;
            total += ia.size;
        }
        sort(a, shown.items);
    }
    {
        const gone: []const u8 = if (a.uninstalling) |key| (if (detail.find(a, key)) |ia| c.print(" · uninstalling {s}…", .{ia.name}) else "") else "";
        const h = kit.header(c, k, "Apps", if (list.done()) c.print("{d} apps · {s}{s}", .{ shown.items.len, kit.bytes(c, total), gone }) else "Reading what is installed…");
        defer h.end();
        procs.search(c, a, k, 220);
        if (kit.roundButton(c, k, "reload", .refresh, k.secondary, !list.running())) list.start();
        if (kit.roundButton(c, k, "panel", .sidebar, if (a.panel) k.accent else k.secondary, true)) a.panel = !a.panel;
        kit.pause(c, a, k);
    }
    const r = ui.div(c).row().wFull().grow().h(0);
    defer r.end();
    {
        const col = ui.div(c).column().grow().w(0).hFull();
        defer col.end();
        {
            const h = ui.div(c).row().wFull().h(30).itemsCenter().px(14);
            defer h.end();
            for (columns, 0..) |cl, i| {
                if (i > 0) _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = 14 }, .background = k.separator }, .none, null);
                ui.key(c, cl.title);
                const d = cell(c, cl, 30).gap(4).hover(k.hover).control();
                defer d.end();
                if (d.clicked()) {
                    if (a.installed_sort == cl.by) a.installed_ascending = !a.installed_ascending else {
                        a.installed_sort = cl.by;
                        a.installed_ascending = cl.by == .name or cl.by == .publisher or cl.by == .source;
                    }
                }
                const on = a.installed_sort == cl.by;
                ui.text(c, cl.title, .{ .size = 12, .weight = if (on) .semibold else .regular, .color = if (on) k.text else k.secondary });
                if (on) kit.glyph(c, if (a.installed_ascending) .chevron_up else .chevron_down, 9, k.secondary);
            }
        }
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
        var rows = ui.list(c, .{ .count = shown.items.len, .row_height = row_h, .padding = .{ .left = 14, .right = 14, .top = 4 } });
        while (rows.next()) |i| row(c, a, k, shown.items[i], i);
        rows.end();
        menu(c, a);
    }
    detail.installed(c, a, k);
}

/// While an app is being uninstalled, reads the list again every three
/// seconds until it has left it, for ten minutes at most.
fn watch(c: *ui.Context, a: *App) void {
    const key = a.uninstalling orelse return;
    const t = ui.clock.now();
    if (detail.find(a, key) == null or t - a.uninstall_at > 600) {
        a.uninstalling = null;
        if (a.app_selected == key) a.app_selected = null;
        return;
    }
    if (t - a.checked_at >= 3 and !a.installed.running()) {
        a.checked_at = t;
        a.installed.start();
    }
    c.frameIn(1);
}

fn has(s: []const u8, q: []const u8) bool {
    return std.ascii.findIgnoreCase(s, q) != null;
}

fn sort(a: *App, items: []*const wa.App) void {
    const By = struct { by: app_mod.InstalledSort, asc: bool };
    std.mem.sort(*const wa.App, items, By{ .by = a.installed_sort, .asc = a.installed_ascending }, struct {
        fn lt(b: By, x: *const wa.App, y: *const wa.App) bool {
            const o: std.math.Order = switch (b.by) {
                .name => std.ascii.orderIgnoreCase(x.name, y.name),
                .version => std.mem.order(u8, x.version, y.version),
                .publisher => std.ascii.orderIgnoreCase(x.publisher, y.publisher),
                .size => std.math.order(x.size, y.size),
                .installed => std.math.order(x.installed, y.installed),
                .source => std.math.order(@intFromEnum(x.source), @intFromEnum(y.source)),
            };
            if (o == .eq) return std.ascii.lessThanIgnoreCase(x.name, y.name);
            return (o == .lt) == b.asc;
        }
    }.lt);
}

/// "Aug 7, 2026".
fn date(c: *ui.Context, at: i64) []const u8 {
    if (at <= 0) return "–";
    const t = @import("win_machine.zig").local(at);
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return c.print("{s} {d}, {d}", .{ months[(t.month -| 1) % 12], t.day, t.year });
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, ia: *const wa.App, i: usize) void {
    const key = keyOf(ia);
    ui.key(c, c.print("app-{d}", .{key}));
    const sel = a.app_selected == key;
    const bg = if (sel) k.selection else if (i % 2 == 1) k.stripe else k.page;
    const d = ui.div(c).row().wFull().h(row_h).itemsCenter().rounded(5).bg(bg);
    defer d.end();
    const it = d.interaction();
    if (it.clicked) {
        a.app_selected = key;
        c.changed = true;
    }
    if (it.double_clicked) a.panel = true;
    if (c.input.right_pressed and it.hovered and !a.app_menu.isOpen()) {
        c.input.right_pressed = false;
        a.app_selected = key;
        a.menu_app = key;
        a.app_menu.openAt(c.input.mouse);
        c.changed = true;
    }
    const text = if (sel) k.on_selection else k.text;
    for (columns) |col| {
        const cl = cell(c, col, row_h);
        defer cl.end();
        switch (col.by) {
            .name => {
                kit.icon(c, a, k, ia.icon, 18);
                const gap = ui.div(c).row().w(9);
                gap.end();
                ui.text(c, ia.name, .{ .size = 12.5, .color = text });
                if (detail.running(a, ia.location).count > 0) {
                    const sp = ui.div(c).row().w(7);
                    sp.end();
                    _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = k.green }, .none, null);
                }
            },
            .version => ui.text(c, if (ia.version.len > 0) ia.version else "–", .{ .size = 12.5, .color = text }),
            .publisher => ui.text(c, if (ia.publisher.len > 0) ia.publisher else "–", .{ .size = 12.5, .color = k.secondary }),
            .size => ui.text(c, if (ia.size > 0) kit.bytes(c, ia.size) else "–", .{ .size = 12.5, .color = text }),
            .installed => ui.text(c, date(c, ia.installed), .{ .size = 12.5, .color = k.secondary }),
            .source => ui.text(c, wa.sourceName(ia.source), .{ .size = 12.5, .color = k.secondary }),
        }
    }
}

/// What a right-click on an app offers.
fn menu(c: *ui.Context, a: *App) void {
    const m = ui.menu(c, &a.app_menu) orelse return;
    defer m.end();
    const ia = detail.find(a, a.menu_app) orelse return a.app_menu.close();
    const run = detail.running(a, ia.location);
    if (m.item("Open", .{})) {
        _ = wa.open(ia);
        a.app_menu.close();
    }
    if (m.item("Uninstall…", .{})) {
        a.confirm_uninstall = a.menu_app;
        a.app_menu.close();
    }
    m.separator();
    if (m.item("Show in File Explorer", .{ .disabled = ia.location.len == 0 })) {
        _ = wa.showFolder(ia);
        a.app_menu.close();
    }
    if (m.item("Show in Processes", .{ .disabled = run.count == 0 })) {
        detail.showProcesses(a, run.first.?);
        a.app_menu.close();
    }
    m.separator();
    if (m.item("Copy Name", .{})) {
        myzig.clipboard.writeText(ia.name);
        a.app_menu.close();
    }
    if (m.item("Copy Path", .{ .disabled = ia.location.len == 0 })) {
        myzig.clipboard.writeText(ia.location);
        a.app_menu.close();
    }
}

/// Asks before an app is uninstalled; its uninstaller does the rest.
pub fn confirm(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (comptime builtin.os.tag != .windows) return;
    const key = a.confirm_uninstall orelse return;
    const ia = detail.find(a, key) orelse {
        a.confirm_uninstall = null;
        return;
    };
    const scrim = ui.div(c).absolute().sizeFull().column().center().bg(.{ .a = 0.25 });
    defer scrim.end();
    if (scrim.clicked()) a.confirm_uninstall = null;
    const box = ui.div(c).column().w(420).gap(14).p(22).rounded(12).bg(k.page).border(k.separator).shadowLg();
    defer box.end();
    _ = box.interaction();
    {
        const h = ui.div(c).row().gap(12).itemsCenter();
        defer h.end();
        kit.icon(c, a, k, ia.icon, 34);
        ui.text(c, c.print("Uninstall {s}?", .{ia.name}), .{ .size = 15, .weight = .semibold, .color = k.text });
    }
    ui.text(c, if (ia.source == .store) "Windows' Settings opens at Installed apps, where it is uninstalled." else "Its uninstaller opens and takes it from there.", .{ .size = 12, .color = k.secondary, .wrap = true });
    const r = ui.div(c).row().wFull().gap(8);
    defer r.end();
    ui.spacer(c);
    if (ui.button(c, "Cancel", .{ .size = 13 }).clicked) a.confirm_uninstall = null;
    if (ui.button(c, "Uninstall", .{ .variant = .primary, .size = 13 }).clicked) {
        if (wa.uninstall(ia)) {
            a.uninstalling = key;
            a.uninstall_at = ui.clock.now();
            a.checked_at = a.uninstall_at;
        }
        a.confirm_uninstall = null;
    }
}
