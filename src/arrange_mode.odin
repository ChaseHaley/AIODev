package main

import "cosmos:input"
import "aio:layout"
import "cosmos:render"
import "cosmos:ui"

// Arrange mode (WORK-477), a submap for panes as Hyprland has for windows: Arrange Panes takes the window's
// keys until Esc, and plain keys move, swap and resize the focused pane while it wears the drag's drop
// outline and a card lists the keys. Every key runs a registry command, so the mode does exactly what those
// commands do. Esc is its only way out: the mode follows its pane to another tab, a float, a linked or new
// window or another workspace's window, and to whichever pane a click or a close leaves focused. While a
// surface it cannot share has the keys, such as the palette or the workspace picker, it pauses and its card
// and outline hide; it resumes when that surface closes. Other keys are swallowed, so nothing typed reaches
// a program. The mode's keys are fixed.

// Arrange mode in one window: whether it is on, and the pane it arranges, which it follows elsewhere.
Arrange_Mode :: struct {
	on:       bool,
	content:  layout.Content,
	// The outline and card fading in and out; they hide while the mode pauses.
	presence: ui.Presence,
}

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

// A key that runs one command.
@(private = "file")
Arrange_Key :: struct {
	key:    input.Key,
	action: Action,
}

@(private = "file", rodata)
ARRANGE_KEYS := [?]Arrange_Key {
	{.R, .Rotate_Split},
	{.Equal, .Balance_Panes},
	{.Digit_1, .Move_Pane_Tab_1},
	{.Digit_2, .Move_Pane_Tab_2},
	{.Digit_3, .Move_Pane_Tab_3},
	{.Digit_4, .Move_Pane_Tab_4},
	{.Digit_5, .Move_Pane_Tab_5},
	{.Digit_6, .Move_Pane_Tab_6},
	{.Digit_7, .Move_Pane_Tab_7},
	{.Digit_8, .Move_Pane_Tab_8},
	{.Digit_9, .Move_Pane_Tab_9},
	{.T, .Move_Pane_New_Tab},
	{.N, .Move_Pane_New_Window},
	{.O, .Linked_Window},
	{.F, .Float_Pane},
	{.W, .Move_Pane_Workspace},
}

// The card's key hints in reading order, matching the keys above. On a wide window they stand in three
// columns, each ending before its entry in ARRANGE_CARD_ENDS; narrower, they flow evenly into fewer.
@(private = "file")
ARRANGE_CARD_COLUMNS :: 3

@(private = "file", rodata)
ARRANGE_HINTS := [?]ui.Key_Hint {
	{{"←↑→↓", "HJKL"}, "Move"},
	{{"Shift+←↑→↓", ""}, "Swap"},
	{{"Ctrl+←↑→↓", ""}, "Resize"},
	{{"Ctrl+Shift+←↑→↓", ""}, "Resize more"},
	{{"Alt+←↑→↓", ""}, "Pick pane"},
	{{"Alt+Shift+←↑→↓", ""}, "Dock to edge"},
	{{"R", ""}, "Rotate split"},
	{{"=", ""}, "Balance"},
	{{"1-9", ""}, "Move to tab"},
	{{"T", ""}, "New tab"},
	{{"N", ""}, "New window"},
	{{"O", ""}, "Linked window"},
	{{"F", ""}, "Float or dock"},
	{{"W", ""}, "Workspace…"},
	{{"Esc", ""}, "Done"},
}

@(private = "file", rodata)
ARRANGE_CARD_ENDS := [ARRANGE_CARD_COLUMNS]int{6, 11, len(ARRANGE_HINTS)}

@(private = "file")
ARRANGE_TITLE :: "Arrange panes"

// Enters Arrange mode on w's focused pane.
arrange_open :: proc(app: ^App, w: ^Window) {
	tree := window_tree(w)
	if w.arrange.on || tree == nil {return}
	content, focused := layout.focused_content(tree)
	if !focused {return}
	w.arrange.on, w.arrange.content = true, content
	w.dirty = true
}

arrange_active :: proc(w: ^Window) -> bool {return w.arrange.on}

@(private = "file")
arrange_leave :: proc(w: ^Window) {
	w.arrange.on = false
	w.dirty = true
}

// Another surface has w's keys, so the mode waits, its card and outline hidden.
arrange_paused :: proc(app: ^App, w: ^Window) -> bool {
	return overlay_kind(app, w) != .None
}

