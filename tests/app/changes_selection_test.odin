package app_test

import "aio:commands"
import "aio:input"
import "aio:markdown"
import "aio:platform"
import "aio:render"
import "aio:turns"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"

@(private = "file")
Selecting :: struct {
	state:     app.App,
	directory: string,
	store:     Diff_Store,
}

@(private = "file")
selecting_start :: proc(t: ^testing.T, f: ^Selecting, name: string) -> bool {
	directory, err := os.make_directory_temp("", "aio-selecting-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return false}
	f.directory = directory
	settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	text := idle_shell_settings(t, "cursor.blink = false\n")
	if !testing.expect_value(t, os.write_entire_file(settings_path, text), nil) {return false}
	f.state = {options = {data_dir = f.directory, inactive = true}}
	f.state.app_id = fmt.aprintf("AIODev.Test.Selecting.%s.%d", name, os.get_pid())
	app.layout_state_enable(&f.state, strings.concatenate({f.directory, "/layout.json"}))
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	return testing.expect(t, app.app_init(&f.state))
}

@(private = "file")
selecting_stop :: proc(t: ^testing.T, f: ^Selecting) {
	app.app_destroy(&f.state)
	testing.expect_value(t, os.remove_all(f.directory), nil)
	delete(f.directory)
}

// The diff the tests select in, filled in place so its slices stay valid. Flat lines: 0 "alpha beta gamma",
// 1 "removed text", 2 "added text here", 3 "  delta epsilon zeta  ", 4 four spaces, then filler to scroll
// through.
@(private = "file")
Diff_Store :: struct {
	lines: [12]turns.Diff_Line,
	hunks: [1]turns.Hunk,
	files: [1]turns.Diff_File,
}

@(private = "file")
diff_store_fill :: proc(s: ^Diff_Store) -> []turns.Diff_File {
	s.lines[0] = {kind = .Context, old_line = 1, new_line = 1, text = "alpha beta gamma"}
	s.lines[1] = {kind = .Removed, old_line = 2, text = "removed text"}
	s.lines[2] = {kind = .Added, new_line = 2, text = "added text here"}
	s.lines[3] = {kind = .Context, old_line = 3, new_line = 3, text = "  delta epsilon zeta  "}
	s.lines[4] = {kind = .Context, old_line = 4, new_line = 4, text = "    "}
	for i in 5 ..< len(s.lines) {
		s.lines[i] = {kind = .Context, old_line = i32(i), new_line = i32(i), text = "filler"}
	}
	s.hunks[0] = {old_start = 1, old_count = 11, new_start = 1, new_count = 11, lines = s.lines[:]}
	s.files[0] = {old_path = "a.odin", new_path = "a.odin", status = .Modified, hunks = s.hunks[:]}
	return s.files[:]
}

// The window, its Agent changes pane filled with the diff store, and its geometry.
@(private = "file")
selecting_pane :: proc(
	t: ^testing.T, f: ^Selecting,
) -> (
	w: ^app.Window,
	pane: ^app.Changes_Pane,
	ok: bool,
) {
	w = f.state.windows[0]
	app.window_resize(&f.state, w, 2400, 900)
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane = f.state.changes_panes[0]
	plain := app.Result_Plain {
		pane = pane.id,
		diff = {files = diff_store_fill(&f.store)},
	}
	app.changes_fill_plain(&f.state, pane, &plain)
	return w, pane, true
}

@(private = "file")
selecting_geometry :: proc(f: ^Selecting, w: ^app.Window, pane: ^app.Changes_Pane) -> ui.Changes_Geometry {
	for shown in w.panes {
		if shown.content.kind == .Changes {return app.changes_geometry_of(&f.state, w, pane, shown)}
	}
	return {}
}

// Where byte `offset` of flat line `line` is on screen, and the middle of its row, as a point.
@(private = "file")
selecting_at :: proc(
	f: ^Selecting, w: ^app.Window, pane: ^app.Changes_Pane, line, offset: int, right := false,
) -> [2]f32 {
	g := selecting_geometry(f, w, pane)
	view := &pane.model.view
	mono := ui.text_mono(&w.ui_text, f.state.family)
	row := ui.changes_line_rect(g, view, &pane.state, 0, line)
	x := row.x + row.width / 4
	if right {x = row.x + row.width * 3 / 4}
	cell, column, _ := ui.changes_line_code(g, view, &pane.state, &mono, 0, line, x)
	text, _ := ui_line_text(view, line)
	return {
		column.text_x + ui.code_x_of(&mono, text, column.width, offset) + 1,
		cell.y + cell.height / 2,
	}
}

@(private = "file")
ui_line_text :: proc(view: ^ui.Changes_View, line: int) -> (string, bool) {
	at := line
	for hunk in view.files[0].hunks {
		if at < len(hunk.lines) {return hunk.lines[at].text, true}
		at -= len(hunk.lines)
	}
	return "", false
}

@(private = "file")
mouse_button :: proc(
	f: ^Selecting, w: ^app.Window, at: [2]f32, pressed: bool, modifiers: input.Modifiers = {},
) {
	app.handle_event(
		&f.state,
		input.Mouse_Button_Event {
			window = w.id,
			x = i32(at.x),
			y = i32(at.y),
			button = .Left,
			pressed = pressed,
			modifiers = modifiers,
		},
	)
}

@(private = "file")
mouse_move :: proc(f: ^Selecting, w: ^app.Window, at: [2]f32, modifiers: input.Modifiers = {}) {
	app.handle_event(
		&f.state,
		input.Mouse_Move_Event{window = w.id, x = i32(at.x), y = i32(at.y), buttons = {.Left}, modifiers = modifiers},
	)
}

@(private = "file")
selecting_click :: proc(f: ^Selecting, w: ^app.Window, rect: render.Rect) {
	at := [2]f32{rect.x + rect.width / 2, rect.y + rect.height / 2}
	mouse_button(f, w, at, true)
	mouse_button(f, w, at, false)
}

// Drags from byte `from` of line `first` to byte `to` of line `last`.
@(private = "file")
selecting_drag :: proc(
	f: ^Selecting, w: ^app.Window, pane: ^app.Changes_Pane, first, from, last, to: int,
	modifiers: input.Modifiers = {},
) {
	start := selecting_at(f, w, pane, first, from)
	stop := selecting_at(f, w, pane, last, to)
	mouse_move(f, w, start, modifiers)
	mouse_button(f, w, start, true, modifiers)
	mouse_move(f, w, stop, modifiers)
	mouse_button(f, w, stop, false, modifiers)
}

@(test)
a_drag_over_code_selects_text_and_the_toolbar_labels_or_deletes_it :: proc(t: ^testing.T) {
	f: Selecting
	defer selecting_stop(t, &f)
	if !selecting_start(t, &f, "Drag") {return}
	w, pane, ok := selecting_pane(t, &f)
	if !ok {return}
	c := &pane.comments

	// Dragging from "beta" on line 0 to "epsilon" on line 3 selects those bytes, and the toolbar waits for the
	// pointer to be let go.
	start := selecting_at(&f, w, pane, 0, 6)
	stop := selecting_at(&f, w, pane, 3, 12)
	mouse_move(&f, w, start)
	mouse_button(&f, w, start, true)
	testing.expect(t, c.dragging)
	testing.expect_value(t, c.selection.active, false)
	mouse_move(&f, w, stop)
	want := ui.Changes_Selection {
		file = 0, first = 0, last = 3, active = true, partial = true, first_offset = 6, last_offset = 12,
	}
	testing.expect_value(t, c.selection, want)
	g := selecting_geometry(&f, w, pane)
	testing.expect_value(t, g.selection_bar.bar, render.Rect{})
	mouse_button(&f, w, stop, false)
	testing.expect_value(t, c.dragging, false)
	testing.expect_value(t, c.selection, want)
	g = selecting_geometry(&f, w, pane)
	if !testing.expect(t, g.selection_bar.bar.width > 0, "letting go shows the toolbar") {return}

	// The buttons say what they do, with their keys.
	deleting := render.Rect{g.selection_bar.delete.x, g.selection_bar.delete.y, 4, 4}
	testing.expect_value(t, app.changes_tooltip(&f.state, w, deleting.x + 2, deleting.y + 2),
		"Ask the agent to delete this")
	shortcut := app.changes_shortcut(&f.state, w, deleting.x + 2, deleting.y + 2)
	key, _ := shortcut.(commands.Shortcut)
	testing.expect_value(t, key, commands.Shortcut{.Delete, {}})
	comment := g.selection_bar.comment
	testing.expect_value(t, app.changes_tooltip(&f.state, w, comment.x + 2, comment.y + 2), "Comment")
	shortcut = app.changes_shortcut(&f.state, w, comment.x + 2, comment.y + 2)
	hint, _ := shortcut.(string)
	testing.expect_value(t, hint, "type to start")
	label := g.selection_bar.label
	testing.expect_value(t, app.changes_tooltip(&f.state, w, label.x + 2, label.y + 2), "Quick label")
	shortcut = app.changes_shortcut(&f.state, w, label.x + 2, label.y + 2)
	hint, _ = shortcut.(string)
	testing.expect_value(t, hint, "Alt+1–9")

	// A press anywhere but on the toolbar and its menu closes the menu: the Select lines button here.
	selecting_click(&f, w, g.selection_bar.label)
	testing.expect(t, c.menu)
	selecting_click(&f, w, g.select_lines_button)
	testing.expect_value(t, c.menu, false)
	selecting_click(&f, w, g.select_lines_button)
	testing.expect_value(t, c.select_lines, false)
	g = selecting_geometry(&f, w, pane)

	// Label opens the menu, and a row applies its label at once: a note on those bytes, the selection and the
	// toolbar gone.
	selecting_click(&f, w, g.selection_bar.label)
	testing.expect(t, c.menu)
	g = selecting_geometry(&f, w, pane)
	if !testing.expect(t, g.selection_bar.menu.width > 0 && g.selection_bar.shown > 1) {return}
	testing.expect_value(t, app.changes_tooltip(&f.state, w, g.selection_bar.rows.x + 8, g.selection_bar.rows.y + 40),
		"This looks like an assumption. Check it against the code or by running it, and say what you found.")
	selecting_click(&f, w, ui.changes_label_row_rect(g.selection_bar, 1))
	if !testing.expect_value(t, len(c.items), 1) {return}
	item := c.items[0]
	testing.expect_value(t, item.kind, ui.Changes_Note_Kind.Label)
	testing.expect_value(t, item.label_name, "Verify this")
	testing.expect_value(t, item.label_colour, "yellow")
	testing.expect(t, item.partial)
	testing.expect_value(t, item.first_offset, 6)
	testing.expect_value(t, item.last_offset, 12)
	testing.expect_value(t, c.selection.active, false)
	testing.expect_value(t, c.menu, false)
	g = selecting_geometry(&f, w, pane)
	testing.expect_value(t, g.selection_bar.bar, render.Rect{})

	// A plain click selects nothing; Delete on a drag adds a deletion of those bytes.
	here := selecting_at(&f, w, pane, 2, 3)
	mouse_move(&f, w, here)
	mouse_button(&f, w, here, true)
	mouse_button(&f, w, here, false)
	testing.expect_value(t, c.selection.active, false)
	selecting_drag(&f, w, pane, 2, 0, 2, 5)
	g = selecting_geometry(&f, w, pane)
	selecting_click(&f, w, g.selection_bar.delete)
	if !testing.expect_value(t, len(c.items), 2) {return}
	testing.expect_value(t, c.items[1].kind, ui.Changes_Note_Kind.Delete)
	testing.expect(t, c.items[1].partial)
	testing.expect_value(t, c.items[1].first_offset, 0)
	testing.expect_value(t, c.items[1].last_offset, 5)
}

@(test)
alt_the_toggle_and_the_gutter_pick_whole_lines :: proc(t: ^testing.T) {
	f: Selecting
	defer selecting_stop(t, &f)
	if !selecting_start(t, &f, "Lines") {return}
	w, pane, ok := selecting_pane(t, &f)
	if !ok {return}
	c := &pane.comments
	view := &pane.model.view

	// Alt alone changes nothing but the rows' hover.
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Alt_Left, modifiers = {.Alt}, pressed = true})
	testing.expect(t, c.alt)
	g := selecting_geometry(&f, w, pane)
	testing.expect(t, view.alt)
	testing.expect_value(t, pane.state.tools_open || pane.state.panel_open || pane.state.files_open, false)
	testing.expect_value(t, c.selection.active, false)
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Alt_Left})
	testing.expect(t, !c.alt)

	// With Alt down, a drag picks the lines under it, whole.
	selecting_drag(&f, w, pane, 0, 4, 3, 2, {.Alt})
	testing.expect_value(t, c.selection, ui.Changes_Selection{file = 0, first = 0, last = 3, active = true})
	g = selecting_geometry(&f, w, pane)
	testing.expect(t, g.selection_bar.bar.width > 0)

	// A press on the numbers picks the line, and Shift extends it.
	row := ui.changes_line_rect(g, view, &pane.state, 0, 1)
	at := [2]f32{row.x + 3, row.y + row.height / 2}
	mouse_move(&f, w, at)
	mouse_button(&f, w, at, true)
	mouse_button(&f, w, at, false)
	testing.expect_value(t, c.selection, ui.Changes_Selection{file = 0, first = 1, last = 1, active = true})
	row = ui.changes_line_rect(g, view, &pane.state, 0, 3)
	at = {row.x + 3, row.y + row.height / 2}
	mouse_button(&f, w, at, true, {.Shift})
	mouse_button(&f, w, at, false)
	testing.expect_value(t, c.selection, ui.Changes_Selection{file = 0, first = 1, last = 3, active = true})

	// The Select lines button turns on whole lines for every press, and says so.
	g = selecting_geometry(&f, w, pane)
	if !testing.expect(t, g.select_lines_button.width > 0) {return}
	testing.expect_value(t, app.changes_tooltip(&f.state, w, g.select_lines_button.x + 4, g.select_lines_button.y + 4),
		"Select lines")
	selecting_click(&f, w, g.select_lines_button)
	testing.expect(t, c.select_lines)
	g = selecting_geometry(&f, w, pane)
	testing.expect(t, view.select_lines)
	testing.expect_value(t, app.changes_tooltip(&f.state, w, g.select_lines_button.x + 4, g.select_lines_button.y + 4),
		"Select text")
	selecting_drag(&f, w, pane, 2, 3, 2, 8)
	testing.expect_value(t, c.selection, ui.Changes_Selection{file = 0, first = 2, last = 2, active = true})
	selecting_click(&f, w, g.select_lines_button)
	testing.expect(t, !c.select_lines)
	selecting_drag(&f, w, pane, 2, 3, 2, 8)
	testing.expect(t, c.selection.partial)
}

