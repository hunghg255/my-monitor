//! Processes and the system on Windows: every process at once from the
//! kernel's list (name, parent, threads, CPU time, private memory, disk
//! bytes; protected processes too), its program's path and owner asked of
//! it once, and its GPU from the counters; the
//! machine's CPU ticks (all and each core), memory, disks (each physical
//! drive's counters), network (every hardware interface, and each one
//! apart), the GPU's engines, the battery, the volumes, and what it is.
const std = @import("std");
const sample = @import("sample.zig");
const model = @import("model.zig");
const gpu_mod = @import("win_gpu.zig");
const Sampler = sample.Sampler;

const HANDLE = *anyopaque;
const BOOL = c_int;

/// Owners: the user running mymonitor, the system's accounts, and anyone
/// else; `unknown` when the process would not say (it isn't ours to ask).
pub const me_uid: u32 = 1000;
pub const system_uid: u32 = 18;
pub const local_service_uid: u32 = 19;
pub const network_service_uid: u32 = 20;
pub const other_uid: u32 = 1;
pub const unknown_uid: u32 = std.math.maxInt(u32);

pub const supported = true;

pub const State = struct {
    /// Each process's owner, worked out once.
    uids: std.AutoHashMapUnmanaged(i32, u32) = .empty,
    /// The user's own SID, to tell their processes.
    sid: [68]u8 = undefined,
    sid_len: u32 = 0,
    /// The user's name.
    login: [128]u8 = undefined,
    login_len: usize = 0,
    text: Text = .{},
    known_machine: bool = false,
    /// The physical drives, opened once (null: none there).
    drives: [16]?HANDLE = @splat(null),
    drives_open: bool = false,
    gpu: ?gpu_mod.Reader = null,
    gpu_now: gpu_mod.Gpu = .{},
    /// The kernel's process list, kept to fill again.
    list: []align(8) u8 = &.{},
    /// Samples taken, for what is read less often (the battery, volumes).
    n: u64 = 0,
};

const Text = struct {
    os: [64]u8 = undefined,
    model: [128]u8 = undefined,
};

pub fn deinit(s: *Sampler) void {
    s.state.uids.deinit(s.gpa);
    for (s.state.drives) |d| if (d) |h| {
        _ = CloseHandle(h);
    };
    if (s.state.gpu) |*g| g.deinit();
    s.gpa.free(s.state.list);
}

/// The name of user `uid`: the user's login for theirs, the system's
/// accounts by name, else nothing (not known).
pub fn userName(s: *Sampler, uid: u32) []const u8 {
    switch (uid) {
        system_uid => return "SYSTEM",
        local_service_uid => return "LOCAL SERVICE",
        network_service_uid => return "NETWORK SERVICE",
        me_uid => {},
        else => return "",
    }
    const st = &s.state;
    if (st.login_len == 0) {
        var w: [64]u16 = undefined;
        var n: u32 = w.len;
        if (GetUserNameW(&w, &n) != 0 and n > 1) st.login_len = std.unicode.wtf16LeToWtf8(&st.login, w[0 .. n - 1]);
        if (st.login_len == 0) {
            @memcpy(st.login[0..3], "you");
            st.login_len = 3;
        }
    }
    return st.login[0..st.login_len];
}

const Namer = struct {
    exe: []const u16,
    pid: u32,
    /// Its program's path when the process says, else "chrome.exe".
    pub fn name(n: Namer, buf: []u8) []const u8 {
        var path: [1024]u16 = undefined;
        var len: u32 = path.len;
        const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, n.pid);
        defer if (h) |ph| {
            _ = CloseHandle(ph);
        };
        const w = if (h != null and QueryFullProcessImageNameW(h.?, 0, &path, &len) != 0) path[0..len] else n.exe;
        const fit = if (w.len * 3 > buf.len) w[0 .. buf.len / 3] else w;
        return buf[0..std.unicode.wtf16LeToWtf8(buf, fit)];
    }
};

