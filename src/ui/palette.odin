package ui

import "aio:commands"
import "aio:fuzzy"
import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "base:runtime"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

@(private)
PALETTE_MAX_ROWS :: 8
@(private)
PALETTE_WIDTH :: 560
@(private)
PALETTE_INPUT_HEIGHT :: 64
@(private)
PALETTE_ROW_HEIGHT :: 42
@(private)
PALETTE_PADDING :: 8
@(private)
PALETTE_RADIUS :: 10
@(private)
PALETTE_TEXT_INSET :: 14

Outcome :: enum {
	None,
	Changed,
	Closed,
	Run,
	Open_Setting,
}

// A setting the palette can open in the settings editor. The strings are static schema text.
Palette_Setting :: struct {
	key, title, group: string,
}

// A command result, or a setting result when command is nil.
Palette_Result :: struct {
	command:     ^commands.Command,
	setting:     int,
	score:       f64,
	positions:   []int,
	title_match: bool,
}

Palette :: struct {
	open:             bool,
	motion:           Motion,
	query:            Text_Field,
	selected, scroll: int,
	results:          [dynamic]Palette_Result,
	positions:        [dynamic]int,
	settings:         []Palette_Setting,
	// The setting key of the last Open_Setting outcome.
	chosen:           string,
	scratch:          ^fuzzy.Scratch,
}

Palette_Layout :: struct {
	panel, input, list: render.Rect,
	row_height:         f32,
}

@(require_results)
palette_init :: proc(
	p: ^Palette,
	settings: []Palette_Setting,
	allocator := context.allocator,
) -> runtime.Allocator_Error {
	p.query.bytes = make([dynamic]u8, allocator)
	p.results = make([dynamic]Palette_Result, allocator)
	p.positions = make([dynamic]int, allocator)
	p.settings = settings
	err: runtime.Allocator_Error
	p.scratch, err = new(fuzzy.Scratch, allocator)
	return err
}

palette_destroy :: proc(p: ^Palette) {
	free(p.scratch, p.query.bytes.allocator)
	delete(p.query.bytes)
	delete(p.results)
	delete(p.positions)
	p^ = {}
}

palette_open :: proc(p: ^Palette, registry: ^commands.Registry) {
	p.open = true
	field_set(&p.query, "")
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
}

palette_close :: proc(p: ^Palette) {
	p.open = false
	p.query.dragging = false
}

palette_query :: proc(p: ^Palette) -> string {return field_string(&p.query)}

// The category a command name belongs to, such as Panes for pane.split_right.
command_category :: proc(name: string) -> string {
	dot := strings.index_byte(name, '.')
	switch dot < 0 ? name : name[:dot] {
	case "app":
		return "Application"
	case "terminal":
		return "Terminal"
	case "pane":
		return "Panes"
	case "tab":
		return "Tabs"
	case "workspace":
		return "Workspaces"
	case "window":
		return "Windows"
	case "settings":
		return "Settings"
	case "edit":
		return "Edit"
	case "view":
		return "View"
	}
	return "Commands"
}
palette_result_name :: proc(p: ^Palette, r: Palette_Result) -> string {
	return r.command != nil ? r.command.name : p.settings[r.setting].key
}

palette_result_title :: proc(p: ^Palette, r: Palette_Result) -> string {
	return r.command != nil ? r.command.title : p.settings[r.setting].title
}

// Fuzzy-matches the title and the group, keeping the entry when either matches. Title matches carry
// highlights and rank ahead of entries found only through their group.
@(private)
consider :: proc(
	p: ^Palette,
	command: ^commands.Command,
	setting: int,
	title, group, query: string,
	width: int,
) {
	by_title, title_error := fuzzy.score(query, title, p.scratch)
	by_group, group_error := fuzzy.score(query, group, p.scratch)
	if title_error != .None || group_error != .None {return}
	if !by_title.matched && !by_group.matched {return}
	result := Palette_Result {
		command = command,
		setting = setting,
		score   = by_group.score,
	}
	if by_title.matched {
		start := len(p.results) * width
		highlights := p.positions[start:start + width]
		if _, err := fuzzy.match_positions(query, title, highlights, p.scratch); err == .None {
			result.positions = highlights
		}
		result.score, result.title_match = by_title.score, true
	}
	append(&p.results, result)
}

