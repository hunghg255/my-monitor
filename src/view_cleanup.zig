//! The Cleanup page: the system drive's free space, and what can go (apps'
//! caches, package managers' downloads, build caches, old agent sessions,
//! installers left in Downloads, logs, stale temporary files), scanned on
//! a thread of its own; the drive as dots, each a slice of it, colored by
//! what holds it; a line for each kind (its size, files, newest change)
//! with a box to tick; and, after asking, the ticked kinds moved to the
//! Recycle Bin on a thread of their own, then scanned again.
const std = @import("std");
const builtin = @import("builtin");
const myzig = @import("myzig");
const ui = myzig.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Glyph = @import("glyphs.zig").Glyph;
const cw = if (builtin.os.tag == .windows) @import("cleanup_win.zig") else struct {};

/// Moving to the Recycle Bin, on its own thread: running, and the bytes
/// gone so far.
var cleaning = std.atomic.Value(bool).init(false);
var moved = std.atomic.Value(u64).init(0);
var was_cleaning = false;

fn look(k: theme.Colors, kind: cw.Kind) struct { Glyph, ui.Color } {
    return switch (kind) {
        .caches => .{ .layers, k.blue },
        .package_caches => .{ .package, k.orange },
        .developer => .{ .hammer, k.red },
        .agent_sessions => .{ .chat, k.sky },
        .installers => .{ .download, ui.Color.hex(0x9a7149) },
        .logs => .{ .doc, k.yellow },
        .temporary => .{ .clock, k.teal },
    };
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (comptime builtin.os.tag != .windows) return;
    const s = &a.cleanup;
    const busy = s.running() or cleaning.load(.acquire);
    if (busy) c.frameIn(0.25);
    if (was_cleaning and !cleaning.load(.acquire)) {
        // Done: what went, then what is left.
        a.cleaned = moved.load(.acquire);
        s.start();
    }
    was_cleaning = cleaning.load(.acquire);
    {
        const h = kit.header(c, k, "Cleanup", "");
        defer h.end();
        if (kit.roundButton(c, k, "rescan", .refresh, k.secondary, !busy)) s.start();
        kit.pause(c, a, k);
    }
    const body = kit.body(c);
    defer body.end();
    hero(c, a, k);
    list(c, a, k);
}

fn hero(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.cleanup;
    const free = cw.freeSpace();
    const total = cw.totalSpace();
    var can: u64 = 0;
    var ticked: u64 = 0;
    if (s.done()) for (cw.kinds, 0..) |kind, i| {
        const f = s.found(kind);
        can += f.bytes;
        if (a.clean_ticked[i]) ticked += f.bytes;
    };
    const d = kit.card(c, k).gap(16);
    defer d.end();
    {
        const r = ui.div(c).row().wFull().gap(16).itemsCenter();
        defer r.end();
        kit.chip(c, .cleanup, k.orange, 44, false);
        {
            const col = ui.div(c).column().gap(2).grow().w(0);
            defer col.end();
            ui.text(c, "Free space", .{ .size = 12, .color = k.secondary });
            var b: [32]u8 = undefined;
            const t = @import("model.zig").bytes(&b, free);
            const sp = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
            kit.figure(c, k, c.print("{s}", .{t[0..sp]}), c.print("{s}", .{t[sp + 1 ..]}), 30);
            const note = if (cleaning.load(.acquire))
                c.print("Moving to the Recycle Bin… {s} so far", .{kit.bytes(c, moved.load(.acquire))})
            else if (s.running())
                c.print("Scanning… {d} files looked at", .{s.progress()})
            else if (s.done())
                c.print("{s} can be cleaned{s}", .{ kit.bytes(c, can), if (a.cleaned > 0) c.print(" · {s} moved to the Recycle Bin", .{kit.bytes(c, a.cleaned)}) else "" })
            else
                "Scan to see what can be cleaned.";
            ui.text(c, note, .{ .size = 12, .color = k.secondary });
        }
        const busy = s.running() or cleaning.load(.acquire);
        if (s.done() and ticked > 0) {
            if (ui.button(c, c.print("Clean {s}…", .{kit.bytes(c, ticked)}), .{ .variant = .primary, .size = 13, .disabled = busy }).clicked) a.confirm_clean = true;
        } else if (ui.button(c, "Scan", .{ .variant = .primary, .size = 13, .disabled = busy }).clicked) s.start();
    }
    var parts: [cw.kinds.len + 1]kit.Part = undefined;
    var used_known: u64 = 0;
    for (cw.kinds, 0..) |kind, i| {
        const bytes = if (s.done()) s.found(kind).bytes else 0;
        used_known += bytes;
        parts[i] = .{ frac(bytes, total), look(k, kind)[1] };
    }
    parts[cw.kinds.len] = .{ frac((total -| free) -| used_known, total), k.gray.alpha(0.45) };
    _ = ui.canvas(c, .{ .w = 0, .h = 96 }, .{}, Grid{ .parts = &parts, .free = k.gray.alpha(0.16) }, Grid.draw);
    const lg = ui.div(c).row().wFull().gap(4).itemsCenter();
    defer lg.end();
    for (cw.kinds) |kind| kit.legend(c, k, &.{.{ cw.name(kind), look(k, kind)[1] }});
    kit.legend(c, k, &.{ .{ "Other files", k.gray.alpha(0.6) }, .{ c.print("Free {s}", .{kit.bytes(c, free)}), k.gray.alpha(0.25) } });
}

