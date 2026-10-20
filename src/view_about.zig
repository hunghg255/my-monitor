//! About This PC: the machine (its maker and model, chip and memory, the
//! system and how long it has been up) beside a laptop showing the logo;
//! then its hardware, its software, its displays and its storage.
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const ui = myzig.ui;
const model = @import("model.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const App = @import("app.zig").App;

/// The page's name, as the system calls its own.
pub const title = "About " ++ machine;
/// The machine, in the overview: "This Mac", "This PC".
pub const machine = if (builtin.os.tag == .windows) "This PC" else "This Mac";

pub const logo = @embedFile("logo.svg");

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const m = &s.machine;
    const name = if (s.info.model.len > 0) s.info.model else s.info.host;
    {
        const h = kit.header(c, k, title, name);
        defer h.end();
        kit.pause(c, a, k);
    }
    const body = kit.body(c);
    defer body.end();
    hero(c, a, k, name);
    {
        const r = kit.cards(c);
        defer r.end();
        hardware(c, a, k);
        software(c, a, k);
    }
    const r = kit.cards(c);
    defer r.end();
    {
        const d = kit.cell(c, k).gap(2);
        defer d.end();
        {
            const t = kit.title(c, .monitor, "Displays", k.teal);
            defer t.end();
        }
        gap(c);
        for (m.displays[0..m.n_displays], 0..) |dp, i| {
            ui.key(c, c.print("display-{d}", .{i}));
            kit.line(c, k, if (dp.primary) "Main display" else c.print("Display {d}", .{i + 1}), c.print("{d} × {d} @ {d} Hz · {d}%", .{ dp.width, dp.height, dp.hz, dp.scale }), null);
        }
    }
    const d = kit.cell(c, k).gap(2);
    defer d.end();
    {
        const t = kit.title(c, .disk, "Storage", k.orange);
        defer t.end();
    }
    gap(c);
    var nb: [96]u8 = undefined;
    for (s.volumes[0..s.n_volumes]) |v| {
        ui.key(c, c.print("vol-{c}", .{v.letter}));
        kit.line(c, k, c.print("{s}", .{v.name(&nb)}), c.print("{s} free of {s}", .{ kit.bytes(c, v.free), kit.bytes(c, v.total) }), null);
    }
}

fn gap(c: *ui.Context) void {
    const g = ui.div(c).row().h(6);
    g.end();
}

/// A laptop with the logo on its screen, and what the machine is.
fn hero(c: *ui.Context, a: *App, k: theme.Colors, name: []const u8) void {
    const s = &a.sampler;
    const d = kit.card(c, k).row().itemsCenter().gap(28).px(28).py(22);
    defer d.end();
    {
        const pc = ui.div(c).column().itemsCenter().gap(0);
        defer pc.end();
        const screen = ui.div(c).row().w(124).h(80).center().rounded(8).bg(.hex(0x17191d)).border(.hex(0x3a3d44)).clip();
        {
            defer screen.end();
            _ = ui.svg(c, logo, .{ .width = 104, .height = 104 });
        }
        _ = c.leaf(.{ .width = .{ .px = 150 }, .height = .{ .px = 7 }, .radius = 3.5, .background = k.gray.alpha(0.55) }, .none, null);
    }
    const col = ui.div(c).column().gap(6);
    defer col.end();
    ui.text(c, name, .{ .size = 24, .weight = .bold, .color = k.text });
    ui.text(c, c.print("{s} · {s}", .{ s.info.chip, kit.bytes(c, s.machine.memory) }), .{ .size = 13, .color = k.secondary });
    const r = ui.div(c).row().gap(8).pt(4);
    defer r.end();
    pill(c, s.info.os, k.blue);
    var b: [32]u8 = undefined;
    pill(c, c.print("Up {s}", .{model.uptime(&b, s.system.uptime_s)}), k.green);
}

fn pill(c: *ui.Context, text: []const u8, color: ui.Color) void {
    const d = ui.div(c).row().gap(6).itemsCenter().px(10).py(4).rounded(14).bg(color.alpha(0.14));
    defer d.end();
    _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = color }, .none, null);
    ui.text(c, text, .{ .size = 12, .weight = .semibold, .color = color });
}

fn hardware(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const m = &s.machine;
    const d = kit.cell(c, k).gap(2);
    defer d.end();
    {
        const t = kit.title(c, .cpu, "Hardware", k.blue);
        defer t.end();
    }
    gap(c);
    kit.line(c, k, "Model", if (s.info.model.len > 0) s.info.model else "–", null);
    kit.line(c, k, "Chip", s.info.chip, null);
    kit.line(c, k, "CPU cores", c.print("{d}", .{s.system.cores}), null);
    kit.line(c, k, "Memory", kit.bytes(c, if (m.memory > 0) m.memory else s.system.mem_total), null);
    kit.line(c, k, "Graphics", s.info.gpu, null);
    kit.line(c, k, "Architecture", m.archSlice(), null);
}

fn software(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    const m = &s.machine;
    const d = kit.cell(c, k).gap(2);
    defer d.end();
    {
        const t = kit.title(c, .laptop, "Software", k.gray);
        defer t.end();
    }
    gap(c);
    var b: [32]u8 = undefined;
    kit.line(c, k, "System", m.productSlice(), null);
    if (m.display_version_len > 0) kit.line(c, k, "Version", m.displayVersionSlice(), null);
    kit.line(c, k, "Build", c.print("{d}.{d}", .{ m.build, m.ubr }), null);
    kit.line(c, k, "Kernel", c.print("NT {d}.{d}.{d}", .{ m.major, m.minor, m.build }), null);
    kit.line(c, k, "Computer name", m.hostSlice(), null);
    kit.line(c, k, "User", m.userSlice(), null);
    if (m.boot_unix > 0 and builtin.os.tag == .windows) {
        const t = @import("win_machine.zig").local(m.boot_unix);
        kit.line(c, k, "Started", c.print("{s}, {s} {d}, {d}, {d:0>2}:{d:0>2}", .{ days[t.weekday % 7], months[(t.month -| 1) % 12], t.day, t.year, t.hour, t.minute }), null);
    }
    kit.line(c, k, "Uptime", c.print("{s}", .{model.uptime(&b, s.system.uptime_s)}), null);
    kit.line(c, k, "Processes", c.print("{s}", .{model.count(&b, s.procs.items.len)}), null);
    kit.line(c, k, "Built with", c.print("Zig {s} · myzig {s}", .{ builtin.zig_version_string, myzig.version }), null);
}
