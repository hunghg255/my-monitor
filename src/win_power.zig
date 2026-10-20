//! The battery and the power source: what Windows says of the power line
//! and the charge, then the first battery's own details from its driver
//! (capacities, cycles, chemistry, voltage, rate); and the power plan.
const std = @import("std");

const HANDLE = *anyopaque;
const BOOL = c_int;

pub const Battery = struct {
    present: bool = false,
    percent: f32 = 0,
    on_ac: bool = false,
    charging: bool = false,
    /// Seconds of battery left when discharging; null when unknown or on AC.
    seconds_left: ?u32 = null,
    /// mW: positive charging, negative discharging, 0 idle/unknown.
    rate_mw: i32 = 0,
    voltage_mv: u32 = 0,
    design_mwh: u32 = 0,
    full_mwh: u32 = 0,
    now_mwh: u32 = 0,
    cycles: u32 = 0,
    chemistry: [4]u8 = @splat(0),

    /// full / design, percent (0 when unknown).
    pub fn health(b: Battery) f32 {
        if (b.design_mwh == 0) return 0;
        return @as(f32, @floatFromInt(b.full_mwh)) * 100 / @as(f32, @floatFromInt(b.design_mwh));
    }
};

pub fn read(out: *Battery) void {
    out.* = .{};
    var s: SYSTEM_POWER_STATUS = .{};
    if (GetSystemPowerStatus(&s) != 0) {
        out.on_ac = s.ACLineStatus == 1;
        out.present = s.BatteryFlag & 0x80 == 0 and s.BatteryFlag != 0xff;
        out.charging = s.BatteryFlag != 0xff and s.BatteryFlag & 0x8 != 0;
        if (s.BatteryLifePercent <= 100) out.percent = @floatFromInt(s.BatteryLifePercent);
        if (!out.on_ac and s.BatteryLifeTime != 0xffff_ffff) out.seconds_left = s.BatteryLifeTime;
    }
    details(out);
}

