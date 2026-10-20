//! A program's icon on Windows, as PNG bytes for a table row: the exe's
//! first icon at the size asked for (PrivateExtractIconsW, so no COM and no
//! generic icon for exes without one), its pixels from GetDIBits, and a
//! small PNG encoder (stored deflate blocks, so tiny and simple).
const std = @import("std");

const HANDLE = *anyopaque;
const BOOL = c_int;

/// The icon of the program at `exe_path` (UTF-8), `size` px square (16 or 32), as PNG; null when it has none. Caller frees with `gpa`.
pub fn exePng(gpa: std.mem.Allocator, exe_path: []const u8, size: u32) ?[]u8 {
    const path = std.unicode.wtf8ToWtf16LeAllocZ(gpa, exe_path) catch return null;
    defer gpa.free(path);
    var icon: ?HANDLE = null;
    const n = PrivateExtractIconsW(path, 0, @intCast(size), @intCast(size), @ptrCast(&icon), null, 1, 0);
    // 0: no icons in it; all ones: it can't be read.
    if (n == 0 or n == std.math.maxInt(u32) or icon == null) return null;
    defer _ = DestroyIcon(icon.?);
    const rgba = pixels(gpa, icon.?, size) orelse return null;
    defer gpa.free(rgba);
    return encodePng(gpa, rgba, size, size) catch null;
}

/// Icon `icon`'s `size`x`size` pixels as RGBA; null for a monochrome icon.
fn pixels(gpa: std.mem.Allocator, icon: HANDLE, size: u32) ?[]u8 {
    var info: ICONINFO = .{};
    if (GetIconInfo(icon, &info) == 0) return null;
    defer if (info.hbmMask) |b| {
        _ = DeleteObject(b);
    };
    defer if (info.hbmColor) |b| {
        _ = DeleteObject(b);
    };
    const color = info.hbmColor orelse return null;
    const dc = GetDC(null) orelse return null;
    defer _ = ReleaseDC(null, dc);
    const out = gpa.alloc(u8, size * size * 4) catch return null;
    var bmi: BITMAPINFO = .{ .header = .{ .biWidth = @intCast(size), .biHeight = -@as(i32, @intCast(size)) } };
    if (GetDIBits(dc, color, 0, size, out.ptr, &bmi, DIB_RGB_COLORS) != @as(c_int, @intCast(size))) {
        gpa.free(out);
        return null;
    }
    var any_alpha = false;
    var i: usize = 0;
    while (i < out.len) : (i += 4) {
        std.mem.swap(u8, &out[i], &out[i + 2]);
        any_alpha = any_alpha or out[i + 3] != 0;
    }
    // Old icons have no alpha: their mask says which pixels show.
    if (!any_alpha) {
        const mask = gpa.alloc(u8, out.len) catch {
            gpa.free(out);
            return null;
        };
        defer gpa.free(mask);
        bmi = .{ .header = .{ .biWidth = @intCast(size), .biHeight = -@as(i32, @intCast(size)) } };
        const got = if (info.hbmMask) |m| GetDIBits(dc, m, 0, size, mask.ptr, &bmi, DIB_RGB_COLORS) else 0;
        i = 0;
        while (i < out.len) : (i += 4) out[i + 3] = if (got == 0 or mask[i] == 0) 255 else 0;
    }
    return out;
}

/// PNG bytes of `w`x`h` RGBA pixels.
pub fn encodePng(gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    std.debug.assert(rgba.len == @as(usize, w) * h * 4);
    // Each row starts with its filter (0: none).
    const row = @as(usize, w) * 4;
    const raw = try gpa.alloc(u8, (row + 1) * h);
    defer gpa.free(raw);
    for (0..h) |y| {
        raw[y * (row + 1)] = 0;
        @memcpy(raw[y * (row + 1) + 1 ..][0..row], rgba[y * row ..][0..row]);
    }
    var png: std.ArrayList(u8) = .empty;
    errdefer png.deinit(gpa);
    try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    // 8 bits, RGBA, deflate, adaptive filters, no interlace.
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(gpa, &png, "IHDR", &ihdr);
    // zlib: a header, stored deflate blocks of up to 65535 bytes, Adler-32.
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (true) {
        const n: u16 = @intCast(@min(raw.len - off, 65535));
        const last = off + n == raw.len;
        var head: [5]u8 = undefined;
        head[0] = @intFromBool(last);
        std.mem.writeInt(u16, head[1..3], n, .little);
        std.mem.writeInt(u16, head[3..5], ~n, .little);
        try z.appendSlice(gpa, &head);
        try z.appendSlice(gpa, raw[off..][0..n]);
        off += n;
        if (last) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(raw), .big);
    try z.appendSlice(gpa, &adler);
    try chunk(gpa, &png, "IDAT", z.items);
    try chunk(gpa, &png, "IEND", "");
    return png.toOwnedSlice(gpa);
}

