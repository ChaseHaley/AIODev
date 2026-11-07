package ui

import "aio:glyphs"
import "aio:input"
import "aio:platform"
import "aio:render"
import "core:strings"
import "core:time"

@(private) FIND_WIDTH :: 440
@(private) FIND_HEIGHT :: 40
@(private) FIND_MARGIN :: 12
@(private) FIND_PADDING :: 12
@(private) FIND_TOGGLE :: 28
@(private) FIND_HISTORY_LIMIT :: 100

Find_Bar :: struct {
	// Only the procedures in this file write it.
	state:                 Find_State,
	query:                 Text_Field,
	case_sensitive, regex: bool,
	hover:                 Find_Outcome,
	armed:                 Armed(Find_Outcome),
	motion:                [Find_Outcome]Control_Motion,
}

// nil is closed. The bar stays open without the keyboard after a click elsewhere, so the terminal takes
// keys while matches stay highlighted.
Find_State :: union {
	Find_Editing,
	Find_Browsing,
	Find_Blurred,
}

Find_Editing :: struct {}

// Up and Down step through history like a shell prompt.
Find_Browsing :: struct {
	// The history entry the query shows.
	index: int,
	// What was being typed before browsing began, restored by moving past the newest entry. Owned.
	draft: Find_Entry,
}

Find_Blurred :: struct {}

Find_Entry :: struct {
	query:                 string,
	case_sensitive, regex: bool,
}

// Searches shared by every window, oldest first.
Find_History :: struct {
	entries: [dynamic]Find_Entry,
}

Find_Layout :: struct { panel, query, case_toggle, regex_toggle, status, older, newer, close: render.Rect }

Find_Outcome :: enum {
	None,
	Changed,
	Moved,
	Older,
	Newer,
	Closed,
	// Pointer targets; activating one returns Changed or Closed.
	Case_Toggle,
	Regex_Toggle,
	Close,
}

find_init :: proc(f: ^Find_Bar, allocator := context.allocator) {
	f.query.bytes = make([dynamic]u8, allocator)
}

find_destroy :: proc(f: ^Find_Bar) {
	find_enter(f, nil)
	delete(f.query.bytes)
	f^ = {}
}

find_is_open :: proc(f: ^Find_Bar) -> bool { return f.state != nil }

// Whether keys and text belong to the find bar rather than the terminal.
find_has_keyboard :: proc(f: ^Find_Bar) -> bool {
	switch _ in f.state {
	case Find_Editing, Find_Browsing:
		return true
	case Find_Blurred:
	}
	return false
}

// Every change of state goes through here, so leaving history browsing always frees its draft.
@(private)
find_enter :: proc(f: ^Find_Bar, to: Find_State) {
	if browsing, ok := f.state.(Find_Browsing); ok {delete(browsing.draft.query)}
	f.state = to
}

find_history_destroy :: proc(h: ^Find_History) {
	for entry in h.entries { delete(entry.query) }
	delete(h.entries)
	h^ = {}
}

find_history_newest :: proc(h: ^Find_History) -> (Find_Entry, bool) {
	if h == nil || len(h.entries) == 0 { return {}, false }
	return h.entries[len(h.entries) - 1], true
}

// Records the query as the newest search, moving an earlier copy of it.
find_history_add :: proc(h: ^Find_History, f: ^Find_Bar) {
	query := field_string(&f.query)
	if h == nil || len(query) == 0 { return }
	for entry, i in h.entries {
		if entry.query != query { continue }
		if i == len(h.entries) - 1 {
			h.entries[i].case_sensitive, h.entries[i].regex = f.case_sensitive, f.regex
			return
		}
		delete(entry.query)
		ordered_remove(&h.entries, i)
		break
	}
	if len(h.entries) >= FIND_HISTORY_LIMIT {
		delete(h.entries[0].query)
		ordered_remove(&h.entries, 0)
	}
	copied, err := strings.clone(query)
	if err != nil { return }
	if _, append_error := append(&h.entries, Find_Entry{copied, f.case_sensitive, f.regex});
	   append_error != nil {
		delete(copied)
	}
}

