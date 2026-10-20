//! What the PC is, on Windows: its maker and model (the BIOS's registry
//! key), its chip and architecture, which Windows and build, its name and
//! user's, when it started, its memory, and each display's size, refresh
//! rate and scale.
const std = @import("std");

const HANDLE = *anyopaque;
const BOOL = c_int;

pub const Display = struct { width: u32 = 0, height: u32 = 0, hz: u32 = 0, scale: u32 = 100, primary: bool = false };

pub const Machine = struct {
    /// "Dell Inc.", "Latitude 5520".
    vendor: [64]u8 = undefined,
    vendor_len: usize = 0,
    model: [64]u8 = undefined,
    model_len: usize = 0,
    /// "11th Gen Intel(R) Core(TM) i7-1185G7 @ 3.00GHz".
    chip: [128]u8 = undefined,
    chip_len: usize = 0,
    /// "amd64", "arm64", "x86".
    arch: [8]u8 = undefined,
    arch_len: usize = 0,
    /// "Windows 11 Pro": the registry's name, put right for Windows 11.
    product: [64]u8 = undefined,
    product_len: usize = 0,
    /// "22H2".
    display_version: [16]u8 = undefined,
    display_version_len: usize = 0,
    host: [64]u8 = undefined,
    host_len: usize = 0,
    user: [64]u8 = undefined,
    user_len: usize = 0,
    major: u32 = 0,
    minor: u32 = 0,
    build: u32 = 0,
    /// The update build revision: 19045.4291's 4291.
    ubr: u32 = 0,
    boot_unix: i64 = 0,
    /// Bytes of RAM installed.
    memory: u64 = 0,
    displays: [8]Display = @splat(.{}),
    n_displays: usize = 0,

    pub fn vendorSlice(m: *const Machine) []const u8 {
        return m.vendor[0..m.vendor_len];
    }
    pub fn modelSlice(m: *const Machine) []const u8 {
        return m.model[0..m.model_len];
    }
    pub fn chipSlice(m: *const Machine) []const u8 {
        return m.chip[0..m.chip_len];
    }
    pub fn archSlice(m: *const Machine) []const u8 {
        return m.arch[0..m.arch_len];
    }
    pub fn productSlice(m: *const Machine) []const u8 {
        return m.product[0..m.product_len];
    }
    pub fn displayVersionSlice(m: *const Machine) []const u8 {
        return m.display_version[0..m.display_version_len];
    }
    pub fn hostSlice(m: *const Machine) []const u8 {
        return m.host[0..m.host_len];
    }
    pub fn userSlice(m: *const Machine) []const u8 {
        return m.user[0..m.user_len];
    }
};