@(test)
a_text_drag_in_side_by_side_stays_in_the_cell_it_started_in :: proc(t: ^testing.T) {
	f: Selecting
	defer selecting_stop(t, &f)
	if !selecting_start(t, &f, "Cell") {return}
	w, pane, ok := selecting_pane(t, &f)
	if !ok {return}
	app.changes_layout_toggle(&f.state, w, pane)
	testing.expect(t, pane.side_by_side)
	c := &pane.comments

	// From byte 2 of the removed line on the left, down into the context row, with the pointer far over in
	// the right half: the end is measured in the left cell, which the pointer was held to.
	start := selecting_at(&f, w, pane, 1, 2)
	into := selecting_at(&f, w, pane, 3, 2, right = true)
	mouse_move(&f, w, start)
	mouse_button(&f, w, start, true)
	mouse_move(&f, w, into)
	mouse_button(&f, w, into, false)
	testing.expect(t, c.selection.active && c.selection.partial)
	testing.expect_value(t, c.selection.first, 1)
	testing.expect_value(t, c.selection.first_offset, 2)
	testing.expect_value(t, c.selection.last, 3)
	// The right half's byte 2 would be 2; held to the left cell, the pointer is at its end, less the spaces
	// trimmed from it.
	testing.expect_value(t, c.selection.last_offset, 20)
}

