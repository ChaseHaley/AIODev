package ui

import "aio:render"

// The AIODev design system. Every interface size, gap, corner and height comes from here; the
// Visual language note explains each role. Values are DIPs at scale 1 and callers multiply by the
// window scale. Text sizes live in Text_Style.

// Spacing: a 4 DIP grid. Related things sit SPACE_2 apart, groups SPACE_4 apart.
SPACE_1 :: f32(4)
SPACE_2 :: f32(8)
SPACE_3 :: f32(12)
SPACE_4 :: f32(16)
SPACE_6 :: f32(24)

// Corners: in-page elements use RADIUS_CONTROL, anything floating or framing content uses
// RADIUS_OVERLAY. Elements 8 DIPs tall or less, and round marks, use half their height instead.
RADIUS_CONTROL :: f32(4)
RADIUS_OVERLAY :: f32(8)
// Chrome buttons (icon buttons, float header and capsule controls) keep their own softer corner.
RADIUS_BUTTON :: f32(6)

// Heights. Compact controls sit inside a row or header, toolbar controls in the title bar, and
// standard controls stand alone: buttons, fields, and the rows of menus and lists.
HEIGHT_COMPACT :: f32(24)
HEIGHT_TOOLBAR :: f32(28)
HEIGHT_STANDARD :: f32(32)
// Title-bar buttons: the title actions, the tab orientation toggle, and the strip's new-tab and
// profiles buttons.
TITLE_BUTTON_WIDTH :: f32(32)

// Switches and slider thumbs share one size on every surface.
SWITCH_WIDTH :: f32(40)
SWITCH_HEIGHT :: f32(20)
SLIDER_THUMB :: f32(16)
// Checkboxes: a confirmation's option and a Markdown task item.
CHECKBOX_SIZE :: f32(16)

// How far a floating surface sinks as it fades out. Dialogs and the palette sink a little; notices,
// which leave from a stack in the corner, sink further.
RISE_DIALOG :: f32(4)
RISE_NOTICE :: f32(6)

// The text inset on each side of a keycap, and its height.
KEYCAP_PADDING :: SPACE_1
KEYCAP_HEIGHT :: f32(20)
// The text inset inside a field, button or row.
CONTROL_INSET :: SPACE_2
// The padding between an overlay's edge and its rows. Row text therefore sits SPACE_3 from the edge.
OVERLAY_PADDING :: SPACE_1
// The inset of a dialog's title, body and buttons from its edge.
DIALOG_PADDING :: SPACE_4

// The radius that fully rounds the short side of `r`: for bars, grooves, underlines and dots.
pill_radius :: proc(r: render.Rect) -> f32 {return min(r.width, r.height) / 2}