// The mode's keys, once every surface that takes keys ahead of it has passed on them.
@(private)
arrange_key :: proc(app: ^App, w: ^Window, e, logical: input.Key_Event) {
	if !logical.pressed || input.is_modifier_key(logical.key) {return}
	tree := window_tree(w)
	if tree == nil {
		arrange_leave(w)
		return
	}
	held := logical.modifiers & {.Shift, .Control, .Alt}
	if direction, arrow := arrange_direction(logical.key); arrow {
		for step in Arrange_Step {
			if ARRANGE_STEP_MODIFIERS[step] != held {continue}
			action := ARRANGE_STEP_ACTIONS[step][direction]
			if step != .Pick {
				arrange_run(app, w, action)
				return
			}
			// Focus may cross into a linked window, which the mode then follows onto the pane it lands on.
			destination, _ := pane_neighbour_toward(app, w, direction)
			id := w.id
			run_action(app, w, action)
			picked, ok := layout.focused_content(window_tree(destination))
			if ok {arrange_follow(app, id, picked, refocus = false)}
			return
		}
		return
	}
	if held == {} {
		if logical.key == .Escape {
			arrange_leave(w)
			return
		}
		for k in ARRANGE_KEYS {
			if k.key == logical.key {
				arrange_run(app, w, k.action)
				return
			}
		}
	}
	// The palette still opens; the mode waits while it is open.
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

// Runs `action` on the arranged pane and keeps the mode on it, wherever the action took it.
@(private = "file")
arrange_run :: proc(app: ^App, w: ^Window, action: Action) {
	content, focused := layout.focused_content(window_tree(w))
	id := w.id
	run_action(app, w, action)
	if focused {arrange_follow(app, id, content, refocus = true)}
}

// Keeps the mode from window `from` on `content`: in the window that now shows it focused. After a mode key,
// `refocus` also finds it shown unfocused, as a pane a linked window returns, and focuses it there. Otherwise
// the mode stays in `from` on whichever pane it now has focused, and leaves a window left with no pane.
@(private = "file")
arrange_follow :: proc(app: ^App, from: input.Window_Id, content: layout.Content, refocus: bool) {
	source := window_find(app, from)
	for pass in 0 ..< (refocus ? 2 : 1) {
		for other in app.windows {
			tree := window_tree(other)
			// A linked window just made for the pane shows at the next sync; a preview or closing one never.
			if tree == nil || other.phase == .Preparing || other.phase == .Closing {continue}
			if pass == 0 {
				if shown, ok := layout.focused_content(tree); !ok || shown != content {continue}
			} else {
				node := layout.find_content(tree, content)
				if node == layout.INVALID_NODE || layout.link_root(tree, node) != layout.INVALID_NODE {continue}
				pane_focus(app, other, node)
			}
			if other == source {
				source.arrange.content = content
				return
			}
			if source != nil {arrange_leave(source)}
			arrange_open(app, other)
			return
		}
	}
	if source == nil {return}
	if tree := window_tree(source); tree != nil {
		if shown, ok := layout.focused_content(tree); ok {
			source.arrange.content = shown
			return
		}
	}
	arrange_leave(source)
}

// Follows the arranged pane after anything that moved focus without a mode key, such as a click, a close or
// a choice in the workspace picker, then shows or hides the card as the mode runs or pauses.
arrange_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	if w.arrange.on {
		shown: layout.Content
		ok := false
		if tree := window_tree(w); tree != nil {shown, ok = layout.focused_content(tree)}
		if !ok || shown != w.arrange.content {arrange_follow(app, w.id, w.arrange.content, refocus = false)}
	}
	presence := &w.arrange.presence
	showing := w.arrange.on && !arrange_paused(app, w)
	if showing && !ui.presence_is_open(presence^) {ui.presence_open(presence, ui.NOTICE_PRESENCE)}
	if !showing && ui.presence_is_open(presence^) {ui.presence_close(presence)}
	changed, _ := ui.presence_advance(presence, app.animations, frame)
	return changed
}

// The drop outline around the arranged pane, following it as a move eases it to its new place.
arrange_outline_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if !ui.presence_visible(w.arrange.presence) {return .Ok}
	tree := window_tree(w)
	if tree == nil {return .Ok}
	for pane in w.panes {
		if pane.node != tree.focus {continue}
		if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
		r := pane_motion_rect(w, pane)
		shown := render.Rect{r.x, r.y, r.width, r.height}
		_ = pane_outline_draw(app, w, shown, shown, w.arrange.presence.motion.value)
		break
	}
	return .Ok
}

