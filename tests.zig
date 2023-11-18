test "sx.Reader" {
    var str =
        \\(test 1 (1 2)
        \\  2 -3 ( "  
        \\" 4 5 6)
        \\  () a b c
        \\)
        ;
    var stream = std.io.fixedBufferStream(str);
    var reader = sx.reader(std.testing.allocator, stream.reader());
    defer reader.deinit();

    var buf: [4096]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);

    var ctx = try reader.token_context();
    try ctx.print_for_string(str, buf_stream.writer(), 80);
    try expectEqualSlices(u8,
        \\   1 |(test 1 (1 2)
        \\     |^^^^^
        \\   2 |  2 -3 ( "  
        \\
    , buf_stream.getWritten());
    buf_stream.reset();

    try expectEqual(try reader.expression("asdf"), false);
    try reader.require_expression("test");
    try expectEqual(try reader.open(), false);
    try expectEqual(try reader.close(), false);
    try expectEqual(try reader.require_any_unsigned(usize, 10), @as(usize, 1));
    try expectEqualSlices(u8, try reader.require_any_expression(), "1");
    try expectEqual(try reader.any_expression(), null);
    try reader.ignore_remaining_expression();
    try expectEqual(try reader.require_any_unsigned(usize, 0), @as(usize, 2));
    try expectEqual(try reader.require_any_int(i8, 0), @as(i8, -3));
    try reader.require_open();

    ctx = try reader.token_context();
    try ctx.print_for_string(str, buf_stream.writer(), 80);
    try expectEqualSlices(u8,
        \\   1 |(test 1 (1 2)
        \\   2 |  2 -3 ( "  
        \\     |         ^^^
        \\   3 |" 4 5 6)
        \\     |^
        \\   4 |  () a b c
        \\
    , buf_stream.getWritten());
    buf_stream.reset();

    try reader.require_string("  \n");
    try expectEqual(try reader.string("x"), false);
    try reader.require_string("4");
    try expectEqual(try reader.require_any_float(f32), @as(f32, 5));
    try expectEqualSlices(u8, try reader.require_any_string(), "6");
    try expectEqual(try reader.any_string(), null);
    try expectEqual(try reader.any_float(f32), null);
    try expectEqual(try reader.any_int(u12, 0), null);
    try expectEqual(try reader.any_unsigned(u12, 0), null);
    try reader.require_close();
    try reader.require_open();
    try reader.require_close();
    try reader.ignore_remaining_expression();
    try reader.require_done();

    ctx = try reader.token_context();
    try ctx.print_for_string(str, buf_stream.writer(), 80);
    try expectEqualSlices(u8,
        \\   4 |  () a b c
        \\   5 |)
        \\
    , buf_stream.getWritten());
    buf_stream.reset();

}

test "sx.Writer" {
    var expected =
      \\(box my-box
      \\   (dimensions 4.3 7 14)
      \\   (color red)
      \\   (contents
      \\      42
      \\      "Big Phil's To Do List:\n - paint it black\n - clean up around the house\n"
      \\      "x y \""
      \\   )
      \\)
    ;

    var buf: [4096]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);

    var writer = sx.writer(std.testing.allocator, buf_stream.writer());
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
    try writer.print_value("x y \"", .{});

    try writer.done();

    try expectEqualSlices(u8, expected, buf_stream.getWritten());
}

const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const sx = @import("sx");
const std = @import("std");
