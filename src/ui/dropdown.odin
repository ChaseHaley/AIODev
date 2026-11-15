package ui

import "aio:input"
import "aio:line_match"
import "aio:platform"
import "aio:render"
import "aio:search"

// A searchable list's filter field, with the overlay's padding above it.
@(private)
DROPDOWN_SEARCH_HEIGHT :: OVERLAY_PADDING + HEIGHT_STANDARD

// The `.*` toggle inside the search field, as wide as the find bar's.
@(private = "file")
DROPDOWN_REGEX_WIDTH :: f32(FIND_TOGGLE)
@(private = "file")
DROPDOWN_INVALID_TEXT :: "Invalid regular expression"
@(private = "file")
DROPDOWN_EMPTY_TEXT :: "No fonts found"

// The one dropdown a setting's choices open in, on the Settings page and in the everything palette.
// It keeps what is open: the highlighted option and the first shown, the search a long list such
// as the installed fonts filters by and its matches, whether the keyboard is on the Show all fonts
// switch, what the pointer holds and whether it is over the scrollbar. The owner keeps the choices,
// which it passes as Dropdown_Choices, and where the list opens, as a Dropdown_Anchor.
Dropdown :: struct {
	list:         Choice_List,
	search:       Text_Field,
	// Indexes of the choices the search matches; meaningful only for a searchable list.
	matches:      [dynamic]int,
	// Tab moves the keyboard from the font search to its Show all fonts switch.
	toggle_focus: bool,
	drag:         Dropdown_Drag,
	bar_hover:    bool,
	// The pointer is over the `.*` toggle, which then shows its hover.
	regex_hover:  bool,
	// The search is a regular expression, in a list with the `.*` toggle. The owner keeps the Dropdown, so
	// the toggle stays as it was between opens.
	regex:        bool,
	// The regular expression does not compile, so nothing matches.
	invalid:      bool,
}

// The pointer drags a selection in the search field, or holds the scrollbar thumb.
Dropdown_Drag :: union {
	Dropdown_Search_Drag,
	Scroll_Drag,
}

Dropdown_Search_Drag :: struct {}

// The choices a dropdown shows, borrowed for the call. `labels`, when present, is what each choice
// displays; `value` is the saved choice the list marks. A multiple choice marks the options `mask`
// has on instead. `font_filter` adds the Show all fonts switch, on when `show_all_fonts`.
// `min_width` is in DIPs; zero follows the field. `regex_toggle` puts the `.*` toggle in a searchable
// list's search field. `faded`, parallel to `choices` when present, draws those choices faded; they
// stay pickable. `search_text`, parallel to `choices` when present, is what the search matches in place
// of the labels, so decorations such as a status mark or counts never get in a pattern's way.
Dropdown_Choices :: struct {
	choices, labels:                          []string,
	value:                                    string,
	mask:                                     u32,
	multiple, searchable:                     bool,
	font_filter, show_all_fonts:              bool,
	regex_toggle:                             bool,
	min_width:                                f32,
	// The search field's hint; "" is "Search fonts".
	placeholder:                              string,
	// What the search shows when nothing matches; "" is "No fonts found".
	empty_text:                               string,
	faded:                                    []bool,
	search_text:                              []string,
}

// Where a dropdown opens: under `field`, flipped above `row` when `bounds` has no room below, and
// kept inside `bounds`. `align_end` lines the list's right edge up with the field's.
Dropdown_Anchor :: struct {
	field, row, bounds: render.Rect,
	align_end:          bool,
}

// What an input did to the open dropdown. Chosen: the highlighted option was picked; the owner
// reads it with dropdown_highlighted. Closed: Escape closed the list. Font_Filter: the Show all fonts
// switch was operated; the owner saves the other filter and restores the search with
// dropdown_restore.
Dropdown_Outcome :: enum {
	None,
	Changed,
	Chosen,
	Closed,
	Font_Filter,
}

dropdown_init :: proc(d: ^Dropdown, allocator := context.allocator) {
	d.search.bytes = make([dynamic]u8, allocator)
	d.matches = make([dynamic]int, allocator)
}

