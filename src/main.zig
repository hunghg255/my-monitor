//! mymonitor: a small activity monitor on myzig, laid out as Windows 11's
//! own apps are: the machine's parts on pages, the processes with their
//! CPU, GPU and memory, sampled every second while the window shows; and
//! an icon in the taskbar's corner whose panel shows them at a glance, and
//! whose tooltip says them in a line. Closing the window leaves the icon;
//! its menu quits.
const std = @import("std");
const myzig = @import("myzig");
const App = @import("app.zig").App;
const view = @import("view.zig");
const tray_view = @import("view_tray.zig");
const settings = @import("settings.zig");
const theme = @import("theme.zig");

/// The window, the tray's icon and its panel, and what they do.
const Host = struct {
    a: *App,
    app: *myzig.App,
    window: *myzig.Window = undefined,
    panel: ?*myzig.Window = null,
    tray: ?*myzig.Tray = null,

    fn open(h: *Host) void {
        if (h.panel) |p| p.hide();
        h.window.show();
        h.window.focus();
    }

    fn opened(ctx: *anyopaque) void {
        open(@ptrCast(@alignCast(ctx)));
    }

    fn clicked(h: *Host, _: *myzig.Tray) void {
        const p = h.panel orelse return h.open();
        if (p.isVisible()) p.hide() else p.show();
    }

    /// With the icon in the tray, closing the window hides it.
    fn mayClose(h: *Host, win: *myzig.Window) bool {
        if (h.tray == null) return true;
        win.hide();
        return false;
    }

    fn showWindow(h: *Host, _: *myzig.menu.Item) void {
        h.open();
    }

    fn showSettings(h: *Host, _: *myzig.menu.Item) void {
        h.a.settings = true;
        h.open();
    }

    /// The tray menu's Quit: a tray icon's menu runs only items' clicks,
    /// not their roles, so this one quits by itself.
    fn quit(h: *Host, _: *myzig.menu.Item) void {
        h.app.quit();
    }

    /// Every interval: samples while nothing shows (the views sample
    /// while they do), and tells the tray's icon what it says under the
    /// pointer.
    fn beat(ctx: ?*anyopaque) callconv(.c) void {
        const h: *Host = @ptrCast(@alignCast(ctx.?));
        const shown = h.window.isVisible() or (if (h.panel) |p| p.isVisible() else false);
        if (!shown) _ = h.a.tick(myzig.ui.clock.now());
        if (h.tray) |t| {
            var buf: [128]u8 = undefined;
            t.setTooltip(tray_view.tooltip(h.a, &buf));
        }
        myzig.App.after(@intFromFloat(h.a.interval * 1000), h, beat);
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try myzig.App.create(init, .{ .name = "mymonitor" });
    defer app.destroy();
    var a: App = .init(init.gpa, init.io);
    defer a.deinit();
    settings.load(&a);
    defer settings.save(&a);
    a.host = app;
    var host: Host = .{ .a = &a, .app = app };
    a.on_open = .{ .ctx = &host, .func = Host.opened };
    const dark = myzig.isDark();
    host.window = try app.newWindow(.{
        .title = "mymonitor",
        .width = 1280,
        .height = 820,
        .min_width = 760,
        .min_height = 480,
        // The pages' headers are the title bar, as Windows 11's apps have.
        .title_bar = .hidden,
        // Opened at login, it waits in the tray.
        .visible = !myzig.system.wasOpenedAtLogin(app),
        .theme = theme.ui(dark),
        .on_close_request = .of(&host, Host.mayClose),
        .content = .{ .view = .init(&a, view.view) },
    });
    a.listen(host.window);
    if (app.newTray(.{
        .id = "mymonitor",
        .icon = @import("view_settings.zig").tray_png,
        .tooltip = "mymonitor",
        .on_click = .of(&host, Host.clicked),
        .menu = &.{
            .{ .label = "Open mymonitor", .click = .of(&host, Host.showWindow) },
            .{ .label = "Settings…", .click = .of(&host, Host.showSettings) },
            .separator,
            .{ .label = "Quit mymonitor", .click = .of(&host, Host.quit) },
        },
    })) |tray| {
        host.tray = tray;
        host.panel = app.newFlyout(.{
            .tray = tray,
            .width = tray_view.width,
            .height = tray_view.height,
            .dismiss = .hide,
            .hidden = true,
            .theme = theme.ui(dark),
            .content = .{ .view = .init(&a, tray_view.view) },
        }) catch null;
        Host.beat(&host);
    } else |err| std.log.warn("tray: {t}", .{err});
    try app.run();
}
