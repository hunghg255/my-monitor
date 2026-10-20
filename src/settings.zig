//! What mymonitor remembers between runs, as "key=value" lines in its
//! config directory (%APPDATA%\mymonitor\settings.txt on Windows): how
//! often it samples, the graphs' range, network units, the sidebar, the
//! process table's grouping, the page, and what the tray's panel shows.
const std = @import("std");
const myzig = @import("myzig");
const app_mod = @import("app.zig");
const App = app_mod.App;

const file = "settings.txt";

fn path(a: *App, buf: []u8) ?[]const u8 {
    const gpa = a.sampler.gpa;
    const dir = myzig.appPath(gpa, .config, "mymonitor") catch return null;
    defer gpa.free(dir);
    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, file }) catch null;
}

pub fn load(a: *App) void {
    var pb: [1024]u8 = undefined;
    const p = path(a, &pb) orelse return;
    var buf: [2048]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(a.sampler.io, p, &buf) catch return;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "interval")) {
            const f = std.fmt.parseFloat(f32, v) catch continue;
            for (app_mod.intervals) |i| if (i == f) {
                a.interval = f;
            };
        } else if (std.mem.eql(u8, key, "range")) {
            a.range = std.meta.stringToEnum(app_mod.Range, v) orelse a.range;
        } else if (std.mem.eql(u8, key, "page")) {
            a.page = std.meta.stringToEnum(app_mod.Page, v) orelse a.page;
        } else if (std.mem.eql(u8, key, "bits")) {
            a.bits = std.mem.eql(u8, v, "1");
        } else if (std.mem.eql(u8, key, "narrow")) {
            a.narrow = std.mem.eql(u8, v, "1");
        } else if (std.mem.eql(u8, key, "tree")) {
            a.tree = std.mem.eql(u8, v, "1");
        } else if (std.mem.startsWith(u8, key, "tray.")) {
            const part = std.meta.stringToEnum(app_mod.TrayPart, key["tray.".len..]) orelse continue;
            a.tray_parts.set(part, std.mem.eql(u8, v, "1"));
        }
    }
}

pub fn save(a: *App) void {
    var pb: [1024]u8 = undefined;
    const p = path(a, &pb) orelse return;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("interval={d}\nrange={s}\npage={s}\nbits={d}\nnarrow={d}\ntree={d}\n", .{
        a.interval, @tagName(a.range), @tagName(a.page), @intFromBool(a.bits), @intFromBool(a.narrow), @intFromBool(a.tree),
    }) catch return;
    for (std.enums.values(app_mod.TrayPart)) |part| w.print("tray.{s}={d}\n", .{ @tagName(part), @intFromBool(a.tray_parts.get(part)) }) catch return;
    std.Io.Dir.cwd().writeFile(a.sampler.io, .{ .sub_path = p, .data = w.buffered() }) catch {};
}

test "settings come back as they were saved" {
    var a: App = .init(std.testing.allocator, std.testing.io);
    defer a.deinit();
    var keep: App = .init(std.testing.allocator, std.testing.io);
    defer keep.deinit();
    load(&keep);
    defer save(&keep);
    a.interval = 2;
    a.bits = true;
    a.page = .energy;
    a.tray_parts.set(.network, true);
    save(&a);
    var b: App = .init(std.testing.allocator, std.testing.io);
    defer b.deinit();
    load(&b);
    try std.testing.expectEqual(@as(f32, 2), b.interval);
    try std.testing.expect(b.bits and b.page == .energy and b.tray_parts.get(.network));
}
