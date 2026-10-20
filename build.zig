const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const myzig = b.dependency("myzig", .{ .target = target, .optimize = optimize }).module("myzig");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "myzig", .module = myzig }},
    });
    // The disks' counters come from IOKit.
    const mac = target.result.os.tag == .macos;
    if (mac) mod.linkFramework("IOKit", .{});
    const exe = b.addExecutable(.{ .name = "mymonitor", .root_module = mod });
    // A window, no console behind it; the icon (tools/make-icon.py).
    if (target.result.os.tag == .windows) {
        exe.subsystem = .windows;
        mod.addWin32ResourceFile(.{ .file = b.path("assets/mymonitor.rc") });
    }
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run mymonitor").dependOn(&run.step);

    // A video of myzig, rendered offscreen (src/video.zig).
    const video = b.addExecutable(.{ .name = "mymonitor-video", .root_module = b.createModule(.{
        .root_source_file = b.path("src/video.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "myzig", .module = myzig }},
    }) });
    if (mac) video.root_module.linkFramework("IOKit", .{});
    b.step("video", "Build zig-out/bin/mymonitor-video").dependOn(&b.addInstallArtifact(video, .{}).step);

    // Pictures of every page with live figures, drawn offscreen (src/shots.zig).
    const shots = b.addExecutable(.{ .name = "mymonitor-shots", .root_module = b.createModule(.{
        .root_source_file = b.path("src/shots.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "myzig", .module = myzig }},
    }) });
    if (mac) shots.root_module.linkFramework("IOKit", .{});
    b.step("shots", "Build zig-out/bin/mymonitor-shots").dependOn(&b.addInstallArtifact(shots, .{}).step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "myzig", .module = myzig }},
    }) });
    if (mac) tests.root_module.linkFramework("IOKit", .{});
    b.step("test", "Run mymonitor tests").dependOn(&b.addRunArtifact(tests).step);
    // The tests as a program, for another machine (Linux in a container).
    b.step("test-bin", "Install the tests as zig-out/bin/mymonitor-tests").dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = "mymonitor-tests" }).step);
}