// Where the key card stands in w and how its hints flow: `columns` columns, column c holding the hints
// before ends[c], `widths[c]` wide, under a heading `heading` tall, with `row` for each hint.
Arrange_Card :: struct {
	rect:                       render.Rect,
	columns:                    int,
	ends:                       [ARRANGE_CARD_COLUMNS]int,
	widths:                     [ARRANGE_CARD_COLUMNS]f32,
	padding, gap, row, heading: f32,
}

// The card centred along the bottom of w's panes, in as many columns as their width holds, down to one, so a
// narrow window still shows every key. Panes narrower than one column leave it centred on them but inside
// the window, over the chrome beside them.
arrange_card :: proc(app: ^App, w: ^Window) -> Arrange_Card {
	s := w.scale
	keycap := ui.text_styled(&w.ui_text, .Detail)
	title := ui.text_styled(&w.ui_text, .Strong)
	card := Arrange_Card {
		padding = ui.DIALOG_PADDING * s,
		gap     = ui.SPACE_6 * s,
		row     = max(ui.KEYCAP_HEIGHT * s, keycap.line_height) + ui.SPACE_1 * s,
		heading = title.line_height + ui.SPACE_2 * s,
	}
	area := window_content_area(app, w)
	margin := ui.NOTICE_MARGIN * s
	title_width := ui.text_width(&title, ARRANGE_TITLE)
	rows := 0
	width := f32(0)
	for columns := ARRANGE_CARD_COLUMNS; columns >= 1; columns -= 1 {
		card.columns, card.ends, card.widths = columns, ARRANGE_CARD_ENDS, {}
		if columns < ARRANGE_CARD_COLUMNS {
			per := (len(ARRANGE_HINTS) + columns - 1) / columns
			for &end, c in card.ends {end = min(len(ARRANGE_HINTS), (c + 1) * per)}
		}
		content, start := f32(0), 0
		rows = 0
		for c in 0 ..< columns {
			for hint in ARRANGE_HINTS[start:card.ends[c]] {
				card.widths[c] = max(card.widths[c], ui.key_hint_width(&keycap, &keycap, hint, s))
			}
			rows = max(rows, card.ends[c] - start)
			content += card.widths[c] + (c > 0 ? card.gap : 0)
			start = card.ends[c]
		}
		width = max(content, title_width) + 2 * card.padding
		if width <= area.width - 2 * margin {break}
	}
	height := 2 * card.padding + card.heading + f32(rows) * card.row
	x := area.x + (area.width - width) / 2
	x = max(0, min(x, f32(w.width) - width))
	y := max(area.y, area.y + area.height - margin - height)
	card.rect = {x, y, width, height}
	return card
}

// The card of the mode's keys, fading and rising as a notice does.
arrange_card_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if !ui.presence_visible(w.arrange.presence) {return .Ok}
	s := w.scale
	keycap := ui.text_styled(&w.ui_text, .Detail)
	title := ui.text_styled(&w.ui_text, .Strong)
	card := arrange_card(app, w)
	r := card.rect
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	mark := render.draw_mark(&w.list)
	defer ui.fade_draw(&w.list, mark, ui.presence_fade(w.arrange.presence, ui.RISE_NOTICE * s))
	if ui.panel_draw(&w.list, ui.popover_panel(r, s), app.theme) != .None {return .Ok}
	baseline := r.y + card.padding + title.ascent
	if result := ui.draw_text(&title, &w.list, ARRANGE_TITLE, r.x + card.padding, baseline, app.theme.text);
	   result != .Ok {return result}
	top := r.y + card.padding + card.heading
	left := r.x + card.padding
	start := 0
	for c in 0 ..< card.columns {
		for hint, i in ARRANGE_HINTS[start:card.ends[c]] {
			band := render.Rect{left, top + f32(i) * card.row, card.widths[c], card.row}
			line := band.y + (band.height - keycap.line_height) / 2 + keycap.ascent
			if result := ui.key_hint_draw(&w.list, &keycap, &keycap, app.theme, hint, left, band, line, s);
			   result != .Ok {return result}
		}
		left += card.widths[c] + card.gap
		start = card.ends[c]
	}
	return .Ok
}
