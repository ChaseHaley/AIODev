package ui

import "aio:commands"
import "aio:input"
import "aio:render"

// The hints a capture shows on the Settings page, and the palette footer's shorter forms.
CAPTURE_HINT :: "Press a shortcut. Enter saves this alternative, Esc cancels, Backspace removes it."
@(private)
CAPTURE_NO_LEADER_HINT :: CAPTURE_HINT + " Set Leader Key to use leader chords."
@(private)
CAPTURE_LEADER_HINT :: "Leader pressed; press the key that follows it."
@(private)
CAPTURE_TYPING_ERROR :: "Typing keys need Ctrl, Alt, or the leader."
@(private)
ALTERNATIVES_HINT :: "Choose an alternative to replace; Delete removes it. Add shortcut keeps the others."
@(private)
CAPTURE_FOOTER :: "Press keys · Enter saves · Esc cancels · Backspace removes"
@(private)
ALTERNATIVES_FOOTER :: "Enter replaces · Delete removes · Esc cancels"

Shortcut_Capture_State :: enum u8 {
	Idle,
	// The alternatives list is open: Enter records one again, Delete removes it.
	Alternatives,
	// The field records the next chord.
	Capturing,
	// The leader was pressed; the next key completes a Leader+ chord.
	Leader_Pending,
}

// A shortcut field's keyboard capture, shared by the Settings shortcut rows and the palette's
// inline shortcut row. The owner keeps the draft value and the saved value it edits, and moves its
// own focus by the outcomes; this control owns everything between them.
Shortcut_Capture :: struct {
	state:        Shortcut_Capture_State,
	alternatives: Choice_List,
	// The alternative a capture replaces; it outlives a refused save, which resumes it.
	replace:      int,
	// Captured chords name physical key positions (Physical+) instead of layout characters.
	physical:     bool,
	leader:       Maybe(commands.Shortcut),
	// The latest hint, static text; an error when `error`.
	hint:         string,
	error:        bool,
	// The chord recorded last, and the "Used by" line naming the other commands that hold it, which
	// the owner writes with shortcut_capture_check. Both are empty while nothing new is recorded.
	chord:        Maybe(commands.Shortcut),
	used_by:      [CAPTURE_USED_BY_CAP]u8,
	used_by_len:  int,
}

// Room for the "Used by" line: several titles. A longer list stops at the last title that fits.
@(private)
CAPTURE_USED_BY_CAP :: 256

Shortcut_Capture_Outcome :: enum u8 {
	None,
	Changed,
	// Changed, and `hint` is new for the owner to show.
	Hinted,
	// The draft holds the value to save.
	Save,
	// Escape: the owner leaves the field, discarding the draft.
	Cancel,
	// Tab: the keyboard moves to the Key positions switch.
	Positions,
}

// Lists the saved alternatives with Add shortcut after them.
shortcut_capture_open :: proc(c: ^Shortcut_Capture) {
	c.state, c.alternatives = .Alternatives, {}
	c.hint, c.error = ALTERNATIVES_HINT, false
	capture_forget(c)
}

// Records the next chord into alternative `index`; the alternative count adds one.
shortcut_capture_start :: proc(c: ^Shortcut_Capture, index: int = 0) {
	c.state, c.replace = .Capturing, index
	c.hint, c.error = c.leader == nil ? CAPTURE_NO_LEADER_HINT : CAPTURE_HINT, false
	capture_forget(c)
}

@(private = "file")
capture_forget :: proc(c: ^Shortcut_Capture) {
	c.chord, c.used_by_len = nil, 0
}

