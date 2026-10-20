//! The pieces mymonitor's pages are made of, as Windows 11's own apps draw
//! them: a page's header (clear of the window's caption buttons), soft
//! gray cards with a tinted chip and a colored title, large figures with
//! their unit small beside them, rows of labeled figures, thin bars, rings
//! and donuts, pills, badges, and the dot graph: a column of round dots
//! for each slice of the range in a well tinted with the part's color,
//! filled from the bottom by each series in turn, the rest left faint; over
//! the column under the pointer, a card reads out its values.
const std = @import("std");
const myzig = @import("myzig");
const ui = myzig.ui;
const theme = @import("theme.zig");
const model = @import("model.zig");
const glyphs = @import("glyphs.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Glyph = glyphs.Glyph;

pub const header_h = 52;

/// The width the window's caption buttons cover at the top right, set
/// each frame (0 where the system draws them elsewhere).
pub var caption: f32 = 0;

/// The page's title and what it is about; add controls, then `end`.
pub fn header(c: *ui.Context, k: theme.Colors, name: []const u8, subtitle: []const u8) ui.Div {
    const h = ui.div(c).row().wFull().h(header_h).itemsCenter().gap(8).pl(24).pr(12 + caption);
    {
        const t = ui.div(c).column().gap(1).clip();
        defer t.end();
        ui.text(c, name, .{ .size = 15, .weight = .bold, .color = k.text });
        if (subtitle.len > 0) ui.text(c, subtitle, .{ .size = 11, .color = k.secondary });
    }
    ui.spacer(c);
    return h;
}

/// The page under the header, scrolling: cards with room between.
pub fn body(c: *ui.Context) ui.Div {
    return ui.div(c).column().wFull().grow().scrollY().px(24).pb(24).gap(16);
}

/// A row of cards sharing the width.
pub fn cards(c: *ui.Context) ui.Div {
    return ui.div(c).row().wFull().gap(16).itemsStretch();
}

pub fn card(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().gap(12).p(18).rounded(14).bg(k.card);
}

/// A card that shares a row with others.
pub fn cell(c: *ui.Context, k: theme.Colors) ui.Div {
    return card(c, k).grow().w(0);
}

pub fn glyph(c: *ui.Context, g: Glyph, size: f32, color: ui.Color) void {
    glyphs.glyph(c, g, size, color);
}

/// A rounded square with a symbol in it: solid with a white symbol (the
/// sidebar's), or tinted with the symbol in its color (the cards').
pub fn chip(c: *ui.Context, g: Glyph, color: ui.Color, size: f32, solid: bool) void {
    const d = ui.div(c).row().w(size).h(size).center().rounded(size * 0.26).bg(if (solid) color else color.alpha(0.14));
    defer d.end();
    glyph(c, g, size * 0.62, if (solid) .white else color);
}

/// A card's title row: its chip and name in the part's color; add more,
/// then `end`.
pub fn title(c: *ui.Context, g: Glyph, name: []const u8, color: ui.Color) ui.Div {
    const r = ui.div(c).row().wFull().gap(10).itemsCenter();
    chip(c, g, color, 26, false);
    ui.text(c, name, .{ .size = 14.5, .weight = .semibold, .color = color });
    ui.spacer(c);
    return r;
}

/// A dot and a name for each series.
pub fn legend(c: *ui.Context, k: theme.Colors, items: []const struct { []const u8, ui.Color }) void {
    for (items) |it| {
        const d = ui.div(c).row().gap(5).itemsCenter().pl(12);
        defer d.end();
        _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = it[1] }, .none, null);
        ui.text(c, it[0], .{ .size = 11.5, .color = k.secondary });
    }
}

/// "✓ Normal": a state in a tinted pill.
pub fn badge(c: *ui.Context, text: []const u8, color: ui.Color, check: bool) void {
    const d = ui.div(c).row().gap(4).itemsCenter().px(9).py(3).rounded(20).bg(color.alpha(0.14));
    defer d.end();
    if (check) glyph(c, .check, 10, color);
    ui.text(c, text, .{ .size = 11.5, .weight = .semibold, .color = color });
}

