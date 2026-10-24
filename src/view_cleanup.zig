//! The Cleanup page: each drive's usage, largest folders and what can go (apps'
//! caches, package managers' downloads, build caches, old agent sessions,
//! installers left in Downloads, logs, stale temporary files), scanned on
//! a thread of its own; the drive as dots, each a slice of it, colored by
//! what holds it; a line for each kind (its size, files, newest change)
//! with a box to tick; and, after asking, the ticked items moved to the
//! Recycle Bin on a thread of their own, then scanned again. Each kind
//! opens to its groups (npm's cache, Go's; Codex's sessions; each
//! installer), and a group to its items, each with a box of its own.
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
var clean_thread: ?std.Thread = null;

/// The worker owns the scan's paths until it has finished recycling.
pub fn waitForCleaning() void {
    if (clean_thread) |t| t.join();
    clean_thread = null;
    was_cleaning = false;
}

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
    const is_cleaning = cleaning.load(.acquire);
    if (was_cleaning and !is_cleaning) {
        // Done: what went, then what is left.
        a.cleaned = moved.load(.acquire);
        s.startDrive(s.scope);
    }
    was_cleaning = is_cleaning;
    const busy = s.running() or is_cleaning;
    if (busy) c.frameIn(0.25);
    {
        const h = kit.header(c, k, "Cleanup", "");
        defer h.end();
        if (kit.roundButton(c, k, "rescan", .refresh, k.secondary, !busy)) s.startDrive(a.clean_drive);
        kit.pause(c, a, k);
    }
    const body = kit.body(c);
    defer body.end();
    drivePicker(c, a, k);
    hero(c, a, k);
    if (s.done()) {
        if (a.clean_drive == null) if (s.scope) |letter| {
            ui.text(c, c.print("Showing the last scan of {c}:. Scan again to include all drives.", .{letter}), .{ .size = 12, .color = k.secondary });
        };
        var shown = false;
        for (s.drives[0..s.n_drives]) |drive| {
            if (a.clean_drive) |letter| if (drive.volume.letter != letter) continue;
            shown = true;
            driveResult(c, a, k, drive);
        }
        if (!shown) ui.text(c, "This drive has not been scanned. Choose Scan to analyze it.", .{ .size = 13, .color = k.secondary });
    }
}

fn drivePicker(c: *ui.Context, a: *App, k: theme.Colors) void {
    const row = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer row.end();
    const busy = a.cleanup.running() or cleaning.load(.acquire);
    if (ui.button(c, "All drives", .{ .size = 12, .variant = if (a.clean_drive == null) .primary else .secondary, .disabled = busy }).clicked) a.clean_drive = null;
    for (a.sampler.volumes[0..a.sampler.n_volumes]) |v| {
        if (ui.button(c, c.print("{c}:", .{v.letter}), .{ .size = 12, .variant = if (a.clean_drive == v.letter) .primary else .secondary, .disabled = busy }).clicked) a.clean_drive = v.letter;
    }
    ui.spacer(c);
    ui.text(c, "Local drives and connected USB drives", .{ .size = 11.5, .color = k.secondary });
}

