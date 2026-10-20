//! The tray's panel, over the taskbar's corner: a tab for each part the
//! user chose in Settings (CPU and GPU, memory, disk, network), each with
//! its figure now, a small graph of the last minute, its figures and the
//! apps using it most; at the bottom, a button to open mymonitor and one
//! for Settings.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const overview = @import("view_overview.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Glyph = @import("glyphs.zig").Glyph;

pub const width = 340;
pub const height = 640;

/// The tab the last frame drew: a new one draws once more, as its graph
/// sizes itself from the last layout.
var tab_drawn: ?app_mod.TrayPart = null;

const graph_h = 48;

pub fn view(a: *App, c: *ui.Context) void {
    const dark = a.dark orelse myzig.isDark();
    c.theme = theme.ui(dark);
    const k = theme.colors(dark);
    c.frameIn(a.tick(ui.clock.now()));
    a.icons.frame();
    if (tab_drawn != a.tray_tab) c.animationFrame();
    tab_drawn = a.tray_tab;
    const root = ui.div(c).column().sizeFull().bg(k.page).border(k.separator);
    defer root.end();
    {
        const body = ui.div(c).column().wFull().grow().scrollY().p(14).gap(12);
        defer body.end();
        tabs(c, a, k);
        switch (a.tray_tab) {
            .cpu => cpu(c, a, k),
            .memory => memory(c, a, k),
            .disk => disk(c, a, k),
            .network => network(c, a, k),
        }
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    const foot = ui.div(c).row().wFull().itemsCenter().px(14).py(10);
    defer foot.end();
    if (ui.button(c, "Open mymonitor", .{ .size = 13 }).clicked) open(a);
    ui.spacer(c);
    ui.key(c, "settings");
    const g = ui.div(c).row().w(30).h(30).center().rounded(6).hover(k.hover).control();
    defer g.end();
    if (g.clicked()) {
        a.settings = true;
        open(a);
    }
    kit.glyph(c, .gear, 16, k.secondary);
    if (a.icons.pending) c.frameIn(1.0 / 60.0);
}

/// What the tray's icon says under the pointer: the parts chosen in
/// Settings, "CPU 18% · Memory 16.6 GB / 31.7 GB".
pub fn tooltip(a: *App, buf: []u8) []const u8 {
    const sy = a.sampler.system;
    var w: std.Io.Writer = .fixed(buf);
    var b: [3][32]u8 = undefined;
    var first = true;
    for (std.enums.values(app_mod.TrayPart)) |part| {
        if (!a.tray_parts.get(part)) continue;
        if (!first) w.writeAll(" · ") catch break;
        first = false;
        const said = switch (part) {
            .cpu => w.print("CPU {d:.0}%", .{sy.cpuBusy()}),
            .memory => w.print("Memory {s} / {s}", .{ model.bytes(&b[0], sy.memUsed()), model.bytes(&b[1], sy.mem_total) }),
            .disk => w.print("Disk {s}", .{kit.rateText(&b[0], a, sy.read_sec + sy.written_sec)}),
            .network => w.print("Network ↓ {s} ↑ {s}", .{ kit.rateText(&b[0], a, sy.net_in_sec), kit.rateText(&b[2], a, sy.net_out_sec) }),
        };
        said catch break;
    }
    return if (first) "mymonitor" else w.buffered();
}

fn open(a: *App) void {
    if (a.on_open) |n| n.func(n.ctx);
}

const names = std.EnumArray(app_mod.TrayPart, []const u8).init(.{ .cpu = "CPU & GPU", .memory = "Memory", .disk = "Disk", .network = "Network" });

fn tabs(c: *ui.Context, a: *App, k: theme.Colors) void {
    var shown: [4]app_mod.TrayPart = undefined;
    var labels: [4][]const u8 = undefined;
    var n: usize = 0;
    var at: usize = 0;
    for (std.enums.values(app_mod.TrayPart)) |p| if (a.tray_parts.get(p)) {
        if (p == a.tray_tab) at = n;
        shown[n] = p;
        labels[n] = names.get(p);
        n += 1;
    };
    if (n == 0) return;
    if (!a.tray_parts.get(a.tray_tab)) a.tray_tab = shown[0];
    if (n == 1) return;
    const r = ui.div(c).row().wFull().center();
    defer r.end();
    if (kit.segmented(c, k, labels[0..n], at)) |i| a.tray_tab = shown[i];
}

/// A part's chip, name and figure now.
fn top(c: *ui.Context, k: theme.Colors, g: Glyph, name: []const u8, color: ui.Color, number: []const u8, unit: []const u8) void {
    const r = ui.div(c).row().wFull().gap(10).itemsCenter();
    defer r.end();
    kit.chip(c, g, color, 30, false);
    ui.text(c, name, .{ .size = 15, .weight = .semibold, .color = color });
    ui.spacer(c);
    kit.figure(c, k, number, unit, 26);
}

fn label(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    ui.text(c, text, .{ .size = 11.5, .color = k.secondary });
}

/// The apps highest by `by`, five of them.
fn apps(c: *ui.Context, a: *App, k: theme.Colors, by: kit.By) void {
    label(c, k, "Processes");
    var best: [5]app_mod.AppRow = undefined;
    const n = kit.topApps(a, &best, switch (by) {
        .cpu => .cpu,
        .memory => .memory,
        .gpu => .gpu,
        .disk => .disk,
    });
    const col = ui.div(c).column().wFull().gap(0);
    defer col.end();
    for (best[0..n]) |r| {
        ui.key(c, r.bundle);
        const l = ui.div(c).row().wFull().h(26).gap(8).itemsCenter();
        defer l.end();
        kit.appName(c, a, k, r.bundle, r.name, 0);
        const v: []const u8 = switch (by) {
            .cpu => c.print("{d:.1}%", .{r.cpu}),
            .memory => kit.bytes(c, r.memory),
            .gpu => c.print("{d:.1}%", .{r.gpu}),
            .disk => kit.rate(c, a, r.disk_rate),
        };
        ui.text(c, v, .{ .size = 12, .weight = .semibold, .color = k.secondary });
    }
}

fn cpu(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    top(c, k, .cpu, "CPU", k.blue, c.print("{d:.0}", .{sy.cpuBusy()}), "%");
    kit.dots(c, k, a, &.{ .{ .values = s.system_history.slice(), .color = k.system, .name = "System", .unit = .percent }, .{ .values = s.user_history.slice(), .color = k.user, .name = "User", .unit = .percent } }, 100, graph_h, false, null, k.blue);
    {
        const r = kit.stats(c);
        defer r.end();
        kit.stat(c, k, "User", c.print("{d:.0}%", .{sy.cpu_user}), "");
        kit.stat(c, k, "System", c.print("{d:.1}%", .{sy.cpu_system}), "");
        kit.stat(c, k, "Idle", c.print("{d:.0}%", .{@max(0, 100 - sy.cpuBusy())}), "");
    }
    label(c, k, "Cores");
    {
        const r = ui.div(c).row().wFull().gap(6).justifyBetween();
        defer r.end();
        for (s.core_load[0..@min(s.cores, 12)], 0..) |v, i| {
            ui.key(c, c.print("core-{d}", .{i}));
            const g = kit.ring(c, 24, 3.5, &.{.{ v / 100, k.blue }}, k.blue.alpha(0.18));
            g.end();
        }
    }
    apps(c, a, k, .cpu);
    {
        const r = ui.div(c).row().wFull();
        defer r.end();
        label(c, k, "GPU");
        ui.spacer(c);
        ui.text(c, s.info.gpu, .{ .size = 11, .color = k.tertiary });
    }
    {
        const r = ui.div(c).row().wFull().center();
        defer r.end();
        const g = kit.ring(c, 76, 7, &.{.{ sy.gpu / 100, k.red }}, k.red.alpha(0.16));
        defer g.end();
        kit.figure(c, k, c.print("{d:.1}", .{sy.gpu}), "%", 16);
        ui.text(c, "GPU", .{ .size = 10, .color = k.secondary });
    }
    var b: [32]u8 = undefined;
    kit.line(c, k, "Uptime", c.print("{s}", .{model.uptime(&b, sy.uptime_s)}), null);
}

fn memory(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    var b: [32]u8 = undefined;
    const t = model.bytes(&b, sy.memUsed());
    const sp = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
    top(c, k, .memory, "Memory", k.green, c.print("{s}", .{t[0..sp]}), c.print("{s}", .{t[sp + 1 ..]}));
    {
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        ui.text(c, c.print("In use of {s}", .{kit.bytes(c, sy.mem_total)}), .{ .size = 12, .color = k.secondary });
        ui.spacer(c);
        const word, const color = kit.pressure(k, sy.pressure);
        kit.badge(c, word, color, true);
    }
    const parts = kit.memoryParts(k, sy);
    const all: f32 = @floatFromInt(@max(1, sy.mem_total));
    var bars: [4]kit.Part = undefined;
    for (parts[0..4], 0..) |p, i| bars[i] = .{ @as(f32, @floatFromInt(p[1])) / all, p[2] };
    kit.stacked(c, &bars, parts[4][2], 6);
    {
        const col = ui.div(c).column().wFull();
        defer col.end();
        for (parts) |p| {
            ui.key(c, p[0]);
            const l = ui.div(c).row().wFull().h(23).gap(8).itemsCenter();
            defer l.end();
            _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = p[2] }, .none, null);
            ui.text(c, p[0], .{ .size = 12.5, .color = k.text });
            ui.spacer(c);
            ui.text(c, kit.bytes(c, p[1]), .{ .size = 12, .color = k.secondary });
        }
    }
    kit.dots(c, k, a, &.{ .{ .values = s.wired_history.slice(), .color = k.orange, .name = "Wired", .unit = .memory }, .{ .values = s.app_history.slice(), .color = k.green, .name = "App", .unit = .memory }, .{ .values = s.compressed_history.slice(), .color = k.sky, .name = "Compressed", .unit = .memory } }, 100, graph_h, false, null, k.green);
    {
        const r = kit.stats(c);
        defer r.end();
        kit.stat(c, k, "Pressure", c.print("{d:.0}%", .{sy.pressure}), "");
        kit.stat(c, k, "Swap", kit.bytes(c, sy.swap_used), "");
        kit.stat(c, k, "Committed", kit.bytes(c, sy.commit), "");
    }
    apps(c, a, k, .memory);
}

