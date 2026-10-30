package ui

import "aio:colour"
import "aio:commands"
import "aio:glyphs"
import "aio:input"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Row_Kind :: enum {
	Text,
	Integer,
	Number,
	Toggle,
	Choice,
	Color,
	Optional_Color,
	Shortcut,
	Action,
	// One row per profile, its inline editor, the add row and the collapsed detected section.
	Profile,
	Profile_Add,
	Profile_Icon,
	Detected_Header,
	Detected,
}

// Facts the profile table draws beside a row. Ordinary settings rows leave these unset.
Editor_Row_Flag :: enum {
	Default,
	Hidden,
	// The profile already has an explicit profile.order entry.
	Listed,
}

// Strings, `choices` and `choice_labels` are owned by the editor. `choice_labels`, when present,
// is what each choice displays; the choice itself is the saved value. An empty optional color has no
// color at all. Profile rows also own `profile`, `badge`, `detail` (extra search text) and `note`
// (an inline problem).
Editor_Row :: struct {
	key, title, description, value, default_value: string,
	group:                                         int,
	kind:                                          Row_Kind,
	minimum, maximum:                              f64,
	choices, choice_labels:                        []string,
	profile, badge, detail, note:                  string,
	flags:                                         bit_set[Editor_Row_Flag],
}

Editor_Group :: struct {
	title: string,
	// The Profiles group draws column captions on its header line.
	table: bool,
}

// One page line: a group header, with its matching row count, when row is -1. Headers are never selected.
Editor_Item :: struct {
	group, row, count: int,
}

Editor_Drag :: enum {
	None,
	Filter,
	Value,
	Slider,
	Wheel,
	Ramp,
	Profile_Order,
}

// Keyboard focus: the search field, the selected row's control, or its key-position switch.
Editor_Focus :: enum {
	Search,
	Control,
	Positions,
}

Editor_Popup :: enum {
	None,
	Choice,
	Color,
	Shortcuts,
}

// The profile table's sub-controls, in Tab and Left/Right order.
Profile_Control :: enum {
	Radio,
	Hidden,
	Expand,
	Duplicate,
	Remove,
	Enable,
}

// A profile write the page owner must perform. Expansion, collapse and section toggles stay inside
// the editor; these outcomes describe a mutation for the page owner.
Profile_Action :: enum {
	None,
	Default,
	Hidden,
	Order,
	Enable,
	Duplicate,
	Remove,
}

// The settings page shown in a settings tab. Only the selected row is edited; its pending value lives
// in `value` until it is saved.
Editor :: struct {
	open, capturing, leader_pending, hover_clear:                      bool,
	// Captured shortcuts name physical key positions (Physical+) instead of layout characters.
	physical:                                                          bool,
	focus:                                                             Editor_Focus,
	popup:                                                             Editor_Popup,
	popup_index, popup_scroll, hover_item, hover_reset, hover_outline: int,
	// The group last chosen in the outline stays highlighted until the page scrolls or the selection moves,
	// since the final groups can be shown without reaching the top of the page.
	jump_group, outline_scroll, outline_active:                        int,
	rows:                                                              [dynamic]Editor_Row,
	groups:                                                            [dynamic]Editor_Group,
	items:                                                             [dynamic]Editor_Item,
	selected, scroll, visible_rows, captured, shortcut_index:          int,
	filter, value:                                                     Text_Field,
	drag:                                                              Editor_Drag,
	// The picker keeps hue and saturation while value is zero, where RGB alone would lose them.
	hsv:                                                               [3]f32,
	leader:                                                            Maybe(commands.Shortcut),
	source:                                                            string,
	message:                                                           string,
	error:                                                             bool,
	// Table state: the one expanded profile, the detected section, the focused control on a profile
	// row, and the drag that rewrites profile.order.
	expanded, remove_confirm:                                          string,
	detected_open:                                                     bool,
	profile_control:                                                   Profile_Control,
	action:                                                            Profile_Action,
	action_slot:                                                       int,
	action_id, action_value:                                           string,
	drag_id:                                                           string,
	drag_from, drag_target:                                            int,
	hover_profile_item:                                                int,
	hover_profile_control:                                             Profile_Control,
	error_key, error_profile, error_text:                              string,
}
Editor_Outcome :: enum {
	None,
	Changed,
	Save,
	Reset,
	Profile_Action,
}

// Table state a settings reload keeps: expansion, an open removal question and the detected section.
Editor_View :: struct {
	expanded, remove_confirm: string,
	detected_open:            bool,
}

// Wide pages put the search field and a group outline in a left column; narrow ones have no outline.
Editor_Layout :: struct {
	page, filter, list, outline:                     render.Rect,
	row_height, outline_row_height, status_x, scale: f32,
	rows:                                            int,
}

// The parts of one setting row; zero-sized parts do not exist for its kind.
Row_Parts :: struct {
	row, reset, field, toggle, slider, swatch, positions, clear: render.Rect,
	text_right:                                                 f32,
	positions_label_below:                                      bool,
}

CAPTURE_HINT :: "Press a shortcut. Enter saves this alternative, Esc cancels, Backspace removes it."
@(private)
ROW_HEIGHT :: 52
@(private)
CHOICE_HEIGHT :: 30
@(private)
OUTLINE_ROW_HEIGHT :: 30
@(private)
OUTLINE_WIDTH :: 220
@(private)
OUTLINE_MIN_PAGE :: 720
editor_destroy :: proc(p: ^Editor) {
	for row in p.rows {
		for s in ([?]string {
			row.key,
			row.title,
			row.description,
			row.value,
			row.default_value,
			row.profile,
			row.badge,
			row.detail,
			row.note,
		}) {delete(s)}
		for choice in row.choices {delete(choice)}
		delete(row.choices)
		for label in row.choice_labels {delete(label)}
		delete(row.choice_labels)
	}
	for group in p.groups {delete(group.title)}
	delete(p.rows)
	delete(p.groups)
	delete(p.items)
	delete(p.filter.bytes)
	delete(p.value.bytes)
	delete(p.source)
	delete(p.message)
	delete(p.expanded)
	delete(p.remove_confirm)
	delete(p.action_id)
	delete(p.action_value)
	delete(p.drag_id)
	delete(p.error_key)
	delete(p.error_profile)
	delete(p.error_text)
	p^ = {}
}

// Copies the table state a reload must keep. The caller frees the result with editor_view_destroy
// after editor_restore, which moves the strings into the rebuilt page.
@(require_results)
editor_view_take :: proc(p: ^Editor) -> (view: Editor_View, alloc_error: runtime.Allocator_Error) {
	view.detected_open = p.detected_open
	view.expanded = strings.clone(p.expanded) or_return
	view.remove_confirm = strings.clone(p.remove_confirm) or_return
	return
}

editor_view_destroy :: proc(view: ^Editor_View) {
	delete(view.expanded)
	delete(view.remove_confirm)
	view^ = {}
}

// Restores a previous view, dropping a profile that no longer exists. A reload after a successful
// save must land back on the same expanded row.
editor_view_restore :: proc(p: ^Editor, view: ^Editor_View) {
	p.detected_open = view.detected_open
	p.expanded, view.expanded = view.expanded, ""
	p.remove_confirm, view.remove_confirm = view.remove_confirm, ""
	if p.expanded != "" && !editor_has_profile_row(p, p.expanded) {delete(p.expanded); p.expanded = ""}
	if p.remove_confirm != "" &&
	   (!editor_has_profile_row(p, p.remove_confirm) || p.remove_confirm != p.expanded) {
		delete(p.remove_confirm)
		p.remove_confirm = ""
	}
}

@(private)
editor_has_profile_row :: proc(p: ^Editor, id: string) -> bool {
	for row in p.rows {
		if row.kind == .Profile && row.profile == id {return true}
	}
	return false
}

// Records the settings write a table action asks for. The page owner performs it and clears it.
editor_action_set :: proc(p: ^Editor, action: Profile_Action, id, value: string) {
	editor_action_clear(p)
	p.action = action
	p.action_id = strings.clone(id)
	p.action_value = strings.clone(value)
}

editor_action_clear :: proc(p: ^Editor) {
	delete(p.action_id)
	delete(p.action_value)
	p.action = .None
	p.action_slot = 0
	p.action_id, p.action_value = "", ""
}

// Marks one field row with an inline problem. The status line keeps the long form.
editor_error_set :: proc(p: ^Editor, profile, key, text: string) {
	editor_error_clear(p)
	p.error_key = strings.clone(key)
	p.error_profile = strings.clone(profile)
	p.error_text = strings.clone(text)
}

editor_error_clear :: proc(p: ^Editor) {
	delete(p.error_key)
	delete(p.error_profile)
	delete(p.error_text)
	p.error_key, p.error_profile, p.error_text = "", "", ""
}

@(require_results)
editor_add :: proc(p: ^Editor, row: Editor_Row, group: string) -> runtime.Allocator_Error {
	group_index := -1
	for g, i in p.groups {if g.title == group {group_index = i}}
	if group_index < 0 {
		title := strings.clone(group) or_return
		if _, err := append(&p.groups, Editor_Group{title = title});
		   err != nil {delete(title); return err}
		group_index = len(p.groups) - 1
	}
	owned: [9]string
	choices, labels: []string
	success := false
	defer if !success {
		for s in owned {delete(s)}
		for choice in choices {delete(choice)}
		delete(choices)
		for label in labels {delete(label)}
		delete(labels)
	}
	for s, i in ([?]string {
		row.key,
		row.title,
		row.description,
		row.value,
		row.default_value,
		row.profile,
		row.badge,
		row.detail,
		row.note,
	}) {owned[i] = strings.clone(s) or_return}
	if len(row.choices) > 0 {
		choices = make([]string, len(row.choices)) or_return
		for choice, i in row.choices {choices[i] = strings.clone(choice) or_return}
	}
	if len(row.choice_labels) > 0 {
		assert(len(row.choice_labels) == len(row.choices))
		labels = make([]string, len(row.choice_labels)) or_return
		for label, i in row.choice_labels {labels[i] = strings.clone(label) or_return}
	}
	added := row
	added.key, added.title, added.description, added.value, added.default_value =
		owned[0], owned[1], owned[2], owned[3], owned[4]
	added.profile, added.badge, added.detail, added.note = owned[5], owned[6], owned[7], owned[8]
	added.choices, added.choice_labels = choices, labels
	added.group = group_index
	_, err := append(&p.rows, added)
	success = err == nil
	return err
}

// Marks a group as the profile table so its header carries the column captions.
editor_group_table :: proc(p: ^Editor, group: string) {
	for &g in p.groups {
		if g.title == group {g.table = true}
	}
}

editor_message :: proc(p: ^Editor, text: string, error: bool) {
	delete(p.message)
	p.message = strings.clone(text)
	p.error = error
}

editor_row :: proc(p: ^Editor) -> ^Editor_Row {
	if p.selected < 0 || p.selected >= len(p.items) || p.items[p.selected].row < 0 {return nil}
	return &p.rows[p.items[p.selected].row]
}

editor_capturing :: proc(p: ^Editor) -> bool {return p.open && p.capturing}

editor_editing :: proc(p: ^Editor) -> bool {return p.focus == .Control}

@(private)
filtering :: proc(p: ^Editor) -> bool {return strings.trim_space(field_string(&p.filter)) != ""}

// A swatch shows a translucent color as it blends over the row.
@(private)
swatch_color :: proc(value: string) -> (render.Color, bool) {
	c, ok := colour.parse_translucent(value, .Permissive)
	return colour.rgba(c.rgb, f32(c.a) / 255), ok
}

@(private)
sync_color :: proc(p: ^Editor) {
	row := editor_row(p)
	if row == nil || (row.kind != .Color && row.kind != .Optional_Color) {return}
	c, ok, _ := settings.parse_color(field_string(&p.value))
	if !ok || settings.hsv_to_rgb(p.hsv[0], p.hsv[1], p.hsv[2]) == c {return}
	h, s, v := settings.rgb_to_hsv(c)
	if s == 0 || v == 0 {h = p.hsv[0]}
	if v == 0 {s = p.hsv[1]}
	p.hsv = {h, s, v}
}

// Leaves the selected row's control, discarding an unsaved value.
@(private)
stop_editing :: proc(p: ^Editor) {
	if p.error || p.capturing || p.popup == .Shortcuts {editor_message(p, "", false)}
	if p.error_text != "" {
		editor_message(p, "", false)
		editor_error_clear(p)
	}
	p.focus, p.capturing, p.leader_pending, p.captured = .Search, false, false, 0
	p.drag, p.popup = .None, .None
	if row := editor_row(p); row != nil {
		field_set(&p.value, row.value)
		sync_color(p)
	}
}