// A comment pane with no window, to drive its keys: the quick labels are set and a selection of lines made.
@(private = "file")
Keys :: struct {
	state: app.App,
	w:     app.Window,
	pane:  ^app.Changes_Pane,
	store: Diff_Store,
}

@(private = "file")
keys_start :: proc(t: ^testing.T, k: ^Keys) -> bool {
	k.state.settings.turns.quick_labels = "Clarify | blue | Explain it; Verify | #ff8800 | Check it; Good | green"
	k.pane = app.changes_pane_create(&k.state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, k.pane != nil) {return false}
	k.pane.model.view.files = diff_store_fill(&k.store)
	return true
}

@(private = "file")
keys_select :: proc(k: ^Keys, first, last: int) {
	hit := ui.Changes_Hit{.Gutter, 0, first}
	_ = app.changes_comments_press(&k.state, &k.w, k.pane, hit, {button = .Left, pressed = true})
	app.changes_comments_release(&k.state, &k.w, k.pane)
	if last != first {
		hit.line = last
		_ = app.changes_comments_press(&k.state, &k.w, k.pane, hit, {button = .Left, pressed = true, modifiers = {.Shift}})
		app.changes_comments_release(&k.state, &k.w, k.pane)
	}
}

@(private = "file")
keys_press :: proc(
	k: ^Keys, key: input.Key, modifiers: input.Modifiers = {}, text := "",
) -> bool {
	return app.changes_comments_key(
		&k.state, &k.w, k.pane, {key = key, modifiers = modifiers, text = text, pressed = true},
	)
}