dropdown_destroy :: proc(d: ^Dropdown) {
	delete(d.search.bytes)
	delete(d.matches)
}

// What choice `i` displays: its label, or the value itself.
dropdown_label :: proc(c: Dropdown_Choices, i: int) -> string {
	return i < len(c.labels) && c.labels[i] != "" ? c.labels[i] : c.choices[i]
}

// How many options the list shows: the search's matches, or every choice.
dropdown_count :: proc(d: ^Dropdown, c: Dropdown_Choices) -> int {
	return c.searchable ? len(d.matches) : len(c.choices)
}

// The choice shown at list position `index`, as an index into `choices`.
@(private)
dropdown_source :: proc(d: ^Dropdown, c: Dropdown_Choices, index: int) -> int {
	return c.searchable ? d.matches[index] : index
}

// The highlighted option as an index into `choices`, or -1 when the list shows none.
dropdown_highlighted :: proc(d: ^Dropdown, c: Dropdown_Choices) -> int {
	if d.list.index < 0 || d.list.index >= dropdown_count(d, c) {return -1}
	return dropdown_source(d, c, d.list.index)
}

// Keeps the choices intact; only the list's index map changes while searching. A regular expression
// compiles once per search and matches each choice's search text anywhere, without regard to case.
@(private)
dropdown_filter :: proc(d: ^Dropdown, c: Dropdown_Choices) {
	d.list, d.invalid = {}, false
	query := field_string(&d.search)
	searched := c
	if c.search_text != nil {searched.labels = c.search_text}
	if !c.regex_toggle || !d.regex || query == "" {
		choice_matches_filter(&d.matches, searched.choices, searched.labels, query)
		return
	}
	clear(&d.matches)
	m: line_match.Matcher
	// A pattern that fails to compile still holds its copy of the query.
	defer line_match.destroy(&m)
	switch line_match.init(&m, query, search.Options{regex = true}) {
	case .Ok:
	case .Invalid:
		d.invalid = true
		return
	case .Out_Of_Memory:
		return
	}
	for _, i in c.choices {
		line_match.begin(&m, dropdown_label(searched, i))
		if _, _, found := line_match.next(&m); found {append(&d.matches, i)}
	}
}

// Flips the `.*` toggle and searches again.
@(private)
dropdown_regex_flip :: proc(d: ^Dropdown, c: Dropdown_Choices) {
	d.regex = !d.regex
	dropdown_filter(d, c)
}

// What the list says when it shows no options, "" while it shows some. A pattern that does not compile
// says so before the list's own empty text.
dropdown_empty_text :: proc(d: ^Dropdown, c: Dropdown_Choices) -> string {
	if dropdown_count(d, c) > 0 {return ""}
	if d.invalid && c.regex_toggle && d.regex {return DROPDOWN_INVALID_TEXT}
	return c.empty_text != "" ? c.empty_text : DROPDOWN_EMPTY_TEXT
}

// Opens on the saved choice, or the first option of a multiple choice, with an empty search.
dropdown_open :: proc(d: ^Dropdown, c: Dropdown_Choices) {
	d.toggle_focus, d.drag, d.bar_hover, d.regex_hover = false, nil, false, false
	if c.searchable {
		field_set(&d.search, "")
		dropdown_filter(d, c)
	}
	d.list = {}
	if !c.multiple {
		for i in 0 ..< dropdown_count(d, c) {
			if c.choices[dropdown_source(d, c, i)] == c.value {d.list.index = i; break}
		}
	}
	d.list.scroll = d.list.index
}

// Drops what the pointer holds and the hover; the owner calls this as the list closes.
dropdown_close :: proc(d: ^Dropdown) {
	d.toggle_focus, d.drag, d.bar_hover, d.regex_hover = false, nil, false, false
}

// Restores an open search over choices the owner rebuilt, as after the Show all fonts switch.
dropdown_restore :: proc(d: ^Dropdown, c: Dropdown_Choices, query: string, toggle_focus: bool) {
	if !c.searchable {return}
	d.toggle_focus, d.drag = toggle_focus, nil
	field_set(&d.search, query)
	dropdown_filter(d, c)
}