// Opens with the keyboard. `restore` refills the newest search, and `select` also selects it so typing
// replaces it.
find_open :: proc(f: ^Find_Bar, h: ^Find_History = nil, restore := false, select := false) {
	find_enter(f, Find_Editing{})
	f.hover = .None
	f.motion = {}
	armed_cancel(&f.armed)
	newest, found := find_history_newest(h)
	field_set(&f.query, (restore || select) && found ? newest.query : "")
	if select { field_select_all(&f.query) }
}

// Gives the open bar the keyboard again, selecting the query when `select` is set. A closed bar stays closed.
find_focus :: proc(f: ^Find_Bar, select := false) {
	if f.state == nil { return }
	if _, blurred := f.state.(Find_Blurred); blurred { find_enter(f, Find_Editing{}) }
	if select { field_select_all(&f.query) }
}

// Leaves the bar and its matches showing while the terminal takes the keyboard.
find_blur :: proc(f: ^Find_Bar, h: ^Find_History = nil) {
	if !find_has_keyboard(f) { return }
	find_history_add(h, f)
	find_enter(f, Find_Blurred{})
	armed_cancel(&f.armed)
}

find_close :: proc(f: ^Find_Bar, h: ^Find_History = nil) {
	if f.state != nil { find_history_add(h, f) }
	find_enter(f, nil)
	f.hover = .None
	f.motion = {}
	armed_cancel(&f.armed)
}

// Typing or Enter ends history browsing; the query keeps what browsing put there.
@(private)
find_edit :: proc(f: ^Find_Bar) {
	if _, browsing := f.state.(Find_Browsing); browsing { find_enter(f, Find_Editing{}) }
}

// Handles a key while the bar has the keyboard. Enter moves to older matches and Shift+Enter to newer;
// Up and Down browse earlier searches; Alt+C and Alt+R toggle case sensitivity and regular expressions.
find_key :: proc(f: ^Find_Bar, e: input.Key_Event, h: ^Find_History = nil) -> Find_Outcome {
	if !e.pressed {
		return .None
	}
	alt := .Alt in e.modifiers && .Control not_in e.modifiers
	#partial switch e.key {
	case .Escape:
		return .Closed
	case .Enter, .Numpad_Enter:
		find_history_add(h, f)
		find_edit(f)
		return .Shift in e.modifiers ? .Newer : .Older
	case .Arrow_Up:
		return find_recall(f, h, true)
	case .Arrow_Down:
		return find_recall(f, h, false)
	case .C:
		if alt { return find_toggle(f, .Case_Toggle) }
	case .R:
		if alt { return find_toggle(f, .Regex_Toggle) }
	}
	outcome := find_change(field_key(&f.query, e))
	if outcome == .Changed { find_edit(f) }
	return outcome
}

@(private)
find_toggle :: proc(f: ^Find_Bar, target: Find_Outcome) -> Find_Outcome {
	#partial switch target {
	case .Case_Toggle:
		f.case_sensitive = !f.case_sensitive
	case .Regex_Toggle:
		f.regex = !f.regex
	case:
		return .None
	}
	return .Changed
}

// Steps through history like a shell prompt. The first step skips an entry equal to the current query, and
// stepping past the newest entry restores the draft and ends browsing.
@(private)
find_recall :: proc(f: ^Find_Bar, h: ^Find_History, older: bool) -> Find_Outcome {
	if h == nil || len(h.entries) == 0 { return .None }
	count := len(h.entries)
	browsing, is_browsing := &f.state.(Find_Browsing)
	switch {
	case older && !is_browsing:
		next := count - 1
		if h.entries[next].query == field_string(&f.query) { next -= 1 }
		if next < 0 { return .None }
		draft: Find_Entry
		if copied, err := strings.clone(field_string(&f.query)); err == nil {
			draft = {copied, f.case_sensitive, f.regex}
		}
		find_enter(f, Find_Browsing{next, draft})
		find_show(f, h.entries[next])
	case older:
		if browsing.index == 0 { return .None }
		browsing.index -= 1
		find_show(f, h.entries[browsing.index])
	case !is_browsing:
		return .None
	case browsing.index + 1 < count:
		browsing.index += 1
		find_show(f, h.entries[browsing.index])
	case:
		find_show(f, browsing.draft)
		find_enter(f, Find_Editing{})
	}
	return .Changed
}

@(private)
find_show :: proc(f: ^Find_Bar, entry: Find_Entry) {
	field_set(&f.query, entry.query)
	f.case_sensitive, f.regex = entry.case_sensitive, entry.regex
}