/// A label over a large number with its unit small beside it: "28 %".
pub fn big(c: *ui.Context, k: theme.Colors, label: []const u8, number: []const u8, unit: []const u8) void {
    const col = ui.div(c).column().gap(4);
    defer col.end();
    if (label.len > 0) ui.text(c, label, .{ .size = 12, .color = k.secondary });
    figure(c, k, number, unit, 34);
}

/// A number `size` high with its unit small beside it.
pub fn figure(c: *ui.Context, k: theme.Colors, number: []const u8, unit: []const u8, size: f32) void {
    const r = ui.div(c).row().itemsEnd().gap(3);
    defer r.end();
    ui.text(c, number, .{ .size = size, .weight = .bold, .color = k.text });
    const u = ui.div(c).column().pb(size * 0.13);
    defer u.end();
    ui.text(c, unit, .{ .size = size * 0.44, .weight = .medium, .color = k.secondary });
}

/// A size as a large figure: "16.0" "GB".
pub fn bigBytes(c: *ui.Context, k: theme.Colors, label: []const u8, n: u64) void {
    var b: [32]u8 = undefined;
    const s = model.bytes(&b, n);
    const sp = std.mem.indexOfScalar(u8, s, ' ') orelse s.len;
    big(c, k, label, c.print("{s}", .{s[0..sp]}), c.print("{s}", .{std.mem.trim(u8, s[sp..], " ")}));
}

/// A rate as a large figure: "13.9" "KB/s".
pub fn bigRate(c: *ui.Context, k: theme.Colors, a: *const App, label: []const u8, per_s: f32) void {
    var b: [32]u8 = undefined;
    const s = rateText(&b, a, per_s);
    const sp = std.mem.indexOfScalar(u8, s, ' ') orelse s.len;
    big(c, k, label, c.print("{s}", .{s[0..sp]}), c.print("{s}", .{std.mem.trim(u8, s[sp..], " ")}));
}

/// A rate in the user's units: bytes or bits a second.
pub fn rateText(buf: []u8, a: *const App, per_s: f32) []const u8 {
    return model.rateIn(buf, per_s, a.bits);
}

pub fn rate(c: *ui.Context, a: *const App, per_s: f32) []const u8 {
    var b: [32]u8 = undefined;
    return c.print("{s}", .{rateText(&b, a, per_s)});
}

pub fn bytes(c: *ui.Context, n: u64) []const u8 {
    var b: [32]u8 = undefined;
    return c.print("{s}", .{model.bytes(&b, n)});
}

/// A figure: its label over its value, and a note under it; columns of
/// them share a row's width.
pub fn stat(c: *ui.Context, k: theme.Colors, label: []const u8, value: []const u8, note: []const u8) void {
    const col = ui.div(c).column().gap(3).grow().w(0).clip();
    defer col.end();
    ui.text(c, label, .{ .size = 11.5, .color = k.secondary });
    ui.text(c, value, .{ .size = 13, .weight = .semibold, .color = k.text });
    if (note.len > 0) ui.text(c, note, .{ .size = 10.5, .color = k.tertiary });
}

/// A row for stats.
pub fn stats(c: *ui.Context) ui.Div {
    return ui.div(c).row().wFull().gap(16).itemsStart();
}

/// A line of a list: the label on the left, the value on the right.
pub fn line(c: *ui.Context, k: theme.Colors, label: []const u8, value: []const u8, color: ?ui.Color) void {
    const r = ui.div(c).row().wFull().itemsCenter().h(25).gap(12);
    defer r.end();
    ui.text(c, label, .{ .size = 12.5, .color = k.secondary });
    ui.spacer(c);
    ui.text(c, value, .{ .size = 12.5, .weight = .semibold, .color = color orelse k.text });
}

