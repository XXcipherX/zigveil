const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const version = builtin.zig_version;
    if (version.major != 0 or version.minor != 17 or version.patch != 0 or version.pre != null or version.build != null) @panic("Zigveil requires exactly Zig 0.17.0");
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .linux) @panic("Zigveil supports Linux; use -Dtarget=x86_64-linux or -Dtarget=aarch64-linux");
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    options.addOption(bool, "dataplane_metrics", b.option(bool, "dataplane_metrics", "Compile diagnostic dataplane counters (default false)") orelse false);
    options.addOption(bool, "relay_splice", b.option(bool, "relay_splice", "Enable bounded Linux splice relay (default true)") orelse true);
    const exe = b.addExecutable(.{
        .name = "zigveil",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    exe.pie = true;
    b.installArtifact(exe);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", options);
    b.step("test", "Run parser, pool and deterministic connection tests").dependOn(&b.addRunArtifact(tests).step);
    const fuzz = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fuzz.root_module.addOptions("build_options", options);
    b.step("fuzz", "Run bounded parser corpus/mutation checks (no external tools)").dependOn(&b.addRunArtifact(fuzz).step);
    if (b.option(bool, "bench_tools", "Build optional native Linux benchmark tool") orelse false) {
        const tool = b.addExecutable(.{
            .name = "zigveil-bench",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        tool.root_module.addCSourceFile(.{ .file = b.path("bench/native.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        tool.pie = true;
        b.installArtifact(tool);
    }
}
