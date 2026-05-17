const std = @import("std");
const ed = @import("ed.zig");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "addrspace", .keyword_addrspace },
        .{ "align", .keyword_align },
        .{ "allowzero", .keyword_allowzero },
        .{ "and", .keyword_and },
        .{ "anyframe", .keyword_anyframe },
        .{ "anytype", .keyword_anytype },
        .{ "asm", .keyword_asm },
        .{ "break", .keyword_break },
        .{ "callconv", .keyword_callconv },
        .{ "catch", .keyword_catch },
        .{ "comptime", .keyword_comptime },
        .{ "const", .keyword_const },
        .{ "continue", .keyword_continue },
        .{ "defer", .keyword_defer },
        .{ "else", .keyword_else },
        .{ "enum", .keyword_enum },
        .{ "errdefer", .keyword_errdefer },
        .{ "error", .keyword_error },
        .{ "export", .keyword_export },
        .{ "extern", .keyword_extern },
        .{ "fn", .keyword_fn },
        .{ "for", .keyword_for },
        .{ "if", .keyword_if },
        .{ "inline", .keyword_inline },
        .{ "noalias", .keyword_noalias },
        .{ "noinline", .keyword_noinline },
        .{ "nosuspend", .keyword_nosuspend },
        .{ "opaque", .keyword_opaque },
        .{ "or", .keyword_or },
        .{ "orelse", .keyword_orelse },
        .{ "packed", .keyword_packed },
        .{ "pub", .keyword_pub },
        .{ "resume", .keyword_resume },
        .{ "return", .keyword_return },
        .{ "linksection", .keyword_linksection },
        .{ "struct", .keyword_struct },
        .{ "suspend", .keyword_suspend },
        .{ "switch", .keyword_switch },
        .{ "test", .keyword_test },
        .{ "threadlocal", .keyword_threadlocal },
        .{ "try", .keyword_try },
        .{ "union", .keyword_union },
        .{ "unreachable", .keyword_unreachable },
        .{ "var", .keyword_var },
        .{ "volatile", .keyword_volatile },
        .{ "while", .keyword_while },
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub const Tag = enum {
        invalid,
        invalid_periodasterisks,
        identifier,
        string_literal,
        multiline_string_literal_line,
        char_literal,
        eof,
        builtin,
        bang,
        pipe,
        pipe_pipe,
        pipe_equal,
        equal,
        equal_equal,
        equal_angle_bracket_right,
        bang_equal,
        l_paren,
        r_paren,
        semicolon,
        percent,
        percent_equal,
        l_brace,
        r_brace,
        l_bracket,
        r_bracket,
        period,
        period_asterisk,
        ellipsis2,
        ellipsis3,
        caret,
        caret_equal,
        plus,
        plus_plus,
        plus_equal,
        plus_percent,
        plus_percent_equal,
        plus_pipe,
        plus_pipe_equal,
        minus,
        minus_equal,
        minus_percent,
        minus_percent_equal,
        minus_pipe,
        minus_pipe_equal,
        asterisk,
        asterisk_equal,
        asterisk_asterisk,
        asterisk_percent,
        asterisk_percent_equal,
        asterisk_pipe,
        asterisk_pipe_equal,
        arrow,
        colon,
        slash,
        slash_equal,
        comma,
        ampersand,
        ampersand_equal,
        question_mark,
        angle_bracket_left,
        angle_bracket_left_equal,
        angle_bracket_angle_bracket_left,
        angle_bracket_angle_bracket_left_equal,
        angle_bracket_angle_bracket_left_pipe,
        angle_bracket_angle_bracket_left_pipe_equal,
        angle_bracket_right,
        angle_bracket_right_equal,
        angle_bracket_angle_bracket_right,
        angle_bracket_angle_bracket_right_equal,
        tilde,
        number_literal,
        line_comment,
        doc_comment,
        container_doc_comment,
        keyword_addrspace,
        keyword_align,
        keyword_allowzero,
        keyword_and,
        keyword_anyframe,
        keyword_anytype,
        keyword_asm,
        keyword_break,
        keyword_callconv,
        keyword_catch,
        keyword_comptime,
        keyword_const,
        keyword_continue,
        keyword_defer,
        keyword_else,
        keyword_enum,
        keyword_errdefer,
        keyword_error,
        keyword_export,
        keyword_extern,
        keyword_fn,
        keyword_for,
        keyword_if,
        keyword_inline,
        keyword_noalias,
        keyword_noinline,
        keyword_nosuspend,
        keyword_opaque,
        keyword_or,
        keyword_orelse,
        keyword_packed,
        keyword_pub,
        keyword_resume,
        keyword_return,
        keyword_linksection,
        keyword_struct,
        keyword_suspend,
        keyword_switch,
        keyword_test,
        keyword_threadlocal,
        keyword_try,
        keyword_union,
        keyword_unreachable,
        keyword_usingnamespace,
        keyword_var,
        keyword_volatile,
        keyword_while,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .invalid,
                .identifier,
                .string_literal,
                .multiline_string_literal_line,
                .char_literal,
                .eof,
                .builtin,
                .number_literal,
                .doc_comment,
                .line_comment,
                .container_doc_comment,
                => null,

                .invalid_periodasterisks => ".**",
                .bang => "!",
                .pipe => "|",
                .pipe_pipe => "||",
                .pipe_equal => "|=",
                .equal => "=",
                .equal_equal => "==",
                .equal_angle_bracket_right => "=>",
                .bang_equal => "!=",
                .l_paren => "(",
                .r_paren => ")",
                .semicolon => ";",
                .percent => "%",
                .percent_equal => "%=",
                .l_brace => "{",
                .r_brace => "}",
                .l_bracket => "[",
                .r_bracket => "]",
                .period => ".",
                .period_asterisk => ".*",
                .ellipsis2 => "..",
                .ellipsis3 => "...",
                .caret => "^",
                .caret_equal => "^=",
                .plus => "+",
                .plus_plus => "++",
                .plus_equal => "+=",
                .plus_percent => "+%",
                .plus_percent_equal => "+%=",
                .plus_pipe => "+|",
                .plus_pipe_equal => "+|=",
                .minus => "-",
                .minus_equal => "-=",
                .minus_percent => "-%",
                .minus_percent_equal => "-%=",
                .minus_pipe => "-|",
                .minus_pipe_equal => "-|=",
                .asterisk => "*",
                .asterisk_equal => "*=",
                .asterisk_asterisk => "**",
                .asterisk_percent => "*%",
                .asterisk_percent_equal => "*%=",
                .asterisk_pipe => "*|",
                .asterisk_pipe_equal => "*|=",
                .arrow => "->",
                .colon => ":",
                .slash => "/",
                .slash_equal => "/=",
                .comma => ",",
                .ampersand => "&",
                .ampersand_equal => "&=",
                .question_mark => "?",
                .angle_bracket_left => "<",
                .angle_bracket_left_equal => "<=",
                .angle_bracket_angle_bracket_left => "<<",
                .angle_bracket_angle_bracket_left_equal => "<<=",
                .angle_bracket_angle_bracket_left_pipe => "<<|",
                .angle_bracket_angle_bracket_left_pipe_equal => "<<|=",
                .angle_bracket_right => ">",
                .angle_bracket_right_equal => ">=",
                .angle_bracket_angle_bracket_right => ">>",
                .angle_bracket_angle_bracket_right_equal => ">>=",
                .tilde => "~",
                .keyword_addrspace => "addrspace",
                .keyword_align => "align",
                .keyword_allowzero => "allowzero",
                .keyword_and => "and",
                .keyword_anyframe => "anyframe",
                .keyword_anytype => "anytype",
                .keyword_asm => "asm",
                .keyword_break => "break",
                .keyword_callconv => "callconv",
                .keyword_catch => "catch",
                .keyword_comptime => "comptime",
                .keyword_const => "const",
                .keyword_continue => "continue",
                .keyword_defer => "defer",
                .keyword_else => "else",
                .keyword_enum => "enum",
                .keyword_errdefer => "errdefer",
                .keyword_error => "error",
                .keyword_export => "export",
                .keyword_extern => "extern",
                .keyword_fn => "fn",
                .keyword_for => "for",
                .keyword_if => "if",
                .keyword_inline => "inline",
                .keyword_noalias => "noalias",
                .keyword_noinline => "noinline",
                .keyword_nosuspend => "nosuspend",
                .keyword_opaque => "opaque",
                .keyword_or => "or",
                .keyword_orelse => "orelse",
                .keyword_packed => "packed",
                .keyword_pub => "pub",
                .keyword_resume => "resume",
                .keyword_return => "return",
                .keyword_linksection => "linksection",
                .keyword_struct => "struct",
                .keyword_suspend => "suspend",
                .keyword_switch => "switch",
                .keyword_test => "test",
                .keyword_threadlocal => "threadlocal",
                .keyword_try => "try",
                .keyword_union => "union",
                .keyword_unreachable => "unreachable",
                .keyword_usingnamespace => "usingnamespace",
                .keyword_var => "var",
                .keyword_volatile => "volatile",
                .keyword_while => "while",
            };
        }

        pub fn symbol(tag: Tag) []const u8 {
            return tag.lexeme() orelse switch (tag) {
                .invalid => "invalid bytes",
                .identifier => "an identifier",
                .string_literal, .multiline_string_literal_line => "a string literal",
                .char_literal => "a character literal",
                .eof => "EOF",
                .builtin => "a builtin function",
                .number_literal => "a number literal",
                .doc_comment, .container_doc_comment => "a document comment",
                .line_comment => "a line comment",
                else => unreachable,
            };
        }
    };
};