@(test)
toolbar_keys_label_delete_comment_and_close :: proc(t: ^testing.T) {
	k: Keys
	defer app.changes_app_destroy(&k.state.changes_state)
	if !keys_start(t, &k) {return}
	c := &k.pane.comments
	testing.expect(t, !keys_press(&k, .Delete), "without a selection the keys are not the toolbar's")

	// Alt and a digit apply that label; a digit with no label there is taken and adds nothing.
	keys_select(&k, 2, 3)
	testing.expect(t, keys_press(&k, .Digit_2, {.Alt}))
	if !testing.expect_value(t, len(c.items), 1) {return}
	testing.expect_value(t, c.items[0].kind, ui.Changes_Note_Kind.Label)
	testing.expect_value(t, c.items[0].label_name, "Verify")
	testing.expect_value(t, c.items[0].label_colour, "#ff8800")
	testing.expect_value(t, c.items[0].label_instruction, "Check it")
	testing.expect_value(t, c.items[0].partial, false)
	testing.expect_value(t, c.selection.active, false)
	keys_select(&k, 2, 2)
	testing.expect(t, keys_press(&k, .Digit_9, {.Alt}))
	testing.expect_value(t, len(c.items), 1)
	testing.expect(t, c.selection.active)
	// Alt+0 is the tenth label.
	testing.expect(t, keys_press(&k, .Digit_0, {.Alt}))
	testing.expect_value(t, len(c.items), 1)

	// Delete and Backspace add a deletion at once.
	testing.expect(t, keys_press(&k, .Delete))
	if !testing.expect_value(t, len(c.items), 2) {return}
	testing.expect_value(t, c.items[1].kind, ui.Changes_Note_Kind.Delete)
	testing.expect_value(t, c.selection.active, false)
	keys_select(&k, 0, 0)
	testing.expect(t, keys_press(&k, .Backspace))
	testing.expect_value(t, len(c.items), 3)

	// Enter opens the comment editor empty; a typed character opens it with that character.
	keys_select(&k, 3, 3)
	testing.expect(t, keys_press(&k, .Enter))
	testing.expect_value(t, c.editing, 3)
	testing.expect_value(t, markdown.edit_string(&c.buffer), "")
	testing.expect(t, keys_press(&k, .Escape))
	testing.expect_value(t, c.editing, -1)
	testing.expect(t, keys_press(&k, .X, {.Shift}, "X"))
	testing.expect_value(t, c.editing, 3)
	testing.expect_value(t, markdown.edit_string(&c.buffer), "X")
	testing.expect(t, keys_press(&k, .Escape))
	testing.expect(t, c.selection.active)

	// Chords with Ctrl are not typing.
	testing.expect(t, !keys_press(&k, .C, {.Control}, ""))
	testing.expect(t, !keys_press(&k, .Arrow_Left))
	testing.expect_value(t, c.editing, -1)

	// Escape ends the selection.
	testing.expect(t, keys_press(&k, .Escape))
	testing.expect_value(t, c.selection.active, false)
}