/// A thin bar `fraction` full in `color` over a track tinted with it.
pub fn bar(c: *ui.Context, fraction: f32, color: ui.Color, h: f32) void {
    const f = std.math.clamp(fraction, 0, 1);
    const track = ui.div(c).row().grow().w(0).h(h).rounded(h / 2).bg(color.alpha(0.16)).clip();
    defer track.end();
    if (f > 0.004) _ = c.leaf(.{ .grow = f, .height = .{ .px = h }, .radius = h / 2, .background = color }, .none, null);
    if (f < 1) _ = c.leaf(.{ .grow = 1 - f }, .none, null);
}

pub const Part = struct { f32, ui.Color };

/// A bar of parts side by side (memory by kind), the rest `rest`.
pub fn stacked(c: *ui.Context, parts: []const Part, rest: ui.Color, h: f32) void {
    const track = ui.div(c).row().wFull().h(h).gap(2).rounded(h / 2).clip();
    defer track.end();
    var used: f32 = 0;
    for (parts) |p| if (p[0] > 0.002) {
        _ = c.leaf(.{ .grow = p[0], .height = .{ .px = h }, .radius = 1, .background = p[1] }, .none, null);
        used += p[0];
    };
    if (used < 1) _ = c.leaf(.{ .grow = 1 - used, .height = .{ .px = h }, .radius = 1, .background = rest }, .none, null);
}

/// A segmented control in a pill; the index clicked, if one was.
pub fn segmented(c: *ui.Context, k: theme.Colors, items: []const []const u8, on: usize) ?usize {
    const seg = ui.div(c).row().p(3).gap(2).rounded(20).bg(k.control);
    defer seg.end();
    var picked: ?usize = null;
    for (items, 0..) |name, i| {
        ui.key(c, name);
        var d = ui.div(c).row().px(12).py(4).rounded(16).control();
        d = if (i == on) d.bg(k.control_on).shadow(.{ .color = .{ .a = 0.16 }, .blur = 3, .y = 0.5 }) else d.hover(k.hover);
        defer d.end();
        if (d.clicked()) picked = i;
        ui.text(c, name, .{ .size = 12, .weight = if (i == on) .semibold else .regular, .color = if (i == on) k.text else k.secondary });
    }
    return picked;
}

/// A round button with a symbol; whether it was clicked.
pub fn roundButton(c: *ui.Context, k: theme.Colors, key: []const u8, g: Glyph, color: ui.Color, enabled: bool) bool {
    ui.key(c, key);
    var d = ui.div(c).row().w(32).h(32).center().rounded(16).bg(k.control).control();
    d = if (enabled) d.hover(k.hover) else d.opacity(0.4);
    defer d.end();
    const clicked = d.clicked() and enabled;
    glyph(c, g, 13, color);
    return clicked;
}

/// The graphs' range (1m, 5m, 15m, 1h), and pause.
pub fn ranges(c: *ui.Context, a: *App, k: theme.Colors) void {
    const all = [_]app_mod.Range{ .m1, .m5, .m15, .h1 };
    var names: [all.len][]const u8 = undefined;
    for (all, 0..) |r, i| names[i] = r.title();
    if (segmented(c, k, &names, @intFromEnum(a.range))) |i| a.range = all[i];
    pause(c, a, k);
}

pub fn pause(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (roundButton(c, k, "pause", if (a.paused) .play else .pause, if (a.paused) k.accent else k.secondary, true)) a.paused = !a.paused;
}

/// "Show All ›"; whether it was clicked.
pub fn link(c: *ui.Context, k: theme.Colors, text: []const u8) bool {
    ui.key(c, text);
    const d = ui.div(c).row().gap(3).itemsCenter().control();
    defer d.end();
    const it = d.interaction();
    ui.text(c, text, .{ .size = 12, .weight = .medium, .color = if (it.hovered) k.accent.mix(k.text, 0.25) else k.accent });
    glyph(c, .chevron_right, 10, k.accent);
    return it.clicked;
}