/// A PNG chunk: length, type, data, CRC-32 of type and data.
fn chunk(gpa: std.mem.Allocator, png: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try png.appendSlice(gpa, &len);
    try png.appendSlice(gpa, kind);
    try png.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var sum: [4]u8 = undefined;
    std.mem.writeInt(u32, &sum, crc.final(), .big);
    try png.appendSlice(gpa, &sum);
}

const DIB_RGB_COLORS = 0;

const ICONINFO = extern struct {
    fIcon: BOOL = 0,
    xHotspot: u32 = 0,
    yHotspot: u32 = 0,
    hbmMask: ?HANDLE = null,
    hbmColor: ?HANDLE = null,
};

const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32 = 0,
    /// Negative: rows top-down.
    biHeight: i32 = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

const BITMAPINFO = extern struct {
    header: BITMAPINFOHEADER = .{},
    colors: [4]u32 = @splat(0),
};

extern "user32" fn PrivateExtractIconsW(file: [*:0]const u16, index: c_int, cx: c_int, cy: c_int, icons: ?[*]?HANDLE, ids: ?[*]u32, n: u32, flags: u32) callconv(.winapi) u32;
extern "user32" fn GetIconInfo(icon: HANDLE, info: *ICONINFO) callconv(.winapi) BOOL;
extern "user32" fn DestroyIcon(icon: HANDLE) callconv(.winapi) BOOL;
extern "user32" fn GetDC(wnd: ?HANDLE) callconv(.winapi) ?HANDLE;
extern "user32" fn ReleaseDC(wnd: ?HANDLE, dc: HANDLE) callconv(.winapi) c_int;
extern "gdi32" fn GetDIBits(dc: HANDLE, bm: HANDLE, start: u32, lines: u32, bits: ?*anyopaque, bmi: *BITMAPINFO, usage: u32) callconv(.winapi) c_int;
extern "gdi32" fn DeleteObject(obj: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetTempPathW(n: u32, buf: [*]u16) callconv(.winapi) u32;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;

fn expectPng(png: []const u8, size: u32) !void {
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png[0..8]);
    try std.testing.expectEqualSlices(u8, "IHDR", png[12..16]);
    try std.testing.expectEqual(size, std.mem.readInt(u32, png[16..20], .big));
    try std.testing.expectEqual(size, std.mem.readInt(u32, png[20..24], .big));
}

test "encodePng" {
    const gpa = std.testing.allocator;
    const rgba: [2 * 2 * 4]u8 = .{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 0, 0, 0, 0 };
    const png = try encodePng(gpa, &rgba, 2, 2);
    defer gpa.free(png);
    try expectPng(png, 2);
    try std.testing.expectEqualSlices(u8, "IEND", png[png.len - 8 ..][0..4]);
    // A picture past one stored block (65535 bytes) still ends right.
    const big = try gpa.alloc(u8, 200 * 200 * 4);
    defer gpa.free(big);
    @memset(big, 0x7f);
    const big_png = try encodePng(gpa, big, 200, 200);
    defer gpa.free(big_png);
    try expectPng(big_png, 200);
}

test "exePng" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "C:\\Windows\\explorer.exe", "C:\\Windows\\System32\\notepad.exe" }) |p| {
        const png = exePng(gpa, p, 32) orelse return error.NoIcon;
        defer gpa.free(png);
        try expectPng(png, 32);
        std.debug.print("{s}: {d}-byte 32 px PNG\n", .{ p, png.len });
    }
    const small = exePng(gpa, "C:\\Windows\\explorer.exe", 16) orelse return error.NoIcon;
    defer gpa.free(small);
    try expectPng(small, 16);
    if (exePng(gpa, "C:\\Windows\\System32\\svchost.exe", 32)) |png| {
        defer gpa.free(png);
        std.debug.print("svchost.exe: an icon, {d} bytes\n", .{png.len});
    } else std.debug.print("svchost.exe: no icon\n", .{});
    try std.testing.expect(exePng(gpa, "C:\\no\\such\\program.exe", 32) == null);

    // One to look at.
    const png = exePng(gpa, "C:\\Windows\\explorer.exe", 32).?;
    defer gpa.free(png);
    var dir: [260]u16 = undefined;
    const n = GetTempPathW(dir.len, &dir);
    const name = std.unicode.wtf8ToWtf16LeStringLiteral("mymonitor-icon-test.png");
    var path: [300:0]u16 = undefined;
    @memcpy(path[0..n], dir[0..n]);
    @memcpy(path[n..][0..name.len], name);
    path[n + name.len] = 0;
    const h = CreateFileW(&path, 0x40000000, 0, null, 2, 0x80, null);
    try std.testing.expect(h != null and h != @as(?HANDLE, @ptrFromInt(std.math.maxInt(usize))));
    defer _ = CloseHandle(h.?);
    var wrote: u32 = 0;
    try std.testing.expect(WriteFile(h.?, png.ptr, @intCast(png.len), &wrote, null) != 0 and wrote == png.len);
    var shown: [600]u8 = undefined;
    std.debug.print("wrote {s}\n", .{shown[0..std.unicode.wtf16LeToWtf8(&shown, path[0 .. n + name.len])]});
}