fn hero(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.cleanup;
    var free: u64 = 0;
    var total: u64 = 0;
    for (a.sampler.volumes[0..a.sampler.n_volumes]) |v| {
        if (a.clean_drive) |letter| if (v.letter != letter) continue;
        free += v.free;
        total += v.total;
    }
    var can: u64 = 0;
    var ticked: u64 = 0;
    if (s.done()) for (cw.kinds) |kind| {
        can += if (a.clean_drive) |letter| s.foundOn(kind, letter).bytes else s.found(kind).bytes;
        ticked += s.ticked(kind).bytes;
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
            ui.text(c, if (a.clean_drive) |letter| c.print("Free space on {c}:", .{letter}) else "Free space across all drives", .{ .size = 12, .color = k.secondary });
            var b: [32]u8 = undefined;
            const t = @import("model.zig").bytes(&b, free);
            const sp = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
            kit.figure(c, k, c.print("{s}", .{t[0..sp]}), c.print("{s}", .{t[sp + 1 ..]}), 30);
            const note = if (cleaning.load(.acquire))
                c.print("Moving to the Recycle Bin… {s} so far", .{kit.bytes(c, moved.load(.acquire))})
            else if (s.running())
                c.print("Scanning {s}… {d} files looked at", .{ if (s.current_drive.load(.monotonic) == 0) "drives" else c.print("{c}:", .{s.current_drive.load(.monotonic)}), s.progress() })
            else if (s.done())
                c.print("{s} cleanup candidates{s}{s}", .{ kit.bytes(c, can), if (s.stop.load(.monotonic)) " · Scan stopped, partial results" else "", if (a.cleaned > 0) c.print(" · {s} removed from original locations", .{kit.bytes(c, a.cleaned)}) else "" })
            else
                "Scan to see what can be cleaned.";
            ui.text(c, note, .{ .size = 12, .color = k.secondary });
        }
        const busy = s.running() or cleaning.load(.acquire);
        if (s.running()) {
            if (ui.button(c, "Stop scan", .{ .size = 13 }).clicked) s.cancel();
        } else if (s.done() and ticked > 0) {
            if (ui.button(c, c.print("Clean selected {s}…", .{kit.bytes(c, ticked)}), .{ .variant = .primary, .size = 13, .disabled = busy }).clicked) a.confirm_clean = true;
        } else if (ui.button(c, "Scan", .{ .variant = .primary, .size = 13, .disabled = busy }).clicked) s.startDrive(a.clean_drive);
    }
    var parts: [cw.kinds.len + 1]kit.Part = undefined;
    var used_known: u64 = 0;
    for (cw.kinds, 0..) |kind, i| {
        const bytes = if (s.done()) (if (a.clean_drive) |letter| s.foundOn(kind, letter).bytes else s.found(kind).bytes) else 0;
        used_known += bytes;
        parts[i] = .{ frac(bytes, total), look(k, kind)[1] };
    }
    parts[cw.kinds.len] = .{ frac((total -| free) -| used_known, total), k.gray.alpha(0.45) };
    _ = ui.canvas(c, .{ .w = 0, .h = 96 }, .{}, Grid{ .parts = &parts, .free = k.gray.alpha(0.16) }, Grid.draw);
    const lg = ui.div(c).row().wFull().gap(4).itemsCenter().clip();
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

fn driveResult(c: *ui.Context, a: *App, k: theme.Colors, drive: cw.Drive) void {
    const v = drive.volume;
    ui.key(c, c.print("drive-{c}", .{v.letter}));
    const card = kit.card(c, k);
    defer card.end();
    {
        const title = kit.title(c, .disk, c.print("{c}:  {s}", .{ v.letter, v.labelSlice() }), k.orange);
        defer title.end();
        ui.text(c, c.print("{s} used · {s} free of {s}", .{ kit.bytes(c, v.used()), kit.bytes(c, v.free), kit.bytes(c, v.total) }), .{ .size = 12, .color = k.secondary });
        if (ui.button(c, "Open drive", .{ .size = 12 }).clicked) _ = myzig.shell.openPath(c.print("{c}:\\", .{v.letter}));
    }
    {
        const row = ui.div(c).row().wFull();
        defer row.end();
        kit.bar(c, frac(v.used(), v.total), k.orange, 5);
    }
    ui.text(c, "Cleanup candidates", .{ .size = 13, .weight = .semibold, .color = k.text });
    list(c, a, k, v.letter);
    ui.text(c, "Largest folders and files", .{ .size = 13, .weight = .semibold, .color = k.text });
    ui.text(c, c.print("{s} measured · {d} skipped paths{s}", .{ kit.bytes(c, drive.found.bytes), drive.skipped, if (!drive.complete) " · Incomplete scan" else "" }), .{ .size = 11.5, .color = k.secondary });
    var line: usize = 0;
    usageRows(c, a, k, drive.entries, 0, &line);
    if (drive.entries.len == 0) ui.text(c, "No readable entries found.", .{ .size = 12, .color = k.secondary });
    ui.text(c, "Logical file sizes may differ from used disk space (links, compressed files and inaccessible data). System and personal folders are for inspection; select only listed cleanup candidates.", .{ .size = 11.5, .color = k.secondary, .wrap = true });
    if (a.cleanup.limited) ui.text(c, "Folder preview limit reached. Open File Explorer to inspect more.", .{ .size = 11.5, .color = k.secondary });
}

