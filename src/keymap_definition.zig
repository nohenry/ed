const ctrl: u32 = 100000;
const alt: u32 = 200000;
const shift: u32 = 300000;
const movement: u32 = 400000;
const character: u32 = 500000;

pub const line_input_keymap_definition = .{
    .{ .{ ctrl, 'a' }, "commandLineInputStartOfLine" },
    .{ .{ ctrl, 'e' }, "commandLineInputEndOfLine" },
    .{ .{ ctrl, 'b' }, "commandLineInputLeft" },
    .{ .{ ctrl, 'f' }, "commandLineInputRight" },
    .{ .{ alt, 'd' }, "commandLineInputDeleteWordForward" },
    .{ .{ alt, 'b' }, "commandLineInputGoBackWord" },
    .{ .{ alt, 'f' }, "commandLineInputGoForwardWord" },
};

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

    .{ '/', "commandEnterSearchMode" },
    .{ ':', "commandEnterCommandMode" },

    .{ movement, "commandMove" },
};

pub const visual_keymap_definition = .{
    .{ 'd', "commandVisualDelete" },
    .{ 'c', "commandVisualChange" },
    .{ 'x', "commandVisualDelete" },

    .{ 'y', "commandVisualYank" },

    .{ '*', "commandVisualSearch" },
    .{ '#', "commandVisualSearchReverse" },
    .{ 'n', "commandVisualSearchNext" },
    .{ 'N', "commandVisualSearchPrev" },

    .{ .{ ctrl, 'u' }, "commandMoveUpHalfView" },
    .{ .{ ctrl, 'd' }, "commandMoveDownHalfView" },

    .{ '>', "commandIndentIn" },
    .{ '<', "commandIndentOut" },

    .{ 'i', character, "commandVisualTextObjectInner" },
    .{ 'a', character, "commandVisualTextObjectOuter" },

    .{ movement, "commandMove" },
};
