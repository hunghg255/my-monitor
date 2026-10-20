//! The Disk and Network pages. Disk: bytes a second across the range,
//! read and written stacked, with the totals since startup; each volume's
//! free space; and the apps reading and writing the most. Network: bytes
//! a second down and up across the range, with the totals and the peak;
//! each connected interface with its rates and addresses; and the rest.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const sample = @import("sample.zig");
const App = @import("app.zig").App;

pub fn disk(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    {
        const h = kit.header(c, k, "Disk", c.print("{d} volume{s}", .{ s.n_volumes, if (s.n_volumes == 1) "" else "s" }));
        defer h.end();
        kit.ranges(c, a, k);
    }
    const body = kit.body(c);
    defer body.end();
    diskLoad(c, a, k, 150);
    var i: usize = 0;
    while (i < s.n_volumes) : (i += 2) {
        const r = kit.cards(c);
        defer r.end();
        volume(c, a, k, s.volumes[i], i);
        if (i + 1 < s.n_volumes) volume(c, a, k, s.volumes[i + 1], i + 1) else {
            const pad = ui.div(c).row().grow().w(0);
            pad.end();
        }
    }
    kit.most(c, a, k, "Reading and Writing the Most", .disk, k.orange, .disk);
}

/// The Disk Activity card, its graph `h` high.
pub fn diskLoad(c: *ui.Context, a: *App, k: theme.Colors, h: f32) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = kit.card(c, k);
    defer d.end();
    {
        const t = kit.title(c, .disk, "Disk Activity", k.orange);
        defer t.end();
        kit.legend(c, k, &.{ .{ "Write", k.orange }, .{ "Read", k.sky } });
    }
    {
        const r = ui.div(c).row().wFull().gap(28).itemsEnd();
        defer r.end();
        kit.bigRate(c, k, a, "Reading and writing", sy.read_sec + sy.written_sec);
        const st = ui.div(c).row().w(660).gap(16).pb(2);
        defer st.end();
        kit.stat(c, k, "Reading", kit.rate(c, a, sy.read_sec), " ");
        kit.stat(c, k, "Writing", kit.rate(c, a, sy.written_sec), " ");
        kit.stat(c, k, "Read", kit.bytes(c, sy.read_bytes), "since startup");
        kit.stat(c, k, "Written", kit.bytes(c, sy.written_bytes), "since startup");
    }
    kit.dots(c, k, a, &.{ .{ .values = s.read_history.slice(), .color = k.sky, .name = "Read", .unit = .rate }, .{ .values = s.write_history.slice(), .color = k.orange, .name = "Write", .unit = .rate } }, null, h, true, .disk, k.orange);
}

/// A volume: its free space, how full it is, its file system. A click
/// opens it in File Explorer.
fn volume(c: *ui.Context, a: *App, k: theme.Colors, v: sample.storage.Volume, i: usize) void {
    _ = a;
    ui.key(c, c.print("vol-{c}", .{v.letter}));
    const color = if (i == 0) k.orange else k.sky;
    const d = kit.cell(c, k).gap(10).hover(k.card.mix(k.text, 0.03)).control();
    defer d.end();
    if (d.clicked()) _ = myzig.shell.openPath(c.print("{c}:\\", .{v.letter}));
    var nb: [96]u8 = undefined;
    {
        const t = kit.title(c, .disk, c.print("{s}", .{v.name(&nb)}), color);
        defer t.end();
        kit.glyph(c, .chevron_right, 12, k.tertiary);
    }
    kit.bigBytes(c, k, c.print("Free of {s}", .{kit.bytes(c, v.total)}), v.free);
    const used: f32 = if (v.total > 0) @floatCast(@as(f64, @floatFromInt(v.used())) / @as(f64, @floatFromInt(v.total))) else 0;
    {
        const r = ui.div(c).row().wFull();
        defer r.end();
        kit.bar(c, used, if (used >= 0.9) k.red else if (used >= 0.75) k.orange else k.blue, 6);
    }
    const r = kit.stats(c);
    defer r.end();
    kit.stat(c, k, "Used", kit.bytes(c, v.used()), "");
    kit.stat(c, k, "Format", c.print("{s}", .{v.fsSlice()}), "");
    kit.stat(c, k, "Device", c.print("{c}:", .{v.letter}), "");
}

pub fn network(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    var active: usize = 0;
    for (s.ifaces[0..s.n_ifaces]) |f| {
        if (connected(f)) active += 1;
    }
    {
        const h = kit.header(c, k, "Network", c.print("{d} active interface{s}", .{ active, if (active == 1) "" else "s" }));
        defer h.end();
        kit.ranges(c, a, k);
    }
    const body = kit.body(c);
    defer body.end();
    netLoad(c, a, k, 150);
    var shown: [sample.max_ifaces]usize = undefined;
    var n: usize = 0;
    for (s.ifaces[0..s.n_ifaces], 0..) |f, i| if (connected(f)) {
        shown[n] = i;
        n += 1;
    };
    var i: usize = 0;
    while (i < n) : (i += 2) {
        const r = kit.cards(c);
        defer r.end();
        iface(c, a, k, shown[i]);
        if (i + 1 < n) iface(c, a, k, shown[i + 1]) else {
            const pad = ui.div(c).row().grow().w(0);
            pad.end();
        }
    }
    others(c, a, k);
}