// The search field and the Show all fonts switch above the options.
dropdown_header :: proc(c: Dropdown_Choices, scale: f32) -> f32 {
	if !c.searchable {return 0}
	return (DROPDOWN_SEARCH_HEIGHT + (c.font_filter ? CHOICE_HEIGHT : 0)) * scale
}

// How many options fit: at most CHOICE_LIST_ROWS, fewer when the bounds are short.
dropdown_rows :: proc(d: ^Dropdown, c: Dropdown_Choices, a: Dropdown_Anchor, scale: f32) -> int {
	return choice_list_rows(dropdown_count(d, c), a.bounds.height, scale, dropdown_header(c, scale))
}

// Keeps the highlight on a shown row, as when the bounds change.
dropdown_fit :: proc(d: ^Dropdown, c: Dropdown_Choices, a: Dropdown_Anchor, scale: f32) {
	choice_list_keep_visible(&d.list, dropdown_count(d, c), dropdown_rows(d, c, a, scale))
}

dropdown_rect :: proc(d: ^Dropdown, c: Dropdown_Choices, a: Dropdown_Anchor, scale: f32) -> render.Rect {
	if a.field.width <= 0 {return {}}
	s := scale
	rows := dropdown_rows(d, c, a, s)
	// The highlight stays on a shown row however the bounds changed since the list moved.
	choice_list_keep_visible(&d.list, dropdown_count(d, c), rows)
	width := max(a.field.width, c.min_width * s)
	r := render.Rect {
		a.align_end ? a.field.x + a.field.width - width : a.field.x,
		a.field.y + a.field.height + SPACE_1 * s,
		width,
		f32(max(1, rows)) * CHOICE_HEIGHT * s + 2 * OVERLAY_PADDING * s + dropdown_header(c, s),
	}
	return dropdown_place(r, a.row, a.bounds, s)
}

dropdown_contains :: proc(d: ^Dropdown, c: Dropdown_Choices, a: Dropdown_Anchor, x, y, scale: f32) -> bool {
	return render.rect_contains(dropdown_rect(d, c, a, scale), x, y)
}

// The search field across the top of the list.
@(private = "file")
dropdown_search_rect :: proc(popup: render.Rect, scale: f32) -> render.Rect {
	pad := OVERLAY_PADDING * scale
	return {popup.x + pad, popup.y + pad, popup.width - 2 * pad, HEIGHT_STANDARD * scale}
}

// The `.*` toggle at the right inside the search field; zero for a list without one.
@(private = "file")
dropdown_regex_in :: proc(c: Dropdown_Choices, popup: render.Rect, scale: f32) -> render.Rect {
	if !c.searchable || !c.regex_toggle {return {}}
	field := dropdown_search_rect(popup, scale)
	inset, width := SPACE_1 * scale, DROPDOWN_REGEX_WIDTH * scale
	return {field.x + field.width - inset - width, field.y + inset, width, max(0, field.height - 2 * inset)}
}

// Where the open list's `.*` toggle is; zero when the list has none.
dropdown_regex_rect :: proc(
	d: ^Dropdown, c: Dropdown_Choices, a: Dropdown_Anchor, scale: f32,
) -> render.Rect {
	return dropdown_regex_in(c, dropdown_rect(d, c, a, scale), scale)
}

// The search's text, which stops short of the `.*` toggle.
@(private)
dropdown_search_box :: proc(
	d: ^Dropdown, c: Dropdown_Choices, popup: render.Rect, text: ^Text, scale: f32,
) -> Field_Box {
	rect := dropdown_search_rect(popup, scale)
	if regex := dropdown_regex_in(c, popup, scale); regex.width > 0 {rect.width = regex.x - rect.x}
	return field_box_standard(&d.search, text, rect, scale)
}

@(private)
dropdown_toggle_rect :: proc(c: Dropdown_Choices, popup: render.Rect, scale: f32) -> render.Rect {
	if !c.searchable || !c.font_filter {return {}}
	s := scale
	pad := OVERLAY_PADDING * s
	return {popup.x + pad, popup.y + pad + DROPDOWN_SEARCH_HEIGHT * s, popup.width - 2 * pad, CHOICE_HEIGHT * s}
}

