const std = @import("std");

pub fn writer(allocator: std.mem.Allocator, inner_writer: anytype) Writer(@TypeOf(inner_writer)) {
    return Writer(@TypeOf(inner_writer)).init(allocator, inner_writer);
}

pub fn Writer(comptime InnerWriter: type) type {
    return struct {
        inner: InnerWriter,
        indent: []const u8,
        compact_state: std.ArrayList(bool),
        first_in_group: bool,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, inner_writer: InnerWriter) Self {
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

        pub fn openExpanded(self: *Self) !void {
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

        pub fn setCompact(self: *Self, compact: bool) void {
            if (self.compact_state.items.len > 0) {
                self.compact_state.items[self.compact_state.items.len - 1] = compact;
            }
        }

        pub fn expression(self: *Self, name: []const u8) !void {
            try self.open();
            try self.string(name);
        }

        pub fn expressionExpanded(self: *Self, name: []const u8) !void {
            try self.open();
            try self.string(name);
            self.setCompact(false);
        }

        fn requiresQuotes(str: []const u8) bool {
            for (str) |c| {
                if (c <= ' ' or c > '~' or c == '(' or c == ')' or c == '"') {
                    return true;
                }
            }
            return false;
        }

        pub fn string(self: *Self, str: []const u8) !void {
            try self.spacing();
            if (requiresQuotes(str)) {
                try self.inner.writeByte('"');
                _ = try self.writeEscaped(str);
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

        pub fn printValue(self: *Self, comptime format: []const u8, args: anytype) !void {
            var buf: [1024]u8 = undefined;
            try self.string(std.fmt.bufPrint(&buf, format, args) catch |e| switch (e) {
                error.NoSpaceLeft => {
                    try self.inner.writeByte('"');
                    const EscapeWriter = std.io.Writer(*Self, InnerWriter.Error, writeEscaped);
                    var esc = EscapeWriter { .context = self };
                    try esc.print(format, args);
                    try self.inner.writeByte('"');
                    return;
                },
                else => return e,
            });
        }

        fn writeEscaped(self: *Self, bytes: []const u8) InnerWriter.Error!usize {
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

        pub fn printRaw(self: *Self, comptime format: []const u8, args: anytype) !void {
            try self.spacing();
            try self.inner.print(format, args);
        }

    };
}
