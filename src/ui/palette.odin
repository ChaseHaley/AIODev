package ui

import "base:runtime"
import "core:unicode/utf8"
import "aio:commands"
import "aio:fuzzy"
import "aio:glyphs"
import "aio:platform"
import "aio:render"

@(private) PALETTE_MAX_ROWS :: 8
@(private) PALETTE_WIDTH :: 640
@(private) PALETTE_INPUT_HEIGHT :: 48
@(private) PALETTE_ROW_HEIGHT :: 34
@(private) PALETTE_PADDING :: 8
@(private) PALETTE_RADIUS :: 10

Outcome :: enum {
	None,
	Changed,
	Closed,
	Run,
}

Palette :: struct {
	open: bool,
	query: [dynamic]u8,
	selected, scroll: int,
	results: [dynamic]commands.Search_Result,
	positions: [dynamic]int,
	scratch: ^fuzzy.Scratch,
}

Palette_Layout :: struct {
	panel, input, list: render.Rect,
	row_height: f32,
}

@(require_results)
palette_init :: proc(p: ^Palette, allocator := context.allocator) -> runtime.Allocator_Error {
	p.query = make([dynamic]u8, allocator)
	p.results = make([dynamic]commands.Search_Result, allocator)
	p.positions = make([dynamic]int, allocator)
	err: runtime.Allocator_Error
	p.scratch, err = new(fuzzy.Scratch, allocator)
	return err
}

palette_destroy :: proc(p: ^Palette) {
	free(p.scratch, p.query.allocator)
	delete(p.query)
	delete(p.results)
	delete(p.positions)
	p^ = {}
}

palette_open :: proc(p: ^Palette, registry: ^commands.Registry) {
	p.open = true
	clear(&p.query)
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
}

palette_close :: proc(p: ^Palette) {
	p.open = false
	clear(&p.query)
	clear(&p.results)
}

@(private)
refresh :: proc(p: ^Palette, registry: ^commands.Registry) {
	count := len(registry.items)
	width := max(1, utf8.rune_count(string(p.query[:])))
	resize(&p.results, count)
	resize(&p.positions, count * width)
	matched, err := commands.search(registry, string(p.query[:]), p.results[:], p.positions[:], p.scratch)
	if err != .None {
		matched = 0
	}
	resize(&p.results, matched)
	p.selected = clamp(p.selected, 0, max(0, matched - 1))
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
	id := p.results[index].command.id
	palette_close(p)
	return .Run, id
}

// Handles a key while the palette is open. Every key is consumed, so none reaches the terminal.
palette_key :: proc(
	p: ^Palette,
	registry: ^commands.Registry,
	e: platform.Key_Event,
) -> (Outcome, commands.Command_Id) {
	if !e.pressed {
		return .None, 0
	}
	control := .Control in e.modifiers
	#partial switch e.key {
	case .Escape:
		palette_close(p)
		return .Closed, 0
	case .Enter, .Numpad_Enter:
		return run(p, p.selected)
	case .Arrow_Up:
		return move(p, -1), 0
	case .Arrow_Down:
		return move(p, 1), 0
	case .Page_Up:
		return move(p, -PALETTE_MAX_ROWS), 0
	case .Page_Down:
		return move(p, PALETTE_MAX_ROWS), 0
	case .Home:
		return move(p, -len(p.results)), 0
	case .End:
		return move(p, len(p.results)), 0
	case .Backspace:
		if len(p.query) == 0 {
			return .None, 0
		}
		erase(p, control)
		refresh(p, registry)
		return .Changed, 0
	}
	if len(e.text) > 0 && (!control || .Alt in e.modifiers) {
		return palette_text(p, registry, e.text), 0
	}
	return .None, 0
}

@(private)
erase :: proc(p: ^Palette, word: bool) {
	end := len(p.query)
	for end > 0 {
		_, size := utf8.decode_last_rune(p.query[:end])
		end -= size
		if !word || (end > 0 && p.query[end - 1] == ' ' && p.query[end] != ' ') {
			break
		}
	}
	resize(&p.query, end)
}

