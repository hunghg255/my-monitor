//! mymonitor's window: a sidebar of pages, each with a figure beside its
//! name (view_side.zig), and the page: an overview, the processes, CPU,
//! memory, GPU, disk, network, energy, apps, cleanup, and this PC; over
//! them, the sheets (Settings, the inspector, quitting). Samples every
//! interval while it shows (unless paused); between samples it draws only
//! what moves.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const theme = @import("theme.zig");
const side = @import("view_side.zig");
const sheet = @import("view_sheet.zig");
const kit = @import("view_kit.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

const pages = struct {
    const overview = @import("view_overview.zig");
    const procs = @import("view_procs.zig");
    const cpu = @import("view_cpu.zig");
    const memory = @import("view_memory.zig");
    const gpu = @import("view_gpu.zig");
    const io = @import("view_io.zig");
    const energy = @import("view_energy.zig");
    const apps = @import("view_apps.zig");
    const cleanup = @import("view_cleanup.zig");
    const about = @import("view_about.zig");
};

pub fn view(a: *App, c: *ui.Context) void {
    const dark = a.dark orelse myzig.isDark();
    c.theme = theme.ui(dark);
    const k = theme.colors(dark);
    // The next sample, and only then, unless something animates. The
    // clock is the app's, not this window's: the tray's panel and its
    // timer sample by it too.
    c.frameIn(a.tick(ui.clock.now()));
    a.icons.frame();
    // The headers' empty space moves the window, as a title bar's does;
    // the caption buttons cover its right end.
    c.title_bar_height = kit.header_h;
    kit.caption = if (a.window) |w| @floatCast(w.titleBar().right) else 0;
    keys(c, a);
    const root = ui.div(c).row().sizeFull().bg(k.page);
    defer root.end();
    side.sidebar(c, a, k);
    {
        const main = ui.div(c).column().grow().w(0).hFull().clip();
        defer main.end();
        switch (a.page) {
            .overview => pages.overview.page(c, a, k),
            .processes => pages.procs.page(c, a, k),
            .cpu => pages.cpu.page(c, a, k),
            .memory => pages.memory.page(c, a, k),
            .gpu => pages.gpu.page(c, a, k),
            .disk => pages.io.disk(c, a, k),
            .network => pages.io.network(c, a, k),
            .energy => pages.energy.page(c, a, k),
            .apps => pages.apps.page(c, a, k),
            .cleanup => pages.cleanup.page(c, a, k),
            .about => pages.about.page(c, a, k),
        }
    }
    // Graphs and lists size themselves from the last frame's layout: a
    // page new to the window draws once more.
    if (a.drawn != a.page) c.animationFrame();
    a.drawn = a.page;
    // Inspecting shows a process's details beside the table.
    if (a.inspect) |pid| {
        a.selected = pid;
        a.panel = true;
        a.inspect = null;
    }
    sheet.menu(c, a, k);
    sheet.confirm(c, a, k);
    sheet.confirmMarked(c, a, k);
    pages.cleanup.confirm(c, a, k);
    pages.apps.confirm(c, a, k);
    @import("view_settings.zig").sheet(c, a, k);
    // Icons left for later frames, a few a frame.
    if (a.icons.pending) c.frameIn(1.0 / 60.0);
}

/// Ctrl+1–9 pick a page; ↑ and ↓ move the selection, Ctrl+I inspects it,
/// Ctrl+Alt+Q quits it, Ctrl+F finds, Ctrl+Shift+P pauses, Ctrl+, opens
/// Settings, Escape closes what is open.
fn keys(c: *ui.Context, a: *App) void {
    const S = ui.Shortcut;
    const all = std.enums.values(app_mod.Page);
    for (all[0..@min(all.len, 9)], 0..) |p, i| if (c.shortcut(.{ .key = @as(u21, '1') + @as(u21, @intCast(i)), .cmd = true })) {
        a.page = p;
    };
    if (c.shortcut(.{ .key = S.down })) {
        a.step(1);
        a.reveal = true;
    }
    if (c.shortcut(.{ .key = S.up })) {
        a.step(-1);
        a.reveal = true;
    }
    if (c.shortcut(.{ .key = 'i', .cmd = true })) a.inspect = a.selected;
    if (c.shortcut(.{ .key = 'q', .cmd = true, .alt = true })) a.confirm = a.selected;
    if (c.shortcut(.{ .key = 'f', .cmd = true })) {
        if (a.page != .apps) a.page = .processes;
        a.find_search = true;
    }
    if (c.shortcut(.{ .key = 'p', .cmd = true, .shift = true })) a.paused = !a.paused;
    if (c.shortcut(.{ .key = ',', .cmd = true })) a.settings = true;
    if (c.shortcut(.{ .key = S.escape })) {
        if (a.settings) a.settings = false else if (a.confirm_uninstall != null) a.confirm_uninstall = null else if (a.confirm_clean) a.confirm_clean = false else if (a.confirm_marked) a.confirm_marked = false else if (a.confirm != null) a.confirm = null else if (a.inspect != null) a.inspect = null else if (a.menu) a.menu = false else a.selected = null;
    }
}