editor_select :: proc(p: ^Editor, index: int) {
	if p.error || p.capturing || p.popup == .Shortcuts {editor_message(p, "", false)}
	if p.error_text != "" {
		editor_message(p, "", false)
		editor_error_clear(p)
	}
	p.jump_group = -1
	p.selected = clamp(index, 0, max(0, len(p.items) - 1))
	p.capturing, p.leader_pending, p.captured, p.drag, p.popup = false, false, 0, .None, .None
	row := editor_row(p)
	if row != nil {
		field_set(&p.value, row.value)
		p.hsv = {0, 0, 1}
		sync_color(p)
	}
	p.profile_control = .Radio
	if row == nil || row.kind == .Shortcut || p.focus == .Positions {p.focus = .Search}
	if p.selected < p.scroll {p.scroll = p.selected}
	if p.selected >= p.scroll + max(1, p.visible_rows) {
		p.scroll = p.selected - max(1, p.visible_rows) + 1
	}
}

editor_select_key :: proc(p: ^Editor, key: string) -> bool {
	for row, i in p.rows {
		if row.key != key {continue}
		for item, index in p.items {
			if item.row == i {editor_select(p, index); return true}
		}
	}
	return false
}

// Selects a settings key, opening the profile row that owns it first. A palette jump or a reveal
// must be able to land on a field the collapsed table is not showing.
editor_reveal :: proc(p: ^Editor, key: string) -> bool {
	for row in p.rows {
		if row.key != key {continue}
		field := row.kind != .Profile && row.kind != .Detected
		if field && row.profile != "" && p.expanded != row.profile {
			delete(p.expanded)
			p.expanded = strings.clone(row.profile)
			if p.remove_confirm != "" {
				delete(p.remove_confirm)
				p.remove_confirm = ""
			}
			editor_rebuild(p)
		}
		break
	}
	return editor_select_key(p, key)
}

// Each query word matches as written or, for plurals such as "panes", without its final s.
@(private)
row_matches :: proc(words: []string, haystack: string, fuzzy: bool = false) -> bool {
	for word in words {
		if strings.contains(haystack, word) {continue}
		if len(word) > 3 &&
		   word[len(word) - 1] == 's' &&
		   strings.contains(haystack, word[:len(word) - 1]) {
			continue
		}
		if !fuzzy {return false}
		at := 0
		for c in haystack {
			if at >= len(word) {break}
			wanted, size := utf8.decode_rune(word[at:])
			if wanted == c {at += size}
		}
		if at != len(word) {return false}
	}
	return true
}

// Whether a row belongs to the page in the current expansion state, before search ranks it.
@(private)
row_available :: proc(p: ^Editor, row: Editor_Row) -> bool {
	#partial switch row.kind {
	case .Profile, .Profile_Add, .Detected_Header:
		return true
	case .Detected:
		return p.detected_open
	case .Action:
		confirm :=
			strings.has_suffix(row.key, ".remove.cancel") ||
			strings.has_suffix(row.key, ".remove.confirm")
		if confirm {
			return p.remove_confirm != "" && p.expanded == row.profile && row.profile == p.remove_confirm
		}
	}
	return row.profile == "" || row.profile == p.expanded
}

// Rebuilds the visible lines, keeping the current selection when it stays visible.
editor_rebuild :: proc(p: ^Editor) {
	selected := Editor_Item{-1, -1, 0}
	if p.selected >= 0 && p.selected < len(p.items) {selected = p.items[p.selected]}
	clear(&p.items)
	query := strings.to_lower(strings.trim_space(field_string(&p.filter)), context.temp_allocator)
	words := strings.fields(query, context.temp_allocator)
	ranks := make([]u8, len(p.rows), context.temp_allocator)
	best: u8
	for row, i in p.rows {
		if !row_available(p, row) {continue}
		haystack := strings.to_lower(
			fmt.tprintf(
				"%s %s %s %s %s %s %s",
				row.key,
				row.title,
				p.groups[row.group].title,
				row.description,
				row.detail,
				row.badge,
				row.kind == .Shortcut ? row.value : "",
			),
			context.temp_allocator,
		)
		if row_matches(words, haystack) {
			ranks[i] = 4
		} else if row.kind == .Shortcut &&
		   row_matches(words, strings.to_lower(row.value, context.temp_allocator), true) {
			ranks[i] = 3
		} else if row_matches(words, strings.to_lower(row.title, context.temp_allocator), true) {
			ranks[i] = 2
		} else if row_matches(words, haystack, true) {ranks[i] = 1}
		best = max(best, ranks[i])
	}
	matched := make([dynamic]int, context.temp_allocator)
	for _, g in p.groups {
		clear(&matched)
		for row, i in p.rows {
			if row.group != g {continue}
			if best > 0 && ranks[i] == best {append(&matched, i)}
		}
		if len(matched) == 0 {continue}
		append(&p.items, Editor_Item{g, -1, len(matched)})
		for i in matched {append(&p.items, Editor_Item{g, i, 0})}
	}
	p.selected = 0
	for item, index in p.items {
		if item.group == selected.group && item.row == selected.row {p.selected = index}
	}
}

editor_filter :: proc(p: ^Editor) {
	clear(&p.items)
	editor_rebuild(p)
	first := 0
	for item, index in p.items {if item.row >= 0 {first = index; break}}
	p.scroll, p.outline_scroll = 0, 0
	editor_select(p, first)
}

// Opens one profile's inline editor and closes any other. The table's row key is profile.ID.
editor_profile_expand :: proc(p: ^Editor, id: string) {
	if id == "" {return}
	if p.expanded != id {
		delete(p.expanded)
		p.expanded = strings.clone(id)
		if p.remove_confirm != "" && p.remove_confirm != id {
			delete(p.remove_confirm)
			p.remove_confirm = ""
		}
	}
	editor_rebuild(p)
	editor_select_key(p, fmt.tprintf("profile.%s", id))
}

editor_profile_collapse :: proc(p: ^Editor) {
	if p.expanded == "" {return}
	id := strings.clone(p.expanded, context.temp_allocator)
	delete(p.expanded)
	p.expanded = ""
	if p.remove_confirm != "" {
		delete(p.remove_confirm)
		p.remove_confirm = ""
	}
	editor_rebuild(p)
	editor_select_key(p, fmt.tprintf("profile.%s", id))
}

editor_profile_toggle :: proc(p: ^Editor, id: string) {
	if p.expanded == id {editor_profile_collapse(p)} else {editor_profile_expand(p, id)}
}

// The detected section is collapsed until asked for; a reload keeps its state.
editor_detected_toggle :: proc(p: ^Editor) {
	p.detected_open = !p.detected_open
	editor_rebuild(p)
	editor_select_key(p, "profiles.detected")
}

// Asks for confirmation inside the row's own editor. The confirm and cancel rows become visible.
editor_profile_remove_ask :: proc(p: ^Editor, id: string) {
	if id == "" || id == settings.PROFILE_DEFAULT_ID {return}
	if p.expanded != id {editor_profile_expand(p, id)}
	delete(p.remove_confirm)
	p.remove_confirm = strings.clone(id)
	editor_rebuild(p)
	editor_select_key(p, fmt.tprintf("profile.%s.remove.confirm", id))
}

editor_profile_remove_cancel :: proc(p: ^Editor) {
	if p.remove_confirm == "" {return}
	id := strings.clone(p.remove_confirm, context.temp_allocator)
	delete(p.remove_confirm)
	p.remove_confirm = ""
	editor_rebuild(p)
	editor_select_key(p, fmt.tprintf("profile.%s.remove", id))
}

// The profile table's index for a page item, counting only table rows before it.
@(private)
profile_index_at :: proc(p: ^Editor, item_index: int) -> int {
	count := 0
	for item, index in p.items {
		if index >= item_index {break}
		if item.row >= 0 && p.rows[item.row].kind == .Profile {count += 1}
	}
	return count
}

@(private)
profile_row_count :: proc(p: ^Editor) -> int {
	count := 0
	for item in p.items {
		if item.row >= 0 && p.rows[item.row].kind == .Profile {count += 1}
	}
	return count
}

// The insertion line's y for a drag target: the top of the slot's row, or the bottom of the last one.
@(private)
profile_drop_y :: proc(p: ^Editor, l: Editor_Layout) -> f32 {
	slot := 0
	for item, index in p.items {
		if item.row < 0 || p.rows[item.row].kind != .Profile {continue}
		if slot == p.drag_target {
			return l.list.y + f32(index - p.scroll) * l.row_height
		}
		slot += 1
	}
	last := -1
	for item, index in p.items {
		if item.row >= 0 && p.rows[item.row].kind == .Profile {last = index}
	}
	if last < 0 {return l.list.y}
	return l.list.y + f32(last - p.scroll + 1) * l.row_height
}

// Moves the selection by `delta` lines, passing over group headers in the direction of travel.
@(private)
editor_step :: proc(p: ^Editor, delta: int) {
	if len(p.items) == 0 {return}
	direction := delta < 0 ? -1 : 1
	index := clamp(p.selected + delta, 0, len(p.items) - 1)
	for index >= 0 && index < len(p.items) && p.items[index].row < 0 {index += direction}
	if index < 0 || index >= len(p.items) {
		index = clamp(p.selected + delta, 0, len(p.items) - 1)
		for index >= 0 && index < len(p.items) && p.items[index].row < 0 {index -= direction}
	}
	if index >= 0 && index < len(p.items) {editor_select(p, index)}
}

@(private)
max_scroll :: proc(p: ^Editor) -> int {return max(0, len(p.items) - max(1, p.visible_rows))}

// Scrolls the page, or the outline under the pointer, without moving the selection.
editor_wheel :: proc(p: ^Editor, l: Editor_Layout, x, y: f32, rows: int) {
	if p.popup == .Shortcuts && contains(editor_popup_rect(p, l), x, y) {
		if row := editor_row(p); row != nil {
			last := len(commands.shortcut_alternatives(row.value, context.temp_allocator))
			visible := shortcut_popup_rows(p, l)
			p.popup_scroll = clamp(p.popup_scroll - rows, 0, max(0, last - visible + 1))
			p.popup_index = clamp(
				p.popup_index,
				p.popup_scroll,
				min(last, p.popup_scroll + visible - 1),
			)
		}
		return
	}
	if contains(l.outline, x, y) {
		p.outline_scroll = clamp(
			p.outline_scroll - rows,
			0,
			max(0, len(outline_entries(p)) - outline_rows(l)),
		)
		return
	}
	p.jump_group = -1
	p.scroll = clamp(p.scroll - rows, 0, max_scroll(p))
}

// The page lines of every group header, in page order; the outline lists them.
@(private)
outline_entries :: proc(p: ^Editor) -> []int {
	entries := make([dynamic]int, context.temp_allocator)
	for item, index in p.items {if item.row < 0 {append(&entries, index)}}
	return entries[:]
}

@(private)
outline_rows :: proc(l: Editor_Layout) -> int {
	return l.outline_row_height > 0 ? int(l.outline.height / l.outline_row_height) : 0
}

// The group the page is showing: the one last chosen in the outline, otherwise the one at the top.
editor_active_group :: proc(p: ^Editor) -> int {
	if len(p.items) == 0 {return -1}
	for item in p.items {if item.row < 0 && item.group == p.jump_group {return p.jump_group}}
	return p.items[clamp(p.scroll, 0, len(p.items) - 1)].group
}

// Scrolls the chosen outline group's header to the top of the page and selects its first setting.
editor_jump :: proc(p: ^Editor, entry: int) {
	entries := outline_entries(p)
	if entry < 0 || entry >= len(entries) {return}
	header := entries[entry]
	if p.focus != .Search {stop_editing(p)}
	p.popup = .None
	p.scroll = clamp(header, 0, max_scroll(p))
	editor_select(p, header + 1)
	p.scroll = clamp(header, 0, max_scroll(p))
	p.jump_group = p.items[header].group
}

@(private)
number_text :: proc(row: ^Editor_Row, value: f64) -> string {
	if row.kind == .Integer || row.key == "font.size" || row.key == "interface.font_size" {
		return fmt.tprintf("%d", int(math.round(value)))
	}
	if row.key == "font.line_height" {return fmt.tprintf("%.2f", math.round(value * 20) / 20)}
	return fmt.tprintf("%g", math.round(value * 10) / 10)
}

// Wide ranges such as scrollback lines use a logarithmic track so small values stay reachable.
@(private)
slider_fraction :: proc(row: ^Editor_Row, value: f64) -> f32 {
	span := row.maximum - row.minimum
	if span <= 0 {return 0}
	v := clamp(value, row.minimum, row.maximum)
	if span > 1000 {return f32(math.ln(v - row.minimum + 1) / math.ln(span + 1))}
	return f32((v - row.minimum) / span)
}

@(private)
slider_value :: proc(row: ^Editor_Row, fraction: f32) -> f64 {
	f := f64(clamp(fraction, 0, 1))
	span := row.maximum - row.minimum
	if span > 1000 {return row.minimum + math.exp(f * math.ln(span + 1)) - 1}
	return row.minimum + f * span
}

