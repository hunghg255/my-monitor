//! The Processes page: the search, which processes show (all, the user's
//! apps, the user's, the system's), grouping by program, Quit, the details
//! and pause; under them the table (view_table.zig) beside the selected
//! process's details (view_detail.zig); when processes are marked, a bar
//! to quit them together; and at the bottom how many show, whose owners
//! Windows would not say (and running as Administrator to know them), and
//! the CPU and memory in use.
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

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    var b: [2][32]u8 = undefined;
    const sy = a.sampler.system;
    {
        const n = a.sampler.procs.items.len;
        const sub = if (sy.threads > 0)
            c.print("{s} processes · {s} threads", .{ model.count(&b[0], n), model.count(&b[1], sy.threads) })
        else
            c.print("{s} processes", .{model.count(&b[0], n)});
        const h = kit.header(c, k, "Processes", sub);
        defer h.end();
        search(c, a, k, 220);
        const filters = [_]app_mod.Filter{ .all, .apps, .mine, .system };
        if (kit.segmented(c, k, &.{ "All", "Apps", "My Processes", "System" }, std.mem.indexOfScalar(app_mod.Filter, &filters, a.filter).?)) |i| a.setFilter(filters[i]);
        if (kit.roundButton(c, k, "tree", .layers, if (a.tree) k.accent else k.secondary, true)) {
            a.tree = !a.tree;
            a.dirty = true;
        }
        const chosen = if (a.selected) |pid| a.find(pid) != null else false;
        if (kit.roundButton(c, k, "quit", .stop, k.secondary, chosen)) a.confirm = a.selected;
        if (kit.roundButton(c, k, "panel", .sidebar, if (a.panel) k.accent else k.secondary, true)) a.panel = !a.panel;
        kit.pause(c, a, k);
    }
    {
        const r = ui.div(c).row().wFull().grow().h(0);
        defer r.end();
        {
            const col = ui.div(c).column().grow().w(0).hFull();
            defer col.end();
            filtered(c, a, k);
            table.table(c, a, k);
            actions(c, a, k);
        }
        @import("view_detail.zig").process(c, a, k);
    }
    status(c, a, k);
}

/// "Showing only Code" or "3 hidden", and a way back to every process.
fn filtered(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.only == null and a.hidden.count() == 0) return;
    const bar = ui.div(c).row().wFull().h(34).itemsCenter().gap(10).px(24).bg(k.accent.alpha(0.08));
    defer bar.end();
    kit.glyph(c, .search, 12, k.accent);
    if (a.only) |key| {
        var name: []const u8 = "one program";
        for (a.sampler.procs.items) |p| if (app_mod.App.groupKey(p) == key) {
            name = p.name;
            break;
        };
        ui.text(c, c.print("Showing only {s}", .{name}), .{ .size = 12, .color = k.text });
    } else ui.text(c, c.print("{d} program{s} hidden", .{ a.hidden.count(), if (a.hidden.count() == 1) "" else "s" }), .{ .size = 12, .color = k.text });
    ui.spacer(c);
    ui.key(c, "show-all");
    const l = ui.div(c).row().control();
    defer l.end();
    if (l.clicked()) {
        a.only = null;
        a.hidden.clearRetainingCapacity();
        a.dirty = true;
    }
    ui.text(c, "Show All", .{ .size = 12, .weight = .medium, .color = k.accent });
}

/// How many show, whose owners are unknown, and the machine's load.
fn status(c: *ui.Context, a: *App, k: theme.Colors) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    const bar = ui.div(c).row().wFull().h(30).itemsCenter().gap(18).px(24);
    defer bar.end();
    var b: [2][32]u8 = undefined;
    const n = a.sampler.procs.items.len;
    ui.text(c, c.print("{s} of {s} processes", .{ model.count(&b[0], a.rows.items.len), model.count(&b[1], n) }), .{ .size = 11.5, .color = k.secondary });
    if (comptime builtin.os.tag == .windows) {
        var unknown: usize = 0;
        for (a.sampler.procs.items) |p| {
            if (p.uid == sample.os.unknown_uid) unknown += 1;
        }
        if (unknown > 0) ui.text(c, c.print("Users unknown for {d} processes", .{unknown}), .{ .size = 11.5, .color = k.tertiary });
        if (!sample.os.elevated()) {
            ui.key(c, "admin");
            const l = ui.div(c).row().control();
            defer l.end();
            if (l.clicked() and sample.os.relaunchElevated()) if (a.host) |h| h.quit();
            ui.text(c, "Run as Administrator", .{ .size = 11.5, .weight = .medium, .color = k.accent });
        }
    }
    ui.spacer(c);
    const sy = a.sampler.system;
    figure(c, k, k.blue, "CPU", c.print("{d:.0}%", .{sy.cpuBusy()}));
    figure(c, k, k.green, "Memory", kit.bytes(c, sy.memUsed()));
}

fn figure(c: *ui.Context, k: theme.Colors, color: ui.Color, name: []const u8, value: []const u8) void {
    const d = ui.div(c).row().gap(5).itemsCenter();
    defer d.end();
    _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = color }, .none, null);
    ui.text(c, name, .{ .size = 11.5, .color = k.secondary });
    ui.text(c, value, .{ .size = 11.5, .weight = .semibold, .color = k.text });
}

/// What is marked, what it holds, and what to do with it; or what the
/// last quitting did.
fn actions(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sum = a.markedSummary();
    const notice = a.noticeText();
    if (sum.count == 0 and notice == null) return;
    if (notice != null) c.frameIn(@floatCast(@max(0.05, a.notice_until - a.now)));
    const bar = ui.div(c).row().wFull().h(48).itemsCenter().gap(10).px(24).bg(k.card);
    defer bar.end();
    if (sum.count == 0) {
        kit.glyph(c, .check, 13, k.green);
        ui.text(c, notice.?, .{ .size = 12, .color = k.text });
        return;
    }
    _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = k.accent }, .none, null);
    ui.text(c, c.print("{d} marked", .{sum.count}), .{ .size = 12.5, .weight = .semibold, .color = k.text });
    ui.text(c, c.print("{s} · {d:.1}% CPU", .{ kit.bytes(c, sum.memory), sum.cpu }), .{ .size = 12, .color = k.secondary });
    if (sum.system > 0) ui.text(c, c.print("· {d} not yours", .{sum.system}), .{ .size = 12, .color = k.red });
    ui.spacer(c);
    if (notice) |n| ui.text(c, n, .{ .size = 12, .color = k.secondary });
    if (ui.button(c, "Clear", .{ .variant = .ghost, .size = 12 }).clicked) a.marked.clearRetainingCapacity();
    if (ui.button(c, c.print("Quit {d}…", .{sum.count}), .{ .variant = .primary, .size = 12 }).clicked) a.confirm_marked = true;
}

pub fn search(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const f = ui.div(c).row().w(w).h(32).itemsCenter().gap(7).px(12).rounded(16).bg(k.control);
    defer f.end();
    kit.glyph(c, .search, 13, k.secondary);
    if (a.find_search) {
        a.find_search = false;
        c.focus = c.peekId(null);
    }
    const res = ui.textField(c, &a.query, .{ .placeholder = "Search", .width = .fill, .size = 12.5, .bare = true });
    if (res.changed) a.dirty = true;
}