// With an empty query, every enabled command in registry order; otherwise commands and settings whose
// title or group fuzzy-matches the query.
@(private)
refresh :: proc(p: ^Palette, registry: ^commands.Registry) {
	query := palette_query(p)
	clear(&p.results)
	if strings.trim_space(query) == "" || !utf8.valid_string(query) {
		for &command in registry.items {
			if !command.disabled {append(&p.results, Palette_Result{command = &command, setting = -1})}
		}
	} else {
		width := utf8.rune_count(query)
		resize(&p.positions, (len(registry.items) + len(p.settings)) * width)
		for &command in registry.items {
			if !command.disabled {
				consider(
					p,
					&command,
					-1,
					command.title,
					command_category(command.name),
					query,
					width,
				)
			}
		}
		for s, i in p.settings {consider(p, nil, i, s.title, s.group, query, width)}
		slice.stable_sort_by(p.results[:], proc(a, b: Palette_Result) -> bool {
			if a.title_match != b.title_match {return a.title_match}
			return a.score > b.score
		})
	}
	p.selected = clamp(p.selected, 0, max(0, len(p.results) - 1))
	keep_selection_visible(p)
}

@(private)
keep_selection_visible :: proc(p: ^Palette) {
	if p.selected < p.scroll {
		p.scroll = p.selected
	} else if p.selected >= p.scroll + PALETTE_MAX_ROWS {
		p.scroll = p.selected - PALETTE_MAX_ROWS + 1
	}
}

@(private)
move :: proc(p: ^Palette, delta: int) -> Outcome {
	if len(p.results) == 0 {
		return .None
	}
	p.selected = clamp(p.selected + delta, 0, len(p.results) - 1)
	keep_selection_visible(p)
	return .Changed
}

@(private)
run :: proc(p: ^Palette, index: int) -> (Outcome, commands.Command_Id) {
	if index < 0 || index >= len(p.results) {
		return .None, 0
	}
	result := p.results[index]
	palette_close(p)
	if result.command == nil {
		p.chosen = p.settings[result.setting].key
		return .Open_Setting, 0
	}
	return .Run, result.command.id
}

@(private)
query_changed :: proc(p: ^Palette, registry: ^commands.Registry, change: Field_Change) -> Outcome {
	switch change {
	case .None:
		return .None
	case .Moved:
		return .Changed
	case .Edited:
	}
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
	return .Changed
}

// Handles a key while the palette is open. Every key is consumed, so none reaches the terminal.
palette_key :: proc(
	p: ^Palette,
	registry: ^commands.Registry,
	e: platform.Key_Event,
) -> (
	Outcome,
	commands.Command_Id,
) {
	if !e.pressed {
		return .None, 0
	}
	shift := .Shift in e.modifiers
	if step := list_step(e); step != 0 {return move(p, step), 0}
	#partial switch e.key {
	case .Escape:
		palette_close(p)
		return .Closed, 0
	case .Enter, .Numpad_Enter:
		return run(p, p.selected)
	case .Page_Up:
		return move(p, -PALETTE_MAX_ROWS), 0
	case .Page_Down:
		return move(p, PALETTE_MAX_ROWS), 0
	case .Home:
		if !shift {return move(p, -len(p.results)), 0}
	case .End:
		if !shift {return move(p, len(p.results)), 0}
	}
	return query_changed(p, registry, field_key(&p.query, e)), 0
}

palette_text :: proc(p: ^Palette, registry: ^commands.Registry, text: string) -> Outcome {
	return query_changed(p, registry, field_text(&p.query, text))
}

// Pastes the first line of `text` over the query selection.
palette_paste :: proc(p: ^Palette, registry: ^commands.Registry, text: string) -> Outcome {
	line := text
	if end := strings.index_any(text, "\r\n"); end >= 0 {line = text[:end]}
	return palette_text(p, registry, line)
}