/// A program's icon `s` points square, or a faint stand-in.
pub fn icon(c: *ui.Context, a: *App, k: theme.Colors, bundle: []const u8, s: f32) void {
    const box = ui.div(c).row().w(s).h(s).center();
    defer box.end();
    if (a.icons.get(bundle)) |png| {
        _ = ui.image(c, .{ .key = bundle, .bytes = png, .max_width = s, .max_height = s, .radius = 0, .size = .{ .w = s, .h = s } });
        return;
    }
    const d = ui.div(c).row().w(s - 2).h(s - 2).center().rounded(3).bg(k.well);
    defer d.end();
    glyph(c, .cleanup, s * 0.6, k.tertiary);
}

/// A process's or app's icon, name and (when more than one) its count.
pub fn appName(c: *ui.Context, a: *App, k: theme.Colors, bundle: []const u8, text: []const u8, n: u32) void {
    const r = ui.div(c).row().grow().w(0).gap(9).itemsCenter().clip();
    defer r.end();
    icon(c, a, k, bundle, 18);
    ui.text(c, text, .{ .size = 12.5, .color = k.text });
    if (n > 1) ui.text(c, c.print("{d}", .{n}), .{ .size = 11, .color = k.tertiary });
}

/// What a series' values are: percents, bytes a second, a share of all
/// memory (read out as bytes), or bytes.
pub const Unit = enum { percent, rate, memory, bytes };

pub const Series = struct { values: []const f32, color: ui.Color, name: []const u8 = "", unit: Unit = .percent };

pub const Hover = app_mod.Hover;