fn disk(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    var b: [32]u8 = undefined;
    const t = kit.rateText(&b, a, sy.read_sec + sy.written_sec);
    const sp = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
    top(c, k, .disk, "Disk", k.orange, c.print("{s}", .{t[0..sp]}), c.print("{s}", .{t[sp + 1 ..]}));
    if (overview.systemVolume(a)) |v| {
        ui.text(c, c.print("{s} free of {s} on {c}:", .{ kit.bytes(c, v.free), kit.bytes(c, v.total), v.letter }), .{ .size = 12, .color = k.secondary });
        const r = ui.div(c).row().wFull();
        defer r.end();
        const used: f32 = if (v.total > 0) @floatCast(@as(f64, @floatFromInt(v.used())) / @as(f64, @floatFromInt(v.total))) else 0;
        kit.bar(c, used, if (used >= 0.9) k.red else k.orange, 6);
    }
    kit.dots(c, k, a, &.{ .{ .values = s.read_history.slice(), .color = k.sky, .name = "Read", .unit = .rate }, .{ .values = s.write_history.slice(), .color = k.orange, .name = "Write", .unit = .rate } }, null, graph_h, false, null, k.orange);
    {
        const r = kit.stats(c);
        defer r.end();
        kit.stat(c, k, "Reading", kit.rate(c, a, sy.read_sec), "");
        kit.stat(c, k, "Writing", kit.rate(c, a, sy.written_sec), "");
        kit.stat(c, k, "Written", kit.bytes(c, sy.written_bytes), "");
    }
    apps(c, a, k, .disk);
}

