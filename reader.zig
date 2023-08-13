const std = @import("std");

pub fn reader(allocator: std.mem.Allocator, inner_reader: anytype) Reader(@TypeOf(inner_reader)) {
    return Reader(@TypeOf(inner_reader)).init(allocator, inner_reader);
}

pub fn Reader(comptime InnerReader: type) type {
    return struct {
        const Self = @This();

        const State = enum(u8) {
            unknown = 0,
            open = 1,
            close = 2,
            val = 3,
            eof = 4
        };

        inner: InnerReader,
        next_byte: ?u8,
        token: std.ArrayList(u8),
        compact: bool,
        state: State,
        ctx: ContextData,
        line_offset: usize,
        val_start_ctx: ContextData,
        token_start_ctx: ContextData,

        const ContextData = struct {
            offset: usize = 0,
            prev_line_offset: usize = 0,
            line_number: usize = 1,
        };

        pub fn init(allocator: std.mem.Allocator, inner_reader: InnerReader) Self {
            return .{
                .inner = inner_reader,
                .next_byte = null,
                .token = std.ArrayList(u8).init(allocator),
                .compact = true,
                .state = .unknown,
                .ctx = .{},
                .line_offset = 0,
                .val_start_ctx = .{},
                .token_start_ctx = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.token.deinit();
        }

        fn consumeByte(self: *Self) !?u8 {
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

        fn putBackByte(self: *Self, b: u8) void {
            self.next_byte = b;
            self.ctx.offset -= 1;
        }

        fn skipWhitespace(self: *Self, include_newlines: bool) !void {
            if (include_newlines) {
                self.compact = true;
            }
            while (try self.consumeByte()) |b| {
                switch (b) {
                    '\n' => {
                        if (include_newlines) {
                            self.ctx.line_number += 1;
                            self.ctx.prev_line_offset = self.line_offset;
                            self.line_offset = self.ctx.offset;
                            self.compact = false;
                        } else {
                            self.putBackByte(b);
                            return;
                        }
                    },
                    33...255 => {
                        self.putBackByte(b);
                        return;
                    },
                    else => {}
                }
            }
        }

        fn readUnquotedVal(self: *Self) !void {
            self.token.clearRetainingCapacity();

            while (try self.consumeByte()) |b| {
                switch (b) {
                    0...' ', '(', ')', '"' => {
                        self.putBackByte(b);
                        return;
                    },
                    else => {
                        try self.token.append(b);
                    },
                }
            }
        }

        fn readQuotedVal(self: *Self) !void {
            self.token.clearRetainingCapacity();

            var in_escape = false;
            while (try self.consumeByte()) |b| {
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

        fn read(self: *Self) !void {
            try self.skipWhitespace(true);
            self.token_start_ctx = self.ctx;
            if (try self.consumeByte()) |b| {
                switch (b) {
                    '(' => {
                        try self.skipWhitespace(false);
                        self.val_start_ctx = self.ctx;
                        if (try self.consumeByte()) |q| {
                            if (q == '"') {
                                try self.readQuotedVal();
                            } else {
                                self.putBackByte(q);
                                try self.readUnquotedVal();
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
                        try self.readQuotedVal();
                        self.state = .val;
                    },
                    else => {
                        self.putBackByte(b);
                        try self.readUnquotedVal();
                        self.state = .val;
                    },
                }
            } else {
                self.state = .eof;
                return;
            }
        }

        pub fn isCompact(self: *Self) !bool {
            if (self.state == .unknown) {
                try self.read();
            }
            return self.compact;
        }

        pub fn open(self: *Self) !bool {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state == .open) {
                if (self.token.items.len > 0) {
                    self.token_start_ctx = self.val_start_ctx;
                    self.state = .val;
                    self.compact = true;
                } else {
                    self.state = .unknown;
                }
                return true;
            } else {
                return false;
            }
        }

        pub fn requireOpen(self: *Self) !void {
            if (!try self.open()) {
                return error.SExpressionSyntaxError;
            }
        }

        pub fn close(self: *Self) !bool {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state == .close) {
                self.state = .unknown;
                return true;
            } else {
                return false;
            }
        }

        pub fn requireClose(self: *Self) !void {
            if (!try self.close()) {
                return error.SExpressionSyntaxError;
            }
        }

        pub fn done(self: *Self) !bool {
            if (self.state == .unknown) {
                try self.read();
            }

            return self.state == .eof;
        }

        pub fn requireDone(self: *Self) !void {
            if (!try self.done()) {
                return error.SExpressionSyntaxError;
            }
        }

        pub fn expression(self: *Self, expected: []const u8) !bool {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state == .open and std.mem.eql(u8, self.token.items, expected)) {
                self.state = .unknown;
                return true;
            } else {
                return false;
            }
        }

        pub fn requireExpression(self: *Self, expected: []const u8) !void {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state == .open and std.mem.eql(u8, self.token.items, expected)) {
                self.state = .unknown;
            } else {
                return error.SExpressionSyntaxError;
            }
        }

        pub fn anyExpression(self: *Self) !?[]const u8 {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state == .open) {
                self.state = .unknown;
                return self.token.items;
            } else {
                return null;
            }
        }

        pub fn requireAnyExpression(self: *Self) ![]const u8 {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state == .open) {
                self.state = .unknown;
                return self.token.items;
            } else {
                return error.SExpressionSyntaxError;
            }
        }

        pub fn string(self: *Self, expected: []const u8) !bool {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state == .val and std.mem.eql(u8, self.token.items, expected)) {
                self.state = .unknown;
                return true;
            } else {
                return false;
            }
        }

        pub fn requireString(self: *Self, expected: []const u8) !void {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state == .val and std.mem.eql(u8, self.token.items, expected)) {
                self.state = .unknown;
            } else {
                return error.SExpressionSyntaxError;
            }
        }

        pub fn anyString(self: *Self) !?[]const u8 {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state == .val) {
                self.state = .unknown;
                return self.token.items;
            } else {
                return null;
            }
        }

        pub fn requireAnyString(self: *Self) ![]const u8 {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state == .val) {
                self.state = .unknown;
                return self.token.items;
            } else {
                return error.SExpressionSyntaxError;
            }
        }

        pub fn anyBoolean(self: *Self) !?bool {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state != .val) {
                return null;
            }

            if (self.token.items.len <= 5) {
                var buf: [5]u8 = undefined;
                var lower = std.ascii.lowerString(&buf, self.token.items);
                if (std.mem.eql(u8, lower, "true")) {
                    self.state = .unknown;
                    return true;
                } else if (std.mem.eql(u8, lower, "false")) {
                    self.state = .unknown;
                    return false;
                }
            }

            var value = 0 != (std.fmt.parseUnsigned(u1, self.token.items, 0) catch return null);
            self.state = .unknown;
            return value;
        }
        pub fn requireAnyBoolean(self: *Self) !bool {
            return try self.anyBoolean() orelse error.SExpressionSyntaxError;
        }

        pub fn anyEnum(self: *Self, comptime T: type) !?T {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state != .val) {
                return null;
            }

            if (std.meta.stringToEnum(T, self.token.items)) |e| {
                self.state = .unknown;
                return e;
            }

            return null;
        }

        pub fn requireAnyEnum(self: *Self, comptime T: type) !T {
            return try self.anyEnum(T) orelse error.SExpressionSyntaxError;
        }

        // Takes a std.ComptimeStringMap to convert strings into the enum
        pub fn mapEnum(self: *Self, comptime T: type, map: anytype) !?T {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state != .val) {
                return null;
            }

            if (map.get(self.token.items)) |e| {
                self.state = .unknown;
                return e;
            }

            return null;
        }

        pub fn requireMapEnum(self: *Self, comptime T: type, map: anytype) !T {
            return try self.mapEnum(T, map) orelse error.SExpressionSyntaxError;
        }

        pub fn anyFloat(self: *Self, comptime T: type) !?T {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state != .val) {
                return null;
            }

            var value = std.fmt.parseFloat(T, self.token.items) catch return null;
            self.state = .unknown;
            return value;
        }
        pub fn requireAnyFloat(self: *Self, comptime T: type) !T {
            return try self.anyFloat(T) orelse error.SExpressionSyntaxError;
        }

        pub fn anyInt(self: *Self, comptime T: type, radix: u8) !?T {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state != .val) {
                return null;
            }

            var value = std.fmt.parseInt(T, self.token.items, radix) catch return null;
            self.state = .unknown;
            return value;
        }
        pub fn requireAnyInt(self: *Self, comptime T: type, radix: u8) !T {
            return try self.anyInt(T, radix) orelse error.SExpressionSyntaxError;
        }

        pub fn anyUnsigned(self: *Self, comptime T: type, radix: u8) !?T {
            if (self.state == .unknown) {
                try self.read();
            }

            if (self.state != .val) {
                return null;
            }

            var value = std.fmt.parseUnsigned(T, self.token.items, radix) catch return null;
            self.state = .unknown;
            return value;
        }
        pub fn requireAnyUnsigned(self: *Self, comptime T: type, radix: u8) !T {
            return try self.anyUnsigned(T, radix) orelse error.SExpressionSyntaxError;
        }

        // note this consumes the current expression's closing parenthesis
        pub fn ignoreRemainingExpression(self: *Self) !void {
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
                self.state = .unknown;
            }
        }

        pub fn getNextTokenContext(self: *Self) !TokenContext {
            if (self.state == .unknown) {
                try self.read();
            }
            return TokenContext {
                .prev_line_offset = self.token_start_ctx.prev_line_offset,
                .start_line_number = self.token_start_ctx.line_number,
                .start_offset = self.token_start_ctx.offset,
                .end_offset = self.ctx.offset,
            };
        }

    };
}

