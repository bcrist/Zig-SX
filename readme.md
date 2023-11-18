# Zig-SX

A simple Zig library for reading and writing S-Expressions.

Ideal for human-readable configuration or data files containing lots of compound structures.

Parsing and writing is always done interactively with the user program; there is no intermediate "document" representation.

## Reader Example
```zig
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

try reader.require_expression("box");
_ = try reader.require_any_string();
var color: []const u8 = "";
var width: f32 = 0;
var depth: f32 = 0;
var height: f32 = 0;

while (try reader.any_expression()) |expr| {
    if (std.mem.eql(u8, expr, "dimensions")) {
        width = try reader.require_any_float(f32);
        depth = try reader.require_any_float(f32);
        height = try reader.require_any_float(f32);
        try reader.require_close();

    } else if (std.mem.eql(u8, expr, "color")) {
        color = try std.testing.allocator.dupe(u8, try reader.require_any_string());
        try reader.require_close();

    } else if (std.mem.eql(u8, expr, "contents")) {
        while (try reader.any_string()) |contents| {
            std.debug.print("Phil's box contains: {s}\n", .{ contents });
        }
        try reader.require_close();

    } else {
        try reader.ignore_remaining_expression();
    }
}
try reader.require_close();
try reader.require_done();
```

## Writer Example
```zig
const std = @import("std");
const sx = @import("sx");

var writer = sx.writer(std.testing.allocator, std.io.getStdOut().writer());
defer writer.deinit();

try writer.expression("box");
try writer.string("my-box");
writer.set_compact(false);

try writer.expression("dimensions");
try writer.float(4.3);
try writer.float(7);
try writer.float(14);
_ = try writer.close();

try writer.expression("color");
try writer.string("red");
_ = try writer.close();

try writer.expression_expanded("contents");
try writer.int(42, 10);
try writer.string(
    \\Big Phil's To Do List:
    \\ - paint it black
    \\ - clean up around the house
    \\
);

try writer.done();
```

## Building
This library is designed to be used with the Zig package manager.  To use it, add a `build.zig.zon` file next to your `build.zig` file:
```zig
.{
    .name = "Your Project Name",
    .version = "0.0.0",
    .dependencies = .{
        .@"Zig-SX" = .{
            .url = "https://github.com/bcrist/Zig-SX/archive/xxxxxx.tar.gz",
        },
    },
}
```
Replace `xxxxxx` with the full commit hash for the version of the library you want to use.  The first time you run `zig build` after adding this, it will tell you a hash to put after `.url = ...`.  This helps zig ensure that the file wasn't corrupted during download, and that the URL hasn't been hijacked.
Then in your `build.zig` file you can get a reference to the package:
```zig
const zig_sx = b.dependency("Zig-SX", .{});
const exe = b.addExecutable(.{
    .name = "my_exe_name",
    .root_source_file = .{ .path = "my_main_file.zig" },
    .target = b.standardTargetOptions(.{}),
    .optimize = b.standardOptimizeOption(.{}),
});
exe.addModule("sx", zig_sx.module("sx"));
```