fn frac(n: u64, total: u64) f32 {
    if (total == 0) return 0;
    return @floatCast(@as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(total)));
}

/// The drive as rows of dots, column by column, each dot an equal slice
/// of it: each kind's, then other files', then free.
const Grid = struct {
    parts: []const kit.Part,
    free: ui.Color,

    fn draw(g: Grid, p: *ui.Painter) void {
        const pitch: f32 = 7;
        const r: f32 = 2.2;
        const rows: usize = @intFromFloat(@floor(p.size.h / pitch));
        const cols: usize = @intFromFloat(@floor(p.size.w / pitch));
        const n = rows * cols;
        if (n == 0) return;
        var at: usize = 0;
        var part: usize = 0;
        var edge: f32 = if (g.parts.len > 0) g.parts[0][0] else 0;
        for (0..cols) |ci| for (0..rows) |ri| {
            const f = (@as(f32, @floatFromInt(at)) + 0.5) / @as(f32, @floatFromInt(n));
            while (part < g.parts.len and f > edge) {
                part += 1;
                if (part < g.parts.len) edge += g.parts[part][0];
            }
            const color = if (part < g.parts.len) g.parts[part][1] else g.free;
            p.fillCircle(@as(f32, @floatFromInt(ci)) * pitch + pitch / 2, @as(f32, @floatFromInt(ri)) * pitch + pitch / 2, r, .color(color));
            at += 1;
        };
    }
};

fn list(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.cleanup;
    const box = ui.div(c).column().wFull();
    defer box.end();
    {
        const h = ui.div(c).row().wFull().h(30).itemsCenter().px(4);
        defer h.end();
        ui.text(c, "Name", .{ .size = 12, .color = k.secondary });
        ui.spacer(c);
        head(c, k, "Size", 100);
        head(c, k, "Files", 80);
        head(c, k, "Modified", 120);
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.separator }, .none, null);
    const now = cw.now();
    for (cw.kinds, 0..) |kind, i| {
        ui.key(c, cw.name(kind));
        const f = if (s.done()) s.found(kind) else cw.Found{};
        const r = ui.div(c).row().wFull().h(34).itemsCenter().gap(10).px(4).rounded(6).bg(if (i % 2 == 1) k.stripe else k.page);
        defer r.end();
        if (tick(c, k, a.clean_ticked[i])) a.clean_ticked[i] = !a.clean_ticked[i];
        const g, const color = look(k, kind);
        kit.chip(c, g, color, 20, false);
        {
            const t = ui.div(c).row().grow().w(0).gap(8).itemsCenter().clip();
            defer t.end();
            ui.text(c, cw.name(kind), .{ .size = 12.5, .weight = .semibold, .color = k.text });
            ui.text(c, cw.about(kind), .{ .size = 11.5, .color = k.tertiary });
        }
        const known = s.done();
        value(c, k, if (known) kit.bytes(c, f.bytes) else "–", 100);
        value(c, k, if (known) c.print("{d}", .{f.files}) else "–", 80);
        value(c, k, if (known and f.newest_unix > 0) since(c, now - f.newest_unix) else "–", 120);
    }
}

