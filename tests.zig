test "sx.Reader" {
    const str =
        \\(test 1 (1 2)
        \\  2 -3 ( "  
        \\" 4 5 6)
        \\  () a b c
        \\)
        \\
        \\
        \\ true
        \\ 0x20
        \\ 0.35
        \\ unsigned
        \\ "hello world"
        \\ "hello world 2"
        \\ (1 2 3 4)
        \\ (1 2 3)
        \\ nil 1234
        \\ (x) (y 1)
        \\(MyStruct
        \\    (a asdf)
        \\    (b 1)
        \\    (c 2)
        \\)
        \\
        ;
    var stream = std.io.fixedBufferStream(str);
    var reader = sx.reader(std.testing.allocator, stream.reader().any());
    defer reader.deinit();

    var buf: [4096]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);

    var ctx = try reader.token_context();
    try ctx.print_for_string(str, buf_stream.writer(), 80);
    try expectEqualStrings(
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
    try expectEqualStrings(try reader.require_any_expression(), "1");
    try expectEqual(try reader.any_expression(), null);
    try reader.ignore_remaining_expression();
    try expectEqual(try reader.require_any_unsigned(usize, 0), @as(usize, 2));
    try expectEqual(try reader.require_any_int(i8, 0), @as(i8, -3));
    try reader.require_open();

    ctx = try reader.token_context();
    try ctx.print_for_string(str, buf_stream.writer(), 80);
    try expectEqualStrings(
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
    try expectEqualStrings(try reader.require_any_string(), "6");
    try expectEqual(try reader.any_string(), null);
    try expectEqual(try reader.any_float(f32), null);
    try expectEqual(try reader.any_int(u12, 0), null);
    try expectEqual(try reader.any_unsigned(u12, 0), null);
    try reader.require_close();
    try reader.require_open();
    try reader.require_close();
    try reader.ignore_remaining_expression();

    ctx = try reader.token_context();
    try ctx.print_for_string(str, buf_stream.writer(), 80);
    try expectEqualStrings(
        \\   7 |
        \\   8 | true
        \\     | ^^^^
        \\   9 | 0x20
        \\
    , buf_stream.getWritten());
    buf_stream.reset();

    const Ctx = struct {
        pub fn type_name(comptime T: type) []const u8 {
            const raw = @typeName(T);
            if (std.mem.lastIndexOfScalar(u8, raw, '.')) |index| {
                return raw[index + 1 ..];
            }
            return raw;
        }
    };

    try expectEqual(true, try reader.require_object(std.testing.allocator, Ctx, false));
    try expectEqual(0x20, try reader.require_object(std.testing.allocator, Ctx, @as(u8, 0)));
    try expectEqual(0.35, try reader.require_object(std.testing.allocator, Ctx, @as(f64, 0)));
    try expectEqual(std.builtin.Signedness.unsigned, try reader.require_object(std.testing.allocator, Ctx, std.builtin.Signedness.signed));

    var xyz: []const u8 = "";
    xyz = try reader.require_object(std.testing.allocator, Ctx, xyz);
    defer std.testing.allocator.free(xyz);
    try expectEqualStrings("hello world", xyz);

    var ptr: *const []const u8 = &"";
    ptr = try reader.require_object(std.testing.allocator, Ctx, ptr);
    defer std.testing.allocator.destroy(ptr);
    defer std.testing.allocator.free(ptr.*);
    try expectEqualStrings("hello world 2", ptr.*);

    var slice: []const u32 = &.{};
    slice = try reader.require_object(std.testing.allocator, Ctx, slice);
    defer std.testing.allocator.free(slice);
    try expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, slice);

    var arr: [3]u4 = .{ 9, 6, 5 };
    arr = try reader.require_object(std.testing.allocator, Ctx, arr);
    try expectEqualSlices(u4, &.{ 1, 2, 3 }, &arr);

    var opt: ?u32 = null;
    opt = try reader.require_object(std.testing.allocator, Ctx, opt);
    try expectEqual(null, opt);
    opt = try reader.require_object(std.testing.allocator, Ctx, opt);
    try expectEqual(1234, opt);

    const U = union (enum) {
        x,
        y: u32
    };
    var u: U = undefined;
    u = try reader.require_object(std.testing.allocator, Ctx, u);
    try expectEqual(.x, u);
    u = try reader.require_object(std.testing.allocator, Ctx, u);
    try expectEqual(@as(U, .{ .y = 1 }), u);

    const MyStruct = struct {
        a: []const u8 = "",
        b: u8 = 0,
        c: i64 = 0,
    };
    const s = try reader.require_object(std.testing.allocator, Ctx, MyStruct{});
    defer std.testing.allocator.free(s.a);
    try expectEqualStrings("asdf", s.a);
    try expectEqual(1, s.b);
    try expectEqual(2, s.c);

    try reader.require_done();
}

test "sx.Writer" {
    const expected =
      \\(box my-box
      \\   (dimensions 4.3 7 14)
      \\   (color red)
      \\   (contents
      \\      42
      \\      "Big Phil's To Do List:\n - paint it black\n - clean up around the house\n"
      \\      "x y \""
      \\      false
      \\      32
      \\      0.35
      \\      unsigned
      \\      "hello world"
      \\      "hello world 2"
      \\      (1 2 3 4)
      \\      (9 6 5)
      \\      nil
      \\      1234
      \\      (x)
      \\      (y 1)
      \\      (tests.test.sx.Writer.MyStruct
      \\         (a asdf)
      \\         (b 123)
      \\         (c 12355)
      \\      )
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

    const Ctx = struct {};

    try writer.object(Ctx, false);
    try writer.object(Ctx, @as(u8, 0x20));
    try writer.object(Ctx, @as(f64, 0.35));
    try writer.object(Ctx, std.builtin.Signedness.unsigned);

    const xyz: []const u8 = "hello world";
    try writer.object(Ctx, xyz);

    const ptr: *const []const u8 = &"hello world 2";
    try writer.object(Ctx, ptr);

    const slice: []const u32 = &.{ 1, 2, 3, 4 };
    try writer.object(Ctx, slice);

    try writer.object(Ctx, [_]u4 { 9, 6, 5 });

    var opt: ?u32 = null;
    try writer.object(Ctx, opt);
    opt = 1234;
    try writer.object(Ctx, opt);

    const U = union (enum) {
        x,
        y: u32
    };
    var u: U = .x;
    try writer.object(Ctx, u);
    u = .{ .y = 1 };
    try writer.object(Ctx, u);

    const MyStruct = struct {
        a: []const u8 = "",
        b: u8 = 0,
        c: i64 = 0,
    };
    try writer.object(Ctx, MyStruct{
        .a = "asdf",
        .b = 123,
        .c = 12355,
    });

    try writer.done();

    try expectEqualStrings(expected, buf_stream.getWritten());
}

const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const sx = @import("sx");
const std = @import("std");
