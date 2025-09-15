pub fn writer(allocator: std.mem.Allocator, w: *std.io.Writer) Writer {
    return Writer.init(allocator, w);
}

pub fn reader(allocator: std.mem.Allocator, r: *std.io.Reader) Reader {
    return Reader.init(allocator, r);
}

pub const Writer = struct {
    inner: *std.io.Writer,
    indent: []const u8,
    gpa: std.mem.Allocator,
    compact_state: std.ArrayList(bool),
    first_in_group: bool,
    wrote_non_compact_item: bool,

    pub fn init(gpa: std.mem.Allocator, w: *std.io.Writer) Writer {
        return .{
            .inner = w,
            .indent = "   ",
            .gpa = gpa,
            .compact_state = .empty,
            .first_in_group = true,
            .wrote_non_compact_item = false,
        };
    }

    pub fn deinit(self: *Writer) void {
        self.compact_state.deinit(self.gpa);
    }

    fn spacing(self: *Writer) !void {
        const cs = self.compact_state;
        if (cs.items.len > 0 and cs.items[cs.items.len - 1]) {
            if (self.first_in_group) {
                self.first_in_group = false;
            } else {
                try self.inner.writeByte(' ');
            }
            self.wrote_non_compact_item = false;
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
            self.wrote_non_compact_item = true;
        }
    }

    pub fn open(self: *Writer) !void {
        try self.spacing();
        try self.inner.writeByte('(');
        try self.compact_state.append(self.gpa, true);
        self.first_in_group = true;
        self.wrote_non_compact_item = false;
    }

    pub fn open_expanded(self: *Writer) !void {
        try self.spacing();
        try self.inner.writeByte('(');
        try self.compact_state.append(self.gpa, false);
        self.first_in_group = true;
        self.wrote_non_compact_item = false;
    }

    pub fn close(self: *Writer) !void {
        if (self.compact_state.items.len > 0) {
            if (!(self.compact_state.pop().?) and !self.first_in_group and self.wrote_non_compact_item) {
                try self.inner.writeByte('\n');
                for (self.compact_state.items) |_| {
                    try self.inner.writeAll(self.indent);
                }
            }
            try self.inner.writeByte(')');
            if (self.compact_state.items.len > 0) {
                self.wrote_non_compact_item = !self.compact_state.items[self.compact_state.items.len - 1];
            }
        }
        self.first_in_group = false;
    }

    pub fn done(self: *Writer) !void {
        while (self.compact_state.items.len > 0) {
            try self.close();
        }
    }

    pub fn is_compact(self: *Writer) bool {
        const items = self.compact_state.items;
        return items.len > 0 and items[items.len - 1];
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
            _ = try write_escaped(self.inner, str);
            try self.inner.writeByte('"');
        } else {
            try self.inner.writeAll(str);
        }
    }

    pub fn float(self: *Writer, val: anytype) !void {
        try self.spacing();
        switch (@typeInfo(@TypeOf(val))) {
            .@"comptime_float", .float => {
                try self.inner.printFloat(val, .{});
            },
            .@"comptime_int", .int => {
                try self.inner.printFloat(@as(f64, @floatFromInt(val)), .{});
            },
            else => @compileError("Expected float"),
        }
    }

    pub fn int(self: *Writer, val: anytype, radix: u8) !void {
        try self.spacing();
        try self.inner.printInt(val, radix, .upper, .{});
    }

    pub fn boolean(self: *Writer, val: bool) !void {
        try self.spacing();
        const str = if (val) "true" else "false";
        try self.inner.writeAll(str);
    }

    pub fn tag(self: *Writer, val: anytype) !void {
        var buf: [256]u8 = undefined;
        return self.string(swap_underscores_and_dashes(@tagName(val), &buf));
    }

    pub fn object(self: *Writer, obj: anytype, comptime Context: type) !void {
        const T = @TypeOf(obj);
        switch (@typeInfo(T)) {
            .@"bool" => try self.boolean(obj),
            .int => try self.int(obj, 10),
            .float => try self.float(obj),
            .@"enum" => try self.tag(obj),
            .void => {},
            .pointer => |info| {
                if (info.size == .slice) {
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
            .array => |info| {
                if (info.child == u8) {
                    try self.string(&obj);
                } else {
                    for (&obj) |el| {
                        try self.object(el, Context);
                    }
                }
            },
            .optional => {
                if (obj) |val| {
                    try self.object(val, Context);
                } else {
                    try self.string("nil");
                }
            },
            .@"union" => |info| {
                std.debug.assert(info.tag_type != null);
                const tag_name = @tagName(obj);
                try self.string(tag_name);

                const has_compact = @hasDecl(Context, "compact") and !@hasField(T, "compact");
                const compact: type = if (has_compact) @field(Context, "compact") else struct {};

                const was_compact = self.is_compact();

                inline for (info.fields) |field| {
                    if (field.type != void and std.mem.eql(u8, tag_name, field.name)) {
                        self.set_compact(if (@hasDecl(compact, field.name)) @field(compact, field.name) else was_compact);
                        try self.object_child(@field(obj, field.name), false, field.name, Context);
                    }
                }

                self.set_compact(was_compact);
            },
            .@"struct" => |info| {
                const has_inline_fields = @hasDecl(Context, "inline_fields") and !@hasField(T, "inline_fields");
                const inline_fields: []const []const u8 = if (has_inline_fields) @field(Context, "inline_fields") else &.{};

                const has_compact = @hasDecl(Context, "compact") and !@hasField(T, "compact");
                const compact: type = if (has_compact) @field(Context, "compact") else struct {};

                const was_compact = self.is_compact();

                if (inline_fields.len > 0) {
                    inline for (inline_fields) |field_name| {
                        self.set_compact(if (@hasDecl(compact, field_name)) @field(compact, field_name) else true);
                        try self.object_child(@field(obj, field_name), false, field_name, Context);
                    }
                }

                inline for (info.fields) |field| {
                    if (!field.is_comptime) {
                        if (!inline for (inline_fields) |inline_field_name| {
                            if (comptime std.mem.eql(u8, inline_field_name, field.name)) break true;
                        } else false) {
                            self.set_compact(if (@hasDecl(compact, field.name)) @field(compact, field.name) else was_compact);
                            try self.object_child(@field(obj, field.name), true, field.name, Context);
                        }
                    }
                }

                self.set_compact(was_compact);
            },
            .error_union => @compileError("Can't serialize error set; did you forget a 'try'?"),
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        }
    }

    fn object_child(self: *Writer, child: anytype, wrap: bool, comptime field_name: []const u8, comptime Parent_Context: type) !void {
        const Child_Context = if (@hasDecl(Parent_Context, field_name)) @field(Parent_Context, field_name) else struct{};
        switch (@typeInfo(@TypeOf(Child_Context))) {
            .@"fn" => {
                log.debug("Writing field {s} using function {s}", .{ field_name, @typeName(@TypeOf(Child_Context)) });
                try Child_Context(child, self, wrap);
            },
            .@"type" => {
                if (Child_Context == void) return; // ignore field
                switch (@typeInfo(@TypeOf(child))) {
                    .pointer => |info| {
                        if (info.size == .slice) {
                            if (info.child == u8) {
                                log.debug("Writing field {s} using context {s}", .{ field_name, @typeName(Child_Context) });
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
                    .array => |info| {
                        if (info.child == u8) {
                            log.debug("Writing field {s} using context {s}", .{ field_name, @typeName(Child_Context) });
                            if (wrap) try self.open_for_object_child(field_name, @TypeOf(child), Child_Context);
                            try self.string(&child);
                            if (wrap) try self.close();
                        } else {
                            for (&child) |item| {
                                try self.object_child(item, wrap, field_name, Parent_Context);
                            }
                        }
                    },
                    .optional => {
                        if (child) |item| {
                            try self.object_child(item, wrap, field_name, Parent_Context);
                        }
                    },
                    else => {
                        log.debug("Writing field {s} using context {s}", .{ field_name, @typeName(Child_Context) });
                        if (wrap) try self.open_for_object_child(field_name, @TypeOf(child), Child_Context);
                        try self.object(child, Child_Context);
                        if (wrap) try self.close();
                    },
                }
            },
            .pointer => {
                // Child_Context is a comptime constant format string
                switch (@typeInfo(@TypeOf(child))) {
                    .pointer => |info| {
                        if (info.size == .slice) {
                            if (wrap) try self.expression(field_name);
                            try self.print_value("{" ++ Child_Context ++ "}", .{ child });
                            if (wrap) try self.close();
                        } else {
                            try self.object_child(child.*, wrap, field_name, Parent_Context);
                        }
                    },
                    .optional => {
                        if (child) |inner| {
                            try self.object_child(inner, wrap, field_name, Parent_Context);
                        }
                    },
                    else => {
                        if (wrap) try self.expression(field_name);
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
        if (@hasDecl(Child_Context, "default_compact")) {
            self.set_compact(@field(Child_Context, "default_compact"));
        } else {
            self.set_compact(!is_big_type(Child));
        }
    }

    pub fn print_value(self: *Writer, comptime format: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print(format, args) catch {
            try self.spacing();
            try self.inner.writeByte('"');
            var ew: Escaped_Writer = .init(self.inner, &buf);
            try ew.writer.print(format, args);
            try ew.writer.flush();
            try self.inner.writeByte('"');
            return;
        };
        try self.string(w.buffered());
    }

    const Escaped_Writer = struct {
        out: *std.io.Writer,
        writer: std.io.Writer,
        done: bool,

        pub fn init(out: *std.io.Writer, buffer: []u8) Escaped_Writer {
            return .{
                .out = out,
                .writer = .{
                    .buffer = buffer,
                    .vtable = &.{ .drain = drain },
                },
                .done = false,
            };
        }

        fn drain(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
            const self: *Escaped_Writer = @alignCast(@fieldParentPtr("writer", w));
            const aux = w.buffered();
            var n = try write_escaped(self.out, aux);
            w.end = 0;

            if (data.len > 0) {
                for (data[0 .. data.len - 1]) |slice| {
                    n += try write_escaped(self.out, slice);
                }
                const pattern = data[data.len - 1];
                for (0..splat) |_| {
                    n += try write_escaped(self.out, pattern);
                }
            }

            return n;
        }
    };

    pub fn print_raw(self: *Writer, comptime format: []const u8, args: anytype) !void {
        try self.spacing();
        try self.inner.print(format, args);
    }

};

fn write_escaped(w: *std.io.Writer, bytes: []const u8) std.io.Writer.Error!usize {
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        var c = bytes[i];
        if (c == '"' or c == '\\') {
            try w.writeByte('\\');
            try w.writeByte(c);
        } else if (c < ' ') {
            if (c == '\n') {
                try w.writeAll("\\n");
            } else if (c == '\r') {
                try w.writeAll("\\r");
            } else if (c == '\t') {
                try w.writeAll("\\t");
            } else {
                try w.writeByte(c);
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
            try w.writeAll(bytes[i..j]);
            i = j - 1;
        }
    }
    return bytes.len;
}

pub const Reader = struct {
    const State = enum(u8) {
        unknown = 0,
        open = 1,
        close = 2,
        val = 3,
        eof = 4
    };

    inner: *std.io.Reader,
    next_byte: ?u8,
    gpa: std.mem.Allocator,
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

    pub fn init(gpa: std.mem.Allocator, r: *std.io.Reader) Reader {
        return .{
            .inner = r,
            .next_byte = null,
            .gpa = gpa,
            .token = .empty,
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
        self.token.deinit(self.gpa);
    }

    fn consume_byte(self: *Reader) error{ReadFailed}!?u8 {
        var b = self.next_byte;
        if (b == null) {
            b = self.inner.takeByte() catch |err| switch (err) {
                error.EndOfStream => return null,
                error.ReadFailed => return @errorCast(err),
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

    fn skip_whitespace(self: *Reader, include_newlines: bool) !void {
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

    fn read_unquoted_val(self: *Reader) !void {
        self.token.clearRetainingCapacity();

        while (try self.consume_byte()) |b| {
            switch (b) {
                0...' ', '(', ')', '"' => {
                    self.put_back_byte(b);
                    return;
                },
                else => {
                    try self.token.append(self.gpa, b);
                },
            }
        }
    }

    fn read_quoted_val(self: *Reader) !void {
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
                try self.token.append(self.gpa, switch (b) {
                    't' => '\t',
                    'n' => '\n',
                    'r' => '\r',
                    else => b,
                });
                in_escape = false;
            } else switch (b) {
                '\\' => in_escape = true,
                '"' => return,
                else => try self.token.append(self.gpa, b),
            }
        }
    }

    fn read(self: *Reader) !void {
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

    pub fn is_compact(self: *Reader) !bool {
        if (self.state == .unknown) {
            try self.read();
        }
        return self.compact;
    }

    pub fn set_peek(self: *Reader, peek: bool) void {
        self.peek = peek;
    }

    pub fn any(self: *Reader) !void {
        if (!self.peek) {
            if (self.state == .unknown) {
                try self.read();
            }
            self.state = .unknown;
        }
    }

    pub fn open(self: *Reader) !bool {
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

    pub fn require_open(self: *Reader) !void {
        if (!try self.open()) {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn close(self: *Reader) !bool {
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

    pub fn require_close(self: *Reader) !void {
        if (!try self.close()) {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn done(self: *Reader) !bool {
        if (self.state == .unknown) {
            try self.read();
        }

        return self.state == .eof;
    }

    pub fn require_done(self: *Reader) !void {
        if (!try self.done()) {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn expression(self: *Reader, expected: []const u8) !bool {
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

    pub fn require_expression(self: *Reader, expected: []const u8) !void {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .open and std.mem.eql(u8, self.token.items, expected)) {
            try self.any();
        } else {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn any_expression(self: *Reader) !?[]const u8 {
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

    pub fn require_any_expression(self: *Reader) ![]const u8 {
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

    pub fn string(self: *Reader, expected: []const u8) !bool {
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
    pub fn require_string(self: *Reader, expected: []const u8) !void {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state == .val and std.mem.eql(u8, self.token.items, expected)) {
            try self.any();
        } else {
            return error.SExpressionSyntaxError;
        }
    }

    pub fn any_string(self: *Reader) !?[]const u8 {
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
    pub fn require_any_string(self: *Reader) ![]const u8 {
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

    pub fn any_boolean(self: *Reader) !?bool {
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
    pub fn require_any_boolean(self: *Reader) !bool {
        return try self.any_boolean() orelse error.SExpressionSyntaxError;
    }

    pub fn any_enum(self: *Reader, comptime T: type) !?T {
        if (self.state == .unknown) {
            try self.read();
        }

        if (self.state != .val) {
            return null;
        }

        if (string_to_enum(T, self.token.items)) |e| {
            try self.any();
            return e;
        }

        return null;
    }
    pub fn require_any_enum(self: *Reader, comptime T: type) !T {
        return try self.any_enum(T) orelse error.SExpressionSyntaxError;
    }

    // Takes a std.StaticStringMap to convert strings into the enum
    pub fn map_enum(self: *Reader, comptime T: type, map: anytype) !?T {
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

    pub fn require_map_enum(self: *Reader, comptime T: type, map: anytype) !T {
        return try self.map_enum(T, map) orelse error.SExpressionSyntaxError;
    }

    pub fn any_float(self: *Reader, comptime T: type) !?T {
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
    pub fn require_any_float(self: *Reader, comptime T: type) !T {
        return try self.any_float(T) orelse error.SExpressionSyntaxError;
    }

    pub fn any_int(self: *Reader, comptime T: type, radix: u8) !?T {
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
    pub fn require_any_int(self: *Reader, comptime T: type, radix: u8) !T {
        return try self.any_int(T, radix) orelse error.SExpressionSyntaxError;
    }

    pub fn any_unsigned(self: *Reader, comptime T: type, radix: u8) !?T {
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
    pub fn require_any_unsigned(self: *Reader, comptime T: type, radix: u8) !T {
        return try self.any_unsigned(T, radix) orelse error.SExpressionSyntaxError;
    }


    pub fn object(self: *Reader, arena: std.mem.Allocator, comptime T: type, comptime Context: type) !?T {
        const obj: T = switch (@typeInfo(T)) {
            .@"bool" => if (try self.any_boolean()) |val| val else return null,
            .int => if (try self.any_int(T, 0)) |val| val else return null,
            .float => if (try self.any_float(T)) |val| val else return null,
            .@"enum" => if (try self.any_enum(T)) |val| val else return null,
            .@"void" => {},
            .pointer => |info| blk: {
                if (info.size == .slice) {
                    if (info.child == u8) {
                        if (try self.any_string()) |val| {
                            break :blk try arena.dupe(u8, val);
                        } else return null;
                    } else {
                        var temp: std.ArrayList(info.child) = .empty;
                        defer temp.deinit(self.gpa);
                        var i: usize = 0;
                        while (true) : (i += 1) {
                            if (try self.object(arena, info.child, Context)) |raw| {
                                try temp.append(self.gpa, raw);
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
            .array => |info| blk: {
                var a: T = undefined;
                if (info.child == u8) {
                    if (try self.any_string()) |val| {
                        if (val.len != a.len) return error.SExpressionSyntaxError;
                        a = val[0..a.len].*;
                    } else return null;
                } else if (info.len > 0) {
                    if (try self.object(arena, info.child, Context)) |raw| {
                        a[0] = raw;
                    } else return null;
                    for (a[1..]) |*el| {
                        el.* = try self.require_object(arena, info.child, Context);
                    }
                }
                break :blk a;
            },
            .optional => |info| blk: {
                if (try self.string("nil")) {
                    break :blk null;
                } else if (try self.object(arena, info.child, Context)) |raw| {
                    break :blk raw;
                } else return null;
            },
            .@"union" => |info| blk: {
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
            .@"struct" => |info| blk: {
                var temp: ArrayList_Struct(T) = .{};
                defer inline for (@typeInfo(@TypeOf(temp)).@"struct".fields) |field| {
                    @field(temp, field.name).deinit(self.gpa);
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
                            .array => |arr_info| {
                                const slice: []arr_info.child = &@field(obj, field.name);
                                @memcpy(slice.data, arraylist_ptr.items);
                            },
                            .pointer => |ptr_info| {
                                if (ptr_info.size == .slice) {
                                    @field(obj, field.name) = try arena.dupe(Unwrapped, arraylist_ptr.items);
                                } else {
                                    const ptr = try arena.create(ptr_info.child);
                                    ptr.* = arraylist_ptr.items[0];
                                    @field(obj, field.name) = ptr;
                                }
                            },
                            .optional => {
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
    pub fn require_object(self: *Reader, arena: std.mem.Allocator, comptime T: type, comptime Context: type) !T {
        return (try self.object(arena, T, Context)) orelse error.SExpressionSyntaxError;
    }

    fn parse_struct_fields(self: *Reader, arena: std.mem.Allocator, comptime T: type, temp: *ArrayList_Struct(T), comptime Context: type) !void {
        const struct_fields = @typeInfo(T).@"struct".fields;

        const has_inline_fields = @hasDecl(Context, "inline_fields") and !@hasField(T, "inline_fields");
        const inline_fields: []const []const u8 = if (has_inline_fields) @field(Context, "inline_fields") else &.{};

        inline for (inline_fields) |field_name| {
            const Unwrapped = @TypeOf(@field(temp, field_name).items[0]);
            const field = struct_fields[std.meta.fieldIndex(T, field_name).?];
            const max_children = max_child_items(field.type);

            var i: usize = 0;
            while (max_children == null or i < max_children.?) : (i += 1) {
                const arraylist_ptr = &@field(temp.*, field_name);
                try arraylist_ptr.ensureUnusedCapacity(self.gpa, 1);
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
                        try @field(temp.*, field.name).ensureUnusedCapacity(self.gpa, 1);
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

    fn object_child(self: *Reader, arena: std.mem.Allocator, comptime T: type, wrap: bool, comptime field_name: []const u8, comptime Parent_Context: type) !?T {
        const Child_Context = if (@hasDecl(Parent_Context, field_name)) @field(Parent_Context, field_name) else struct{};
        switch (@typeInfo(@TypeOf(Child_Context))) {
            .@"fn" => return Child_Context(arena, self, wrap),
            .@"type" => {
                if (wrap) {
                    if (try self.expression(field_name)) {
                        if (Child_Context == void) {
                            try self.ignore_remaining_expression();
                            return null;
                        }
                        const value = try self.require_object(arena, T, Child_Context);
                        try self.require_close();
                        return value;
                    } else return null;
                } else {
                    if (Child_Context == void) return null;
                    return try self.object(arena, T, Child_Context);
                }
            },
            .pointer => {
                // Child_Context is a comptime constant format string
                if (wrap) {
                    if (try self.expression(field_name)) {
                        const value = if (comptime has_from_string(T))
                            try T.from_string(Child_Context, try self.require_any_string())
                        else
                            try self.require_object(arena, T, struct {});

                        try self.require_close();
                        return value;
                    } else return null;
                } else {
                    if (comptime has_from_string(T)) {
                        if (try self.any_string()) |raw| {
                            return try T.from_string(Child_Context, raw);
                        } else return null;
                    } else {
                        return try self.object(arena, T, struct {});
                    }
                }
            },
            else => @compileError("Expected child context to be a struct or function declaration"),
        }
    }
    fn require_object_child(self: *Reader, arena: std.mem.Allocator, comptime T: type, wrap: bool, comptime field_name: []const u8, comptime Parent_Context: type) !T {
        return (try self.object_child(arena, T, wrap, field_name, Parent_Context)) orelse error.SExpressionSyntaxError;
    }

    // note this consumes the current expression's closing parenthesis
    pub fn ignore_remaining_expression(self: *Reader) !void {
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

    pub fn token_context(self: *Reader) !Token_Context {
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

    pub fn print_for_string(self: Token_Context, source: []const u8, w: *std.io.Writer, max_line_width: usize) !void {
        var offset = self.prev_line_offset;
        var line_number = self.start_line_number;
        if (line_number > 1) {
            line_number -= 1;
        }
        var iter = std.mem.splitScalar(u8, source[offset..], '\n');
        while (iter.next()) |line| {
            if (std.mem.endsWith(u8, line, "\r")) {
                try print_line(self, w, line_number, offset, line[0..line.len - 1], max_line_width);
            } else {
                try print_line(self, w, line_number, offset, line, max_line_width);
            }

            if (offset >= self.end_offset) {
                break;
            }

            line_number += 1;
            offset += line.len + 1;
        }
    }

    pub fn print_for_file(self: Token_Context, source: *std.fs.File, w: *std.io.Writer, comptime max_line_width: usize) !void {
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
                try print_line(self, w, line_number, offset, line[0..line.len - 1], max_line_width);
            } else {
                try print_line(self, w, line_number, offset, line, max_line_width);
            }

            if (offset >= self.end_offset) {
                break;
            }

            line_number += 1;
            offset += line_length + 1;
        }

        try source.seekTo(originalPos);
    }

    fn read_file_line(r: *std.io.Reader, buffer: []u8, line_length: *usize) !?[]u8 {
        var bw = std.io.Writer.fixed(buffer);
        r.streamDelimiter(bw, '\n') catch |e| switch (e) {
            error.WriteFailed => {
                var length = buffer.len;

                length += try r.discardDelimiterExclusive('\n');

                line_length.* = length;
                return buffer;
            },
            error.EndOfStream => {},
            else => return e,
        };
        line_length.* = bw.buffered().len;
        return bw.buffered();
    }

    fn print_line(self: Token_Context, w: *std.io.Writer, line_number: usize, offset: usize, line: []const u8, max_line_width: usize) !void {
        try print_line_number(w, self.start_line_number, line_number);

        const end_of_line = offset + line.len;
        var end_of_display = end_of_line;
        if (line.len > max_line_width) {
            try w.writeAll(line[0..max_line_width - 3]);
            try w.writeAll("...\n");
            end_of_display = offset + max_line_width - 3;
        } else {
            try w.writeAll(line);
            try w.writeAll("\n");
        }

        if (self.start_offset < end_of_line and self.end_offset > offset) {
            try print_line_number_padding(w, self.start_line_number);
            if (self.start_offset <= offset) {
                if (self.end_offset >= end_of_display) {
                    // highlight full line
                    if (line.len > max_line_width and self.end_offset > end_of_display) {
                        try w.splatByteAll('^', max_line_width - 3);
                        try w.writeAll("   ^");
                    } else {
                        try w.splatByteAll('^', end_of_display - offset);
                    }
                } else {
                    // highlight start of line
                    try w.splatByteAll('^', self.end_offset - offset);
                }
            } else if (self.end_offset >= end_of_display) {
                // highlight end of line
                if (line.len > max_line_width and self.end_offset > end_of_display) {
                    if (self.start_offset < end_of_display) {
                        try w.splatByteAll(' ', self.start_offset - offset);
                        try w.splatByteAll('^', end_of_display - self.start_offset);
                    } else {
                        try w.splatByteAll(' ', max_line_width - 3);
                    }
                    try w.writeAll("   ^");
                } else {
                    try w.splatByteAll(' ', self.start_offset - offset);
                    try w.splatByteAll('^', end_of_display - self.start_offset);
                }
            } else {
                // highlight within line
                try w.splatByteAll(' ', self.start_offset - offset);
                try w.splatByteAll('^', self.end_offset - self.start_offset);
            }
            try w.writeAll("\n");
        }
    }

    fn print_line_number(w: *std.io.Writer, initial_line: usize, line: usize) !void {
        if (initial_line < 1000) {
            try w.print("{:>4} |", .{ line });
        } else if (initial_line < 100_000) {
            try w.print("{:>6} |", .{ line });
        } else {
            try w.print("{:>8} |", .{ line });
        }
    }
    fn print_line_number_padding(w: *std.io.Writer, initial_line: usize) !void {
        if (initial_line < 1000) {
            try w.writeAll("     |");
        } else if (initial_line < 100_000) {
            try w.writeAll("       |");
        } else {
            try w.writeAll("         |");
        }
    }
};

fn is_big_type(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| if (info.size == .slice) info.child != u8 else is_big_type(info.child),
        .optional => |info| is_big_type(info.child),
        .array => |info| info.child != u8,
        .@"struct" => true,
        else => false,
    };
}

fn ArrayList_Struct(comptime S: type) type {
    return comptime blk: {
        const info = @typeInfo(S).@"struct";

        var arraylist_fields: [info.fields.len]std.builtin.Type.StructField = undefined;
        for (&arraylist_fields, info.fields) |*arraylist_field, field| {
            const ArrayList_Field = ArrayListify(field.type);
            arraylist_field.* = .{
                .name = field.name,
                .type = ArrayList_Field,
                .default_value_ptr = &@as(ArrayList_Field, .{}),
                .is_comptime = false,
                .alignment = @alignOf(ArrayList_Field),
            };
        }

        break :blk @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = &arraylist_fields,
            .decls = &.{},
            .is_tuple = false,
        }});
    };
}

fn ArrayListify(comptime T: type) type {
    return std.ArrayListUnmanaged(switch (@typeInfo(T)) {
        .pointer => |info| if (info.size == .slice and info.child == u8) T else info.child,
        .optional => |info| info.child,
        .array => |info| info.child,
        else => T,
    });
}

fn max_child_items(comptime T: type) ?comptime_int {
    return switch (@typeInfo(T)) {
        .pointer => |info| if (info.size == .slice and info.child != u8) null else 1,
        .array => |info| info.len,
        else => 1,
    };
}

fn swap_underscores_and_dashes(str: []const u8, buf: []u8) []const u8 {
    if (str.len > buf.len) return str;

    for (str, buf[0..str.len]) |c, *out| {
        out.* = switch (c) {
            '_' => '-',
            '-' => '_',
            else => c,
        };
    }
    
    return buf[0..str.len];
}

fn swap_underscores_and_dashes_comptime(comptime str: []const u8) []const u8 {
    if (str.len > 256) return str;

    comptime var temp: [str.len]u8 = undefined;
    _ = comptime swap_underscores_and_dashes(str, &temp);

    const result = temp[0..].*;
    return &result;
}

/// Same as std.meta.stringToEnum, but swaps '_' and '-' in enum names
fn string_to_enum(comptime T: type, str: []const u8) ?T {
    // Using StaticStringMap here is more performant, but it will start to take too
    // long to compile if the enum is large enough, due to the current limits of comptime
    // performance when doing things like constructing lookup maps at comptime.
    // TODO The '100' here is arbitrary and should be increased when possible:
    // - https://github.com/ziglang/zig/issues/4055
    // - https://github.com/ziglang/zig/issues/3863
    if (@typeInfo(T).@"enum".fields.len <= 100) {
        const kvs = comptime build_kvs: {
            const EnumKV = struct { []const u8, T };
            var kvs_array: [@typeInfo(T).@"enum".fields.len]EnumKV = undefined;
            for (@typeInfo(T).@"enum".fields, 0..) |enumField, i| {
                kvs_array[i] = .{ swap_underscores_and_dashes_comptime(enumField.name), @field(T, enumField.name) };
            }
            break :build_kvs kvs_array[0..];
        };

        const map = if (comptime zig_version.minor == 12)
            std.ComptimeStringMap(T, kvs) // TODO remove zig 0.12 support when 0.14 is released
        else
            std.StaticStringMap(T).initComptime(kvs);

        return map.get(str);
    } else {
        inline for (@typeInfo(T).@"enum".fields) |enumField| {
            if (std.mem.eql(u8, str, swap_underscores_and_dashes_comptime(enumField.name))) {
                return @field(T, enumField.name);
            }
        }
        return null;
    }
}

inline fn has_from_string(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "from_string"),
        else => false,
    };
}

const zig_version = @import("builtin").zig_version;

const log = std.log.scoped(.sx);

const std = @import("std");
