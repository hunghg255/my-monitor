//! The Memory page: memory in use now, by kind (app, wired, compressed,
//! cached) as figures and a bar, and across the range; memory by kind as a
//! donut; how hard memory is pressed, as a ring; the page file; memory by
//! app as tiles; and the apps using the most of it.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const overview = @import("view_overview.zig");
const App = @import("app.zig").App;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    {
        const h = kit.header(c, k, "Memory", c.print("{s} of memory", .{kit.bytes(c, sy.mem_total)}));
        defer h.end();
        kit.ranges(c, a, k);
    }
    const body = kit.body(c);
    defer body.end();
    usage(c, a, k, 150);
    {
        const r = kit.cards(c);
        defer r.end();
        overview.byType(c, a, k);
        pressure(c, a, k);
        swap(c, a, k);
    }
    {
        const r = kit.cards(c);
        defer r.end();
        overview.byApp(c, a, k);
    }
    kit.most(c, a, k, "Using the Most Memory", .memory, k.green, .memory);
}

/// The Memory card, its graph `h` high.
pub fn usage(c: *ui.Context, a: *App, k: theme.Colors, h: f32) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = kit.card(c, k);
    defer d.end();
    {
        const t = kit.title(c, .memory, "Memory", k.green);
        defer t.end();
        kit.legend(c, k, &.{ .{ "App", k.green }, .{ "Compressed", k.sky }, .{ "Wired", k.orange } });
        const gap = ui.div(c).row().w(10);
        gap.end();
        const word, const color = kit.pressure(k, sy.pressure);
        kit.badge(c, word, color, true);
    }
    {
        const r = ui.div(c).row().wFull().gap(28).itemsEnd();
        defer r.end();
        {
            const col = ui.div(c).column().gap(4);
            defer col.end();
            ui.text(c, c.print("In use of {s}", .{kit.bytes(c, sy.mem_total)}), .{ .size = 12, .color = k.secondary });
            var b: [32]u8 = undefined;
            const t = model.bytes(&b, sy.memUsed());
            const sp = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
            kit.figure(c, k, c.print("{s}", .{t[0..sp]}), c.print("{s}", .{t[sp + 1 ..]}), 34);
        }
        const st = ui.div(c).row().w(660).gap(16).pb(8);
        defer st.end();
        kit.stat(c, k, "App", kit.bytes(c, sy.mem_app), "");
        kit.stat(c, k, "Wired", kit.bytes(c, sy.mem_wired), "");
        kit.stat(c, k, "Compressed", kit.bytes(c, sy.mem_compressed), "");
        kit.stat(c, k, "Cached", kit.bytes(c, sy.mem_cached), "");
    }
    const parts = kit.memoryParts(k, sy);
    const all: f32 = @floatFromInt(@max(1, sy.mem_total));
    var bars: [4]kit.Part = undefined;
    for (parts[0..4], 0..) |p, i| bars[i] = .{ @as(f32, @floatFromInt(p[1])) / all, p[2] };
    kit.stacked(c, &bars, parts[4][2], 6);
    const series = [_]kit.Series{
        .{ .values = s.wired_history.slice(), .color = k.orange, .name = "Wired", .unit = .memory },
        .{ .values = s.app_history.slice(), .color = k.green, .name = "App", .unit = .memory },
        .{ .values = s.compressed_history.slice(), .color = k.sky, .name = "Compressed", .unit = .memory },
    };
    kit.dots(c, k, a, &series, 100, h, true, .memory, k.green);
}

/// How hard memory is pressed, as a ring, and what commits it.
fn pressure(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    const p = sy.pressure;
    const word, const color = kit.pressure(k, p);
    const d = kit.cell(c, k);
    defer d.end();
    {
        const t = kit.title(c, .activity, "Pressure", k.green);
        defer t.end();
        kit.badge(c, word, color, true);
    }
    {
        const r = ui.div(c).row().wFull().center().py(4);
        defer r.end();
        const g = kit.ring(c, 110, 10, &.{.{ p / 100, color }}, color.alpha(0.16));
        defer g.end();
        ui.text(c, c.print("{d:.0}%", .{p}), .{ .size = 20, .weight = .bold, .color = k.text });
        ui.text(c, "pressure", .{ .size = 10.5, .color = k.secondary });
    }
    kit.line(c, k, "Committed", kit.bytes(c, sy.commit), null);
    kit.line(c, k, "Commit limit", kit.bytes(c, sy.commit_limit), null);
}

/// The page file: what it holds, against its size.
fn swap(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    const d = kit.cell(c, k);
    defer d.end();
    {
        const t = kit.title(c, .disk, "Swap", k.blue);
        defer t.end();
    }
    kit.bigBytes(c, k, "Written to disk", sy.swap_used);
    {
        const r = ui.div(c).row().wFull();
        defer r.end();
        const f: f32 = if (sy.swap_total > 0) @floatCast(@as(f64, @floatFromInt(sy.swap_used)) / @as(f64, @floatFromInt(sy.swap_total))) else 0;
        kit.bar(c, f, k.sky, 6);
    }
    kit.line(c, k, "Swap size", kit.bytes(c, sy.swap_total), null);
    kit.line(c, k, "Compressed", kit.bytes(c, sy.mem_compressed), null);
}
