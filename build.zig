const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the shared library
    const lib = b.addSharedLibrary(.{
        .name = "hot_module",
        .root_source_file = .{ .path = "src/hot_module.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Build the main executable
    const exe = b.addExecutable(.{
        .name = "hot-reload-example",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Install both artifacts
    b.installArtifact(lib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the hot reload example");
    run_step.dependOn(&run_cmd.step);
}