dropdown_scrollbar :: proc(
	d: ^Dropdown,
	c: Dropdown_Choices,
	a: Dropdown_Anchor,
	scale: f32,
) -> (
	bar: Scrollbar,
	visible: bool,
) {
	r := dropdown_rect(d, c, a, scale)
	if r.width == 0 {return}
	s := scale
	header := dropdown_header(c, s)
	pad := OVERLAY_PADDING * s
	area := render.Rect{r.x, r.y + header + pad, r.width - s, r.height - header - 2 * pad}
	extent := Scroll_Extent{dropdown_count(d, c), dropdown_rows(d, c, a, s), d.list.scroll}
	held, _ := d.drag.(Scroll_Drag)
	return scrollbar_layout(area, extent, scrollbar_state(d.bar_hover, held), s)
}

// Whether the pointer holds the search's selection or the scrollbar thumb.
dropdown_dragging :: proc(d: ^Dropdown) -> bool {return d.drag != nil}

dropdown_scrollbar_held :: proc(d: ^Dropdown) -> bool {
	_, held := d.drag.(Scroll_Drag)
	return held
}

// Where the options end: at the scrollbar when the list scrolls.
@(private)
dropdown_option_right :: proc(
	d: ^Dropdown,
	c: Dropdown_Choices,
	a: Dropdown_Anchor,
	popup: render.Rect,
	scale: f32,
) -> f32 {
	if bar, visible := dropdown_scrollbar(d, c, a, scale); visible {return bar.track.x}
	return popup.x + popup.width - OVERLAY_PADDING * scale
}

// The list position of the option under x, y, or -1.
@(private)
dropdown_option_at :: proc(d: ^Dropdown, c: Dropdown_Choices, a: Dropdown_Anchor, x, y, scale: f32) -> int {
	popup := dropdown_rect(d, c, a, scale)
	if !render.rect_contains(popup, x, y) || x >= dropdown_option_right(d, c, a, popup, scale) {return -1}
	top := popup.y + dropdown_header(c, scale) + OVERLAY_PADDING * scale
	rows := dropdown_rows(d, c, a, scale)
	return choice_list_at(d.list, top, CHOICE_HEIGHT * scale, y, dropdown_count(d, c), rows)
}

// Scrolls the list, keeping the highlight on a shown row.
@(private)
dropdown_scroll_to :: proc(
	d: ^Dropdown,
	c: Dropdown_Choices,
	a: Dropdown_Anchor,
	offset: int,
	scale: f32,
) -> bool {
	return choice_list_scroll_to(&d.list, offset, dropdown_count(d, c), dropdown_rows(d, c, a, scale))
}

dropdown_wheel :: proc(d: ^Dropdown, c: Dropdown_Choices, a: Dropdown_Anchor, rows: int, scale: f32) -> bool {
	return dropdown_scroll_to(d, c, a, d.list.scroll - rows, scale)
}

// The highlight follows the pointer, like the menus. Reports whether the highlight, the scrollbar's
// hover or the `.*` toggle's hover changed.
dropdown_hover :: proc(d: ^Dropdown, c: Dropdown_Choices, a: Dropdown_Anchor, x, y, scale: f32) -> bool {
	bar, visible := dropdown_scrollbar(d, c, a, scale)
	over := visible && scrollbar_contains(bar, x, y)
	on_regex := render.rect_contains(dropdown_regex_rect(d, c, a, scale), x, y)
	changed := over != d.bar_hover || on_regex != d.regex_hover
	d.bar_hover, d.regex_hover = over, on_regex
	if index := dropdown_option_at(d, c, a, x, y, scale); index >= 0 && index != d.list.index {
		d.list.index = index
		changed = true
	}
	return changed
}