@(test)
the_label_menu_takes_arrows_enter_and_plain_digits :: proc(t: ^testing.T) {
	k: Keys
	defer app.changes_app_destroy(&k.state.changes_state)
	if !keys_start(t, &k) {return}
	c := &k.pane.comments
	keys_select(&k, 1, 1)
	_ = app.changes_comments_press(&k.state, &k.w, k.pane, {.Toolbar_Label, 0, 0}, {button = .Left, pressed = true})
	if !testing.expect(t, c.menu) {return}
	testing.expect_value(t, k.pane.model.view.label_menu, true)

	// Arrows move through the labels and wrap; Enter applies the one the keys are on.
	testing.expect(t, keys_press(&k, .Arrow_Down))
	testing.expect(t, keys_press(&k, .Arrow_Down))
	testing.expect_value(t, c.menu_row, 2)
	testing.expect(t, keys_press(&k, .Arrow_Down))
	testing.expect_value(t, c.menu_row, 0)
	testing.expect(t, keys_press(&k, .Arrow_Up))
	testing.expect_value(t, c.menu_row, 2)
	// Escape closes the menu and keeps the selection; the next Escape ends it.
	testing.expect(t, keys_press(&k, .Escape))
	testing.expect_value(t, c.menu, false)
	testing.expect(t, c.selection.active)

	_ = app.changes_comments_press(&k.state, &k.w, k.pane, {.Toolbar_Label, 0, 0}, {button = .Left, pressed = true})
	testing.expect(t, keys_press(&k, .Arrow_Down))
	testing.expect(t, keys_press(&k, .Enter))
	if !testing.expect_value(t, len(k.pane.comments.items), 1) {return}
	testing.expect_value(t, c.items[0].label_name, "Verify")
	testing.expect_value(t, c.menu, false)

	// With the menu open a plain digit picks that label, where it would otherwise start a comment.
	keys_select(&k, 0, 0)
	_ = app.changes_comments_press(&k.state, &k.w, k.pane, {.Toolbar_Label, 0, 0}, {button = .Left, pressed = true})
	testing.expect(t, keys_press(&k, .Digit_3, {}, "3"))
	testing.expect_value(t, len(c.items), 2)
	testing.expect_value(t, c.items[1].label_name, "Good")
	testing.expect_value(t, c.items[1].label_instruction, "")
	keys_select(&k, 0, 0)
	testing.expect(t, keys_press(&k, .Digit_3, {}, "3"))
	testing.expect_value(t, c.editing, 2)
	testing.expect_value(t, markdown.edit_string(&c.buffer), "3")

	testing.expect(t, keys_press(&k, .Escape))
	testing.expect_value(t, c.editing, -1)
}

