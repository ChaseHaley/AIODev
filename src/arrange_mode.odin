package main

import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:ui"

// Arrange mode (WORK-477), a submap for panes as Hyprland has for windows: Arrange Panes takes the window's
// keys until Enter or Esc, and plain keys move, swap and resize the focused pane while it wears the drag's
// drop outline and a card lists the keys. Every key runs a registry command, so the mode does exactly what
// those commands do; moving the pane to another tab or window keeps the mode on it. A press anywhere,
// opening the palette or the window losing focus also leaves, and leaving keeps every change. Other keys
// are swallowed, so nothing typed reaches a program. The mode's keys are fixed.

// What a direction key does, by the modifiers held with it.
@(private = "file")
Arrange_Step :: enum u8 {
	Move,
	Swap,
	Resize,
	Resize_More,
	Pick,
	Dock,
}

@(private = "file", rodata)
ARRANGE_STEP_MODIFIERS := [Arrange_Step]input.Modifiers {
	.Move        = {},
	.Swap        = {.Shift},
	.Resize      = {.Control},
	.Resize_More = {.Control, .Shift},
	.Pick        = {.Alt},
	.Dock        = {.Alt, .Shift},
}

@(private = "file", rodata)
ARRANGE_STEP_ACTIONS := [Arrange_Step][layout.Direction]Action {
	.Move        = {.Left = .Move_Left, .Right = .Move_Right, .Up = .Move_Up, .Down = .Move_Down},
	.Swap        = {.Left = .Swap_Left, .Right = .Swap_Right, .Up = .Swap_Up, .Down = .Swap_Down},
	.Resize      = {.Left = .Resize_Left, .Right = .Resize_Right, .Up = .Resize_Up, .Down = .Resize_Down},
	.Resize_More = {
		.Left = .Resize_Left_Large,
		.Right = .Resize_Right_Large,
		.Up = .Resize_Up_Large,
		.Down = .Resize_Down_Large,
	},
	.Pick        = {.Left = .Focus_Left, .Right = .Focus_Right, .Up = .Focus_Up, .Down = .Focus_Down},
	.Dock        = {.Left = .Dock_Left, .Right = .Dock_Right, .Up = .Dock_Up, .Down = .Dock_Down},
}

// A key that runs one command. One that `leaves` ends the mode first: its command takes the pane out of
// the tiling it arranges or opens a surface of its own.
@(private = "file")
Arrange_Key :: struct {
	key:    input.Key,
	action: Action,
	leaves: bool,
}

@(private = "file", rodata)
ARRANGE_KEYS := [?]Arrange_Key {
	{.R, .Rotate_Split, false},
	{.Equal, .Balance_Panes, false},
	{.Digit_1, .Move_Pane_Tab_1, false},
	{.Digit_2, .Move_Pane_Tab_2, false},
	{.Digit_3, .Move_Pane_Tab_3, false},
	{.Digit_4, .Move_Pane_Tab_4, false},
	{.Digit_5, .Move_Pane_Tab_5, false},
	{.Digit_6, .Move_Pane_Tab_6, false},
	{.Digit_7, .Move_Pane_Tab_7, false},
	{.Digit_8, .Move_Pane_Tab_8, false},
	{.Digit_9, .Move_Pane_Tab_9, false},
	{.T, .Move_Pane_New_Tab, false},
	{.N, .Move_Pane_New_Window, true},
	{.O, .Linked_Window, true},
	{.F, .Float_Pane, true},
	{.W, .Move_Pane_Workspace, true},
}

// The card's columns of key hints, matching the keys above; an empty label ends a column.
@(private = "file")
ARRANGE_CARD_COLUMNS :: 3

@(private = "file")
ARRANGE_CARD_ROWS :: 6

