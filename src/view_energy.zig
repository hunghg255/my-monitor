//! The Energy page: the battery (how full, as a ring; how long it lasts,
//! what flows in or out, its health against its design, its cycles and
//! capacity, the adapter) and its level across the range; the apps that
//! weigh most on it (their CPU and GPU, as Windows measures no app's
//! watts); and where the power comes from.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const overview = @import("view_overview.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    {
        const h = kit.header(c, k, "Energy", "Battery and power");
        defer h.end();
        kit.ranges(c, a, k);
    }
    const body = kit.body(c);
    defer body.end();
    battery(c, a, k);
    level(c, a, k);
    const r = kit.cards(c);
    defer r.end();
    impact(c, a, k);
    source(c, a, k);
}

fn battery(c: *ui.Context, a: *App, k: theme.Colors) void {
    const b = a.sampler.battery;
    const d = kit.card(c, k);
    defer d.end();
    const health = b.health();
    {
        const t = kit.title(c, .battery, "Battery", k.green);
        defer t.end();
        if (b.present) {
            if (health > 0 and health < 60) kit.badge(c, "Service Recommended", k.orange, false) else kit.badge(c, "Normal", k.green, true);
        }
    }
    const r = ui.div(c).row().wFull().gap(36).itemsCenter();
    defer r.end();
    {
        const g = kit.ring(c, 132, 12, &.{.{ if (b.present) b.percent / 100 else 1, k.green }}, k.green.alpha(0.16));
        defer g.end();
        kit.figure(c, k, if (b.present) c.print("{d:.0}", .{b.percent}) else "AC", if (b.present) "%" else "", 26);
        ui.text(c, overview.batteryState(b), .{ .size = 11, .color = k.secondary });
    }
    const grid = ui.div(c).column().grow().w(0).gap(18);
    defer grid.end();
    var nb: [2][32]u8 = undefined;
    {
        const row = kit.stats(c);
        defer row.end();
        kit.stat(c, k, "Remaining", overview.remaining(c, b), "");
        kit.stat(c, k, "Battery Flow", flow(c, b), "");
        kit.stat(c, k, "Health", if (b.design_mwh > 0) c.print("{d:.0}%", .{health}) else "–", "of design capacity");
    }
    const row = kit.stats(c);
    defer row.end();
    kit.stat(c, k, "Cycles", if (b.cycles > 0) c.print("{d}", .{b.cycles}) else "Not reported", "");
    kit.stat(c, k, "Capacity", if (b.full_mwh > 0) c.print("{s} mWh", .{model.count(&nb[0], b.full_mwh)}) else "–", if (b.design_mwh > 0) c.print("design {s}", .{model.count(&nb[1], b.design_mwh)}) else "");
    kit.stat(c, k, "Adapter", if (b.on_ac) "Connected" else "Not connected", "");
}

/// What flows into or out of the battery.
fn flow(c: *ui.Context, b: @import("win_power.zig").Battery) []const u8 {
    if (b.rate_mw > 0) return c.print("Charging · {s}", .{overview.watts(c, b.rate_mw)});
    if (b.rate_mw < 0) return c.print("Discharging · {s}", .{overview.watts(c, b.rate_mw)});
    return "Idle";
}

fn level(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = kit.card(c, k);
    defer d.end();
    {
        const t = kit.title(c, .activity, "Battery Level", k.green);
        defer t.end();
    }
    kit.dots(c, k, a, &.{.{ .values = a.sampler.battery_history.slice(), .color = k.green, .name = "Charge", .unit = .percent }}, 100, 110, true, .battery, k.green);
}

/// The apps weighing most on the battery: their CPU and GPU together.
fn impact(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = kit.cell(c, k).gap(8);
    defer d.end();
    var best: [6]app_mod.AppRow = undefined;
    var n: usize = 0;
    for (a.apps.items) |r| {
        const v = r.cpu + r.gpu;
        if (v <= 0) continue;
        var at = n;
        while (at > 0 and best[at - 1].cpu + best[at - 1].gpu < v) : (at -= 1) {}
        if (at >= best.len) continue;
        var j = @min(n, best.len - 1);
        while (j > at) : (j -= 1) best[j] = best[j - 1];
        best[at] = r;
        n = @min(n + 1, best.len);
    }
    var all: f32 = 0;
    for (a.apps.items) |r| all += r.cpu + r.gpu;
    {
        const t = kit.title(c, .energy, "Energy Impact by App", k.yellow);
        defer t.end();
        ui.text(c, c.print("{d:.0} in all", .{all}), .{ .size = 11.5, .color = k.secondary });
    }
    var most: f32 = 1;
    for (best[0..n]) |r| most = @max(most, r.cpu + r.gpu);
    for (best[0..n]) |r| {
        ui.key(c, r.bundle);
        const col = ui.div(c).column().wFull().gap(4);
        defer col.end();
        {
            const l = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer l.end();
            kit.appName(c, a, k, r.bundle, r.name, r.processes);
            ui.text(c, c.print("{d:.1}", .{r.cpu + r.gpu}), .{ .size = 12, .color = k.secondary });
        }
        const b = ui.div(c).row().wFull().pl(27);
        defer b.end();
        kit.bar(c, (r.cpu + r.gpu) / most, k.yellow, 4);
    }
    ui.text(c, "CPU and GPU kept busy; Windows measures no app's watts.", .{ .size = 11, .color = k.tertiary });
}

fn source(c: *ui.Context, a: *App, k: theme.Colors) void {
    const b = a.sampler.battery;
    const d = kit.cell(c, k).gap(2);
    defer d.end();
    {
        const t = kit.title(c, .plug, "Power Source", k.yellow);
        defer t.end();
    }
    const gap = ui.div(c).row().h(6);
    gap.end();
    kit.line(c, k, "Drawing from", if (b.on_ac or !b.present) "Power Adapter" else "Battery", null);
    if (b.present) kit.line(c, k, "Battery", c.print("{d:.0}% · {s}", .{ b.percent, overview.batteryState(b) }), null);
    var pb: [64]u8 = undefined;
    const plan = @import("win_power.zig").planName(&pb);
    if (plan.len > 0) kit.line(c, k, "Power plan", c.print("{s}", .{plan}), null);
    if (b.voltage_mv > 0) kit.line(c, k, "Voltage", c.print("{d:.2} V", .{@as(f32, @floatFromInt(b.voltage_mv)) / 1000}), null);
    kit.line(c, k, "Whole computer", if (b.rate_mw < 0) overview.watts(c, b.rate_mw) else "On the adapter", null);
}
