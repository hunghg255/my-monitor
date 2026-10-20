//! The GPU as Task Manager shows it: each engine's busy percent from the
//! performance counters (summed over processes; the busiest engine type
//! counts), the adapters' memory in use, and the primary adapter's name
//! and memory size (registry).
const std = @import("std");

const HANDLE = *anyopaque;
const BOOL = c_int;

pub const Engines = struct { three_d: f32 = 0, copy: f32 = 0, video_decode: f32 = 0, video_processing: f32 = 0, compute: f32 = 0 };

pub const Gpu = struct {
    name: [128]u8 = undefined,
    name_len: usize = 0,
    /// Percent busy: the busiest engine type, summed over processes, as Task Manager.
    util: f32 = 0,
    engines: Engines = .{},
    dedicated_used: u64 = 0,
    shared_used: u64 = 0,
    dedicated_total: u64 = 0,

    pub fn nameSlice(g: *const Gpu) []const u8 {
        return g.name[0..g.name_len];
    }
};

/// Engine types as the counters name them ("Compute_1" is "Compute");
/// any other type counts in the last slot.
const types = [_][]const u8{ "3D", "Copy", "VideoDecode", "VideoProcessing", "Compute", "VideoEncode" };
const Sums = [types.len + 1]f32;

pub const Reader = struct {
    gpa: std.mem.Allocator,
    query: ?HANDLE = null,
    engine: ?HANDLE = null,
    dedicated: ?HANDLE = null,
    shared: ?HANDLE = null,
    /// Each process's engine types at the last sample.
    procs: std.AutoHashMapUnmanaged(u32, Sums) = .empty,
    /// Where the counters' values land.
    buf: []align(8) u8 = &.{},
    name: [128]u8 = undefined,
    name_len: usize = 0,
    total: u64 = 0,

    /// Never fails: unavailable counters read as zero.
    pub fn init(gpa: std.mem.Allocator) Reader {
        var r: Reader = .{ .gpa = gpa };
        var q: ?HANDLE = null;
        if (PdhOpenQueryW(null, 0, &q) == 0) {
            r.query = q;
            r.engine = counter(q.?, std.unicode.utf8ToUtf16LeStringLiteral("\\GPU Engine(*)\\Utilization Percentage"));
            r.dedicated = counter(q.?, std.unicode.utf8ToUtf16LeStringLiteral("\\GPU Adapter Memory(*)\\Dedicated Usage"));
            r.shared = counter(q.?, std.unicode.utf8ToUtf16LeStringLiteral("\\GPU Adapter Memory(*)\\Shared Usage"));
            // Rates need two collections: the first is here.
            _ = PdhCollectQueryData(q.?);
        }
        r.adapter();
        return r;
    }

    pub fn deinit(r: *Reader) void {
        if (r.query) |q| _ = PdhCloseQuery(q);
        r.procs.deinit(r.gpa);
        r.gpa.free(r.buf);
    }

    /// Collects the counters (call once each sample, ~every 1-2 s) and fills `out`.
    pub fn sample(r: *Reader, out: *Gpu) void {
        out.* = .{ .name_len = r.name_len, .dedicated_total = r.total };
        @memcpy(out.name[0..r.name_len], r.name[0..r.name_len]);
        r.procs.clearRetainingCapacity();
        const q = r.query orelse return;
        if (PdhCollectQueryData(q) != 0) return;

        // Each adapter's engine types, summed over processes.
        var keys: [8]u64 = undefined;
        var adapters: [8]Sums = undefined;
        var n: usize = 0;
        for (r.items(r.engine, PDH_FMT_DOUBLE)) |it| {
            if (it.CStatus > PDH_CSTATUS_NEW_DATA) continue;
            var a: [128]u8 = undefined;
            const name = ascii(&a, std.mem.sliceTo(it.szName, 0));
            const at = std.mem.indexOf(u8, name, "luid_") orelse continue;
            const end = std.mem.indexOf(u8, name, "_eng_") orelse continue;
            const key = std.hash.Wyhash.hash(0, name[at..end]);
            const t = kind(field(name, "engtype_") orelse continue);
            const v: f32 = @floatCast(it.value.double);
            const i = std.mem.indexOfScalar(u64, keys[0..n], key) orelse blk: {
                if (n == keys.len) continue;
                keys[n] = key;
                adapters[n] = @splat(0);
                n += 1;
                break :blk n - 1;
            };
            adapters[i][t] += v;
            const pid = std.fmt.parseInt(u32, field(name, "pid_") orelse continue, 10) catch continue;
            const p = r.procs.getOrPut(r.gpa, pid) catch continue;
            if (!p.found_existing) p.value_ptr.* = @splat(0);
            p.value_ptr[t] += v;
        }
        for (adapters[0..n]) |s| {
            out.util = @max(out.util, busiest(s));
            const e = &out.engines;
            e.three_d = @max(e.three_d, @min(s[0], 100));
            e.copy = @max(e.copy, @min(s[1], 100));
            e.video_decode = @max(e.video_decode, @min(s[2], 100));
            e.video_processing = @max(e.video_processing, @min(s[3], 100));
            e.compute = @max(e.compute, @min(s[4], 100));
        }
        out.dedicated_used = r.bytes(r.dedicated);
        out.shared_used = r.bytes(r.shared);
    }

    /// The GPU percent of process `pid` at the last sample (sum over its engines of the busiest engine type, as Task Manager's GPU column); 0 if none.
    pub fn processPercent(r: *const Reader, pid: u32) f32 {
        return busiest(r.procs.get(pid) orelse return 0);
    }

    /// Bytes in use, over every adapter.
    fn bytes(r: *Reader, c: ?HANDLE) u64 {
        var sum: u64 = 0;
        for (r.items(c, PDH_FMT_LARGE)) |it| {
            if (it.CStatus <= PDH_CSTATUS_NEW_DATA and it.value.large > 0) sum += @intCast(it.value.large);
        }
        return sum;
    }

    /// Each instance of counter `c` at the last collection.
    fn items(r: *Reader, c: ?HANDLE, format: u32) []const Item {
        const h = c orelse return &.{};
        var size: u32 = 0;
        var n: u32 = 0;
        if (PdhGetFormattedCounterArrayW(h, format, &size, &n, null) != PDH_MORE_DATA) return &.{};
        if (size > r.buf.len) {
            r.gpa.free(r.buf);
            r.buf = r.gpa.alignedAlloc(u8, .@"8", size) catch {
                r.buf = &.{};
                return &.{};
            };
        }
        if (PdhGetFormattedCounterArrayW(h, format, &size, &n, @ptrCast(r.buf.ptr)) != 0) return &.{};
        const all: [*]const Item = @ptrCast(r.buf.ptr);
        return all[0..n];
    }

    /// The primary display adapter's name, and its memory from its video key.
    fn adapter(r: *Reader) void {
        var d: DISPLAY_DEVICEW = .{};
        var i: u32 = 0;
        while (EnumDisplayDevicesW(null, i, &d, 0) != 0) : (i += 1) {
            if (d.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE != 0) break;
        } else return;
        var all: [128 * 3]u8 = undefined;
        const name = all[0..std.unicode.wtf16LeToWtf8(&all, std.mem.sliceTo(&d.DeviceString, 0))];
        r.name_len = @min(name.len, r.name.len);
        @memcpy(r.name[0..r.name_len], name[0..r.name_len]);
        // "\Registry\Machine\System\...\Video\{guid}\0000", under HKLM.
        const prefix = "\\Registry\\Machine\\";
        const key = std.mem.sliceTo(&d.DeviceKey, 0);
        if (key.len <= prefix.len) return;
        var sub: [128:0]u16 = undefined;
        const rest = key[prefix.len..];
        @memcpy(sub[0..rest.len], rest);
        sub[rest.len] = 0;
        for ([_][*:0]const u16{
            std.unicode.utf8ToUtf16LeStringLiteral("HardwareInformation.qwMemorySize"),
            std.unicode.utf8ToUtf16LeStringLiteral("HardwareInformation.MemorySize"),
        }) |value| {
            var size: u64 = 0;
            var len: u32 = @sizeOf(u64);
            if (RegGetValueW(HKEY_LOCAL_MACHINE, &sub, value, RRF_RT_ANY, null, &size, &len) == 0 and size > 0) {
                r.total = size;
                return;
            }
        }
    }
};

