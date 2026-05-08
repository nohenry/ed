const Self = @This();

pub const Selection = struct {
    /// The part of the cursor that is moveable, and is rendered
    head: usize = 0,
    /// The other end of the cursor from head
    tail: usize = 0,

    pub inline fn containsPosition(self: @This(), position: usize) bool {
        return (position >= self.tail and position <= self.head) or (position >= self.head and position <= self.tail);
    }

    pub inline fn getOrdered(self: @This()) struct { usize, usize } {
        return if (self.head >= self.tail) .{ self.tail, self.head } else .{ self.head, self.tail };
    }
};

/// Index of the character at the top of the screen
start_position: usize = 0,
// cursor_position: usize = 0,

/// Index of the character the cursor is on
cursor: Selection = .{},

/// When moving downwards, we save the column value that we were on.
max_column: usize = 0,
lines: u32 = 0,
columns: u32 = 0,