fn usageRows(c: *ui.Context, a: *App, k: theme.Colors, entries: []const cw.Usage, depth: f32, line: *usize) void {
    // Show the largest entries first; allow the full list on demand.
    const more_key = if (entries.len > 0) std.hash.Wyhash.hash(991, entries[0].path) else 0;
    const all = a.clean_groups.contains(more_key);
    for (entries[0..if (all) entries.len else @min(8, entries.len)]) |entry| {
        ui.key(c, entry.path);
        const key = std.hash.Wyhash.hash(990, entry.path);
        const open = a.clean_groups.contains(key);
        {
            const r, const toggled, _ = lineStart(c, k, line, depth, if (entry.children.len > 0) open else null, .absent);
            defer r.end();
            if (toggled and !a.clean_groups.remove(key)) a.clean_groups.put(a.sampler.gpa, key, {}) catch {};
            const name = entry.path[if (std.mem.lastIndexOfScalar(u8, entry.path, '\\')) |i| i + 1 else 0..];
            {
                const label = ui.div(c).row().grow().w(0).clip();
                defer label.end();
                ui.text(c, name, .{ .size = 12.5, .color = k.text });
            }
            ui.text(c, if (entry.protected) "Keep / system" else "Inspect first", .{ .size = 11.5, .color = if (entry.protected) k.tertiary else k.orange });
            value(c, k, kit.bytes(c, entry.found.bytes), 95);
            if (ui.button(c, "Open folder", .{ .size = 11 }).clicked) {
                // Always open the containing directory, never execute a file.
                const end = std.mem.lastIndexOfScalar(u8, entry.path, '\\') orelse 2;
                _ = myzig.shell.openPath(if (entry.is_dir) entry.path else entry.path[0 .. end + 1]);
            }
        }
        if (open) usageRows(c, a, k, entry.children, depth + 1, line);
    }
    if (entries.len > 8 and ui.button(c, if (all) "Show fewer" else c.print("Show all {d} entries", .{entries.len}), .{ .size = 11 }).clicked) {
        if (!a.clean_groups.remove(more_key)) a.clean_groups.put(a.sampler.gpa, more_key, {}) catch {};
    }
}

fn list(c: *ui.Context, a: *App, k: theme.Colors, drive: u8) void {
    const s = &a.cleanup;
    var count: u64 = 0;
    for (cw.kinds) |kind| count += s.foundOn(kind, drive).files;
    if (count == 0) {
        ui.text(c, "No recognized cleanup candidates on this drive. Inspect the folders below.", .{ .size = 12, .color = k.secondary });
        return;
    }
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
    // The kinds by size, those with nothing last.
    var order: [cw.kinds.len]cw.Kind = cw.kinds[0..].*;
    const By = struct { s: *const cw.Scanner, drive: u8 };
    if (s.done()) std.mem.sort(cw.Kind, &order, By{ .s = s, .drive = drive }, struct {
        fn lt(by: By, x: cw.Kind, y: cw.Kind) bool {
            return by.s.foundOn(x, by.drive).bytes > by.s.foundOn(y, by.drive).bytes;
        }
    }.lt);
    var line: usize = 0;
    for (order) |kind| {
        if (s.foundOn(kind, drive).files == 0) continue;
        ui.key(c, cw.name(kind));
        const col = ui.div(c).column().wFull();
        defer col.end();
        kindRow(c, a, k, kind, drive, &line);
        if (!s.done() or !a.clean_open[drive - 'A'][@backingInt(kind)]) continue;
        for (s.groups(kind), 0..) |g, gi| {
            if (g.drive != drive) continue;
            ui.key(c, c.print("g{d}", .{gi}));
            groupRow(c, a, k, kind, g, &line);
            if (g.label.len == 0 or g.count == 0 or !a.clean_groups.contains(groupKey(kind, g))) continue;
            for (g.first..g.first + g.count) |ii| {
                ui.key(c, c.print("i{d}", .{ii}));
                itemRow(c, a, k, kind, @intCast(ii), 2, &line);
            }
        }
    }
}

/// What opens a group, across scans: its kind and name.
fn groupKey(kind: cw.Kind, g: cw.Group) u64 {
    return std.hash.Wyhash.hash(@as(u64, g.drive) * 16 + @backingInt(kind), g.label);
}

/// A line of the list: its stripe, a chevron (or room for one) `depth`
/// steps in, and its box; whether the chevron was clicked, and whether the
/// box was.
fn lineStart(c: *ui.Context, k: theme.Colors, line: *usize, depth: f32, opens: ?bool, mark: Mark) struct { ui.Div, bool, bool } {
    const r = ui.div(c).row().wFull().h(30).itemsCenter().gap(8).px(4).rounded(6).bg(if (line.* % 2 == 1) k.stripe else k.page);
    line.* += 1;
    const in = ui.div(c).row().w(depth * 26);
    in.end();
    ui.key(c, "open");
    const ch = ui.div(c).row().w(18).h(18).center().rounded(4).control();
    const open_clicked = ch.clicked() and opens != null;
    if (opens) |o| kit.glyph(c, if (o) .chevron_down else .chevron_right, 11, k.secondary);
    ch.end();
    const ticked = if (mark != .absent) tick(c, k, mark) else blk: {
        const sp = ui.div(c).row().w(24);
        sp.end();
        break :blk false;
    };
    return .{ r, open_clicked, ticked };
}

