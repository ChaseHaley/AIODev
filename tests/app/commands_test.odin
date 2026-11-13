package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:input"
import "aio:layout"
import "aio:settings"
import "aio:term"
import "aio:ui"

// A Palette_Fixture with a cmd.exe profile and a pane of it in `sub`, a folder below `root`, focused.
@(private = "file")
Commands_Fixture :: struct {
	using palette: Palette_Fixture,
	root, sub:     string,
	pane:          u32,
}

@(private = "file")
commands_fixture_create :: proc(t: ^testing.T, f: ^Commands_Fixture, name, commands: string) -> bool {
	if !palette_fixture_create(t, &f.palette, name, false) {return false}
	root, root_error := os.make_directory_temp("", "aio-commands-*", context.allocator)
	if !testing.expect_value(t, root_error, nil) {return false}
	f.root = root
	f.sub = fmt.aprintf(`%s\sub`, root)
	if !testing.expect_value(t, os.make_directory(f.sub), nil) {return false}
	existing, read_error := os.read_entire_file(f.path, context.allocator)
	if !testing.expect_value(t, read_error, nil) {return false}
	defer delete(existing)
	profile := "\nprofile.cmdp.name = Cmd\nprofile.cmdp.command = \"cmd.exe /d /q /k\"\n"
	text := strings.concatenate({string(existing), profile, commands}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(f.path, transmute([]u8)text), nil) {return false}
	s, w := &f.state, f.state.windows[0]
	app.reload_settings(s, false)
	id, opened := app.shell_open_placed(s, w, app.window_tree(w).focus, {directory = f.sub, profile = "cmdp"}, .Split_Right)
	f.pane = id
	return testing.expect(t, opened, "a cmd pane opens in the sub folder")
}

@(private = "file")
commands_fixture_destroy :: proc(t: ^testing.T, f: ^Commands_Fixture) {
	palette_fixture_destroy(t, &f.palette)
	if f.root != "" {testing.expect_value(t, os.remove_all(f.root), nil)}
	delete(f.root)
	delete(f.sub)
}

// Waits for the pane's screen to show `needle`, letting the app read its output.
@(private = "file")
screen_shows :: proc(s: ^app.App, id: u32, needle: string) -> bool {
	for start := time.tick_now(); time.tick_since(start) < 15 * time.Second; {
		app.tick(s)
		if entry := app.session_find(s, id); entry != nil {
			text, err := term.screen_text(entry.session, {unwrap = true, max_rows = 200}, context.temp_allocator)
			if err == .None && strings.contains(text, needle) {return true}
		}
		time.sleep(50 * time.Millisecond)
	}
	return false
}

// Whether a line of the pane's screen is exactly `line`: a command's output rather than its echo.
@(private = "file")
screen_line :: proc(s: ^app.App, id: u32, line: string) -> bool {
	entry := app.session_find(s, id)
	if entry == nil {return false}
	text, _ := term.screen_text(entry.session, {unwrap = true, max_rows = 200}, context.temp_allocator)
	for row in strings.split_lines_iterator(&text) {
		if strings.trim_space(row) == line {return true}
	}
	return false
}

@(private = "file")
command_rows :: proc(w: ^app.Window) -> []string {
	labels := make([dynamic]string, context.temp_allocator)
	for item, row in w.command_menu.menu.items {
		if entry, _ := app.command_menu_entry(&w.command_menu, row); entry.action == .Run {append(&labels, item.label)}
	}
	return labels[:]
}

@(private = "file")
command_row :: proc(w: ^app.Window, label: string) -> int {
	for item, row in w.command_menu.menu.items {
		if entry, _ := app.command_menu_entry(&w.command_menu, row); entry.action == .Run && item.label == label {
			return row
		}
	}
	return -1
}

@(private = "file")
command_click :: proc(s: ^app.App, w: ^app.Window, row: int) {
	r := ui.menu_row_rect(&w.command_menu.menu, row, f32(w.width), f32(w.height), w.scale)
	for pressed in ([?]bool{true, false}) {
		app.handle_event(
			s,
			input.Mouse_Button_Event {
				window = w.id,
				button = .Left,
				pressed = pressed,
				x = i32(r.x + 40 * w.scale),
				y = i32(r.y + r.height / 2),
			},
		)
	}
}

