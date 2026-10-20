//! The Overview page: a card for each part of the machine (CPU, memory,
//! GPU, disk, network, battery), its figure now beside three more over a
//! small graph of the range, each opening its page; then memory by kind
//! as a donut, memory by app as tiles, and CPU by app as bars.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const side = @import("view_side.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Glyph = @import("glyphs.zig").Glyph;

const mini_h = 56;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    {
        const h = kit.header(c, k, "Overview", s.info.host);
        defer h.end();
        kit.ranges(c, a, k);
    }
    const body = kit.body(c);
    defer body.end();
    {
        const r = kit.cards(c);
        defer r.end();
        cpu(c, a, k);
        memory(c, a, k);
        gpu(c, a, k);
    }
    {
        const r = kit.cards(c);
        defer r.end();
        disk(c, a, k);
        network(c, a, k);
        battery(c, a, k);
    }
    const r = kit.cards(c);
    defer r.end();
    byType(c, a, k);
    byApp(c, a, k);
    cpuByApp(c, a, k);
}

/// Opens a tile for `to`: its chip, name and a chevron; then what it is
/// about. The caller adds its figures and graph, then ends it.
fn tile(c: *ui.Context, a: *App, k: theme.Colors, to: app_mod.Page, name: []const u8, about: []const u8) ui.Div {
    ui.key(c, name);
    const d = kit.cell(c, k).gap(10).hover(k.card.mix(k.text, 0.03)).control();
    if (d.clicked()) a.page = to;
    const g, const color = side.look(k, to);
    {
        const t = kit.title(c, g, name, color);
        defer t.end();
        kit.glyph(c, .chevron_right, 12, k.tertiary);
    }
    ui.text(c, about, .{ .size = 12, .color = k.secondary });
    return d;
}

fn cpu(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = tile(c, a, k, .cpu, "CPU", "Now");
    defer d.end();
    kit.figure(c, k, c.print("{d:.0}", .{sy.cpuBusy()}), "%", 34);
    {
        const r = kit.stats(c);
        defer r.end();
        const n = a.range.samples(a.interval);
        kit.stat(c, k, "User", c.print("{d:.0}%", .{sy.cpu_user}), "");
        kit.stat(c, k, "System", c.print("{d:.0}%", .{sy.cpu_system}), "");
        kit.stat(c, k, "Average", c.print("{d:.0}%", .{kit.mean(s.user_history.slice(), n) + kit.mean(s.system_history.slice(), n)}), "");
    }
    kit.dots(c, k, a, &.{ .{ .values = s.system_history.slice(), .color = k.system, .name = "System", .unit = .percent }, .{ .values = s.user_history.slice(), .color = k.user, .name = "User", .unit = .percent } }, 100, mini_h, false, null, k.blue);
}

fn memory(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = tile(c, a, k, .memory, "Memory", c.print("In use of {s}", .{kit.bytes(c, sy.mem_total)}));
    defer d.end();
    {
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        kit.bigBytes(c, k, "", sy.memUsed());
        ui.spacer(c);
        const word, const color = kit.pressure(k, sy.pressure);
        kit.badge(c, word, color, true);
    }
    {
        const r = kit.stats(c);
        defer r.end();
        kit.stat(c, k, "App", kit.bytes(c, sy.mem_app), "");
        kit.stat(c, k, "Wired", kit.bytes(c, sy.mem_wired), "");
        kit.stat(c, k, "Compressed", kit.bytes(c, sy.mem_compressed), "");
    }
    kit.dots(c, k, a, &.{ .{ .values = s.wired_history.slice(), .color = k.orange, .name = "Wired", .unit = .memory }, .{ .values = s.app_history.slice(), .color = k.green, .name = "App", .unit = .memory }, .{ .values = s.compressed_history.slice(), .color = k.sky, .name = "Compressed", .unit = .memory } }, 100, mini_h, false, null, k.green);
}