// A press inside the dropdown. `text` measures the search; without it a press selects the search.
dropdown_press :: proc(
	d: ^Dropdown,
	c: Dropdown_Choices,
	a: Dropdown_Anchor,
	text: ^Text,
	x, y: f32,
	extend: bool,
	scale: f32,
) -> Dropdown_Outcome {
	r := dropdown_rect(d, c, a, scale)
	if !render.rect_contains(r, x, y) {return .None}
	s := scale
	if render.rect_contains(dropdown_toggle_rect(c, r, s), x, y) {
		d.toggle_focus = true
		return .Font_Filter
	}
	if render.rect_contains(dropdown_regex_in(c, r, s), x, y) {
		dropdown_regex_flip(d, c)
		return .Changed
	}
	if c.searchable && y < r.y + OVERLAY_PADDING * s + dropdown_header(c, s) {
		if text != nil {
			_ = field_move(&d.search, field_box_offset(dropdown_search_box(d, c, r, text, s), x), extend)
		} else {field_select_all(&d.search)}
		d.toggle_focus, d.drag = false, Dropdown_Search_Drag{}
		return .Changed
	}
	if bar, visible := dropdown_scrollbar(d, c, a, s); visible && scrollbar_contains(bar, x, y) {
		held: Scroll_Drag
		_ = dropdown_scroll_to(d, c, a, scrollbar_press(&held, bar, y), s)
		if held.active {d.drag = held}
		return .Changed
	}
	index := dropdown_option_at(d, c, a, x, y, s)
	if index < 0 {return .None}
	d.list.index = index
	return .Chosen
}

// Moves what the pointer holds. Reports whether anything moved.
dropdown_drag :: proc(
	d: ^Dropdown,
	c: Dropdown_Choices,
	a: Dropdown_Anchor,
	text: ^Text,
	x, y, scale: f32,
) -> bool {
	switch drag in d.drag {
	case Dropdown_Search_Drag:
		if text == nil {return false}
		box := dropdown_search_box(d, c, dropdown_rect(d, c, a, scale), text, scale)
		return field_move(&d.search, field_box_offset(box, x), true) != .None
	case Scroll_Drag:
		bar, visible := dropdown_scrollbar(d, c, a, scale)
		if !visible {return false}
		return dropdown_scroll_to(d, c, a, scrollbar_drag(drag, bar, y), scale)
	}
	return false
}

// Ends a pointer gesture. Reports whether it held the scrollbar thumb, whose look changes.
dropdown_release :: proc(d: ^Dropdown) -> bool {
	held := dropdown_scrollbar_held(d)
	d.drag = nil
	return held
}

// The pointer over the dropdown: text over the search, a hand over an option or the switch.
dropdown_pointer :: proc(
	d: ^Dropdown,
	c: Dropdown_Choices,
	a: Dropdown_Anchor,
	x, y, scale: f32,
) -> platform.Cursor_Shape {
	r := dropdown_rect(d, c, a, scale)
	s := scale
	if bar, visible := dropdown_scrollbar(d, c, a, s); visible && scrollbar_contains(bar, x, y) {return .Arrow}
	if render.rect_contains(dropdown_toggle_rect(c, r, s), x, y) {return .Hand}
	if render.rect_contains(dropdown_regex_in(c, r, s), x, y) {return .Hand}
	if !render.rect_contains(r, x, y) {return .Arrow}
	if c.searchable && y < r.y + OVERLAY_PADDING * s + dropdown_header(c, s) {return .Text}
	return dropdown_option_at(d, c, a, x, y, s) >= 0 ? .Hand : .Arrow
}

