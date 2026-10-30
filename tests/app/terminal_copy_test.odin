package app_test

import app "../../src"
import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"
import "core:testing"

@(private)
Terminal_Copy_Fixture :: struct {
	state: app.App,
	window: app.Window,
	workspace: app.Workspace,
	tree: layout.Layout,
	session: ^term.Session,
}

@(private, require_results)
terminal_copy_fixture :: proc(t: ^testing.T, f: ^Terminal_Copy_Fixture) -> bool {
	f.state.registry = commands.create()
	if !testing.expect_value(t, app.register_actions(&f.state.registry), commands.Error.None) {return false}
	ui.notices_init(&f.state.notices)
	if !testing.expect_value(t, layout.init(&f.tree, {.Terminal, 232}), nil) {return false}
	f.window = {id = 232, tree = &f.tree, workspace = &f.workspace, width = 640, height = 384, scale = 1}
	ui.find_init(&f.window.find)
	append(&f.state.windows, &f.window)
	geometry := term.Geometry{columns = 80, rows = 24, cell_width = 8, cell_height = 16,
		surface_width = 640, surface_height = 384}
	session, err := term.create_headless(geometry, 100)
	if !testing.expect_value(t, err, term.Error.None) {return false}
	f.session = session
	append(&f.state.sessions, app.Session_Entry{id = 232, session = session, status = .Running})
	initial := "\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[>3uCLAUDE_SELECTION"
	term.replay_write(session, transmute([]u8)initial)
	return true
}

@(private)
terminal_copy_fixture_destroy :: proc(f: ^Terminal_Copy_Fixture) {
	if f.session != nil {term.destroy(f.session)}
	layout.destroy(&f.tree)
	ui.find_destroy(&f.window.find)
	ui.notices_destroy(&f.state.notices)
	commands.destroy(&f.state.registry)
	delete(f.state.windows)
	delete(f.state.sessions)
}

@(private)
terminal_copy_key :: proc(t: ^testing.T, f: ^Terminal_Copy_Fixture, key: input.Key, modifiers: input.Modifiers) {
	buffer: [32]u8
	for pressed in ([2]bool{true, false}) {
		e, err := platform.synthesize_key(f.window.id, key, modifiers, pressed, buffer[:])
		if !testing.expect_value(t, err, platform.Error.None) {return}
		app.handle_event(&f.state, e)
	}
}

@(test)
terminal_copy_without_native_selection_reaches_fullscreen_application :: proc(t: ^testing.T) {
	f: Terminal_Copy_Fixture
	defer terminal_copy_fixture_destroy(&f)
	if !terminal_copy_fixture(t, &f) {return}
	testing.expect(t, !term.has_selection(f.session) && term.mouse_tracking(f.session))
	terminal_copy_key(t, &f, .C, {.Control, .Shift})
	testing.expect_value(t, string(f.session.queue.pending[:]), "\x1b[99;6u")
	testing.expect(t, f.window.suppressed_key == nil)
	clear(&f.session.queue.pending)
	terminal_copy_key(t, &f, .Insert, {.Control})
	testing.expect_value(t, string(f.session.queue.pending[:]), "\x1b[2;5~\x1b[2;5:3~")
}

@(test)
terminal_copy_custom_binding_and_find_keep_their_own_scope :: proc(t: ^testing.T) {
	f: Terminal_Copy_Fixture
	defer terminal_copy_fixture_destroy(&f)
	if !terminal_copy_fixture(t, &f) {return}
	bindings := [?]commands.Shortcut{{.Y, {.Control, .Alt}}}
	overrides := [?]commands.Override{{commands.Command_Id(app.Action.Copy), bindings[:]}}
	errors: [1]commands.Error
	testing.expect_value(t, commands.rebind(&f.state.registry, overrides[:], errors[:]), commands.Error.None)
	terminal_copy_key(t, &f, .Y, {.Control, .Alt})
	testing.expect_value(t, string(f.session.queue.pending[:]), "\x1b[121;7u")
	clear(&f.session.queue.pending)
	ui.find_open(&f.window.find)
	ui.field_set(&f.window.find.query, "find selection")
	ui.field_select_all(&f.window.find.query)
	terminal_copy_key(t, &f, .Y, {.Control, .Alt})
	testing.expect_value(t, len(f.session.queue.pending), 0)
	testing.expect_value(t, ui.field_selected_text(&f.window.find.query), "find selection")
	testing.expect(t, f.window.suppressed_key == nil)
}

@(test)
terminal_native_copy_keeps_repeats_and_release_out_of_the_application :: proc(t: ^testing.T) {
	f: Terminal_Copy_Fixture
	defer terminal_copy_fixture_destroy(&f)
	if !terminal_copy_fixture(t, &f) {return}
	term.select_all(f.session)
	if !testing.expect(t, term.has_selection(f.session)) {return}
	e := platform.Key_Event{window = f.window.id, key = .C, modifiers = {.Control, .Shift}, pressed = true}
	app.handle_event(&f.state, e)
	testing.expect_value(t, len(f.session.queue.pending), 0)
	testing.expect(t, f.window.suppressed_key != nil)
	// Successful copy clears the native selection before a held key can repeat.
	term.clear_selection(f.session)
	e.repeat = true
	app.handle_event(&f.state, e)
	e.pressed, e.repeat = false, false
	app.handle_event(&f.state, e)
	testing.expect_value(t, len(f.session.queue.pending), 0)
	testing.expect(t, f.window.suppressed_key == nil)
	terminal_copy_key(t, &f, .C, {.Control, .Shift})
	testing.expect_value(t, string(f.session.queue.pending[:]), "\x1b[99;6u")
}

@(test)
terminal_copy_fallback_preserves_interrupt_and_selection_extension :: proc(t: ^testing.T) {
	f: Terminal_Copy_Fixture
	defer terminal_copy_fixture_destroy(&f)
	if !terminal_copy_fixture(t, &f) {return}
	terminal_copy_key(t, &f, .C, {.Control})
	terminal_copy_key(t, &f, .Arrow_Right, {.Shift})
	terminal_copy_key(t, &f, .Home, {.Shift})
	terminal_copy_key(t, &f, .V, {.Alt})
	testing.expect_value(t, string(f.session.queue.pending[:]),
		"\x1b[99;5u\x1b[1;2:1C\x1b[1;2:3C\x1b[1;2:1H\x1b[1;2:3H\x1b[118;3u")
}