fn gpu(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = tile(c, a, k, .gpu, "GPU", if (s.info.gpu.len > 0) s.info.gpu else "Graphics");
    defer d.end();
    kit.figure(c, k, c.print("{d:.1}", .{sy.gpu}), "%", 34);
    {
        const r = kit.stats(c);
        defer r.end();
        const n = a.range.samples(a.interval);
        kit.stat(c, k, "Memory", kit.bytes(c, sy.gpu_memory), "");
        kit.stat(c, k, "Average", c.print("{d:.1}%", .{kit.mean(s.gpu_history.slice(), n)}), "");
        kit.stat(c, k, "Peak", c.print("{d:.0}%", .{kit.peak(s.gpu_history.slice(), n)}), "");
    }
    kit.dots(c, k, a, &.{.{ .values = s.gpu_history.slice(), .color = k.red, .name = "GPU", .unit = .percent }}, 100, mini_h, false, null, k.red);
}

/// The system drive: the first fixed volume (C:).
pub fn systemVolume(a: *App) ?@import("win_storage.zig").Volume {
    const s = &a.sampler;
    for (s.volumes[0..s.n_volumes]) |v| if (v.letter == 'C') return v;
    return if (s.n_volumes > 0) s.volumes[0] else null;
}

fn disk(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    const v = systemVolume(a);
    const d = tile(c, a, k, .disk, "Disk", if (v) |x| c.print("Free of {s}", .{kit.bytes(c, x.total)}) else "Now");
    defer d.end();
    if (v) |x| kit.bigBytes(c, k, "", x.free) else kit.bigRate(c, k, a, "", sy.read_sec + sy.written_sec);
    {
        const r = kit.stats(c);
        defer r.end();
        kit.stat(c, k, "Reading", kit.rate(c, a, sy.read_sec), "");
        kit.stat(c, k, "Writing", kit.rate(c, a, sy.written_sec), "");
        kit.stat(c, k, "Written", kit.bytes(c, sy.written_bytes), "");
    }
    kit.dots(c, k, a, &.{ .{ .values = s.read_history.slice(), .color = k.sky, .name = "Read", .unit = .rate }, .{ .values = s.write_history.slice(), .color = k.orange, .name = "Write", .unit = .rate } }, null, mini_h, false, null, k.orange);
}

fn network(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = tile(c, a, k, .network, "Network", "Downloading");
    defer d.end();
    kit.bigRate(c, k, a, "", sy.net_in_sec);
    {
        const r = kit.stats(c);
        defer r.end();
        kit.stat(c, k, "Uploading", kit.rate(c, a, sy.net_out_sec), "");
        kit.stat(c, k, "Received", kit.bytes(c, sy.net_in), "");
        kit.stat(c, k, "Sent", kit.bytes(c, sy.net_out), "");
    }
    kit.dots(c, k, a, &.{ .{ .values = s.out_history.slice(), .color = k.blue, .name = "Upload", .unit = .rate }, .{ .values = s.in_history.slice(), .color = k.teal, .name = "Download", .unit = .rate } }, null, mini_h, false, null, k.teal);
}

/// The battery's state in a word: "Charging", "Charged", "On battery".
pub fn batteryState(b: @import("win_power.zig").Battery) []const u8 {
    if (!b.present) return "No battery";
    if (b.charging) return "Charging";
    if (b.on_ac) return if (b.percent >= 99) "Charged" else "Not charging";
    return "On battery";
}

/// How long it lasts, or that it runs from the wall.
pub fn remaining(c: *ui.Context, b: @import("win_power.zig").Battery) []const u8 {
    if (b.on_ac) return "On power";
    if (b.seconds_left) |s| return kit.hoursMinutes(c, s);
    return "Working it out";
}

/// Watts drawn or charged, from the battery's rate ("–" when idle).
pub fn watts(c: *ui.Context, mw: i32) []const u8 {
    if (mw == 0) return "–";
    const w = @as(f32, @floatFromInt(@abs(mw))) / 1000;
    return if (w >= 10) c.print("{d:.0} W", .{w}) else c.print("{d:.1} W", .{w});
}

