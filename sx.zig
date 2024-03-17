pub fn writer(allocator: std.mem.Allocator, anywriter: std.io.AnyWriter) Writer {
    return Writer.init(allocator, anywriter);
}

pub fn reader(allocator: std.mem.Allocator, anyreader: std.io.AnyReader) Reader {
    return Reader.init(allocator, anyreader);
}

pub const Writer = struct {
    inner: std.io.AnyWriter,
    indent: []const u8,
    compact_state: std.ArrayList(bool),
    first_in_group: bool,

    pub fn init(allocator: std.mem.Allocator, inner_writer: std.io.AnyWriter) Writer {
        return .{
            .inner = inner_writer,
            .indent = "   ",
            .compact_state = std.ArrayList(bool).init(allocator),
            .first_in_group = true,
        };
    }

    pub fn deinit(self: *Writer) void {
        self.compact_state.deinit();
    }

    fn spacing(self: *Writer) !void {
        const cs = self.compact_state;
        if (cs.items.len > 0 and cs.items[cs.items.len - 1]) {
            if (self.first_in_group) {
                self.first_in_group = false;
            } else {
                try self.inner.writeByte(' ');
            }
        } else {
            if (cs.items.len > 0 or !self.first_in_group) {
                try self.inner.writeByte('\n');
                for (self.compact_state.items) |_| {
                    try self.inner.writeAll(self.indent);
                }
            }
            if (self.first_in_group) {
                self.first_in_group = false;
            }
        }
    }

    pub fn open(self: *Writer) !void {
        try self.spacing();
        try self.inner.writeByte('(');
        try self.compact_state.append(true);
        self.first_in_group = true;
    }

    pub fn open_expanded(self: *Writer) !void {
        try self.spacing();
        try self.inner.writeByte('(');
        try self.compact_state.append(false);
        self.first_in_group = true;
    }

    pub fn close(self: *Writer) !void {
        if (self.compact_state.items.len > 0) {
            if (!self.compact_state.pop() and !self.first_in_group) {
                try self.inner.writeByte('\n');
                for (self.compact_state.items) |_| {
                    try self.inner.writeAll(self.indent);
                }
            }
            try self.inner.writeByte(')');
        }
        self.first_in_group = false;
    }

    pub fn done(self: *Writer) !void {
        while (self.compact_state.items.len > 0) {
            try self.close();
        }
    }

    pub fn set_compact(self: *Writer, compact: bool) void {
        if (self.compact_state.items.len > 0) {
            self.compact_state.items[self.compact_state.items.len - 1] = compact;
        }
    }

    pub fn expression(self: *Writer, name: []const u8) !void {
        try self.open();
        try self.string(name);
    }

    pub fn expression_expanded(self: *Writer, name: []const u8) !void {
        try self.open();
        try self.string(name);
        self.set_compact(false);
    }

    fn requires_quotes(str: []const u8) bool {
        if (str.len == 0) return true;
        for (str) |c| {
            if (c <= ' ' or c > '~' or c == '(' or c == ')' or c == '"') {
                return true;
            }
        }
        return false;
    }

    pub fn string(self: *Writer, str: []const u8) !void {
        try self.spacing();
        if (requires_quotes(str)) {
            try self.inner.writeByte('"');
            _ = try self.write_escaped(str);
            try self.inner.writeByte('"');
        } else {
            try self.inner.writeAll(str);
        }
    }

    pub fn float(self: *Writer, val: anytype) !void {
        try self.spacing();
        try std.fmt.formatFloatDecimal(val, .{}, self.inner);
    }

    pub fn int(self: *Writer, val: anytype, radix: u8) !void {
        try self.spacing();
        try std.fmt.formatInt(val, radix, std.fmt.Case.upper, .{}, self.inner);
    }

    pub fn boolean(self: *Writer, val: bool) !void {
        try self.spacing();
        const str = if (val) "true" else "false";
        try self.inner.writeAll(str);
    }

    pub fn tag(self: *Writer, val: anytype) !void {
        return self.string(@tagName(val));
    }

    pub fn object(self: *Writer, obj: anytype, comptime Context: type) anyerror!void {
        const T = @TypeOf(obj);
        switch (@typeInfo(T)) {
            .Bool => try self.boolean(obj),
            .Int => try self.int(obj, 10),
            .Float => try self.float(obj),
            .Enum => try self.tag(obj),
            .Void => {},
            .Pointer => |info| {
                if (info.size == .Slice) {
                    if (info.child == u8) {
                        try self.string(obj);
                    } else {
                        for (obj) |item| {
                            try self.object(item, Context);
                        }
                    }
                } else {
                    try self.object(obj.*, Context);
                }
            },
            .Array => {
                for (&obj) |el| {
                    try self.object(el, Context);
                }
            },
            .Optional => {
                if (obj) |val| {
                    try self.object(val, Context);
                } else {
                    try self.string("nil");
                }
            },
            .Union => |info| {
                std.debug.assert(info.tag_type != null);
                const tag_name = @tagName(obj);
                try self.string(tag_name);
                inline for (info.fields) |field| {
                    if (field.type != void and std.mem.eql(u8, tag_name, field.name)) {
                        try self.object_child(@field(obj, field.name), false, field.name, Context);
                    }
                }
            },
            .Struct => |info| {
                const inline_fields: []const []const u8 = if (@hasDecl(Context, "inline_fields")) @field(Context, "inline_fields") else &.{};
                inline for (inline_fields) |field_name| {
                    try self.object_child(@field(obj, field_name), false, field_name, Context);
                }
                inline for (info.fields) |field| {
                    if (!field.is_comptime) {
                        if (!inline for (inline_fields) |inline_field_name| {
                            if (comptime std.mem.eql(u8, inline_field_name, field.name)) break true;
                        } else false) {
                            try self.object_child(@field(obj, field.name), true, field.name, Context);
                        }
                    }
                }
            },
            else => @compileError("Unsupported type"),
        }
    }

    fn object_child(self: *Writer, child: anytype, wrap: bool, comptime field_name: []const u8, comptime Parent_Context: type) anyerror!void {
        const Child_Context = if (@hasDecl(Parent_Context, field_name)) @field(Parent_Context, field_name) else struct{};
        switch (@typeInfo(@TypeOf(Child_Context))) {
            .Fn => try Child_Context(child, self, wrap),
            .Type => switch (@typeInfo(@TypeOf(child))) {
                .Pointer => |info| {
                    if (info.size == .Slice) {
                        if (info.child == u8) {
                            if (wrap) try self.open_for_object_child(field_name, @TypeOf(child), Child_Context);
                            try self.string(child);
                            if (wrap) try self.close();
                        } else {
                            for (child) |item| {
                                try self.object_child(item, wrap, field_name, Parent_Context);
                            }
                        }
                    } else {
                        try self.object_child(child.*, wrap, field_name, Parent_Context);
                    }
                },
                .Array => {
                    for (&child) |item| {
                        try self.object_child(item, wrap, field_name, Parent_Context);
                    }
                },
                .Optional => {
                    if (child) |item| {
                        try self.object_child(item, wrap, field_name, Parent_Context);
                    }
                },
                else => {
                    if (wrap) try self.open_for_object_child(field_name, @TypeOf(child), Child_Context);
                    try self.object(child, Child_Context);
                    if (wrap) try self.close();
                },
            },
            .Pointer => |child_context_ptr_info| {
                // Child_Context is a comptime constant format string
                std.debug.assert(child_context_ptr_info.size == .Slice);
                std.debug.assert(child_context_ptr_info.child == u8);
                switch (@typeInfo(@TypeOf(child))) {
                    .Pointer => |info| {
                        if (info.size == .Slice) {
                            if (wrap) try self.open_for_object_child(field_name, @TypeOf(child), Child_Context);
                            try self.print_value("{" ++ Child_Context ++ "}", .{ child });
                            if (wrap) try self.close();
                        } else {
                            try self.object_child(child.*, wrap, field_name, Parent_Context);
                        }
                    },
                    else => {
                        if (wrap) try self.open_for_object_child(field_name, @TypeOf(child), Child_Context);
                        try self.print_value("{" ++ Child_Context ++ "}", .{ child });
                        if (wrap) try self.close();
                    },
                }
            },
            else => @compileError("Expected child context to be a struct, function, or format string declaration"),
        }
    }

    fn open_for_object_child(self: *Writer, field_name: []const u8, comptime Child: type, comptime Child_Context: type) !void {
        try self.expression(field_name);
        if (@hasDecl(Child_Context, "compact")) {
            self.set_compact(@field(Child_Context, "compact"));
        } else {
            self.set_compact(!is_big_type(Child));
        }
    }

    pub fn print_value(self: *Writer, comptime format: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        try self.string(std.fmt.bufPrint(&buf, format, args) catch |e| switch (e) {
            error.NoSpaceLeft => {
                try self.inner.writeByte('"');
                const EscapeWriter = std.io.Writer(*Writer, anyerror, write_escaped);
                var esc = EscapeWriter { .context = self };
                try esc.print(format, args);
                try self.inner.writeByte('"');
                return;
            },
            else => return e,
        });
    }

    fn write_escaped(self: *Writer, bytes: []const u8) anyerror!usize {
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            var c = bytes[i];
            if (c == '"' or c == '\\') {
                try self.inner.writeByte('\\');
                try self.inner.writeByte(c);
            } else if (c < ' ') {
                if (c == '\n') {
                    try self.inner.writeAll("\\n");
                } else if (c == '\r') {
                    try self.inner.writeAll("\\r");
                } else if (c == '\t') {
                    try self.inner.writeAll("\\t");
                } else {
                    try self.inner.writeByte(c);
                }
            } else {
                var j = i + 1;
                while (j < bytes.len) : (j += 1) {
                    c = bytes[j];
                    switch (c) {
                        '"', '\\', '\n', '\r', '\t' => break,
                        else => {},
                    }
                }
                try self.inner.writeAll(bytes[i..j]);
                i = j - 1;
            }
        }
        return bytes.len;
    }

    pub fn print_raw(self: *Writer, comptime format: []const u8, args: anytype) !void {
        try self.spacing();
        try self.inner.print(format, args);
    }

};