@(private)
flip_toggle :: proc(p: ^Editor) -> Editor_Outcome {
	field_set(&p.value, field_string(&p.value) == "true" ? "false" : "true")
	return .Save
}

@(private)
choice_index :: proc(row: ^Editor_Row, value: string) -> int {
	for name, i in row.choices {if name == value {return i}}
	return 0
}

// What a choice displays: its label, or the value itself.
@(private)
choice_label :: proc(row: ^Editor_Row, value: string) -> string {
	if len(row.choice_labels) == 0 {return value}
	for name, i in row.choices {if name == value && row.choice_labels[i] != "" {return row.choice_labels[i]}}
	return value
}

@(private)
choose :: proc(p: ^Editor, row: ^Editor_Row, index: int) -> Editor_Outcome {
	if len(row.choices) == 0 {return .None}
	next := clamp(index, 0, len(row.choices) - 1)
	p.popup = .None
	if row.choices[next] == field_string(&p.value) {return .Changed}
	field_set(&p.value, row.choices[next])
	return .Save
}

@(private)
open_choices :: proc(p: ^Editor, row: ^Editor_Row) {
	p.popup, p.focus = .Choice, .Control
	p.popup_index = choice_index(row, field_string(&p.value))
}

@(private)
start_capture :: proc(p: ^Editor, index: int = 0) {
	p.focus, p.capturing, p.leader_pending, p.captured, p.popup = .Control, true, false, 0, .None
	p.shortcut_index = index
	editor_message(
		p,
		p.leader == nil ? CAPTURE_HINT + " Set Leader Key to use leader chords." : CAPTURE_HINT,
		false,
	)
}

@(private)
shortcut_replace :: proc(p: ^Editor, row: ^Editor_Row, label: string) {
	parts := commands.shortcut_alternatives(row.value, context.temp_allocator)
	alternatives := make([]string, len(parts) + 1, context.temp_allocator)
	copy(alternatives, parts)
	count := len(parts)
	if p.shortcut_index < count {
		alternatives[p.shortcut_index] = label
	} else if label != "" {
		alternatives[count] = label
		count += 1
	}
	text := commands.shortcut_alternatives_text(alternatives[:count], context.temp_allocator)
	field_set(&p.value, text)
}

@(private)
open_shortcuts :: proc(p: ^Editor) {
	p.popup_scroll = 0
	p.popup, p.popup_index, p.focus = .Shortcuts, 0, .Control
	editor_message(
		p,
		"Choose an alternative to replace; Delete removes it. Add shortcut keeps the others.",
		false,
	)
}

@(private)
is_modifier :: proc(key: input.Key) -> bool {
	#partial switch key {
	case .Shift_Left,
	     .Shift_Right,
	     .Control_Left,
	     .Control_Right,
	     .Alt_Left,
	     .Alt_Right,
	     .Meta_Left,
	     .Meta_Right,
	     .Caps_Lock,
	     .Num_Lock:
		return true
	}
	return false
}

// Records chords pressed while a shortcut field captures. Pressing the leader first adds Leader+.
@(private)
capture_key :: proc(p: ^Editor, row: ^Editor_Row, e: platform.Key_Event) -> Editor_Outcome {
	if is_modifier(e.key) {return .None}
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	if modifiers == {} && !p.leader_pending {
		#partial switch e.key {
		case .Escape:
			stop_editing(p)
			editor_message(p, "", false)
			return .Changed
		case .Enter, .Numpad_Enter:
			p.capturing = false
			return .Save
		case .Backspace, .Delete:
			if strings.has_prefix(row.key, settings.KEY_BINDING_PREFIX) {
				shortcut_replace(p, row, "")
			} else {field_set(&p.value, "")}
			p.captured = 0
			return .Changed
		case .Tab:
			p.capturing, p.focus = false, .Positions
			editor_message(p, "", false)
			return .Changed
		}
	}
	chord := commands.Shortcut {
		p.physical ? e.key : commands.logical_key(e.key, e.unshifted),
		modifiers,
	}
	if p.physical {chord.modifiers += {.Physical}}
	binding := strings.has_prefix(row.key, settings.KEY_BINDING_PREFIX)
	if leader, ok := p.leader.?;
	   ok &&
	   binding &&
	   !p.leader_pending &&
	   commands.shortcut_matches(leader, e.key, modifiers, e.unshifted) {
		p.leader_pending = true
		editor_message(p, "Leader pressed; press the key that follows it.", false)
		return .Changed
	}
	if p.leader_pending {
		chord.modifiers += {.Leader}
		p.leader_pending = false
	} else if modifiers & {.Control, .Alt, .Super} == {} && e.text != "" {
		editor_message(p, "Typing keys need Ctrl, Alt, or the leader.", true)
		return .Changed
	}
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	label := commands.shortcut_text(chord, buffer[:])
	if binding {
		shortcut_replace(p, row, label)
		p.captured = 1
	} else {
		field_set(&p.value, label)
		p.captured = 1
	}
	editor_message(p, CAPTURE_HINT, false)
	return .Changed
}

@(private)
text_kind :: proc(kind: Row_Kind) -> bool {
	return(
		kind == .Text ||
		kind == .Integer ||
		kind == .Number ||
		kind == .Color ||
		kind == .Optional_Color ||
		kind == .Profile_Icon \
	)
}

// Moves the focus ring across a table row's controls. A detected row has only Enable.
@(private)
profile_control_step :: proc(p: ^Editor, row: ^Editor_Row, step: int) {
	order: [5]Profile_Control
	count := 0
	if row.kind == .Detected {
		order[0] = .Enable
		count = 1
	} else {
		order[0], order[1], order[2], order[3], order[4] =
			.Radio, .Hidden, .Expand, .Duplicate, .Remove
		count = row.profile == settings.PROFILE_DEFAULT_ID ? 4 : 5
	}
	index := 0
	for control, i in order[:count] {if control == p.profile_control {index = i}}
	p.profile_control = order[(index + step + count) % count]
}

// Runs the control under the focus ring. Radio, Hidden, Duplicate, Remove and Enable name a
// settings write the page owner performs; Expand stays inside the editor.
@(private)
profile_activate :: proc(p: ^Editor, row: ^Editor_Row) -> Editor_Outcome {
	switch p.profile_control {
	case .Radio:
		editor_action_set(p, .Default, row.profile, "")
		return .Profile_Action
	case .Hidden:
		editor_action_set(p, .Hidden, row.profile, .Hidden in row.flags ? "false" : "true")
		return .Profile_Action
	case .Expand:
		editor_profile_toggle(p, row.profile)
		return .Changed
	case .Duplicate:
		editor_action_set(p, .Duplicate, row.profile, "")
		return .Profile_Action
	case .Remove:
		editor_profile_remove_ask(p, row.profile)
		return .Changed
	case .Enable:
		editor_action_set(p, .Enable, row.profile, "")
		return .Profile_Action
	}
	return .None
}

// Activates the selected row from the keyboard: toggles flip, lists open, fields take the keyboard.
@(private)
activate :: proc(p: ^Editor, row: ^Editor_Row) -> Editor_Outcome {
	switch row.kind {
	case .Action:
		return .Save
	case .Toggle:
		p.focus = .Control
		return flip_toggle(p)
	case .Choice:
		open_choices(p, row)
	case .Shortcut:
		if strings.has_prefix(
			row.key,
			settings.KEY_BINDING_PREFIX,
		) {open_shortcuts(p)} else {start_capture(p)}
	case .Color, .Optional_Color:
		p.focus, p.popup = .Control, .Color
		field_select_all(&p.value)
	case .Text, .Integer, .Number, .Profile_Icon:
		p.focus = .Control
		field_select_all(&p.value)
	case .Profile:
		if p.focus == .Control {return profile_activate(p, row)}
		editor_profile_toggle(p, row.profile)
	case .Profile_Add:
		return .Save
	case .Detected_Header:
		editor_detected_toggle(p)
	case .Detected:
		editor_action_set(p, .Enable, row.profile, "")
		return .Profile_Action
	}
	return .Changed
}

@(private)
popup_key :: proc(p: ^Editor, row: ^Editor_Row, e: platform.Key_Event) -> (Editor_Outcome, bool) {
	control := .Control in e.modifiers && .Alt not_in e.modifiers
	if p.popup == .Shortcuts {
		count := len(commands.shortcut_alternatives(row.value, context.temp_allocator))
		last := count
		#partial switch e.key {
		case .Escape:
			stop_editing(p)
		case .Arrow_Up, .Arrow_Down, .P, .N:
			if (e.key == .P || e.key == .N) && !control {return .None, true}
			p.popup_index = clamp(
				p.popup_index + (e.key == .Arrow_Up || e.key == .P ? -1 : 1),
				0,
				last,
			)
			p.popup_scroll = clamp(p.popup_scroll, max(0, p.popup_index - 7), p.popup_index)
		case .Enter, .Numpad_Enter, .Space:
			start_capture(p, p.popup_index)
		case .Delete, .Backspace:
			if p.popup_index < count {
				p.shortcut_index = p.popup_index
				shortcut_replace(p, row, "")
				p.popup = .None
				return .Save, true
			}
		}
		return .Changed, true
	}
	#partial switch e.key {
	case .Escape:
		p.popup = .None
		return .Changed, true
	case .Arrow_Up, .Arrow_Down, .P, .N:
		if p.popup != .Choice || ((e.key == .P || e.key == .N) && !control) {return .None, false}
		delta := e.key == .Arrow_Up || e.key == .P ? -1 : 1
		p.popup_index = clamp(p.popup_index + delta, 0, len(row.choices) - 1)
		return .Changed, true
	case .Enter, .Numpad_Enter, .Space:
		if p.popup == .Choice {return choose(p, row, p.popup_index), true}
		if e.key == .Space {return .None, false}
		p.popup = .None
		return .Save, true
	}
	return .None, p.popup == .Choice
}

// Takes the raw key event: capture needs the physical key, and navigation uses the layout's key.
editor_key :: proc(p: ^Editor, raw: platform.Key_Event) -> Editor_Outcome {
	if !raw.pressed {return .None}
	row := editor_row(p)
	if p.capturing && row != nil {return capture_key(p, row, raw)}
	e := raw
	e.key = commands.logical_key(raw.key, raw.unshifted)
	if p.popup != .None && row != nil {
		if outcome, handled := popup_key(p, row, e); handled {return outcome}
	}
	control := .Control in e.modifiers && .Alt not_in e.modifiers
	if .Alt in e.modifiers && (e.key == .Arrow_Up || e.key == .Arrow_Down) {
		entries := outline_entries(p)
		for header, entry in entries {
			if p.items[header].group == editor_active_group(p) {
				editor_jump(p, clamp(entry + (e.key == .Arrow_Up ? -1 : 1), 0, len(entries) - 1))
				break
			}
		}
		return .Changed
	}
	#partial switch e.key {
	case .Escape:
		if p.remove_confirm != "" {
			editor_profile_remove_cancel(p)
			return .Changed
		}
		// Escape leaves an expanded field first, then collapses the row from its table line.
		if row != nil &&
		   row.profile != "" &&
		   row.profile == p.expanded &&
		   (p.focus != .Control || row.kind == .Profile) {
			editor_profile_collapse(p)
			return .Changed
		}
		if p.focus != .Search {
			stop_editing(p)
			return .Changed
		}
		if len(p.filter.bytes) == 0 {return .None}
		field_set(&p.filter, "")
		editor_filter(p)
		return .Changed
	case .Tab:
		stops := 2
		if row == nil || row.kind == .Profile_Add || row.kind == .Detected_Header {stops = 1}
		if row != nil && row.kind == .Shortcut {stops = 3}
		focus := (int(p.focus) + (.Shift in e.modifiers ? stops - 1 : 1)) % stops
		p.popup = .None
		if Editor_Focus(focus) == .Control && row != nil {
			if row.kind == .Profile || row.kind == .Detected {
				p.focus = .Control
				p.profile_control = row.kind == .Detected ? .Enable : .Radio
				return .Changed
			}
			return activate(p, row)
		}
		if p.focus == .Control {stop_editing(p)}
		p.focus = Editor_Focus(focus)
		return .Changed
	case .Arrow_Up:
		editor_step(p, -1); return .Changed
	case .Arrow_Down:
		editor_step(p, 1); return .Changed
	case .P, .N:
		if control {
			editor_step(p, e.key == .N ? 1 : -1)
			return .Changed
		}
	case .Page_Up:
		editor_step(p, -max(1, p.visible_rows)); return .Changed
	case .Page_Down:
		editor_step(p, max(1, p.visible_rows)); return .Changed
	case .Enter, .Numpad_Enter:
		if row == nil {return .None}
		if p.focus == .Positions {p.physical = !p.physical; return .Changed}
		if p.focus == .Control && text_kind(row.kind) {
			p.popup = .None
			return .Save
		}
		if row.kind == .Profile && p.focus == .Control {return profile_activate(p, row)}
		return activate(p, row)
	case .Space:
		if p.focus == .Positions {p.physical = !p.physical; return .Changed}
		if row == nil {return .None}
		if p.focus == .Control && (row.kind == .Profile || row.kind == .Detected) {
			return profile_activate(p, row)
		}
		if p.focus == .Control && row.kind == .Toggle {return flip_toggle(p)}
	case .Arrow_Left, .Arrow_Right:
		left := e.key == .Arrow_Left
		if row != nil && (row.kind == .Profile || row.kind == .Detected) {
			if p.focus == .Control {
				profile_control_step(p, row, left ? -1 : 1)
				return .Changed
			}
			if row.kind == .Profile {
				if left {editor_profile_collapse(p)} else {editor_profile_expand(p, row.profile)}
				return .Changed
			}
		}
		if p.focus == .Control && row != nil && row.kind == .Choice {
			return choose(p, row, choice_index(row, field_string(&p.value)) + (left ? -1 : 1))
		}
	case .D:
		if control {break}
		// Row shortcuts only run from the row's own control focus. While the search has focus,
		// the same letters belong to the filter.
		if p.focus == .Control && row != nil && row.kind == .Profile {
			editor_action_set(p, .Default, row.profile, "")
			return .Profile_Action
		}
	case .Delete, .Backspace:
		if control {break}
		if p.focus == .Control && row != nil && row.kind == .Profile {
			editor_profile_remove_ask(p, row.profile)
			return .Changed
		}
	case .R:
		if control {return row == nil ? .None : .Reset}
	}
	switch p.focus {
	case .Positions:
		return .None
	case .Control:
		if row != nil && text_kind(row.kind) {
			if field_key(&p.value, e) == .Edited {sync_color(p)}
			return .Changed
		}
		p.focus, p.popup = .Search, .None
	case .Search:
	}
	if field_key(&p.filter, e) == .Edited {editor_filter(p)}
	return .Changed
}

