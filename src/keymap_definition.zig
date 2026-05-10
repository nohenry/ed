const ctrl: u32 = 100000;
const alt: u32 = 200000;
const shift: u32 = 300000;
const movement: u32 = 400000;
const character: u32 = 500000;

pub const normal_keymap_definition = .{
    .{ 'i', "commandEnterInsertMode" },
    .{ 'a', "commandEnterInsertModeAppend" },
    .{ 'I', "commandEnterInsertModeStartOfLine" },
    .{ 'A', "commandEnterInsertModeEndOfLine" },
    .{ 'O', "commandEnterInsertModeAboveLine" },
    .{ 'o', "commandEnterInsertModeBelowLine" },
    .{ 'v', "commandEnterVisualMode" },
    .{ 'V', "commandEnterVisualLineMode" },

    .{ 'd', movement, "commandDeleteMovement" },
    .{ 'd', 'd', "commandDeleteLine" },

    .{ 'c', movement, "commandChangeMovement" },

    .{ 'y', movement, "commandYankMovement" },
    .{ 'y', 'y', "commandYankLine" },

    .{ 'p', "commandPasteAfter" },
    .{ 'P', "commandPasteBefore" },

    .{ 'x', "commandDeleteUnder" },

    .{ .{ ctrl, 'u' }, "commandMoveUpHalfView" },
    .{ .{ ctrl, 'd' }, "commandMoveDownHalfView" },


    .{ '>', "commandIndentIn" },
    .{ '<', "commandIndentOut" },

    .{ 'n', "commandVisualSearchNext" },
    .{ 'N', "commandVisualSearchPrev" },

    .{ movement, "commandMove" },
};

pub const visual_keymap_definition = .{
    .{ 'd', "commandVisualDelete" },
    .{ 'c', "commandVisualChange" },
    .{ 'x', "commandDeleteUnder" },

    .{ 'y', "commandVisualYank" },

    .{ '*', "commandVisualSearch" },
    .{ '#', "commandVisualSearchReverse" },
    .{ 'n', "commandVisualSearchNext" },
    .{ 'N', "commandVisualSearchPrev" },

    .{ .{ ctrl, 'u' }, "commandMoveUpHalfView" },
    .{ .{ ctrl, 'd' }, "commandMoveDownHalfView" },

    .{ '>', "commandIndentIn" },
    .{ '<', "commandIndentOut" },

    .{ movement, "commandMove" },
};