@(test)
text_selections_become_partial_notes_only_when_they_leave_something_out :: proc(t: ^testing.T) {
	k: Keys
	defer app.changes_app_destroy(&k.state.changes_state)
	if !keys_start(t, &k) {return}
	c := &k.pane.comments
	press := proc(k: ^Keys, line, offset: int, pressed: bool) {
		hit := ui.Changes_Hit{.Line, 0, line}
		at := app.Changes_Text_Point{offset = offset}
		if pressed {
			_ = app.changes_comments_press(&k.state, &k.w, k.pane, hit, {button = .Left, pressed = true}, at)
		} else {
			_ = app.changes_comments_drag(&k.state, &k.w, k.pane, hit, at)
		}
	}

	// A press and a drag across "beta gamma" on line 0, then let go: those bytes.
	press(&k, 0, 6, true)
	testing.expect(t, c.dragging)
	press(&k, 0, 16, false)
	app.changes_comments_release(&k.state, &k.w, k.pane)
	want := ui.Changes_Selection {
		file = 0, first = 0, last = 0, active = true, partial = true, first_offset = 6, last_offset = 16,
	}
	testing.expect_value(t, c.selection, want)
	testing.expect(t, keys_press(&k, .Delete))
	if !testing.expect_value(t, len(c.items), 1) {return}
	testing.expect(t, c.items[0].partial)
	testing.expect_value(t, c.items[0].first_offset, 6)
	testing.expect_value(t, c.items[0].last_offset, 16)

	// Backwards, from the end of line 3 to its start, which has spaces round its text: they go from both ends,
	// and what is left is the whole text of the line, which is a note on the line.
	press(&k, 3, 22, true)
	press(&k, 3, 0, false)
	app.changes_comments_release(&k.state, &k.w, k.pane)
	testing.expect_value(t, c.selection.first_offset, 2)
	testing.expect_value(t, c.selection.last_offset, 20)
	testing.expect(t, keys_press(&k, .Delete))
	if !testing.expect_value(t, len(c.items), 2) {return}
	testing.expect(t, !c.items[1].partial, "the whole text of a line is a note on the line")
	testing.expect_value(t, c.items[1].first_offset, 0)

	// A click with no drag selects nothing, and so does a drag over nothing.
	press(&k, 2, 4, true)
	app.changes_comments_release(&k.state, &k.w, k.pane)
	testing.expect_value(t, c.selection.active, false)
	press(&k, 2, 4, true)
	press(&k, 2, 4, false)
	app.changes_comments_release(&k.state, &k.w, k.pane)
	testing.expect_value(t, c.selection.active, false)

	// Spaces alone are nothing.
	press(&k, 4, 0, true)
	press(&k, 4, 4, false)
	app.changes_comments_release(&k.state, &k.w, k.pane)
	testing.expect_value(t, c.selection.active, false)
	// A drag from the end of one line over the start of the next is that gap, which is nothing.
	press(&k, 0, 16, true)
	press(&k, 1, 0, false)
	app.changes_comments_release(&k.state, &k.w, k.pane)
	testing.expect_value(t, c.selection.active, false)
	// Shift extends a text selection from its anchor.
	press(&k, 0, 2, true)
	press(&k, 0, 5, false)
	app.changes_comments_release(&k.state, &k.w, k.pane)
	testing.expect_value(t, c.selection.last_offset, 5)
	_ = app.changes_comments_press(
		&k.state, &k.w, k.pane, {.Line, 0, 3}, {button = .Left, pressed = true, modifiers = {.Shift}},
		{offset = 4},
	)
	app.changes_comments_release(&k.state, &k.w, k.pane)
	testing.expect_value(t, c.selection, ui.Changes_Selection{
		file = 0, first = 0, last = 3, active = true, partial = true, first_offset = 2, last_offset = 4,
	})
}

