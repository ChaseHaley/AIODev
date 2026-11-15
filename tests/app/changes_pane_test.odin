package app_test

import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:turns"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"

@(private = "file")
Fixture :: struct {
	state:     app.App,
	directory: string,
}

@(private = "file")
fixture_start :: proc(t: ^testing.T, f: ^Fixture, name: string, keep_directory := false) -> bool {
	if !keep_directory {
		directory, err := os.make_directory_temp("", "aio-changes-*", context.allocator)
		if !testing.expect_value(t, err, nil) {return false}
		f.directory = directory
		settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
		text := idle_shell_settings(t, "cursor.blink = false\n")
		if !testing.expect_value(t, os.write_entire_file(settings_path, text), nil) {return false}
	}
	f.state = {options = {data_dir = f.directory, inactive = true}}
	f.state.app_id = fmt.aprintf("AIODev.Test.Changes.%s.%d", name, os.get_pid())
	app.layout_state_enable(&f.state, strings.concatenate({f.directory, "/layout.json"}))
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	return testing.expect(t, app.app_init(&f.state))
}

@(private = "file")
changes_pane_of :: proc(state: ^app.App, w: ^app.Window) -> (layout.Pane_Rect, bool) {
	for pane in w.panes {if pane.content.kind == .Changes {return pane, true}}
	return {}, false
}

@(test)
agent_changes_opens_another_pane_on_every_run :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "Open") {return}
	w := f.state.windows[0]
	terminal := app.window_tree(w).focus
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	testing.expect_value(t, pane.scope, ui.Changes_Scope.Uncommitted)
	testing.expect_value(t, pane.agent.pane_key, f.state.sessions[0].key)
	testing.expect_value(t, pane.side_by_side, false)
	testing.expect(t, app.workspace_has_content(w.workspace, {.Changes, pane.id}))
	testing.expect_value(t, app.window_tree(w).focus != terminal, true)
	tree := app.window_tree(w)
	testing.expect_value(t, layout.find_content(tree, {.Changes, pane.id}) != layout.INVALID_NODE, true)

	// A run from an Agent changes pane opens another with its agent and scope.
	agent, cloned := app.changes_session_clone(
		{pane_key = pane.agent.pane_key, harness = "claude", session = "s1"},
	)
	if !testing.expect(t, cloned) {return}
	app.changes_session_delete(&pane.agent)
	pane.agent, pane.scope = agent, .Staged
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 2) {return}
	opened := f.state.changes_panes[1]
	testing.expect(t, app.workspace_has_content(w.workspace, {.Changes, pane.id}))
	testing.expect(t, app.workspace_has_content(w.workspace, {.Changes, opened.id}))
	testing.expect_value(t, opened.scope, ui.Changes_Scope.Staged)
	testing.expect_value(t, opened.agent.pane_key, pane.agent.pane_key)
	testing.expect_value(t, opened.agent.harness, "claude")
	testing.expect_value(t, opened.agent.session, "s1")
	testing.expect_value(t, opened.directory, pane.directory)
	focused, _ := app.window_focused_content(w)
	testing.expect_value(t, focused, layout.Content{.Changes, opened.id})
}