fn battery(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const b = s.battery;
    const d = tile(c, a, k, .energy, "Battery", batteryState(b));
    defer d.end();
    if (b.present) kit.figure(c, k, c.print("{d:.0}", .{b.percent}), "%", 34) else kit.figure(c, k, "AC", "power", 34);
    {
        const r = kit.stats(c);
        defer r.end();
        kit.stat(c, k, "Remaining", remaining(c, b), "");
        kit.stat(c, k, "Power Draw", watts(c, b.rate_mw), "");
        kit.stat(c, k, "Health", if (b.design_mwh > 0) c.print("{d:.0}%", .{b.health()}) else "–", "");
    }
    kit.dots(c, k, a, &.{.{ .values = s.battery_history.slice(), .color = k.green, .name = "Charge", .unit = .percent }}, 100, mini_h, false, null, k.green);
}

/// Memory by kind: a donut of all of it, and each kind's size.
pub fn byType(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sy = a.sampler.system;
    const d = kit.cell(c, k);
    defer d.end();
    {
        const t = kit.title(c, .memory, "Memory by Type", k.green);
        defer t.end();
    }
    const r = ui.div(c).row().wFull().gap(18).itemsCenter().pt(6);
    defer r.end();
    const parts = kit.memoryParts(k, sy);
    const all: f32 = @floatFromInt(@max(1, sy.mem_total));
    var arcs: [4]kit.Part = undefined;
    for (parts[0..4], 0..) |p, i| arcs[i] = .{ @as(f32, @floatFromInt(p[1])) / all, p[2] };
    {
        const g = kit.ring(c, 104, 12, &arcs, parts[4][2]);
        defer g.end();
        ui.text(c, c.print("{d:.0}%", .{side.memPercent(sy)}), .{ .size = 20, .weight = .bold, .color = k.text });
        ui.text(c, "in use", .{ .size = 10.5, .color = k.secondary });
    }
    const list = ui.div(c).column().grow().w(0).gap(0);
    defer list.end();
    for (parts) |p| {
        ui.key(c, p[0]);
        const l = ui.div(c).row().wFull().h(25).gap(8).itemsCenter();
        defer l.end();
        _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = p[2] }, .none, null);
        ui.text(c, p[0], .{ .size = 12.5, .color = k.text });
        ui.spacer(c);
        ui.text(c, kit.bytes(c, p[1]), .{ .size = 12, .color = k.secondary });
    }
}

/// The apps holding the most memory, as tiles.
pub fn byApp(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = kit.cell(c, k);
    defer d.end();
    var best: [8]app_mod.AppRow = undefined;
    const n = kit.topApps(a, &best, .memory);
    var tiles: [8]kit.Tile = undefined;
    var sum: u64 = 0;
    for (best[0..n], 0..) |r, i| {
        tiles[i] = .{ .name = r.name, .bundle = r.bundle, .value = r.memory };
        sum += r.memory;
    }
    {
        const t = kit.title(c, .apps, "Memory by App", k.green);
        defer t.end();
        ui.text(c, c.print("{s} in all", .{kit.bytes(c, sum)}), .{ .size = 11.5, .color = k.secondary });
    }
    kit.treemap(c, a, k, tiles[0..n], 158);
}

/// The apps busiest now, with their CPU as bars.
fn cpuByApp(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = kit.cell(c, k).gap(8);
    defer d.end();
    {
        const t = kit.title(c, .cpu, "CPU by App", k.blue);
        defer t.end();
        ui.text(c, c.print("{d:.0}% in all", .{a.sampler.system.cpuBusy()}), .{ .size = 11.5, .color = k.secondary });
    }
    var best: [5]app_mod.AppRow = undefined;
    const n = kit.topApps(a, &best, .cpu);
    var most: f32 = 100;
    for (best[0..n]) |r| most = @max(most, r.cpu);
    for (best[0..n]) |r| {
        ui.key(c, r.bundle);
        const col = ui.div(c).column().wFull().gap(4);
        defer col.end();
        {
            const l = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer l.end();
            kit.appName(c, a, k, r.bundle, r.name, 0);
            ui.text(c, c.print("{d:.1}%", .{r.cpu}), .{ .size = 12, .color = k.secondary });
        }
        const b = ui.div(c).row().wFull().pl(27);
        defer b.end();
        kit.bar(c, r.cpu / most, k.blue, 4);
    }
}