/// The series stacked in columns of dots across `a.range`, scaled to
/// `scale` (null: to the busiest column), in a well tinted with `tint`;
/// `h` points high, with the range's marks under it when `axis`. The
/// column under the pointer goes to `graph`'s hover (read by the card's
/// title, drawn before the graph: a change draws another frame so the
/// title catches up).
pub fn dots(c: *ui.Context, k: theme.Colors, a: *App, series: []const Series, scale: ?f32, h: f32, axis: bool, graph: ?app_mod.Graph, tint: ui.Color) void {
    _ = k;
    const small = h < 100;
    const dot: f32 = if (small) 3.6 else 5;
    const pitch: f32 = if (small) 5.6 else 8;
    const inset: f32 = if (small) 8 else 12;
    const col = ui.div(c).column().wFull().gap(0).rounded(10).bg(tint.alpha(0.09));
    defer col.end();
    var tip_x: f32 = 0;
    const box = ui.div(c).wFull().h(h).p(inset);
    const it = box.interaction();
    const rect = it.rect orelse ui.Rect{ .x = 0, .y = 0, .w = 600, .h = h };
    const inner_w = @max(0, rect.w - 2 * inset);
    const cols: usize = @intFromFloat(@max(1, @floor((inner_w + pitch - dot) / pitch)));
    const rows: usize = @intFromFloat(@max(1, @floor((h - 2 * inset + pitch - dot) / pitch)));
    const x0 = (inner_w - (@as(f32, @floatFromInt(cols)) * pitch - (pitch - dot))) / 2;
    const n = a.range.samples(a.interval);
    const len = if (series.len > 0) series[0].values.len else 0;
    const start: i64 = @as(i64, @intCast(len)) - @as(i64, @intCast(n));
    // Each column's values: the mean of its slice of the range.
    var vals: [4][512]f32 = undefined;
    var has: [512]bool = undefined;
    const ncols = @min(cols, 512);
    var busiest: f32 = 0;
    for (0..ncols) |i| {
        var lo = start + @as(i64, @intCast(i * n / cols));
        var hi = start + @as(i64, @intCast((i + 1) * n / cols));
        if (hi <= lo) {
            lo = start + @as(i64, @intFromFloat(@floor((@as(f32, @floatFromInt(i)) + 0.5) * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(cols)))));
            hi = lo + 1;
        }
        lo = @max(lo, 0);
        hi = @min(hi, @as(i64, @intCast(len)));
        has[i] = hi > lo;
        var sum: f32 = 0;
        for (series[0..@min(series.len, 4)], 0..) |s, si| {
            var v: f32 = 0;
            if (has[i]) {
                for (s.values[@intCast(lo)..@intCast(hi)]) |x| v += x;
                v /= @floatFromInt(hi - lo);
            }
            vals[si][i] = v;
            sum += v;
        }
        busiest = @max(busiest, sum);
    }
    const top = scale orelse @max(busiest * 1.15, 1e-6);
    // The column under the pointer.
    var hover: ?Hover = null;
    var hot_col: ?usize = null;
    if (it.hovered) {
        c.wants_moves = true;
        const mx = c.input.mouse.x - rect.x - inset - x0;
        if (mx >= 0) {
            const ci: usize = @intFromFloat(@floor(mx / pitch));
            if (ci < ncols and has[ci]) {
                hot_col = ci;
                tip_x = inset + x0 + @as(f32, @floatFromInt(ci)) * pitch + dot / 2;
                var hv: Hover = .{ .ago = a.range.seconds() * (1 - (@as(f32, @floatFromInt(ci)) + 0.5) / @as(f32, @floatFromInt(cols))) };
                for (0..@min(series.len, 4)) |si| hv.values[si] = vals[si][ci];
                hover = hv;
            }
        }
    }
    const empty = tint.alpha(0.2);
    const rf: f32 = @floatFromInt(rows);
    for (0..ncols) |i| {
        // How many dots each series fills, stacked.
        var levels: [4]usize = @splat(0);
        var cum: f32 = 0;
        for (0..@min(series.len, 4)) |si| {
            cum += vals[si][i];
            levels[si] = @intFromFloat(@min(rf, @round(cum / top * rf)));
        }
        // A sliver still shows: the bottom dot of the first series.
        if (has[i] and series.len > 0 and levels[0] == 0) levels[0] = 1;
        const dim = hot_col != null and hot_col.? != i;
        const x = x0 + @as(f32, @floatFromInt(i)) * pitch;
        for (0..rows) |r| {
            var color = empty;
            for (0..@min(series.len, 4)) |si| if (has[i] and r < levels[si]) {
                color = series[si].color;
                break;
            };
            if (dim and color.a > 0.5) color = color.alpha(0.55);
            const y = (rf - 1 - @as(f32, @floatFromInt(r))) * pitch + (h - 2 * inset - (rf * pitch - (pitch - dot))) / 2;
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = dot }, .height = .{ .px = dot }, .radius = dot * 0.3, .background = color }, .none, null);
        }
    }
    box.end();
    if (axis) marks(c, a.range, tint);
    if (hover) |hv| tip(c, a, series, hv, tip_x, rect.w);
    if (graph) |g| {
        const was = a.hovers.get(g);
        const same = if (was) |w| (if (hover) |now| std.meta.eql(w, now) else false) else hover == null;
        if (!same) c.animationFrame();
        a.hovers.set(g, hover);
    }
}