@(test)
layout_restore_keeps_a_changes_pane_with_its_agent_scope_and_directory :: proc(t: ^testing.T) {
	first: Fixture
	if !fixture_start(t, &first, "RestoreA") {return}
	defer delete(first.directory)
	defer testing.expect_value(t, os.remove_all(first.directory), nil)
	app.run_action(&first.state, first.state.windows[0], .Agent_Changes)
	if !testing.expect_value(t, len(first.state.changes_panes), 1) {
		app.app_destroy(&first.state)
		return
	}
	saved := first.state.changes_panes[0]
	saved.scope, saved.side_by_side = .Staged, true
	agent, cloned := app.changes_session_clone(
		{pane_key = saved.agent.pane_key, harness = "codex", session = "s9"},
	)
	if !testing.expect(t, cloned) {
		app.app_destroy(&first.state)
		return
	}
	app.changes_session_delete(&saved.agent)
	saved.agent = agent
	directory := strings.clone(saved.directory)
	pane_key := strings.clone(saved.agent.pane_key)
	defer delete(directory)
	defer delete(pane_key)
	app.layout_state_save(&first.state)
	app.app_destroy(&first.state)

	second := Fixture{directory = first.directory}
	if !fixture_start(t, &second, "RestoreB", true) {return}
	defer app.app_destroy(&second.state)
	if !testing.expect_value(t, len(second.state.changes_panes), 1) {return}
	restored := second.state.changes_panes[0]
	testing.expect_value(t, restored.scope, ui.Changes_Scope.Staged)
	testing.expect_value(t, restored.directory, directory)
	testing.expect_value(t, restored.agent.pane_key, pane_key)
	testing.expect_value(t, restored.agent.harness, "codex")
	testing.expect_value(t, restored.agent.session, "s9")
	testing.expect_value(t, restored.side_by_side, true)
	testing.expect_value(t, restored.model.view.side_by_side, true)
}

@(test)
a_new_pane_takes_the_default_diff_view_or_the_one_it_opens_from :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "DiffView") {return}
	w := f.state.windows[0]
	f.state.settings.turns.diff_view = .Side_By_Side
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	first := f.state.changes_panes[0]
	testing.expect_value(t, first.side_by_side, true)
	testing.expect_value(t, first.model.view.side_by_side, true)

	// A pane opened from an Agent changes pane copies its view, not the setting.
	first.side_by_side, first.model.view.side_by_side = false, false
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 2) {return}
	testing.expect_value(t, f.state.changes_panes[1].side_by_side, false)
}

@(test)
the_file_list_and_the_layout_toggle_keep_the_picked_file_at_the_top :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "FileList") {return}
	w := f.state.windows[0]
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}

	lines := make([]turns.Diff_Line, 60)
	defer delete(lines)
	for &line, i in lines {line = {kind = .Context, old_line = i32(i + 1), new_line = i32(i + 1), text = "line"}}
	hunks := []turns.Hunk{{old_start = 1, old_count = 60, new_start = 1, new_count = 60, lines = lines}}
	files := []turns.Diff_File {
		{old_path = "a.odin", new_path = "a.odin", hunks = hunks},
		{old_path = "b.odin", new_path = "b.odin", hunks = hunks},
		{old_path = "c.odin", new_path = "c.odin", hunks = hunks},
		{old_path = "d.odin", new_path = "d.odin", hunks = hunks},
	}
	plain := app.Result_Plain {
		pane = pane.id,
		diff = {files = files},
	}
	app.changes_fill_plain(&f.state, pane, &plain)
	view := &pane.model.view
	app.changes_model_fold(&pane.model, 2)
	testing.expect(t, view.collapsed[2])

	app.changes_file_pick(&f.state, w, pane, 2)
	testing.expect(t, !view.collapsed[2], "a picked file unfolds")
	testing.expect(t, pane.state.diff_scroll > 0)
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, ui.changes_top_file(&pane.state, view), 2)

	app.changes_layout_toggle(&f.state, w, pane)
	testing.expect_value(t, pane.side_by_side, true)
	testing.expect_value(t, view.side_by_side, true)
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, ui.changes_top_file(&pane.state, view), 2)
	app.changes_layout_toggle(&f.state, w, pane)
	testing.expect_value(t, pane.side_by_side, false)
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, ui.changes_top_file(&pane.state, view), 2)
}

@(private = "file")
files_named :: proc(paths: []string, hunks: []turns.Hunk) -> []turns.Diff_File {
	files := make([]turns.Diff_File, len(paths))
	for path, i in paths {files[i] = {old_path = path, new_path = path, hunks = hunks}}
	return files
}

@(private = "file")
tap :: proc(state: ^app.App, w: ^app.Window, key: input.Key) {
	app.handle_event(state, input.Key_Event{window = w.id, key = key, pressed = true})
	app.handle_event(state, input.Key_Event{window = w.id, key = key})
}