pub fn collect(s: *Sampler) sample.Ticks {
    const st = &s.state;
    if (st.sid_len == 0) ownSid(st);
    if (st.gpu == null) st.gpu = .init(s.gpa);
    st.gpu.?.sample(&st.gpu_now);
    st.n += 1;
    var compressed: u64 = 0;
    var off: usize = 0;
    const list = processList(s);
    while (off + @sizeOf(SPI) <= list.len) {
        const e: *const SPI = @ptrCast(@alignCast(list[off..].ptr));
        defer off = if (e.NextEntryOffset == 0) list.len else off + e.NextEntryOffset;
        const id: u32 = @intCast(e.UniqueProcessId);
        // The idle "process" is the CPU's idle time, not a program.
        if (id == 0) continue;
        const pid: i32 = @bitCast(id);
        const uid = st.uids.get(pid) orelse blk: {
            const u = if (pid == 4) system_uid else ownerOf(st, id);
            st.uids.put(s.gpa, pid, u) catch {};
            break :blk u;
        };
        const exe: []const u16 = if (e.ImageName.Buffer) |b| b[0 .. e.ImageName.Length / 2] else std.unicode.utf8ToUtf16LeStringLiteral("System");
        const named = s.name(pid, Namer{ .exe = exe, .pid = id });
        var p: model.Process = .{ .pid = pid, .ppid = @intCast(e.InheritedFromUniqueProcessId), .uid = uid, .name = named.name, .user = s.user(uid), .bundle = named.bundle, .known = true };
        p.threads = e.NumberOfThreads;
        p.gpu = st.gpu.?.processPercent(id);
        p.cpu_time_ns = @as(u64, @bitCast(e.UserTime + e.KernelTime)) * 100;
        // Its private working set, as Task Manager's Memory column.
        p.memory = @bitCast(e.WorkingSetPrivateSize);
        // The store of compressed pages: what it holds is its working set.
        if (std.mem.eql(u8, p.name, "Memory Compression")) {
            p.memory = e.WorkingSetSize;
            compressed = e.WorkingSetSize;
        }
        p.virtual = e.VirtualSize;
        if (e.CreateTime > 0) p.started = @divFloor(e.CreateTime, 10_000_000) - 11_644_473_600;
        p.disk_read = @bitCast(e.ReadTransferCount);
        p.disk_written = @bitCast(e.WriteTransferCount);
        s.procs.append(s.gpa, p) catch break;
    }
    if (st.uids.count() > 4 * (s.procs.items.len + 64)) st.uids.clearRetainingCapacity();
    memory(s, compressed);
    disks(s);
    network(s);
    s.n_ifaces = sample.net.list(&s.ifaces);
    // What changes slowly, every few samples.
    if (st.n % 5 == 1) {
        s.n_volumes = sample.storage.list(&s.volumes);
        sample.power.read(&s.battery);
    }
    const g = st.gpu_now;
    s.system.gpu = g.util;
    s.system.gpu_3d = g.engines.three_d;
    s.system.gpu_copy = g.engines.copy;
    s.system.gpu_decode = g.engines.video_decode;
    s.system.gpu_processing = g.engines.video_processing;
    s.system.gpu_memory = g.dedicated_used + g.shared_used;
    const t = ticks(s);
    if (!st.known_machine) {
        st.known_machine = true;
        machine(s);
    }
    s.system.tasks = @intCast(s.procs.items.len);
    s.system.uptime_s = GetTickCount64() / 1000;
    return t;
}

/// The kernel's list of every process, in the buffer kept for it (grown
/// when the list outgrows it); empty when it can't be read.
fn processList(s: *Sampler) []const u8 {
    const st = &s.state;
    while (true) {
        var len: u32 = 0;
        const r = NtQuerySystemInformation(SystemProcessInformation, st.list.ptr, @intCast(st.list.len), &len);
        if (r == 0) return st.list[0..@min(len, st.list.len)];
        if (r != STATUS_INFO_LENGTH_MISMATCH) return &.{};
        s.gpa.free(st.list);
        st.list = s.gpa.alignedAlloc(u8, .@"8", len + 64 * 1024) catch {
            st.list = &.{};
            return &.{};
        };
    }
}