fn counter(q: HANDLE, path: [*:0]const u16) ?HANDLE {
    var c: ?HANDLE = null;
    return if (PdhAddEnglishCounterW(q, path, 0, &c) == 0) c else null;
}

/// The busiest engine type, as a percent.
fn busiest(s: Sums) f32 {
    var m: f32 = 0;
    for (s) |v| m = @max(m, v);
    return std.math.clamp(m, 0, 100);
}

fn kind(t: []const u8) usize {
    for (types, 0..) |name, i| if (std.mem.eql(u8, name, t)) return i;
    return types.len;
}

/// The text after `tag`, up to the next '_'.
fn field(name: []const u8, tag: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, name, tag) orelse return null;
    const rest = name[at + tag.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '_') orelse rest.len];
}

/// Instance names are ASCII ("pid_1234_luid_0x…_phys_0_eng_3_engtype_3D").
fn ascii(buf: []u8, w: []const u16) []const u8 {
    const n = @min(buf.len, w.len);
    for (buf[0..n], w[0..n]) |*c, u| c.* = if (u < 128) @intCast(u) else '?';
    return buf[0..n];
}

const PDH_FMT_DOUBLE = 0x200;
const PDH_FMT_LARGE = 0x400;
const PDH_MORE_DATA = 0x800007D2;
const PDH_CSTATUS_NEW_DATA = 1;
const DISPLAY_DEVICE_PRIMARY_DEVICE = 0x4;
const HKEY_LOCAL_MACHINE: *anyopaque = @ptrFromInt(0x80000002);
const RRF_RT_ANY = 0xffff;