/// The card over the column under the pointer: how long ago, and each
/// series' value by its color (`series`' names), above the graph.
fn tip(c: *ui.Context, a: *App, series: []const Series, hv: Hover, x: f32, w: f32) void {
    var named: usize = 0;
    for (series) |s| {
        if (s.name.len > 0) named += 1;
    }
    if (named == 0) return;
    const dark = c.theme.background.r < 0.5;
    const k = theme.colors(dark);
    const card_w: f32 = 150;
    const card_h: f32 = 34 + 20 * @as(f32, @floatFromInt(named));
    const left = std.math.clamp(x - card_w / 2, 0, @max(0, w - card_w));
    const d = ui.div(c).absolute().offset(left, -card_h - 6).w(card_w).column().gap(4).px(12).py(9).rounded(10).bg(k.page).border(k.separator).shadow(.{ .color = .{ .a = 0.14 }, .blur = 12, .y = 3 });
    defer d.end();
    ui.text(c, if (hv.ago < 1.5) "Now" else c.print("{s} ago", .{ago(c, hv.ago)[3..]}), .{ .size = 11, .color = k.secondary });
    // The series stack bottom up; the card lists them as they are drawn.
    for (series, 0..) |s, i| {
        if (s.name.len == 0 or i >= 4) continue;
        const r = ui.div(c).row().wFull().gap(7).itemsCenter();
        defer r.end();
        _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = s.color }, .none, null);
        ui.text(c, s.name, .{ .size = 12, .color = k.text });
        ui.spacer(c);
        const v = hv.values[i];
        const said: []const u8 = switch (s.unit) {
            .percent => if (v < 10) c.print("{d:.1}%", .{v}) else c.print("{d:.0}%", .{v}),
            .rate => rate(c, a, v),
            .memory => bytes(c, @intFromFloat(@max(0, v) / 100 * @as(f32, @floatFromInt(a.sampler.system.mem_total)))),
            .bytes => bytes(c, @intFromFloat(@max(0, v))),
        };
        ui.text(c, said, .{ .size = 12, .weight = .semibold, .color = k.text });
    }
}

/// The range's marks under a graph: "−1m … now".
fn marks(c: *ui.Context, r: app_mod.Range, tint: ui.Color) void {
    const labels: []const []const u8 = switch (r) {
        .m1 => &.{ "−1m", "−45s", "−30s", "−15s", "now" },
        .m5 => &.{ "−5m", "−4m", "−3m", "−2m", "−1m", "now" },
        .m15 => &.{ "−15m", "−10m", "−5m", "now" },
        .h1 => &.{ "−1h", "−45m", "−30m", "−15m", "now" },
    };
    const row = ui.div(c).row().wFull().justifyBetween().px(12).pb(6);
    defer row.end();
    for (labels) |l| ui.text(c, l, .{ .size = 10, .color = tint.mix(.{ .r = 0.5, .g = 0.5, .b = 0.5 }, 0.5).alpha(0.8) });
}

/// "−42s", "−3m 10s".
pub fn ago(c: *ui.Context, s: f32) []const u8 {
    const t: u32 = @intFromFloat(@max(0, s));
    if (t < 60) return c.print("−{d}s", .{t});
    if (t % 60 == 0) return c.print("−{d}m", .{t / 60});
    return c.print("−{d}m {d}s", .{ t / 60, t % 60 });
}

/// The mean of the last `n` values.
pub fn mean(values: []const f32, n: usize) f32 {
    const v = values[values.len -| n..];
    if (v.len == 0) return 0;
    var s: f32 = 0;
    for (v) |x| s += x;
    return s / @as(f32, @floatFromInt(v.len));
}

/// The largest of the last `n` values.
pub fn peak(values: []const f32, n: usize) f32 {
    var m: f32 = 0;
    for (values[values.len -| n..]) |x| m = @max(m, x);
    return m;
}

const Ring = struct {
    parts: []const Part,
    track: ui.Color,
    width: f32,
    gap: f32,

    fn draw(r: Ring, p: *ui.Painter) void {
        const cx = p.size.w / 2;
        const cy = p.size.h / 2;
        const rad = @min(cx, cy) - r.width / 2;
        const tau = 2 * std.math.pi;
        const start = -std.math.pi / 2.0;
        var track = p.path();
        track.arc(cx, cy, rad, 0, tau, false);
        p.stroke(&track, .color(r.track), .{ .width = r.width });
        var at: f32 = 0;
        for (r.parts) |part| {
            const f = std.math.clamp(part[0], 0, 1 - at);
            if (f < 0.002) continue;
            const gap = if (r.parts.len > 1) @min(r.gap, f * tau * 0.3) else 0;
            var arc = p.path();
            arc.arc(cx, cy, rad, start + at * tau + gap / 2, start + (at + f) * tau - gap / 2, false);
            p.stroke(&arc, .color(part[1]), .{ .width = r.width, .cap = if (r.parts.len == 1) .round else .butt });
            at += f;
        }
    }
};