// Keys for the open dropdown. `taken` is false for a list key at the list's end, which the owner may
// use, and true for every other key.
dropdown_key :: proc(
	d: ^Dropdown,
	c: Dropdown_Choices,
	a: Dropdown_Anchor,
	e: input.Key_Event,
	scale: f32,
) -> (
	outcome: Dropdown_Outcome,
	taken: bool,
) {
	if c.searchable {
		if c.regex_toggle && e.key == .R && .Alt in e.modifiers && .Control not_in e.modifiers {
			dropdown_regex_flip(d, c)
			return .Changed, true
		}
		if c.font_filter && e.key == .Tab {
			d.toggle_focus = !d.toggle_focus
			return .Changed, true
		}
		if d.toggle_focus {
			// The owner saves the other filter; the choices it rebuilds list those fonts.
			if e.key == .Space || e.key == .Enter || e.key == .Numpad_Enter {return .Font_Filter, true}
			if e.key != .Escape && e.key != .Arrow_Down && e.key != .Arrow_Up {return .None, true}
			d.toggle_focus = false
		}
	}
	count := dropdown_count(d, c)
	visible := dropdown_rows(d, c, a, scale)
	if choice_list_key(&d.list, e, count, visible) {return .Changed, true}
	// Without a search field the list has no caret to give Home and End to.
	if !c.searchable && (e.key == .Home || e.key == .End) {
		choice_list_move(&d.list, e.key == .Home ? -count : count, count, visible)
		return .Changed, true
	}
	if c.searchable {
		// Every key the list did not take, but Escape and Enter, edits the search as in any field.
		#partial switch e.key {
		case .Escape, .Enter, .Numpad_Enter:
		case:
			change := field_key(&d.search, e)
			if change == .Edited {dropdown_filter(d, c)}
			return change == .None ? .None : .Changed, true
		}
	}
	#partial switch e.key {
	case .Escape:
		return .Closed, true
	case .Arrow_Up, .Arrow_Down, .P, .N, .Home, .End, .Page_Up, .Page_Down:
		return .None, false
	case .Enter, .Numpad_Enter, .Space:
		return dropdown_highlighted(d, c) >= 0 ? .Chosen : .None, true
	}
	return .None, true
}

// Typed or pasted text goes to the search. Reports whether the search changed.
dropdown_text :: proc(d: ^Dropdown, c: Dropdown_Choices, text: string) -> bool {
	if !c.searchable || d.toggle_focus {return false}
	change := field_text(&d.search, text)
	if change == .Edited {dropdown_filter(d, c)}
	return change != .None
}

// The search's selected text, for copying.
dropdown_selection :: proc(d: ^Dropdown, c: Dropdown_Choices) -> string {
	return c.searchable ? field_selected_text(&d.search) : ""
}

// A closed dropdown's field: the shown value and a chevron, outlined while its list is open.
dropdown_field_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	field: render.Rect,
	label: string,
	focused: bool,
	scale: f32,
) -> render.Build_Status {
	box_draw(list, field, theme, focused, scale)
	input_text := text_styled(text, .Body)
	inset := CONTROL_INSET * scale
	baseline := field.y + (field.height - input_text.line_height) / 2 + input_text.ascent
	if r := draw_text(&input_text, list, label, field.x + inset, baseline, theme.text,
		max(1, field.width - 2 * inset - (ICON_INDICATOR + SPACE_1) * scale)); r != .Ok {return r}
	chevron := render.Rect {
		field.x + field.width - inset - ICON_INDICATOR * scale,
		field.y,
		ICON_INDICATOR * scale,
		field.height,
	}
	icon_draw(list, .Chevron_Down, chevron, theme.muted, ICON_INDICATOR, scale)
	return .Ok
}