pub const Reader = struct {
    const State = enum(u8) {
        unknown = 0,
        open = 1,
        close = 2,
        val = 3,
        eof = 4
    };

    inner: std.io.AnyReader,
    next_byte: ?u8,
    token: std.ArrayList(u8),
    compact: bool,
    peek: bool,
    state: State,
    ctx: Context_Data,
    line_offset: usize,
    val_start_ctx: Context_Data,
    token_start_ctx: Context_Data,

    const Context_Data = struct {
        offset: usize = 0,
        prev_line_offset: usize = 0,
        line_number: usize = 1,
    };

    pub fn init(allocator: std.mem.Allocator, inner_reader: std.io.AnyReader) Reader {
        return .{
            .inner = inner_reader,
            .next_byte = null,
            .token = std.ArrayList(u8).init(allocator),
            .compact = true,
            .peek = false,
            .state = .unknown,
            .ctx = .{},
            .line_offset = 0,
            .val_start_ctx = .{},
            .token_start_ctx = .{},
        };
    }

    pub fn deinit(self: *Reader) void {
        self.token.deinit();
    }

    fn consume_byte(self: *Reader) anyerror!?u8 {
        var b = self.next_byte;
        if (b == null) {
            b = self.inner.readByte() catch |err| {
                if (err == error.EndOfStream) {
                    return null;
                } else {
                    return err;
                }
            };
        } else {
            self.next_byte = null;
        }
        self.ctx.offset += 1;
        return b;
    }

    fn put_back_byte(self: *Reader, b: u8) void {
        self.next_byte = b;
        self.ctx.offset -= 1;
    }

    fn skip_whitespace(self: *Reader, include_newlines: bool) anyerror!void {
        if (include_newlines) {
            self.compact = true;
        }
        while (try self.consume_byte()) |b| {
            switch (b) {
                '\n' => {
                    if (include_newlines) {
                        self.ctx.line_number += 1;
                        self.ctx.prev_line_offset = self.line_offset;
                        self.line_offset = self.ctx.offset;
                        self.compact = false;
                    } else {
                        self.put_back_byte(b);
                        return;
                    }
                },
                33...255 => {
                    self.put_back_byte(b);
                    return;
                },
                else => {}
            }
        }
    }

    fn read_unquoted_val(self: *Reader) anyerror!void {
        self.token.clearRetainingCapacity();

        while (try self.consume_byte()) |b| {
            switch (b) {
                0...' ', '(', ')', '"' => {
                    self.put_back_byte(b);
                    return;
                },
                else => {
                    try self.token.append(b);
                },
            }
        }
    }

    fn read_quoted_val(self: *Reader) anyerror!void {
        self.token.clearRetainingCapacity();

        var in_escape = false;
        while (try self.consume_byte()) |b| {
            if (b == '\n') {
                self.ctx.line_number += 1;
                self.ctx.prev_line_offset = self.line_offset;
                self.line_offset = self.ctx.offset;
            } else if (b == '\r') {
                // CR must be escaped as \r if you want it in a literal, otherwise CRLF will be turned into just LF
                continue;
            }
            if (in_escape) {
                try self.token.append(switch (b) {
                    't' => '\t',
                    'n' => '\n',
                    'r' => '\r',
                    else => b,
                });
                in_escape = false;
            } else switch (b) {
                '\\' => in_escape = true,
                '"' => return,
                else => try self.token.append(b),
            }
        }
    }

    fn read(self: *Reader) anyerror!void {
        try self.skip_whitespace(true);
        self.token_start_ctx = self.ctx;
        if (try self.consume_byte()) |b| {
            switch (b) {
                '(' => {
                    try self.skip_whitespace(false);
                    self.val_start_ctx = self.ctx;
                    if (try self.consume_byte()) |q| {
                        if (q == '"') {
                            try self.read_quoted_val();
                        } else {
                            self.put_back_byte(q);
                            try self.read_unquoted_val();
                        }
                    } else {
                        self.token.clearRetainingCapacity();
                    }
                    self.state = .open;
                },
                ')' => {
                    self.state = .close;
                },
                '"' => {
                    try self.read_quoted_val();
                    self.state = .val;
                },
                else => {
                    self.put_back_byte(b);
                    try self.read_unquoted_val();
                    self.state = .val;
                },
            }
        } else {
            self.state = .eof;
            return;
        }
    }

    pub fn is_compact(self: *Reader) anyerror!bool {
        if (self.state == .unknown) {
            try self.read();
        }
        return self.compact;
    }

    pub fn set_peek(self: *Reader, peek: bool) void {
        self.peek = peek;
    }

    pub fn any(self: *Reader) anyerror!void {
        if (!self.peek) {
            if (self.state == .unknown) {
                try self.read();
            }
            self.state = .unknown;
        }
    }

    pub fn open(self: *Reader) anyerror!bool {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .open) {
            if (self.peek) return true;

            if (self.token.items.len > 0) {
                self.token_start_ctx = self.val_start_ctx;
                self.state = .val;
                self.compact = true;
            } else {
                try self.any();
            }
            return true;
        } else {
            return false;
        }
    }

    pub fn require_open(self: *Reader) anyerror!void {
        if (!try self.open()) {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn close(self: *Reader) anyerror!bool {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .close) {
            try self.any();
            return true;
        } else {
            return false;
        }
    }

    pub fn require_close(self: *Reader) anyerror!void {
        if (!try self.close()) {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn done(self: *Reader) anyerror!bool {
        if (self.state == .unknown) {
            try self.read();
        }

        return self.state == .eof;
    }

    pub fn require_done(self: *Reader) anyerror!void {
        if (!try self.done()) {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn expression(self: *Reader, expected: []const u8) anyerror!bool {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .open and std.mem.eql(u8, self.token.items, expected)) {
            try self.any();
            return true;
        } else {
            return false;
        }
    }

    pub fn require_expression(self: *Reader, expected: []const u8) anyerror!void {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .open and std.mem.eql(u8, self.token.items, expected)) {
            try self.any();
        } else {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn any_expression(self: *Reader) anyerror!?[]const u8 {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .open) {
            try self.any();
            return self.token.items;
        } else {
            return null;
        }
    }

    pub fn require_any_expression(self: *Reader) anyerror![]const u8 {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .open) {
            try self.any();
            return self.token.items;
        } else {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn string(self: *Reader, expected: []const u8) anyerror!bool {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .val and std.mem.eql(u8, self.token.items, expected)) {
            try self.any();
            return true;
        } else {
            return false;
        }
    }
    pub fn require_string(self: *Reader, expected: []const u8) anyerror!void {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .val and std.mem.eql(u8, self.token.items, expected)) {
            try self.any();
        } else {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn any_string(self: *Reader) anyerror!?[]const u8 {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .val) {
            try self.any();
            return self.token.items;
        } else {
            return null;
        }
    }
    pub fn require_any_string(self: *Reader) anyerror![]const u8 {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .val) {
            try self.any();
            return self.token.items;
        } else {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn any_boolean(self: *Reader) anyerror!?bool {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state != .val) {
            return null;
        }

        if (self.token.items.len <= 5) {
            var buf: [5]u8 = undefined;
            const lower = std.ascii.lowerString(&buf, self.token.items);
            if (std.mem.eql(u8, lower, "true")) {
                try self.any();
                return true;
            } else if (std.mem.eql(u8, lower, "false")) {
                try self.any();
                return false;
            }
        }

        const value = 0 != (std.fmt.parseUnsigned(u1, self.token.items, 0) catch return null);
        try self.any();
        return value;
    }
    pub fn require_any_boolean(self: *Reader) anyerror!bool {
        return try self.any_boolean() orelse error.SExpressionSyntaxError;
    }

    pub fn any_enum(self: *Reader, comptime T: type) anyerror!?T {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state != .val) {
            return null;
        }

        if (std.meta.stringToEnum(T, self.token.items)) |e| {
            try self.any();
            return e;
        }

        return null;
    }
    pub fn require_any_enum(self: *Reader, comptime T: type) anyerror!T {
        return try self.any_enum(T) orelse error.SExpressionSyntaxError;
    }

    // Takes a std.ComptimeStringMap to convert strings into the enum
    pub fn map_enum(self: *Reader, comptime T: type, map: anytype) anyerror!?T {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state != .val) {
            return null;
        }

        if (map.get(self.token.items)) |e| {
            try self.any();
            return e;
        }

        return null;
    }

    pub fn require_map_enum(self: *Reader, comptime T: type, map: anytype) anyerror!T {
        return try self.map_enum(T, map) orelse error.SExpressionSyntaxError;
    }

    pub fn any_float(self: *Reader, comptime T: type) anyerror!?T {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state != .val) {
            return null;
        }

        const value = std.fmt.parseFloat(T, self.token.items) catch return null;
        try self.any();
        return value;
    }
    pub fn require_any_float(self: *Reader, comptime T: type) anyerror!T {
        return try self.any_float(T) orelse error.SExpressionSyntaxError;
    }

    pub fn any_int(self: *Reader, comptime T: type, radix: u8) anyerror!?T {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state != .val) {
            return null;
        }

        const value = std.fmt.parseInt(T, self.token.items, radix) catch return null;
        try self.any();
        return value;
    }
    pub fn require_any_int(self: *Reader, comptime T: type, radix: u8) anyerror!T {
        return try self.any_int(T, radix) orelse error.SExpressionSyntaxError;
    }

    pub fn any_unsigned(self: *Reader, comptime T: type, radix: u8) anyerror!?T {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state != .val) {
            return null;
        }

        const value = std.fmt.parseUnsigned(T, self.token.items, radix) catch return null;
        try self.any();
        return value;
    }
    pub fn require_any_unsigned(self: *Reader, comptime T: type, radix: u8) anyerror!T {
        return try self.any_unsigned(T, radix) orelse error.SExpressionSyntaxError;
    }


    pub fn object(self: *Reader, arena: std.mem.Allocator, comptime T: type, comptime Context: type) anyerror!?T {
        const obj: T = switch (@typeInfo(T)) {
            .Bool => if (try self.any_boolean()) |val| val else return null,
            .Int => if (try self.any_int(T, 0)) |val| val else return null,
            .Float => if (try self.any_float(T)) |val| val else return null,
            .Enum => if (try self.any_enum(T)) |val| val else return null,
            .Void => {},
            .Pointer => |info| blk: {
                if (info.size == .Slice) {
                    if (info.child == u8) {
                        if (try self.any_string()) |val| {
                            break :blk try arena.dupe(u8, val);
                        } else return null;
                    } else {
                        var temp = std.ArrayList(info.child).init(self.token.allocator);
                        defer temp.deinit();
                        var i: usize = 0;
                        while (true) : (i += 1) {
                            if (try self.object(arena, info.child, Context)) |raw| {
                                try temp.append(raw);
                            } else break;
                        }
                        break :blk try arena.dupe(info.child, temp.items);
                    }
                } else if (try self.object(arena, info.child, Context)) |raw| {
                    const ptr = try arena.create(info.child);
                    ptr.* = raw;
                    break :blk ptr;
                } else return null;
            },
            .Array => |info| blk: {
                var a: T = undefined;
                if (info.len > 0) {
                    if (try self.object(arena, info.child, Context)) |raw| {
                        a[0] = raw;
                    } else return null;
                    for (a[1..]) |*el| {
                        el.* = try self.require_object(arena, info.child, Context);
                    }
                }
                break :blk a;
            },
            .Optional => |info| blk: {
                if (try self.string("nil")) {
                    break :blk null;
                } else if (try self.object(arena, info.child, Context)) |raw| {
                    break :blk raw;
                } else return null;
            },
            .Union => |info| blk: {
                std.debug.assert(info.tag_type != null);
                var obj: ?T = null;
                inline for (info.fields) |field| {
                    if (obj == null and try self.string(field.name)) {
                        const value = try self.require_object_child(arena, field.type, false, field.name, Context);
                        obj = @unionInit(T, field.name, value);
                    }
                }
                if (obj) |o| break :blk o;
                return null;
            },
            .Struct => |info| blk: {
                var temp: ArrayList_Struct(T) = .{};
                defer inline for (@typeInfo(@TypeOf(temp)).Struct.fields) |field| {
                    @field(temp, field.name).deinit(self.token.allocator);
                };

                try self.parse_struct_fields(arena, T, &temp, Context);

                var obj: T = .{};
                inline for (info.fields) |field| {
                    const arraylist_ptr = &@field(temp, field.name);
                    if (arraylist_ptr.items.len > 0) {
                        const Unwrapped = @TypeOf(arraylist_ptr.items[0]);
                        if (field.type == Unwrapped) {
                            @field(obj, field.name) = arraylist_ptr.items[0];
                        } else switch (@typeInfo(field.type)) {
                            .Array => |arr_info| {
                                const slice: []arr_info.child = &@field(obj, field.name);
                                @memcpy(slice.data, arraylist_ptr.items);
                            },
                            .Pointer => |ptr_info| {
                                if (ptr_info.size == .Slice) {
                                    @field(obj, field.name) = try arena.dupe(Unwrapped, arraylist_ptr.items);
                                } else {
                                    const ptr = try arena.create(ptr_info.child);
                                    ptr.* = arraylist_ptr.items[0];
                                    @field(obj, field.name) = ptr;
                                }
                            },
                            .Optional => {
                                @field(obj, field.name) = arraylist_ptr.items[0];
                            },
                            else => unreachable,
                        }
                    }
                }
                break :blk obj;
            },
            else => @compileError("Unsupported type"),
        };

        if (@hasDecl(Context, "validate")) {
            const fun = @field(Context, "validate");
            try fun(&obj, arena);
        }

        return obj;
    }
    pub fn require_object(self: *Reader, arena: std.mem.Allocator, comptime T: type, comptime Context: type) anyerror!T {
        return (try self.object(arena, T, Context)) orelse error.SExpressionSyntaxError;
    }

    fn parse_struct_fields(self: *Reader, arena: std.mem.Allocator, comptime T: type, temp: *ArrayList_Struct(T), comptime Context: type) anyerror!void {
        const struct_fields = @typeInfo(T).Struct.fields;

        const inline_fields: []const []const u8 = if (@hasDecl(Context, "inline_fields")) @field(Context, "inline_fields") else &.{};
        inline for (inline_fields) |field_name| {
            const Unwrapped = @TypeOf(@field(temp, field_name).items[0]);
            const field = struct_fields[std.meta.fieldIndex(T, field_name).?];
            const max_children = max_child_items(field.type);

            var i: usize = 0;
            while (max_children == null or i < max_children.?) : (i += 1) {
                const arraylist_ptr = &@field(temp.*, field_name);
                try arraylist_ptr.ensureUnusedCapacity(self.token.allocator, 1);
                if (try self.object_child(arena, Unwrapped, false, field_name, Context)) |raw| {
                    arraylist_ptr.appendAssumeCapacity(raw);
                } else break;
            }
        }

        while (true) {
            var found_field = false;
            inline for (struct_fields) |field| {
                if (!field.is_comptime) {
                    const arraylist_ptr = &@field(temp.*, field.name);
                    const check_this_field = if (max_child_items(field.type)) |max| arraylist_ptr.items.len < max else true;
                    if (check_this_field) {
                        const Unwrapped = @TypeOf(@field(temp, field.name).items[0]);
                        try @field(temp.*, field.name).ensureUnusedCapacity(self.token.allocator, 1);
                        if (try self.object_child(arena, Unwrapped, true, field.name, Context)) |raw| {
                            @field(temp.*, field.name).appendAssumeCapacity(raw);
                            found_field = true;
                        }
                    }
                }
            }

            if (!found_field) break;
        }
    }

    fn object_child(self: *Reader, arena: std.mem.Allocator, comptime T: type, wrap: bool, comptime field_name: []const u8, comptime Parent_Context: type) anyerror!?T {
        const Child_Context = if (@hasDecl(Parent_Context, field_name)) @field(Parent_Context, field_name) else struct{};
        switch (@typeInfo(@TypeOf(Child_Context))) {
            .Fn => return Child_Context(arena, self, wrap),
            .Type => {
                if (wrap) {
                    if (try self.expression(field_name)) {
                        const value = try self.require_object(arena, T, Child_Context);
                        try self.require_close();
                        return value;
                    } else return null;
                } else {
                    return self.object(arena, T, Child_Context);
                }
            },
            .Pointer => |child_context_ptr_info| {
                // Child_Context is a comptime constant format string
                std.debug.assert(child_context_ptr_info.size == .Slice);
                std.debug.assert(child_context_ptr_info.child == u8);
                if (wrap) {
                    if (try self.expression(field_name)) {
                        const value = try T.from_string(Child_Context, try self.require_any_string());
                        try self.require_close();
                        return value;
                    } else return null;
                } else {
                    if (try self.any_string()) |raw| {
                        return T.from_string(Child_Context, raw);
                    } else return null;
                }
            },
            else => @compileError("Expected child context to be a struct or function declaration"),
        }
    }
    fn require_object_child(self: *Reader, arena: std.mem.Allocator, comptime T: type, wrap: bool, comptime field_name: []const u8, comptime Parent_Context: type) anyerror!T {
        return (try self.object_child(arena, T, wrap, field_name, Parent_Context)) orelse error.SExpressionSyntaxError;
    }

    // note this consumes the current expression's closing parenthesis
    pub fn ignore_remaining_expression(self: *Reader) anyerror!void {
        var depth: usize = 1;
        while (self.state != .eof and depth > 0) {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state == .close) {
                depth -= 1;
            } else if (self.state == .open) {
                depth += 1;
            }
            try self.any();
        }
    }

    pub fn token_context(self: *Reader) anyerror!Token_Context {
        if (self.state == .unknown) {
            try self.read();
        }
        return Token_Context {
            .prev_line_offset = self.token_start_ctx.prev_line_offset,
            .start_line_number = self.token_start_ctx.line_number,
            .start_offset = self.token_start_ctx.offset,
            .end_offset = self.ctx.offset,
        };
    }

};