palette_selection :: proc(p: ^Palette) -> string {return field_selected_text(&p.query)}

palette_cut :: proc(p: ^Palette, registry: ^commands.Registry) -> Outcome {
	if palette_selection(p) == "" {return .None}
	return palette_text(p, registry, "")
}

palette_layout :: proc(p: ^Palette, width, height, scale: f32) -> Palette_Layout {
	panel_width := min(PALETTE_WIDTH * scale, width - 32 * scale)
	rows := max(1, min(len(p.results), PALETTE_MAX_ROWS))
	row_height := PALETTE_ROW_HEIGHT * scale
	padding := PALETTE_PADDING * scale
	input_height := PALETTE_INPUT_HEIGHT * scale
	panel := render.Rect {
		x      = (width - panel_width) / 2,
		y      = max(24 * scale, height * 0.12),
		width  = panel_width,
		height = input_height + 1 + 2 * padding + f32(rows) * row_height,
	}
	return {
		panel = panel,
		input = {panel.x, panel.y, panel.width, input_height},
		list = {
			panel.x + padding,
			panel.y + input_height + 1 + padding,
			panel.width - 2 * padding,
			f32(rows) * row_height,
		},
		row_height = row_height,
	}
}

@(private)
row_at :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> int {
	r := l.list
	if x < r.x || x >= r.x + r.width || y < r.y || y >= r.y + r.height {
		return -1
	}
	index := p.scroll + int((y - r.y) / l.row_height)
	return index < len(p.results) ? index : -1
}

palette_mouse_move :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> Outcome {
	index := row_at(p, l, x, y)
	if index < 0 || index == p.selected {
		return .None
	}
	p.selected = index
	return .Changed
}

palette_mouse_press :: proc(
	p: ^Palette,
	l: Palette_Layout,
	x, y: f32,
) -> (
	Outcome,
	commands.Command_Id,
) {
	if index := row_at(p, l, x, y); index >= 0 {
		return run(p, index)
	}
	r := l.panel
	if x < r.x || x >= r.x + r.width || y < r.y || y >= r.y + r.height {
		palette_close(p)
		return .Closed, 0
	}
	return .None, 0
}

@(private)
query_offset :: proc(p: ^Palette, l: Palette_Layout, text: ^Text, x, scale: f32) -> int {
	input_text := text_styled(text, .Input)
	origin := l.input.x + PALETTE_TEXT_INSET * scale
	available := l.input.width - 2 * PALETTE_TEXT_INSET * scale
	return field_offset_at(
		&p.query,
		&input_text,
		field_view_start(&p.query, &input_text, available),
		origin,
		x,
	)
}