// The open list over everything inside `a.bounds`.
dropdown_draw :: proc(
	d: ^Dropdown,
	c: Dropdown_Choices,
	a: Dropdown_Anchor,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	pointer: [2]f32,
	scale: f32,
) -> render.Build_Status {
	r := dropdown_rect(d, c, a, scale)
	if r.width == 0 {return .Ok}
	s := scale
	if render.push_layer(list, a.bounds) != .None {return .Ok}
	if panel_draw(list, popover_panel(r, s), theme) != .None {return .Ok}
	count := dropdown_rows(d, c, a, s)
	if c.searchable {
		field := dropdown_search_rect(r, s)
		box_draw(list, field, theme, !d.toggle_focus, s)
		box := dropdown_search_box(d, c, r, text, s)
		if result := field_box_draw(box, list, theme, field_box_baseline(box), !d.toggle_focus,
			c.placeholder != "" ? c.placeholder : "Search fonts");
		   result != .Ok {return result}
		if regex := dropdown_regex_in(c, r, s); regex.width > 0 {
			over := d.regex_hover
			face, ink, err := button_draw(
				list,
				theme,
				{rect = regex, hover = over ? 1 : 0, radius = RADIUS_CONTROL, selected = d.regex},
				s,
				pointer,
			)
			if err != .None {return .Ok}
			if d.regex {ink = theme.accent}
			label := text_styled(text, .Body)
			x := face.x + (face.width - text_width(&label, ".*")) / 2
			if result := draw_text(&label, list, ".*", x, baseline_in(face.y, face.height, &label), ink);
			   result != .Ok {return result}
		}
		if render.push_layer(list, a.bounds) != .None {return .Ok}
		if c.font_filter {
			toggle := dropdown_toggle_rect(c, r, s)
			switch_w, switch_h := SWITCH_WIDTH * s, SWITCH_HEIGHT * s
			switch_rect := render.Rect {
				toggle.x + toggle.width - CONTROL_INSET * s - switch_w,
				toggle.y + (toggle.height - switch_h) / 2,
				switch_w,
				switch_h,
			}
			switch_draw(list, switch_rect, c.show_all_fonts, d.toggle_focus, theme, s)
			if result := draw_text(text, list, "Show all fonts", toggle.x + CONTROL_INSET * s,
			                       toggle.y + (toggle.height - text.line_height) / 2 + text.ascent,
			                       theme.text, switch_rect.x - toggle.x - 2 * CONTROL_INSET * s);
			   result != .Ok {return result}
		}
		header := dropdown_header(c, s)
		r.y += header
		r.height -= header
		if empty := dropdown_empty_text(d, c); empty != "" {
			return draw_text(text, list, empty, r.x + SPACE_3 * s,
			                 r.y + (r.height - text.line_height) / 2 + text.ascent,
			                 theme.muted, r.width - 28 * s)
		}
	}
	right := dropdown_option_right(d, c, a, r, s)
	pad := OVERLAY_PADDING * s
	for shown in 0 ..< count {
		i := d.list.scroll + shown
		if i >= dropdown_count(d, c) {break}
		source := dropdown_source(d, c, i)
		option := render.Rect {
			r.x + pad,
			r.y + pad + f32(shown) * CHOICE_HEIGHT * s,
			right - r.x - pad,
			CHOICE_HEIGHT * s,
		}
		if i == d.list.index {
			draw_rect(list, {rect = option, color = theme.selection, radius = RADIUS_CONTROL * s})
		}
		if render.rect_contains(option, pointer.x, pointer.y) {
			// Options carry the selection tint, not the paper fill, so no hairline.
			if result := hover_rim_draw(list, theme, option, RADIUS_CONTROL * s, 1, s, pointer, false);
			   result != .None {return .Ok}
		}
		if c.multiple {
			if choice_set_has(c.mask, source) {
				check := render.Rect{option.x + option.width - 28 * s, option.y, 24 * s, option.height}
				icon_draw(list, .Check, check, theme.accent, ICON_INDICATOR, s)
			}
		} else if c.choices[source] == c.value {
			mark := render.Rect{option.x, option.y + SPACE_2 * s, 3 * s, option.height - 2 * SPACE_2 * s}
			draw_rect(list, {rect = mark, color = theme.accent, radius = pill_radius(mark)})
		}
		ink := theme.text
		if source < len(c.faded) && c.faded[source] {
			ink = theme.muted
			ink.a *= DISABLED_ALPHA
		}
		if result := draw_text(
			text,
			list,
			dropdown_label(c, source),
			option.x + SPACE_3 * s,
			option.y + (option.height - text.line_height) / 2 + text.ascent,
			ink,
			option.width - (c.multiple ? 44 : 24) * s,
		); result != .Ok {return result}
	}
	if bar, visible := dropdown_scrollbar(d, c, a, s); visible {
		scrollbar_draw(list, theme, bar, scrollbar_state(d.bar_hover, d.drag.(Scroll_Drag) or_else Scroll_Drag{}))
	}
	return .Ok
}