pub const Token_Context = struct {
    prev_line_offset: usize,
    start_line_number: usize,
    start_offset: usize,
    end_offset: usize,

    pub fn print_for_string(self: Token_Context, source: []const u8, print_writer: anytype, max_line_width: usize) !void {
        var offset = self.prev_line_offset;
        var line_number = self.start_line_number;
        if (line_number > 1) {
            line_number -= 1;
        }
        var iter = std.mem.split(u8, source[offset..], "\n");
        while (iter.next()) |line| {
            if (std.mem.endsWith(u8, line, "\r")) {
                try print_line(self, print_writer, line_number, offset, line[0..line.len - 1], max_line_width);
            } else {
                try print_line(self, print_writer, line_number, offset, line, max_line_width);
            }

            if (offset >= self.end_offset) {
                break;
            }

            line_number += 1;
            offset += line.len + 1;
        }
    }

    pub fn print_for_file(self: Token_Context, source: *std.fs.File, print_writer: anytype, comptime max_line_width: usize) !void {
        const originalPos = try source.getPos();
        errdefer source.seekTo(originalPos) catch {}; // best effort not to change file position in case of error

        var offset = self.prev_line_offset;
        var line_number = self.start_line_number;
        if (line_number > 1) {
            line_number -= 1;
        }

        try source.seekTo(self.prev_line_offset);
        var br = std.io.bufferedReader(source.reader());
        const file_reader = br.reader();
        var line_buf: [max_line_width + 1]u8 = undefined;
        var line_length: usize = undefined;
        while (try read_file_line(file_reader, &line_buf, &line_length)) |line| {
            if (std.mem.endsWith(u8, line, "\r")) {
                try print_line(self, print_writer, line_number, offset, line[0..line.len - 1], max_line_width);
            } else {
                try print_line(self, print_writer, line_number, offset, line, max_line_width);
            }

            if (offset >= self.end_offset) {
                break;
            }

            line_number += 1;
            offset += line_length + 1;
        }

        try source.seekTo(originalPos);
    }

    fn read_file_line(file_reader: anytype, buffer: []u8, line_length: *usize) !?[]u8 {
        const line = file_reader.readUntilDelimiterOrEof(buffer, '\n') catch |e| switch (e) {
            error.StreamTooLong => {
                var length = buffer.len;

                while (true) {
                    const byte = file_reader.readByte() catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return err,
                    };
                    if (byte == '\n') break;
                    length += 1;
                }

                line_length.* = length;
                return buffer;
            },
            else => return e,
        };
        line_length.* = (line orelse "").len;
        return line;
    }

    fn print_line(self: Token_Context, print_writer: anytype, line_number: usize, offset: usize, line: []const u8, max_line_width: usize) !void {
        try print_line_number(print_writer, self.start_line_number, line_number);

        const end_of_line = offset + line.len;
        var end_of_display = end_of_line;
        if (line.len > max_line_width) {
            try print_writer.writeAll(line[0..max_line_width - 3]);
            try print_writer.writeAll("...\n");
            end_of_display = offset + max_line_width - 3;
        } else {
            try print_writer.writeAll(line);
            try print_writer.writeAll("\n");
        }

        if (self.start_offset < end_of_line and self.end_offset > offset) {
            try print_line_number_padding(print_writer, self.start_line_number);
            if (self.start_offset <= offset) {
                if (self.end_offset >= end_of_display) {
                    // highlight full line
                    if (line.len > max_line_width and self.end_offset > end_of_display) {
                        try print_writer.writeByteNTimes('^', max_line_width - 3);
                        try print_writer.writeAll("   ^");
                    } else {
                        try print_writer.writeByteNTimes('^', end_of_display - offset);
                    }
                } else {
                    // highlight start of line
                    try print_writer.writeByteNTimes('^', self.end_offset - offset);
                }
            } else if (self.end_offset >= end_of_display) {
                // highlight end of line
                if (line.len > max_line_width and self.end_offset > end_of_display) {
                    if (self.start_offset < end_of_display) {
                        try print_writer.writeByteNTimes(' ', self.start_offset - offset);
                        try print_writer.writeByteNTimes('^', end_of_display - self.start_offset);
                    } else {
                        try print_writer.writeByteNTimes(' ', max_line_width - 3);
                    }
                    try print_writer.writeAll("   ^");
                } else {
                    try print_writer.writeByteNTimes(' ', self.start_offset - offset);
                    try print_writer.writeByteNTimes('^', end_of_display - self.start_offset);
                }
            } else {
                // highlight within line
                try print_writer.writeByteNTimes(' ', self.start_offset - offset);
                try print_writer.writeByteNTimes('^', self.end_offset - self.start_offset);
            }
            try print_writer.writeAll("\n");
        }
    }

    fn print_line_number(print_writer: anytype, initial_line: usize, line: usize) !void {
        if (initial_line < 1000) {
            try print_writer.print("{:>4} |", .{ line });
        } else if (initial_line < 100_000) {
            try print_writer.print("{:>6} |", .{ line });
        } else {
            try print_writer.print("{:>8} |", .{ line });
        }
    }
    fn print_line_number_padding(print_writer: anytype, initial_line: usize) !void {
        if (initial_line < 1000) {
            try print_writer.writeAll("     |");
        } else if (initial_line < 100_000) {
            try print_writer.writeAll("       |");
        } else {
            try print_writer.writeAll("         |");
        }
    }
};

