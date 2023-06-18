const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const reader = b.addModule("sx-reader", .{
        .source_file = .{ .path = "reader.zig" },
    });

    const writer = b.addModule("sx-writer", .{
        .source_file = .{ .path = "writer.zig" },
    });

    const sx = b.addModule("sx", .{
        .source_file = .{ .path = "sx.zig" },
        .dependencies = &.{
            .{ .name = "sx-reader", .module = reader },
            .{ .name = "sx-writer", .module = writer },
        },
    });

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "tests.zig"},
        .target = target,
        .optimize = mode,
    });
    tests.addModule("sx", sx);
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