editor_text :: proc(p: ^Editor, text: string) {
	if p.capturing || p.focus == .Positions {return}
	row := editor_row(p)
	if p.focus == .Control && row != nil && text_kind(row.kind) {
		if field_text(&p.value, text) == .Edited {sync_color(p)}
		return
	}
	if p.focus == .Control &&
	   row != nil &&
	   (row.kind == .Profile ||
			   row.kind == .Detected ||
			   row.kind == .Detected_Header ||
			   row.kind == .Profile_Add) {return}
	p.focus, p.popup = .Search, .None
	if field_text(&p.filter, text) == .Edited {
		editor_filter(p)
	}
}

// Pasted text replaces the focused field's selection up to its first line break.
editor_paste :: proc(p: ^Editor, text: string) {
	line := text
	if end := strings.index_any(text, "\r\n"); end >= 0 {line = text[:end]}
	editor_text(p, line)
}

// The selected text of the focused field, for copying.
editor_selection :: proc(p: ^Editor) -> string {
	switch p.focus {
	case .Search:
		return field_selected_text(&p.filter)
	case .Control:
		if !p.capturing {return field_selected_text(&p.value)}
	case .Positions:
	}
	return ""
}

// Removes the selected text of the focused field after it was copied.
editor_cut :: proc(p: ^Editor) {
	if editor_selection(p) == "" {return}
	if p.focus == .Control {
		if row := editor_row(p); row != nil && text_kind(row.kind) {
			field_text(&p.value, "")
			sync_color(p)
		}
	} else {
		field_text(&p.filter, "")
		editor_filter(p)
	}
}

// Lays the page out inside a settings tab's card.
editor_layout :: proc(area: render.Rect, scale: f32) -> Editor_Layout {
	s := scale
	pad := 24 * s
	bottom := area.y + area.height - pad / 2
	l := Editor_Layout {
		page       = area,
		row_height = ROW_HEIGHT * s,
		scale      = s,
	}
	if area.width < OUTLINE_MIN_PAGE * s {
		width := max(0, min(960 * s, area.width - 2 * pad))
		x := area.x + max(pad, (area.width - width) / 2)
		l.filter = {x, area.y + 52 * s, width, 34 * s}
		top := l.filter.y + l.filter.height + 12 * s
		l.rows = max(0, int((bottom - top) / l.row_height))
		l.list = {x, top, width, f32(l.rows) * l.row_height}
		return l
	}
	// The outline and list stay together as one block, centered once the list reaches its maximum width.
	gutter := 24 * s
	width := max(0, min(960 * s, area.width - 2 * pad - OUTLINE_WIDTH * s - gutter))
	outline_x := area.x + max(pad, (area.width - OUTLINE_WIDTH * s - gutter - width) / 2)
	l.filter = {outline_x, area.y + 52 * s, OUTLINE_WIDTH * s, 34 * s}
	outline_top := l.filter.y + l.filter.height + 12 * s
	l.outline_row_height = OUTLINE_ROW_HEIGHT * s
	l.outline = {outline_x, outline_top, OUTLINE_WIDTH * s, max(0, bottom - outline_top)}
	x := outline_x + OUTLINE_WIDTH * s + gutter
	top := l.filter.y
	l.rows = max(0, int((bottom - top) / l.row_height))
	l.list = {x, top, width, f32(l.rows) * l.row_height}
	l.status_x = x
	return l
}

// The clear button inside the search field, shown while the field has text.
editor_clear_rect :: proc(p: ^Editor, l: Editor_Layout) -> render.Rect {
	if len(p.filter.bytes) == 0 {return {}}
	s := l.scale
	return {
		l.filter.x + l.filter.width - 30 * s,
		l.filter.y + (l.filter.height - 26 * s) / 2,
		26 * s,
		26 * s,
	}
}

@(private)
filter_text_rect :: proc(p: ^Editor, l: Editor_Layout) -> render.Rect {
	r := l.filter
	if clear := editor_clear_rect(p, l); clear.width > 0 {r.width = clear.x - r.x}
	return r
}

// The value field of one row. Every row kind that shows editable text shares this box.
@(private)
value_box :: proc(p: ^Editor, parts: Row_Parts, text: ^Text, scale: f32) -> Field_Box {
	return {
		field = &p.value,
		text = text,
		rect = parts.field,
		inset = 10,
		caret_width = 1,
		radius = 6,
		style = .Input,
		scale = scale,
	}
}

// The search field, narrowed to leave room for the clear button when it is shown.
@(private)
filter_box :: proc(p: ^Editor, l: Editor_Layout, text: ^Text) -> Field_Box {
	return {
		field = &p.filter,
		text = text,
		rect = filter_text_rect(p, l),
		inset = 10,
		caret_width = 1,
		radius = 6,
		style = .Input,
		scale = l.scale,
	}
}

editor_row_parts :: proc(p: ^Editor, l: Editor_Layout, index: int) -> Row_Parts {
	s := l.scale
	r := render.Rect {
		l.list.x,
		l.list.y + f32(index - p.scroll) * l.row_height,
		l.list.width,
		l.row_height,
	}
	parts := Row_Parts {
		row = r,
	}
	item := p.items[index]
	cy := r.y + r.height / 2
	parts.reset = {r.x + r.width - 34 * s, cy - 13 * s, 26 * s, 26 * s}
	right := parts.reset.x - 12 * s
	parts.text_right = right
	if item.row < 0 {return parts}
	row := p.rows[item.row]
	field := proc(right, cy, width, s: f32) -> render.Rect {return {
			right - width * s,
			cy - 15 * s,
			width * s,
			30 * s,
		}}
	switch row.kind {
	case .Action:
		parts.field = field(right, cy, 240, s)
		parts.reset = {}
	case .Toggle:
		parts.toggle = {right - 44 * s, cy - 11 * s, 44 * s, 22 * s}
		parts.text_right = parts.toggle.x - 48 * s
	case .Choice:
		parts.field = field(right, cy, 180, s)
	case .Integer, .Number:
		parts.field = field(right, cy, 90, s)
		parts.slider = {parts.field.x - 176 * s, cy - 6 * s, 160 * s, 12 * s}
		parts.text_right = parts.slider.x - 12 * s
	case .Text:
		parts.field = field(right, cy, min(360, r.width / s * 0.42), s)
	case .Profile_Icon:
		edge := r.x + r.width - 12 * s
		parts.clear = {edge - 52 * s, cy - 13 * s, 52 * s, 26 * s}
		parts.field = field(parts.clear.x - 8 * s, cy, min(300, r.width / s * 0.38), s)
		parts.swatch = {parts.field.x - 42 * s, cy - 15 * s, 30 * s, 30 * s}
		parts.reset = {}
		parts.text_right = parts.swatch.x - 12 * s
	case .Color, .Optional_Color:
		parts.field = field(right, cy, 120, s)
		parts.swatch = {parts.field.x - 38 * s, cy - 15 * s, 30 * s, 30 * s}
		parts.text_right = parts.swatch.x - 12 * s
	case .Shortcut:
		parts.field = field(right, cy, clamp((right - r.x) / s * 0.45, 120, 240), s)
		if index == p.selected {
			parts.positions = {parts.field.x - 148 * s, cy - 11 * s, 36 * s, 22 * s}
			parts.text_right = parts.positions.x
			// Narrow rows stack the label under the switch so both stay inside the row.
			if parts.positions.x - r.x < 190 * s {
				parts.text_right = parts.field.x - 84 * s
				parts.positions = {parts.text_right + 18 * s, r.y + 6 * s, 36 * s, 22 * s}
				parts.positions_label_below = true
			}
		}
	case .Profile, .Profile_Add, .Detected_Header, .Detected:
		parts.reset = {}
	}
	if parts.field.width > 0 && parts.text_right > parts.field.x {parts.text_right = parts.field.x}
	parts.text_right -= 16 * s
	return parts
}

// The table cells of the item at `index`. The editor's row rect is the only shared part.
editor_profile_parts :: proc(p: ^Editor, l: Editor_Layout, index: int) -> Profile_Parts {
	if index < 0 || index >= len(p.items) || p.items[index].row < 0 {return {}}
	row := &p.rows[p.items[index].row]
	return profile_row_parts(row.kind, editor_row_parts(p, l, index).row, l.scale)
}

// The open dropdown or color picker for the selected row, flipped above it when there is no room below.
@(private)
shortcut_popup_rows :: proc(p: ^Editor, l: Editor_Layout) -> int {
	row := editor_row(p)
	if row == nil {return 0}
	return min(
		len(commands.shortcut_alternatives(row.value, context.temp_allocator)) + 1,
		8,
		max(1, int((l.page.height - 16 * l.scale) / (CHOICE_HEIGHT * l.scale))),
	)
}

editor_popup_rect :: proc(p: ^Editor, l: Editor_Layout) -> render.Rect {
	row := editor_row(p)
	if p.popup == .None || row == nil || p.selected < p.scroll || p.selected >= p.scroll + l.rows {
		return {}
	}
	parts := editor_row_parts(p, l, p.selected)
	s := l.scale
	r: render.Rect
	if p.popup == .Shortcuts {
		count := shortcut_popup_rows(p, l)
		r = {
			parts.field.x + parts.field.width - 320 * s,
			parts.field.y + parts.field.height + 4 * s,
			320 * s,
			f32(count) * CHOICE_HEIGHT * s + 8 * s,
		}
	} else if p.popup == .Choice {
		r = {
			parts.field.x,
			parts.field.y + parts.field.height + 4 * s,
			parts.field.width,
			f32(len(row.choices)) * CHOICE_HEIGHT * s + 8 * s,
		}
	} else {
		r = {
			parts.field.x + parts.field.width - 292 * s,
			parts.field.y + parts.field.height + 6 * s,
			292 * s,
			(row.kind == .Optional_Color ? 206 : 166) * s,
		}
	}
	if r.y + r.height > l.page.y + l.page.height - 8 * s {r.y = parts.row.y - r.height - 4 * s}
	if p.popup == .Shortcuts {
		r.width = min(r.width, l.page.width - 16 * s)
		r.x = clamp(
			r.x,
			l.page.x + 8 * s,
			max(l.page.x + 8 * s, l.page.x + l.page.width - r.width - 8 * s),
		)
		r.y = clamp(
			r.y,
			l.page.y + 8 * s,
			max(l.page.y + 8 * s, l.page.y + l.page.height - r.height - 8 * s),
		)
	}
	return r
}

@(private)
Color_Parts :: struct {
	wheel, ramp, swatch, no_color: render.Rect,
}

@(private)
color_parts :: proc(popup: render.Rect, optional: bool, scale: f32) -> Color_Parts {
	s := scale
	c := Color_Parts {
		wheel = {popup.x + 12 * s, popup.y + 12 * s, 140 * s, 140 * s},
	}
	c.ramp = {popup.x + 168 * s, popup.y + 24 * s, 112 * s, 16 * s}
	c.swatch = {popup.x + 168 * s, popup.y + 60 * s, 112 * s, 40 * s}
	if optional {c.no_color = {popup.x + 12 * s, popup.y + 166 * s, 140 * s, 28 * s}}
	return c
}