/// Who process `pid` runs as, asked of it.
fn ownerOf(st: *State, pid: u32) u32 {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return unknown_uid;
    defer _ = CloseHandle(h);
    return owner(st, h);
}

/// The SID of the user running mymonitor.
fn ownSid(st: *State) void {
    var tok: ?HANDLE = null;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok) == 0) return;
    defer _ = CloseHandle(tok.?);
    var buf: [128]u8 align(8) = undefined;
    var n: u32 = 0;
    if (GetTokenInformation(tok.?, TokenUser, &buf, buf.len, &n) == 0) return;
    const sid: *anyopaque = @as(*const ?*anyopaque, @ptrCast(&buf)).*.?;
    const len = GetLengthSid(sid);
    if (len > st.sid.len) return;
    @memcpy(st.sid[0..len], @as([*]const u8, @ptrCast(sid))[0..len]);
    st.sid_len = len;
}

/// Who process `h` runs as: the user, one of the system's accounts, or
/// someone else; unknown when its token isn't ours to read.
fn owner(st: *State, h: HANDLE) u32 {
    var tok: ?HANDLE = null;
    if (OpenProcessToken(h, TOKEN_QUERY, &tok) == 0) return unknown_uid;
    defer _ = CloseHandle(tok.?);
    var buf: [128]u8 align(8) = undefined;
    var n: u32 = 0;
    if (GetTokenInformation(tok.?, TokenUser, &buf, buf.len, &n) == 0) return unknown_uid;
    const sid: *anyopaque = @as(*const ?*anyopaque, @ptrCast(&buf)).*.?;
    if (st.sid_len > 0 and EqualSid(sid, &st.sid) != 0) return me_uid;
    if (IsWellKnownSid(sid, WinLocalSystemSid) != 0) return system_uid;
    if (IsWellKnownSid(sid, WinLocalServiceSid) != 0) return local_service_uid;
    if (IsWellKnownSid(sid, WinNetworkServiceSid) != 0) return network_service_uid;
    return other_uid;
}

/// Whether mymonitor runs elevated (as Administrator), asked once.
pub fn elevated() bool {
    const once = struct {
        var known: ?bool = null;
    };
    if (once.known) |e| return e;
    once.known = elevation();
    return once.known.?;
}

fn elevation() bool {
    var tok: ?HANDLE = null;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok) == 0) return false;
    defer _ = CloseHandle(tok.?);
    var e: u32 = 0;
    var n: u32 = 0;
    return GetTokenInformation(tok.?, TokenElevation, &e, @sizeOf(u32), &n) != 0 and e != 0;
}

/// Starts mymonitor again as Administrator (Windows asks first); whether
/// it did.
pub fn relaunchElevated() bool {
    var path: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &path, path.len);
    if (n == 0 or n >= path.len) return false;
    path[n] = 0;
    const verb = std.unicode.utf8ToUtf16LeStringLiteral("runas");
    return @intFromPtr(ShellExecuteW(null, verb, @ptrCast(&path), null, null, 1)) > 32;
}

/// The machine's ticks (100 ns), and each core's.
fn ticks(s: *Sampler) sample.Ticks {
    var idle: u64 = 0;
    var kernel: u64 = 0;
    var user: u64 = 0;
    if (GetSystemTimes(&idle, &kernel, &user) == 0) return .{};
    var per: [64]PROCESSOR_PERFORMANCE = undefined;
    var len: u32 = 0;
    if (NtQuerySystemInformation(SystemProcessorPerformanceInformation, &per, @sizeOf(@TypeOf(per)), &len) == 0) {
        const cores: u32 = @intCast(len / @sizeOf(PROCESSOR_PERFORMANCE));
        for (per[0..cores], 0..) |c, i| {
            // Kernel time includes idle time.
            const ci: u64 = @bitCast(c.IdleTime);
            const ck: u64 = @bitCast(c.KernelTime);
            const cu: u64 = @bitCast(c.UserTime);
            s.core_ticks[i] = .{ .user = cu, .system = ck -| ci, .idle = ci };
        }
        s.cores = @min(cores, sample.max_cores);
        s.system.cores = @max(1, cores);
    }
    return .{ .user = user, .system = kernel -| idle, .idle = idle };
}

