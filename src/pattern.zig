const std = @import("std");

kind: enum {
    Literal,
    Sequence,
    Alternatives,
    Zero_Or_One,
    One_Or_More,
    Zero_Or_More,
    Word,
},

pub const Pattern = union(enum) {
    literal: []const u8,
    sequence: []const *Pattern,
    alternatives: []const *Pattern,
    zero_or_one: *Pattern,
    one_or_more: *Pattern,
    zero_or_more: *Pattern,

    pub fn matchesWithIterator(self: *const Pattern, comptime nextFn: anytype, nextFnIterator: anytype) struct { bool, usize } {
        var len: usize = 0;
        switch (self.*) {
            .literal => |a| {
                const saved = nextFnIterator.save();
                var i: usize = 0;
                while (i < a.len) : (i += 1) {
                    if (nextFn(nextFnIterator)) |c| {
                        if (c != a[i]) break;
                    } else break;
                }
                return if (i == a.len) .{ true, a.len } else {
                    nextFnIterator.restore(saved);
                    return .{ false, 0 };
                };
            },
            .sequence => |a| {
                const saved = nextFnIterator.save();
                for (a) |item| {
                    const matched, const match_length = item.matchesWithIterator(nextFn, nextFnIterator);
                    len += match_length;
                    if (!matched) {
                        nextFnIterator.restore(saved);
                        return .{ false, len };
                    }
                }
                return .{ true, len };
            },
            .alternatives => |a| {
                const saved = nextFnIterator.save();
                var largest_match: usize = 0;
                var at_least_one_match = false;
                for (a) |item| {
                    const matched, const match_length = item.matchesWithIterator(nextFn, nextFnIterator);
                    at_least_one_match = at_least_one_match or matched;
                    if (match_length > largest_match) largest_match = match_length;
                }
                if (!at_least_one_match) nextFnIterator.restore(saved);
                return .{ at_least_one_match, largest_match };
            },
            .zero_or_one => |a| {
                const matched, const match_length = a.matchesWithIterator(nextFn, nextFnIterator);
                return if (matched) .{ true, match_length } else .{ true, 0 };
            },
            .one_or_more => |a| {
                var matched, var match_length = a.matchesWithIterator(nextFn, nextFnIterator);
                if (!matched) return .{ false, 0 };
                len += match_length;
                while (matched) {
                    matched, match_length = a.matchesWithIterator(nextFn, nextFnIterator);
                    len += match_length;
                }
                return .{ true, len };
            },
            .zero_or_more => |a| {
                var matched, var match_length = a.matchesWithIterator(nextFn, nextFnIterator);
                len += match_length;
                while (matched) {
                    matched, match_length = a.matchesWithIterator(nextFn, nextFnIterator);
                    len += match_length;
                }
                return .{ true, len };
            },
        }
    }

    pub fn matches(self: *Pattern, string: []const u8) struct { bool, usize } {
        var len: usize = 0;
        switch (self.*) {
            .literal => |a| return if (std.mem.startsWith(u8, string, a)) .{ true, a.len } else .{ false, 0 },
            .sequence => |a| {
                for (a) |item| {
                    const matched, const match_length = item.matches(string[len..]);
                    len += match_length;
                    if (!matched) return .{ false, len };
                }
                return .{ true, len };
            },
            .alternatives => |a| {
                var largest_match: usize = 0;
                var at_least_one_match = false;
                for (a) |item| {
                    const matched, const match_length = item.matches(string);
                    at_least_one_match = at_least_one_match or matched;
                    if (match_length > largest_match) largest_match = match_length;
                }
                return .{ at_least_one_match, largest_match };
            },
            .zero_or_one => |a| {
                const matched, const match_length = a.matches(string);
                return if (matched) .{ true, match_length } else .{ true, 0 };
            },
            .one_or_more => |a| {
                var matched, var match_length = a.matches(string);
                if (!matched) return .{ false, 0 };
                len += match_length;
                while (matched) {
                    matched, match_length = a.matches(string[len..]);
                    len += match_length;
                }
                return .{ true, len };
            },
            .zero_or_more => |a| {
                var matched, var match_length = a.matches(string);
                len += match_length;
                while (matched) {
                    matched, match_length = a.matches(string[len..]);
                    len += match_length;
                }
                return .{ true, len };
            },
        }
    }

    pub fn parse(pattern: []const u8, allocator: std.mem.Allocator) *Pattern {
        var state = Parser{ .pattern = pattern, .allocator = allocator };
        const result = state.parsePatternImpl();
        return result;
    }

    pub fn parseTokenBased(pattern: []const u8, allocator: std.mem.Allocator) *Pattern {
        var state = TokenBasedParser{ .pattern = pattern, .allocator = allocator };
        const result = state.parsePatternImpl();
        return result;
    }

    pub fn format(self: *const Pattern, w: *std.Io.Writer) !void {
        try self.formatImpl(w, 0);
    }

    pub fn formatImpl(self: *const Pattern, w: *std.Io.Writer, indent: usize) !void {
        for (0..indent) |_| _ = try w.writeAll("   ");

        switch (self.*) {
            .literal => |a| try w.print("Pattern Literal '{s}'\n", .{a}),
            .sequence => |a| {
                try w.print("Pattern Sequence:\n", .{});
                for (a) |item| {
                    try item.formatImpl(w, indent + 1);
                }
            },
            .alternatives => |a| {
                try w.print("Pattern Alternatives:\n", .{});
                for (a) |item| {
                    try item.formatImpl(w, indent + 1);
                }
            },
            .zero_or_one => |a| {
                try w.print("Pattern ?:\n", .{});
                try a.formatImpl(w, indent + 1);
            },
            .one_or_more => |a| {
                try w.print("Pattern +:\n", .{});
                try a.formatImpl(w, indent + 1);
            },
            .zero_or_more => |a| {
                try w.print("Pattern *:\n", .{});
                try a.formatImpl(w, indent + 1);
            },
        }
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    cursor: usize = 0,
    literal_start: usize = 0,
    current: ?*Pattern = null,

    fn createPattern(self: *Parser, pattern: Pattern) *Pattern {
        const result = self.allocator.create(Pattern) catch @panic("OOM");
        result.* = pattern;
        return result;
    }

    fn ensureCurrent(self: *Parser, sequence: *std.ArrayList(*Pattern)) void {
        if (self.cursor > self.literal_start) {
            if (self.current) |current| {
                sequence.append(self.allocator, current) catch @panic("OOM");
            }
            self.current = self.createPattern(.{ .literal = self.pattern[self.literal_start..self.cursor] });
        }
    }

    fn consumeCurrent(self: *Parser) *Pattern {
        defer self.current = null;
        return self.current.?;
    }

    fn flushSequence(self: *Parser, sequence: *std.ArrayList(*Pattern), comptime finish_sequence: bool) *Pattern {
        defer self.current = null;

        if (self.cursor > self.literal_start) {
            if (self.current) |current| {
                sequence.append(self.allocator, current) catch @panic("OOM");
            }

            const literal = self.createPattern(.{ .literal = self.pattern[self.literal_start..self.cursor] });
            if (finish_sequence and sequence.items.len == 0) return literal;
            sequence.append(self.allocator, literal) catch @panic("OOM");
        } else if (self.current) |current| {
            if (finish_sequence and sequence.items.len == 0) return current;
            sequence.append(self.allocator, current) catch @panic("OOM");
        }
        self.current = null;

        if (finish_sequence) {
            const result = if (sequence.items.len == 1)
                sequence.items[0]
            else
                self.createPattern(.{ .sequence = sequence.items });
            sequence.items.len = 0;
            return result;
        } else {
            return undefined;
        }
    }

    fn parsePatternImpl(self: *Parser) *Pattern {
        var sb = std.ArrayList(*Pattern).empty;

        while (self.cursor < self.pattern.len) {
            const c = self.pattern[self.cursor];
            switch (c) {
                '?' => {
                    self.ensureCurrent(&sb);

                    const pattern = self.createPattern(.{ .zero_or_one = self.consumeCurrent() });
                    sb.append(self.allocator, pattern) catch @panic("OOM");

                    self.cursor += 1;
                    self.literal_start = self.cursor;
                },
                '+' => {
                    self.ensureCurrent(&sb);

                    const pattern = self.createPattern(.{ .one_or_more = self.consumeCurrent() });
                    sb.append(self.allocator, pattern) catch @panic("OOM");

                    self.cursor += 1;
                    self.literal_start = self.cursor;
                },
                '*' => {
                    self.ensureCurrent(&sb);

                    const pattern = self.createPattern(.{ .zero_or_more = self.consumeCurrent() });
                    sb.append(self.allocator, pattern) catch @panic("OOM");

                    self.cursor += 1;
                    self.literal_start = self.cursor;
                },
                '|' => {
                    const flushedPattern = self.flushSequence(&sb, true);

                    var sb1 = std.ArrayList(*Pattern).empty;
                    sb1.append(self.allocator, flushedPattern) catch @panic("OOM");

                    while (self.cursor < self.pattern.len and self.pattern[self.cursor] == '|') {
                        self.cursor += 1;
                        self.literal_start = self.cursor;

                        const item = self.parsePatternImpl();
                        sb1.append(self.allocator, item) catch @panic("OOM");
                    }

                    if (sb1.items.len == 1) {
                        self.current = sb1.items[0];
                    } else {
                        self.current = self.createPattern(.{ .alternatives = sb1.items });
                    }

                    self.literal_start = self.cursor;
                },
                '(' => {
                    _ = self.flushSequence(&sb, false);

                    self.cursor += 1;
                    self.literal_start = self.cursor;

                    self.current = self.parsePatternImpl();

                    self.cursor += 1;
                    self.literal_start = self.cursor;
                },
                ')' => break,
                '\\' => {
                    self.cursor += 1;
                    if (self.cursor < self.pattern.len) {
                        // switch (self.pattern[self.cursor]) {}
                    }
                },
                else => self.cursor += 1,
            }
        }

        return self.flushSequence(&sb, true);
    }
};

/// Precedence is token based, not char based.
/// foo+ means one ore more foos.
/// one two
const TokenBasedParser = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    cursor: usize = 0,
    literal_start: usize = 0,
    current: ?*Pattern = null,

    fn createPattern(self: *TokenBasedParser, pattern: Pattern) *Pattern {
        const result = self.allocator.create(Pattern) catch @panic("OOM");
        result.* = pattern;
        return result;
    }

    fn ensureCurrent(self: *TokenBasedParser, sequence: *std.ArrayList(*Pattern)) void {
        if (self.cursor > self.literal_start) {
            if (self.current) |current| {
                sequence.append(self.allocator, current) catch @panic("OOM");
            }
            self.current = self.createPattern(.{ .literal = self.pattern[self.literal_start..self.cursor] });
        }
    }

    fn consumeCurrent(self: *TokenBasedParser) *Pattern {
        defer self.current = null;
        return self.current.?;
    }

    fn flushSequence(self: *TokenBasedParser, sequence: *std.ArrayList(*Pattern), comptime finish_sequence: bool) *Pattern {
        defer self.current = null;

        if (self.cursor > self.literal_start) {
            if (self.current) |current| {
                sequence.append(self.allocator, current) catch @panic("OOM");
            }

            const literal = self.createPattern(.{ .literal = self.pattern[self.literal_start..self.cursor] });
            if (finish_sequence and sequence.items.len == 0) return literal;
            sequence.append(self.allocator, literal) catch @panic("OOM");
        } else if (self.current) |current| {
            if (finish_sequence and sequence.items.len == 0) return current;
            sequence.append(self.allocator, current) catch @panic("OOM");
        }
        self.current = null;

        if (finish_sequence) {
            const result = if (sequence.items.len == 1)
                sequence.items[0]
            else
                self.createPattern(.{ .sequence = sequence.items });
            sequence.items.len = 0;
            return result;
        } else {
            return undefined;
        }
    }

    fn parsePatternImpl(self: *TokenBasedParser) *Pattern {
        var sb = std.ArrayList(*Pattern).empty;

        while (self.cursor < self.pattern.len) {
            const c = self.pattern[self.cursor];
            switch (c) {
                '?' => {
                    self.ensureCurrent(&sb);

                    const pattern = self.createPattern(.{ .zero_or_one = self.consumeCurrent() });
                    self.current = pattern;

                    self.cursor += 1;
                    self.literal_start = self.cursor;
                },
                '+' => {
                    self.ensureCurrent(&sb);

                    const pattern = self.createPattern(.{ .one_or_more = self.consumeCurrent() });
                    self.current = pattern;

                    self.cursor += 1;
                    self.literal_start = self.cursor;
                },
                '*' => {
                    self.ensureCurrent(&sb);

                    const pattern = self.createPattern(.{ .zero_or_more = self.consumeCurrent() });
                    self.current = pattern;

                    self.cursor += 1;
                    self.literal_start = self.cursor;
                },
                '|' => {
                    // const flushedPattern = self.flushSequence(&sb, true);
                    self.ensureCurrent(&sb);

                    var sb1 = std.ArrayList(*Pattern).empty;
                    // sb1.append(self.allocator, flushedPattern) catch @panic("OOM");
                    sb1.append(self.allocator, self.current.?) catch @panic("OOM");
                    self.current = null;

                    while (self.cursor < self.pattern.len and self.pattern[self.cursor] == '|') {
                        self.cursor += 1;
                        self.literal_start = self.cursor;

                        const item = self.parsePatternImpl();
                        sb1.append(self.allocator, item) catch @panic("OOM");
                    }

                    if (sb1.items.len == 1) {
                        self.current = sb1.items[0];
                    } else {
                        self.current = self.createPattern(.{ .alternatives = sb1.items });
                    }

                    self.literal_start = self.cursor;
                },
                '(' => {
                    _ = self.flushSequence(&sb, false);

                    self.cursor += 1;
                    self.literal_start = self.cursor;

                    self.current = self.parsePatternImpl();

                    self.cursor += 1;
                    self.literal_start = self.cursor;
                },
                ')' => break,
                '\\' => {
                    self.cursor += 1;
                    if (self.cursor < self.pattern.len) {
                        // switch (self.pattern[self.cursor]) {}
                    }
                },
                ' ', '\t', '\r', '\n' => {
                    _ = self.flushSequence(&sb, false);
                    self.literal_start = self.cursor;
                    while (self.cursor < self.pattern.len) : (self.cursor += 1) {
                        switch (self.pattern[self.cursor]) {
                            ' ', '\t', '\r', '\n' => {},
                            else => break,
                        }
                    }
                    self.ensureCurrent(&sb);
                    self.literal_start = self.cursor;
                },
                else => self.cursor += 1,
            }
        }

        return self.flushSequence(&sb, true);
    }
};
