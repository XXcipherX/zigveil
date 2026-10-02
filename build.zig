const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 16 or builtin.zig_version.patch != 0) @panic("Zigveil requires Zig 0.16.0");
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .linux) @panic("Zigveil supports Linux; use -Dtarget=x86_64-linux or -Dtarget=aarch64-linux");
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "zigveil",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.pie = true;
    b.installArtifact(exe);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Run parser, pool and deterministic connection tests").dependOn(&b.addRunArtifact(tests).step);
    const fuzz = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("fuzz", "Run bounded parser corpus/mutation checks (no external tools)").dependOn(&b.addRunArtifact(fuzz).step);
}