/// Fills `m` with what the PC is (fields it cannot learn stay empty).
pub fn read(m: *Machine) void {
    m.* = .{};
    const bios = L("HARDWARE\\DESCRIPTION\\System\\BIOS");
    m.vendor_len = text(&m.vendor, bios, L("SystemManufacturer"));
    m.model_len = text(&m.model, bios, L("SystemProductName"));
    m.chip_len = text(&m.chip, L("HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0"), L("ProcessorNameString"));

    var si: SYSTEM_INFO = undefined;
    GetNativeSystemInfo(&si);
    const arch: []const u8 = switch (si.wProcessorArchitecture) {
        PROCESSOR_ARCHITECTURE_AMD64 => "amd64",
        PROCESSOR_ARCHITECTURE_ARM64 => "arm64",
        PROCESSOR_ARCHITECTURE_INTEL => "x86",
        PROCESSOR_ARCHITECTURE_ARM => "arm",
        else => "unknown",
    };
    @memcpy(m.arch[0..arch.len], arch);
    m.arch_len = arch.len;

    var v: OSVERSIONINFOW = .{};
    if (RtlGetVersion(&v) == 0) {
        m.major = v.dwMajorVersion;
        m.minor = v.dwMinorVersion;
        m.build = v.dwBuildNumber;
    }
    const nt = L("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion");
    m.product_len = text(&m.product, nt, L("ProductName"));
    // Windows 11 still says 10; its builds start at 22000.
    if (m.build >= 22000 and std.mem.startsWith(u8, m.productSlice(), "Windows 10")) m.product[9] = '1';
    m.display_version_len = text(&m.display_version, nt, L("DisplayVersion"));
    if (m.display_version_len == 0) m.display_version_len = text(&m.display_version, nt, L("ReleaseId"));
    var size: u32 = @sizeOf(u32);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, nt, L("UBR"), RRF_RT_REG_DWORD, null, &m.ubr, &size) != 0) m.ubr = 0;

    var w: [64]u16 = undefined;
    var n: u32 = w.len;
    if (GetComputerNameExW(ComputerNameDnsHostname, &w, &n) != 0) m.host_len = keep(&m.host, w[0..n]);
    n = w.len;
    if (GetUserNameW(&w, &n) != 0 and n > 1) m.user_len = keep(&m.user, w[0 .. n - 1]);

    // FILETIME counts 100 ns from 1601; Unix time starts 11644473600 s later.
    var ft: u64 = 0;
    GetSystemTimeAsFileTime(&ft);
    m.boot_unix = @as(i64, @intCast(ft / 10_000_000)) - 11_644_473_600 - @as(i64, @intCast(GetTickCount64() / 1000));

    var kb: u64 = 0;
    if (GetPhysicallyInstalledSystemMemory(&kb) != 0) m.memory = kb * 1024 else {
        var ms: MEMORYSTATUSEX = .{};
        if (GlobalMemoryStatusEx(&ms) != 0) m.memory = ms.ullTotalPhys;
    }

    // Per-monitor awareness for a moment, so each display tells its own scale.
    const was = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    defer if (was) |c| {
        _ = SetThreadDpiAwarenessContext(c);
    };
    _ = EnumDisplayMonitors(null, null, display, @bitCast(@intFromPtr(m)));
}

fn display(mon: HANDLE, _: ?HANDLE, _: ?*RECT, data: isize) callconv(.winapi) BOOL {
    const m: *Machine = @ptrFromInt(@as(usize, @bitCast(data)));
    if (m.n_displays == m.displays.len) return 0;
    var info: MONITORINFOEXW = .{};
    if (GetMonitorInfoW(mon, &info) == 0) return 1;
    var mode: DEVMODEW = .{};
    if (EnumDisplaySettingsW(@ptrCast(&info.szDevice), ENUM_CURRENT_SETTINGS, &mode) == 0) return 1;
    var dpi_x: u32 = 96;
    var dpi_y: u32 = 96;
    if (GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y) != 0) dpi_x = 96;
    m.displays[m.n_displays] = .{
        .width = mode.dmPelsWidth,
        .height = mode.dmPelsHeight,
        .hz = mode.dmDisplayFrequency,
        .scale = (dpi_x * 100 + 48) / 96,
        .primary = info.dwFlags & MONITORINFOF_PRIMARY != 0,
    };
    m.n_displays += 1;
    return 1;
}