@(private)
contains :: proc(r: render.Rect, x, y: f32) -> bool {
	return r.width > 0 && x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

@(private)
pick_color :: proc(p: ^Editor, c: Color_Parts, x, y: f32) {
	if p.drag == .Wheel {
		radius := c.wheel.width / 2
		dx, dy := x - (c.wheel.x + radius), y - (c.wheel.y + radius)
		hue := math.to_degrees(math.atan2(dy, dx))
		if hue < 0 {hue += 360}
		p.hsv[0], p.hsv[1] = hue, min(1, math.sqrt(dx * dx + dy * dy) / max(1, radius))
	} else {
		p.hsv[2] = clamp((x - c.ramp.x) / max(1, c.ramp.width), 0, 1)
	}
	// The picker chooses hue, saturation and value; a translucent color keeps its typed alpha.
	picked := settings.hsv_to_rgb(p.hsv[0], p.hsv[1], p.hsv[2])
	previous, _ := colour.parse_translucent(field_string(&p.value), .Permissive)
	buffer: [colour.HEX_ALPHA_LENGTH]u8
	text := colour.format_translucent({picked.r, picked.g, picked.b, previous.a}, buffer[:])
	if previous.a == 0 {text = colour.format(picked, buffer[:])}
	field_set(&p.value, text)
}

@(private)
slide :: proc(p: ^Editor, row: ^Editor_Row, slider: render.Rect, x: f32) {
	field_set(&p.value, number_text(row, slider_value(row, (x - slider.x) / max(1, slider.width))))
}

// A press inside the page; `extend` (Shift) grows a text selection instead of moving the caret.
editor_press :: proc(
	p: ^Editor,
	l: Editor_Layout,
	text: ^Text,
	x, y: f32,
	extend: bool,
) -> Editor_Outcome {
	s := l.scale
	if p.popup != .None {
		popup := editor_popup_rect(p, l)
		row := editor_row(p)
		if !contains(popup, x, y) || row == nil {
			if p.popup == .Shortcuts {editor_message(p, "", false)}
			p.popup = .None
			return .Changed
		}
		if p.popup == .Choice {
			return choose(p, row, int((y - popup.y - 4 * s) / (CHOICE_HEIGHT * s)))
		}
		if p.popup == .Shortcuts {
			count := len(commands.shortcut_alternatives(row.value, context.temp_allocator))
			index := clamp(
				int((y - popup.y - 4 * s) / (CHOICE_HEIGHT * s)) + p.popup_scroll,
				0,
				count,
			)
			if index < count && x >= popup.x + popup.width - 32 * s {
				p.shortcut_index = index
				shortcut_replace(p, row, "")
				p.popup = .None
				return .Save
			}
			start_capture(p, index)
			return .Changed
		}
		c := color_parts(popup, row.kind == .Optional_Color, s)
		switch {
		case contains(c.wheel, x, y):
			p.drag = .Wheel
		case contains({c.ramp.x, c.ramp.y - 6 * s, c.ramp.width, c.ramp.height + 12 * s}, x, y):
			p.drag = .Ramp
		case contains(c.no_color, x, y):
			field_set(&p.value, "")
			p.popup = .None
			return .Save
		case:
			return .None
		}
		pick_color(p, c, x, y)
		return .Changed
	}
	if contains(editor_clear_rect(p, l), x, y) {
		if p.focus != .Search {stop_editing(p)}
		field_set(&p.filter, "")
		editor_filter(p)
		return .Changed
	}
	if contains(l.filter, x, y) {
		if p.focus != .Search {stop_editing(p)}
		field_pointer(&p.filter, field_box_offset(filter_box(p, l, text), x), true, extend)
		p.drag = .Filter
		return .Changed
	}
	if contains(l.outline, x, y) {
		entry := p.outline_scroll + int((y - l.outline.y) / l.outline_row_height)
		if entry >= len(outline_entries(p)) {return .None}
		editor_jump(p, entry)
		return .Changed
	}
	if !contains(l.list, x, y) {return .None}
	index := p.scroll + int((y - l.list.y) / l.row_height)
	if index >= len(p.items) || p.items[index].row < 0 {return .None}
	if index != p.selected {editor_select(p, index)}
	row := editor_row(p)
	parts := editor_row_parts(p, l, index)
	if row.kind == .Profile || row.kind == .Detected || row.kind == .Profile_Add ||
	   row.kind == .Detected_Header {
		table := profile_row_parts(row.kind, parts.row, s)
		switch {
		case row.kind == .Profile && contains(table.handle, x, y):
			if filtering(p) {return .Changed}
			p.drag = .Profile_Order
			delete(p.drag_id)
			p.drag_id = strings.clone(row.profile)
			p.drag_from = profile_index_at(p, index)
			p.drag_target = p.drag_from
			return .Changed
		case row.kind == .Profile && contains(table.radio, x, y):
			p.focus, p.profile_control = .Control, .Radio
			editor_action_set(p, .Default, row.profile, "")
			return .Profile_Action
		case row.kind == .Profile && contains(table.toggle, x, y):
			p.focus, p.profile_control = .Control, .Hidden
			editor_action_set(p, .Hidden, row.profile, .Hidden in row.flags ? "false" : "true")
			return .Profile_Action
		case row.kind == .Profile && contains(table.expand, x, y):
			p.focus, p.profile_control = .Control, .Expand
			editor_profile_toggle(p, row.profile)
			return .Changed
		case row.kind == .Profile && contains(table.duplicate, x, y):
			p.focus, p.profile_control = .Control, .Duplicate
			editor_action_set(p, .Duplicate, row.profile, "")
			return .Profile_Action
		case row.kind == .Profile &&
		     row.profile != settings.PROFILE_DEFAULT_ID &&
		     contains(table.remove, x, y):
			p.focus, p.profile_control = .Control, .Remove
			editor_profile_remove_ask(p, row.profile)
			return .Changed
		case row.kind == .Detected && contains(table.enable, x, y):
			p.focus, p.profile_control = .Control, .Enable
			editor_action_set(p, .Enable, row.profile, "")
			return .Profile_Action
		case row.kind == .Detected_Header:
			editor_detected_toggle(p)
			return .Changed
		case row.kind == .Profile_Add:
			return .Save
		case row.kind == .Profile:
			if row.profile == settings.PROFILE_DEFAULT_ID && contains(table.remove, x, y) {
				return .Changed
			}
			editor_profile_toggle(p, row.profile)
			return .Changed
		}
		return .Changed
	}
	switch {
	case contains(parts.reset, x, y):
		return .Reset
	case contains(parts.clear, x, y):
		field_set(&p.value, "")
		return .Save
	case contains(parts.toggle, x, y):
		p.focus = .Control
		return flip_toggle(p)
	case contains(parts.positions, x, y):
		p.physical = !p.physical
		return .Changed
	case contains(parts.swatch, x, y) && row.kind != .Profile_Icon:
		p.focus, p.popup = .Control, .Color
		return .Changed
	case contains(parts.slider, x, y) ||
	     contains(
		     {
			     parts.slider.x - 8 * s,
			     parts.slider.y - 10 * s,
			     parts.slider.width + 16 * s,
			     parts.slider.height + 20 * s,
		     },
		     x,
		     y,
	     ) &&
		     parts.slider.width > 0:
		p.focus, p.drag = .Control, .Slider
		slide(p, row, parts.slider, x)
		return .Changed
	case contains(parts.field, x, y):
		#partial switch row.kind {
		case .Choice:
			if p.popup == .Choice {p.popup = .None} else {open_choices(p, row)}
			return .Changed
		case .Shortcut:
			return activate(p, row)
		case .Action:
			return .Save
		}
		if p.capturing {stop_editing(p)}
		p.focus = .Control
		field_pointer(&p.value, field_box_offset(value_box(p, parts, text, s), x), true, extend)
		p.drag = .Value
		return .Changed
	}
	if p.capturing {
		stop_editing(p)
		editor_message(p, "", false)
	}
	return .Changed
}

// Continues a pointer drag; returns whether anything changed.
editor_drag :: proc(p: ^Editor, l: Editor_Layout, text: ^Text, x, y: f32) -> bool {
	row := editor_row(p)
	if row == nil && p.drag != .Filter {return false}
	switch p.drag {
	case .None:
		return false
	case .Filter:
		return(
			field_pointer(
				&p.filter,
				field_box_offset(filter_box(p, l, text), x),
				false,
				true,
			) !=
			.None \
		)
	case .Value:
		parts := editor_row_parts(p, l, p.selected)
		return(
			field_pointer(
				&p.value,
				field_box_offset(value_box(p, parts, text, l.scale), x),
				false,
				true,
			) !=
			.None \
		)
	case .Slider:
		slide(p, row, editor_row_parts(p, l, p.selected).slider, x)
	case .Profile_Order:
		index := clamp(p.scroll + int((y - l.list.y) / l.row_height), 0, len(p.items))
		slot := 0
		for item, i in p.items {
			if i >= index {break}
			if item.row >= 0 && p.rows[item.row].kind == .Profile {slot += 1}
		}
		if index < len(p.items) && p.items[index].row >= 0 {
			target := p.rows[p.items[index].row]
			if target.kind == .Profile {
				top := l.list.y + f32(index - p.scroll) * l.row_height
				if y >= top + l.row_height / 2 {slot += 1}
			}
		} else if index >= len(p.items) {
			slot = profile_row_count(p)
		}
		slot = clamp(slot, 0, profile_row_count(p))
		if slot != p.drag_target {
			p.drag_target = slot
			return true
		}
		return false
	case .Wheel, .Ramp:
		pick_color(
			p,
			color_parts(editor_popup_rect(p, l), row.kind == .Optional_Color, l.scale),
			x,
			y,
		)
	}
	return true
}

// Ends a pointer drag; a slider drag saves the value it settled on and a color drag previews until
// the picker closes or Enter saves. Dropping a profile row names its ID and insertion slot.
editor_release :: proc(p: ^Editor) -> Editor_Outcome {
	drag := p.drag
	p.drag = .None
	p.filter.dragging, p.value.dragging = false, false
	if drag == .Profile_Order {
		defer {
			delete(p.drag_id)
			p.drag_id = ""
		}
		if p.drag_target == p.drag_from {return .Changed}
		editor_action_set(p, .Order, p.drag_id, "")
		p.action_slot = p.drag_target
		return .Profile_Action
	}
	row := editor_row(p)
	if row == nil || (drag != .Slider && drag != .Wheel && drag != .Ramp) {return .None}
	return field_string(&p.value) == row.value ? .Changed : .Save
}

// Hover state for row highlights and reset buttons; returns whether the page must redraw.
editor_hover :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> bool {
	// An open dropdown highlights the option under the pointer, like the menus.
	if p.popup != .None {
		if row := editor_row(p); row != nil {
			popup := editor_popup_rect(p, l)
			visible := int((y - popup.y - 4 * l.scale) / (CHOICE_HEIGHT * l.scale))
			option := render.Rect {
				popup.x + 4 * l.scale,
				popup.y + 4 * l.scale + f32(visible) * CHOICE_HEIGHT * l.scale,
				popup.width - 8 * l.scale,
				CHOICE_HEIGHT * l.scale,
			}
			if contains(popup, x, y) && visible >= 0 && contains(option, x, y) {
				index, valid := visible, false
				#partial switch p.popup {
				case .Choice:
					valid = index < len(row.choices)
				case .Shortcuts:
					index += p.popup_scroll
					count := len(commands.shortcut_alternatives(row.value, context.temp_allocator))
					valid = index <= count
				case .Color, .None:
				}
				if valid && index != p.popup_index {
					p.popup_index = index
					return true
				}
			}
		}
	}
	item, reset, outline := -1, -1, -1
	profile_item, profile_control := -1, Profile_Control.Radio
	if p.popup == .None && contains(l.list, x, y) {
		index := p.scroll + int((y - l.list.y) / l.row_height)
		if index < len(p.items) && p.items[index].row >= 0 {
			item = index
			parts := editor_row_parts(p, l, index)
			if contains(parts.reset, x, y) {reset = index}
			row := &p.rows[p.items[index].row]
			if row.kind == .Profile || row.kind == .Detected {
				table := profile_row_parts(row.kind, parts.row, l.scale)
				profile_item = index
				switch {
				case contains(table.radio, x, y):
					profile_control = .Radio
				case contains(table.toggle, x, y):
					profile_control = .Hidden
				case contains(table.expand, x, y):
					profile_control = .Expand
				case contains(table.duplicate, x, y):
					profile_control = .Duplicate
				case row.profile != settings.PROFILE_DEFAULT_ID && contains(table.remove, x, y):
					profile_control = .Remove
				case contains(table.enable, x, y):
					profile_control = .Enable
				case:
					profile_item = -1
				}
			}
		}
	}
	if p.popup == .None && contains(l.outline, x, y) {
		entry := p.outline_scroll + int((y - l.outline.y) / l.outline_row_height)
		if entry < len(outline_entries(p)) {outline = entry}
	}
	clear := contains(editor_clear_rect(p, l), x, y)
	if item == p.hover_item &&
	   reset == p.hover_reset &&
	   outline == p.hover_outline &&
	   clear == p.hover_clear &&
	   profile_item == p.hover_profile_item &&
	   profile_control == p.hover_profile_control {
		return false
	}
	p.hover_item, p.hover_reset, p.hover_outline, p.hover_clear = item, reset, outline, clear
	p.hover_profile_item, p.hover_profile_control = profile_item, profile_control
	return true
}

