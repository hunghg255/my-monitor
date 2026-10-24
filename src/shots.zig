//! Pictures of every page, the Settings sheet and the tray's panel, with
//! this machine's live figures, drawn offscreen (no window shows):
//!
//!     zig build shots && zig-out/bin/mymonitor-shots <dir> [--dark]
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const view = @import("view.zig");
const tray_view = @import("view_tray.zig");
const theme = @import("theme.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const dir = if (args.len > 1) args[1] else ".";
    var dark = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dark")) dark = true;
    }
    var a: App = .init(gpa, init.io);
    defer a.deinit();
    a.dark = dark;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1600, .height = 1000, .scale = 1, .theme = theme.ui(dark) });
    defer t.deinit();
    // A minute of samples, as the window would have taken them.
    for (0..8) |_| {
        myzig.runFor(a.interval);
        t.advance(a.interval);
    }
    // A process selected, followed a few samples, for its details.
    a.page = .processes;
    t.settle(1);
    if (a.rows.items.len > 0) a.selected = a.sampler.procs.items[a.rows.items[0]].pid;
    for (0..4) |_| {
        myzig.runFor(a.interval);
        t.advance(a.interval);
    }
    var buf: [1024]u8 = undefined;
    for (std.enums.values(app_mod.Page)) |p| {
        a.page = p;
        t.settle(1);
        if (p == .apps) {
            a.installed.start();
            while (a.installed.running()) myzig.runFor(0.1);
            _ = a.installed.take();
            if (a.installed.items().len > 0) a.app_selected = std.hash.Wyhash.hash(0, a.installed.items()[0].name);
            t.settle(1);
        }
        if (p == .cpu) {
            // The pointer over the graph: the card reads out its column.
            const now = t.findText("Now").?;
            t.moveTo(now.x + 1240, now.y + 150);
            t.settle(1);
        }
        if (p == .cleanup and !a.cleanup.done()) {
            a.cleanup.start();
            while (a.cleanup.running()) myzig.runFor(0.2);
            // A few kinds open, and one ticked.
            for (a.cleanup.drives[0..a.cleanup.n_drives]) |drive| {
                for ([_]@import("cleanup_win.zig").Kind{ .package_caches, .installers, .agent_sessions }) |kind| a.clean_open[drive.volume.letter - 'A'][@backingInt(kind)] = true;
            }
            for (a.cleanup.ticks(.temporary)) |*on| on.* = true;
            t.settle(1);
        }
        // Icons come a few a frame.
        for (0..40) |_| t.frame();
        try t.screenshot(try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ dir, @tagName(p) }));
    }
    a.settings = true;
    t.settle(1);
    try t.screenshot(try std.fmt.bufPrint(&buf, "{s}/settings.png", .{dir}));
    a.settings_tab = .tray;
    t.settle(1);
    try t.screenshot(try std.fmt.bufPrint(&buf, "{s}/settings-tray.png", .{dir}));
    a.settings = false;
    var panel: ui.Tester = undefined;
    try panel.init(gpa, .init(&a, tray_view.view), .{ .width = tray_view.width, .height = tray_view.height, .scale = 1, .theme = theme.ui(dark) });
    defer panel.deinit();
    for (std.enums.values(app_mod.TrayPart)) |part| {
        a.tray_parts.set(part, true);
        a.tray_tab = part;
        panel.settle(1);
        try panel.screenshot(try std.fmt.bufPrint(&buf, "{s}/tray-{s}.png", .{ dir, @tagName(part) }));
    }
}