fn L(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// String `value` of HKLM's `key` into `dst`, trimmed; the length (0: none).
fn text(dst: []u8, key: [*:0]const u16, value: [*:0]const u16) usize {
    var w: [256]u16 = undefined;
    var size: u32 = @sizeOf(@TypeOf(w));
    if (RegGetValueW(HKEY_LOCAL_MACHINE, key, value, RRF_RT_REG_SZ, null, &w, &size) != 0 or size < 2) return 0;
    var all: [256 * 3]u8 = undefined;
    const s = std.mem.trim(u8, all[0..std.unicode.wtf16LeToWtf8(&all, std.mem.sliceTo(w[0 .. size / 2], 0))], " ");
    return keepUtf8(dst, s);
}

/// Copies UTF-16 `w` into `dst` as UTF-8, cut at a whole character; the length.
fn keep(dst: []u8, w: []const u16) usize {
    var all: [64 * 3]u8 = undefined;
    return keepUtf8(dst, all[0..std.unicode.wtf16LeToWtf8(&all, w[0..@min(w.len, 64)])]);
}

fn keepUtf8(dst: []u8, s: []const u8) usize {
    var n = @min(dst.len, s.len);
    if (n < s.len) while (n > 0 and s[n] & 0xc0 == 0x80) : (n -= 1) {};
    @memcpy(dst[0..n], s[0..n]);
    return n;
}

const HKEY_LOCAL_MACHINE: *anyopaque = @ptrFromInt(0x80000002);
const RRF_RT_REG_SZ = 0x2;
const RRF_RT_REG_DWORD = 0x10;
const PROCESSOR_ARCHITECTURE_INTEL = 0;
const PROCESSOR_ARCHITECTURE_ARM = 5;
const PROCESSOR_ARCHITECTURE_AMD64 = 9;
const PROCESSOR_ARCHITECTURE_ARM64 = 12;
const ComputerNameDnsHostname = 1;
const ENUM_CURRENT_SETTINGS: u32 = 0xFFFFFFFF;
const MONITORINFOF_PRIMARY = 0x1;
const MDT_EFFECTIVE_DPI = 0;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

/// A moment in the local time zone.
pub const Local = struct { year: u16, month: u16, day: u16, weekday: u16, hour: u16, minute: u16 };

/// Unix seconds `unix` in the local time zone.
pub fn local(unix: i64) Local {
    const ft: u64 = @intCast((unix + 11_644_473_600) * 10_000_000);
    var lt: u64 = 0;
    var st: SYSTEMTIME = .{};
    _ = FileTimeToLocalFileTime(&ft, &lt);
    _ = FileTimeToSystemTime(&lt, &st);
    return .{ .year = st.wYear, .month = st.wMonth, .day = st.wDay, .weekday = st.wDayOfWeek, .hour = st.wHour, .minute = st.wMinute };
}

const SYSTEMTIME = extern struct { wYear: u16 = 0, wMonth: u16 = 0, wDayOfWeek: u16 = 0, wDay: u16 = 0, wHour: u16 = 0, wMinute: u16 = 0, wSecond: u16 = 0, wMilliseconds: u16 = 0 };

const SYSTEM_INFO = extern struct {
    wProcessorArchitecture: u16,
    wReserved: u16,
    dwPageSize: u32,
    lpMinimumApplicationAddress: ?*anyopaque,
    lpMaximumApplicationAddress: ?*anyopaque,
    dwActiveProcessorMask: usize,
    dwNumberOfProcessors: u32,
    dwProcessorType: u32,
    dwAllocationGranularity: u32,
    wProcessorLevel: u16,
    wProcessorRevision: u16,
};

const OSVERSIONINFOW = extern struct {
    dwOSVersionInfoSize: u32 = @sizeOf(OSVERSIONINFOW),
    dwMajorVersion: u32 = 0,
    dwMinorVersion: u32 = 0,
    dwBuildNumber: u32 = 0,
    dwPlatformId: u32 = 0,
    szCSDVersion: [128]u16 = @splat(0),
};

const MEMORYSTATUSEX = extern struct {
    dwLength: u32 = @sizeOf(MEMORYSTATUSEX),
    dwMemoryLoad: u32 = 0,
    ullTotalPhys: u64 = 0,
    ullAvailPhys: u64 = 0,
    ullTotalPageFile: u64 = 0,
    ullAvailPageFile: u64 = 0,
    ullTotalVirtual: u64 = 0,
    ullAvailVirtual: u64 = 0,
    ullAvailExtendedVirtual: u64 = 0,
};

const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

const MONITORINFOEXW = extern struct {
    cbSize: u32 = @sizeOf(MONITORINFOEXW),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: u32 = 0,
    szDevice: [32]u16 = @splat(0),
};

const DEVMODEW = extern struct {
    dmDeviceName: [32]u16 = @splat(0),
    dmSpecVersion: u16 = 0,
    dmDriverVersion: u16 = 0,
    dmSize: u16 = @sizeOf(DEVMODEW),
    dmDriverExtra: u16 = 0,
    dmFields: u32 = 0,
    /// Position and orientation (or a printer's paper).
    dmUnion: [16]u8 = @splat(0),
    dmColor: i16 = 0,
    dmDuplex: i16 = 0,
    dmYResolution: i16 = 0,
    dmTTOption: i16 = 0,
    dmCollate: i16 = 0,
    dmFormName: [32]u16 = @splat(0),
    dmLogPixels: u16 = 0,
    dmBitsPerPel: u32 = 0,
    dmPelsWidth: u32 = 0,
    dmPelsHeight: u32 = 0,
    dmDisplayFlags: u32 = 0,
    dmDisplayFrequency: u32 = 0,
    dmICM: [8]u32 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(DEVMODEW) == 220);
}

