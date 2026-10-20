//! The Settings sheet, over the window: General (opening at login, how
//! often to sample, network speeds in bytes or bits, the shortcuts, the
//! version) and Tray (which parts the tray's panel shows, over a picture
//! of the taskbar's corner).
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const ui = myzig.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const about = @import("view_about.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Glyph = @import("glyphs.zig").Glyph;

pub fn sheet(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!a.settings) return;
    const scrim = ui.div(c).absolute().sizeFull().column().center().bg(.{ .a = 0.2 });
    defer scrim.end();
    if (scrim.clicked()) a.settings = false;
    const box = ui.div(c).column().w(580).rounded(10).bg(k.page).border(k.separator).shadowLg().clip();
    defer box.end();
    _ = box.interaction();
    {
        const h = ui.div(c).row().wFull().h(40).itemsCenter().px(12);
        defer h.end();
        const pad = ui.div(c).row().w(28);
        pad.end();
        ui.spacer(c);
        ui.text(c, "Settings", .{ .size = 13, .weight = .medium, .color = k.text });
        ui.spacer(c);
        ui.key(c, "close");
        const x = ui.div(c).row().w(28).h(28).center().rounded(6).hover(k.hover).control();
        defer x.end();
        if (x.clicked()) a.settings = false;
        kit.glyph(c, .close, 14, k.text);
    }
    {
        const tabs = ui.div(c).row().wFull().center().gap(4).pb(6);
        defer tabs.end();
        tab(c, a, k, .general, .gear, "General");
        tab(c, a, k, .tray, .layers, "Tray");
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    const body = ui.div(c).column().wFull().gap(12).p(22).pb(24);
    defer body.end();
    switch (a.settings_tab) {
        .general => general(c, a, k),
        .tray => tray(c, a, k),
    }
}

fn tab(c: *ui.Context, a: *App, k: theme.Colors, t: app_mod.SettingsTab, g: Glyph, name: []const u8) void {
    ui.key(c, name);
    const on = a.settings_tab == t;
    var d = ui.div(c).column().w(76).py(6).gap(3).itemsCenter().rounded(6).control();
    d = if (on) d.bg(k.card) else d.hover(k.hover);
    defer d.end();
    if (d.clicked()) a.settings_tab = t;
    kit.glyph(c, g, 18, if (on) k.accent else k.secondary);
    ui.text(c, name, .{ .size = 11, .color = if (on) k.accent else k.secondary });
}

/// A rounded group of settings, one a line.
fn group(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().px(14).rounded(8).bg(k.card);
}

/// A setting's line: its name (and what it does) on the left; add its
/// control, then `end`.
fn setting(c: *ui.Context, k: theme.Colors, name: []const u8, about_it: []const u8, first: bool) ui.Div {
    if (!first) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    const r = ui.div(c).row().wFull().gap(12).itemsCenter().py(10);
    const t = ui.div(c).column().grow().w(0).gap(2);
    ui.text(c, name, .{ .size = 13, .color = k.text });
    if (about_it.len > 0) ui.text(c, about_it, .{ .size = 11, .color = k.secondary });
    t.end();
    return r;
}

fn general(c: *ui.Context, a: *App, k: theme.Colors) void {
    {
        const g = group(c, k);
        defer g.end();
        {
            const r = setting(c, k, "Open at login", "Starts in the background, without opening its window.", true);
            defer r.end();
            var on = if (a.host) |h| myzig.system.openAtLogin(h) else false;
            if (switchControl(c, k, "login", on)) if (a.host) |h| {
                on = !on;
                myzig.system.setOpenAtLogin(h, on) catch {};
            };
        }
        {
            const r = setting(c, k, "Update every", "", false);
            defer r.end();
            var at: usize = 1;
            for (app_mod.intervals, 0..) |v, i| if (v == a.interval) {
                at = i;
            };
            if (kit.segmented(c, k, &.{ "0.5 s", "1 s", "2 s", "5 s" }, at)) |i| {
                a.interval = app_mod.intervals[i];
                @import("settings.zig").save(a);
            }
        }
        {
            const r = setting(c, k, "Network speeds in", "", false);
            defer r.end();
            if (kit.segmented(c, k, &.{ "Bytes/s", "Bits/s" }, @intFromBool(a.bits))) |i| {
                a.bits = i == 1;
                @import("settings.zig").save(a);
            }
        }
    }
    ui.text(c, "Ctrl+1–9 switch pages · Ctrl+F searches · Ctrl+I shows the inspector · Ctrl+, opens Settings", .{ .size = 11, .color = k.tertiary });
    const g = group(c, k);
    defer g.end();
    const r = setting(c, k, "mymonitor 0.1.0", c.print("Built with Zig {s} on myzig {s}.", .{ builtin.zig_version_string, myzig.version }), true);
    defer r.end();
    _ = ui.svg(c, about.logo, .{ .width = 30, .height = 30 });
}

fn tray(c: *ui.Context, a: *App, k: theme.Colors) void {
    {
        // The taskbar's corner, with mymonitor's icon in it.
        const bar = ui.div(c).row().wFull().h(48).itemsCenter().justifyEnd().gap(12).px(16).rounded(8).bg(k.blue.alpha(0.16));
        defer bar.end();
        const icon = ui.div(c).row().w(26).h(26).center().rounded(4).bg(k.page.alpha(0.6));
        {
            defer icon.end();
            _ = ui.image(c, .{ .key = "tray", .bytes = tray_png, .max_width = 18, .max_height = 18, .radius = 0, .size = .{ .w = 18, .h = 18 } });
        }
        ui.text(c, "mymonitor", .{ .size = 12, .weight = .medium, .color = k.text });
    }
    ui.text(c, "A click on mymonitor's icon in the taskbar's corner shows these, each a tab:", .{ .size = 12, .color = k.secondary });
    const g = group(c, k);
    defer g.end();
    const parts = [_]struct { app_mod.TrayPart, Glyph, ui.Color, []const u8 }{
        .{ .cpu, .cpu, k.blue, "CPU & GPU" },
        .{ .memory, .memory, k.green, "Memory" },
        .{ .disk, .disk, k.orange, "Disk" },
        .{ .network, .network, k.teal, "Network" },
    };
    for (parts, 0..) |p, i| {
        ui.key(c, p[3]);
        if (i > 0) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
        const r = ui.div(c).row().wFull().gap(12).itemsCenter().py(9);
        defer r.end();
        kit.chip(c, p[1], p[2], 26, false);
        ui.text(c, p[3], .{ .size = 13, .color = k.text });
        ui.spacer(c);
        const on = a.tray_parts.get(p[0]);
        if (switchControl(c, k, "on", on)) {
            a.tray_parts.set(p[0], !on);
            // One stays: the panel needs a tab.
            var any = false;
            for (std.enums.values(app_mod.TrayPart)) |t| any = any or a.tray_parts.get(t);
            if (!any) a.tray_parts.set(p[0], true);
            @import("settings.zig").save(a);
        }
    }
}

pub const tray_png = @embedFile("tray.png");

/// A switch, as Windows 11 draws one; whether it was clicked.
pub fn switchControl(c: *ui.Context, k: theme.Colors, key: []const u8, on: bool) bool {
    ui.key(c, key);
    const d = ui.div(c).row().w(40).h(20).itemsCenter().px(4).rounded(10).bg(if (on) k.accent else k.page).border(if (on) k.accent else k.secondary).control();
    defer d.end();
    const clicked = d.clicked();
    const x = c.animate(c.peekId(null), 3, if (on) 1 else 0, 14);
    const pad = ui.div(c).row().w(x * 20);
    pad.end();
    _ = c.leaf(.{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .radius = 6, .background = if (on) ui.Color.white else k.secondary }, .none, null);
    return clicked;
}