palette_text :: proc(p: ^Palette, registry: ^commands.Registry, text: string) -> Outcome {
	changed := false
	for r in text {
		if r >= ' ' && r != 0x7f {
			bytes, size := utf8.encode_rune(r)
			append(&p.query, ..bytes[:size])
			changed = true
		}
	}
	if !changed {
		return .None
	}
	p.selected, p.scroll = 0, 0
	refresh(p, registry)
	return .Changed
}

palette_layout :: proc(p: ^Palette, width, height, scale: f32) -> Palette_Layout {
	panel_width := min(PALETTE_WIDTH * scale, width - 32 * scale)
	rows := max(1, min(len(p.results), PALETTE_MAX_ROWS))
	row_height := PALETTE_ROW_HEIGHT * scale
	padding := PALETTE_PADDING * scale
	input_height := PALETTE_INPUT_HEIGHT * scale
	panel := render.Rect{
		x = (width - panel_width) / 2,
		y = max(24 * scale, height * 0.15),
		width = panel_width,
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

palette_mouse_press :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> (Outcome, commands.Command_Id) {
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
	registry: ^commands.Registry,
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
	shadow := render.Rect{panel.x, panel.y + 8 * scale, panel.width, panel.height}
	border := render.Rect{panel.x - scale, panel.y - scale, panel.width + 2 * scale, panel.height + 2 * scale}
	rects := [?]render.Rect_Instance{
		{rect = shadow, color = theme.shadow, radius = radius, softness = 18 * scale},
		{rect = border, color = theme.border, radius = radius + scale},
		{rect = panel, color = theme.surface, radius = radius},
		{rect = {panel.x, l.input.y + l.input.height, panel.width, scale}, color = theme.border},
	}
	for r in rects {
		draw_rect(list, r)
	}
	padding := 14 * scale
	baseline := l.input.y + (l.input.height - text.line_height) / 2 + text.ascent
	query := string(p.query[:])
	shown, shown_color := query, theme.text
	if len(query) == 0 {
		shown, shown_color = "Type a command", theme.muted
	}
	if result := draw_text(text, list, shown, l.input.x + padding, baseline, shown_color); result != .Ok {
		return result
	}
	caret_x := l.input.x + padding + text_width(text, query)
	caret := render.Rect{caret_x, baseline - text.ascent, max(1, 1.5 * scale), text.line_height}
	draw_rect(list, {rect = caret, color = theme.accent})
	if len(p.results) == 0 {
		row_baseline := l.list.y + (l.row_height - text.line_height) / 2 + text.ascent
		return draw_text(text, list, "No matching commands", l.list.x + padding, row_baseline, theme.muted)
	}
	label_buffer: [64]u8
	for index in p.scroll ..< min(len(p.results), p.scroll + PALETTE_MAX_ROWS) {
		item := p.results[index]
		row := render.Rect{l.list.x, l.list.y + f32(index - p.scroll) * l.row_height, l.list.width, l.row_height}
		if index == p.selected {
			draw_rect(list, {rect = row, color = theme.selection, radius = 6 * scale})
		}
		row_baseline := row.y + (row.height - text.line_height) / 2 + text.ascent
		label_width: f32
		if shortcuts := commands.active_shortcuts(item.command); len(shortcuts) > 0 {
			if label, err := commands.shortcut_label(shortcuts[0], label_buffer[:]); err == .None {
				label_width = text_width(text, label)
				x := row.x + row.width - padding - label_width
				if result := draw_text(text, list, label, x, row_baseline, theme.muted); result != .Ok {
					return result
				}
			}
		}
		title_width := row.width - 2 * padding - label_width - 16 * scale
		result := draw_text(
			text, list, item.command.title, row.x + padding, row_baseline, theme.text,
			title_width, item.positions, theme.accent,
		)
		if result != .Ok {
			return result
		}
	}
	return .Ok
}