/// Memory as Task Manager splits it: in use (the kernel's nonpaged pool
/// as wired, and what Memory Compression holds), cached (the standby list
/// and the system's cache), free; the page file and commit.
fn memory(s: *Sampler, compressed: u64) void {
    var m: MEMORYSTATUSEX = .{};
    if (GlobalMemoryStatusEx(&m) == 0) return;
    var pi: PERFORMANCE_INFORMATION = .{};
    const have_pi = K32GetPerformanceInfo(&pi, @sizeOf(PERFORMANCE_INFORMATION)) != 0;
    const sy = &s.system;
    sy.mem_total = m.ullTotalPhys;
    const used = m.ullTotalPhys -| m.ullAvailPhys;
    // The kernel's nonpaged pool stays put, as wired memory does.
    const wired: u64 = if (have_pi) @min(used, pi.KernelNonpaged * pi.PageSize) else 0;
    sy.mem_wired = wired;
    sy.mem_compressed = @min(compressed, used - wired);
    sy.mem_app = used - wired - sy.mem_compressed;
    sy.mem_cached = if (have_pi) @min(m.ullAvailPhys, pi.SystemCache * pi.PageSize) else 0;
    pageFiles(sy, if (have_pi) pi.PageSize else 4096);
    sy.commit = m.ullTotalPageFile -| m.ullAvailPageFile;
    sy.commit_limit = m.ullTotalPageFile;
    sy.pressure = @floatFromInt(m.dwMemoryLoad);
    if (have_pi) sy.threads = pi.ThreadCount;
}

/// The page files' size and what they hold, from the kernel's list of them.
fn pageFiles(sy: *model.System, page: u64) void {
    var buf: [4096]u8 align(8) = undefined;
    var len: u32 = 0;
    if (NtQuerySystemInformation(SystemPageFileInformation, &buf, buf.len, &len) != 0) return;
    var total: u64 = 0;
    var used: u64 = 0;
    var off: usize = 0;
    while (off + @sizeOf(PAGEFILE) <= len) {
        const f: *const PAGEFILE = @ptrCast(@alignCast(buf[off..].ptr));
        total += @as(u64, f.TotalSize) * page;
        used += @as(u64, f.TotalInUse) * page;
        if (f.NextEntryOffset == 0) break;
        off += f.NextEntryOffset;
    }
    sy.swap_total = total;
    sy.swap_used = used;
}