pub const TokenContext = struct {
    prev_line_offset: usize,
    start_line_number: usize,
    start_offset: usize,
    end_offset: usize,

    pub fn printForString(self: TokenContext, source: []const u8, print_writer: anytype, max_line_width: usize) !void {
        var offset = self.prev_line_offset;
        var line_number = self.start_line_number;
        if (line_number > 1) {
            line_number -= 1;
        }
        var iter = std.mem.split(u8, source[offset..], "\n");
        while (iter.next()) |line| {
            if (std.mem.endsWith(u8, line, "\r")) {
                try printLine(self, print_writer, line_number, offset, line[0..line.len - 1], max_line_width);
            } else {
                try printLine(self, print_writer, line_number, offset, line, max_line_width);
            }

            if (offset >= self.end_offset) {
                break;
            }

            line_number += 1;
            offset += line.len + 1;
        }
    }

    pub fn printForFile(self: TokenContext, source: *std.fs.File, print_writer: anytype, comptime max_line_width: usize) !void {
        const originalPos = try source.getPos();
        errdefer source.seekTo(originalPos) catch {}; // best effort not to change file position in case of error

        var offset = self.prev_line_offset;
        var line_number = self.start_line_number;
        if (line_number > 1) {
            line_number -= 1;
        }

        try source.seekTo(self.prev_line_offset);
        var br = std.io.bufferedReader(source.reader());
        var file_reader = br.reader();
        var line_buf: [max_line_width + 1]u8 = undefined;
        var line_length: usize = undefined;
        while (try readFileLine(file_reader, &line_buf, &line_length)) |line| {
            if (std.mem.endsWith(u8, line, "\r")) {
                try printLine(self, print_writer, line_number, offset, line[0..line.len - 1], max_line_width);
            } else {
                try printLine(self, print_writer, line_number, offset, line, max_line_width);
            }

            if (offset >= self.end_offset) {
                break;
            }

            line_number += 1;
            offset += line_length + 1;
        }

        try source.seekTo(originalPos);
    }

    fn readFileLine(file_reader: anytype, buffer: []u8, line_length: *usize) !?[]u8 {
        var line = file_reader.readUntilDelimiterOrEof(buffer, '\n') catch |e| switch (e) {
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

    fn printLine(self: TokenContext, print_writer: anytype, line_number: usize, offset: usize, line: []const u8, max_line_width: usize) !void {
        try printLineNumber(print_writer, self.start_line_number, line_number);

        var end_of_line = offset + line.len;
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
            try printLineNumberPadding(print_writer, self.start_line_number);
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

    fn printLineNumber(print_writer: anytype, initial_line: usize, line: usize) !void {
        if (initial_line < 1000) {
            try print_writer.print("{:>4} |", .{ line });
        } else if (initial_line < 100_000) {
            try print_writer.print("{:>6} |", .{ line });
        } else {
            try print_writer.print("{:>8} |", .{ line });
        }
    }
    fn printLineNumberPadding(print_writer: anytype, initial_line: usize) !void {
        if (initial_line < 1000) {
            try print_writer.writeAll("     |");
        } else if (initial_line < 100_000) {
            try print_writer.writeAll("       |");
        } else {
            try print_writer.writeAll("         |");
        }
    }
};
