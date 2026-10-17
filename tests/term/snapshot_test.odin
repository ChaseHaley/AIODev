package term_test

import "base:runtime"
import "core:mem"
import "core:testing"
import "aio:ghostty"
import "aio:term"

Snapshot_Source :: struct {
	terminal: ghostty.Terminal,
	state: ghostty.Render_State,
}

snapshot_source :: proc(t: ^testing.T, text: string, columns: u16 = 20) -> (Snapshot_Source, bool) {
	s: Snapshot_Source
	if !testing.expect_value(t, ghostty.terminal_new(nil, &s.terminal, columns, 3), ghostty.Result.Success) {
		return {}, false
	}
	if !testing.expect_value(t, ghostty.render_state_new(nil, &s.state), ghostty.Result.Success) {
		ghostty.terminal_free(s.terminal)
		return {}, false
	}
	ghostty.terminal_vt_write(s.terminal, raw_data(text), uint(len(text)))
	if !testing.expect_value(t, ghostty.render_state_update(s.state, s.terminal), ghostty.Result.Success) {
		snapshot_source_destroy(&s)
		return {}, false
	}
	return s, true
}

snapshot_source_destroy :: proc(s: ^Snapshot_Source) {
	ghostty.render_state_free(s.state)
	ghostty.terminal_free(s.terminal)
	s^ = {}
}

expect_row :: proc(t: ^testing.T, s: ^term.Snapshot, row: int, expected: string) {
	text, err := term.row_text(s, row)
	defer delete(text)
	testing.expect_value(t, err, term.Error.None)
	testing.expect_value(t, text, expected)
}

@(test)
snapshot_text_width_and_ownership :: proc(t: ^testing.T) {
	source, ok := snapshot_source(t, " a  b  \r\n\u754ce\u0301", 10)
	if !ok { return }
	defer snapshot_source_destroy(&source)
	s, err := term.snapshot(source.state)
	if !testing.expect_value(t, err, term.Error.None) { return }
	defer term.snapshot_destroy(&s)
	testing.expect_value(t, s.columns, 10)
	testing.expect_value(t, s.rows, 3)
	testing.expect_value(t, len(s.cells), 30)
	expect_row(t, &s, 0, " a  b")
	expect_row(t, &s, 1, "\u754ce\u0301")
	expect_row(t, &s, 2, "")
	expect_row(t, &s, -1, "")
	expect_row(t, &s, 3, "")
	testing.expect_value(t, term.snapshot_cell(&s, 0, 1).width, ghostty.Cell_Wide.Wide)
	testing.expect_value(t, term.snapshot_cell(&s, 1, 1).width, ghostty.Cell_Wide.Spacer_Tail)
	testing.expect_value(t, term.snapshot_cell(&s, 1, 1).text, "")
	testing.expect_value(t, term.snapshot_cell(&s, 2, 1).text, "e\u0301")
	testing.expect_value(t, term.snapshot_cell(&s, 2, 1).width, ghostty.Cell_Wide.Narrow)
	testing.expect_value(t, term.snapshot_cell(&s, 0, 2).text, "")
	outside := [?][2]int{{-1, 0}, {0, -1}, {10, 0}, {0, 3}}
	for p in outside {
		testing.expect(t, term.snapshot_cell(&s, p.x, p.y) == nil)
	}
	snapshot_source_destroy(&source)
	expect_row(t, &s, 1, "\u754ce\u0301")
	term.snapshot_destroy(&s)
	term.snapshot_destroy(&s)
	testing.expect(t, term.snapshot_cell(&s, 0, 0) == nil)
}