/// Every physical drive's reads, writes and bytes, summed.
fn disks(s: *Sampler) void {
    const st = &s.state;
    if (!st.drives_open) {
        st.drives_open = true;
        for (&st.drives, 0..) |*d, i| {
            var name: [32]u16 = undefined;
            var ascii: [32]u8 = undefined;
            const a = std.fmt.bufPrint(&ascii, "\\\\.\\PhysicalDrive{d}", .{i}) catch continue;
            for (a, 0..) |c, j| name[j] = c;
            name[a.len] = 0;
            const h = CreateFileW(@ptrCast(&name), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
            d.* = if (h == INVALID_HANDLE) null else h;
        }
    }
    var t: [4]u64 = @splat(0);
    for (st.drives) |d| if (d) |h| {
        var perf: DISK_PERFORMANCE = undefined;
        var got: u32 = 0;
        if (DeviceIoControl(h, IOCTL_DISK_PERFORMANCE, null, 0, &perf, @sizeOf(DISK_PERFORMANCE), &got, null) == 0) continue;
        t[0] += perf.ReadCount;
        t[1] += perf.WriteCount;
        t[2] += @bitCast(perf.BytesRead);
        t[3] += @bitCast(perf.BytesWritten);
    };
    s.system.reads = t[0];
    s.system.writes = t[1];
    s.system.read_bytes = t[2];
    s.system.written_bytes = t[3];
}

/// Bytes through every hardware interface (no loopback, no filters).
fn network(s: *Sampler) void {
    var table: ?*MIB_IF_TABLE2 = null;
    if (GetIfTable2(&table) != 0 or table == null) return;
    defer FreeMibTable(table.?);
    const rows: [*]const MIB_IF_ROW2 = @ptrCast(&table.?.Table);
    var in: u64 = 0;
    var out: u64 = 0;
    for (rows[0..table.?.NumEntries]) |r| {
        const hardware = r.Flags & 1 != 0;
        const filter = r.Flags & 2 != 0;
        if (!hardware or filter or r.Type == 24) continue;
        in += r.InOctets;
        out += r.OutOctets;
    }
    s.system.net_in = in;
    s.system.net_out = out;
}

/// What the machine is: once.
fn machine(s: *Sampler) void {
    const m = &s.machine;
    sample.machine.read(m);
    const t = &s.state.text;
    s.info.chip = m.chipSlice();
    s.info.host = m.hostSlice();
    s.info.os = std.fmt.bufPrint(&t.os, "{s} ({d})", .{ m.productSlice(), m.build }) catch "Windows";
    s.info.model = std.fmt.bufPrint(&t.model, "{s} {s}", .{ m.vendorSlice(), m.modelSlice() }) catch "";
    s.info.gpu = s.state.gpu_now.nameSlice();
    s.info.fast = s.cores;
    s.info.fast_name = "Cores";
}

/// Asks process `pid` to quit, as closing its windows does; a process
/// without windows is ended.
pub fn close(pid: c_int) c_int {
    const Ask = struct {
        pid: u32,
        asked: bool = false,

        fn each(hwnd: HANDLE, ctx: isize) callconv(.winapi) BOOL {
            const ask: *@This() = @ptrFromInt(@as(usize, @bitCast(ctx)));
            var of: u32 = 0;
            _ = GetWindowThreadProcessId(hwnd, &of);
            if (of == ask.pid and IsWindowVisible(hwnd) != 0) {
                _ = PostMessageW(hwnd, WM_CLOSE, 0, 0);
                ask.asked = true;
            }
            return 1;
        }
    };
    var ask: Ask = .{ .pid = @bitCast(pid) };
    _ = EnumWindows(Ask.each, @bitCast(@intFromPtr(&ask)));
    return if (ask.asked) 0 else terminate(pid);
}

/// The command line process `pid` was started with; "" when it won't say.
pub fn commandLine(pid: i32, out: []u8) []const u8 {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, @bitCast(pid)) orelse return "";
    defer _ = CloseHandle(h);
    var buf: [8192]u8 align(8) = undefined;
    var len: u32 = 0;
    if (NtQueryInformationProcess(h, ProcessCommandLineInformation, &buf, buf.len, &len) != 0) return "";
    const us: *const UNICODE_STRING = @ptrCast(&buf);
    const w = (us.Buffer orelse return "")[0 .. us.Length / 2];
    const fit = if (w.len * 3 > out.len) w[0 .. out.len / 3] else w;
    return out[0..std.unicode.wtf16LeToWtf8(out, fit)];
}

/// Ends process `pid` at once.
pub fn terminate(pid: c_int) c_int {
    const h = OpenProcess(PROCESS_TERMINATE, 0, @bitCast(pid)) orelse return -1;
    defer _ = CloseHandle(h);
    return if (TerminateProcess(h, 1) != 0) 0 else -1;
}

pub fn currentPid() i32 {
    return @bitCast(GetCurrentProcessId());
}

