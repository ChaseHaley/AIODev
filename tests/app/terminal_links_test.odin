package app_test

import "core:fmt"
import "core:os"
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
	confirmed: bool,
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
	// Writing directly skips the reader that records a change, and the link scan keys on that record.
	term.clear_selection(entry.session)
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
	if !palette_fixture_create(t, &f, "terminal-links", second_window = false) {return}
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

	g := term.geometry(entry.session)
	grid_point, grid_ok := link_point(t, &f, 0, 0)
	if !grid_ok {return}
	app.handle_event(
		s,
		platform.Mouse_Move_Event {
			window = w.id,
			x = grid_point.x - i32(g.cell_width / 2) - 1,
			y = grid_point.y,
		},
	)
	testing.expect_value(t, w.pointer_shape, platform.Cursor_Shape.Text)
	_, still_hovered := view.hover.?
	testing.expect(t, !still_hovered, "padding beside the grid is not a link cell")

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
	if !palette_fixture_create(t, &f, "terminal-links-osc8", second_window = false) {return}
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
		"\x1b[2;1H\x1b]8;;file://remote/C:/Windows\x1b\\BLOCKED\x1b]8;;\x1b\\",
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
	if !palette_fixture_create(t, &f, "terminal-links-scroll", second_window = false) {return}
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

@(test)
active_terminal_file_waits_for_confirmation_and_can_be_cancelled :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "terminal-active-file", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.terminal_file_request(s, w, `C:\Windows\System32\cmd.exe`)
	testing.expect(t, w.pending_file.confirm.open)
	app.confirmation_cancel(s, w)
	testing.expect(t, !w.pending_file.confirm.open)
}

link_file_stub :: proc(path, approved: string) -> bool {
	Open_Stub_State.calls += 1
	Open_Stub_State.confirmed = approved != ""
	Open_Stub_State.uri = strings.clone(path, context.temp_allocator)
	return path != ""
}

@(private)
Link_Files :: struct {
	root, folder, spaced, plain: string,
}

// A real tree, because the click settles what text means by checking which file exists. Its paths
// outlive the app ticks that reset the temporary allocator.
@(private, require_results)
link_files_create :: proc(t: ^testing.T) -> (files: Link_Files, ok: bool) {
	root, err := os.make_directory_temp("", "aio-terminal-links-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return {}, false}
	files = {
		root = root,
		folder = fmt.aprintf(`%s\My Folder`, root),
		spaced = fmt.aprintf(`%s\My Folder\target file.txt`, root),
		plain = fmt.aprintf(`%s\plain.txt`, root),
	}
	testing.expect_value(t, os.make_directory(files.folder), nil)
	testing.expect_value(t, os.write_entire_file(files.spaced, transmute([]u8)string("x")), nil)
	testing.expect_value(t, os.write_entire_file(files.plain, transmute([]u8)string("x")), nil)
	return files, true
}

@(private)
link_files_destroy :: proc(files: Link_Files) {
	_ = os.remove(files.spaced)
	_ = os.remove(files.plain)
	_ = os.remove(files.folder)
	_ = os.remove(files.root)
	delete(files.spaced)
	delete(files.plain)
	delete(files.folder)
	delete(files.root)
}

@(test)
ctrl_click_opens_a_spaced_path_the_underline_could_not_prove :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "terminal-spaced-path", second_window = false) {return}
	files, ok := link_files_create(t)
	if !ok {return}
	defer link_files_destroy(files)
	s := &f.state
	s.open_file = link_file_stub
	Open_Stub_State = {}
	// Nothing after "My" shows the path goes on, so only the disk can tell this is a folder.
	link_feed(t, &f, fmt.tprintf("\x1b[2J\x1b[3J\x1b[H%s", files.folder))
	link_click(t, &f, 2, 0, true)
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect(t, strings.has_suffix(Open_Stub_State.uri, `My Folder`), Open_Stub_State.uri)

	Open_Stub_State = {}
	link_feed(t, &f, fmt.tprintf("\x1b[2J\x1b[3J\x1b[H%s for review", files.spaced))
	link_click(t, &f, 2, 0, true)
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect(t, strings.has_suffix(Open_Stub_State.uri, `target file.txt`), Open_Stub_State.uri)
}

@(test)
ctrl_click_opens_a_path_a_program_wrapped_at_the_edge :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "terminal-wrapped-path", second_window = false) {return}
	files, ok := link_files_create(t)
	if !ok {return}
	defer link_files_destroy(files)
	s, w := &f.state, f.state.windows[0]
	s.open_file = link_file_stub
	Open_Stub_State = {}
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	columns := int(term.geometry(entry.session).columns)
	split := min(columns - 2, len(files.plain) - 4)
	pad := strings.repeat("x", columns - split - 1, context.temp_allocator)
	link_feed(
		t,
		&f,
		fmt.tprintf(
			"\x1b[2J\x1b[3J\x1b[H%s %s\r\n  %s",
			pad,
			files.plain[:split],
			files.plain[split:],
		),
	)
	link_click(t, &f, 3, 1, true)
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect(t, strings.has_suffix(Open_Stub_State.uri, `plain.txt`), Open_Stub_State.uri)
}

@(test)
ctrl_click_inside_a_selection_opens_the_selected_text :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "terminal-selected-path", second_window = false) {return}
	files, ok := link_files_create(t)
	if !ok {return}
	defer link_files_destroy(files)
	s, w := &f.state, f.state.windows[0]
	s.open_file = link_file_stub
	Open_Stub_State = {}
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	link_feed(t, &f, fmt.tprintf("\x1b[2J\x1b[3J\x1b[H%s is the folder", files.folder))
	columns := int(term.geometry(entry.session).columns)
	rows := len(files.folder) / columns
	first, first_ok := term.cell_center(term.geometry(entry.session), 0, 0)
	last, last_ok := term.cell_center(term.geometry(entry.session), len(files.folder) % columns - 1, rows)
	if !testing.expect(t, first_ok && last_ok) {return}
	term.selection_press(entry.session, f32(first.x) - 2, f32(first.y), 3_000_000_000)
	term.selection_drag(entry.session, f32(last.x) + 2, f32(last.y))
	term.selection_release(entry.session, f32(last.x) + 2, f32(last.y))
	app.tick(s)
	if !link_move(t, &f, 1, 0) {return}
	testing.expect_value(t, w.pointer_shape, platform.Cursor_Shape.Hand)
	link_click(t, &f, 1, 0, true)
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect(t, strings.has_suffix(Open_Stub_State.uri, `My Folder`), Open_Stub_State.uri)
	testing.expect(t, term.has_selection(entry.session), "opening keeps the selection")
}

@(test)
ctrl_click_active_file_opens_only_after_explicit_acceptance :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "terminal-confirm-file", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.open_file = link_file_stub
	Open_Stub_State = {}
	link_feed(t, &f, "\x1b[2J\x1b[3J\x1b[H" +
		"\x1b]8;;file:///C:/Windows/System32/cmd.exe\x1b\\EXEC\x1b]8;;\x1b\\")
	link_click(t, &f, 0, 0, true)
	testing.expect(t, w.pending_file.confirm.open)
	testing.expect_value(t, Open_Stub_State.calls, 0)
	_ = app.confirmation_key(s, w, {key = .Enter, pressed = true})
	testing.expect(t, !w.pending_file.confirm.open, "Enter initially cancels")
	link_click(t, &f, 0, 0, true)
	_ = app.confirmation_key(s, w, {key = .Tab, pressed = true})
	_ = app.confirmation_key(s, w, {key = .Enter, pressed = true})
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect(t, Open_Stub_State.confirmed)
}
