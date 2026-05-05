const Self = @This();

/// Index of the character at the top of the screen
start_position: usize = 0,
/// Index of the character the cursor is on
cursor_position: usize = 0,
/// When moving downwards, we save the column value that we were on.
max_column: usize = 0,
lines: u32 = 0,
columns: u32 = 0,
