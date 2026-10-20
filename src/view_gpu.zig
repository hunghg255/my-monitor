//! The GPU page: its load now (its 3D and copy engines, the memory it
//! holds, the peak over the range) over a dot graph of the range; what it
//! is; each engine's load as a bar; and the apps using it the most.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const App = @import("app.zig").App;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const info = a.sampler.info;
    {
        const h = kit.header(c, k, "GPU", info.gpu);
        defer h.end();
        kit.ranges(c, a, k);
    }
    const body = kit.body(c);
    defer body.end();
    load(c, a, k, 150);
    {
        const r = kit.cards(c);
        defer r.end();
        about(c, a, k);
        engines(c, a, k);
    }
    kit.most(c, a, k, "Using the Most GPU", .gpu, k.red, .gpu);
}

/// The Graphics card, its graph `h` high.
pub fn load(c: *ui.Context, a: *App, k: theme.Colors, h: f32) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = kit.card(c, k);
    defer d.end();
    {
        const t = kit.title(c, .gpu, "Graphics", k.red);
        defer t.end();
    }
    {
        const r = ui.div(c).row().wFull().gap(28).itemsEnd();
        defer r.end();
        kit.big(c, k, s.info.gpu, c.print("{d:.1}", .{sy.gpu}), "%");
        const st = ui.div(c).row().w(660).gap(16).pb(8);
        defer st.end();
        const n = a.range.samples(a.interval);
        kit.stat(c, k, "3D", c.print("{d:.1}%", .{sy.gpu_3d}), "");
        kit.stat(c, k, "Copy", c.print("{d:.0}%", .{sy.gpu_copy}), "");
        kit.stat(c, k, "Memory", kit.bytes(c, sy.gpu_memory), "");
        kit.stat(c, k, "Peak", c.print("{d:.0}%", .{kit.peak(s.gpu_history.slice(), n)}), "");
    }
    kit.dots(c, k, a, &.{.{ .values = s.gpu_history.slice(), .color = k.red, .name = "GPU", .unit = .percent }}, 100, h, true, .gpu, k.red);
}

fn about(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    const d = kit.cell(c, k).gap(2);
    defer d.end();
    {
        const t = kit.title(c, .info, "About", k.red);
        defer t.end();
    }
    const gap = ui.div(c).row().h(6);
    gap.end();
    kit.line(c, k, "Model", a.sampler.info.gpu, null);
    kit.line(c, k, "Memory in use", kit.bytes(c, sy.gpu_memory), null);
}

fn engines(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    const d = kit.cell(c, k).gap(6);
    defer d.end();
    {
        const t = kit.title(c, .activity, "Engines", k.red);
        defer t.end();
    }
    const lines = [_]struct { []const u8, f32 }{
        .{ "Device", sy.gpu },
        .{ "3D", sy.gpu_3d },
        .{ "Copy", sy.gpu_copy },
        .{ "Video Decode", sy.gpu_decode },
        .{ "Video Processing", sy.gpu_processing },
    };
    for (lines) |l| {
        ui.key(c, l[0]);
        const r = ui.div(c).row().wFull().gap(14).itemsCenter().h(24);
        defer r.end();
        const name = ui.div(c).row().w(110);
        ui.text(c, l[0], .{ .size = 12, .color = k.secondary });
        name.end();
        kit.bar(c, l[1] / 100, k.red, 5);
        const v = ui.div(c).row().w(48).justifyEnd();
        ui.text(c, c.print("{d:.1}%", .{l[1]}), .{ .size = 12, .weight = .semibold, .color = k.text });
        v.end();
    }
}