@(private = "file")
command_key :: proc(s: ^app.App, w: ^app.Window, which: input.Key, modifiers: input.Modifiers = {}) {
	app.handle_event(s, input.Key_Event{window = w.id, key = which, modifiers = modifiers, pressed = true})
	app.handle_event(s, input.Key_Event{window = w.id, key = which, modifiers = modifiers, pressed = false})
}

// Selects row `row` of the list and chooses the submenu row labelled `label` from the keyboard.
@(private = "file")
command_submenu_choose :: proc(s: ^app.App, w: ^app.Window, row: int, label: string) -> bool {
	ui.menu_select(&w.command_menu.menu, row)
	command_key(s, w, .Arrow_Right)
	if !app.command_submenu_shown(w) {return false}
	sub := &w.command_menu.submenu
	for item, i in sub.items {
		if item.label != label {continue}
		ui.menu_select(&sub.menu, i)
		command_key(s, w, .Enter)
		return true
	}
	return false
}

@(test)
commands_menu_offers_the_panes_commands_and_runs_or_types_them :: proc(t: ^testing.T) {
	f: Commands_Fixture
	defer commands_fixture_destroy(t, &f)
	root_probe, probe_error := os.make_directory_temp("", "aio-commands-other-*", context.allocator)
	if !testing.expect_value(t, probe_error, nil) {return}
	defer {testing.expect_value(t, os.remove_all(root_probe), nil); delete(root_probe)}
	// The folder command is saved for the pane's parent folder, so it is inherited; the others are for
	// another folder and another profile, which this pane does not see.
	if !commands_fixture_create(t, &f, "commands-run", "") {return}
	commands := fmt.tprintf(
		"saved_command.up.name = Up\nsaved_command.up.command = \"echo ran-folder\"\n" +
		"saved_command.up.level = folder\nsaved_command.up.folder = \"%s\"\nsaved_command.up.profile = cmdp\n" +
		"saved_command.away.command = \"echo away\"\nsaved_command.away.level = folder\n" +
		"saved_command.away.folder = \"%s\"\n" +
		"saved_command.mine.command = \"echo ran-profile\"\nsaved_command.mine.level = profile\n" +
		"saved_command.mine.profile = cmdp\n" +
		"saved_command.other.command = \"echo other\"\nsaved_command.other.level = profile\n" +
		"saved_command.other.profile = default\n" +
		"saved_command.all.name = Everywhere echo\nsaved_command.all.command = \"echo ran-everywhere\"\n" +
		"saved_command.all.level = everywhere\n",
		f.root,
		root_probe,
	)
	existing, _ := os.read_entire_file(f.path, context.temp_allocator)
	updated := strings.concatenate({string(existing), commands}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(f.path, transmute([]u8)updated), nil) {return}
	s, w := &f.state, f.state.windows[0]
	app.reload_settings(s, false)

	// The header has a Commands button beside Links, which opens the menu for its pane.
	pane: layout.Pane_Rect
	for candidate in w.panes {if candidate.content.id == f.pane {pane = candidate}}
	l := app.pane_header_layout(w, pane)
	button := l.buttons[.Commands]
	if !testing.expect(t, button.width > 0 && button.x > l.buttons[.Links].x) {return}
	for pressed in ([?]bool{true, false}) {
		app.handle_event(s, input.Mouse_Button_Event {
			window = w.id, button = .Left, pressed = pressed,
			x = i32(button.x + button.width / 2), y = i32(button.y + button.height / 2),
		})
	}
	if !testing.expect(t, app.command_menu_shown(w)) {return}
	rows := command_rows(w)
	if !testing.expect_value(t, len(rows), 3) {return}
	testing.expect_value(t, rows[0], "Up")
	testing.expect_value(t, rows[1], "echo ran-profile")
	testing.expect_value(t, rows[2], "Everywhere echo")
	up := w.command_menu.menu.items[command_row(w, "Up")]
	testing.expect(t, strings.has_prefix(up.detail, "from "), up.detail)

	// Typing filters by name and command line.
	app.handle_event(s, input.Text_Event{window = w.id, text = "everywhere"})
	testing.expect_value(t, len(command_rows(w)), 1)
	command_key(s, w, .Escape)
	testing.expect(t, app.command_menu_shown(w) && len(command_rows(w)) == 3)

	// A click runs the folder command in a new shell in its folder, with the profile it was saved from.
	before := len(s.sessions)
	command_click(s, w, command_row(w, "Up"))
	testing.expect(t, !app.command_menu_shown(w))
	if !testing.expect_value(t, len(s.sessions), before + 1) {return}
	ran := &s.sessions[len(s.sessions) - 1]
	ran_id := ran.id
	testing.expect_value(t, ran.profile_id, "cmdp")
	testing.expect(t, strings.equal_fold(ran.header.launch_directory, f.root), ran.header.launch_directory)
	testing.expect(t, screen_shows(s, ran_id, "ran-folder"), "the command ran")
	testing.expect(t, screen_line(s, ran_id, "ran-folder"), "its output printed")

	// Alt+Enter types a command into the menu's pane without running it.
	app.command_menu_open_focused(s, w)
	if !testing.expect(t, app.command_menu_shown(w)) {return}
	ui.menu_select(&w.command_menu.menu, command_row(w, "Everywhere echo"))
	command_key(s, w, .Enter, {.Alt})
	testing.expect(t, !app.command_menu_shown(w))
	testing.expect(t, screen_shows(s, ran_id, "echo ran-everywhere"), "the command was typed")
	time.sleep(300 * time.Millisecond)
	app.tick(s)
	testing.expect(t, !screen_line(s, ran_id, "ran-everywhere"), "the typed command did not run")
}

