//! The network interfaces on Windows, as Settings shows them: each one's
//! name, what it is, whether it is up, its bytes, first addresses and MAC.
//! The interface table gives the first, the adapter addresses the rest;
//! filter layers (WFP, QoS, Native WiFi), tunnels, hidden adapters ("Local
//! Area Connection* 7": WAN miniports, Wi-Fi Direct) and ones with no
//! address of their own (switch extensions, the kernel debugger) stay out.
const std = @import("std");

pub const Kind = enum { wifi, ethernet, loopback, other };

pub const Iface = struct {
    luid: u64 = 0,
    index: u32 = 0,
    /// "Wi-Fi", "vEthernet (WSL)", "Ethernet 2".
    alias: [128]u8 = undefined,
    alias_len: usize = 0,
    /// The adapter: "Intel(R) Wi-Fi 6 AX201 160MHz".
    desc: [128]u8 = undefined,
    desc_len: usize = 0,
    kind: Kind = .other,
    up: bool = false,
    in_bytes: u64 = 0,
    out_bytes: u64 = 0,
    /// "192.168.1.20".
    ipv4: [16]u8 = undefined,
    ipv4_len: usize = 0,
    /// A global address when there is one, else the link-local, no scope.
    ipv6: [46]u8 = undefined,
    ipv6_len: usize = 0,
    /// "4c:44:5b:c9:36:7d".
    mac: [18]u8 = undefined,
    mac_len: usize = 0,

    pub fn aliasSlice(i: *const Iface) []const u8 {
        return i.alias[0..i.alias_len];
    }
    pub fn descSlice(i: *const Iface) []const u8 {
        return i.desc[0..i.desc_len];
    }
    pub fn ipv4Slice(i: *const Iface) []const u8 {
        return i.ipv4[0..i.ipv4_len];
    }
    pub fn ipv6Slice(i: *const Iface) []const u8 {
        return i.ipv6[0..i.ipv6_len];
    }
    pub fn macSlice(i: *const Iface) []const u8 {
        return i.mac[0..i.mac_len];
    }
};

/// Fills `out` with the interfaces (up ones first, then the rest by name); how many.
pub fn list(out: []Iface) usize {
    var table: ?*MIB_IF_TABLE2 = null;
    if (GetIfTable2(&table) != 0 or table == null) return 0;
    defer FreeMibTable(table.?);
    const rows: [*]const MIB_IF_ROW2 = @ptrCast(&table.?.Table);
    var n: usize = 0;
    for (rows[0..table.?.NumEntries]) |*r| {
        if (n == out.len) break;
        if (!shown(r)) continue;
        const i = &out[n];
        i.* = .{
            .luid = r.InterfaceLuid,
            .index = r.InterfaceIndex,
            .kind = switch (r.Type) {
                IF_TYPE_IEEE80211 => .wifi,
                IF_TYPE_ETHERNET_CSMACD => .ethernet,
                IF_TYPE_SOFTWARE_LOOPBACK => .loopback,
                else => .other,
            },
            .up = r.OperStatus == IfOperStatusUp,
            .in_bytes = r.InOctets,
            .out_bytes = r.OutOctets,
        };
        i.alias_len = keep(&i.alias, std.mem.sliceTo(&r.Alias, 0));
        i.desc_len = keep(&i.desc, std.mem.sliceTo(&r.Description, 0));
        if (r.PhysicalAddressLength == 6) i.mac_len = (std.fmt.bufPrint(&i.mac, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            r.PhysicalAddress[0], r.PhysicalAddress[1], r.PhysicalAddress[2],
            r.PhysicalAddress[3], r.PhysicalAddress[4], r.PhysicalAddress[5],
        }) catch unreachable).len;
        n += 1;
    }
    addresses(out[0..n]);
    std.mem.sort(Iface, out[0..n], {}, before);
    return n;
}