const Item = extern struct {
    szName: [*:0]const u16,
    CStatus: u32,
    value: extern union { long: i32, double: f64, large: i64 },
};

const DISPLAY_DEVICEW = extern struct {
    cb: u32 = @sizeOf(DISPLAY_DEVICEW),
    DeviceName: [32]u16 = @splat(0),
    DeviceString: [128]u16 = @splat(0),
    StateFlags: u32 = 0,
    DeviceID: [128]u16 = @splat(0),
    DeviceKey: [128]u16 = @splat(0),
};

extern "pdh" fn PdhOpenQueryW(source: ?[*:0]const u16, user: usize, q: *?HANDLE) callconv(.winapi) u32;
extern "pdh" fn PdhAddEnglishCounterW(q: HANDLE, path: [*:0]const u16, user: usize, c: *?HANDLE) callconv(.winapi) u32;
extern "pdh" fn PdhCollectQueryData(q: HANDLE) callconv(.winapi) u32;
extern "pdh" fn PdhGetFormattedCounterArrayW(c: HANDLE, format: u32, size: *u32, n: *u32, items: ?*Item) callconv(.winapi) u32;
extern "pdh" fn PdhCloseQuery(q: HANDLE) callconv(.winapi) u32;
extern "user32" fn EnumDisplayDevicesW(device: ?[*:0]const u16, i: u32, d: *DISPLAY_DEVICEW, flags: u32) callconv(.winapi) BOOL;
extern "advapi32" fn RegGetValueW(key: *anyopaque, sub: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: *anyopaque, size: *u32) callconv(.winapi) i32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

test "the GPU, as read on this machine" {
    var r = Reader.init(std.testing.allocator);
    defer r.deinit();
    var g: Gpu = .{};
    r.sample(&g);
    Sleep(1000);
    r.sample(&g);
    const e = g.engines;
    std.debug.print("\nGPU {s}: {d:.1}% (3D {d:.1}, copy {d:.1}, decode {d:.1}, processing {d:.1}, compute {d:.1})\n", .{ g.nameSlice(), g.util, e.three_d, e.copy, e.video_decode, e.video_processing, e.compute });
    std.debug.print("memory: dedicated {d} MB of {d} MB, shared {d} MB\n", .{ g.dedicated_used >> 20, g.dedicated_total >> 20, g.shared_used >> 20 });
    var top: [3]struct { pid: u32, pct: f32 } = @splat(.{ .pid = 0, .pct = -1 });
    var it = r.procs.keyIterator();
    while (it.next()) |pid| {
        const pct = r.processPercent(pid.*);
        for (&top, 0..) |*t, i| if (pct > t.pct) {
            std.mem.copyBackwards(@TypeOf(t.*), top[i + 1 ..], top[i .. top.len - 1]);
            t.* = .{ .pid = pid.*, .pct = pct };
            break;
        };
    }
    for (top) |t| if (t.pct >= 0) std.debug.print("pid {d}: {d:.1}%\n", .{ t.pid, t.pct });
    try std.testing.expect(g.util >= 0 and g.util <= 100);
    try std.testing.expect(g.name_len > 0);
    try std.testing.expect(r.procs.count() > 0);
    try std.testing.expectEqual(@as(f32, 0), r.processPercent(0xffff_fff0));
}
