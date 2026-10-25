package app_test

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "aio:ghostty"
import "aio:input"
import "aio:platform"
import "aio:term"
import app "../../src"

Open_Stub :: struct {
	uri:   string,
	calls: int,
}

// Only the link tests use the stub; they hold this lock so the package's parallel runner cannot
// interleave two journeys against one record.
Open_Stub_State: Open_Stub
Link_Test_Lock: sync.Mutex

link_open_stub :: proc(uri: string) -> bool {
	Open_Stub_State.uri = uri
	Open_Stub_State.calls += 1
	return true
}

@(private)
link_write :: proc(terminal: ghostty.Terminal, user: rawptr) -> bool {
	text := (^string)(user)
	ghostty.terminal_vt_write(terminal, raw_data(text^), uint(len(text^)))
	return true
}

link_feed :: proc(t: ^testing.T, f: ^Palette_Fixture, text: string) {
	s, w := &f.state, f.state.windows[0]
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	value := text
	if !testing.expect(t, term.with_terminal(entry.session, link_write, &value)) {return}
	app.tick(s)
}

@(private, require_results)
link_view :: proc(w: ^app.Window, id: u32) -> ^app.Pane_View {
	for &view, i in w.views {
		if view.content.id == id {
			return &w.views[i]
		}
	}
	return nil
}

@(private, require_results)
link_point :: proc(
	t: ^testing.T,
	f: ^Palette_Fixture,
	column, row: int,
) -> (
	point: [2]i32,
	ok: bool,
) {
	s, w := &f.state, f.state.windows[0]
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return {}, false}
	point, ok = term.cell_center(term.geometry(entry.session), column, row)
	testing.expect(t, ok)
	return
}

@(private)
link_move :: proc(t: ^testing.T, f: ^Palette_Fixture, column, row: int) -> bool {
	s, w := &f.state, f.state.windows[0]
	point, ok := link_point(t, f, column, row)
	if !ok {return false}
	app.handle_event(s, platform.Mouse_Move_Event{window = w.id, x = point.x, y = point.y})
	return true
}

@(private)
link_click :: proc(
	t: ^testing.T,
	f: ^Palette_Fixture,
	column, row: int,
	control: bool,
) {
	s, w := &f.state, f.state.windows[0]
	point, ok := link_point(t, f, column, row)
	if !ok {return}
	modifiers: input.Modifiers
	if control {modifiers = {.Control}}
	app.handle_event(
		s,
		platform.Mouse_Button_Event {
			window = w.id,
			button = .Left,
			pressed = true,
			x = point.x,
			y = point.y,
			modifiers = modifiers,
			time_ns = 1_000_000_000,
		},
	)
	app.handle_event(
		s,
		platform.Mouse_Button_Event {
			window = w.id,
			button = .Left,
			pressed = false,
			x = point.x,
			y = point.y,
			modifiers = modifiers,
			time_ns = 1_100_000_000,
		},
	)
}

@(test)
terminal_links_hover_and_ctrl_click_without_changing_plain_click :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "terminal-links") {return}
	s, w := &f.state, f.state.windows[0]
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	s.open_url = link_open_stub
	Open_Stub_State = {}

	link_feed(t, &f, "\x1b[2J\x1b[3J\x1b[Hhttps://example.com/one")
	view := link_view(w, entry.id)
	if !testing.expect(t, view != nil) {return}
	if !link_move(t, &f, 0, 0) {return}
	testing.expect_value(t, w.pointer_shape, platform.Cursor_Shape.Hand)
	hover, hovered := view.hover.?
	testing.expect(t, hovered)
	testing.expect_value(t, hover, term.Link_Range{0, 0, 0, 22})

	term.select_all(entry.session)
	before, selected := term.selection_text(entry.session, context.temp_allocator)
	testing.expect(t, selected)
	if !link_move(t, &f, 10, 0) {return}
	after, still_selected := term.selection_text(entry.session, context.temp_allocator)
	testing.expect(t, still_selected)
	testing.expect_value(t, after, before)
	term.clear_selection(entry.session)

	link_click(t, &f, 5, 0, true)
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect_value(t, Open_Stub_State.uri, "https://example.com/one")
	testing.expect(t, !term.has_selection(entry.session))

	point, point_ok := link_point(t, &f, 5, 0)
	if !point_ok {return}
	app.handle_event(
		s,
		platform.Mouse_Button_Event {
			window = w.id,
			button = .Left,
			pressed = true,
			x = point.x,
			y = point.y,
			time_ns = 2_000_000_000,
		},
	)
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect(t, w.selecting, "a plain click still begins the selection gesture")
	app.handle_event(
		s,
		platform.Mouse_Button_Event {
			window = w.id,
			button = .Left,
			pressed = false,
			x = point.x,
			y = point.y,
			time_ns = 2_100_000_000,
		},
	)
	testing.expect(t, !w.selecting)
}

@(test)
terminal_links_prefer_osc8_and_ignore_blocked_schemes :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "terminal-links-osc8") {return}
	s, w := &f.state, f.state.windows[0]
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	s.open_url = link_open_stub
	Open_Stub_State = {}
	link_feed(
		t,
		&f,
		"\x1b[2J\x1b[3J\x1b[H" +
		"\x1b]8;;https://osc.example\x1b\\https://plain.example\x1b]8;;\x1b\\" +
		"\x1b[2;1H\x1b]8;;file:///C:/Windows\x1b\\BLOCKED\x1b]8;;\x1b\\",
	)
	if !link_move(t, &f, 0, 0) {return}
	testing.expect_value(t, w.pointer_shape, platform.Cursor_Shape.Hand)
	link_click(t, &f, 0, 0, true)
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect_value(t, Open_Stub_State.uri, "https://osc.example")

	if !link_move(t, &f, 0, 1) {return}
	testing.expect_value(t, w.pointer_shape, platform.Cursor_Shape.Text)
	view := link_view(w, entry.id)
	if !testing.expect(t, view != nil) {return}
	_, hovered := view.hover.?
	testing.expect(t, !hovered)
	link_click(t, &f, 0, 1, true)
	testing.expect_value(t, Open_Stub_State.calls, 1)
}

@(test)
terminal_links_hover_at_nonzero_scroll_offset :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "terminal-links-scroll") {return}
	s, w := &f.state, f.state.windows[0]
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	s.open_url = link_open_stub
	Open_Stub_State = {}
	rows := int(term.geometry(entry.session).rows)
	if !testing.expect(t, rows > 5) {return}
	text := strings.builder_make()
	defer strings.builder_destroy(&text)
	fmt.sbprint(&text, "\x1b[2J\x1b[3J\x1b[H")
	for line in 0 ..< rows + 6 {
		if line == rows + 2 {
			fmt.sbprint(&text, "https://example.com/scrolled")
		} else {
			fmt.sbprintf(&text, "line%d", line)
		}
		if line != rows + 5 {
			fmt.sbprint(&text, "\r\n")
		}
	}
	link_feed(t, &f, strings.to_string(text))
	term.scroll_viewport(entry.session, -3)
	app.tick(s)
	if !link_move(t, &f, 0, rows - 1) {return}
	testing.expect_value(t, w.pointer_shape, platform.Cursor_Shape.Hand)
	link_click(t, &f, 3, rows - 1, true)
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect_value(t, Open_Stub_State.uri, "https://example.com/scrolled")
}