palette_input_contains :: proc(l: Palette_Layout, x, y: f32) -> bool {
	r := l.input
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

// Places the caret, or with `extend` grows the selection, and starts a drag selection.
palette_input_press :: proc(
	p: ^Palette,
	l: Palette_Layout,
	text: ^Text,
	x, scale: f32,
	extend: bool,
) -> Outcome {
	return(
		field_pointer(&p.query, query_offset(p, l, text, x, scale), true, extend) == .None ? .None : .Changed \
	)
}

palette_input_drag :: proc(p: ^Palette, l: Palette_Layout, text: ^Text, x, scale: f32) -> Outcome {
	return(
		field_pointer(&p.query, query_offset(p, l, text, x, scale), false, true) == .None ? .None : .Changed \
	)
}

palette_input_release :: proc(p: ^Palette) -> bool {
	dragging := p.query.dragging
	p.query.dragging = false
	return dragging
}

palette_scroll :: proc(p: ^Palette, rows: int) -> Outcome {
	limit := max(0, len(p.results) - PALETTE_MAX_ROWS)
	scroll := clamp(p.scroll - rows, 0, limit)
	if scroll == p.scroll {
		return .None
	}
	p.scroll = scroll
	p.selected = clamp(p.selected, p.scroll, p.scroll + PALETTE_MAX_ROWS - 1)
	return .Changed
}

palette_draw :: proc(
	p: ^Palette,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, height, scale: f32,
) -> glyphs.Result {
	l := palette_layout(p, width, height, scale)
	panel := l.panel
	radius := PALETTE_RADIUS * scale
	if render.push_layer(list, {0, 0, width, height}) != .None {
		return .Ok
	}
	draw_rect(list, {rect = {0, 0, width, height}, color = theme.scrim})
	shadow := render.Rect{panel.x, panel.y + 12 * scale, panel.width, panel.height}
	border := render.Rect {
		panel.x - scale,
		panel.y - scale,
		panel.width + 2 * scale,
		panel.height + 2 * scale,
	}
	rects := [?]render.Rect_Instance {
		{rect = shadow, color = theme.shadow, radius = radius, softness = 32 * scale},
		{rect = border, color = theme.border, radius = radius + scale},
		{rect = panel, color = theme.surface, radius = radius},
		{rect = {panel.x, l.input.y + l.input.height, panel.width, scale}, color = theme.border},
	}
	for r in rects {
		draw_rect(list, r)
	}
	padding := PALETTE_TEXT_INSET * scale
	input_text := text_styled(text, .Input)
	label_text := text_styled(text, .Label)
	if result := draw_text(
		&label_text,
		list,
		"COMMANDS AND SETTINGS",
		l.input.x + padding,
		l.input.y + 19 * scale,
		theme.faint,
	); result != .Ok {return result}
	if result := field_draw(
		&p.query,
		list,
		&input_text,
		theme,
		l.input.x + padding,
		l.input.y + 43 * scale,
		l.input.width - 2 * padding,
		true,
		"Type a command or setting",
		theme.text,
		max(1, 1.5 * scale),
	); result != .Ok {return result}
	if len(p.results) == 0 {
		row_baseline := l.list.y + (l.row_height - text.line_height) / 2 + text.ascent
		return draw_text(
			text,
			list,
			"No matching commands or settings",
			l.list.x + padding,
			row_baseline,
			theme.muted,
		)
	}
	label_buffer: [64]u8
	for index in p.scroll ..< min(len(p.results), p.scroll + PALETTE_MAX_ROWS) {
		item := p.results[index]
		row := render.Rect {
			l.list.x,
			l.list.y + f32(index - p.scroll) * l.row_height,
			l.list.width,
			l.row_height,
		}
		if index == p.selected {
			draw_rect(list, {rect = row, color = theme.selection, radius = 6 * scale})
		}
		row_baseline := row.y + 31 * scale
		category :=
			item.command != nil ? command_category(item.command.name) : p.settings[item.setting].group
		category = strings.to_upper(category, context.temp_allocator)
		if item.command ==
		   nil {category = strings.concatenate({category, " SETTING"}, context.temp_allocator)}
		if result := draw_text(
			&label_text,
			list,
			category,
			row.x + padding,
			row.y + 13 * scale,
			theme.faint,
		); result != .Ok {return result}
		label_width: f32
		if item.command != nil {
			if shortcuts := commands.active_shortcuts(item.command); len(shortcuts) > 0 {
				if label, err := commands.shortcut_label(shortcuts[0], label_buffer[:]);
				   err == .None {
					key_text := text_styled(text, .Keycap)
					label_width = text_width(&key_text, label) + 12 * scale
					x := row.x + row.width - padding - label_width
					draw_rect(
						list,
						{
							rect = {
								x - 4 * scale,
								row.y + 7 * scale,
								label_width + 4 * scale,
								row.height - 14 * scale,
							},
							color = theme.border,
							radius = 4 * scale,
							stroke = scale,
						},
					)
					if result := draw_text(
						&key_text,
						list,
						label,
						x + 2 * scale,
						row_baseline,
						theme.muted,
					); result != .Ok {return result}
				}
			}
		}
		title_width := row.width - 2 * padding - label_width - 16 * scale
		result := draw_text(
			text,
			list,
			palette_result_title(p, item),
			row.x + padding,
			row_baseline,
			theme.text,
			title_width,
			item.positions,
			theme.accent,
		)
		if result != .Ok {
			return result
		}
	}
	return .Ok
}