@(test)
commands_menu_saves_edits_moves_and_removes_commands :: proc(t: ^testing.T) {
	f: Commands_Fixture
	defer commands_fixture_destroy(t, &f)
	if !commands_fixture_create(t, &f, "commands-save", "") {return}
	s, w := &f.state, f.state.windows[0]
	saved := &s.settings.saved_commands

	// Ctrl+S opens the form; an empty command line stays there with a complaint.
	app.command_menu_open_focused(s, w)
	command_key(s, w, .S, {.Control})
	form, editing := app.command_menu_form(w)
	if !testing.expect(t, editing) {return}
	command_key(s, w, .Enter)
	form, editing = app.command_menu_form(w)
	testing.expect(t, editing && form.invalid)

	// Typing goes to the command line, Tab to the name, and Enter saves at This Folder.
	app.handle_event(s, input.Text_Event{window = w.id, text = `echo "saved"`})
	command_key(s, w, .Tab)
	app.handle_event(s, input.Text_Event{window = w.id, text = "Saved one"})
	command_key(s, w, .Enter)
	_, editing = app.command_menu_form(w)
	testing.expect(t, !editing && app.command_menu_shown(w))
	if !testing.expect_value(t, len(saved.items), 1) {return}
	command := &saved.items[0]
	testing.expect_value(t, command.name, "Saved one")
	testing.expect_value(t, command.command, `echo "saved"`)
	testing.expect_value(t, command.level, settings.Saved_Command_Level.Folder)
	testing.expect(t, strings.equal_fold(command.folder, f.sub), command.folder)
	testing.expect_value(t, command.profile, "cmdp")
	written, _ := os.read_entire_file(f.path, context.temp_allocator)
	testing.expect(t, strings.contains(string(written), `saved_command.command-1.command = "echo "saved""`))
	testing.expect_value(t, command_rows(w)[0], "Saved one")

	// Edit… fills the form in; Down twice picks Everywhere, where Enter keeps it.
	if !testing.expect(t, command_submenu_choose(s, w, command_row(w, "Saved one"), "Edit…")) {return}
	testing.expect_value(t, ui.field_string(&w.command_menu.command), `echo "saved"`)
	command_key(s, w, .Arrow_Down)
	command_key(s, w, .Arrow_Down)
	command_key(s, w, .Enter)
	if !testing.expect_value(t, len(saved.items), 1) {return}
	testing.expect_value(t, saved.items[0].level, settings.Saved_Command_Level.Everywhere)
	testing.expect_value(t, saved.items[0].folder, "")

	// Move to the pane's profile, then remove it.
	if !testing.expect(t, command_submenu_choose(s, w, command_row(w, "Saved one"), "Move to Cmd")) {return}
	if !testing.expect_value(t, len(saved.items), 1) {return}
	testing.expect_value(t, saved.items[0].level, settings.Saved_Command_Level.Profile)
	testing.expect_value(t, saved.items[0].profile, "cmdp")
	if !testing.expect(t, command_submenu_choose(s, w, command_row(w, "Saved one"), "Remove")) {return}
	testing.expect_value(t, len(saved.items), 0)
	written, _ = os.read_entire_file(f.path, context.temp_allocator)
	testing.expect(t, !strings.contains(string(written), "saved_command."))
	testing.expect(t, app.command_menu_shown(w) && len(command_rows(w)) == 0)
}