@(private)
find_change :: proc(change: Field_Change) -> Find_Outcome {
	switch change {
	case .None:
		return .None
	case .Moved:
		return .Moved
	case .Edited:
	}
	return .Changed
}

find_text :: proc(f: ^Find_Bar, text: string) -> Find_Outcome {
	outcome := find_change(field_text(&f.query, text))
	if outcome == .Changed { find_edit(f) }
	return outcome
}

// Keep the overlay below the title chrome, where `caption_claim_height` says the caption
// controls claim pointer input, so they cannot intercept its events. The query, its toggles and the
// close button share the first row; the count and arrows follow them or wrap below on narrow windows.
find_layout :: proc(width, scale: f32, status_width: f32 = 0) -> Find_Layout {
	margin := FIND_MARGIN * scale
	panel_width := max(0, min(FIND_WIDTH * scale, width - 2 * margin))
	l: Find_Layout
	l.panel = {
		max(0, width - margin - panel_width),
		caption_claim_height(scale) + margin,
		panel_width,
		FIND_HEIGHT * scale,
	}
	padding, gap, button, toggle := FIND_PADDING * scale, 8 * scale, 32 * scale, FIND_TOGGLE * scale
	inner := max(0, panel_width - 2 * padding)
	left := l.panel.x + min(padding, panel_width)
	right := left + inner
	y := l.panel.y + 4 * scale
	controls := status_width + gap + 2 * button
	stacked := inner < 80 * scale + 2 * toggle + gap + controls + gap + button
	l.close = {right - button, y, button, button}
	edge := l.close.x - gap
	if !stacked {
		l.newer = {edge - button, y, button, button}
		l.older = {l.newer.x - button, y, button, button}
		l.status = {l.older.x - gap - status_width, y, status_width, button}
		edge = l.status.x - gap
	}
	l.regex_toggle = {edge - toggle, y, toggle, button}
	l.case_toggle = {l.regex_toggle.x - toggle, y, toggle, button}
	l.query = {left, y, max(0, l.case_toggle.x - left), button}
	if stacked {
		y += FIND_HEIGHT * scale
		l.panel.height += FIND_HEIGHT * scale
		// On very narrow windows give the count its own row to keep every digit visible.
		separate := inner < controls
		l.status = {left, y, min(status_width, inner), button}
		if separate {
			y += FIND_HEIGHT * scale
			l.panel.height += FIND_HEIGHT * scale
		}
		l.newer = {right - button, y, button, button}
		l.older = {l.newer.x - button, y, button, button}
		if !separate { l.status.x = l.older.x - gap - l.status.width }
	}
	// Tiny windows squeeze the controls; clip them so none reaches outside the panel.
	content := render.Rect{left, l.panel.y, inner, l.panel.height}
	controls_rects := [?]^render.Rect {
		&l.query, &l.case_toggle, &l.regex_toggle, &l.status, &l.older, &l.newer, &l.close,
	}
	for r in controls_rects { r^ = clip_rect(r^, content) }
	return l
}

@(private)
clip_rect :: proc(r, bounds: render.Rect) -> render.Rect {
	x := clamp(r.x, bounds.x, bounds.x + bounds.width)
	right := clamp(r.x + r.width, bounds.x, bounds.x + bounds.width)
	return {x, r.y, max(0, right - x), r.height}
}

find_contains :: proc(l: Find_Layout, x, y: f32) -> bool { return contains(l.panel, x, y) }

// Toggles and close always respond; the arrows only when there are matches.
find_hit :: proc(l: Find_Layout, enabled: bool, x, y: f32) -> Find_Outcome {
	if contains(l.close, x, y) { return .Close }
	if contains(l.case_toggle, x, y) { return .Case_Toggle }
	if contains(l.regex_toggle, x, y) { return .Regex_Toggle }
	if !enabled { return .None }
	if contains(l.older, x, y) { return .Older }
	if contains(l.newer, x, y) { return .Newer }
	return .None
}

// Text over the query, a hand over an enabled button.
find_pointer :: proc(l: Find_Layout, enabled: bool, x, y: f32) -> platform.Cursor_Shape {
	if find_hit(l, enabled, x, y) != .None {return .Hand}
	return contains(l.query, x, y) ? .Text : .Arrow
}

