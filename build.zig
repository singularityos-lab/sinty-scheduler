const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("cmd/sinty-schedd/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    daemon_mod.addIncludePath(b.path("cmd/sinty-schedd"));
    daemon_mod.linkSystemLibrary("gio-2.0", .{});
    const daemon = b.addExecutable(.{ .name = "sinty-schedd", .root_module = daemon_mod });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(daemon.getEmittedBin(), .{ .custom = "libexec" }, "sinty-schedd").step);

    b.installFile("data/dev.sinty.Scheduler.conf", "share/dbus-1/system.d/dev.sinty.Scheduler.conf");
    b.installFile("data/dev.sinty.Scheduler.service", "share/dbus-1/system-services/dev.sinty.Scheduler.service");
    b.installFile("data/dev.sinty.scheduler.policy", "share/polkit-1/actions/dev.sinty.scheduler.policy");
    b.installFile("data/sinty-schedd.service", "lib/systemd/system/sinty-schedd.service");

    const test_step = b.step("test", "run tests");
    const state_mod = b.createModule(.{
        .root_source_file = b.path("cmd/sinty-schedd/state.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = state_mod })).step);
}