fn head(c: *ui.Context, k: theme.Colors, text: []const u8, w: f32) void {
    const d = ui.div(c).row().w(w).justifyEnd().px(8);
    defer d.end();
    ui.text(c, text, .{ .size = 12, .color = k.secondary });
}

fn value(c: *ui.Context, k: theme.Colors, text: []const u8, w: f32) void {
    const d = ui.div(c).row().w(w).justifyEnd().px(8);
    defer d.end();
    ui.text(c, text, .{ .size = 12.5, .color = k.text });
}

/// "Today", "3 days ago", "2 months ago".
fn since(c: *ui.Context, s: i64) []const u8 {
    const days = @divFloor(@max(0, s), 86400);
    if (days < 1) return "Today";
    if (days < 2) return "Yesterday";
    if (days < 31) return c.print("{d} days ago", .{days});
    const months = @divFloor(days, 30);
    if (days < 365) return if (months == 1) "1 month ago" else c.print("{d} months ago", .{months});
    const years = @divFloor(days, 365);
    return if (years == 1) "1 year ago" else c.print("{d} years ago", .{years});
}

/// A check box; whether it was clicked.
fn tick(c: *ui.Context, k: theme.Colors, on: bool) bool {
    ui.key(c, "tick");
    const cell = ui.div(c).row().w(24).h(24).center().control();
    defer cell.end();
    const clicked = cell.clicked();
    const box = ui.div(c).row().w(16).h(16).center().rounded(4).bg(if (on) k.accent else k.page).border(if (on) k.accent else k.tertiary);
    defer box.end();
    if (on) kit.glyph(c, .check, 11, .white);
    return clicked;
}

/// Asks before the ticked kinds go to the Recycle Bin.
pub fn confirm(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (comptime builtin.os.tag != .windows) return;
    if (!a.confirm_clean) return;
    const s = &a.cleanup;
    const scrim = ui.div(c).absolute().sizeFull().column().center().bg(.{ .a = 0.25 });
    defer scrim.end();
    if (scrim.clicked()) a.confirm_clean = false;
    const box = ui.div(c).column().w(440).gap(14).p(22).rounded(12).bg(k.page).border(k.separator).shadowLg();
    defer box.end();
    _ = box.interaction();
    var total: u64 = 0;
    for (cw.kinds, 0..) |kind, i| {
        if (a.clean_ticked[i]) total += s.found(kind).bytes;
    }
    {
        const h = ui.div(c).row().gap(12).itemsCenter();
        defer h.end();
        kit.chip(c, .trash, k.orange, 34, false);
        ui.text(c, c.print("Move {s} to the Recycle Bin?", .{kit.bytes(c, total)}), .{ .size = 15, .weight = .semibold, .color = k.text });
    }
    {
        const l = ui.div(c).column().wFull().p(10).rounded(8).bg(k.card);
        defer l.end();
        for (cw.kinds, 0..) |kind, i| if (a.clean_ticked[i] and s.found(kind).bytes > 0) {
            ui.key(c, cw.name(kind));
            kit.line(c, k, cw.name(kind), kit.bytes(c, s.found(kind).bytes), null);
        };
    }
    ui.text(c, "Apps and tools make these again as they need them. Files in use stay where they are; the Recycle Bin gives back anything you miss.", .{ .size = 12, .color = k.secondary, .wrap = true });
    const r = ui.div(c).row().wFull().gap(8);
    defer r.end();
    ui.spacer(c);
    if (ui.button(c, "Cancel", .{ .size = 13 }).clicked) a.confirm_clean = false;
    if (ui.button(c, "Move to Recycle Bin", .{ .variant = .primary, .size = 13 }).clicked) {
        a.confirm_clean = false;
        start(a);
    }
}

/// Moves the ticked kinds to the Recycle Bin on a thread of its own.
fn start(a: *App) void {
    if (cleaning.load(.acquire) or a.cleanup.running()) return;
    cleaning.store(true, .release);
    moved.store(0, .release);
    const t = std.Thread.spawn(.{}, run, .{a}) catch {
        cleaning.store(false, .release);
        return;
    };
    t.detach();
}

fn run(a: *App) void {
    for (cw.kinds, 0..) |kind, i| {
        if (a.clean_ticked[i]) _ = moved.fetchAdd(a.cleanup.clean(kind), .acq_rel);
    }
    // The page looks in while it runs.
    cleaning.store(false, .release);
}