@(private = "file", rodata)
ARRANGE_HINTS := [ARRANGE_CARD_COLUMNS][ARRANGE_CARD_ROWS]ui.Key_Hint {
	{
		{{"←↑→↓", "HJKL"}, "Move"},
		{{"Shift+←↑→↓", ""}, "Swap"},
		{{"Ctrl+←↑→↓", ""}, "Resize"},
		{{"Ctrl+Shift+←↑→↓", ""}, "Resize more"},
		{{"Alt+←↑→↓", ""}, "Pick pane"},
		{{"Alt+Shift+←↑→↓", ""}, "Dock to edge"},
	},
	{
		{{"R", ""}, "Rotate split"},
		{{"=", ""}, "Balance"},
		{{"1-9", ""}, "Move to tab"},
		{{"T", ""}, "New tab"},
		{{"N", ""}, "New window"},
		{},
	},
	{
		{{"O", ""}, "Linked window"},
		{{"F", ""}, "Float or dock"},
		{{"W", ""}, "Workspace…"},
		{{"Enter", "Esc"}, "Done"},
		{},
		{},
	},
}

@(private = "file")
ARRANGE_TITLE :: "Arrange panes"

// Enters Arrange mode on w's focused pane; whatever else took w's input closes first.
arrange_open :: proc(app: ^App, w: ^Window) {
	if arrange_active(w) {return}
	if window_tree(w) == nil || !gesture_cancel(app, w) {return}
	overlay_open(app, w, Overlay_Arrange{})
	ui.presence_open(&w.arrange, ui.NOTICE_PRESENCE)
	w.dirty = true
}

arrange_active :: proc(w: ^Window) -> bool {
	_, open := w.overlay.(Overlay_Arrange)
	return open
}

@(private)
arrange_key :: proc(app: ^App, w: ^Window, e, logical: input.Key_Event) {
	if !logical.pressed || input.is_modifier_key(logical.key) {return}
	if window_tree(w) == nil {
		overlay_close(app, w)
		return
	}
	held := logical.modifiers & {.Shift, .Control, .Alt}
	if direction, arrow := arrange_direction(logical.key); arrow {
		for step in Arrange_Step {
			if ARRANGE_STEP_MODIFIERS[step] != held {continue}
			action := ARRANGE_STEP_ACTIONS[step][direction]
			if step == .Pick {
				// Focus may cross into a linked window, which the mode then follows.
				destination, _ := pane_neighbour_toward(app, w, direction)
				id := w.id
				run_action(app, w, action)
				arrange_keep(app, id, destination)
			} else {
				arrange_run(app, w, action)
			}
			return
		}
		return
	}
	if held == {} {
		#partial switch logical.key {
		case .Enter, .Numpad_Enter, .Escape:
			overlay_close(app, w)
			return
		}
		for k in ARRANGE_KEYS {
			if k.key != logical.key {continue}
			if k.leaves {
				overlay_close(app, w)
				run_action(app, w, k.action)
			} else {
				arrange_run(app, w, k.action)
			}
			return
		}
	}
	// The palette still opens, which leaves the mode as it does from anywhere.
	if action, found := shortcut_action(app, e); found && action == .Command_Palette {run_action(app, w, action)}
}

@(private = "file")
arrange_direction :: proc(key: input.Key) -> (layout.Direction, bool) {
	#partial switch key {
	case .Arrow_Left, .H:
		return .Left, true
	case .Arrow_Right, .L:
		return .Right, true
	case .Arrow_Up, .K:
		return .Up, true
	case .Arrow_Down, .J:
		return .Down, true
	}
	return .Left, false
}

// Runs `action` on the arranged pane and keeps the mode on it, in whichever window then shows it focused.
@(private = "file")
arrange_run :: proc(app: ^App, w: ^Window, action: Action) {
	tree := window_tree(w)
	if tree == nil {return}
	content, focused := layout.focused_content(tree)
	id := w.id
	run_action(app, w, action)
	if !focused {
		arrange_keep(app, id, nil)
		return
	}
	for other in app.windows {
		shown_tree := window_tree(other)
		if shown_tree == nil || !window_drawable(other) {continue}
		if shown, ok := layout.focused_content(shown_tree); ok && shown == content {
			arrange_keep(app, id, other)
			return
		}
	}
	arrange_keep(app, id, nil)
}