@(private = "file")
click :: proc(state: ^app.App, w: ^app.Window, rect: render.Rect) {
	x, y := i32(rect.x + rect.width / 2), i32(rect.y + rect.height / 2)
	for pressed in ([2]bool{true, false}) {
		event := input.Mouse_Button_Event {
			window  = w.id,
			x       = x,
			y       = y,
			button  = .Left,
			pressed = pressed,
		}
		app.handle_event(state, event)
	}
}

@(test)
an_open_file_list_takes_typed_text_and_the_comment_draft_is_kept :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "ListText") {return}
	w := f.state.windows[0]
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	lines := make([]turns.Diff_Line, 60)
	defer delete(lines)
	for &line, i in lines {line = {kind = .Context, old_line = i32(i + 1), new_line = i32(i + 1), text = "line"}}
	hunks := []turns.Hunk{{old_start = 1, old_count = 60, new_start = 1, new_count = 60, lines = lines}}
	files := files_named({"a.odin", "b.odin", "c.odin", "d.odin"}, hunks)
	defer delete(files)
	plain := app.Result_Plain {
		pane = pane.id,
		diff = {files = files},
	}
	app.changes_fill_plain(&f.state, pane, &plain)

	// A comment is being written when the file list opens.
	_ = app.changes_comments_press(&f.state, w, pane, {.Line, 0, 0}, {button = .Left})
	_ = app.changes_comments_press(&f.state, w, pane, {.Comment_Button, 0, 0}, {button = .Left})
	if !testing.expect_value(t, pane.comments.editing, 0) {return}
	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "draft"})
	testing.expect_value(t, ui.field_string(&pane.comments.editor), "draft")
	g := app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.files_button)
	if !testing.expect(t, pane.files_open, "the files button opens the list") {return}
	testing.expect_value(t, pane.comments.editing, -1)
	if !testing.expect_value(t, len(pane.comments.items), 1) {return}
	testing.expect_value(t, pane.comments.items[0].text, "draft")

	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "c.od"})
	testing.expect_value(t, ui.field_string(&pane.dropdown.search), "c.od")
	testing.expect_value(t, pane.comments.items[0].text, "draft")
	tap(&f.state, w, .Enter)
	testing.expect_value(t, pane.files_open, false)
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, ui.changes_top_file(&pane.state, &pane.model.view), 2)
}

@(test)
the_file_list_keeps_its_highlight_when_a_new_result_arrives :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "ListKeep") {return}
	w := f.state.windows[0]
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	lines := make([]turns.Diff_Line, 60)
	defer delete(lines)
	for &line, i in lines {line = {kind = .Context, old_line = i32(i + 1), new_line = i32(i + 1), text = "line"}}
	hunks := []turns.Hunk{{old_start = 1, old_count = 60, new_start = 1, new_count = 60, lines = lines}}
	four := files_named({"a.odin", "b.odin", "c.odin", "d.odin"}, hunks)
	defer delete(four)
	five := files_named({"0.odin", "a.odin", "b.odin", "c.odin", "d.odin"}, hunks)
	defer delete(five)
	first := app.Result_Plain {
		pane    = pane.id,
		request = pane.model.request,
		diff    = {files = four},
	}
	app.changes_model_result(&f.state, first)
	if !testing.expect_value(t, len(pane.model.view.files), 4) {return}

	g := app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.files_button)
	if !testing.expect(t, pane.files_open) {return}
	tap(&f.state, w, .Arrow_Down)
	tap(&f.state, w, .Arrow_Down)
	testing.expect_value(t, pane.model.file_labels[pane.dropdown.list.index], "M c.odin  +0 \u22120")

	// A live refresh lists a new file first; the highlight stays on c.odin.
	second := app.Result_Plain {
		pane    = pane.id,
		request = pane.model.request,
		diff    = {files = five},
	}
	app.changes_model_result(&f.state, second)
	if !testing.expect_value(t, len(pane.model.view.files), 5) {return}
	testing.expect(t, pane.files_open)
	testing.expect_value(t, pane.dropdown.list.index, 3)
	tap(&f.state, w, .Enter)
	testing.expect_value(t, pane.files_open, false)
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, ui.changes_top_file(&pane.state, &pane.model.view), 3)
}