@(test)
dragging_a_command_onto_a_pane_types_it_there_without_running :: proc(t: ^testing.T) {
	f: Commands_Fixture
	defer commands_fixture_destroy(t, &f)
	commands := "saved_command.drag.command = \"echo dragged\"\nsaved_command.drag.level = everywhere\n"
	if !commands_fixture_create(t, &f, "commands-drag", commands) {return}
	s, w := &f.state, f.state.windows[0]
	target := f.pane
	// A second cmd pane holds the menu; the first takes the drop.
	holder, opened := app.shell_open_placed(s, w, app.window_tree(w).focus, {directory = f.sub, profile = "cmdp"}, .Split_Down)
	if !testing.expect(t, opened) {return}
	app.command_menu_open_focused(s, w)
	if !testing.expect(t, app.command_menu_shown(w)) {return}
	drop: layout.Pane_Rect
	for pane in w.panes {if pane.content.id == target {drop = pane}}
	r := ui.menu_row_rect(&w.command_menu.menu, command_row(w, "echo dragged"), f32(w.width), f32(w.height), w.scale)
	start := [2]i32{i32(r.x + 40 * w.scale), i32(r.y + r.height / 2)}
	end := [2]i32{i32(drop.rect.x + drop.rect.width / 2), i32(drop.rect.y + drop.rect.height / 2)}
	app.handle_event(s, input.Mouse_Button_Event{window = w.id, button = .Left, pressed = true, x = start.x, y = start.y})
	app.handle_event(s, input.Mouse_Move_Event{window = w.id, x = start.x + 30, y = start.y + 30, buttons = {.Left}})
	testing.expect(t, app.command_menu_dragging(w), "the row lifted out of the menu")
	app.handle_event(s, input.Mouse_Move_Event{window = w.id, x = end.x, y = end.y, buttons = {.Left}})
	app.handle_event(s, input.Mouse_Button_Event{window = w.id, button = .Left, pressed = false, x = end.x, y = end.y})
	testing.expect(t, !app.command_menu_shown(w))
	tree := app.window_tree(w)
	focused := tree.nodes[tree.focus].(layout.Pane)
	testing.expect_value(t, focused.content.id, target)
	testing.expect(t, screen_shows(s, target, "echo dragged"), "the command was typed into the drop pane")
	time.sleep(300 * time.Millisecond)
	app.tick(s)
	testing.expect(t, !screen_line(s, target, "dragged"), "the dropped command did not run")
	testing.expect(t, !screen_line(s, holder, "echo dragged"))

	// A drop outside every pane puts the menu back.
	app.command_menu_open_focused(s, w)
	r = ui.menu_row_rect(&w.command_menu.menu, command_row(w, "echo dragged"), f32(w.width), f32(w.height), w.scale)
	start = {i32(r.x + 40 * w.scale), i32(r.y + r.height / 2)}
	app.handle_event(s, input.Mouse_Button_Event{window = w.id, button = .Left, pressed = true, x = start.x, y = start.y})
	app.handle_event(s, input.Mouse_Move_Event{window = w.id, x = 2, y = 2, buttons = {.Left}})
	app.handle_event(s, input.Mouse_Button_Event{window = w.id, button = .Left, pressed = false, x = 2, y = 2})
	testing.expect(t, app.command_menu_shown(w) && !app.command_menu_dragging(w))
}