@(test)
snapshot_wrapping_and_overscan :: proc(t: ^testing.T) {
	wrapped, wrapped_ok := snapshot_source(t, "abc\u754c", 4)
	if !wrapped_ok { return }
	defer snapshot_source_destroy(&wrapped)
	w, wrap_err := term.snapshot(wrapped.state)
	if !testing.expect_value(t, wrap_err, term.Error.None) { return }
	defer term.snapshot_destroy(&w)
	testing.expect_value(t, term.snapshot_cell(&w, 3, 0).width, ghostty.Cell_Wide.Spacer_Head)
	testing.expect_value(t, term.snapshot_cell(&w, 3, 0).text, "")
	expect_row(t, &w, 0, "abc")
	expect_row(t, &w, 1, "\u754c")
	source, ok := snapshot_source(t, "0\r\n1\r\n2\r\n3\r\n4")
	if !ok { return }
	defer snapshot_source_destroy(&source)
	ghostty.terminal_scroll_viewport(source.terminal, {tag = .Delta, value = {delta = -1}})
	overscan := ghostty.Render_State_Overscan{above = 1, below = 1}
	testing.expect_value(t, ghostty.render_state_set(source.state, .Overscan, &overscan), ghostty.Result.Success)
	testing.expect_value(t, ghostty.render_state_update(source.state, source.terminal), ghostty.Result.Success)
	s, err := term.snapshot(source.state)
	if !testing.expect_value(t, err, term.Error.None) { return }
	defer term.snapshot_destroy(&s)
	testing.expect_value(t, s.rows, 3)
	testing.expect_value(t, len(s.cells), 60)
	expect_row(t, &s, 0, "1")
	expect_row(t, &s, 1, "2")
	expect_row(t, &s, 2, "3")
	testing.expect(t, !s.cursor.viewport_has_value)
}

@(test)
snapshot_background_only_cells :: proc(t: ^testing.T) {
	source, ok := snapshot_source(t, "\x1b[48;5;42m\x1b[K\x1b[2;1H\x1b[48;2;12;34;56m\x1b[K")
	if !ok { return }
	defer snapshot_source_destroy(&source)
	s, err := term.snapshot(source.state)
	if !testing.expect_value(t, err, term.Error.None) { return }
	defer term.snapshot_destroy(&s)
	palette := term.snapshot_cell(&s, 0, 0)
	rgb := term.snapshot_cell(&s, 0, 1)
	testing.expect_value(t, palette.text, "")
	testing.expect_value(t, rgb.text, "")
	testing.expect_value(t, palette.background, Maybe(term.Color)(s.palette[42]))
	testing.expect_value(t, rgb.background, Maybe(term.Color)(term.Color{12, 34, 56}))
	expect_row(t, &s, 0, "")
	expect_row(t, &s, 1, "")
}

@(test)
snapshot_styles_and_colors :: proc(t: ^testing.T) {
	source, ok := snapshot_source(t,
		"\x1b[1;2;3;5;7;8;9;53mA\x1b[0m" +
		"\x1b[4mB\x1b[21mC\x1b[4:3mD\x1b[4:4mE\x1b[4:5;58:5:42mF\x1b[0m" +
		"\x1b[38;5;123;48;5;45mG\x1b[38;2;1;2;3;48;2;4;5;6mH\x1b[0mI" +
		"\x1b]10;#112233\x07\x1b]11;#445566\x07\x1b]12;#778899\x07" +
		"\x1b]4;42;#abcdef\x07")
	if !ok { return }
	defer snapshot_source_destroy(&source)
	s, err := term.snapshot(source.state)
	if !testing.expect_value(t, err, term.Error.None) { return }
	defer term.snapshot_destroy(&s)
	a := term.snapshot_cell(&s, 0, 0).style
	testing.expect(t, a.bold && a.faint && a.italic && a.blink && a.inverse && a.invisible)
	testing.expect(t, a.strikethrough && a.overline)
	underlines := [?]ghostty.Sgr_Underline{.Single, .Double, .Curly, .Dotted, .Dashed}
	for underline, i in underlines {
		testing.expect_value(t, term.snapshot_cell(&s, i+1, 0).style.underline, i32(underline))
	}
	u := term.snapshot_cell(&s, 5, 0).style.underline_color
	testing.expect_value(t, u.tag, ghostty.Style_Color_Tag.Palette)
	testing.expect_value(t, u.value.palette, 42)
	testing.expect_value(t, s.palette[42], term.Color{0xab, 0xcd, 0xef})
	g := term.snapshot_cell(&s, 6, 0)
	testing.expect_value(t, g.foreground, Maybe(term.Color)(s.palette[123]))
	testing.expect_value(t, g.background, Maybe(term.Color)(s.palette[45]))
	h := term.snapshot_cell(&s, 7, 0)
	testing.expect_value(t, h.foreground, Maybe(term.Color)(term.Color{1, 2, 3}))
	testing.expect_value(t, h.background, Maybe(term.Color)(term.Color{4, 5, 6}))
	i := term.snapshot_cell(&s, 8, 0)
	testing.expect(t, i.foreground == nil && i.background == nil)
	testing.expect(t, !i.style.bold && !i.style.inverse && !i.style.invisible)
	testing.expect_value(t, s.foreground, term.Color{0x11, 0x22, 0x33})
	testing.expect_value(t, s.background, term.Color{0x44, 0x55, 0x66})
	testing.expect_value(t, s.cursor_color, Maybe(term.Color)(term.Color{0x77, 0x88, 0x99}))
}