@(test)
a_selection_side_by_side_remembers_the_half_it_was_made_in :: proc(t: ^testing.T) {
	f: Selecting
	defer selecting_stop(t, &f)
	if !selecting_start(t, &f, "Half") {return}
	w, pane, ok := selecting_pane(t, &f)
	if !ok {return}
	app.changes_layout_toggle(&f.state, w, pane)
	testing.expect(t, pane.side_by_side)
	c := &pane.comments

	// Context line 0 is drawn in both halves: a drag in each picks the half it began in, and the note made
	// on it keeps that half.
	for right in ([2]bool{false, true}) {
		want := right ? ui.Changes_Half.Right : ui.Changes_Half.Left
		start, stop := selecting_at(&f, w, pane, 0, 2, right), selecting_at(&f, w, pane, 0, 8, right)
		mouse_move(&f, w, start)
		mouse_button(&f, w, start, true)
		mouse_move(&f, w, stop)
		mouse_button(&f, w, stop, false)
		testing.expect_value(t, c.selection.half, want)
		g := selecting_geometry(&f, w, pane)
		selecting_click(&f, w, g.selection_bar.delete)
		if !testing.expect(t, len(c.items) > 0) {return}
		testing.expect_value(t, c.items[len(c.items) - 1].half, want)
		testing.expect_value(t, pane.model.view.comments[len(c.items) - 1].half, want)
	}

	// Alt and a press on the numbers pick whole lines in the half they are pressed in too, and Shift keeps it.
	g := selecting_geometry(&f, w, pane)
	view := &pane.model.view
	mono := ui.text_mono(&w.ui_text, f.state.family)
	for right in ([2]bool{false, true}) {
		want := right ? ui.Changes_Half.Right : ui.Changes_Half.Left
		row := ui.changes_line_rect(g, view, &pane.state, 0, 3)
		x := right ? row.x + row.width * 3 / 4 : row.x + row.width / 4
		cell, column, _ := ui.changes_line_code(g, view, &pane.state, &mono, 0, 3, x)
		gutter := [2]f32{cell.x + 3, cell.y + cell.height / 2}
		mouse_move(&f, w, gutter)
		mouse_button(&f, w, gutter, true)
		mouse_button(&f, w, gutter, false)
		testing.expect_value(t, c.selection.half, want)
		testing.expect_value(t, c.selection.partial, false)
		text := [2]f32{column.text_x + 20, gutter.y}
		mouse_move(&f, w, text, {.Alt})
		mouse_button(&f, w, text, true, {.Alt})
		mouse_button(&f, w, text, false, {.Alt})
		testing.expect_value(t, c.selection.half, want)
		testing.expect_value(t, c.selection.partial, false)
	}
}

@(test)
the_label_menus_edit_row_opens_settings_on_the_quick_labels :: proc(t: ^testing.T) {
	f: Selecting
	defer selecting_stop(t, &f)
	if !selecting_start(t, &f, "EditLabels") {return}
	w, pane, ok := selecting_pane(t, &f)
	if !ok {return}
	c := &pane.comments
	selecting_drag(&f, w, pane, 0, 6, 0, 10)
	g := selecting_geometry(&f, w, pane)
	selecting_click(&f, w, g.selection_bar.label)
	g = selecting_geometry(&f, w, pane)
	if !testing.expect(t, c.menu && g.selection_bar.edit.width > 0) {return}
	testing.expect_value(t, ui.changes_hit(g, &pane.model.view, &pane.state, g.selection_bar.edit.x + 4,
		g.selection_bar.edit.y + 4), ui.Changes_Hit{.Label_Edit, 0, 0})

	// The row ends the selection and shows the setting.
	selecting_click(&f, w, g.selection_bar.edit)
	testing.expect_value(t, c.menu, false)
	testing.expect_value(t, c.selection.active, false)
	testing.expect_value(t, len(c.items), 0)
	row := ui.editor_row(&w.editor)
	if !testing.expect(t, row != nil, "Settings has a row selected") {return}
	// The quick labels rows are the rows named label.N; the reveal lands on the first.
	testing.expect(t, strings.has_prefix(row.key, "label."), row.key)
}

