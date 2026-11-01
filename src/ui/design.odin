package ui

// Shape and spacing tokens from the Visual language note. Values are DIPs at scale 1; callers
// multiply by the window scale. Spacing uses the steps 2, 4, 6, 8, 10, 12, 16 and 24.

// Indicator bars, checked marks and the small frames inside icons.
RADIUS_MARK :: f32(2)
// Rows and cells inside a popover, keycaps and checkboxes: the popover radius less its padding.
RADIUS_INNER :: f32(4)
// Buttons, fields, dropdowns, swatches, tooltips and list rows outside popovers.
RADIUS_CONTROL :: f32(6)
// Title bar tabs.
RADIUS_TAB :: f32(7)
// Surfaces anchored to a control: menus, dropdown lists, pickers, the find bar and notices.
RADIUS_POPOVER :: f32(8)
// Centred surfaces over a scrim: the command palette, confirmations and rename.
RADIUS_DIALOG :: f32(10)

// The padding between a popover's edge and its rows, so RADIUS_INNER rows nest concentrically.
POPOVER_PADDING :: f32(4)
// The inset of a dialog's title, body and buttons from its edge.
DIALOG_PADDING :: f32(16)

// The height of a button or one-line field in dialogs, popovers and settings rows.
CONTROL_HEIGHT :: f32(30)
// The height of a row inside a popover or dropdown list.
POPOVER_ROW_HEIGHT :: f32(30)
// The space between the text and the edge of a field or text button.
CONTROL_INSET :: f32(10)