editor_hover_clear :: proc(p: ^Editor) {
	p.hover_item, p.hover_reset, p.hover_outline, p.hover_clear = -1, -1, -1, false
	p.hover_profile_item, p.hover_profile_control = -1, .Radio
}

// Whether the pointer is over editable text, which shows a text cursor.
editor_over_text :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> bool {
	if contains(editor_popup_rect(p, l), x, y) {return false}
	if contains(filter_text_rect(p, l), x, y) {return true}
	if !contains(l.list, x, y) {return false}
	index := p.scroll + int((y - l.list.y) / l.row_height)
	if index >= len(p.items) || p.items[index].row < 0 {return false}
	kind := p.rows[p.items[index].row].kind
	return text_kind(kind) && contains(editor_row_parts(p, l, index).field, x, y)
}

// The pointer for the page: text over editable text, a hand over anything a click changes.
editor_pointer :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> platform.Cursor_Shape {
	s := l.scale
	if popup := editor_popup_rect(p, l); contains(popup, x, y) {
		row := editor_row(p)
		if row == nil {return .Arrow}
		option := int((y - popup.y - 4 * s) / (CHOICE_HEIGHT * s))
		#partial switch p.popup {
		case .Choice:
			if option >= 0 && option < len(row.choices) {return .Hand}
		case .Shortcuts:
			count := len(commands.shortcut_alternatives(row.value, context.temp_allocator))
			if option >= 0 && option + p.popup_scroll <= count {return .Hand}
		case .Color:
			c := color_parts(popup, row.kind == .Optional_Color, s)
			ramp := render.Rect{c.ramp.x, c.ramp.y - 6 * s, c.ramp.width, c.ramp.height + 12 * s}
			if contains(c.wheel, x, y) || contains(ramp, x, y) || contains(c.no_color, x, y) {
				return .Hand
			}
		}
		return .Arrow
	}
	if contains(editor_clear_rect(p, l), x, y) {return .Hand}
	if contains(filter_text_rect(p, l), x, y) {return .Text}
	if contains(l.outline, x, y) {
		entry := p.outline_scroll + int((y - l.outline.y) / l.outline_row_height)
		return entry < len(outline_entries(p)) ? .Hand : .Arrow
	}
	if !contains(l.list, x, y) {return .Arrow}
	index := p.scroll + int((y - l.list.y) / l.row_height)
	if index >= len(p.items) || p.items[index].row < 0 {return .Arrow}
	row := &p.rows[p.items[index].row]
	parts := editor_row_parts(p, l, index)
	#partial switch row.kind {
	case .Profile, .Detected_Header, .Profile_Add:
		return .Hand
	case .Detected:
		return contains(profile_row_parts(row.kind, parts.row, s).enable, x, y) ? .Hand : .Arrow
	}
	slider := render.Rect {
		parts.slider.x - 8 * s,
		parts.slider.y - 10 * s,
		parts.slider.width + 16 * s,
		parts.slider.height + 20 * s,
	}
	switch {
	case contains(parts.reset, x, y),
	     contains(parts.clear, x, y),
	     contains(parts.toggle, x, y),
	     contains(parts.positions, x, y),
	     contains(parts.swatch, x, y) && row.kind != .Profile_Icon,
	     parts.slider.width > 0 && contains(slider, x, y):
		return .Hand
	case contains(parts.field, x, y):
		#partial switch row.kind {
		case .Choice, .Shortcut, .Action:
			return .Hand
		}
		return .Text
	}
	return .Arrow
}

@(private)
row_preview :: proc(row: ^Editor_Row, value: string) -> string {
	#partial switch row.kind {
	case .Optional_Color:
		if value == "" {return "None"}
	case .Shortcut:
		if value == "" {return "None"}
	}
	return value
}

@(private)
switch_draw :: proc(
	list: ^render.Draw_List,
	track: render.Rect,
	on, focused: bool,
	theme: Theme,
	scale: f32,
) {
	draw_rect(
		list,
		{rect = track, color = on ? theme.accent : theme.border, radius = track.height / 2},
	)
	knob := track.height - 6 * scale
	knob_x := on ? track.x + track.width - 3 * scale - knob : track.x + 3 * scale
	draw_rect(
		list,
		{
			rect = {knob_x, track.y + 3 * scale, knob, knob},
			color = on ? theme.accent_text : theme.text,
			radius = knob / 2,
		},
	)
	if focused {focus_ring_draw(list, track, theme, scale)}
}

@(private)
box_draw :: proc(
	list: ^render.Draw_List,
	r: render.Rect,
	theme: Theme,
	focused: bool,
	scale: f32,
) {
	draw_rect(list, {rect = r, color = theme.border, radius = 6 * scale})
	if focused {focus_ring_draw(list, r, theme, scale)}
}

// The square text badge a pane header and the profile table use for a shell.
@(private)
profile_badge_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	badge: string,
	rect: render.Rect,
	theme: Theme,
	scale: f32,
	muted: bool,
) {
	if rect.width <= 0 {return}
	draw_rect(list, {rect = rect, color = theme.surface, radius = 6 * scale})
	draw_rect(list, {rect = rect, color = theme.border, radius = 6 * scale, stroke = scale})
	small := text_styled(text, .Small)
	width := min(rect.width - 4 * scale, text_width(&small, badge))
	draw_text(
		&small,
		list,
		badge,
		rect.x + (rect.width - width) / 2,
		rect.y + (rect.height - small.line_height) / 2 + small.ascent,
		muted ? theme.muted : theme.text,
		width,
	)
}

// A 22px radio dot with a pointer and keyboard focus state.
@(private)
profile_radio_draw :: proc(
	list: ^render.Draw_List,
	rect: render.Rect,
	on, focused, hovered: bool,
	theme: Theme,
	scale: f32,
) {
	if rect.width <= 0 {return}
	if hovered {
		hover := render.Rect {
			rect.x - 4 * scale,
			rect.y - 4 * scale,
			rect.width + 8 * scale,
			rect.height + 8 * scale,
		}
		draw_rect(list, {rect = hover, color = theme.hover, radius = hover.width / 2})
	}
	dot := render.Rect {
		rect.x + rect.width / 2 - 8 * scale,
		rect.y + rect.height / 2 - 8 * scale,
		16 * scale,
		16 * scale,
	}
	draw_rect(list, {rect = dot, color = on ? theme.accent : theme.border, radius = 8 * scale})
	draw_rect(list, {rect = dot, color = theme.border, radius = 8 * scale, stroke = scale})
	if on {
		inner := render.Rect{dot.x + 4 * scale, dot.y + 4 * scale, 8 * scale, 8 * scale}
		draw_rect(list, {rect = inner, color = theme.accent_text, radius = 4 * scale})
	}
	if focused {focus_ring_draw(list, dot, theme, scale)}
}

// A small icon button inside a table row.
@(private)
profile_button_draw :: proc(
	list: ^render.Draw_List,
	rect: render.Rect,
	icon: Icon,
	size: f32,
	theme: Theme,
	scale: f32,
	focused, hovered, enabled: bool,
) {
	if rect.width <= 0 {return}
	if enabled && (hovered || focused) {
		draw_rect(
			list,
			{rect = rect, color = hovered ? theme.hover : theme.selection, radius = 5 * scale},
		)
	}
	color := enabled ? theme.muted : theme.faint
	if hovered || focused {color = theme.text}
	if focused {focus_ring_draw(list, rect, theme, scale)}
	icon_draw(list, icon, rect, color, size, scale)
}

@(private)
profile_row_draw :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	parts: Row_Parts,
	index: int,
	selected: bool,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	scale: f32,
) -> glyphs.Result {
	table := profile_row_parts(.Profile, parts.row, scale)
	small := text_styled(text, .Small)
	cy := parts.row.y + parts.row.height / 2
	focused := selected && p.focus == .Control
	hovered := index == p.hover_profile_item
	strong := (selected || index == p.hover_item) && !(.Hidden in row.flags)
	grip_ink := selected || index == p.hover_item ? theme.muted : theme.faint
	icon_draw(list, .Grip, table.handle, grip_ink, ICON_BUTTON, scale)
	badge := render.Rect {table.icon.x, cy - 13 * scale, 26 * scale, 26 * scale}
	profile_badge_draw(list, text, row.badge, badge, theme, scale, .Hidden in row.flags)
	name_color := strong ? theme.text : theme.muted
	if .Hidden in row.flags {name_color = theme.muted}
	name_baseline := parts.row.y + 21 * scale
	if row.note == "" {name_baseline = cy - text.line_height / 2 + text.ascent}
	if result := draw_text(
		text,
		list,
		row.title,
		table.name.x,
		name_baseline,
		name_color,
		max(1, table.name.width),
	); result != .Ok {return result}
	if row.note != "" {
		if result := draw_text(
			&small,
			list,
			row.note,
			table.name.x,
			parts.row.y + 39 * scale,
			theme.error,
			max(1, table.name.width),
		); result != .Ok {return result}
	}
	if result := draw_fading_text(
		&small,
		list,
		row.description,
		table.command.x,
		cy - small.line_height / 2 + small.ascent,
		theme.muted,
		max(1, table.command.width),
	); result != .Ok {return result}
	if table.directory.width > 0 {
		if result := draw_fading_text(
			&small,
			list,
			row.value,
			table.directory.x,
			cy - small.line_height / 2 + small.ascent,
			theme.faint,
			max(1, table.directory.width),
		); result != .Ok {return result}
	}
	radio_focus := focused && p.profile_control == .Radio
	profile_radio_draw(
		list,
		table.radio,
		.Default in row.flags,
		radio_focus,
		hovered && p.hover_profile_control == .Radio,
		theme,
		scale,
	)
	switch_draw(
		list,
		table.toggle,
		.Hidden in row.flags,
		focused && p.profile_control == .Hidden,
		theme,
		scale,
	)
	if table.expand.width > 0 {
		controls := [?]struct {
			rect: render.Rect,
			icon: Icon,
			size: f32,
			kind: Profile_Control,
		} {
			{table.expand, p.expanded == row.profile ? .Chevron_Down : .Chevron_Right, ICON_INDICATOR, .Expand},
			{table.duplicate, .Copy, ICON_BUTTON, .Duplicate},
			{table.remove, .Trash, ICON_BUTTON, .Remove},
		}
		for control in controls {
			enabled := !(control.kind == .Remove && row.profile == settings.PROFILE_DEFAULT_ID)
			profile_button_draw(
				list,
				control.rect,
				control.icon,
				control.size,
				theme,
				scale,
				enabled && focused && p.profile_control == control.kind,
				enabled && hovered && p.hover_profile_control == control.kind,
				enabled,
			)
		}
	}
	if p.error_profile != "" && p.error_profile == row.profile {
		draw_rect(list, {rect = parts.row, color = theme.error, radius = 6 * scale, stroke = scale})
	}
	return .Ok
}

// Column captions for the profile table's group header line.
@(private)
profile_columns_draw :: proc(
	row: render.Rect,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	scale: f32,
) -> glyphs.Result {
	label := text_styled(text, .Label)
	columns := profile_columns(row, scale)
	baseline := row.y + row.height - 12 * scale
	captions := [?]struct {
		rect: render.Rect,
		name: string,
	} {
		{columns.name, "Profile"},
		{columns.command, "Command line"},
		{columns.directory, "Directory"},
		{columns.default, "Default"},
		{columns.hidden, "Hidden"},
	}
	for caption in captions {
		if caption.rect.width < 34 * scale {continue}
		if result := draw_text(
			&label,
			list,
			caption.name,
			caption.rect.x,
			baseline,
			theme.faint,
			caption.rect.width,
		); result != .Ok {return result}
	}
	return .Ok
}

