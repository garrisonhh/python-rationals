const std = @import("std");
const stderr = std.io.getStdErr().writer();
const builtin = @import("builtin");

const package_dir = "rationals";

pub fn build(b: *std.Build) !void {
    const stable_zig = std.SemanticVersion.parse("0.12.0") catch unreachable;
    if (!builtin.zig_version.order(stable_zig).compare(.eq)) {
        try stderr.print("this package expects zig version {}", .{stable_zig});
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    b.install_path = package_dir;

    const lib = b.addSharedLibrary(.{
        .name = "rational",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const install_lib = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .{ .custom = "lib" } },
    });
    b.getInstallStep().dependOn(&install_lib.step);

    const init_py = b.addInstallFile(b.path("src/__init__.py"), "__init__.py");
    const install_py = b.addInstallFile(b.path("src/rational.py"), "rational.py");
    b.getInstallStep().dependOn(&init_py.step);
    b.getInstallStep().dependOn(&install_py.step);

    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
