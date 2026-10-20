//! Marking processes and ending them together, through the Tester. No
//! signal is sent: the app's `send` records them.
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const ui = myzig.ui;
const app_mod = @import("app.zig");
const App = app_mod.App;
const view = @import("view.zig");
const theme = @import("theme.zig");
const side = @import("view_side.zig");
const t_mod = @import("tests.zig");

var sent: [16][2]c_int = undefined;
var sent_len: usize = 0;

/// The user's processes quit; root's refuse, as kill(2) would.
fn record(pid: c_int, sig: c_int) callconv(.c) c_int {
    sent[sent_len] = .{ pid, sig };
    sent_len += 1;
    return if (pid == 990001 or pid == 990004) -1 else 0;
}

fn at(t: *ui.Tester, name: []const u8) [2]f32 {
    const r = t.findText(name).?;
    return .{ r.x + 4, r.y + r.h / 2 };
}

test "processes are marked by Ctrl-click and Shift-click, and quit together" {
    const gpa = std.testing.allocator;
    var a: App = .init(gpa, std.testing.io);
    defer a.deinit();
    try t_mod.fake(&a);
    a.page = .processes;
    a.send = record;
    sent_len = 0;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, view.view), .{ .width = 1280, .height = 820, .theme = theme.ui(false) });
    defer t.deinit();
    t.settle(2);
    // Ctrl-click (⌘ on macOS) marks one, then another.
    t.ctx.input.cmd = true;
    t.ctx.input.ctrl = true;
    for ([_][]const u8{ "Safari", "Mail" }) |name| {
        const p = at(&t, name);
        t.click(p[0], p[1]);
        t.settle(1);
    }
    t.ctx.input.cmd = false;
    t.ctx.input.ctrl = false;
    try std.testing.expect(a.marked.contains(990002) and a.marked.contains(990003) and a.selected == null);
    try std.testing.expect(t.hasText("2 marked"));
    // Shift-click marks the run from the selected row.
    const web = at(&t, "Safari Web Content");
    t.click(web[0], web[1]);
    t.settle(1);
    const kern = at(&t, "kernel_task");
    t.ctx.input.shift = true;
    t.click(kern[0], kern[1]);
    t.ctx.input.shift = false;
    t.settle(1);
    try std.testing.expect(a.marked.contains(990005) and a.marked.contains(990001));
    try std.testing.expect(t.hasText("4 marked") and t.hasText("· 1 not yours"));
    try t.screenshot("/tmp/mymonitor-marked.png");
    // Quitting asks first, naming them.
    try t_mod.open(&t, "Quit 4…");
    try std.testing.expect(t.hasText("Quit 4 processes?"));
    try t.screenshot("/tmp/mymonitor-quit-marked.png");
    try t_mod.open(&t, "Quit 4");
    try std.testing.expectEqual(@as(usize, 4), sent_len);
    for (sent[0..sent_len]) |s| try std.testing.expectEqual(@as(c_int, 15), s[1]);
    // The one not ours stays marked; the notice says so.
    try std.testing.expectEqual(@as(usize, 1), a.marked.count());
    try std.testing.expect(t.containsText("not yours to quit"));
    try t_mod.open(&t, "Clear");
    try std.testing.expectEqual(@as(usize, 0), a.marked.count());
}

test "mymonitor itself, launchd and the kernel are never signaled" {
    try std.testing.expect(App.untouchable(0) and App.untouchable(1));
    if (builtin.os.tag != .windows) try std.testing.expect(App.untouchable(std.c.getpid()));
}