/// Its size, files and newest change, at the line's end.
fn figures(c: *ui.Context, k: theme.Colors, f: ?cw.Found) void {
    const now = cw.now();
    value(c, k, if (f) |x| kit.bytes(c, x.bytes) else "–", 100);
    value(c, k, if (f) |x| c.print("{d}", .{x.files}) else "–", 80);
    value(c, k, if (f) |x| (if (x.newest_unix > 0) since(c, now - x.newest_unix) else "–") else "–", 120);
}

/// How many of `ticks` are on.
fn markOf(ticks: []const bool) Mark {
    var on: usize = 0;
    for (ticks) |t| {
        if (t) on += 1;
    }
    if (on == 0) return .none;
    return if (on == ticks.len) .all else .some;
}

fn kindRow(c: *ui.Context, a: *App, k: theme.Colors, kind: cw.Kind, drive: u8, line: *usize) void {
    const s = &a.cleanup;
    const found = s.foundOn(kind, drive);
    const n = found.files;
    var count: usize = 0;
    var on_count: usize = 0;
    for (s.groups(kind)) |g| if (g.drive == drive) {
        for (s.ticks(kind)[g.first..][0..g.count]) |on| {
            count += 1;
            if (on) on_count += 1;
        }
    };
    const mark: Mark = if (on_count == 0) .none else if (on_count == count) .all else .some;
    const open = &a.clean_open[drive - 'A'][@backingInt(kind)];
    const r, const toggled, const ticked = lineStart(c, k, line, 0, if (n > 0) open.* else null, if (n > 0 and !cleaning.load(.acquire)) mark else .absent);
    defer r.end();
    if (toggled) open.* = !open.*;
    if (ticked) {
        s.selectDrive(kind, drive, mark != .all);
    }
    const g, const color = look(k, kind);
    kit.chip(c, g, if (n > 0) color else color.alpha(0.6), 20, false);
    {
        const t = ui.div(c).row().grow().w(0).gap(8).itemsCenter().clip();
        defer t.end();
        ui.text(c, cw.name(kind), .{ .size = 12.5, .weight = .semibold, .color = if (n > 0) k.text else k.secondary });
        ui.text(c, if (cw.needsReview(kind)) "Review before deleting" else switch (kind) {
            .developer => "Rebuild / reinstall after removing",
            .logs => "Review logs and crash reports",
            .temporary => "Review stale files; close apps first",
            else => "Can be recreated; close apps first",
        }, .{ .size = 11.5, .color = if (cw.needsReview(kind)) k.orange else k.tertiary });
    }
    figures(c, k, if (n > 0) found else null);
}

fn groupRow(c: *ui.Context, a: *App, k: theme.Colors, kind: cw.Kind, g: cw.Group, line: *usize) void {
    const s = &a.cleanup;
    // An item alone: its own line.
    if (g.label.len == 0) return itemRow(c, a, k, kind, g.first, 1, line);
    const key = groupKey(kind, g);
    const opens = g.count > 0;
    const ticks = s.ticks(kind)[g.first..][0..g.count];
    const r, const toggled, const ticked = lineStart(c, k, line, 1, if (opens) a.clean_groups.contains(key) else null, if (cleaning.load(.acquire)) .absent else markOf(ticks));
    defer r.end();
    if (toggled and !a.clean_groups.remove(key)) a.clean_groups.put(a.sampler.gpa, key, {}) catch {};
    if (ticked) {
        const on = markOf(ticks) != .all;
        for (ticks) |*t| t.* = on;
    }
    const glyph, const color = look(k, kind);
    kit.chip(c, glyph, color, 18, false);
    {
        const t = ui.div(c).row().grow().w(0).gap(8).itemsCenter().clip();
        defer t.end();
        ui.text(c, g.label, .{ .size = 12.5, .color = k.text });
        if (opens) ui.text(c, c.print("{d} items", .{g.count}), .{ .size = 11.5, .color = k.tertiary });
    }
    figures(c, k, g.found);
}