/// Whether Settings would show row `r`.
fn shown(r: *const MIB_IF_ROW2) bool {
    if (r.Flags & FilterInterface != 0 or r.Type == IF_TYPE_TUNNEL) return false;
    if (r.PhysicalAddressLength == 0 and r.Type != IF_TYPE_SOFTWARE_LOOPBACK) return false;
    const alias = std.mem.sliceTo(&r.Alias, 0);
    if (std.mem.findScalar(u16, alias, '*') != null) return false;
    // Filter layers carry the flag; their names give them away too.
    inline for (.{ "-WFP", "-QoS", "-Native WiFi Filter", "-Npcap", "-Virtual Filter" }) |layer| {
        if (std.mem.find(u16, alias, std.unicode.utf8ToUtf16LeStringLiteral(layer)) != null) return false;
    }
    return true;
}

fn before(_: void, a: Iface, b: Iface) bool {
    if (a.up != b.up) return a.up;
    return std.ascii.lessThanIgnoreCase(a.aliasSlice(), b.aliasSlice());
}

/// Each interface's first IPv4 and IPv6 address, from its adapter.
fn addresses(ifaces: []Iface) void {
    const gpa = std.heap.page_allocator;
    var size: u32 = 16 * 1024;
    var buf: []align(8) u8 = &.{};
    defer gpa.free(buf);
    while (true) {
        gpa.free(buf);
        buf = gpa.alignedAlloc(u8, .@"8", size) catch return;
        const err = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX, null, @ptrCast(buf.ptr), &size);
        if (err == 0) break;
        if (err != ERROR_BUFFER_OVERFLOW) return;
    }
    var a: ?*const IP_ADAPTER_ADDRESSES = @ptrCast(buf.ptr);
    while (a) |ad| : (a = ad.Next) {
        const i = for (ifaces) |*i| {
            if (i.luid == ad.Luid or i.index == ad.IfIndex) break i;
        } else continue;
        var link_local = false;
        var u = ad.FirstUnicastAddress;
        while (u) |ua| : (u = ua.Next) {
            const sa = ua.Address.lpSockaddr orelse continue;
            switch (sa.family) {
                AF_INET => if (i.ipv4_len == 0) {
                    const in: *const SOCKADDR_IN = @ptrCast(@alignCast(sa));
                    var tmp: [16]u8 = undefined;
                    const end = RtlIpv4AddressToStringA(&in.addr, &tmp);
                    i.ipv4_len = end - @as([*]u8, &tmp);
                    @memcpy(i.ipv4[0..i.ipv4_len], tmp[0..i.ipv4_len]);
                },
                AF_INET6 => {
                    const in6: *const SOCKADDR_IN6 = @ptrCast(@alignCast(sa));
                    const local = in6.addr[0] == 0xfe and in6.addr[1] & 0xc0 == 0x80;
                    if (i.ipv6_len != 0 and (local or !link_local)) continue;
                    var tmp: [46]u8 = undefined;
                    const end = RtlIpv6AddressToStringA(&in6.addr, &tmp);
                    i.ipv6_len = end - @as([*]u8, &tmp);
                    @memcpy(i.ipv6[0..i.ipv6_len], tmp[0..i.ipv6_len]);
                    link_local = local;
                },
                else => {},
            }
        }
    }
}

/// Copies UTF-16 `w` into `dst` as UTF-8, cut at a whole character; the length.
fn keep(dst: []u8, w: []const u16) usize {
    var all: [257 * 3]u8 = undefined;
    const len = std.unicode.wtf16LeToWtf8(&all, w[0..@min(w.len, 257)]);
    var n = @min(dst.len, len);
    if (n < len) while (n > 0 and all[n] & 0xc0 == 0x80) : (n -= 1) {};
    @memcpy(dst[0..n], all[0..n]);
    return n;
}

const IF_TYPE_ETHERNET_CSMACD = 6;
const IF_TYPE_SOFTWARE_LOOPBACK = 24;
const IF_TYPE_IEEE80211 = 71;
const IF_TYPE_TUNNEL = 131;
const IfOperStatusUp = 1;
const FilterInterface = 0x2;
const AF_UNSPEC = 0;
const AF_INET = 2;
const AF_INET6 = 23;
const GAA_FLAG_INCLUDE_PREFIX = 0x10;
const ERROR_BUFFER_OVERFLOW = 111;

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