find_hover :: proc(f: ^Find_Bar, l: Find_Layout, enabled: bool, x, y: f32) -> bool {
	hit := find_hit(l, enabled, x, y)
	if hit == f.hover { return false }
	f.hover = hit
	return true
}

// Moves each button's hover and press toward the pointer and the armed press; true when a frame is due.
find_animate :: proc(f: ^Find_Bar, animations: bool, now: time.Tick) -> bool {
	changed := false
	for &m, action in f.motion {
		hovered := f.hover == action && action != .None
		changed = control_update(&m, hovered, hovered && armed_is(f.armed, action), animations, now) || changed
	}
	return changed
}

find_animating :: proc(f: ^Find_Bar) -> bool {
	for m in f.motion {if control_active(m) {return true}}
	return false
}

// Like other chrome buttons, activate only on a matching left press/release. A press anywhere on the bar
// gives it the keyboard.
find_mouse :: proc(f: ^Find_Bar, l: Find_Layout, enabled: bool, button: input.Mouse_Button,
	pressed: bool, x, y: f32) -> Find_Outcome {
	if button != .Left { return .None }
	hit := find_hit(l, enabled, x, y)
	if pressed {
		find_focus(f)
		armed_press(&f.armed, hit)
		return .Moved
	}
	fired, ok := armed_release(&f.armed, hit)
	if !ok { return .Moved }
	#partial switch fired {
	case .Older, .Newer:
		return fired
	case .Close:
		return .Closed
	case .Case_Toggle, .Regex_Toggle:
		return find_toggle(f, fired)
	}
	return .Moved
}

// Draws the bar with `status` (such as "3 of 17") right-aligned after the query.
find_draw :: proc(
	f: ^Find_Bar,
	list: ^render.Draw_List,
	base: ^Text,
	theme: Theme,
	status: string,
	enabled: bool,
	width, height, scale: f32,
	pointer: [2]f32 = {},
) -> glyphs.Result {
	input_text := text_styled(base, .Body)
	count := text_styled(base, .Detail)
	l := find_layout(width, scale, text_width(&count, status))
	panel := l.panel
	if panel.width <= 2 * FIND_PADDING * scale { return .Ok }
	if render.push_layer(list, {0, 0, width, height}) != .None {
		return .Ok
	}
	frame := popover_panel(panel, scale)
	if panel_draw(list, frame, theme) != .None {return .Ok}
	if result := draw_text(&count, list, status, l.status.x,
		l.status.y + (l.status.height - count.line_height) / 2 + count.ascent, theme.muted); result != .Ok {
		return result
	}
	buttons := [?]struct {
		area:   render.Rect,
		action: Find_Outcome,
		icon:   Icon,
		label:  string,
		on:     bool,
		live:   bool,
	} {
		{l.older, .Older, .Arrow_Up, "", false, enabled},
		{l.newer, .Newer, .Arrow_Down, "", false, enabled},
		{l.close, .Close, .Close, "", false, true},
		{l.case_toggle, .Case_Toggle, {}, "Aa", f.case_sensitive, true},
		{l.regex_toggle, .Regex_Toggle, {}, ".*", f.regex, true},
	}
	for b in buttons {
		if b.area.width <= 0 { continue }
		m := f.motion[b.action]
		face, ink, err := button_draw(
			list,
			theme,
			{rect = b.area, hover = m.hover.value, press = m.press.value, selected = b.on, disabled = !b.live},
			scale,
			pointer,
		)
		if err != .None { return .Ok }
		if len(b.label) == 0 {
			icon_draw(list, b.icon, face, ink, ICON_BUTTON, scale)
			continue
		}
		label := input_text
		x := face.x + (face.width - text_width(&label, b.label)) / 2
		baseline := face.y + (face.height - label.line_height) / 2 + label.ascent
		if result := draw_text(&label, list, b.label, x, baseline, ink); result != .Ok { return result }
	}
	if l.query.width <= 0 { return .Ok }
	box := Field_Box {
		field       = &f.query,
		text        = base,
		rect        = l.query,
		inset       = 0,
		caret_width = 1.5,
		radius      = 0,
		style       = .Body,
		scale       = scale,
	}
	return field_box_draw(box, list, theme, field_box_baseline(box), find_has_keyboard(f), "Find")
}