@(test)
snapshot_cursor_and_selection :: proc(t: ^testing.T) {
	source, ok := snapshot_source(t, "hello\r\n\u754c\x1b[2;2H\x1b[5 q")
	if !ok { return }
	defer snapshot_source_destroy(&source)
	selection := ghostty.sized(ghostty.Selection)
	testing.expect_value(t, ghostty.terminal_select_all(source.terminal, &selection), ghostty.Result.Success)
	result := ghostty.terminal_set(source.terminal, .Selection, &selection)
	testing.expect_value(t, result, ghostty.Result.Success)
	testing.expect_value(t, ghostty.render_state_update(source.state, source.terminal), ghostty.Result.Success)
	s, err := term.snapshot(source.state)
	if !testing.expect_value(t, err, term.Error.None) { return }
	defer term.snapshot_destroy(&s)
	testing.expect(t, s.cursor.viewport_has_value && s.cursor.visible && s.cursor.blinking)
	testing.expect_value(t, s.cursor.viewport_x, 1)
	testing.expect_value(t, s.cursor.viewport_y, 1)
	testing.expect(t, s.cursor.wide_tail)
	testing.expect_value(t, s.cursor.visual_style, ghostty.Render_State_Cursor_Visual_Style.Bar)
	testing.expect(t, s.cursor_color == nil)
	testing.expect(t, term.snapshot_cell(&s, 0, 0).selected)
	testing.expect(t, !term.snapshot_cell(&s, 19, 2).selected)
	text :: "\x1b[?25l\x1b[4 q"
	ghostty.terminal_vt_write(source.terminal, raw_data(string(text)), len(text))
	testing.expect_value(t, ghostty.render_state_update(source.state, source.terminal), ghostty.Result.Success)
	hidden, hidden_err := term.snapshot(source.state)
	if !testing.expect_value(t, hidden_err, term.Error.None) { return }
	defer term.snapshot_destroy(&hidden)
	testing.expect(t, !hidden.cursor.visible && !hidden.cursor.blinking)
	testing.expect_value(t, hidden.cursor.visual_style, ghostty.Render_State_Cursor_Visual_Style.Underline)
}

@(test)
snapshot_preserves_render_state :: proc(t: ^testing.T) {
	source, ok := snapshot_source(t, "old\r\nsecond\r\nthird")
	if !ok { return }
	defer snapshot_source_destroy(&source)
	rows: ghostty.Render_State_Row_Iterator
	testing.expect_value(t, ghostty.render_state_row_iterator_new(nil, &rows), ghostty.Result.Success)
	defer ghostty.render_state_row_iterator_free(rows)
	cells: ghostty.Render_State_Row_Cells
	testing.expect_value(t, ghostty.render_state_row_cells_new(nil, &cells), ghostty.Result.Success)
	defer ghostty.render_state_row_cells_free(cells)
	testing.expect_value(t, ghostty.render_state_get(source.state, .Row_Iterator, &rows), ghostty.Result.Success)
	testing.expect(t, ghostty.render_state_row_iterator_next(rows))
	testing.expect_value(t, ghostty.render_state_row_get(rows, .Cells, &cells), ghostty.Result.Success)
	testing.expect_value(t, ghostty.render_state_row_cells_select(cells, 1), ghostty.Result.Success)
	before: ghostty.Render_State_Dirty
	testing.expect_value(t, ghostty.render_state_get(source.state, .Dirty, &before), ghostty.Result.Success)
	text :: "\x1b[Hnew"
	ghostty.terminal_vt_write(source.terminal, raw_data(string(text)), len(text))
	s, err := term.snapshot(source.state)
	if !testing.expect_value(t, err, term.Error.None) { return }
	defer term.snapshot_destroy(&s)
	expect_row(t, &s, 0, "old")
	expect_row(t, &s, 1, "second")
	expect_row(t, &s, 2, "third")
	after: ghostty.Render_State_Dirty
	testing.expect_value(t, ghostty.render_state_get(source.state, .Dirty, &after), ghostty.Result.Success)
	testing.expect_value(t, after, before)
	y: i32
	testing.expect_value(t, ghostty.render_state_row_get(rows, .Viewport_Y, &y), ghostty.Result.Success)
	testing.expect_value(t, y, 0)
	buffer: [8]u8
	grapheme := ghostty.Buffer{ptr = &buffer[0], cap = len(buffer)}
	testing.expect_value(t, ghostty.render_state_row_cells_get(cells, .Graphemes_Utf8, &grapheme),
	                     ghostty.Result.Success)
	testing.expect_value(t, string(buffer[:grapheme.len]), "l")
}