pub const Open = struct {
    outer: ui.Div,
    inner: ui.Div,

    pub fn end(o: Open) void {
        o.inner.end();
        o.outer.end();
    }
};

/// A ring `d` points across, `w` thick: the parts clockwise from the top
/// over the track; open, to put words in its middle, until `end`.
pub fn ring(c: *ui.Context, d: f32, w: f32, parts: []const Part, track: ui.Color) Open {
    const box = ui.div(c).w(d).h(d);
    _ = ui.canvas(c, .{ .w = d, .h = d }, .{}, Ring{ .parts = parts, .track = track, .width = w, .gap = 0.05 }, Ring.draw);
    return .{ .outer = box, .inner = ui.div(c).absolute().sizeFull().column().center() };
}

pub const Tile = struct { name: []const u8, bundle: []const u8, value: u64 };

/// The tiles in a box `h` high, each with room as its share of their sum
/// (largest first), halves split along the longer side: a treemap. Each
/// shows its icon, and its name and size where there is room.
pub fn treemap(c: *ui.Context, a: *App, k: theme.Colors, tiles: []const Tile, h: f32) void {
    const box = ui.div(c).wFull().h(h);
    defer box.end();
    const r = box.interaction().rect orelse return c.animationFrame();
    var rects: [16]ui.Rect = undefined;
    const n = @min(tiles.len, rects.len);
    split(tiles[0..n], .{ .x = 0, .y = 0, .w = r.w, .h = h }, rects[0..n]);
    for (tiles[0..n], rects[0..n]) |t, q| {
        ui.key(c, t.bundle);
        const gap: f32 = 3;
        const d = ui.div(c).absolute().offset(q.x + gap / 2, q.y + gap / 2).w(@max(0, q.w - gap)).h(@max(0, q.h - gap)).column().p(8).gap(2).rounded(8).bg(k.page).clip();
        defer d.end();
        icon(c, a, k, t.bundle, 18);
        ui.spacer(c);
        if (q.w < 56 or q.h < 44) continue;
        ui.text(c, t.name, .{ .size = 11.5, .weight = .medium, .color = k.text });
        if (q.h >= 62) ui.text(c, bytes(c, t.value), .{ .size = 10.5, .color = k.secondary });
    }
}

fn split(tiles: []const Tile, r: ui.Rect, out: []ui.Rect) void {
    if (tiles.len == 0) return;
    if (tiles.len == 1) {
        out[0] = r;
        return;
    }
    var total: f64 = 0;
    for (tiles) |t| total += @floatFromInt(t.value);
    // The first part: the tiles up to about half the sum.
    var acc: f64 = 0;
    var cut: usize = 0;
    while (cut < tiles.len - 1) {
        acc += @floatFromInt(tiles[cut].value);
        cut += 1;
        if (acc >= total / 2) break;
    }
    const f: f32 = if (total > 0) @floatCast(acc / total) else 0.5;
    if (r.w >= r.h) {
        split(tiles[0..cut], .{ .x = r.x, .y = r.y, .w = r.w * f, .h = r.h }, out[0..cut]);
        split(tiles[cut..], .{ .x = r.x + r.w * f, .y = r.y, .w = r.w * (1 - f), .h = r.h }, out[cut..]);
    } else {
        split(tiles[0..cut], .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h * f }, out[0..cut]);
        split(tiles[cut..], .{ .x = r.x, .y = r.y + r.h * f, .w = r.w, .h = r.h * (1 - f) }, out[cut..]);
    }
}

