//! Where mymonitor cannot read processes yet: nothing, but it
//! builds and says so.
const sample = @import("sample.zig");

pub const State = struct {};
pub const supported = false;

pub fn deinit(_: *sample.Sampler) void {}

pub fn collect(_: *sample.Sampler) sample.Ticks {
    return .{};
}
