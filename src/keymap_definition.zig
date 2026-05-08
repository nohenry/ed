const ctrl: u32 = 100000;
const alt: u32 = 200000;
const shift: u32 = 300000;
const movement: u32 = 400000;

pub const normal_keymap_definition = .{
    .{ 'i', "commandEnterInsertMode" },
    .{ 'v', "commandEnterVisualMode" },

    .{ 'd', movement, "commandDeleteMovement" },
    .{ 'd', 'd', "commandDeleteLine" },

    .{ .{ ctrl, 'u' }, "commandMoveUpHalfView" },
    .{ .{ ctrl, 'd' }, "commandMoveDownHalfView" },

    .{ movement, "commandMove" },
};

pub const visual_keymap_definition = .{
    .{ 'd', "commandVisualDelete" },
    .{ '*', "commandVisualSearch" },
    .{ 'n', "commandVisualSearchNext" },
    .{ 'N', "commandVisualSearchPrev" },
    .{ movement, "commandMove" },
};