pub const Tokenizer = struct {
    iterator: ed.Rope.Iterator,
    buffer_length: usize,
    index: usize,
    pending_invalid_token: ?Token,
    peeked_char: ?u32 = null,

    /// For debugging purposes
    pub fn dump(self: *Tokenizer, token: *const Token) void {
        std.debug.print("{s} \"{s}\"\n", .{ @tagName(token.tag), self.buffer[token.loc.start..token.loc.end] });
    }

    pub fn init(rope: *ed.Rope) Tokenizer {
        // Skip the UTF-8 BOM if present
        return Tokenizer{
            .iterator = rope.iter(),
            .buffer_length = rope.length(),
            .index = 0,
            .pending_invalid_token = null,
        };
    }

    pub fn initStartingFrom(rope: *ed.Rope, starting_from: usize) Tokenizer {
        // Skip the UTF-8 BOM if present
        return Tokenizer{
            .iterator = rope.iterStartingFrom(starting_from),
            .buffer_length = rope.length(),
            .index = starting_from,
            .pending_invalid_token = null,
        };
    }

    const State = enum {
        start,
        identifier,
        builtin,
        string_literal,
        string_literal_backslash,
        multiline_string_literal_line,
        char_literal,
        char_literal_backslash,
        char_literal_hex_escape,
        char_literal_unicode_escape_saw_u,
        char_literal_unicode_escape,
        char_literal_unicode_invalid,
        char_literal_unicode,
        char_literal_end,
        backslash,
        equal,
        bang,
        pipe,
        minus,
        minus_percent,
        minus_pipe,
        asterisk,
        asterisk_percent,
        asterisk_pipe,
        slash,
        line_comment_start,
        line_comment,
        doc_comment_start,
        doc_comment,
        int,
        int_exponent,
        int_period,
        float,
        float_exponent,
        ampersand,
        caret,
        percent,
        plus,
        plus_percent,
        plus_pipe,
        angle_bracket_left,
        angle_bracket_angle_bracket_left,
        angle_bracket_angle_bracket_left_pipe,
        angle_bracket_right,
        angle_bracket_angle_bracket_right,
        period,
        period_2,
        period_asterisk,
        saw_at_sign,
    };

    /// This is a workaround to the fact that the tokenizer can queue up
    /// 'pending_invalid_token's when parsing literals, which means that we need
    /// to scan from the start of the current line to find a matching tag - just
    /// in case it was an invalid character generated during literal
    /// tokenization. Ideally this processing of this would be pushed to the AST
    /// parser or another later stage, both to give more useful error messages
    /// with that extra context and in order to be able to remove this
    /// workaround.
    pub fn findTagAtCurrentIndex(self: *Tokenizer, tag: Token.Tag) Token {
        if (tag == .invalid) {
            const target_index = self.index;
            var starting_index = target_index;
            while (starting_index > 0) {
                if (self.buffer[starting_index] == '\n') {
                    break;
                }
                starting_index -= 1;
            }

            self.index = starting_index;
            while (self.index <= target_index or self.pending_invalid_token != null) {
                const result = self.next();
                if (result.loc.start == target_index and result.tag == tag) {
                    return result;
                }
            }
            unreachable;
        } else {
            return self.next();
        }
    }

    pub fn next(self: *Tokenizer) Token {
        if (self.pending_invalid_token) |token| {
            self.pending_invalid_token = null;
            return token;
        }
        var state: State = .start;
        var result = Token{
            .tag = .eof,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };
        var seen_escape_digits: usize = undefined;
        var remaining_code_units: usize = undefined;
        while (true) : (self.index += 1) {
            const c = self.peeked_char orelse self.iterator.next();
            self.peeked_char = c;
            switch (state) {
                .start => switch (c orelse {
                    if (self.index != self.buffer_length) {
                        result.tag = .invalid;
                        result.loc.start = self.index;
                        self.index += 1;
                        result.loc.end = self.index;
                        return result;
                    }
                    break;
                }) {
                    ' ', '\n', '\t', '\r' => {
                        result.loc.start = self.index + 1;
                    },
                    '"' => {
                        state = .string_literal;
                        result.tag = .string_literal;
                    },
                    '\'' => {
                        state = .char_literal;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .identifier;
                        result.tag = .identifier;
                    },
                    '@' => {
                        state = .saw_at_sign;
                    },
                    '=' => {
                        state = .equal;
                    },
                    '!' => {
                        state = .bang;
                    },
                    '|' => {
                        state = .pipe;
                    },
                    '(' => {
                        self.peeked_char = null;
                        result.tag = .l_paren;
                        self.index += 1;
                        break;
                    },
                    ')' => {
                        self.peeked_char = null;
                        result.tag = .r_paren;
                        self.index += 1;
                        break;
                    },
                    '[' => {
                        self.peeked_char = null;
                        result.tag = .l_bracket;
                        self.index += 1;
                        break;
                    },
                    ']' => {
                        self.peeked_char = null;
                        result.tag = .r_bracket;
                        self.index += 1;
                        break;
                    },
                    ';' => {
                        self.peeked_char = null;
                        result.tag = .semicolon;
                        self.index += 1;
                        break;
                    },
                    ',' => {
                        self.peeked_char = null;
                        result.tag = .comma;
                        self.index += 1;
                        break;
                    },
                    '?' => {
                        self.peeked_char = null;
                        result.tag = .question_mark;
                        self.index += 1;
                        break;
                    },
                    ':' => {
                        self.peeked_char = null;
                        result.tag = .colon;
                        self.index += 1;
                        break;
                    },
                    '%' => {
                        state = .percent;
                    },
                    '*' => {
                        state = .asterisk;
                    },
                    '+' => {
                        state = .plus;
                    },
                    '<' => {
                        state = .angle_bracket_left;
                    },
                    '>' => {
                        state = .angle_bracket_right;
                    },
                    '^' => {
                        state = .caret;
                    },
                    '\\' => {
                        state = .backslash;
                        result.tag = .multiline_string_literal_line;
                    },
                    '{' => {
                        self.peeked_char = null;
                        result.tag = .l_brace;
                        self.index += 1;
                        break;
                    },
                    '}' => {
                        self.peeked_char = null;
                        result.tag = .r_brace;
                        self.index += 1;
                        break;
                    },
                    '~' => {
                        self.peeked_char = null;
                        result.tag = .tilde;
                        self.index += 1;
                        break;
                    },
                    '.' => {
                        state = .period;
                    },
                    '-' => {
                        state = .minus;
                    },
                    '/' => {
                        state = .slash;
                    },
                    '&' => {
                        state = .ampersand;
                    },
                    '0'...'9' => {
                        state = .int;
                        result.tag = .number_literal;
                    },
                    else => {
                        self.peeked_char = null;
                        result.tag = .invalid;
                        result.loc.end = self.index;
                        self.index += 1;
                        return result;
                    },
                },

                .saw_at_sign => switch (c orelse {
                    result.tag = .invalid;
                    break;
                }) {
                    '"' => {
                        result.tag = .identifier;
                        state = .string_literal;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .builtin;
                        result.tag = .builtin;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .ampersand => switch (c orelse {
                    result.tag = .ampersand;
                    break;
                }) {
                    '=' => {
                        result.tag = .ampersand_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .ampersand;
                        break;
                    },
                },

                .asterisk => switch (c orelse {
                    result.tag = .asterisk;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .asterisk_equal;
                        self.index += 1;
                        break;
                    },
                    '*' => {
                        self.peeked_char = null;
                        result.tag = .asterisk_asterisk;
                        self.index += 1;
                        break;
                    },
                    '%' => {
                        state = .asterisk_percent;
                    },
                    '|' => {
                        state = .asterisk_pipe;
                    },
                    else => {
                        result.tag = .asterisk;
                        break;
                    },
                },

                .asterisk_percent => switch (c orelse {
                    result.tag = .asterisk_percent;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .asterisk_percent_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .asterisk_percent;
                        break;
                    },
                },

                .asterisk_pipe => switch (c orelse {
                    result.tag = .asterisk_pipe;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .asterisk_pipe_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .asterisk_pipe;
                        break;
                    },
                },

                .percent => switch (c orelse {
                    result.tag = .percent;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .percent_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .percent;
                        break;
                    },
                },

                .plus => switch (c orelse {
                    result.tag = .plus;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .plus_equal;
                        self.index += 1;
                        break;
                    },
                    '+' => {
                        self.peeked_char = null;
                        result.tag = .plus_plus;
                        self.index += 1;
                        break;
                    },
                    '%' => {
                        state = .plus_percent;
                    },
                    '|' => {
                        state = .plus_pipe;
                    },
                    else => {
                        result.tag = .plus;
                        break;
                    },
                },

                .plus_percent => switch (c orelse {
                    result.tag = .plus_percent;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .plus_percent_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .plus_percent;
                        break;
                    },
                },

                .plus_pipe => switch (c orelse {
                    result.tag = .plus_pipe;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .plus_pipe_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .plus_pipe;
                        break;
                    },
                },

                .caret => switch (c orelse {
                    result.tag = .caret;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .caret_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .caret;
                        break;
                    },
                },

                .identifier => switch (c orelse {
                    break;
                }) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
                    else => {
                        //if (Token.getKeyword(self.buffer[result.loc.start..self.index])) |tag| {
                        //    result.tag = tag;
                        //}
                        break;
                    },
                },
                .builtin => switch (c orelse {
                    break;
                }) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
                    else => break,
                },
                .backslash => switch (c orelse {
                    result.tag = .invalid;
                    break;
                }) {
                    '\\' => {
                        state = .multiline_string_literal_line;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },
                .string_literal => switch (c orelse {
                    if (self.index == self.buffer_length) {
                        result.tag = .invalid;
                        break;
                    } else {
                        self.checkLiteralCharacter();
                    }
                    break;
                }) {
                    '\\' => {
                        state = .string_literal_backslash;
                    },
                    '"' => {
                        self.peeked_char = null;
                        self.index += 1;
                        break;
                    },
                    '\n' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => self.checkLiteralCharacter(),
                },

                .string_literal_backslash => switch (c orelse {
                    result.tag = .invalid;
                    break;
                }) {
                    '\n' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => {
                        state = .string_literal;
                    },
                },

                .char_literal => switch (c orelse {
                    result.tag = .invalid;
                    break;
                }) {
                    '\\' => {
                        state = .char_literal_backslash;
                    },
                    '\'', 0x80...0xbf, 0xf8...0xff => {
                        self.peeked_char = null;
                        result.tag = .invalid;
                        break;
                    },
                    0xc0...0xdf => { // 110xxxxx
                        remaining_code_units = 1;
                        state = .char_literal_unicode;
                    },
                    0xe0...0xef => { // 1110xxxx
                        remaining_code_units = 2;
                        state = .char_literal_unicode;
                    },
                    0xf0...0xf7 => { // 11110xxx
                        remaining_code_units = 3;
                        state = .char_literal_unicode;
                    },
                    '\n' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => {
                        state = .char_literal_end;
                    },
                },

                .char_literal_backslash => switch (c orelse {
                    result.tag = .invalid;
                    break;
                }) {
                    '\n' => {
                        result.tag = .invalid;
                        break;
                    },
                    'x' => {
                        state = .char_literal_hex_escape;
                        seen_escape_digits = 0;
                    },
                    'u' => {
                        state = .char_literal_unicode_escape_saw_u;
                    },
                    else => {
                        state = .char_literal_end;
                    },
                },

                .char_literal_hex_escape => switch (c orelse {
                    result.tag = .invalid;
                    break;
                }) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        seen_escape_digits += 1;
                        if (seen_escape_digits == 2) {
                            state = .char_literal_end;
                        }
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .char_literal_unicode_escape_saw_u => switch (c orelse {
                    result.tag = .invalid;
                    state = .char_literal_unicode_invalid;
                    continue;
                }) {
                    '{' => {
                        state = .char_literal_unicode_escape;
                    },
                    else => {
                        result.tag = .invalid;
                        state = .char_literal_unicode_invalid;
                    },
                },

                .char_literal_unicode_escape => switch (c orelse {
                    result.tag = .invalid;
                    state = .char_literal_unicode_invalid;
                    continue;
                }) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {},
                    '}' => {
                        state = .char_literal_end; // too many/few digits handled later
                    },
                    else => {
                        result.tag = .invalid;
                        state = .char_literal_unicode_invalid;
                    },
                },

                .char_literal_unicode_invalid => switch (c orelse {
                    break;
                }) {
                    // Keep consuming characters until an obvious stopping point.
                    // This consolidates e.g. `u{0ab1Q}` into a single invalid token
                    // instead of creating the tokens `u{0ab1`, `Q`, `}`
                    '0'...'9', 'a'...'z', 'A'...'Z', '}' => {},
                    else => break,
                },

                .char_literal_end => switch (c orelse {
                    result.tag = .invalid;
                    break;
                }) {
                    '\'' => {
                        self.peeked_char = null;
                        result.tag = .char_literal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .char_literal_unicode => switch (c orelse {
                    result.tag = .invalid;
                    break;
                }) {
                    0x80...0xbf => {
                        remaining_code_units -= 1;
                        if (remaining_code_units == 0) {
                            state = .char_literal_end;
                        }
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .multiline_string_literal_line => switch (c orelse {
                    break;
                }) {
                    '\n' => {
                        self.peeked_char = null;
                        self.index += 1;
                        break;
                    },
                    '\t' => {},
                    else => self.checkLiteralCharacter(),
                },

                .bang => switch (c orelse {
                    result.tag = .bang;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .bang_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .bang;
                        break;
                    },
                },

                .pipe => switch (c orelse {
                    result.tag = .pipe;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .pipe_equal;
                        self.index += 1;
                        break;
                    },
                    '|' => {
                        self.peeked_char = null;
                        result.tag = .pipe_pipe;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .pipe;
                        break;
                    },
                },

                .equal => switch (c orelse {
                    result.tag = .equal;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .equal_equal;
                        self.index += 1;
                        break;
                    },
                    '>' => {
                        self.peeked_char = null;
                        result.tag = .equal_angle_bracket_right;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .equal;
                        break;
                    },
                },

                .minus => switch (c orelse {
                    result.tag = .minus;
                    break;
                }) {
                    '>' => {
                        self.peeked_char = null;
                        result.tag = .arrow;
                        self.index += 1;
                        break;
                    },
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .minus_equal;
                        self.index += 1;
                        break;
                    },
                    '%' => {
                        state = .minus_percent;
                    },
                    '|' => {
                        state = .minus_pipe;
                    },
                    else => {
                        result.tag = .minus;
                        break;
                    },
                },

                .minus_percent => switch (c orelse {
                    result.tag = .minus_percent;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .minus_percent_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .minus_percent;
                        break;
                    },
                },
                .minus_pipe => switch (c orelse {
                    result.tag = .minus_pipe;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .minus_pipe_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .minus_pipe;
                        break;
                    },
                },

                .angle_bracket_left => switch (c orelse {
                    result.tag = .angle_bracket_left;
                    break;
                }) {
                    '<' => {
                        state = .angle_bracket_angle_bracket_left;
                    },
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .angle_bracket_left_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .angle_bracket_left;
                        break;
                    },
                },

                .angle_bracket_angle_bracket_left => switch (c orelse {
                    result.tag = .angle_bracket_angle_bracket_left;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .angle_bracket_angle_bracket_left_equal;
                        self.index += 1;
                        break;
                    },
                    '|' => {
                        state = .angle_bracket_angle_bracket_left_pipe;
                    },
                    else => {
                        result.tag = .angle_bracket_angle_bracket_left;
                        break;
                    },
                },

                .angle_bracket_angle_bracket_left_pipe => switch (c orelse {
                    result.tag = .angle_bracket_angle_bracket_left_pipe;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .angle_bracket_angle_bracket_left_pipe_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .angle_bracket_angle_bracket_left_pipe;
                        break;
                    },
                },

                .angle_bracket_right => switch (c orelse {
                    result.tag = .angle_bracket_right;
                    break;
                }) {
                    '>' => {
                        state = .angle_bracket_angle_bracket_right;
                    },
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .angle_bracket_right_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .angle_bracket_right;
                        break;
                    },
                },

                .angle_bracket_angle_bracket_right => switch (c orelse {
                    result.tag = .angle_bracket_angle_bracket_right;
                    break;
                }) {
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .angle_bracket_angle_bracket_right_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .angle_bracket_angle_bracket_right;
                        break;
                    },
                },

                .period => switch (c orelse {
                    result.tag = .period;
                    break;
                }) {
                    '.' => {
                        state = .period_2;
                    },
                    '*' => {
                        state = .period_asterisk;
                    },
                    else => {
                        result.tag = .period;
                        break;
                    },
                },

                .period_2 => switch (c orelse {
                    result.tag = .ellipsis2;
                    break;
                }) {
                    '.' => {
                        self.peeked_char = null;
                        result.tag = .ellipsis3;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .ellipsis2;
                        break;
                    },
                },

                .period_asterisk => switch (c orelse {
                    result.tag = .period_asterisk;
                    break;
                }) {
                    '*' => {
                        self.peeked_char = null;
                        result.tag = .invalid_periodasterisks;
                        // todo: doesn't this need index += 1???
                        break;
                    },
                    else => {
                        result.tag = .period_asterisk;
                        break;
                    },
                },

                .slash => switch (c orelse {
                    result.tag = .slash;
                    break;
                }) {
                    '/' => {
                        state = .line_comment_start;
                    },
                    '=' => {
                        self.peeked_char = null;
                        result.tag = .slash_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .slash;
                        break;
                    },
                },
                .line_comment_start => switch (c orelse {
                    result.tag = .line_comment;
                    break;
                }) {
                    '/' => {
                        state = .doc_comment_start;
                    },
                    '!' => {
                        result.tag = .container_doc_comment;
                        state = .doc_comment;
                    },
                    '\n' => {
                        self.peeked_char = null;
                        result.tag = .line_comment;
                        // state = .start;
                        //result.loc.start = self.index + 1;
                        break;
                    },
                    '\t' => state = .line_comment,
                    else => {
                        state = .line_comment;
                        result.tag = .line_comment;
                        self.checkLiteralCharacter();
                    },
                },
                .doc_comment_start => switch (c orelse {
                    result.tag = .doc_comment;
                    break;
                }) {
                    '/' => {
                        state = .line_comment;
                    },
                    '\n' => {
                        self.peeked_char = null;
                        result.tag = .doc_comment;
                        break;
                    },
                    '\t' => {
                        state = .doc_comment;
                        result.tag = .doc_comment;
                    },
                    else => {
                        state = .doc_comment;
                        result.tag = .doc_comment;
                        self.checkLiteralCharacter();
                    },
                },
                .line_comment => switch (c orelse {
                    break;
                }) {
                    '\n' => break,
                    '\t' => {},
                    else => self.checkLiteralCharacter(),
                },
                .doc_comment => switch (c orelse {
                    break;
                }) {
                    '\n' => break,
                    '\t' => {},
                    else => self.checkLiteralCharacter(),
                },
                .int => switch (c orelse {
                    break;
                }) {
                    '.' => state = .int_period,
                    '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {},
                    'e', 'E', 'p', 'P' => state = .int_exponent,
                    else => break,
                },
                .int_exponent => switch (c orelse {
                    self.index -= 1;
                    state = .int;
                    continue;
                }) {
                    '-', '+' => {
                        state = .float;
                    },
                    else => {
                        self.index -= 1;
                        state = .int;
                    },
                },
                .int_period => switch (c orelse {
                    self.index -= 1;
                    break;
                }) {
                    '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                        state = .float;
                    },
                    'e', 'E', 'p', 'P' => state = .float_exponent,
                    else => {
                        self.index -= 1;
                        break;
                    },
                },
                .float => switch (c orelse {
                    break;
                }) {
                    '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {},
                    'e', 'E', 'p', 'P' => state = .float_exponent,
                    else => break,
                },
                .float_exponent => switch (c orelse {
                    self.index -= 1;
                    state = .float;
                    continue;
                }) {
                    '-', '+' => state = .float,
                    else => {
                        self.index -= 1;
                        state = .float;
                    },
                },
            }
            self.peeked_char = null;
        }

        if (result.tag == .eof) {
            if (self.pending_invalid_token) |token| {
                self.pending_invalid_token = null;
                return token;
            }
            result.loc.start = self.index;
        }

        result.loc.end = self.index;
        return result;
    }

    fn checkLiteralCharacter(self: *Tokenizer) void {
        if (self.pending_invalid_token != null) return;
        const invalid_length = self.getInvalidCharacterLength();
        if (invalid_length == 0) return;
        self.pending_invalid_token = .{
            .tag = .invalid,
            .loc = .{
                .start = self.index,
                .end = self.index + invalid_length,
            },
        };
    }

    fn getInvalidCharacterLength(self: *Tokenizer) u3 {
        _ = self;
        return 0;
        //const c0 = self.buffer[self.index];
        //if (std.ascii.isASCII(c0)) {
        //    if (c0 == '\r') {
        //        if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '\n') {
        //            // Carriage returns are *only* allowed just before a linefeed as part of a CRLF pair, otherwise
        //            // they constitute an illegal byte!
        //            return 0;
        //        } else {
        //            return 1;
        //        }
        //    } else if (std.ascii.isControl(c0)) {
        //        // ascii control codes are never allowed
        //        // (note that \n was checked before we got here)
        //        return 1;
        //    }
        //    // looks fine to me.
        //    return 0;
        //} else {
        //    // check utf8-encoded character.
        //    const length = std.unicode.utf8ByteSequenceLength(c0) catch return 1;
        //    if (self.index + length > self.buffer.len) {
        //        return @as(u3, @intCast(self.buffer.len - self.index));
        //    }
        //    const bytes = self.buffer[self.index .. self.index + length];
        //    switch (length) {
        //        2 => {
        //            const value = std.unicode.utf8Decode2(bytes) catch return length;
        //            if (value == 0x85) return length; // U+0085 (NEL)
        //        },
        //        3 => {
        //            const value = std.unicode.utf8Decode3(bytes) catch return length;
        //            if (value == 0x2028) return length; // U+2028 (LS)
        //            if (value == 0x2029) return length; // U+2029 (PS)
        //        },
        //        4 => {
        //            _ = std.unicode.utf8Decode4(bytes) catch return length;
        //        },
        //        else => unreachable,
        //    }
        //    self.index += length - 1;
        //    return 0;
        //}
    }
};