const INVALID_HANDLE: ?HANDLE = @ptrFromInt(std.math.maxInt(usize));
const PROCESS_TERMINATE = 0x1;
const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
const TOKEN_QUERY = 0x8;
const TokenUser = 1;
const TokenElevation = 20;
const WinLocalSystemSid = 22;
const WinLocalServiceSid = 23;
const WinNetworkServiceSid = 24;
const SystemProcessInformation = 5;
const ProcessCommandLineInformation = 60;
const WM_CLOSE = 0x0010;
const SystemPageFileInformation = 18;
const SystemProcessorPerformanceInformation = 8;
const STATUS_INFO_LENGTH_MISMATCH: i32 = @bitCast(@as(u32, 0xC0000004));
const FILE_SHARE_READ = 0x1;
const FILE_SHARE_WRITE = 0x2;
const OPEN_EXISTING = 3;
const IOCTL_DISK_PERFORMANCE = 0x70020;

const UNICODE_STRING = extern struct { Length: u16, MaximumLength: u16, Buffer: ?[*]u16 };

/// SYSTEM_PAGEFILE_INFORMATION: a page file, in pages.
const PAGEFILE = extern struct {
    NextEntryOffset: u32,
    TotalSize: u32,
    TotalInUse: u32,
    PeakUsage: u32,
    PageFileName: UNICODE_STRING,
};

/// SYSTEM_PROCESS_INFORMATION: a process in the kernel's list.
const SPI = extern struct {
    NextEntryOffset: u32,
    NumberOfThreads: u32,
    WorkingSetPrivateSize: i64,
    HardFaultCount: u32,
    NumberOfThreadsHighWatermark: u32,
    CycleTime: u64,
    CreateTime: i64,
    UserTime: i64,
    KernelTime: i64,
    ImageName: UNICODE_STRING,
    BasePriority: i32,
    UniqueProcessId: usize,
    InheritedFromUniqueProcessId: usize,
    HandleCount: u32,
    SessionId: u32,
    UniqueProcessKey: usize,
    PeakVirtualSize: usize,
    VirtualSize: usize,
    PageFaultCount: u32,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
    PrivatePageCount: usize,
    ReadOperationCount: i64,
    WriteOperationCount: i64,
    OtherOperationCount: i64,
    ReadTransferCount: i64,
    WriteTransferCount: i64,
    OtherTransferCount: i64,
};

comptime {
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(SPI) == 256);
}

const PROCESSOR_PERFORMANCE = extern struct {
    IdleTime: i64,
    KernelTime: i64,
    UserTime: i64,
    DpcTime: i64,
    InterruptTime: i64,
    InterruptCount: u32,
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

const PERFORMANCE_INFORMATION = extern struct {
    cb: u32 = @sizeOf(PERFORMANCE_INFORMATION),
    CommitTotal: usize = 0,
    CommitLimit: usize = 0,
    CommitPeak: usize = 0,
    PhysicalTotal: usize = 0,
    PhysicalAvailable: usize = 0,
    SystemCache: usize = 0,
    KernelTotal: usize = 0,
    KernelPaged: usize = 0,
    KernelNonpaged: usize = 0,
    PageSize: usize = 0,
    HandleCount: u32 = 0,
    ProcessCount: u32 = 0,
    ThreadCount: u32 = 0,
};

const DISK_PERFORMANCE = extern struct {
    BytesRead: i64,
    BytesWritten: i64,
    ReadTime: i64,
    WriteTime: i64,
    IdleTime: i64,
    ReadCount: u32,
    WriteCount: u32,
    QueueDepth: u32,
    SplitCount: u32,
    QueryTime: i64,
    StorageDeviceNumber: u32,
    StorageManagerName: [8]u16,
};

const MIB_IF_ROW2 = extern struct {
    InterfaceLuid: u64,
    InterfaceIndex: u32,
    InterfaceGuid: [16]u8,
    Alias: [257]u16,
    Description: [257]u16,
    PhysicalAddressLength: u32,
    PhysicalAddress: [32]u8,
    PermanentPhysicalAddress: [32]u8,
    Mtu: u32,
    Type: u32,
    TunnelType: u32,
    MediaType: u32,
    PhysicalMediumType: u32,
    AccessType: u32,
    DirectionType: u32,
    /// HardwareInterface (bit 0), FilterInterface (bit 1), …
    Flags: u8,
    OperStatus: u32,
    AdminStatus: u32,
    MediaConnectState: u32,
    NetworkGuid: [16]u8,
    ConnectionType: u32,
    TransmitLinkSpeed: u64,
    ReceiveLinkSpeed: u64,
    InOctets: u64,
    InUcastPkts: u64,
    InNUcastPkts: u64,
    InDiscards: u64,
    InErrors: u64,
    InUnknownProtos: u64,
    InUcastOctets: u64,
    InMulticastOctets: u64,
    InBroadcastOctets: u64,
    OutOctets: u64,
    OutUcastPkts: u64,
    OutNUcastPkts: u64,
    OutDiscards: u64,
    OutErrors: u64,
    OutUcastOctets: u64,
    OutMulticastOctets: u64,
    OutBroadcastOctets: u64,
    OutQLen: u64,
};

comptime {
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(MIB_IF_ROW2) == 1352);
}

