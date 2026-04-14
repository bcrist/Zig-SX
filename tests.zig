test "sx.Reader" {
    const str = @embedFile("test/test1.sx");
    var stream = std.Io.Reader.fixed(str);
    var reader = sx.reader(std.testing.allocator, &stream);
    defer reader.deinit();

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    var ctx = try reader.token_context();
    try ctx.print_for_string(str, &w, 80);
    try expectEqualStrings(
        \\   1 |(test 1 (1 2)
        \\     |^^^^^
        \\   2 |  2 -3 ( "  
        \\
    , w.buffered());
    w.end = 0;

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
    try ctx.print_for_string(str, &w, 80);
    try expectEqualStrings(
        \\   1 |(test 1 (1 2)
        \\   2 |  2 -3 ( "  
        \\     |         ^^^
        \\   3 |" 4 5 6)
        \\     |^
        \\   4 |  () a b c
        \\
    , w.buffered());
    w.end = 0;

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
    try ctx.print_for_string(str, &w, 80);
    try expectEqualStrings(
        \\   7 |
        \\   8 | true
        \\     | ^^^^
        \\   9 | 0x20
        \\
    , w.buffered());
    w.end = 0;

    const Ctx = struct {
        pub fn type_name(comptime T: type) []const u8 {
            const raw = @typeName(T);
            if (std.mem.lastIndexOfScalar(u8, raw, '.')) |index| {
                return raw[index + 1 ..];
            }
            return raw;
        }
    };

    try expectEqual(true, try reader.require_object(std.testing.allocator, bool, Ctx));
    try expectEqual(0x20, try reader.require_object(std.testing.allocator, u8, Ctx));
    try expectEqual(0.35, try reader.require_object(std.testing.allocator, f64, Ctx));
    try expectEqual(std.builtin.Signedness.unsigned, try reader.require_object(std.testing.allocator, std.builtin.Signedness, Ctx));

    const xyz = try reader.require_object(std.testing.allocator, []const u8, Ctx);
    defer std.testing.allocator.free(xyz);
    try expectEqualStrings("hello world", xyz);

    const slice = try reader.require_object(std.testing.allocator, []const u32, Ctx);
    defer std.testing.allocator.free(slice);
    try expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, slice);

    const ptr = try reader.require_object(std.testing.allocator, *const []const u8, Ctx);
    defer std.testing.allocator.destroy(ptr);
    defer std.testing.allocator.free(ptr.*);
    try expectEqualStrings("hello world 2", ptr.*);

    const arr = try reader.require_object(std.testing.allocator, [3]u4, Ctx);
    try expectEqualSlices(u4, &.{ 1, 2, 3 }, &arr);

    var opt = try reader.require_object(std.testing.allocator, ?u32, Ctx);
    try expectEqual(null, opt);
    opt = try reader.require_object(std.testing.allocator, ?u32, Ctx);
    try expectEqual(1234, opt);

    const U = union (enum) {
        x,
        y: u32
    };
    var u = try reader.require_object(std.testing.allocator, U, Ctx);
    try expectEqual(.x, u);
    u = try reader.require_object(std.testing.allocator, U, Ctx);
    try expectEqual(@as(U, .{ .y = 1 }), u);

    const MyEnum = enum {
        abc,
        multiple_words,
    };

    const MyStruct = struct {
        a: []const u8 = "",
        b: u8 = 0,
        c: i64 = 0,
        d: MyEnum = .abc,
    };
    const s = try reader.require_object(std.testing.allocator, MyStruct, Ctx);
    defer std.testing.allocator.free(s.a);
    try expectEqualStrings("asdf", s.a);
    try expectEqual(1, s.b);
    try expectEqual(2, s.c);
    try expectEqual(.multiple_words, s.d);

    try reader.require_done();
}

test "sx.Reader from file" {
    // Note: cwd is expected to be the repo root
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, "test/test1.sx", .{});
    defer file.close(std.testing.io);

    var reader_buf: [64]u8 = undefined;
    var file_reader = file.reader(std.testing.io, &reader_buf);

    var reader = sx.reader(std.testing.allocator, &file_reader.interface);
    defer reader.deinit();

    var writer_buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&writer_buf);

    var ctx = try reader.token_context();
    try ctx.print_for_file(&file_reader, &w, 80);
    try expectEqualStrings(
        \\   1 |(test 1 (1 2)
        \\     |^^^^^
        \\   2 |  2 -3 ( "  
        \\
    , w.buffered());
    w.end = 0;

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
    try ctx.print_for_file(&file_reader, &w, 80);
    try expectEqualStrings(
        \\   1 |(test 1 (1 2)
        \\   2 |  2 -3 ( "  
        \\     |         ^^^
        \\   3 |" 4 5 6)
        \\     |^
        \\   4 |  () a b c
        \\
    , w.buffered());
    w.end = 0;

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
    try ctx.print_for_file(&file_reader, &w, 80);
    try expectEqualStrings(
        \\   7 |
        \\   8 | true
        \\     | ^^^^
        \\   9 | 0x20
        \\
    , w.buffered());
    w.end = 0;
}

test "sx.Writer" {
    const expected = @embedFile("test/test2.sx");

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    var writer = sx.writer(std.testing.allocator, &w);
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
    writer.set_compact(false);
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

    try writer.object(false, Ctx);
    try writer.object(@as(u8, 0x20), Ctx);
    try writer.object(@as(f64, 0.35), Ctx);
    try writer.object(std.builtin.Signedness.unsigned, Ctx);

    const xyz: []const u8 = "hello world";
    try writer.object(xyz, Ctx);

    const ptr: *const []const u8 = &"hello world 2";
    try writer.object(ptr, Ctx);

    const slice: []const u32 = &.{ 1, 2, 3, 4 };
    try writer.object(slice, Ctx);

    try writer.object([_]u4 { 9, 6, 5 }, Ctx);

    var opt: ?u32 = null;
    try writer.object(opt, Ctx);
    opt = 1234;
    try writer.object(opt, Ctx);

    const U = union (enum) {
        x,
        y: u32
    };
    var u: U = .x;
    try writer.object(u, Ctx);
    u = .{ .y = 1 };
    try writer.object(u, Ctx);

    writer.set_compact(true);

    const MyEnum = enum {
        abc,
        multiple_words,
    };
    const MyStruct = struct {
        a: []const u8 = "",
        b: u8 = 0,
        c: i64 = 0,
        d: MyEnum = .abc,
    };
    try writer.object(MyStruct{
        .a = "asdf",
        .b = 123,
        .c = 12355,
        .d = .multiple_words,
    }, Ctx);

    writer.set_compact(false);

    try writer.done();

    try expectEqualStrings(expected, w.buffered());
}


const Inline_Fields_Struct = struct {
    a: []const u8 = "",
    inline_items: []const []const u8 = &.{},
    misc: u32 = 0,
    multi: []const u32 = &.{},
};

const Inline_Fields_Ctx = struct {
    pub const inline_fields = &.{ "a", "inline_items" };
};

test "read struct with inline fields" {
    const str =
        \\asdf abc 123
        \\(multi 1)
        \\(misc 5678)
        \\(multi 7)
        \\(multi 1234)
        \\
        ;
    var r = std.Io.Reader.fixed(str);
    var reader = sx.reader(std.testing.allocator, &r);
    defer reader.deinit();

    const result = try reader.require_object(std.testing.allocator, Inline_Fields_Struct, Inline_Fields_Ctx);
    defer std.testing.allocator.free(result.a);
    defer std.testing.allocator.free(result.inline_items);
    defer for(result.inline_items) |item| {
        std.testing.allocator.free(item);
    };
    defer std.testing.allocator.free(result.multi);

    try expectEqualStrings("asdf", result.a);
    try expectEqual(2, result.inline_items.len);
    try expectEqualStrings("abc", result.inline_items[0]);
    try expectEqualStrings("123", result.inline_items[1]);

    try expectEqual(5678, result.misc);
    try expectEqual(3, result.multi.len);
    try expectEqual(1, result.multi[0]);
    try expectEqual(7, result.multi[1]);
    try expectEqual(1234, result.multi[2]);
}

test "write struct with inline fields" {
     const expected =
        \\asdf
        \\abc
        \\123
        \\(misc 5678)
        \\(multi 1)
        \\(multi 7)
        \\(multi 1234)
        ;

    const obj: Inline_Fields_Struct = .{
        .a = "asdf",
        .inline_items = &.{ "abc", "123" },
        .misc = 5678,
        .multi = &.{ 1, 7, 1234 },
    };

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    var writer = sx.writer(std.testing.allocator, &w);
    defer writer.deinit();

    try writer.object(obj, Inline_Fields_Ctx);
    try writer.done();

    try expectEqualStrings(expected, w.buffered());
}

fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    var i_expected: usize = 0;
    var i_actual: usize = 0;

    while (true) {
        while (i_expected < expected.len and expected[i_expected] == '\r') i_expected += 1;
        while (i_actual < actual.len and actual[i_actual] == '\r') i_actual += 1;
        if (i_expected >= expected.len or i_actual >= actual.len) break;

        if (expected[i_expected] != actual[i_actual]) break;

        i_expected += 1;
        i_actual += 1;
    }

    if (i_expected < expected.len or i_actual < actual.len) {
        if (@inComptime()) {
            @compileError(std.fmt.comptimePrint("\nexpected:\n{s}\nfound:\n{s}\ndifference starts at index {d}/{d}", .{
                expected, actual, i_expected, i_actual,
            }));
        }
        print("\n====== expected this output: =========\n", .{});
        printWithVisibleNewlines(expected);
        print("\n======== instead found this: =========\n", .{});
        printWithVisibleNewlines(actual);
        print("\n======================================\n", .{});

        var diff_line_number: usize = 1;
        for (expected[0..i_expected]) |value| {
            if (value == '\n') diff_line_number += 1;
        }
        print("First difference occurs on line {d}:\n", .{diff_line_number});

        print("expected:\n", .{});
        printIndicatorLine(expected, i_expected);

        print("found:\n", .{});
        printIndicatorLine(actual, i_actual);

        return error.TestExpectedEqual;
    }
}

fn printIndicatorLine(source: []const u8, indicator_index: usize) void {
    const line_begin_index = if (std.mem.lastIndexOfScalar(u8, source[0..indicator_index], '\n')) |line_begin|
        line_begin + 1
    else
        0;
    const line_end_index = if (std.mem.findScalar(u8, source[indicator_index..], '\n')) |line_end|
        (indicator_index + line_end)
    else
        source.len;

    printLine(source[line_begin_index..line_end_index]);
    for (line_begin_index..indicator_index) |_|
        print(" ", .{});
    if (indicator_index >= source.len)
        print("^ (end of string)\n", .{})
    else
        print("^ ('\\x{x:0>2}')\n", .{source[indicator_index]});
}

fn printWithVisibleNewlines(source: []const u8) void {
    var i: usize = 0;
    while (std.mem.findScalar(u8, source[i..], '\n')) |nl| : (i += nl + 1) {
        printLine(source[i..][0..nl]);
    }
    print("{s}␃\n", .{source[i..]}); // End of Text symbol (ETX)
}

fn printLine(line: []const u8) void {
    if (line.len != 0) switch (line[line.len - 1]) {
        ' ', '\t' => return print("{s}⏎\n", .{line}), // Return symbol
        else => {},
    };
    print("{s}\n", .{line});
}

fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else if (std.testing.backend_can_print) {
        std.debug.print(fmt, args);
    }
}

const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const sx = @import("sx");
const std = @import("std");
