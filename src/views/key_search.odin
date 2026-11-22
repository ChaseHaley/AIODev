package views

import "aio:commands"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import "cosmos:ui"

// Record mode of a search field, shared by the palette query and the Settings search (WORK-407). The
// field's keyboard button or Alt+K turn it on; the next chord pressed, app shortcuts included, becomes
// the query and shows as keycaps. Recording ends once a chord is complete, so the list keys work on
// its results; Esc, Alt+K or the button return to typing.
Key_Search_State :: enum u8 {
	Off,
	Recording,
	Recorded,
}

Key_Search :: struct {
	state: Key_Search_State,
	press: commands.Key_Press,
}

Key_Search_Step :: enum u8 {
	None,
	Changed,
	// Back to typing: the owner calls key_search_leave.
	Leave,
}

KEY_SEARCH_TOGGLE :: input.Shortcut{.K, {.Alt}}
KEY_SEARCH_LABEL :: "Alt+K"
KEY_SEARCH_CLEAR_LABEL :: "Backspace"
@(private)
KEY_SEARCH_WAITING :: "Press a shortcut"
@(private)
KEY_SEARCH_HELD :: "+ any key"
@(private)
KEY_SEARCH_LEADER :: "then a key"
// What the list says before a chord is recorded, or when a recorded one runs nothing.
KEY_SEARCH_EMPTY_HINT :: "Press a shortcut. Hold modifiers to list theirs; press the leader for its keys."
KEY_SEARCH_NO_MATCH :: "No command uses this shortcut"

// Alt+K by the layout's letter, as every other list chord is read.
key_search_toggles :: proc(raw: input.Key_Event) -> bool {
	key := commands.logical_key(raw.key, raw.unshifted)
	return raw.pressed && key == KEY_SEARCH_TOGGLE.key &&
		raw.modifiers & {.Control, .Shift, .Alt, .Super} == KEY_SEARCH_TOGGLE.modifiers
}

key_search_active :: proc(k: ^Key_Search) -> bool {return k.state != .Off}

key_search_start :: proc(k: ^Key_Search) {k^ = {state = .Recording}}

// Takes the raw key while recording: recording needs the physical key and the leader. Bare Esc and
// Alt+K leave; bare Backspace clears what was recorded; everything else is recorded.
key_search_record :: proc(
	k: ^Key_Search, raw: input.Key_Event, leader: Maybe(input.Shortcut),
) -> Key_Search_Step {
	if !raw.pressed {return .None}
	if key_search_toggles(raw) {return .Leave}
	if raw.modifiers & {.Control, .Shift, .Alt, .Super} == {} {
		#partial switch raw.key {
		case .Escape:
			if k.press.state != .Leader {return .Leave}
			k.press = {}
			return .Changed
		case .Backspace:
			k.press = {}
			return .Changed
		}
	}
	if raw.repeat {return .None}
	if commands.key_press_record(&k.press, raw, leader) {k.state = .Recorded}
	return .Changed
}

// The keys a recorded search keeps for itself; the owner's list keys handle the rest.
key_search_recorded_key :: proc(
	k: ^Key_Search, e: input.Key_Event,
) -> (step: Key_Search_Step, handled: bool) {
	if key_search_toggles(e) {return .Leave, true}
	if e.modifiers & {.Control, .Shift, .Alt, .Super} != {} {return}
	#partial switch e.key {
	case .Escape:
		return .Leave, true
	case .Backspace:
		key_search_start(k)
		return .Changed, true
	}
	return
}

// Leaves record mode. Recorded keys become their typed form, which a text search reads as the same keys;
// with nothing recorded the text typed before stays.
key_search_leave :: proc(k: ^Key_Search, field: ^ui.Text_Field) {
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	if text := commands.key_press_text(k.press, buffer[:]); text != "" {ui.field_set(field, text)}
	k^ = {}
}

key_search_match :: proc(k: ^Key_Search, shortcut: input.Shortcut) -> commands.Shortcut_Hit {
	return commands.key_press_match(k.press, shortcut)
}

// The keyboard button at the right of a search field: selected while the field records keys.
key_search_button_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	rect: render.Rect,
	active: bool,
	scale: f32,
	pointer: [2]f32,
) -> render.Error {
	if rect.width <= 0 {return .None}
	hover: f32 = render.rect_contains(rect, pointer.x, pointer.y) ? 1 : 0
	face, ink, err := ui.button_draw(list, theme, {rect = rect, hover = hover, selected = active},
		scale, pointer)
	ui.icon_draw(list, .Keyboard, face, ink, ui.ICON_BUTTON, scale)
	return err
}

key_search_pointer :: proc(rect: render.Rect, x, y: f32) -> (platform.Cursor_Shape, bool) {
	return .Hand, render.rect_contains(rect, x, y)
}

// What the keyboard button's tooltip says; the tooltip shows KEY_SEARCH_TOGGLE beside it.
key_search_tooltip :: proc(k: ^Key_Search) -> string {
	return k.state == .Off ? "Search by pressing a shortcut" : "Search by typing"
}

// Draws the recorded keys as keycaps from the left of `area`, centred on it, with what recording still
// waits for; the field's text styling sizes them. Caps take the accent edge while recording.
key_search_draw :: proc(
	k: ^Key_Search,
	list: ^render.Draw_List,
	text: ^ui.Text,
	theme: Theme,
	area: render.Rect,
	scale: f32,
) -> render.Build_Status {
	if area.width <= 0 {return .Ok}
	scope, opened := ui.clip_scope_open(list, area)
	if !opened {return .Ok}
	defer ui.clip_scope_close(list, scope)
	cap_height := min(ui.HEIGHT_COMPACT * scale, area.height)
	top := area.y + (area.height - cap_height) / 2
	baseline := area.y + (area.height - text.line_height) / 2 + text.ascent
	edge := k.state == .Recording ? theme.accent : theme.border
	pen := area.x
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	rest := commands.key_press_text(k.press, buffer[:])
	for part in commands.shortcut_label_next(&rest) {
		width := ui.text_width(text, part.text) + 2 * (ui.KEYCAP_PADDING + ui.SPACE_1) * scale
		keycap := render.Rect{pen, top, width, cap_height}
		ui.draw_rect(list, {rect = keycap, color = theme.surface, radius = ui.RADIUS_CONTROL * scale})
		ui.draw_rect(list, {rect = keycap, color = edge, radius = ui.RADIUS_CONTROL * scale, stroke = scale})
		x := pen + (ui.KEYCAP_PADDING + ui.SPACE_1) * scale
		if result := ui.draw_text(text, list, part.text, x, baseline, theme.text); result != .Ok {return result}
		pen += width + ui.SPACE_1 * scale
	}
	hint := ""
	switch k.press.state {
	case .None:
		hint = k.state == .Recording ? KEY_SEARCH_WAITING : ""
	case .Held:
		hint = KEY_SEARCH_HELD
	case .Leader:
		hint = KEY_SEARCH_LEADER
	case .Chord:
	}
	if hint == "" {return .Ok}
	if pen > area.x {pen += ui.SPACE_1 * scale}
	return ui.draw_text(text, list, hint, pen, baseline, theme.muted, max(1, area.x + area.width - pen))
}