@(test)
the_file_list_regex_search_matches_paths_not_labels :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "ListRegex") {return}
	w := f.state.windows[0]
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	lines := make([]turns.Diff_Line, 4)
	defer delete(lines)
	for &line, i in lines {line = {kind = .Context, old_line = i32(i + 1), new_line = i32(i + 1), text = "line"}}
	hunks := []turns.Hunk{{old_start = 1, old_count = 4, new_start = 1, new_count = 4, lines = lines}}
	files := files_named({"long.txt", "live.py", "notes.txt", "src/new.py"}, hunks)
	defer delete(files)
	files[3].old_path, files[3].status = "src/old.py", .Renamed
	plain := app.Result_Plain {
		pane = pane.id,
		diff = {files = files},
	}
	app.changes_fill_plain(&f.state, pane, &plain)
	testing.expect_value(t, pane.model.file_paths[1], "live.py")
	testing.expect_value(t, pane.model.file_paths[3], "src/old.py \u2192 src/new.py")

	g := app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.files_button)
	if !testing.expect(t, pane.files_open) {return}
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .R, modifiers = {.Alt}, pressed = true})
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .R, modifiers = {.Alt}})
	if !testing.expect(t, pane.dropdown.regex, "Alt+R turns the regular expression on") {return}
	// Anchored on the path: the labels' status mark and counts would hide every match.
	app.handle_event(&f.state, input.Text_Event{window = w.id, text = `^l.*\.py$`})
	if !testing.expect_value(t, len(pane.dropdown.matches), 1) {return}
	testing.expect_value(t, pane.dropdown.matches[0], 1)

	// A renamed file is found by its old path, as its header shows it.
	for _ in 0 ..< len(`^l.*\.py$`) {tap(&f.state, w, .Backspace)}
	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "^src/old"})
	if !testing.expect_value(t, len(pane.dropdown.matches), 1) {return}
	testing.expect_value(t, pane.dropdown.matches[0], 3)
}

@(test)
a_new_pane_takes_the_default_filter_or_the_one_it_opens_from_and_keeps_it :: proc(t: ^testing.T) {
	first: Fixture
	if !fixture_start(t, &first, "FilterA") {return}
	defer delete(first.directory)
	defer testing.expect_value(t, os.remove_all(first.directory), nil)
	w := first.state.windows[0]
	saved := app.settings_save_value(&first.state, "turns.diff_filter", "!long", "Could not save.")
	testing.expect(t, saved)
	app.run_action(&first.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(first.state.changes_panes), 1) {
		app.app_destroy(&first.state)
		return
	}
	from := first.state.changes_panes[0]
	testing.expect_value(t, app.changes_filter_text(from), "!long")
	testing.expect(t, from.model.view.filter_active)

	// A pane opened from an Agent changes pane copies its filter, not the setting.
	_ = ui.field_set(&from.filter_editor, "notes")
	app.changes_filter_changed(from)
	app.run_action(&first.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(first.state.changes_panes), 2) {
		app.app_destroy(&first.state)
		return
	}
	opened := first.state.changes_panes[1]
	testing.expect_value(t, app.changes_filter_text(opened), "notes")
	// An empty filter comes back empty, not as the setting.
	_ = ui.field_set(&opened.filter_editor, "")
	app.changes_filter_changed(opened)
	app.layout_state_save(&first.state)
	app.app_destroy(&first.state)

	second := Fixture{directory = first.directory}
	if !fixture_start(t, &second, "FilterB", true) {return}
	defer app.app_destroy(&second.state)
	testing.expect_value(t, second.state.settings.turns.diff_filter, "!long")
	if !testing.expect_value(t, len(second.state.changes_panes), 2) {return}
	texts: [2]string
	for pane, i in second.state.changes_panes {texts[i] = app.changes_filter_text(pane)}
	both := texts == [2]string{"notes", ""} || texts == [2]string{"", "notes"}
	testing.expect(t, both, "both filters come back")
}

