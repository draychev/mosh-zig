const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    module.linkSystemLibrary("crypto", .{});
    module.linkSystemLibrary("z", .{});
    const exe = b.addExecutable(.{ .name = "mosh", .root_module = module });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Connect to a Mosh server").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run protocol and terminal tests").dependOn(&b.addRunArtifact(tests).step);
}