/// The `out.len` largest apps by `by`.
pub fn topApps(a: *App, out: []app_mod.AppRow, by: enum { cpu, memory, gpu, disk }) usize {
    var n: usize = 0;
    for (a.apps.items) |r| {
        const v = appKey(r, by);
        if (v <= 0) continue;
        var at = n;
        while (at > 0 and appKey(out[at - 1], by) < v) : (at -= 1) {}
        if (at >= out.len) continue;
        var j = @min(n, out.len - 1);
        while (j > at) : (j -= 1) out[j] = out[j - 1];
        out[at] = r;
        n = @min(n + 1, out.len);
    }
    return n;
}

fn appKey(r: app_mod.AppRow, by: anytype) f64 {
    return switch (by) {
        .cpu => r.cpu,
        .memory => @floatFromInt(r.memory),
        .gpu => r.gpu,
        .disk => r.disk_rate,
    };
}

/// "Normal", "Elevated", "High": how hard memory is pressed, and its color.
pub fn pressure(k: theme.Colors, p: f32) struct { []const u8, ui.Color } {
    if (p >= 90) return .{ "High", k.red };
    if (p >= 75) return .{ "Elevated", k.orange };
    return .{ "Normal", k.green };
}

/// Memory by kind as parts of all of it: app, wired, compressed, cached,
/// free, with their colors.
pub fn memoryParts(k: theme.Colors, sy: model.System) [5]struct { []const u8, u64, ui.Color } {
    const used = sy.mem_app + sy.mem_wired + sy.mem_compressed;
    const free = sy.mem_total -| used -| sy.mem_cached;
    return .{
        .{ "App", sy.mem_app, k.green },
        .{ "Wired", sy.mem_wired, k.orange },
        .{ "Compressed", sy.mem_compressed, k.sky },
        .{ "Cached", sy.mem_cached, k.gray.alpha(0.55) },
        .{ "Free", free, k.empty },
    };
}

/// "2h 10m", "45m".
pub fn hoursMinutes(c: *ui.Context, s: u32) []const u8 {
    if (s >= 3600) return c.print("{d}h {d}m", .{ s / 3600, (s / 60) % 60 });
    return c.print("{d}m", .{s / 60});
}

pub const By = enum { cpu, memory, gpu, disk };

/// "Using the Most CPU": the apps highest by `by` in two columns, each
/// with its icon, name, how many processes and its figure; "Show All"
/// opens the processes, sorted by it.
pub fn most(c: *ui.Context, a: *App, k: theme.Colors, heading: []const u8, g: Glyph, color: ui.Color, by: By) void {
    const d = card(c, k).gap(6);
    defer d.end();
    {
        const t = title(c, g, heading, color);
        defer t.end();
        if (link(c, k, "Show All")) {
            a.page = .processes;
            a.sort = switch (by) {
                .cpu => .cpu,
                .memory => .memory,
                .gpu => .gpu,
                .disk => .written,
            };
            a.ascending = false;
            a.dirty = true;
        }
    }
    var best: [10]app_mod.AppRow = undefined;
    const n = topApps(a, &best, switch (by) {
        .cpu => .cpu,
        .memory => .memory,
        .gpu => .gpu,
        .disk => .disk,
    });
    const half = (n + 1) / 2;
    const r = ui.div(c).row().wFull().gap(40).itemsStart().pt(4);
    defer r.end();
    for ([_][]const app_mod.AppRow{ best[0..half], best[half..n] }, 0..) |part, ci| {
        ui.key(c, if (ci == 0) "left" else "right");
        const col = ui.div(c).column().grow().w(0);
        defer col.end();
        for (part) |row| {
            ui.key(c, row.bundle);
            const l = ui.div(c).row().wFull().h(34).gap(10).itemsCenter();
            defer l.end();
            appName(c, a, k, row.bundle, row.name, row.processes);
            const v: []const u8 = switch (by) {
                .cpu => c.print("{d:.1}%", .{row.cpu}),
                .memory => bytes(c, row.memory),
                .gpu => c.print("{d:.1}%", .{row.gpu}),
                .disk => rate(c, a, row.disk_rate),
            };
            ui.text(c, v, .{ .size = 12.5, .weight = .semibold, .color = k.text });
        }
    }
}