// The Add Profile row closes the main table.
@(private)
profile_add_draw :: proc(
	row: ^Editor_Row,
	row_rect: render.Rect,
	selected: bool,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	scale: f32,
) -> glyphs.Result {
	small := text_styled(text, .Small)
	icon := render.Rect {
		row_rect.x + 12 * scale,
		row_rect.y + row_rect.height / 2 - 9 * scale,
		18 * scale,
		18 * scale,
	}
	icon_draw(list, .Add, icon, theme.muted, ICON_INDICATOR, scale)
	color := selected ? theme.text : theme.muted
	return draw_text(
		&small,
		list,
		row.title,
		icon.x + icon.width + 8 * scale,
		row_rect.y + (row_rect.height - small.line_height) / 2 + small.ascent,
		color,
		max(1, row_rect.width - 60 * scale),
	)
}

// The collapsed section that holds shells detection found but the file has not enabled.
@(private)
profile_detected_header_draw :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	parts: Row_Parts,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	scale: f32,
) -> glyphs.Result {
	draw_rect(
		list,
		{
			rect = {
				parts.row.x + 10 * scale,
				parts.row.y + 10 * scale,
				parts.row.width - 20 * scale,
				scale,
			},
			color = theme.border,
		},
	)
	chevron := profile_row_parts(.Detected_Header, parts.row, scale).chevron
	chevron_icon: Icon = p.detected_open ? .Chevron_Down : .Chevron_Right
	icon_draw(list, chevron_icon, chevron, theme.muted, ICON_INDICATOR, scale)
	small := text_styled(text, .Small)
	if result := draw_text(
		&small,
		list,
		row.title,
		chevron.x + chevron.width + 4 * scale,
		parts.row.y + (parts.row.height - small.line_height) / 2 + small.ascent,
		theme.muted,
		max(1, parts.row.width * 0.55),
	); result != .Ok {return result}
	count := fmt.tprintf("%s not enabled", row.value)
	return draw_text(
		&small,
		list,
		count,
		parts.row.x + parts.row.width - 14 * scale - text_width(&small, count),
		parts.row.y + (parts.row.height - small.line_height) / 2 + small.ascent,
		theme.faint,
	)
}

// One detected-but-not-enabled profile: identity, command, Enable, and a radio when it is the
// configured default.
@(private)
profile_detected_draw :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	parts: Row_Parts,
	index: int,
	selected: bool,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	scale: f32,
) -> glyphs.Result {
	table := profile_row_parts(.Detected, parts.row, scale)
	small := text_styled(text, .Small)
	cy := parts.row.y + parts.row.height / 2
	profile_badge_draw(list, text, row.badge, table.icon, theme, scale, true)
	if result := draw_text(
		text,
		list,
		row.title,
		table.name.x,
		cy - text.line_height / 2 + text.ascent,
		theme.muted,
		max(1, table.name.width),
	); result != .Ok {return result}
	if result := draw_fading_text(
		&small,
		list,
		row.description,
		table.command.x,
		cy - small.line_height / 2 + small.ascent,
		theme.faint,
		max(1, table.command.width),
	); result != .Ok {return result}
	focused := selected && p.focus == .Control
	hovered := index == p.hover_profile_item
	// A detected profile the file already names as default reads as default here even though its
	// radio is not a write target until the profile is enabled.
	if .Default in row.flags {
		profile_radio_draw(list, table.radio, true, false, false, theme, scale)
	}
	if hovered && p.hover_profile_control == .Enable {
		draw_rect(list, {rect = table.enable, color = theme.hover, radius = 6 * scale})
	}
	box_draw(list, table.enable, theme, focused && p.profile_control == .Enable, scale)
	label := "Enable"
	return draw_text(
		&small,
		list,
		label,
		table.enable.x + (table.enable.width - text_width(&small, label)) / 2,
		table.enable.y + (table.enable.height - small.line_height) / 2 + small.ascent,
		theme.text,
	)
}

// Draws a control's resting value, or for the selected row its pending value and focus.
@(private)
control_draw :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	parts: Row_Parts,
	selected: bool,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	page: render.Rect,
	scale: f32,
) -> glyphs.Result {
	value := selected ? field_string(&p.value) : row.value
	focused := selected && p.focus == .Control
	input_text := text_styled(text, .Input)
	baseline :=
		parts.field.y + (parts.field.height - input_text.line_height) / 2 + input_text.ascent
	switch row.kind {
	case .Action:
		box_draw(list, parts.field, theme, focused, scale)
		return draw_text(
			&input_text,
			list,
			value,
			parts.field.x + 10 * scale,
			baseline,
			theme.text,
			max(1, parts.field.width - 20 * scale),
		)
	case .Toggle:
		on := value == "true"
		switch_draw(list, parts.toggle, on, focused, theme, scale)
		label := on ? "On" : "Off"
		return draw_text(
			text,
			list,
			label,
			parts.toggle.x - 12 * scale - text_width(text, label),
			parts.toggle.y + (parts.toggle.height - text.line_height) / 2 + text.ascent,
			theme.muted,
		)
	case .Choice:
		box_draw(list, parts.field, theme, focused, scale)
		if r := draw_text(
			&input_text,
			list,
			choice_label(row, value),
			parts.field.x + 10 * scale,
			baseline,
			theme.text,
			max(1, parts.field.width - 40 * scale),
		); r != .Ok {return r}
		chevron := render.Rect {
			parts.field.x + parts.field.width - 30 * scale,
			parts.field.y,
			24 * scale,
			parts.field.height,
		}
		icon_draw(list, .Chevron_Down, chevron, theme.muted, ICON_INDICATOR, scale)
		return .Ok
	case .Integer, .Number:
		number, ok := strconv.parse_f64(value)
		if !ok {number, _ = strconv.parse_f64(row.value)}
		fraction := slider_fraction(row, number)
		track := parts.slider
		groove := render.Rect{track.x, track.y + 4 * scale, track.width, 4 * scale}
		draw_rect(list, {rect = groove, color = theme.border, radius = 2 * scale})
		groove.width *= fraction
		draw_rect(list, {rect = groove, color = theme.accent, radius = 2 * scale})
		thumb := render.Rect {
			track.x + track.width * fraction - 7 * scale,
			track.y - 1 * scale,
			14 * scale,
			14 * scale,
		}
		draw_rect(list, {rect = thumb, color = theme.accent, radius = 7 * scale})
		draw_rect(
			list,
			{rect = thumb, color = theme.surface, radius = 7 * scale, stroke = 2 * scale},
		)
	case .Color, .Optional_Color:
		if c, ok := swatch_color(value); ok {
			draw_rect(list, {rect = parts.swatch, color = c, radius = 6 * scale})
		}
		draw_rect(
			list,
			{rect = parts.swatch, color = theme.border, radius = 6 * scale, stroke = scale},
		)
		if selected && p.popup == .Color {focus_ring_draw(list, parts.swatch, theme, scale)}
	case .Text, .Shortcut:
	case .Profile_Icon:
		profile_badge_draw(list, text, row.badge, parts.swatch, theme, scale, false)
	case .Profile, .Profile_Add, .Detected_Header, .Detected:
		return .Ok
	}
	if selected {
		placeholder := row.kind == .Optional_Color ? "None" : "Empty"
		if row.kind == .Shortcut {placeholder = p.capturing ? "Press keys…" : "None"}
		field_focused := focused && !p.capturing && row.kind != .Shortcut
		box := value_box(p, parts, text, scale)
		box_draw(list, parts.field, theme, field_focused, scale)
		if r := field_box_draw(box, list, theme, field_box_baseline(box), field_focused, placeholder);
		   r != .Ok {
			return r
		}
		if p.capturing {
			draw_rect(
				list,
				{rect = parts.field, color = theme.accent, radius = 6 * scale, stroke = 2 * scale},
			)
		}
		if parts.positions.width > 0 {
			if render.push_layer(list, page) != .None {return .Ok}
			switch_draw(list, parts.positions, p.physical, p.focus == .Positions, theme, scale)
			small := text_styled(text, .Small)
			label := "Key positions"
			if parts.positions_label_below {
				return draw_text(
					&small,
					list,
					label,
					parts.positions.x + (parts.positions.width - text_width(&small, label)) / 2,
					parts.positions.y + parts.positions.height + 2 * scale + small.ascent,
					theme.muted,
				)
			}
			return draw_text(
				&small,
				list,
				label,
				parts.positions.x + parts.positions.width + 8 * scale,
				parts.positions.y +
				(parts.positions.height - small.line_height) / 2 +
				small.ascent,
				theme.muted,
			)
		}
		return .Ok
	}
	box_draw(list, parts.field, theme, false, scale)
	shown := row_preview(row, value)
	color := row.value == "" ? theme.muted : theme.text
	return draw_text(
		&input_text,
		list,
		shown,
		parts.field.x + 10 * scale,
		baseline,
		color,
		max(1, parts.field.width - 20 * scale),
	)
}

@(private)
popup_draw :: proc(
	p: ^Editor,
	l: Editor_Layout,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	pointer: [2]f32 = {},
) -> glyphs.Result {
	r := editor_popup_rect(p, l)
	row := editor_row(p)
	if r.width == 0 || row == nil {return .Ok}
	s := l.scale
	if render.push_layer(list, l.page) != .None {return .Ok}
	frame := Panel {
		rect     = r,
		radius   = 8 * s,
		scale    = s,
		shadow_y = 6,
		softness = 16,
		border   = .Stroked,
	}
	if panel_draw(list, frame, theme) != .None {return .Ok}
	if p.popup == .Shortcuts {
		parts := commands.shortcut_alternatives(row.value, context.temp_allocator)
		count := shortcut_popup_rows(p, l)
		p.popup_scroll = clamp(p.popup_scroll, max(0, p.popup_index - count + 1), p.popup_index)
		for visible in 0 ..< count {
			i := p.popup_scroll + visible
			if i > len(parts) {break}
			option := render.Rect {
				r.x + 4 * s,
				r.y + 4 * s + f32(visible) * CHOICE_HEIGHT * s,
				r.width - 8 * s,
				CHOICE_HEIGHT * s,
			}
			if i ==
			   p.popup_index {draw_rect(list, {rect = option, color = theme.selection, radius = 5 * s})}
			if contains(option, pointer.x, pointer.y) {
				// Options carry the selection tint, not the paper fill, so no hairline.
				if result := hover_rim_draw(list, theme, option, 5 * s, 1, s, pointer, false);
				   result != .None {return .Ok}
			}
			label := i < len(parts) ? parts[i] : "+ Add shortcut"
			if result := draw_text(
				text,
				list,
				label,
				option.x + 10 * s,
				option.y + (option.height - text.line_height) / 2 + text.ascent,
				theme.text,
				option.width - 44 * s,
			); result != .Ok {return result}
			if i < len(parts) {
				remove := render.Rect {
					option.x + option.width - 28 * s,
					option.y,
					28 * s,
					option.height,
				}
				icon_draw(list, .Close, remove, theme.muted, ICON_INDICATOR, s)
			}
		}
		return .Ok
	}
	if p.popup == .Choice {
		for name, i in row.choices {
			option := render.Rect {
				r.x + 4 * s,
				r.y + 4 * s + f32(i) * CHOICE_HEIGHT * s,
				r.width - 8 * s,
				CHOICE_HEIGHT * s,
			}
			if i ==
			   p.popup_index {draw_rect(list, {rect = option, color = theme.selection, radius = 5 * s})}
			if contains(option, pointer.x, pointer.y) {
				// Options carry the selection tint, not the paper fill, so no hairline.
				if result := hover_rim_draw(list, theme, option, 5 * s, 1, s, pointer, false);
				   result != .None {return .Ok}
			}
			if name == field_string(&p.value) {
				draw_rect(
					list,
					{
						rect = {option.x, option.y + 8 * s, 3 * s, option.height - 16 * s},
						color = theme.accent,
						radius = 2 * s,
					},
				)
			}
			if result := draw_text(
				text,
				list,
				choice_label(row, name),
				option.x + 12 * s,
				option.y + (option.height - text.line_height) / 2 + text.ascent,
				theme.text,
			); result != .Ok {return result}
		}
		return .Ok
	}
	c := color_parts(r, row.kind == .Optional_Color, s)
	wheel := c.wheel
	draw_rect(
		list,
		{
			rect = wheel,
			color = {p.hsv[2], 0, 0, 1},
			radius = wheel.width / 2,
			fill = render.RECT_FILL_HUE_WHEEL,
		},
	)
	draw_rect(list, {rect = wheel, color = theme.border, radius = wheel.width / 2, stroke = s})
	angle := math.to_radians(p.hsv[0])
	reach := wheel.width / 2 * p.hsv[1]
	mx := wheel.x + wheel.width / 2 + math.cos(angle) * reach
	my := wheel.y + wheel.height / 2 + math.sin(angle) * reach
	draw_rect(
		list,
		{
			rect = {mx - 7 * s, my - 7 * s, 14 * s, 14 * s},
			color = {0, 0, 0, 0.6},
			radius = 7 * s,
			stroke = s,
		},
	)
	draw_rect(
		list,
		{
			rect = {mx - 6 * s, my - 6 * s, 12 * s, 12 * s},
			color = {1, 1, 1, 1},
			radius = 6 * s,
			stroke = 2 * s,
		},
	)
	full := colour.rgba(settings.hsv_to_rgb(p.hsv[0], p.hsv[1], 1))
	draw_rect(
		list,
		{rect = c.ramp, color = full, radius = 4 * s, fill = render.RECT_FILL_VALUE_RAMP},
	)
	draw_rect(list, {rect = c.ramp, color = theme.border, radius = 4 * s, stroke = s})
	marker := c.ramp.x + c.ramp.width * p.hsv[2]
	draw_rect(
		list,
		{
			rect = {marker - 3 * s, c.ramp.y - 3 * s, 6 * s, c.ramp.height + 6 * s},
			color = {1, 1, 1, 1},
			radius = 3 * s,
			stroke = 2 * s,
		},
	)
	if color, ok := swatch_color(field_string(&p.value)); ok {
		draw_rect(list, {rect = c.swatch, color = color, radius = 6 * s})
	}
	draw_rect(list, {rect = c.swatch, color = theme.border, radius = 6 * s, stroke = s})
	small := text_styled(text, .Small)
	if result := draw_text(
		&small,
		list,
		"Enter saves, Esc closes",
		c.swatch.x,
		c.swatch.y + c.swatch.height + 22 * s,
		theme.muted,
		c.swatch.width,
	); result != .Ok {return result}
	if c.no_color.width == 0 {return .Ok}
	box_draw(list, c.no_color, theme, false, s)
	return draw_text(
		text,
		list,
		"No color",
		c.no_color.x + 10 * s,
		c.no_color.y + (c.no_color.height - text.line_height) / 2 + text.ascent,
		theme.text,
		c.no_color.width - 20 * s,
	)
}

