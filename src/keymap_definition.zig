const ctrl: u32 = 100000;
const alt: u32 = 200000;
const shift: u32 = 300000;
const movement: u32 = 400000;

pub const keymap_definition = .{
    .{ 'i', "commandEnterInsertMode" },
    .{ 'd', movement, "commandDeleteMovement" },
    .{ 'd', 'd', "commandDeleteLine" },
    .{ movement, "commandMove" },
    // .{ 'd', "d_command" },
    // .{ .{ ctrl, 'd' }, "go_down" },
    // .{ 'd', 'a', "d_a_command" },
    // .{ 'a', "a_command" },
};