const MIB_IF_TABLE2 = extern struct {
    NumEntries: u32,
    Table: [1]MIB_IF_ROW2,
};


extern "kernel32" fn OpenProcess(access: u32, inherit: BOOL, pid: u32) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn K32GetPerformanceInfo(info: *PERFORMANCE_INFORMATION, cb: u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetSystemTimes(idle: *u64, kernel: *u64, user: *u64) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalMemoryStatusEx(m: *MEMORYSTATUSEX) callconv(.winapi) BOOL;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn QueryFullProcessImageNameW(h: HANDLE, flags: u32, buf: [*]u16, n: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleFileNameW(module: ?HANDLE, buf: [*]u16, n: u32) callconv(.winapi) u32;
extern "shell32" fn ShellExecuteW(hwnd: ?HANDLE, verb: [*:0]const u16, file: [*:0]const u16, params: ?[*:0]const u16, dir: ?[*:0]const u16, show: c_int) callconv(.winapi) ?HANDLE;
extern "advapi32" fn IsWellKnownSid(sid: *anyopaque, kind: c_int) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) ?HANDLE;
extern "kernel32" fn DeviceIoControl(h: HANDLE, code: u32, in: ?*anyopaque, in_size: u32, out: ?*anyopaque, out_size: u32, got: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "advapi32" fn OpenProcessToken(h: HANDLE, access: u32, tok: *?HANDLE) callconv(.winapi) BOOL;
extern "advapi32" fn GetTokenInformation(tok: HANDLE, class: u32, buf: *anyopaque, len: u32, got: *u32) callconv(.winapi) BOOL;
extern "advapi32" fn GetLengthSid(sid: *anyopaque) callconv(.winapi) u32;
extern "advapi32" fn EqualSid(a: *anyopaque, b: *anyopaque) callconv(.winapi) BOOL;
extern "advapi32" fn GetUserNameW(buf: [*]u16, n: *u32) callconv(.winapi) BOOL;
extern "ntdll" fn NtQueryInformationProcess(h: HANDLE, class: u32, info: *anyopaque, len: u32, got: *u32) callconv(.winapi) i32;
extern "user32" fn EnumWindows(f: *const fn (HANDLE, isize) callconv(.winapi) BOOL, ctx: isize) callconv(.winapi) BOOL;
extern "user32" fn GetWindowThreadProcessId(hwnd: HANDLE, pid: *u32) callconv(.winapi) u32;
extern "user32" fn IsWindowVisible(hwnd: HANDLE) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(hwnd: HANDLE, msg: u32, w: usize, l: isize) callconv(.winapi) BOOL;
extern "ntdll" fn NtQuerySystemInformation(class: u32, info: *anyopaque, len: u32, got: *u32) callconv(.winapi) i32;
extern "iphlpapi" fn GetIfTable2(table: *?*MIB_IF_TABLE2) callconv(.winapi) u32;
extern "iphlpapi" fn FreeMibTable(table: *anyopaque) callconv(.winapi) void;