// Keeps the mode in `to`, leaving the window `from` when it is another one; nil keeps it in `from` when that
// window is still open. A command may have closed the mode on its way, which this opens again.
@(private = "file")
arrange_keep :: proc(app: ^App, from: input.Window_Id, to: ^Window) {
	source := window_find(app, from)
	if to == nil || to == source {
		if source != nil {arrange_open(app, source)}
		return
	}
	if source != nil && arrange_active(source) {overlay_close(app, source)}
	arrange_open(app, to)
}

arrange_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	changed, _ := ui.presence_advance(&w.arrange, app.animations, frame)
	return changed
}

// The drop outline around the arranged pane, following it as a move eases it to its new place.
arrange_outline_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if !ui.presence_visible(w.arrange) {return .Ok}
	tree := window_tree(w)
	if tree == nil {return .Ok}
	for pane in w.panes {
		if pane.node != tree.focus {continue}
		if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
		r := pane_motion_rect(w, pane)
		shown := render.Rect{r.x, r.y, r.width, r.height}
		_ = pane_outline_draw(app, w, shown, shown, w.arrange.motion.value)
		break
	}
	return .Ok
}

// The card of the mode's keys, centred along the bottom of w's panes, fading and rising as a notice does.
arrange_card_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if !ui.presence_visible(w.arrange) {return .Ok}
	s := w.scale
	keycap := ui.text_styled(&w.ui_text, .Detail)
	label := ui.text_styled(&w.ui_text, .Detail)
	title := ui.text_styled(&w.ui_text, .Strong)
	padding, gap := ui.DIALOG_PADDING * s, ui.SPACE_6 * s
	row := max(ui.KEYCAP_HEIGHT * s, label.line_height) + ui.SPACE_1 * s
	widths: [ARRANGE_CARD_COLUMNS]f32
	rows := 0
	content_width := f32(0)
	for column, c in ARRANGE_HINTS {
		for hint, r in column {
			if hint.label == "" {break}
			widths[c] = max(widths[c], ui.key_hint_width(&keycap, &label, hint, s))
			rows = max(rows, r + 1)
		}
		content_width += widths[c] + (c > 0 ? gap : 0)
	}
	heading := title.line_height + ui.SPACE_2 * s
	area := window_content_area(app, w)
	width := content_width + 2 * padding
	height := 2 * padding + heading + f32(rows) * row
	x := max(area.x, area.x + (area.width - width) / 2)
	y := area.y + area.height - ui.NOTICE_MARGIN * s - height
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	mark := render.draw_mark(&w.list)
	defer ui.fade_draw(&w.list, mark, ui.presence_fade(w.arrange, ui.RISE_NOTICE * s))
	if ui.panel_draw(&w.list, ui.popover_panel({x, y, width, height}, s), app.theme) != .None {return .Ok}
	baseline := y + padding + title.ascent
	if result := ui.draw_text(&title, &w.list, ARRANGE_TITLE, x + padding, baseline, app.theme.text);
	   result != .Ok {return result}
	top := y + padding + heading
	left := x + padding
	for column, c in ARRANGE_HINTS {
		for hint, r in column {
			if hint.label == "" {break}
			band := render.Rect{left, top + f32(r) * row, widths[c], row}
			line := band.y + (band.height - label.line_height) / 2 + label.ascent
			if result := ui.key_hint_draw(&w.list, &keycap, &label, app.theme, hint, left, band, line, s);
			   result != .Ok {return result}
		}
		left += widths[c] + gap
	}
	return .Ok
}

@(private)
arrange_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return arrange_active(w)}

@(private)
arrange_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner == .Arrange {pointer_set(app, w, .Arrow)}
}

// A press anywhere leaves the mode, keeping its changes, and then reaches what it landed on.
@(private)
arrange_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if !e.pressed {return}
	overlay_close(app, w, .Leave)
	target := pointer_target(app, w, f32(e.x), f32(e.y))
	gesture_hand_off(w, e.button, target)
	pointer_press(app, w, target, e)
}