const MonitorEnum = *const fn (HANDLE, ?HANDLE, ?*RECT, isize) callconv(.winapi) BOOL;

extern "kernel32" fn GetNativeSystemInfo(si: *SYSTEM_INFO) callconv(.winapi) void;
extern "kernel32" fn GetComputerNameExW(format: u32, buf: [*]u16, n: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetSystemTimeAsFileTime(ft: *u64) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn FileTimeToLocalFileTime(ft: *const u64, local: *u64) callconv(.winapi) BOOL;
extern "kernel32" fn FileTimeToSystemTime(ft: *const u64, st: *SYSTEMTIME) callconv(.winapi) BOOL;
extern "kernel32" fn GetPhysicallyInstalledSystemMemory(kb: *u64) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalMemoryStatusEx(m: *MEMORYSTATUSEX) callconv(.winapi) BOOL;
extern "advapi32" fn GetUserNameW(buf: [*]u16, n: *u32) callconv(.winapi) BOOL;
extern "advapi32" fn RegGetValueW(key: *anyopaque, sub: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: *anyopaque, size: *u32) callconv(.winapi) i32;
extern "ntdll" fn RtlGetVersion(v: *OSVERSIONINFOW) callconv(.winapi) i32;
extern "user32" fn EnumDisplayMonitors(hdc: ?HANDLE, clip: ?*const RECT, f: MonitorEnum, data: isize) callconv(.winapi) BOOL;
extern "user32" fn GetMonitorInfoW(mon: HANDLE, info: *MONITORINFOEXW) callconv(.winapi) BOOL;
extern "user32" fn EnumDisplaySettingsW(device: [*:0]const u16, mode: u32, dm: *DEVMODEW) callconv(.winapi) BOOL;
extern "user32" fn SetThreadDpiAwarenessContext(ctx: HANDLE) callconv(.winapi) ?HANDLE;
extern "shcore" fn GetDpiForMonitor(mon: HANDLE, kind: u32, x: *u32, y: *u32) callconv(.winapi) i32;

test read {
    var m: Machine = undefined;
    read(&m);
    std.debug.print("{s} {s}\n{s} ({s})\n{s} {s} {d}.{d}.{d}.{d}\nhost {s} user {s}\nbooted {d} (up {d} s)\nmemory {d} bytes ({d} GB)\n", .{
        m.vendorSlice(),  m.modelSlice(),          m.chipSlice(), m.archSlice(),
        m.productSlice(), m.displayVersionSlice(), m.major,       m.minor,
        m.build,          m.ubr,                   m.hostSlice(), m.userSlice(),
        m.boot_unix,      GetTickCount64() / 1000, m.memory,      m.memory >> 30,
    });
    for (m.displays[0..m.n_displays]) |d| std.debug.print("display {d}x{d} @ {d} Hz, {d}%{s}\n", .{ d.width, d.height, d.hz, d.scale, if (d.primary) " primary" else "" });
    try std.testing.expect(m.chip_len > 0 and m.arch_len > 0 and m.product_len > 0 and m.host_len > 0);
    try std.testing.expect(std.mem.startsWith(u8, m.productSlice(), "Windows"));
    try std.testing.expect(m.major >= 10 and m.build > 0);
    try std.testing.expect(m.boot_unix > 1_500_000_000);
    try std.testing.expect(m.memory > 1 << 30);
    try std.testing.expect(m.n_displays > 0 and m.displays[0].width > 0);
}
