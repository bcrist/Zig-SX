# Zig-SX

A simple Zig library for reading and writing S-Expressions.

Ideal for human-readable configuration or data files containing lots of compound structures.

Parsing and writing is always done interactively with the user program; there is no intermediate "document" representation.

## Reader Example

    const std = @import("std");
    const sx = @import("sx");

    var source =
      \\(box my-box
      \\    (dimensions  4.3   7    14)
      \\    (color red)
      \\    (contents
      \\        42
      \\        "Big Phil's To Do List:
      \\ - paint it black
      \\ - clean up around the house
      \\")
      \\)
      \\
    ;

    var stream = std.io.fixedBufferStream(source);
    var reader = sx.reader(std.testing.allocator, stream.reader());
    defer reader.deinit();

    try reader.requireExpression("box");
    _ = try reader.requireAnyString();
    var color: []const u8 = "";
    var width: f32 = 0;
    var depth: f32 = 0;
    var height: f32 = 0;

    while (try reader.anyExpression()) |expr| {
        if (std.mem.eql(u8, expr, "dimensions")) {
            width = try reader.requireAnyFloat(f32);
            depth = try reader.requireAnyFloat(f32);
            height = try reader.requireAnyFloat(f32);
            try reader.requireClose();

        } else if (std.mem.eql(u8, expr, "color")) {
            color = try std.testing.allocator.dupe(u8, try reader.requireAnyString());
            try reader.requireClose();

        } else if (std.mem.eql(u8, expr, "contents")) {
            while (try reader.anyString()) |contents| {
                std.debug.print("Phil's box contains: {s}\n", .{ contents });
            }
            try reader.requireClose();

        } else {
            try reader.ignoreRemainingExpression();
        }
    }
    try reader.requireClose();
    try reader.requireDone();

## Writer Example

    const std = @import("std");
    const sx = @import("sx");

    var writer = sx.writer(std.testing.allocator, std.io.getStdOut().writer());
    defer writer.deinit();

    try writer.expression("box");
    try writer.string("my-box");
    writer.setCompact(false);

    try writer.expression("dimensions");
    try writer.float(4.3);
    try writer.float(7);
    try writer.float(14);
    _ = try writer.close();

    try writer.expression("color");
    try writer.string("red");
    _ = try writer.close();

    try writer.expressionExpanded("contents");
    try writer.int(42, 10);
    try writer.string(
        \\Big Phil's To Do List:
        \\ - paint it black
        \\ - clean up around the house
        \\
    );

    try writer.done();
