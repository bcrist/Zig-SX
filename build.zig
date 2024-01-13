const std = @import("std");

pub fn build(b: *std.Build) void {
    const sx = b.addModule("sx", .{
        .root_source_file = .{ .path = "sx.zig" },
    });

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "tests.zig"},
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    tests.root_module.addImport("sx", sx);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