@(private)
filter_draw :: proc(
	p: ^Editor,
	l: Editor_Layout,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	focused: bool,
	pointer: [2]f32 = {},
) -> glyphs.Result {
	s := l.scale
	box := filter_box(p, l, text)
	box_draw(list, l.filter, theme, focused, s)
	placeholder :=
		l.outline.width > 0 ? "Search settings" : "Search settings, groups, and shortcuts"
	if result := field_box_draw(box, list, theme, field_box_baseline(box), focused, placeholder);
	   result != .Ok {
		return result
	}
	clear := editor_clear_rect(p, l)
	if clear.width == 0 {return .Ok}
	if render.push_layer(list, l.page) != .None {return .Ok}
	if p.hover_clear {
		draw_rect(list, {rect = clear, color = theme.hover, radius = 5 * s})
		if result := hover_rim_draw(list, theme, clear, 5 * s, 1, s, pointer);
		   result != .None {return .Ok}
	}
	icon_draw(list, .Close, clear, p.hover_clear ? theme.text : theme.muted, ICON_INDICATOR, s)
	return .Ok
}

@(private)
outline_draw :: proc(
	p: ^Editor,
	l: Editor_Layout,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	pointer: [2]f32 = {},
) -> glyphs.Result {
	if l.outline.width == 0 {return .Ok}
	s := l.scale
	entries := outline_entries(p)
	rows := outline_rows(l)
	active := editor_active_group(p)
	if active != p.outline_active {
		for header, entry in entries {
			if p.items[header].group != active {continue}
			if entry < p.outline_scroll {p.outline_scroll = entry}
			if entry >= p.outline_scroll + rows {p.outline_scroll = entry - rows + 1}
		}
		p.outline_active = active
	}
	p.outline_scroll = clamp(p.outline_scroll, 0, max(0, len(entries) - rows))
	if render.push_layer(list, l.outline) != .None {return .Ok}
	small := text_styled(text, .Small)
	for entry in p.outline_scroll ..< min(len(entries), p.outline_scroll + rows) {
		item := p.items[entries[entry]]
		r := render.Rect {
			l.outline.x,
			l.outline.y + f32(entry - p.outline_scroll) * l.outline_row_height,
			l.outline.width,
			l.outline_row_height,
		}
		current := item.group == active
		if current {
			draw_rect(list, {rect = r, color = theme.selection, radius = 6 * s})
			draw_rect(
				list,
				{
					rect = {r.x, r.y + 8 * s, 3 * s, r.height - 16 * s},
					color = theme.accent,
					radius = 2 * s,
				},
			)
		} else if entry == p.hover_outline {
			draw_rect(list, {rect = r, color = theme.hover, radius = 6 * s})
		}
		if entry == p.hover_outline {
			// The current group keeps its accent bar; the hairline would ink it.
			if result := hover_rim_draw(list, theme, r, 6 * s, 1, s, pointer, !current);
			   result != .None {return .Ok}
		}
		baseline := r.y + (r.height - text.line_height) / 2 + text.ascent
		label := fmt.tprintf("%d", item.count)
		label_width := text_width(&small, label)
		if result := draw_text(
			text,
			list,
			p.groups[item.group].title,
			r.x + 14 * s,
			baseline,
			current ? theme.text : theme.muted,
			max(1, r.width - label_width - 34 * s),
		); result != .Ok {return result}
		if result := draw_text(
			&small,
			list,
			label,
			r.x + r.width - 10 * s - label_width,
			baseline,
			theme.faint,
		); result != .Ok {return result}
	}
	return .Ok
}

editor_draw :: proc(
	p: ^Editor,
	l: Editor_Layout,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	focused: bool,
	pointer: [2]f32 = {},
) -> glyphs.Result {
	s := l.scale
	p.visible_rows = l.rows
	p.scroll = clamp(p.scroll, 0, max_scroll(p))
	if render.push_layer(list, l.page) != .None {return .Ok}
	strong := text_styled(text, .Strong)
	small := text_styled(text, .Small)
	heading := strong
	text_set_size(&heading, strong.size_px * 1.4)
	x := l.filter.x
	if r := draw_text(&heading, list, "Settings", x, l.page.y + 36 * s, theme.text);
	   r != .Ok {return r}
	status := p.message
	matches := 0
	for item in p.items {matches += item.count}
	if status == "" {
		status = fmt.tprintf(
			"%d settings and shortcuts · Alt+↑/↓ groups · Esc clears search",
			matches,
		)
	}
	status_x := x + text_width(&heading, "Settings") + 16 * s
	status_right := l.filter.x + l.filter.width
	if l.outline.width > 0 {status_x, status_right = l.status_x, l.list.x + l.list.width}
	if r := draw_text(
		&small,
		list,
		status,
		status_x,
		l.page.y + 36 * s,
		p.error ? theme.error : theme.muted,
		max(1, status_right - status_x),
	); r != .Ok {return r}
	if r := filter_draw(p, l, list, text, theme, focused && p.focus == .Search, pointer);
	   r != .Ok {return r}
	if r := outline_draw(p, l, list, text, theme, pointer); r != .Ok {return r}
	if len(p.items) == 0 && filtering(p) {
		if render.push_layer(list, l.page) != .None {return .Ok}
		return draw_text(
			text,
			list,
			"No matching settings or shortcuts",
			l.list.x + 10 * s,
			l.list.y + (l.row_height - text.line_height) / 2 + text.ascent,
			theme.muted,
		)
	}
	if render.push_layer(list, l.list) != .None {return .Ok}
	for index in p.scroll ..< min(len(p.items), p.scroll + l.rows) {
		item := p.items[index]
		parts := editor_row_parts(p, l, index)
		r := parts.row
		selected := index == p.selected
		if selected {
			draw_rect(list, {rect = r, color = theme.selection, radius = 6 * s})
			if p.error && item.row >= 0 && p.rows[item.row].kind == .Shortcut {
				draw_rect(list, {rect = r, color = theme.error, radius = 6 * s, stroke = 2 * s})
			}
		} else if index == p.hover_item {
			draw_rect(list, {rect = r, color = theme.hover, radius = 6 * s})
		}
		if index == p.hover_item {
			// A row is a reading surface: it takes the pointer light but never the lift. A
			// selected row keeps its tint and any error ring, so it takes no hairline.
			if result := hover_rim_draw(list, theme, r, 6 * s, 1, s, pointer, !selected);
			   result != .None {return .Ok}
		}
		if item.row < 0 {
			baseline := r.y + r.height - 14 * s
			table_group := p.groups[item.group].table
			if table_group {baseline = r.y + 22 * s}
			if index >
			   0 {draw_rect(list, {rect = {r.x + 10 * s, r.y + 10 * s, r.width - 20 * s, s}, color = theme.border})}
			if result := draw_text(
				&strong,
				list,
				p.groups[item.group].title,
				r.x + 10 * s,
				baseline,
				theme.text,
				max(1, r.width * 0.7),
			); result != .Ok {return result}
			label := fmt.tprintf("%d", item.count)
			if result := draw_text(
				&small,
				list,
				label,
				r.x + r.width - 14 * s - text_width(&small, label),
				baseline,
				theme.faint,
			); result != .Ok {return result}
			if table_group {
				if result := profile_columns_draw(r, list, text, theme, s); result != .Ok {
					return result
				}
			}
			continue
		}
		row := &p.rows[item.row]
		if row.kind == .Profile {
			if result := profile_row_draw(p, row, parts, index, selected, list, text, theme, s);
			   result != .Ok {
				return result
			}
			continue
		}
		if row.kind == .Detected {
			if result := profile_detected_draw(
				p,
				row,
				parts,
				index,
				selected,
				list,
				text,
				theme,
				s,
			); result != .Ok {return result}
			continue
		}
		if row.kind == .Detected_Header {
			if result := profile_detected_header_draw(p, row, parts, list, text, theme, s);
			   result != .Ok {
				return result
			}
			continue
		}
		if row.kind == .Profile_Add {
			if result := profile_add_draw(row, r, selected, list, text, theme, s);
			   result != .Ok {
				return result
			}
			continue
		}
		if row.profile != "" {
			// Expanded editors carry an accent rail so they read as part of the row above.
			draw_rect(
				list,
				{
					rect = {r.x + 2 * s, r.y + 6 * s, 3 * s, r.height - 12 * s},
					color = theme.accent,
					radius = 1.5 * s,
				},
			)
		}
		text_width_limit := max(1, parts.text_right - r.x - 30 * s)
		baseline := r.y + 21 * s
		if row.description == "" {baseline = r.y + (r.height - text.line_height) / 2 + text.ascent}
		if result := draw_text(
			text,
			list,
			row.title,
			r.x + 30 * s,
			baseline,
			theme.text,
			text_width_limit,
		); result != .Ok {return result}
		note := row.note
		note_error := note != ""
		if p.error_key == row.key && p.error_text != "" {
			note, note_error = p.error_text, true
		}
		if note_error {
			if result := draw_text(
				&small,
				list,
				note,
				r.x + 30 * s,
				r.y + 39 * s,
				theme.error,
				text_width_limit,
			); result != .Ok {return result}
		} else if result := draw_text(
			&small,
			list,
			row.description,
			r.x + 30 * s,
			r.y + 39 * s,
			theme.muted,
			text_width_limit,
		); result != .Ok {return result}
		if result := control_draw(p, row, parts, selected, list, text, theme, l.list, s);
		   result != .Ok {
			return result
		}
		if row.kind == .Profile_Icon {
			if render.push_layer(list, l.list) != .None {return .Ok}
			box_draw(list, parts.clear, theme, false, s)
			label := "Clear"
			if result := draw_text(
				text,
				list,
				label,
				parts.clear.x + (parts.clear.width - text_width(text, label)) / 2,
				parts.clear.y + (parts.clear.height - text.line_height) / 2 + text.ascent,
				theme.muted,
			); result != .Ok {return result}
		}
		if p.error_key == row.key {
			draw_rect(list, {rect = r, color = theme.error, radius = 6 * s, stroke = s})
		}
		if render.push_layer(list, l.list) != .None {return .Ok}
		if row.kind == .Action {continue}
		modified := row.value != row.default_value
		if index == p.hover_reset && modified {
			if !selected {
				draw_rect(list, {rect = parts.reset, color = theme.hover, radius = 6 * s})
			}
			if result := hover_rim_draw(list, theme, parts.reset, 6 * s, 1, s, pointer, !selected);
			   result != .None {return .Ok}
		}
		icon_color := theme.faint
		if modified {
			icon_color = index == p.hover_reset ? theme.text : theme.muted
		} else {
			icon_color.a *= 0.5
		}
		icon_draw(list, .Undo, parts.reset, icon_color, ICON_BUTTON, s)
	}
	if p.drag == .Profile_Order {
		y := profile_drop_y(p, l)
		draw_rect(
			list,
			{
				rect = {l.list.x + 10 * s, y - s, l.list.width - 20 * s, 2 * s},
				color = theme.accent,
				radius = s,
			},
		)
	}
	return popup_draw(p, l, list, text, theme, pointer)
}