/// The first battery's details, from its driver.
fn details(out: *Battery) void {
    const set = SetupDiGetClassDevsW(&GUID_DEVCLASS_BATTERY, null, null, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (set == INVALID_HANDLE) return;
    defer _ = SetupDiDestroyDeviceInfoList(set.?);
    var i: u32 = 0;
    var iface: SP_DEVICE_INTERFACE_DATA = .{};
    while (SetupDiEnumDeviceInterfaces(set.?, null, &GUID_DEVCLASS_BATTERY, i, &iface) != 0) : (i += 1) {
        // SP_DEVICE_INTERFACE_DETAIL_DATA_W: its size, then the path.
        var detail: [512]u16 align(8) = undefined;
        @as(*u32, @ptrCast(&detail)).* = if (@sizeOf(usize) == 8) 8 else 6;
        if (SetupDiGetDeviceInterfaceDetailW(set.?, &iface, &detail, @sizeOf(@TypeOf(detail)), null, null) == 0) continue;
        const path: [*:0]const u16 = @ptrCast(detail[2..]);
        const h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
        if (h == INVALID_HANDLE) continue;
        defer _ = CloseHandle(h.?);
        if (battery(h.?, out)) return;
    }
}

fn battery(h: HANDLE, out: *Battery) bool {
    var wait: u32 = 0;
    var tag: u32 = 0;
    var got: u32 = 0;
    if (DeviceIoControl(h, IOCTL_BATTERY_QUERY_TAG, &wait, @sizeOf(u32), &tag, @sizeOf(u32), &got, null) == 0 or tag == 0) return false;
    var q: BATTERY_QUERY_INFORMATION = .{ .BatteryTag = tag };
    var info: BATTERY_INFORMATION = .{};
    if (DeviceIoControl(h, IOCTL_BATTERY_QUERY_INFORMATION, &q, @sizeOf(BATTERY_QUERY_INFORMATION), &info, @sizeOf(BATTERY_INFORMATION), &got, null) == 0) return false;
    out.present = true;
    out.chemistry = info.Chemistry;
    out.cycles = info.CycleCount;
    // Capacities in percent rather than mWh say nothing of health.
    const relative = info.Capabilities & BATTERY_CAPACITY_RELATIVE != 0;
    if (!relative) {
        out.design_mwh = info.DesignedCapacity;
        out.full_mwh = info.FullChargedCapacity;
    }
    var w: BATTERY_WAIT_STATUS = .{ .BatteryTag = tag };
    var st: BATTERY_STATUS = .{};
    if (DeviceIoControl(h, IOCTL_BATTERY_QUERY_STATUS, &w, @sizeOf(BATTERY_WAIT_STATUS), &st, @sizeOf(BATTERY_STATUS), &got, null) == 0) return true;
    if (st.PowerState & BATTERY_POWER_ON_LINE != 0) out.on_ac = true;
    if (st.PowerState & BATTERY_CHARGING != 0) out.charging = true;
    if (!relative and st.Capacity != BATTERY_UNKNOWN) out.now_mwh = st.Capacity;
    if (st.Voltage != BATTERY_UNKNOWN) out.voltage_mv = st.Voltage;
    if (st.Rate != BATTERY_UNKNOWN_RATE) out.rate_mw = st.Rate;
    return true;
}

/// The active power plan's name ("Balanced"), or "" when unknown.
pub fn planName(buf: []u8) []const u8 {
    var scheme: ?*GUID = null;
    if (PowerGetActiveScheme(null, &scheme) != 0) return "";
    defer _ = LocalFree(scheme.?);
    var w: [64]u16 = undefined;
    var size: u32 = @sizeOf(@TypeOf(w));
    if (PowerReadFriendlyName(null, scheme.?, null, null, @ptrCast(&w), &size) != 0) return "";
    var all: [64 * 3]u8 = undefined;
    const name = all[0..std.unicode.wtf16LeToWtf8(&all, std.mem.sliceTo(w[0 .. size / 2], 0))];
    const n = @min(buf.len, name.len);
    @memcpy(buf[0..n], name[0..n]);
    return buf[0..n];
}

const INVALID_HANDLE: ?HANDLE = @ptrFromInt(std.math.maxInt(usize));
const DIGCF_PRESENT = 0x2;
const DIGCF_DEVICEINTERFACE = 0x10;
const GENERIC_READ = 0x80000000;
const GENERIC_WRITE = 0x40000000;
const FILE_SHARE_READ = 0x1;
const FILE_SHARE_WRITE = 0x2;
const OPEN_EXISTING = 3;
const IOCTL_BATTERY_QUERY_TAG = 0x294040;
const IOCTL_BATTERY_QUERY_INFORMATION = 0x294044;
const IOCTL_BATTERY_QUERY_STATUS = 0x29404C;
const BATTERY_CAPACITY_RELATIVE = 0x40000000;
const BATTERY_POWER_ON_LINE = 0x1;
const BATTERY_CHARGING = 0x4;
const BATTERY_UNKNOWN = 0xffff_ffff;
const BATTERY_UNKNOWN_RATE: i32 = std.math.minInt(i32);

const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const GUID_DEVCLASS_BATTERY: GUID = .{ .a = 0x72631e54, .b = 0x78a4, .c = 0x11d0, .d = .{ 0xbc, 0xf7, 0x00, 0xaa, 0x00, 0xb7, 0xb3, 0x2a } };

const SYSTEM_POWER_STATUS = extern struct {
    ACLineStatus: u8 = 0,
    /// Charging (8), no battery (128), unknown (255), …
    BatteryFlag: u8 = 0,
    BatteryLifePercent: u8 = 0,
    SystemStatusFlag: u8 = 0,
    BatteryLifeTime: u32 = 0,
    BatteryFullLifeTime: u32 = 0,
};

const SP_DEVICE_INTERFACE_DATA = extern struct {
    cbSize: u32 = @sizeOf(SP_DEVICE_INTERFACE_DATA),
    InterfaceClassGuid: GUID = undefined,
    Flags: u32 = 0,
    Reserved: usize = 0,
};

const BATTERY_QUERY_INFORMATION = extern struct {
    BatteryTag: u32,
    /// BatteryInformation (0).
    InformationLevel: u32 = 0,
    AtRate: i32 = 0,
};

const BATTERY_INFORMATION = extern struct {
    Capabilities: u32 = 0,
    Technology: u8 = 0,
    Reserved: [3]u8 = @splat(0),
    Chemistry: [4]u8 = @splat(0),
    DesignedCapacity: u32 = 0,
    FullChargedCapacity: u32 = 0,
    DefaultAlert1: u32 = 0,
    DefaultAlert2: u32 = 0,
    CriticalBias: u32 = 0,
    CycleCount: u32 = 0,
};

const BATTERY_WAIT_STATUS = extern struct {
    BatteryTag: u32,
    Timeout: u32 = 0,
    PowerState: u32 = 0,
    LowCapacity: u32 = 0,
    HighCapacity: u32 = 0,
};

const BATTERY_STATUS = extern struct {
    PowerState: u32 = 0,
    Capacity: u32 = 0,
    Voltage: u32 = 0,
    Rate: i32 = 0,
};

extern "kernel32" fn GetSystemPowerStatus(s: *SYSTEM_POWER_STATUS) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) ?HANDLE;
extern "kernel32" fn DeviceIoControl(h: HANDLE, code: u32, in: ?*anyopaque, in_size: u32, out: ?*anyopaque, out_size: u32, got: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn LocalFree(p: *anyopaque) callconv(.winapi) ?*anyopaque;
extern "setupapi" fn SetupDiGetClassDevsW(class: ?*const GUID, enumerator: ?[*:0]const u16, parent: ?HANDLE, flags: u32) callconv(.winapi) ?HANDLE;
extern "setupapi" fn SetupDiEnumDeviceInterfaces(set: HANDLE, dev: ?*anyopaque, class: *const GUID, i: u32, iface: *SP_DEVICE_INTERFACE_DATA) callconv(.winapi) BOOL;
extern "setupapi" fn SetupDiGetDeviceInterfaceDetailW(set: HANDLE, iface: *SP_DEVICE_INTERFACE_DATA, detail: *anyopaque, size: u32, need: ?*u32, dev: ?*anyopaque) callconv(.winapi) BOOL;
extern "setupapi" fn SetupDiDestroyDeviceInfoList(set: HANDLE) callconv(.winapi) BOOL;
extern "powrprof" fn PowerGetActiveScheme(root: ?HANDLE, scheme: *?*GUID) callconv(.winapi) u32;
extern "powrprof" fn PowerReadFriendlyName(root: ?HANDLE, scheme: *const GUID, group: ?*const GUID, setting: ?*const GUID, buf: ?[*]u8, size: *u32) callconv(.winapi) u32;

test "the battery, as read on this machine" {
    var b: Battery = .{};
    read(&b);
    var buf: [64]u8 = undefined;
    std.debug.print("\nbattery: present {}, {d:.0}%, on AC {}, charging {}, left {?d} s\n", .{ b.present, b.percent, b.on_ac, b.charging, b.seconds_left });
    std.debug.print("rate {d} mW, {d} mV, now {d} / full {d} / design {d} mWh, health {d:.1}%, {d} cycles, chemistry \"{s}\"\n", .{ b.rate_mw, b.voltage_mv, b.now_mwh, b.full_mwh, b.design_mwh, b.health(), b.cycles, std.mem.sliceTo(&b.chemistry, 0) });
    std.debug.print("power plan: \"{s}\"\n", .{planName(&buf)});
    try std.testing.expect(b.percent >= 0 and b.percent <= 100);
    if (b.present) try std.testing.expect(b.full_mwh <= b.design_mwh * 2);
    if (b.on_ac) try std.testing.expect(b.seconds_left == null);
}