const SOCKADDR = extern struct { family: u16 };
const SOCKADDR_IN = extern struct { family: u16, port: u16, addr: [4]u8 };
const SOCKADDR_IN6 = extern struct { family: u16, port: u16, flowinfo: u32, addr: [16]u8, scope_id: u32 };

const IP_ADAPTER_UNICAST_ADDRESS = extern struct {
    Length: u32,
    Flags: u32,
    Next: ?*const IP_ADAPTER_UNICAST_ADDRESS,
    Address: extern struct { lpSockaddr: ?*const SOCKADDR, iSockaddrLength: i32 },
};

/// The head of IP_ADAPTER_ADDRESSES_LH, up to Luid (only read through a pointer).
const IP_ADAPTER_ADDRESSES = extern struct {
    Length: u32,
    IfIndex: u32,
    Next: ?*const IP_ADAPTER_ADDRESSES,
    AdapterName: ?[*:0]const u8,
    FirstUnicastAddress: ?*const IP_ADAPTER_UNICAST_ADDRESS,
    FirstAnycastAddress: ?*anyopaque,
    FirstMulticastAddress: ?*anyopaque,
    FirstDnsServerAddress: ?*anyopaque,
    DnsSuffix: ?[*:0]const u16,
    Description: ?[*:0]const u16,
    FriendlyName: ?[*:0]const u16,
    PhysicalAddress: [8]u8,
    PhysicalAddressLength: u32,
    Flags: u32,
    Mtu: u32,
    IfType: u32,
    OperStatus: u32,
    Ipv6IfIndex: u32,
    ZoneIndices: [16]u32,
    FirstPrefix: ?*anyopaque,
    TransmitLinkSpeed: u64,
    ReceiveLinkSpeed: u64,
    FirstWinsServerAddress: ?*anyopaque,
    FirstGatewayAddress: ?*anyopaque,
    Ipv4Metric: u32,
    Ipv6Metric: u32,
    Luid: u64,
};

extern "iphlpapi" fn GetIfTable2(table: *?*MIB_IF_TABLE2) callconv(.winapi) u32;
extern "iphlpapi" fn FreeMibTable(table: *anyopaque) callconv(.winapi) void;
extern "iphlpapi" fn GetAdaptersAddresses(family: u32, flags: u32, reserved: ?*anyopaque, addrs: *IP_ADAPTER_ADDRESSES, size: *u32) callconv(.winapi) u32;
extern "ntdll" fn RtlIpv4AddressToStringA(addr: *const [4]u8, buf: [*]u8) callconv(.winapi) [*]u8;
extern "ntdll" fn RtlIpv6AddressToStringA(addr: *const [16]u8, buf: [*]u8) callconv(.winapi) [*]u8;

test list {
    var ifaces: [64]Iface = undefined;
    const n = list(&ifaces);
    try std.testing.expect(n > 0);
    var loopback = false;
    for (ifaces[0..n]) |*i| {
        std.debug.print("{s:<28} {s:<8} {s:<4} in {d:>12} out {d:>12} {s:<15} {s:<26} {s:<17} {s}\n", .{
            i.aliasSlice(), @tagName(i.kind), if (i.up) "up" else "down", i.in_bytes,    i.out_bytes,
            i.ipv4Slice(),  i.ipv6Slice(),    i.macSlice(),               i.descSlice(),
        });
        try std.testing.expect(i.alias_len > 0);
        try std.testing.expect(std.unicode.utf8ValidateSlice(i.aliasSlice()));
        try std.testing.expect(std.mem.findScalar(u8, i.ipv6Slice(), '%') == null);
        if (i.kind == .loopback) loopback = true;
    }
    try std.testing.expect(loopback);
}