fn network(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const sy = s.system;
    var b: [32]u8 = undefined;
    const t = kit.rateText(&b, a, sy.net_in_sec);
    const sp = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
    top(c, k, .network, "Network", k.teal, c.print("{s}", .{t[0..sp]}), c.print("{s}", .{t[sp + 1 ..]}));
    kit.dots(c, k, a, &.{ .{ .values = s.out_history.slice(), .color = k.blue, .name = "Upload", .unit = .rate }, .{ .values = s.in_history.slice(), .color = k.teal, .name = "Download", .unit = .rate } }, null, graph_h, false, null, k.teal);
    {
        const r = kit.stats(c);
        defer r.end();
        kit.stat(c, k, "Uploading", kit.rate(c, a, sy.net_out_sec), "");
        kit.stat(c, k, "Received", kit.bytes(c, sy.net_in), "");
        kit.stat(c, k, "Sent", kit.bytes(c, sy.net_out), "");
    }
    label(c, k, "Interfaces");
    for (s.ifaces[0..s.n_ifaces], 0..) |*f, i| if (f.up and f.kind != .loopback) {
        ui.key(c, c.print("if-{d}", .{f.luid}));
        const l = ui.div(c).row().wFull().h(26).gap(8).itemsCenter();
        defer l.end();
        kit.glyph(c, if (f.kind == .wifi) .wifi else .ethernet, 15, k.teal);
        ui.text(c, f.aliasSlice(), .{ .size = 12.5, .color = k.text });
        ui.spacer(c);
        ui.text(c, c.print("↓ {s}  ↑ {s}", .{ kit.rate(c, a, s.iface_rates[i][0]), kit.rate(c, a, s.iface_rates[i][1]) }), .{ .size = 11.5, .color = k.secondary });
    };
}