// Writes the "Used by" line for the chord `c` recorded last: the commands in `book` other than the
// one with settings key `except` that hold it. A free chord, or none, leaves the line empty.
shortcut_capture_check :: proc(c: ^Shortcut_Capture, book: []Shortcut_Command, except: string) {
	c.used_by_len = 0
	chord, recorded := c.chord.?
	if !recorded {return}
	for command in book {
		if command.key == except || !shortcuts_hold(command.shortcuts, chord) {continue}
		lead := c.used_by_len == 0 ? "Used by " : ", "
		if c.used_by_len + len(lead) + len(command.title) > CAPTURE_USED_BY_CAP {break}
		c.used_by_len += copy(c.used_by[c.used_by_len:], lead)
		c.used_by_len += copy(c.used_by[c.used_by_len:], command.title)
	}
}

// "Used by" and the titles of the other commands holding the recorded chord, or empty.
shortcut_capture_used_by :: proc(c: ^Shortcut_Capture) -> string {
	return string(c.used_by[:c.used_by_len])
}

// A refused save records into the same alternative again, keeping the hint.
shortcut_capture_resume :: proc(c: ^Shortcut_Capture) {c.state = .Capturing}

// Records `chord` after the saved alternatives, as a press would, so the owner's conflict check reads
// it; Enter saves it, Esc discards it.
shortcut_capture_add :: proc(
	c: ^Shortcut_Capture, draft: ^Text_Field, saved: string, chord: commands.Shortcut,
) {
	shortcut_capture_start(c, len(commands.shortcut_alternatives(saved, context.temp_allocator)))
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	capture_replace(c, draft, saved, commands.shortcut_text(chord, buffer[:]))
	c.chord = chord
}

shortcut_capture_recording :: proc(c: ^Shortcut_Capture) -> bool {
	return c.state == .Capturing || c.state == .Leader_Pending
}

// Moves a capture into a rebuilt owner; the leader is the new owner's.
shortcut_capture_carry :: proc(to, from: ^Shortcut_Capture) {
	leader := to.leader
	to^ = from^
	to.leader = leader
}

// The palette footer's line for the capture: its error, or the keys that apply.
shortcut_capture_footer :: proc(c: ^Shortcut_Capture) -> (text: string, error: bool) {
	if c.error {return c.hint, true}
	return shortcut_capture_recording(c) ? CAPTURE_FOOTER : ALTERNATIVES_FOOTER, false
}

@(private = "file")
capture_note :: proc(c: ^Shortcut_Capture, hint: string, error: bool) -> Shortcut_Capture_Outcome {
	c.hint, c.error = hint, error
	return .Hinted
}

// Writes `label` over the alternative being replaced, or after the saved ones; empty removes it.
@(private = "file")
capture_replace :: proc(c: ^Shortcut_Capture, draft: ^Text_Field, saved, label: string) {
	parts := commands.shortcut_alternatives(saved, context.temp_allocator)
	alternatives := make([]string, len(parts) + 1, context.temp_allocator)
	copy(alternatives, parts)
	count := len(parts)
	if c.replace < count {
		alternatives[c.replace] = label
	} else if label != "" {
		alternatives[count] = label
		count += 1
	}
	field_set(draft, commands.shortcut_alternatives_text(alternatives[:count], context.temp_allocator))
}

// Takes the raw key event: recording needs the physical key, and the list uses the layout's key.
// `draft` is the owner's pending value and `saved` the value its alternatives come from.
shortcut_capture_key :: proc(
	c: ^Shortcut_Capture,
	draft: ^Text_Field,
	saved: string,
	mode: Shortcut_Mode,
	raw: input.Key_Event,
	visible: int,
) -> Shortcut_Capture_Outcome {
	switch c.state {
	case .Idle:
	case .Alternatives:
		e := raw
		e.key = commands.logical_key(raw.key, raw.unshifted)
		return alternatives_key(c, draft, saved, e, visible)
	case .Capturing, .Leader_Pending:
		return capture_key(c, draft, saved, mode, raw)
	}
	return .None
}

