const std = @import("std");

pub fn build(b: *std.Build) void {
    const sx = b.addModule("sx", .{
        .root_source_file = b.path("sx.zig"),
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
            .imports = &.{
                .{ .name = "sx", .module = sx },
            },
        }),
    });
    b.step("test", "Run all tests").dependOn(&b.addRunArtifact(tests).step);
}