/// Up, and not the loopback: an interface with traffic of its own.
fn connected(f: sample.net.Iface) bool {
    return f.up and f.kind != .loopback;
}

/// The Network card, its graph `h` high.
pub fn netLoad(c: *ui.Context, a: *App, k: theme.Colors, h: f32) void {
    const s = &a.sampler;
    const sy = s.system;
    const d = kit.card(c, k);
    defer d.end();
    {
        const t = kit.title(c, .network, "Network", k.teal);
        defer t.end();
        kit.legend(c, k, &.{ .{ "Download", k.teal }, .{ "Upload", k.blue } });
    }
    {
        const r = ui.div(c).row().wFull().gap(28).itemsEnd();
        defer r.end();
        kit.bigRate(c, k, a, "Downloading", sy.net_in_sec);
        const st = ui.div(c).row().w(820).gap(16).pb(2);
        defer st.end();
        const n = a.range.samples(a.interval);
        var top: f32 = 0;
        const ins = s.in_history.slice();
        const outs = s.out_history.slice();
        for (ins[ins.len -| n..], outs[outs.len -| n..]) |x, y| top = @max(top, x + y);
        kit.stat(c, k, "Uploading", kit.rate(c, a, sy.net_out_sec), " ");
        kit.stat(c, k, "Received", kit.bytes(c, sy.net_in), "since startup");
        kit.stat(c, k, "Sent", kit.bytes(c, sy.net_out), "since startup");
        kit.stat(c, k, "Peak", kit.rate(c, a, top), " ");
    }
    kit.dots(c, k, a, &.{ .{ .values = s.out_history.slice(), .color = k.blue, .name = "Upload", .unit = .rate }, .{ .values = s.in_history.slice(), .color = k.teal, .name = "Download", .unit = .rate } }, null, h, true, .network, k.teal);
}

/// An interface: its rates now, what went through it, its addresses.
fn iface(c: *ui.Context, a: *App, k: theme.Colors, i: usize) void {
    const f = &a.sampler.ifaces[i];
    const rates = a.sampler.iface_rates[i];
    ui.key(c, c.print("if-{d}", .{f.luid}));
    const wifi = f.kind == .wifi;
    const color = if (wifi) k.teal else k.sky;
    const d = kit.cell(c, k).gap(10);
    defer d.end();
    {
        const t = kit.title(c, if (wifi) .wifi else .ethernet, f.aliasSlice(), color);
        defer t.end();
        ui.text(c, f.descSlice(), .{ .size = 11, .color = k.tertiary });
    }
    {
        const col = ui.div(c).column().gap(4);
        defer col.end();
        ui.text(c, "Downloading", .{ .size = 12, .color = k.secondary });
        var b: [32]u8 = undefined;
        const t = kit.rateText(&b, a, rates[0]);
        const sp = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
        kit.figure(c, k, c.print("{s}", .{t[0..sp]}), c.print("{s}", .{t[sp + 1 ..]}), 24);
    }
    {
        const r = kit.stats(c);
        defer r.end();
        kit.stat(c, k, "Uploading", kit.rate(c, a, rates[1]), "");
        kit.stat(c, k, "Received", kit.bytes(c, f.in_bytes), "");
        kit.stat(c, k, "Sent", kit.bytes(c, f.out_bytes), "");
    }
    const gap = ui.div(c).row().h(2);
    gap.end();
    if (f.ipv4_len > 0) kit.line(c, k, "IPv4", f.ipv4Slice(), null);
    if (f.ipv6_len > 0) kit.line(c, k, "IPv6", f.ipv6Slice(), null);
    if (f.mac_len > 0) kit.line(c, k, "Hardware", f.macSlice(), null);
}

/// The interfaces not connected, and the loopback.
fn others(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.sampler;
    var any = false;
    for (s.ifaces[0..s.n_ifaces]) |f| {
        if (!connected(f)) any = true;
    }
    if (!any) return;
    const d = kit.card(c, k).gap(2);
    defer d.end();
    {
        const t = kit.title(c, .ethernet, "Other Interfaces", k.gray);
        defer t.end();
    }
    const gap = ui.div(c).row().h(6);
    gap.end();
    for (s.ifaces[0..s.n_ifaces]) |*f| if (!connected(f.*)) {
        ui.key(c, c.print("other-{d}", .{f.luid}));
        kit.line(c, k, f.aliasSlice(), if (f.kind == .loopback) "Within this computer" else "Not connected", null);
    };
}