@(private = "file")
alternatives_key :: proc(
	c: ^Shortcut_Capture,
	draft: ^Text_Field,
	saved: string,
	e: input.Key_Event,
	visible: int,
) -> Shortcut_Capture_Outcome {
	count := len(commands.shortcut_alternatives(saved, context.temp_allocator))
	#partial switch e.key {
	case .Escape:
		c.state = .Idle
		return .Cancel
	case .Arrow_Up, .Arrow_Down, LIST_PREVIOUS_KEY, LIST_NEXT_KEY:
		step := list_step(e)
		if step == 0 {return .None}
		choice_list_move(&c.alternatives, step, count + 1, visible)
	case .Enter, .Numpad_Enter, .Space:
		shortcut_capture_start(c, c.alternatives.index)
		return .Hinted
	case .Delete, .Backspace:
		if c.alternatives.index < count {
			c.replace = c.alternatives.index
			capture_replace(c, draft, saved, "")
			c.state = .Idle
			return .Save
		}
	}
	return .Changed
}

// Records chords pressed while the field captures. Pressing the leader first adds Leader+.
@(private = "file")
capture_key :: proc(
	c: ^Shortcut_Capture,
	draft: ^Text_Field,
	saved: string,
	mode: Shortcut_Mode,
	e: input.Key_Event,
) -> Shortcut_Capture_Outcome {
	if input.is_modifier_key(e.key) {return .None}
	leader_pending := c.state == .Leader_Pending
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	if modifiers == {} && !leader_pending {
		#partial switch e.key {
		case .Escape:
			c.state = .Idle
			return .Cancel
		case .Enter, .Numpad_Enter:
			c.state = .Idle
			return .Save
		case .Backspace, .Delete:
			if mode == .Alternatives {capture_replace(c, draft, saved, "")} else {field_set(draft, "")}
			capture_forget(c)
			return .Changed
		case .Tab:
			c.state = .Idle
			c.hint, c.error = "", false
			return .Positions
		}
	}
	chord := commands.Shortcut{c.physical ? e.key : commands.logical_key(e.key, e.unshifted), modifiers}
	if c.physical {chord.modifiers += {.Physical}}
	binding := mode == .Alternatives
	if leader, ok := c.leader.?;
	   ok && binding && !leader_pending &&
	   commands.shortcut_matches(leader, e.key, modifiers, e.unshifted) {
		c.state = .Leader_Pending
		capture_forget(c)
		return capture_note(c, CAPTURE_LEADER_HINT, false)
	}
	if leader_pending {
		chord.modifiers += {.Leader}
		c.state = .Capturing
	} else if modifiers & {.Control, .Alt, .Super} == {} && e.text != "" {
		return capture_note(c, CAPTURE_TYPING_ERROR, true)
	}
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	label := commands.shortcut_text(chord, buffer[:])
	if binding {capture_replace(c, draft, saved, label)} else {field_set(draft, label)}
	c.chord = chord
	return capture_note(c, CAPTURE_HINT, false)
}

// How many alternative rows the list shows on `page`: the saved ones and Add shortcut.
@(private)
shortcut_capture_popup_rows :: proc(saved: string, page: render.Rect, scale: f32) -> int {
	return choice_list_rows(len(commands.shortcut_alternatives(saved, context.temp_allocator)) + 1,
	                        page.height, scale)
}

// The open alternatives list, under the field at its right edge, or nothing while it is closed.
shortcut_capture_popup_rect :: proc(
	c: ^Shortcut_Capture,
	parts: Row_Parts,
	page: render.Rect,
	saved: string,
	scale: f32,
) -> render.Rect {
	if c.state != .Alternatives {return {}}
	s := scale
	r := render.Rect {
		parts.field.x + parts.field.width - 320 * s,
		parts.field.y + parts.field.height + 4 * s,
		320 * s,
		f32(shortcut_capture_popup_rows(saved, page, s)) * CHOICE_HEIGHT * s + 8 * s,
	}
	return dropdown_place(r, parts.row, page, s)
}

