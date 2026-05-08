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

    // .{ 'r', character, "commandReplace" },
    // .{ 'f', character, "commandFindNext" },
    // .{ 'F', character, "commandFindPrevious" },
    // .{ 't', character, "commandFindTillNext" },
    // .{ 'T', character, "commandFindTillPrevious" },
    // .{ 'T', character, "commandFindTillPrevious" },
    // .{ ';', "commandFindAgainNext" },
    // .{ ',', "commandFindAgainPrev" },

    .{ 'd', movement, "commandDeleteMovement" },
    .{ 'd', 'd', "commandDeleteLine" },

    .{ 'c', movement, "commandChangeMovement" },

    .{ 'x', "commandDeleteUnder" },

    .{ .{ ctrl, 'u' }, "commandMoveUpHalfView" },
    .{ .{ ctrl, 'd' }, "commandMoveDownHalfView" },

    .{ 'z', character, 't', movement, "fjkldsjf" },

    .{ movement, "commandMove" },
};

pub const visual_keymap_definition = .{
    .{ 'd', "commandVisualDelete" },
    .{ 'c', "commandVisualChange" },
    .{ 'x', "commandDeleteUnder" },

    .{ 'r', character, "commandReplace" },
    .{ 'f', character, "commandFindNext" },
    .{ 'F', character, "commandFindPrevious" },
    .{ 't', character, "commandFindTillNext" },
    .{ 'T', character, "commandFindTillPrevious" },
    .{ 'T', character, "commandFindTillPrevious" },
    .{ ';', "commandFindAgainNext" },
    .{ ',', "commandFindAgainPrev" },

    .{ '*', "commandVisualSearch" },
    .{ '#', "commandVisualSearchReverse" },
    .{ 'n', "commandVisualSearchNext" },
    .{ 'N', "commandVisualSearchPrev" },

    .{ .{ ctrl, 'u' }, "commandMoveUpHalfView" },
    .{ .{ ctrl, 'd' }, "commandMoveDownHalfView" },

    .{ movement, "commandMove" },
};
