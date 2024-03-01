pub fn writer(allocator: std.mem.Allocator, inner_writer: anytype) Writer(@TypeOf(inner_writer)) {
    return Writer(@TypeOf(inner_writer)).init(allocator, inner_writer);
}

pub fn reader(allocator: std.mem.Allocator, inner_reader: std.io.AnyReader) Reader {
    return Reader.init(allocator, inner_reader);
}

pub fn Writer(comptime Inner_Writer: type) type {
    return struct {
        inner: Inner_Writer,
        indent: []const u8,
        compact_state: std.ArrayList(bool),
        first_in_group: bool,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, inner_writer: Inner_Writer) Self {
            return .{
                .inner = inner_writer,
                .indent = "   ",
                .compact_state = std.ArrayList(bool).init(allocator),
                .first_in_group = true,
            };
        }

        pub fn deinit(self: *Self) void {
            self.compact_state.deinit();
        }

        fn spacing(self: *Self) !void {
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

        pub fn open(self: *Self) !void {
            try self.spacing();
            try self.inner.writeByte('(');
            try self.compact_state.append(true);
            self.first_in_group = true;
        }

        pub fn open_expanded(self: *Self) !void {
            try self.spacing();
            try self.inner.writeByte('(');
            try self.compact_state.append(false);
            self.first_in_group = true;
        }

        pub fn close(self: *Self) !void {
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

        pub fn done(self: *Self) !void {
            while (self.compact_state.items.len > 0) {
                try self.close();
            }
        }

        pub fn set_compact(self: *Self, compact: bool) void {
            if (self.compact_state.items.len > 0) {
                self.compact_state.items[self.compact_state.items.len - 1] = compact;
            }
        }

        pub fn expression(self: *Self, name: []const u8) !void {
            try self.open();
            try self.string(name);
        }

        pub fn expression_expanded(self: *Self, name: []const u8) !void {
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

        pub fn string(self: *Self, str: []const u8) !void {
            try self.spacing();
            if (requires_quotes(str)) {
                try self.inner.writeByte('"');
                _ = try self.write_escaped(str);
                try self.inner.writeByte('"');
            } else {
                try self.inner.writeAll(str);
            }
        }

        pub fn float(self: *Self, val: anytype) !void {
            try self.spacing();
            try std.fmt.formatFloatDecimal(val, .{}, self.inner);
        }

        pub fn int(self: *Self, val: anytype, radix: u8) !void {
            try self.spacing();
            try std.fmt.formatInt(val, radix, std.fmt.Case.upper, .{}, self.inner);
        }

        pub fn boolean(self: *Self, val: bool) !void {
            try self.spacing();
            const str = if (val) "true" else "false";
            try self.inner.writeAll(str);
        }

        pub fn tag(self: *Self, val: anytype) !void {
            return self.string(@tagName(val));
        }

        fn object_internal(self: *Self, comptime Context: type, obj: anytype, comptime maybe_field_name: ?[]const u8) anyerror!void {
            const T = @TypeOf(obj);
            const type_name = comptime if (@hasDecl(Context, "type_name")) Context.type_name(T) else @typeName(T);
            const compact = if (@hasDecl(Context, "write_compact")) Context.write_compact else false;

            if (maybe_field_name) |field_name| {
                if (@hasDecl(Context, "write_field_" ++ field_name)) {
                    const fun = @field(Context, "write_field_" ++ field_name);
                    try fun(self, obj);
                    return;
                }
            }

            if (@hasDecl(Context, "write_" ++ type_name)) {
                const fun = @field(Context, "write_" ++ type_name);
                try fun(self, obj);
                return;
            }

            switch (@typeInfo(T)) {
                .Bool => try self.boolean(obj),
                .Int => try self.int(obj, 10),
                .Float => try self.float(obj),
                .Enum => try self.tag(obj),
                .Pointer => |info| {
                    if (info.size == .Slice) {
                        if (info.child == u8) {
                            try self.string(obj);
                        } else {
                            try self.open();
                            if (is_big_type(info.child)) {
                                self.set_compact(compact);
                            }
                            for (obj) |item| {
                                try self.object_internal(Context, item, null);
                            }
                            try self.close();
                        }
                    } else {
                        try self.object_internal(Context, obj.*, null);
                    }
                },
                .Array => |info| {
                    try self.open();
                    if (is_big_type(info.child)) {
                        self.set_compact(compact);
                    }
                    for (&obj) |el| {
                        try self.object_internal(Context, el, null);
                    }
                    try self.close();
                },
                .Optional => {
                    if (obj) |val| {
                        try self.object_internal(Context, val, null);
                    } else {
                        try self.string("nil");
                    }
                },
                .Union => |info| {
                    std.debug.assert(info.tag_type != null);
                    const tag_name = @tagName(obj);
                    try self.expression(tag_name);
                    inline for (info.fields) |field| {
                        if (field.type != void and std.mem.eql(u8, tag_name, field.name)) {
                            try self.object_internal(Context, @field(obj, field.name), field.name);
                        }
                    }
                    try self.close();
                },
                .Struct => |info| {
                    try self.expression(type_name);
                    self.set_compact(compact);
                    inline for (info.fields) |field| {
                        if (!field.is_comptime) {
                            try self.expression(field.name);
                            try self.object_internal(Context, @field(obj, field.name), field.name);
                            try self.close();
                        }
                    }
                    try self.close();
                },
                else => unreachable,
            }
        }
        pub fn object(self: *Self, comptime Context: type, obj: anytype) anyerror!void {
            return self.object_internal(Context, obj, null);
        }

        pub fn print_value(self: *Self, comptime format: []const u8, args: anytype) !void {
            var buf: [1024]u8 = undefined;
            try self.string(std.fmt.bufPrint(&buf, format, args) catch |e| switch (e) {
                error.NoSpaceLeft => {
                    try self.inner.writeByte('"');
                    const EscapeWriter = std.io.Writer(*Self, Inner_Writer.Error, write_escaped);
                    var esc = EscapeWriter { .context = self };
                    try esc.print(format, args);
                    try self.inner.writeByte('"');
                    return;
                },
                else => return e,
            });
        }

        fn write_escaped(self: *Self, bytes: []const u8) Inner_Writer.Error!usize {
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

        pub fn print_raw(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.spacing();
            try self.inner.print(format, args);
        }

    };
}

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

    fn object_internal(self: *Reader, arena: std.mem.Allocator, comptime Context: type, defaults: anytype, comptime maybe_field_name: ?[]const u8) anyerror!?@TypeOf(defaults) {
        var obj = defaults;
        const T = @TypeOf(obj);
        const type_name = comptime if (@hasDecl(Context, "type_name")) Context.type_name(T) else @typeName(T);
        var parsed = false;

        if (maybe_field_name) |field_name| {
            if (@hasDecl(Context, "read_field_" ++ field_name)) {
                const fun = @field(Context, "read_field_" ++ field_name);
                if (try fun(self, arena, obj)) |parsed_obj| {
                    obj = parsed_obj;
                } else return null;
            }
        }

        if (!parsed and @hasDecl(Context, "read_" ++ type_name)) {
            const fun = @field(Context, "read_" ++ type_name);
            if (try fun(self, arena, obj)) |parsed_obj| {
                obj = parsed_obj;
                parsed = true;
            } else return null;
        }

        switch (@typeInfo(T)) {
            .Bool => {
                if (try self.any_boolean()) |val| {
                    obj = val;
                } else return null;
            },
            .Int => {
                if (try self.any_int(T, 0)) |val| {
                    obj = val;
                } else return null;
            },
            .Float => {
                if (try self.any_float(T)) |val| {
                    obj = val;
                } else return null;
            },
            .Enum => {
                if (try self.any_enum(T)) |val| {
                    obj = val;
                } else return null;
            },
            .Pointer => |info| {
                if (info.size == .Slice) {
                    if (info.child == u8) {
                        if (try self.any_string()) |val| {
                            obj = try arena.dupe(u8, val);
                        } else return null;
                    } else {
                        if (!try self.open()) return null;
                        var temp = std.ArrayList(info.child).init(self.token.allocator);
                        defer temp.deinit();
                        while (try self.object_internal(arena, Context, std.mem.zeroes(info.child), null)) |raw| {
                            try temp.append(raw);
                        }
                        try self.require_close();
                        obj = try arena.dupe(info.child, temp.items);
                    }
                } else {
                    if (try self.object_internal(arena, Context, obj.*, null)) |raw| {
                        const ptr = try arena.create(info.child);
                        ptr.* = raw;
                        obj = ptr;
                    } else return null;
                }
            },
            .Array => {
                if (!try self.open()) return null;
                for (&obj) |*el| {
                    el.* = try self.require_object_internal(arena, Context, el.*, null);
                }
                try self.require_close();
            },
            .Optional => |info| {
                if (try self.string("nil")) {
                    obj = null;
                } else if (obj) |default_value| {
                    if (try self.object_internal(arena, Context, default_value, null)) |raw| {
                        obj = raw;
                    } else return null;
                } else if (try self.object_internal(arena, Context, std.mem.zeroes(info.child), null)) |raw| {
                    obj = raw;
                } else return null;
            },
            .Union => |info| {
                var found_field = false;
                inline for (info.fields) |field| {
                    if (!found_field and try self.expression(field.name)) {
                        if (field.type == void) {
                            obj = @unionInit(T, field.name, {});
                        } else if (std.mem.eql(u8, @tagName(obj), field.name)) {
                            obj = @unionInit(T, field.name, try self.require_object_internal(arena, Context, @field(obj, field.name), field.name));
                        } else {
                            obj = @unionInit(T, field.name, try self.require_object_internal(arena, Context, std.mem.zeroes(field.type), field.name));
                        }
                        try self.require_close();
                        found_field = true;
                    }
                }
                if (!found_field) return null;
            },
            .Struct => |info| {
                if (!try self.expression(type_name)) return null;
                while (true) {
                    var found_field = false;
                    inline for (info.fields) |field| {
                        if (!field.is_comptime and try self.expression(field.name)) {
                            @field(obj, field.name) = try self.require_object_internal(arena, Context, @field(obj, field.name), field.name);
                            try self.require_close();
                            found_field = true;
                        }
                    }

                    if (!found_field) break;
                }

                try self.require_close();
            },
            else => unreachable,
        }

        if (maybe_field_name) |field_name| {
            if (@hasDecl(Context, "validate_field_" ++ field_name)) {
                const fun = @field(Context, "validate_field_" ++ field_name);
                try fun(&obj, arena);
            }
        }
        if (@hasDecl(Context, "validate_" ++ type_name)) {
            const fun = @field(Context, "validate_" ++ type_name);
            try fun(&obj, arena);
        }

        return obj;
    }
    fn require_object_internal(self: *Reader, arena: std.mem.Allocator, comptime Context: type, defaults: anytype, comptime maybe_field_name: ?[]const u8) anyerror!@TypeOf(defaults) {
        return try self.object_internal(arena, Context, defaults, maybe_field_name) orelse error.SExpressionSyntaxError;
    }

    pub fn object(self: *Reader, arena: std.mem.Allocator, comptime Context: type, defaults: anytype) anyerror!@TypeOf(defaults) {
        return try self.object_internal(arena, Context, defaults, null);
    }
    pub fn require_object(self: *Reader, arena: std.mem.Allocator, comptime Context: type, defaults: anytype) anyerror!@TypeOf(defaults) {
        return try self.object_internal(arena, Context, defaults, null) orelse error.SExpressionSyntaxError;
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

const std = @import("std");