@(test)
the_note_editor_and_the_saved_card_answer_the_pointer_and_the_keyboard :: proc(t: ^testing.T) {
	f: Selecting
	defer selecting_stop(t, &f)
	if !selecting_start(t, &f, "Cards") {return}
	w, pane, ok := selecting_pane(t, &f)
	if !ok {return}
	c := &pane.comments
	view := &pane.model.view

	// Enter opens the editor under the selection's last line, at the code column, and the toolbar steps aside.
	selecting_drag(&f, w, pane, 2, 0, 2, 5)
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Enter, pressed = true})
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Enter})
	if !testing.expect_value(t, c.editing, 0) {return}
	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "Why"})
	g := selecting_geometry(&f, w, pane)
	testing.expect_value(t, g.selection_bar.bar, render.Rect{})
	parts, shown := ui.changes_editor_of(g, view, &pane.state)
	if !testing.expect(t, shown) {return}
	line := ui.changes_line_rect(g, view, &pane.state, 0, 2)
	testing.expect(t, parts.card.y > line.y + line.height)
	testing.expect_value(t, markdown.edit_string(&c.buffer), "Why")
	testing.expect_value(t, app.changes_tooltip(&f.state, w, parts.bold.x + 2, parts.bold.y + 2), "Bold")
	testing.expect_value(t, app.changes_tooltip(&f.state, w, parts.suggest.x + 2, parts.suggest.y + 2),
		"Insert the selected lines as an editable replacement")

	// Bold wraps a word at the caret; Add note saves with the pointer.
	selecting_click(&f, w, parts.bold)
	testing.expect_value(t, markdown.edit_string(&c.buffer), "Why**bold**")
	g = selecting_geometry(&f, w, pane)
	parts, _ = ui.changes_editor_of(g, view, &pane.state)
	selecting_click(&f, w, parts.save)
	if !testing.expect_value(t, len(c.items), 1) {return}
	testing.expect_value(t, c.items[0].text, "Why**bold**")
	testing.expect_value(t, c.editing, -1)

	// The saved card under the line has Edit and Remove, with their tooltips; Edit reopens the editor, and
	// Cancel leaves the note alone.
	g = selecting_geometry(&f, w, pane)
	card, found := ui.changes_card_rect(g, view, &pane.state, 0)
	if !testing.expect(t, found) {return}
	edit, remove := ui.changes_note_actions(card, w.scale)
	testing.expect_value(t, app.changes_tooltip(&f.state, w, edit.x + 2, edit.y + 2), "Edit")
	testing.expect_value(t, app.changes_tooltip(&f.state, w, remove.x + 2, remove.y + 2), "Remove")
	selecting_click(&f, w, edit)
	testing.expect_value(t, c.editing, 0)
	testing.expect_value(t, markdown.edit_string(&c.buffer), "Why**bold**")
	g = selecting_geometry(&f, w, pane)
	parts, _ = ui.changes_editor_of(g, view, &pane.state)
	selecting_click(&f, w, parts.cancel)
	testing.expect_value(t, c.editing, -1)
	testing.expect_value(t, len(c.items), 1)

	// Remove takes the note away.
	g = selecting_geometry(&f, w, pane)
	card, _ = ui.changes_card_rect(g, view, &pane.state, 0)
	_, remove = ui.changes_note_actions(card, w.scale)
	selecting_click(&f, w, remove)
	testing.expect_value(t, len(c.items), 0)
}

@(test)
ctrl_enter_saves_and_escape_cancels_the_editor_through_the_window :: proc(t: ^testing.T) {
	f: Selecting
	defer selecting_stop(t, &f)
	if !selecting_start(t, &f, "Keys") {return}
	w, pane, ok := selecting_pane(t, &f)
	if !ok {return}
	c := &pane.comments
	selecting_drag(&f, w, pane, 2, 0, 2, 5)
	// A typed character opens the editor with it.
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Q, text = "q", pressed = true})
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Q})
	testing.expect_value(t, c.editing, 0)
	testing.expect_value(t, markdown.edit_string(&c.buffer), "q")
	ctrl_enter := input.Key_Event {
		window    = w.id,
		key       = .Enter,
		modifiers = {.Control},
		pressed   = true,
	}
	app.handle_event(&f.state, ctrl_enter)
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Enter, modifiers = {.Control}})
	testing.expect_value(t, c.editing, -1)
	if !testing.expect_value(t, len(c.items), 1) {return}
	testing.expect_value(t, c.items[0].text, "q")
	// Escape drops a new note's text.
	selecting_drag(&f, w, pane, 2, 0, 2, 5)
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Enter, pressed = true})
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Enter})
	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "gone"})
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Escape, pressed = true})
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Escape})
	testing.expect_value(t, c.editing, -1)
	testing.expect_value(t, len(c.items), 1)
}