// Highlights the alternative under the pointer; reports whether the highlight moved.
shortcut_capture_hover :: proc(
	c: ^Shortcut_Capture,
	popup, page: render.Rect,
	saved: string,
	x, y, scale: f32,
) -> bool {
	if c.state != .Alternatives || !render.rect_contains(popup, x, y) {return false}
	s := scale
	if x < popup.x + 4 * s || x >= popup.x + popup.width - 4 * s {return false}
	count := len(commands.shortcut_alternatives(saved, context.temp_allocator)) + 1
	index := choice_list_at(c.alternatives, popup.y + 4 * s, CHOICE_HEIGHT * s, y, count,
	                        shortcut_capture_popup_rows(saved, page, s))
	if index < 0 || index == c.alternatives.index {return false}
	c.alternatives.index = index
	return true
}

// Scrolls the open list by `rows`, keeping the highlight on a shown row.
shortcut_capture_wheel :: proc(
	c: ^Shortcut_Capture,
	saved: string,
	page: render.Rect,
	scale: f32,
	rows: int,
) {
	count := len(commands.shortcut_alternatives(saved, context.temp_allocator)) + 1
	visible := shortcut_capture_popup_rows(saved, page, scale)
	_ = choice_list_scroll_to(&c.alternatives, c.alternatives.scroll - rows, count, visible)
}

// A press inside the open list: the remove mark deletes an alternative, the rest of a row records
// it again.
shortcut_capture_press :: proc(
	c: ^Shortcut_Capture,
	draft: ^Text_Field,
	saved: string,
	popup: render.Rect,
	x, y, scale: f32,
) -> Shortcut_Capture_Outcome {
	s := scale
	count := len(commands.shortcut_alternatives(saved, context.temp_allocator))
	index := clamp(int((y - popup.y - 4 * s) / (CHOICE_HEIGHT * s)) + c.alternatives.scroll, 0, count)
	if index < count && x >= popup.x + popup.width - 32 * s {
		c.replace = index
		capture_replace(c, draft, saved, "")
		c.state = .Idle
		return .Save
	}
	shortcut_capture_start(c, index)
	return .Hinted
}

shortcut_capture_popup_draw :: proc(
	c: ^Shortcut_Capture,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	r, page: render.Rect,
	saved: string,
	pointer: [2]f32,
	scale: f32,
) -> render.Build_Status {
	if r.width == 0 {return .Ok}
	s := scale
	if render.push_layer(list, page) != .None {return .Ok}
	if panel_draw(list, popover_panel(r, s), theme) != .None {return .Ok}
	parts := commands.shortcut_alternatives(saved, context.temp_allocator)
	count := shortcut_capture_popup_rows(saved, page, s)
	shown := c.alternatives
	for visible in 0 ..< count {
		i := shown.scroll + visible
		if i > len(parts) {break}
		option := render.Rect {
			r.x + 4 * s,
			r.y + 4 * s + f32(visible) * CHOICE_HEIGHT * s,
			r.width - 8 * s,
			CHOICE_HEIGHT * s,
		}
		if i == shown.index {
			draw_rect(list, {rect = option, color = theme.selection, radius = RADIUS_CONTROL * s})
		}
		if render.rect_contains(option, pointer.x, pointer.y) {
			// Options carry the selection tint, not the paper fill, so no hairline.
			if result := hover_rim_draw(list, theme, option, RADIUS_CONTROL * s, 1, s, pointer, false);
			   result != .None {return .Ok}
		}
		label := i < len(parts) ? parts[i] : "+ Add shortcut"
		if result := draw_text(
			text,
			list,
			label,
			option.x + CONTROL_INSET * s,
			option.y + (option.height - text.line_height) / 2 + text.ascent,
			theme.text,
			option.width - (2 * CONTROL_INSET + ICON_INDICATOR + SPACE_2) * s,
		); result != .Ok {return result}
		if i < len(parts) {
			remove := render.Rect {
				option.x + option.width - (CONTROL_INSET + ICON_INDICATOR) * s,
				option.y,
				ICON_INDICATOR * s,
				option.height,
			}
			icon_draw(list, .Close, remove, theme.muted, ICON_INDICATOR, s)
		}
	}
	return .Ok
}
