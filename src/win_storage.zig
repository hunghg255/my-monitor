//! The volumes on Windows, as File Explorer's "This PC" shows them: each
//! fixed or removable drive's letter, label, file system and space. Drives
//! with no media in them (an empty card reader, a CD drive) stay out.
const std = @import("std");

const BOOL = c_int;

pub const Volume = struct {
    letter: u8 = 'C',
    /// "Local Disk" when it has none.
    label: [64]u8 = undefined,
    label_len: usize = 0,
    /// "NTFS".
    fs: [16]u8 = undefined,
    fs_len: usize = 0,
    total: u64 = 0,
    free: u64 = 0,
    removable: bool = false,

    pub fn labelSlice(v: *const Volume) []const u8 {
        return v.label[0..v.label_len];
    }
    pub fn fsSlice(v: *const Volume) []const u8 {
        return v.fs[0..v.fs_len];
    }
    pub fn used(v: Volume) u64 {
        return v.total -| v.free;
    }
    /// What Explorer calls it: "Local Disk (C:)".
    pub fn name(v: *const Volume, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s} ({c}:)", .{ v.labelSlice(), v.letter }) catch v.labelSlice();
    }
};

/// Fills `out` with the volumes, by letter; how many.
pub fn list(out: []Volume) usize {
    // Error mode: no "insert a disk" box for an empty drive.
    const was = SetErrorMode(SEM_FAILCRITICALERRORS);
    defer _ = SetErrorMode(was);
    const drives = GetLogicalDrives();
    var n: usize = 0;
    for (0..26) |bit| {
        if (n == out.len) break;
        if (drives & (@as(u32, 1) << @intCast(bit)) == 0) continue;
        const letter: u8 = 'A' + @as(u8, @intCast(bit));
        const root = [_:0]u16{ letter, ':', '\\' };
        const kind = GetDriveTypeW(&root);
        if (kind != DRIVE_FIXED and kind != DRIVE_REMOVABLE) continue;
        var label: [MAX_PATH + 1]u16 = undefined;
        var fs: [MAX_PATH + 1]u16 = undefined;
        if (GetVolumeInformationW(&root, &label, label.len, null, null, null, &fs, fs.len) == 0) continue;
        const v = &out[n];
        v.* = .{ .letter = letter, .removable = kind == DRIVE_REMOVABLE };
        if (GetDiskFreeSpaceExW(&root, null, &v.total, &v.free) == 0) continue;
        v.label_len = keep(&v.label, std.mem.sliceTo(&label, 0));
        if (v.label_len == 0) {
            const none = if (v.removable) "USB Drive" else "Local Disk";
            @memcpy(v.label[0..none.len], none);
            v.label_len = none.len;
        }
        v.fs_len = keep(&v.fs, std.mem.sliceTo(&fs, 0));
        n += 1;
    }
    return n;
}

/// Copies UTF-16 `w` into `dst` as UTF-8, cut at a whole character; the length.
fn keep(dst: []u8, w: []const u16) usize {
    var all: [(MAX_PATH + 1) * 3]u8 = undefined;
    const len = std.unicode.wtf16LeToWtf8(&all, w[0..@min(w.len, MAX_PATH + 1)]);
    var n = @min(dst.len, len);
    if (n < len) while (n > 0 and all[n] & 0xc0 == 0x80) : (n -= 1) {};
    @memcpy(dst[0..n], all[0..n]);
    return n;
}

const MAX_PATH = 260;
const DRIVE_REMOVABLE = 2;
const DRIVE_FIXED = 3;
const SEM_FAILCRITICALERRORS = 0x1;

extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;
extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetVolumeInformationW(root: [*:0]const u16, label: [*]u16, label_len: u32, serial: ?*u32, max_component: ?*u32, flags: ?*u32, fs: [*]u16, fs_len: u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetDiskFreeSpaceExW(root: [*:0]const u16, avail: ?*u64, total: *u64, free: *u64) callconv(.winapi) BOOL;
extern "kernel32" fn SetErrorMode(mode: u32) callconv(.winapi) u32;

test list {
    var vols: [26]Volume = undefined;
    const n = list(&vols);
    try std.testing.expect(n > 0);
    var system = false;
    for (vols[0..n]) |*v| {
        var buf: [80]u8 = undefined;
        std.debug.print("{s:<24} {s:<6} {d:>8.1} GB total {d:>8.1} GB free {d:>8.1} GB used{s}\n", .{
            v.name(&buf), v.fsSlice(), gb(v.total), gb(v.free), gb(v.used()), if (v.removable) " removable" else "",
        });
        try std.testing.expect(v.total > 0 and v.free <= v.total);
        try std.testing.expect(v.fs_len > 0);
        if (v.letter == 'C') system = true;
    }
    try std.testing.expect(system);
}

fn gb(b: u64) f64 {
    return @as(f64, @floatFromInt(b)) / 1e9;
}