Snapshot_Allocator :: struct {
	backing: runtime.Allocator,
	remaining: int,
}

snapshot_allocate :: proc(
	data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location: runtime.Source_Code_Location,
) -> ([]u8, runtime.Allocator_Error) {
	s := (^Snapshot_Allocator)(data)
	if size > 0 && (mode == .Alloc || mode == .Alloc_Non_Zeroed ||
	                mode == .Resize || mode == .Resize_Non_Zeroed) {
		if s.remaining == 0 { return nil, .Out_Of_Memory }
		s.remaining -= 1
	}
	return s.backing.procedure(s.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
snapshot_failures_and_zero_destroy :: proc(t: ^testing.T) {
	zero: term.Snapshot
	term.snapshot_destroy(&zero)
	context.logger = {}
	invalid, invalid_err := term.snapshot(nil)
	defer term.snapshot_destroy(&invalid)
	testing.expect_value(t, invalid_err, term.Error.Terminal_Failed)
	source, ok := snapshot_source(t, "a long row with text")
	if !ok { return }
	defer snapshot_source_destroy(&source)
	for allowed in 0 ..< 8 {
		state := Snapshot_Allocator{context.allocator, allowed}
		s, err := term.snapshot(source.state, {snapshot_allocate, &state})
		if err == .None {
			expect_row(t, &s, 0, "a long row with text")
			_, row_err := term.row_text(&s, 0, mem.nil_allocator())
			testing.expect_value(t, row_err, term.Error.Out_Of_Memory)
		} else {
			testing.expect_value(t, err, term.Error.Out_Of_Memory)
			testing.expect_value(t, len(s.cells), 0)
		}
		term.snapshot_destroy(&s)
	}
}

@(test)
scrollbar_tracks_history :: proc(t: ^testing.T) {
	wakes: Wakes
	s := start(t, "cmd.exe /d /c \"for /l %i in (1,1,90) do @echo SCROLL_%i\"", &wakes)
	if s == nil { return }
	defer term.destroy(s)
	if !await(t, s, exited, "exit") || !await(t, s, shows, "SCROLL_90") { return }
	live, ok := term.scrollbar(s)
	if !testing.expect(t, ok) { return }
	testing.expect(t, live.total > live.len)
	testing.expect_value(t, live.len, u64(config("").geometry.rows))
	testing.expect_value(t, live.offset + live.len, live.total)
	term.scroll_viewport(s, -10)
	history, history_ok := term.scrollbar(s)
	testing.expect(t, history_ok)
	testing.expect_value(t, history.total, live.total)
	testing.expect_value(t, history.offset, live.offset - 10)
	term.scroll_to_bottom(s)
	bottom, bottom_ok := term.scrollbar(s)
	testing.expect(t, bottom_ok)
	testing.expect_value(t, bottom, live)
	zero: term.Session
	context.logger = {}
	_, zero_ok := term.scrollbar(&zero)
	testing.expect(t, !zero_ok)
}