@(test)
the_filter_popover_edits_the_filter_and_the_bar_clears_it :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "FilterEdit") {return}
	w := f.state.windows[0]
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	view := &pane.model.view
	lines := make([]turns.Diff_Line, 60)
	defer delete(lines)
	for &line, i in lines {line = {kind = .Context, old_line = i32(i + 1), new_line = i32(i + 1), text = "line"}}
	hunks := []turns.Hunk{{old_start = 1, old_count = 60, new_start = 1, new_count = 60, lines = lines}}
	files := files_named({"a.odin", "b.odin", "c.odin", "d.odin"}, hunks)
	defer delete(files)
	plain := app.Result_Plain {
		pane = pane.id,
		diff = {files = files},
	}
	app.changes_fill_plain(&f.state, pane, &plain)

	g := app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.filter_button)
	if !testing.expect(t, pane.state.filter_open, "the filter button opens the popover") {return}
	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "!b.od"})
	testing.expect_value(t, app.changes_filter_text(pane), "!b.od")
	testing.expect_value(t, view.hidden_count, 1)
	testing.expect_value(t, len(view.files), 3)
	tap(&f.state, w, .Escape)
	testing.expect(t, !pane.state.filter_open)
	testing.expect_value(t, app.changes_filter_text(pane), "!b.od")

	// Picking the hidden file from the list shows it at the top.
	app.changes_file_pick(&f.state, w, pane, 1)
	testing.expect_value(t, len(view.files), 4)
	testing.expect_value(t, view.hidden_count, 0)
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, ui.changes_top_file(&pane.state, view), 1)

	// Editing the filter hides it again.
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.filter_button)
	if !testing.expect(t, pane.state.filter_open) {return}
	tap(&f.state, w, .Backspace)
	testing.expect_value(t, app.changes_filter_text(pane), "!b.o")
	testing.expect_value(t, len(view.files), 3)
	tap(&f.state, w, .Enter)
	testing.expect(t, !pane.state.filter_open)

	g = app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.filter_bar_clear)
	testing.expect_value(t, app.changes_filter_text(pane), "")
	testing.expect_value(t, view.hidden_count, 0)
	testing.expect_value(t, len(view.files), 4)
}

@(test)
turn_settings_default_to_off_two_weeks_unified_and_no_filter :: proc(t: ^testing.T) {
	s, d, err := settings.parse("")
	testing.expect_value(t, err, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, s.turns.record, false)
	testing.expect_value(t, s.turns.retention_days, 14)
	testing.expect_value(t, s.turns.diff_view, settings.Diff_View.Unified)
	testing.expect_value(t, s.turns.diff_filter, "")
	side, side_diagnostics, side_error := settings.parse("turns.diff_view = side_by_side\n")
	testing.expect_value(t, side_error, nil)
	defer settings.destroy(&side)
	defer settings.diagnostics_destroy(&side_diagnostics)
	testing.expect_value(t, side.turns.diff_view, settings.Diff_View.Side_By_Side)
}

@(test)
the_record_button_turns_recording_on :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "Record") {return}
	testing.expect(t, !f.state.settings.turns.record)
	app.run_action(&f.state, f.state.windows[0], .Agent_Changes)
	f.state.changes_panes[0].scope = .Agent
	app.changes_model_changed(&f.state, f.state.changes_panes[0])
	testing.expect_value(t, f.state.changes_panes[0].model.view.notice, ui.Changes_Notice.Recording_Off)
	testing.expect(t, app.settings_save_value(&f.state, "turns.record", "true", "Could not turn on turn recording."))
	testing.expect(t, f.state.settings.turns.record)
	app.changes_model_changed(&f.state, f.state.changes_panes[0])
	testing.expect(t, f.state.changes_panes[0].model.view.notice != ui.Changes_Notice.Recording_Off)
}