/// Item `i` of `kind`: its name (the path's last part), `depth` steps in.
fn itemRow(c: *ui.Context, a: *App, k: theme.Colors, kind: cw.Kind, i: u32, depth: f32, line: *usize) void {
    const s = &a.cleanup;
    const on = &s.ticks(kind)[i];
    const r, _, const ticked = lineStart(c, k, line, depth, null, if (cleaning.load(.acquire)) .absent else if (on.*) .all else .none);
    defer r.end();
    if (ticked) on.* = !on.*;
    kit.glyph(c, .doc, 14, k.tertiary);
    var buf: [1024]u8 = undefined;
    const path = s.path(kind, i, &buf);
    {
        const t = ui.div(c).row().grow().w(0).clip();
        defer t.end();
        ui.text(c, c.print("{s}", .{path}), .{ .size = 12.5, .color = k.text });
        ui.tooltip(c, t.interaction(), c.print("{s}", .{path}));
    }
    figures(c, k, s.item(kind, i));
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

const Mark = enum { none, some, all, absent };

/// A check box, empty, partly or wholly ticked; whether it was clicked.
fn tick(c: *ui.Context, k: theme.Colors, mark: Mark) bool {
    ui.key(c, "tick");
    const cell = ui.div(c).row().w(24).h(24).center().control();
    defer cell.end();
    const clicked = cell.clicked();
    const on = mark == .all or mark == .some;
    const box = ui.div(c).row().w(16).h(16).center().rounded(4).bg(if (on) k.accent else k.page).border(if (on) k.accent else k.tertiary);
    defer box.end();
    if (mark == .all) kit.glyph(c, .check, 11, .white);
    if (mark == .some) _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 2 }, .radius = 1, .background = .white }, .none, null);
    return clicked;
}

/// Asks before the ticked items go to the Recycle Bin.
pub fn confirm(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (comptime builtin.os.tag != .windows) return;
    if (!a.confirm_clean or !a.cleanup.done() or cleaning.load(.acquire)) return;
    const s = &a.cleanup;
    const scrim = ui.div(c).absolute().sizeFull().column().center().bg(.{ .a = 0.25 });
    defer scrim.end();
    if (scrim.clicked()) a.confirm_clean = false;
    const box = ui.div(c).column().w(440).gap(14).p(22).rounded(12).bg(k.page).border(k.separator).shadowLg();
    defer box.end();
    _ = box.interaction();
    var total: u64 = 0;
    for (cw.kinds) |kind| total += s.ticked(kind).bytes;
    {
        const h = ui.div(c).row().gap(12).itemsCenter();
        defer h.end();
        kit.chip(c, .trash, k.orange, 34, false);
        ui.text(c, c.print("Move {s} to the Recycle Bin?", .{kit.bytes(c, total)}), .{ .size = 15, .weight = .semibold, .color = k.text });
    }
    {
        const l = ui.div(c).column().wFull().p(10).rounded(8).bg(k.card);
        defer l.end();
        for (s.drives[0..s.n_drives]) |drive| for (cw.kinds) |kind| {
            var bytes: u64 = 0;
            for (s.groups(kind)) |g| if (g.drive == drive.volume.letter) {
                for (g.first..g.first + g.count) |i| if (s.ticks(kind)[i]) {
                    bytes += s.item(kind, @intCast(i)).bytes;
                };
            };
            if (bytes > 0) kit.line(c, k, c.print("{c}: · {s}", .{ drive.volume.letter, cw.name(kind) }), kit.bytes(c, bytes), null);
        };
    }
    ui.text(c, "Close apps and build tools first. Caches and dependencies may need downloading or rebuilding. Installers and old sessions may contain data you still want. Windows will ask if an item cannot be recycled. Space is reclaimed only after emptying the Recycle Bin.", .{ .size = 12, .color = k.secondary, .wrap = true });
    const r = ui.div(c).row().wFull().gap(8);
    defer r.end();
    ui.spacer(c);
    if (ui.button(c, "Cancel", .{ .size = 13 }).clicked) a.confirm_clean = false;
    if (ui.button(c, "Move to Recycle Bin", .{ .variant = .primary, .size = 13 }).clicked) {
        a.confirm_clean = false;
        start(a);
    }
}

/// Moves the ticked items to the Recycle Bin on a thread of its own.
fn start(a: *App) void {
    if (cleaning.load(.acquire) or a.cleanup.running()) return;
    waitForCleaning();
    cleaning.store(true, .release);
    moved.store(0, .release);
    clean_thread = std.Thread.spawn(.{}, run, .{a}) catch {
        cleaning.store(false, .release);
        return;
    };
    was_cleaning = true;
}

fn run(a: *App) void {
    for (cw.kinds) |kind| _ = moved.fetchAdd(a.cleanup.clean(kind), .acq_rel);
    // The page looks in while it runs.
    cleaning.store(false, .release);
}
