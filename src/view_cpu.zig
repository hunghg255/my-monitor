//! The CPU page: the processor's load now (user, system, idle, the
//! average over the range) over a dot graph of the range, system red under
//! user blue; every core's load in two columns; the machine's activity
//! (processes, threads, uptime); and the apps using the most CPU.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const App = @import("app.zig").App;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const info = a.sampler.info;
    const sub = if (info.frugal > 0)
        c.print("{s} · {d} {s} + {d} {s} cores", .{ info.chip, info.fast, info.fast_name, info.frugal, info.frugal_name })
    else
        c.print("{s} · {d} cores", .{ info.chip, a.sampler.system.cores });
    {
        const h = kit.header(c, k, "CPU", sub);
        defer h.end();
        kit.ranges(c, a, k);
    }
    const b = kit.body(c);
    defer b.end();
    load(c, a, k, 170);
    {
        const r = kit.cards(c);
        defer r.end();
        cores(c, a, k);
        activity(c, a, k);
    }
    kit.most(c, a, k, "Using the Most CPU", .cpu, k.blue, .cpu);
}

/// The mean of the last `n` values.
pub fn mean(values: []const f32, n: usize) f32 {
    return kit.mean(values, n);
}

pub fn thermalName(t: u8) []const u8 {
    return switch (t) {
        0 => "Nominal",
        1 => "Fair",
        2 => "Serious",
        else => "Critical",
    };
}

/// The Processor Load card, its graph `h` high.
pub fn load(c: *ui.Context, a: *App, k: theme.Colors, h: f32) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = kit.card(c, k);
    defer d.end();
    const series = [_]kit.Series{ .{ .values = s.system_history.slice(), .color = k.system, .name = "System", .unit = .percent }, .{ .values = s.user_history.slice(), .color = k.user, .name = "User", .unit = .percent } };
    {
        const t = kit.title(c, .cpu, "Processor Load", k.blue);
        defer t.end();
        kit.legend(c, k, &.{ .{ "User", k.user }, .{ "System", k.system } });
    }
    {
        const r = ui.div(c).row().wFull().gap(28).itemsEnd();
        defer r.end();
        kit.big(c, k, "Now", c.print("{d:.1}", .{sy.cpuBusy()}), "%");
        const st = ui.div(c).row().w(660).gap(16).pb(8);
        defer st.end();
        const n = a.range.samples(a.interval);
        kit.stat(c, k, "User", c.print("{d:.1}%", .{sy.cpu_user}), "");
        kit.stat(c, k, "System", c.print("{d:.1}%", .{sy.cpu_system}), "");
        kit.stat(c, k, "Idle", c.print("{d:.0}%", .{@max(0, 100 - sy.cpuBusy())}), "");
        kit.stat(c, k, "Average", c.print("{d:.0}%", .{mean(s.user_history.slice(), n) + mean(s.system_history.slice(), n)}), "");
    }
    kit.dots(c, k, a, &series, 100, h, true, .cpu, k.blue);
}

/// Every core's load, two a line.
fn cores(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const info = s.info;
    const d = kit.cell(c, k).gap(8);
    defer d.end();
    {
        const t = kit.title(c, .cpu, "Cores", k.blue);
        defer t.end();
        ui.text(c, c.print("{d} logical processors", .{s.cores}), .{ .size = 11.5, .color = k.secondary });
    }
    const frugal = @min(info.frugal, s.cores);
    if (frugal > 0) {
        group(c, a, k, c.print("{s} Cores", .{info.fast_name}), frugal, s.cores, k.fast);
        group(c, a, k, c.print("{s} Cores", .{info.frugal_name}), 0, frugal, k.frugal);
    } else group(c, a, k, "All Cores", 0, s.cores, k.fast);
}

fn group(c: *ui.Context, a: *App, k: theme.Colors, name: []const u8, from: u32, to: u32, color: ui.Color) void {
    ui.text(c, name, .{ .size = 11.5, .color = k.secondary });
    var i = from;
    while (i < to) : (i += 2) {
        const r = ui.div(c).row().wFull().gap(24);
        defer r.end();
        core(c, a, k, i, color);
        if (i + 1 < to) core(c, a, k, i + 1, color) else {
            const pad = ui.div(c).row().grow().w(0);
            pad.end();
        }
    }
}

fn core(c: *ui.Context, a: *App, k: theme.Colors, i: u32, color: ui.Color) void {
    ui.key(c, c.print("core-{d}", .{i}));
    const r = ui.div(c).row().grow().w(0).gap(12).itemsCenter().h(24);
    defer r.end();
    const label = ui.div(c).row().w(54);
    ui.text(c, c.print("Core {d}", .{i + 1}), .{ .size = 12, .color = k.secondary });
    label.end();
    const v = a.sampler.core_load[i];
    kit.bar(c, v / 100, color, 5);
    const pct = ui.div(c).row().w(44).justifyEnd();
    ui.text(c, c.print("{d:.1}%", .{v}), .{ .size = 12, .weight = .semibold, .color = k.text });
    pct.end();
}

fn activity(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    const d = kit.cell(c, k).gap(2);
    defer d.end();
    {
        const t = kit.title(c, .activity, "Activity", k.gray);
        defer t.end();
    }
    const gap = ui.div(c).row().h(6);
    gap.end();
    var b: [32]u8 = undefined;
    kit.line(c, k, "Processes", c.print("{s}", .{model.count(&b, if (sy.tasks > 0) sy.tasks else a.sampler.procs.items.len)}), null);
    if (sy.threads > 0) kit.line(c, k, "Threads", c.print("{s}", .{model.count(&b, sy.threads)}), null);
    kit.line(c, k, "Uptime", c.print("{s}", .{model.uptime(&b, sy.uptime_s)}), null);
    if (sy.load[0] > 0) kit.line(c, k, "Load", c.print("{d:.2} · {d:.2} · {d:.2}", .{ sy.load[0], sy.load[1], sy.load[2] }), null);
}
