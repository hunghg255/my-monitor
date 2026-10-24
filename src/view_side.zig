//! The sidebar: a button that folds it to its symbols, the pages, each
//! with its colored chip and, beside its name, its figure now (how many
//! processes, CPU and memory in use, the GPU's load, the disk's and
//! network's rates, the battery), and at the bottom the machine's name
//! and chip beside the Settings button.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Glyph = @import("glyphs.zig").Glyph;

pub const width = 220;
pub const narrow_width = 60;

const Item = struct { page: app_mod.Page, glyph: Glyph, name: []const u8 };

/// Each page's symbol and color, as its cards have them too.
pub fn look(k: theme.Colors, page: app_mod.Page) struct { Glyph, ui.Color } {
    return switch (page) {
        .overview => .{ .overview, k.gray },
        .processes => .{ .processes, k.gray },
        .cpu => .{ .cpu, k.blue },
        .memory => .{ .memory, k.green },
        .gpu => .{ .gpu, k.red },
        .disk => .{ .disk, k.orange },
        .network => .{ .network, k.teal },
        .energy => .{ .energy, k.yellow },
        .apps => .{ .apps, k.gray },
        .cleanup => .{ .cleanup, k.orange },
        .about => .{ .laptop, k.gray },
    };
}

pub fn memPercent(sy: model.System) f32 {
    if (sy.mem_total == 0) return 0;
    return @floatCast(@as(f64, @floatFromInt(sy.memUsed())) / @as(f64, @floatFromInt(sy.mem_total)) * 100);
}

pub fn sidebar(c: *ui.Context, a: *App, k: theme.Colors) void {
    const w: f32 = if (a.narrow) narrow_width else width;
    const s = ui.div(c).column().w(w).hFull().bg(k.sidebar).px(10).gap(2);
    defer s.end();
    {
        const top = ui.div(c).row().wFull().h(kit.header_h).itemsCenter().px(2);
        defer top.end();
        ui.key(c, "fold");
        const b = ui.div(c).row().w(32).h(32).center().rounded(6).hover(k.hover).control();
        defer b.end();
        if (b.clicked()) a.narrow = !a.narrow;
        kit.glyph(c, .sidebar, 16, k.secondary);
    }
    const sy = a.sampler.system;
    var b: [32]u8 = undefined;
    item(c, a, k, .overview, "Overview", "");
    item(c, a, k, .processes, "Processes", c.print("{s}", .{model.count(&b, a.sampler.procs.items.len)}));
    section(c, a, k, "Hardware");
    item(c, a, k, .cpu, "CPU", c.print("{d:.0}%", .{sy.cpuBusy()}));
    item(c, a, k, .memory, "Memory", c.print("{d:.0}%", .{memPercent(sy)}));
    item(c, a, k, .gpu, "GPU", c.print("{d:.1}%", .{sy.gpu}));
    item(c, a, k, .disk, "Disk", kit.rate(c, a, sy.read_sec + sy.written_sec));
    item(c, a, k, .network, "Network", kit.rate(c, a, sy.net_in_sec + sy.net_out_sec));
    const bat = a.sampler.battery;
    item(c, a, k, .energy, "Energy", if (bat.present) c.print("{d:.0}%", .{bat.percent}) else "");
    section(c, a, k, "System");
    item(c, a, k, .apps, "Apps", "");
    item(c, a, k, .cleanup, "Cleanup", cleanable(c, a));
    item(c, a, k, .about, @import("view_about.zig").title, "");
    ui.spacer(c);
    foot(c, a, k);
}

/// What Cleanup found can go, once it has looked.
fn cleanable(c: *ui.Context, a: *App) []const u8 {
    if (comptime @import("builtin").os.tag != .windows) return "";
    if (!a.cleanup.done()) return "";
    var all: u64 = 0;
    for (@import("cleanup_win.zig").kinds) |kind| all += a.cleanup.found(kind).bytes;
    return kit.bytes(c, all);
}

fn section(c: *ui.Context, a: *App, k: theme.Colors, name: []const u8) void {
    const d = ui.div(c).row().wFull().px(8).pt(16).pb(5);
    defer d.end();
    if (a.narrow) {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
        return;
    }
    ui.text(c, name, .{ .size = 11.5, .color = k.tertiary });
}

fn item(c: *ui.Context, a: *App, k: theme.Colors, page: app_mod.Page, name: []const u8, figure: []const u8) void {
    ui.key(c, name);
    const on = a.page == page;
    var d = ui.div(c).row().wFull().h(30).itemsCenter().gap(10).px(8).rounded(6).control();
    d = if (on) d.bg(k.picked) else d.hover(k.hover);
    defer d.end();
    if (d.clicked()) {
        a.page = page;
        a.menu = false;
    }
    const g, const color = look(k, page);
    kit.chip(c, g, if (on) color.mix(.white, 0.12) else color, 20, true);
    if (a.narrow) return;
    ui.text(c, name, .{ .size = 13, .weight = if (on) .semibold else .regular, .color = if (on) k.on_picked else k.text });
    ui.spacer(c);
    if (figure.len > 0) ui.text(c, figure, .{ .size = 11, .color = if (on) k.on_picked.alpha(0.85) else k.secondary });
}

/// The machine's name and chip, and the Settings button.
fn foot(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = ui.div(c).row().wFull().gap(6).itemsCenter().px(8).pb(14).pt(8);
    defer d.end();
    if (!a.narrow) {
        const t = ui.div(c).column().grow().w(0).gap(2).clip();
        defer t.end();
        const info = a.sampler.info;
        ui.text(c, if (info.model.len > 0) info.model else info.host, .{ .size = 12, .weight = .medium, .color = k.text });
        ui.text(c, info.chip, .{ .size = 11, .color = k.secondary });
    }
    ui.key(c, "settings");
    const b = ui.div(c).row().w(30).h(30).center().rounded(6).hover(k.hover).control();
    defer b.end();
    if (b.clicked()) a.settings = true;
    kit.glyph(c, .gear, 16, k.secondary);
}