fn is_big_type(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Pointer => |info| if (info.size == .Slice) info.child != u8 else is_big_type(info.child),
        .Optional => |info| is_big_type(info.child),
        .Struct, .Array => true,
        else => false,
    };
}

fn ArrayList_Struct(comptime S: type) type {
    return comptime blk: {
        const info = @typeInfo(S).Struct;

        var arraylist_fields: [info.fields.len]std.builtin.Type.StructField = undefined;
        for (&arraylist_fields, info.fields) |*arraylist_field, field| {
            const ArrayList_Field = ArrayListify(field.type);
            arraylist_field.* = .{
                .name = field.name,
                .type = ArrayList_Field,
                .default_value = &@as(ArrayList_Field, .{}),
                .is_comptime = false,
                .alignment = @alignOf(ArrayList_Field),
            };
        }

        break :blk @Type(.{ .Struct = .{
            .layout = .Auto,
            .fields = &arraylist_fields,
            .decls = &.{},
            .is_tuple = false,
        }});
    };
}

fn ArrayListify(comptime T: type) type {
    return std.ArrayListUnmanaged(switch (@typeInfo(T)) {
        .Pointer => |info| if (info.size == .Slice and info.child == u8) T else info.child,
        .Optional => |info| info.child,
        .Array => |info| info.child,
        else => T,
    });
}

fn max_child_items(comptime T: type) ?comptime_int {
    return switch (@typeInfo(T)) {
        .Pointer => |info| if (info.size == .Slice and info.child != u8) null else 1,
        .Array => |info| info.len,
        else => 1,
    };
}

const std = @import("std");
