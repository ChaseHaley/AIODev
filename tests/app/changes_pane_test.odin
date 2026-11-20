package app_test

import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:markdown"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:turns"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
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
	_ = app.changes_comments_press(&f.state, w, pane, {.Gutter, 0, 0}, {button = .Left})
	_ = app.changes_comments_press(&f.state, w, pane, {.Toolbar_Comment, 0, 0}, {button = .Left})
	if !testing.expect_value(t, pane.comments.editing, 0) {return}
	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "draft"})
	testing.expect_value(t, markdown.edit_string(&pane.comments.buffer), "draft")
	g := app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.files_button)
	if !testing.expect(t, pane.state.files_open, "the files button opens the file list") {return}
	testing.expect_value(t, pane.comments.editing, -1)
	if !testing.expect_value(t, len(pane.comments.items), 1) {return}
	testing.expect_value(t, pane.comments.items[0].text, "draft")

	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "c.od"})
	testing.expect_value(t, ui.field_string(&pane.dropdown.search), "c.od")
	testing.expect_value(t, pane.comments.items[0].text, "draft")
	tap(&f.state, w, .Enter)
	testing.expect_value(t, pane.state.files_open, false)
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
	if !testing.expect(t, pane.state.files_open) {return}
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
	testing.expect(t, pane.state.files_open)
	testing.expect_value(t, pane.dropdown.list.index, 3)
	tap(&f.state, w, .Enter)
	testing.expect_value(t, pane.state.files_open, false)
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, ui.changes_top_file(&pane.state, &pane.model.view), 3)
}

@(test)
fold_all_and_the_sticky_header_keep_the_file_at_the_top :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "FoldAll") {return}
	w := f.state.windows[0]
	app.window_resize(&f.state, w, 2400, 900)
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
	names: [60]string
	for &name, i in names {name = fmt.tprintf("file_%02d.odin", i)}
	files := files_named(names[:], hunks)
	defer delete(files)
	plain := app.Result_Plain {
		pane = pane.id,
		diff = {files = files},
	}
	app.changes_fill_plain(&f.state, pane, &plain)
	testing.expect(t, view.any_expanded)
	top_of :: proc(f: ^Fixture, w: ^app.Window, pane: ^app.Changes_Pane, shown: layout.Pane_Rect) -> int {
		_ = app.changes_geometry_of(&f.state, w, pane, shown)
		return ui.changes_top_file(&pane.state, &pane.model.view)
	}

	// Collapsing every file keeps the file at the top there; expanding brings it back the same way.
	app.changes_file_pick(&f.state, w, pane, 20)
	testing.expect_value(t, top_of(&f, w, pane, shown), 20)
	g := app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.fold_button)
	for folded, i in view.collapsed {testing.expectf(t, folded, "file %d collapses", i)}
	testing.expect(t, !view.any_expanded)
	testing.expect_value(t, top_of(&f, w, pane, shown), 20)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.fold_button)
	for folded, i in view.collapsed {testing.expectf(t, !folded, "file %d expands", i)}
	testing.expect(t, view.any_expanded)
	testing.expect_value(t, top_of(&f, w, pane, shown), 20)

	// Collapsing from the pinned header puts that file's header at the top.
	pane.state.diff_scroll = ui.changes_diff_file_top(&pane.state, view, 20) + 300
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	sticky, sticky_rect := ui.changes_sticky_header(&pane.state, view, g)
	if !testing.expect_value(t, sticky, 20) {return}
	click(&f.state, w, sticky_rect)
	testing.expect(t, view.collapsed[20])
	testing.expect_value(t, top_of(&f, w, pane, shown), 20)
	testing.expect_value(t, pane.state.diff_scroll, ui.changes_diff_file_top(&pane.state, view, 20))
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	sticky, _ = ui.changes_sticky_header(&pane.state, view, g)
	testing.expect_value(t, sticky, -1)
	// The file's own header, now under the pointer, keeps the hover the pinned one had.
	testing.expect_value(t, pane.state.hover, ui.Changes_Hit{.File_Header, 20, 0})
	testing.expect_value(t, pane.state.lit, ui.Changes_Hit{.File_Header, 20, 0})

	// A header in its own place collapses without moving the diff.
	pane.state.diff_scroll = ui.changes_diff_file_top(&pane.state, view, 2) - 100
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	before := pane.state.diff_scroll
	click(&f.state, w, {g.diff.x + 40, g.diff.y + 102, 10, 4})
	testing.expect(t, view.collapsed[2], "the header in place collapses")
	testing.expect_value(t, pane.state.diff_scroll, before)

	// A page leaves out the row a pinned header covers.
	pane.state.diff_scroll = ui.changes_diff_file_top(&pane.state, view, 10)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	before = pane.state.diff_scroll
	tap(&f.state, w, .Page_Down)
	testing.expect_value(t, pane.state.diff_scroll, before + int(g.diff.height) - pane.state.rows.header)
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
	if !testing.expect(t, pane.state.files_open) {return}
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
	app.window_resize(&f.state, w, 2400, 900)
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
turn_settings_default_to_off_two_weeks_unified_no_filter_and_4_5_contrast :: proc(t: ^testing.T) {
	s, d, err := settings.parse("")
	testing.expect_value(t, err, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, s.turns.record, false)
	testing.expect_value(t, s.turns.retention_days, 14)
	testing.expect_value(t, s.turns.diff_view, settings.Diff_View.Unified)
	testing.expect_value(t, s.turns.diff_filter, "")
	testing.expect_value(t, s.turns.diff_minimum_contrast, 4.5)
	side, side_diagnostics, side_error := settings.parse("turns.diff_view = side_by_side\n")
	testing.expect_value(t, side_error, nil)
	defer settings.destroy(&side)
	defer settings.diagnostics_destroy(&side_diagnostics)
	testing.expect_value(t, side.turns.diff_view, settings.Diff_View.Side_By_Side)
	// A contrast past 21 is refused and the default stays.
	high, high_diagnostics, high_error := settings.parse("turns.diff_minimum_contrast = 30\n")
	testing.expect_value(t, high_error, nil)
	defer settings.destroy(&high)
	defer settings.diagnostics_destroy(&high_diagnostics)
	testing.expect_value(t, high.turns.diff_minimum_contrast, 4.5)
	testing.expect(t, len(high_diagnostics) > 0, "the refused value is reported")
	one, one_diagnostics, one_error := settings.parse("turns.diff_minimum_contrast = 1\n")
	testing.expect_value(t, one_error, nil)
	defer settings.destroy(&one)
	defer settings.diagnostics_destroy(&one_diagnostics)
	testing.expect_value(t, one.turns.diff_minimum_contrast, 1)
}

@(test)
the_diff_carries_the_minimum_contrast_setting_into_the_next_frame :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "Contrast") {return}
	w := f.state.windows[0]
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, pane.model.view.minimum_contrast, 4.5)
	saved := app.settings_save_value(&f.state, "turns.diff_minimum_contrast", "7", "Could not save.")
	testing.expect(t, saved)
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, pane.model.view.minimum_contrast, 7)
}

@(test)
the_long_lines_setting_picks_wrap_or_scroll_and_open_panes_follow_it :: proc(t: ^testing.T) {
	s, d, err := settings.parse("")
	testing.expect_value(t, err, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, s.turns.diff_long_lines, settings.Long_Lines.Scroll)
	wrap, wrap_diagnostics, wrap_error := settings.parse("turns.diff_long_lines = wrap\n")
	testing.expect_value(t, wrap_error, nil)
	defer settings.destroy(&wrap)
	defer settings.diagnostics_destroy(&wrap_diagnostics)
	testing.expect_value(t, wrap.turns.diff_long_lines, settings.Long_Lines.Wrap)
	bad, bad_diagnostics, bad_error := settings.parse("turns.diff_long_lines = fade\n")
	testing.expect_value(t, bad_error, nil)
	defer settings.destroy(&bad)
	defer settings.diagnostics_destroy(&bad_diagnostics)
	testing.expect_value(t, bad.turns.diff_long_lines, settings.Long_Lines.Scroll)
	testing.expect(t, len(bad_diagnostics) > 0, "the refused value is reported")

	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "LongLines") {return}
	w := f.state.windows[0]
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, pane.model.view.wrap, false)
	testing.expect(t, app.settings_save_value(&f.state, "turns.diff_long_lines", "wrap", "Could not save."))
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, pane.model.view.wrap, true)
	testing.expect_value(t, pane.state.rows.wrapped, true)
}

@(private = "file")
tooltip_at :: proc(f: ^Fixture, w: ^app.Window, rect: render.Rect) -> string {
	return app.changes_tooltip(&f.state, w, rect.x + rect.width / 2, rect.y + rect.height / 2)
}

@(private = "file")
key_at :: proc(f: ^Fixture, w: ^app.Window, rect: render.Rect) -> commands.Shortcut {
	shortcut := app.changes_shortcut(&f.state, w, rect.x + rect.width / 2, rect.y + rect.height / 2)
	key, _ := shortcut.(commands.Shortcut)
	return key
}

@(test)
every_control_says_what_it_does :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "Tooltips") {return}
	w := f.state.windows[0]
	app.window_resize(&f.state, w, 2400, 900)
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	view := &pane.model.view
	pane.scope, view.scope = .Repository, .Repository
	// With no files the fold and files buttons are off; they still say what they do.
	empty := app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, len(view.files), 0)
	testing.expect_value(t, tooltip_at(&f, w, empty.fold_button), "Expand all files")
	testing.expect_value(t, tooltip_at(&f, w, empty.layout_button), "Side-by-side view")
	testing.expect_value(t, tooltip_at(&f, w, empty.filter_button), "Filter files")
	// The files button names its list; the summary opens the panel, and names the key that does.
	testing.expect_value(t, tooltip_at(&f, w, empty.files_button), "Files in this diff")
	testing.expect_value(t, tooltip_at(&f, w, empty.summary), "Source and turns")
	testing.expect_value(t, key_at(&f, w, empty.summary), commands.Shortcut{.K, {.Control}})
	lines := make([]turns.Diff_Line, 4)
	defer delete(lines)
	for &line, i in lines {line = {kind = .Context, old_line = i32(i + 1), new_line = i32(i + 1), text = "line"}}
	hunks := []turns.Hunk{{old_start = 1, old_count = 4, new_start = 1, new_count = 4, lines = lines}}
	files := files_named({"a.odin", "b.odin"}, hunks)
	defer delete(files)
	rows := []app.Turn_Row{{id = 3, kind = .Turn, ended = 3}, {id = 2, kind = .Turn, ended = 2}, {id = 1, ended = 1}}
	q := app.Result_Query {
		pane     = pane.id,
		rows     = rows,
		selected = {3},
		diff     = {files = files},
	}
	app.changes_fill_query(&f.state, pane, &q, time.now(), true)

	g := app.changes_geometry_of(&f.state, w, pane, shown)
	// The strip, its steps and the chips are the panel's: they have tooltips while it is open.
	pane.state.panel_open = true
	testing.expect_value(t, tooltip_at(&f, w, g.step_back), "Older turn")
	testing.expect_value(t, key_at(&f, w, g.step_back), commands.Shortcut{.Arrow_Left, {}})
	// The newest turn is selected, so the newer step is off; it still says what it does.
	testing.expect_value(t, tooltip_at(&f, w, g.step_forward), "Newer turn")
	testing.expect_value(t, key_at(&f, w, g.step_forward), commands.Shortcut{.Arrow_Right, {}})
	testing.expect_value(t, tooltip_at(&f, w, g.range_label), "Choose turns")
	testing.expect_value(t, tooltip_at(&f, w, g.source_chips[0]), pane.model.sources[0])
	testing.expect(t, g.overview.width > 0)
	testing.expect_value(t, tooltip_at(&f, w, g.overview), "Overview: click or drag to scroll")
	header := render.Rect{g.diff.x + 600, g.diff.y + 2, 4, 4}
	testing.expect_value(t, tooltip_at(&f, w, header), "Collapse file")
	app.changes_model_fold(&pane.model, 0)
	_ = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, tooltip_at(&f, w, header), "Expand file")
	app.changes_model_fold(&pane.model, 0)

	// The send bar of a written comment.
	_ = app.changes_comments_press(&f.state, w, pane, {.Gutter, 0, 0}, {button = .Left})
	_ = app.changes_comments_press(&f.state, w, pane, {.Toolbar_Comment, 0, 0}, {button = .Left})
	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "note"})
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Enter, modifiers = {.Control}, pressed = true})
	if !testing.expect_value(t, len(pane.comments.items), 1) {return}
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	send, copy_rect, discard := ui.changes_send_rects(g, view)
	testing.expect(t, !view.send.can_send, "a shell is not an agent")
	testing.expect_value(t, tooltip_at(&f, w, send), view.send.reason)
	testing.expect(t, view.send.reason != "")
	testing.expect_value(t, tooltip_at(&f, w, copy_rect), "Copy the notes")
	testing.expect_value(t, tooltip_at(&f, w, discard), "Discard the notes")

	// The filter's clear buttons, in its field and in the bar.
	_ = ui.field_set(&pane.filter_editor, "zzz")
	app.changes_filter_changed(pane)
	pane.state.filter_open = true
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, tooltip_at(&f, w, g.filter_clear), "Clear the filter")
	// A press outside the open popover only closes it, so nothing out there has a tooltip.
	testing.expect_value(t, tooltip_at(&f, w, g.step_back), "")
	testing.expect_value(t, tooltip_at(&f, w, g.filter_button), "")
	pane.state.filter_open = false
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, tooltip_at(&f, w, g.filter_bar_clear), "Clear the filter")
	testing.expect_value(t, tooltip_at(&f, w, g.filter_button), "Filter files")
	// Nor outside the open turn list, except on the range label that closes it.
	pane.state.turn_list_open = true
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, tooltip_at(&f, w, g.files_button), "")
	testing.expect_value(t, tooltip_at(&f, w, g.range_label), "Choose turns")
	pane.state.turn_list_open = false
}

@(test)
the_strip_markers_page_through_turns_it_cannot_show :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "StripPage") {return}
	w := f.state.windows[0]
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	// Wide enough for the strip's ten bars beside the toolbar's other controls.
	app.window_resize(&f.state, w, 2400, 900)
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	view := &pane.model.view
	pane.scope, view.scope = .Repository, .Repository
	rows: [25]app.Turn_Row
	for &row, i in rows {row = {id = u64(25 - i), kind = .Turn, ended = i64(25 - i)}}
	files := files_named({"a.odin"}, nil)
	defer delete(files)
	// Delivered as the worker would, so the strip shows the newest turn the result selects.
	q := app.Result_Query {
		pane     = pane.id,
		request  = pane.model.request,
		rows     = rows[:],
		selected = {25},
		diff     = {files = files},
	}
	app.changes_model_result(&f.state, q)
	if !testing.expect_value(t, len(view.turns), 25) {return}
	// The strip lives in the panel: the summary opens it, and the strip's own markers still answer first.
	opening := app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, opening.summary)
	testing.expect(t, pane.state.panel_open && !pane.state.files_open)

	g := app.changes_geometry_of(&f.state, w, pane, shown)
	marker :: proc(g: ui.Changes_Geometry, pane: ^app.Changes_Pane, newer: bool) -> render.Rect {
		return ui.changes_strip_marker_rect(g, &pane.state, &pane.model.view, newer)
	}
	testing.expect_value(t, g.strip_bars, 10)
	older, newer := ui.changes_strip_hidden(g, &pane.state, view)
	testing.expect_value(t, older, 15)
	testing.expect_value(t, newer, 0)
	testing.expect(t, marker(g, pane, true) == (render.Rect{}), "no newer marker while the newest bar shows")
	testing.expect_value(t, tooltip_at(&f, w, marker(g, pane, false)), "15 older turns")

	// A press pages to the older bars, ending next to the page it came from, and leaves the selection.
	from := older
	click(&f.state, w, marker(g, pane, false))
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	older, newer = ui.changes_strip_hidden(g, &pane.state, view)
	testing.expect_value(t, older + g.strip_bars, from)
	testing.expect_value(t, newer, 25 - older - g.strip_bars)
	testing.expect(t, marker(g, pane, true) != (render.Rect{}), "the newer marker appears")
	testing.expect_value(t, tooltip_at(&f, w, marker(g, pane, true)), fmt.tprintf("%d newer turns", newer))
	testing.expect_value(t, view.first, 0)
	testing.expect_value(t, view.last, 0)
	click(&f.state, w, marker(g, pane, false))
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	older, newer = ui.changes_strip_hidden(g, &pane.state, view)
	testing.expect_value(t, older, 0)
	testing.expect_value(t, newer, 25 - g.strip_bars)
	testing.expect(t, marker(g, pane, false) == (render.Rect{}), "no older marker at the oldest bar")
	// A newer page starts right after the page it came from.
	shown_bars := g.strip_bars
	click(&f.state, w, marker(g, pane, true))
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	older, newer = ui.changes_strip_hidden(g, &pane.state, view)
	testing.expect_value(t, older, shown_bars)
	testing.expect_value(t, tooltip_at(&f, w, marker(g, pane, true)), fmt.tprintf("%d newer turns", newer))

	// Escape closes the panel; with it closed the keys step turns.
	tap(&f.state, w, .Escape)
	testing.expect(t, !pane.state.panel_open && !pane.state.files_open)
	// The arrow keys the step tooltips name move the selection.
	tap(&f.state, w, .Arrow_Left)
	testing.expect_value(t, view.first, 1)
	tap(&f.state, w, .Arrow_Right)
	testing.expect_value(t, view.first, 0)

	// At any width, an older page ends next to the page it came from.
	for width in ([?]i32{900, 1100, 1300, 1500, 1800, 2100}) {
		app.window_resize(&f.state, w, width, 900)
		shown, found = changes_pane_of(&f.state, w)
		if !found {continue}
		pane.state.strip_offset, pane.state.panel_open = 25, true
		g = app.changes_geometry_of(&f.state, w, pane, shown)
		before, _ := ui.changes_strip_hidden(g, &pane.state, view)
		older_marker := marker(g, pane, false)
		if older_marker == (render.Rect{}) {continue}
		click(&f.state, w, older_marker)
		g = app.changes_geometry_of(&f.state, w, pane, shown)
		after, _ := ui.changes_strip_hidden(g, &pane.state, view)
		testing.expectf(t, after == max(0, before - g.strip_bars), "width %d: %d then %d", width, before, after)
	}
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

@(private = "file")
chord :: proc(state: ^app.App, w: ^app.Window, key: input.Key, modifiers: input.Modifiers) {
	app.handle_event(state, input.Key_Event{window = w.id, key = key, modifiers = modifiers, pressed = true})
	app.handle_event(state, input.Key_Event{window = w.id, key = key, modifiers = modifiers})
}

// Four 60-line files in a git scope with two worktrees, borrowed by the pane: the caller keeps `lines` and
// `hunks` alive and deletes the returned files.
@(private = "file")
fill_four_files :: proc(
	f: ^Fixture,
	pane: ^app.Changes_Pane,
	lines: []turns.Diff_Line,
	hunks: ^[1]turns.Hunk,
) -> []turns.Diff_File {
	for &line, i in lines {line = {kind = .Context, old_line = i32(i + 1), new_line = i32(i + 1), text = "line"}}
	hunks^ = {{old_start = 1, old_count = 60, new_start = 1, new_count = 60, lines = lines}}
	files := files_named({"a.odin", "b.odin", "c.odin", "d.odin"}, hunks[:])
	plain := app.Result_Plain {
		pane      = pane.id,
		worktree  = "C:/work/wt-a",
		worktrees = {"C:/work/wt-a", "C:/work/wt-b"},
		diff      = {files = files},
	}
	app.changes_fill_plain(&f.state, pane, &plain)
	return files
}

@(test)
the_panel_opens_from_the_summary_and_ctrl_k_and_the_files_button_opens_the_list :: proc(
	t: ^testing.T,
) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "Panel") {return}
	w := f.state.windows[0]
	app.window_resize(&f.state, w, 2400, 900)
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	lines := make([]turns.Diff_Line, 60)
	defer delete(lines)
	hunks: [1]turns.Hunk
	files := fill_four_files(&f, pane, lines, &hunks)
	defer delete(files)
	view := &pane.model.view
	state := &pane.state

	// The summary opens the panel, with no file list; a second click on it closes it, and Escape does too.
	g := app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.summary)
	testing.expect(t, state.panel_open && !state.files_open)
	click(&f.state, w, g.summary)
	testing.expect(t, !state.panel_open)
	click(&f.state, w, g.summary)
	tap(&f.state, w, .Escape)
	testing.expect(t, !state.panel_open)

	// Ctrl+K toggles it while the pane is focused.
	chord(&f.state, w, .K, {.Control})
	testing.expect(t, state.panel_open && !state.files_open)
	chord(&f.state, w, .K, {.Control})
	testing.expect(t, !state.panel_open)

	// The files button opens the file list instead, which excludes the panel: a press on the files button
	// again, or outside the list, only closes it, and Escape does too.
	click(&f.state, w, g.files_button)
	testing.expect(t, state.files_open && !state.panel_open)
	click(&f.state, w, g.files_button)
	testing.expect(t, !state.files_open && !state.panel_open)
	click(&f.state, w, g.files_button)
	tap(&f.state, w, .Escape)
	testing.expect(t, !state.files_open && !state.panel_open)
	click(&f.state, w, g.files_button)
	click(&f.state, w, {g.diff.x + 10, g.diff.y + 400, 4, 4})
	testing.expect(t, !state.files_open && !state.panel_open)
	// Ctrl+K swaps the list for the panel.
	click(&f.state, w, g.files_button)
	chord(&f.state, w, .K, {.Control})
	testing.expect(t, state.panel_open && !state.files_open)
	// A press on the files button while the panel is open only closes the panel, as outside presses do.
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.files_button)
	testing.expect(t, !state.panel_open && !state.files_open)
	click(&f.state, w, g.files_button)
	testing.expect(t, state.files_open && !state.panel_open)
	tap(&f.state, w, .Escape)

	// A press outside the panel only closes it: the header it lands on does not fold.
	chord(&f.state, w, .K, {.Control})
	click(&f.state, w, {g.diff.x + 600, g.diff.y + 5, 4, 4})
	testing.expect(t, !state.panel_open && !state.files_open)
	testing.expect(t, !view.collapsed[0])

	// The overlays exclude each other: a press on the filter button only closes the panel, and opening the
	// popover then Ctrl+K swaps it for the panel.
	chord(&f.state, w, .K, {.Control})
	click(&f.state, w, g.filter_button)
	testing.expect(t, !state.panel_open && !state.filter_open)
	click(&f.state, w, g.filter_button)
	testing.expect(t, state.filter_open && !state.panel_open)
	chord(&f.state, w, .K, {.Control})
	testing.expect(t, state.panel_open && !state.filter_open)
	tap(&f.state, w, .Escape)

	// Without files the files button opens nothing.
	empty := app.Result_Plain {
		pane = pane.id,
	}
	app.changes_fill_plain(&f.state, pane, &empty)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.files_button)
	testing.expect(t, !state.files_open)
	chord(&f.state, w, .K, {.Control})
	testing.expect(t, state.panel_open)
	tap(&f.state, w, .Escape)
	testing.expect(t, !state.panel_open)
}

@(test)
the_chips_choose_the_source_and_the_worktree_and_leave_the_panel_open :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "Chips") {return}
	w := f.state.windows[0]
	app.window_resize(&f.state, w, 2400, 900)
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	lines := make([]turns.Diff_Line, 60)
	defer delete(lines)
	hunks: [1]turns.Hunk
	files := fill_four_files(&f, pane, lines, &hunks)
	defer delete(files)
	view := &pane.model.view

	// No agent is listed, so the chips are the four scopes; Uncommitted is the pane's own.
	g := app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.summary)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	if !testing.expect_value(t, len(g.source_chips), 4) {return}
	testing.expect_value(t, view.source_current, 1)
	// Picking a chip is what choosing in the old dropdown was, and the panel stays open.
	click(&f.state, w, g.source_chips[2])
	testing.expect_value(t, pane.scope, ui.Changes_Scope.Staged)
	testing.expect(t, pane.state.panel_open)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, view.source_current, 2)
	click(&f.state, w, g.source_chips[0])
	testing.expect_value(t, pane.scope, ui.Changes_Scope.Repository)
	testing.expect(t, pane.state.panel_open)
	click(&f.state, w, g.source_chips[1])
	testing.expect_value(t, pane.scope, ui.Changes_Scope.Uncommitted)

	// The worktree chips: Follow the agent first, then each worktree.
	pane.scope = .Staged
	previous := files
	files = fill_four_files(&f, pane, lines, &hunks)
	delete(previous)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	if !testing.expect_value(t, len(g.worktree_chips), 3) {return}
	testing.expect_value(t, view.worktree_current, 0)
	click(&f.state, w, g.worktree_chips[2])
	testing.expect_value(t, pane.worktree_pick, "C:/work/wt-b")
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect_value(t, view.worktree_current, 2)
	testing.expect(t, pane.state.panel_open)
	click(&f.state, w, g.worktree_chips[0])
	testing.expect_value(t, pane.worktree_pick, "")
}

@(test)
the_tools_menu_holds_the_view_buttons_when_the_row_runs_out_of_room :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "Tools") {return}
	w := f.state.windows[0]
	app.window_resize(&f.state, w, 700, 900)
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	lines := make([]turns.Diff_Line, 60)
	defer delete(lines)
	hunks: [1]turns.Hunk
	files := fill_four_files(&f, pane, lines, &hunks)
	defer delete(files)
	view := &pane.model.view
	state := &pane.state

	// Narrow the window until the row has given up its buttons.
	g := app.changes_geometry_of(&f.state, w, pane, shown)
	for width in ([?]i32{600, 500, 400, 320}) {
		if g.row_steps >= 1 {break}
		app.window_resize(&f.state, w, width, 900)
		shown, found = changes_pane_of(&f.state, w)
		if !testing.expect(t, found) {return}
		g = app.changes_geometry_of(&f.state, w, pane, shown)
	}
	if !testing.expect(t, g.row_steps >= 1 && g.tools_button.width > 0) {return}
	testing.expect_value(t, g.layout_button, render.Rect{})

	// The Side-by-side row toggles the layout and the menu closes with it.
	click(&f.state, w, g.tools_button)
	testing.expect(t, state.tools_open)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.tools_rows[0])
	testing.expect(t, pane.side_by_side && !state.tools_open)

	// Escape closes it without acting; so does a press outside.
	click(&f.state, w, g.tools_button)
	testing.expect(t, state.tools_open)
	tap(&f.state, w, .Escape)
	testing.expect(t, !state.tools_open && pane.side_by_side)
	click(&f.state, w, g.tools_button)
	click(&f.state, w, {g.diff.x + 10, g.diff.y + 5, 4, 4})
	testing.expect(t, !state.tools_open && !view.collapsed[0])

	// The fold row folds every file.
	click(&f.state, w, g.tools_button)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.tools_rows[1])
	testing.expect(t, !view.any_expanded && !state.tools_open)

	// Filter files… opens the popover under the ⋯ button and closes the menu.
	click(&f.state, w, g.tools_button)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.tools_rows[2])
	testing.expect(t, state.filter_open && !state.tools_open)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	testing.expect(t, g.filter_popover.width > 0 && g.filter_button.width == 0)
}

// Holding a press on the overview strip's track pages the diff toward the pointer, as every scrollbar's
// does: once at the press, then repeatedly until the thumb is under the pointer, retargeting as the pointer
// moves, pausing off the track and stopping at the release.
@(test)
a_held_press_on_the_overview_track_keeps_paging_until_the_thumb_meets_the_pointer :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "OverviewHold") {return}
	w := f.state.windows[0]
	app.window_resize(&f.state, w, 2400, 900)
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	lines := make([]turns.Diff_Line, 60)
	defer delete(lines)
	hunks: [1]turns.Hunk
	files := fill_four_files(&f, pane, lines, &hunks)
	defer delete(files)

	g := app.changes_geometry_of(&f.state, w, pane, shown)
	lane := g.overview
	total, visible := pane.state.rows.total, int(g.diff.height)
	if !testing.expect(t, lane.width > 0 && total > 3 * visible) {return}
	limit := total - visible
	x := i32(lane.x + lane.width / 2)
	middle := i32(lane.y + lane.height / 2)
	top, bottom := i32(lane.y + 2), i32(lane.y + lane.height - 2)
	button :: proc(w: ^app.Window, x, y: i32, pressed: bool) -> input.Mouse_Button_Event {
		return {window = w.id, x = x, y = y, button = .Left, pressed = pressed}
	}
	move :: proc(w: ^app.Window, x, y: i32) -> input.Mouse_Move_Event {
		return {window = w.id, x = x, y = y, buttons = {.Left}}
	}

	// The press pages once toward the pointer (down, from the top) and holds the track.
	app.handle_event(&f.state, button(w, x, middle, true))
	testing.expect_value(t, pane.state.diff_scroll, visible)
	testing.expect_value(t, w.scroll_hold.bar, app.Scroll_Hold_Bar.Changes_Overview)
	testing.expect(t, !pane.state.overview_drag.active)

	// One page per repeat, until the thumb is under the pointer; then it stops with the press held.
	previous, pages := pane.state.diff_scroll, 0
	for pages < 40 {
		if !hold_repeat(&f.state, w) {break}
		current := pane.state.diff_scroll
		if current == previous {break}
		testing.expect_value(t, current - previous, visible)
		previous = current
		pages += 1
	}
	testing.expect(t, pages >= 1 && pages < 40)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	thumb := ui.changes_overview_thumb(&pane.state, g)
	testing.expect(t, f32(middle) >= thumb.y && f32(middle) < thumb.y + thumb.height)
	_ = hold_repeat(&f.state, w)
	testing.expect_value(t, pane.state.diff_scroll, previous)

	// The press began below the thumb, so the pointer crossing above it pauses rather than reverses the
	// paging, off the lane it pauses too, and back below the thumb it resumes down to the end.
	app.handle_event(&f.state, move(w, x, top))
	for _ in 0 ..< 10 {_ = hold_repeat(&f.state, w)}
	testing.expect_value(t, pane.state.diff_scroll, previous)
	app.handle_event(&f.state, move(w, i32(lane.x - 40), bottom))
	for _ in 0 ..< 10 {_ = hold_repeat(&f.state, w)}
	testing.expect_value(t, pane.state.diff_scroll, previous)
	app.handle_event(&f.state, move(w, x, bottom))
	for _ in 0 ..< 60 {_ = hold_repeat(&f.state, w)}
	testing.expect_value(t, pane.state.diff_scroll, limit)

	// The release ends it.
	app.handle_event(&f.state, button(w, x, bottom, false))
	testing.expect_value(t, w.scroll_hold.bar, app.Scroll_Hold_Bar.None)
	testing.expect(t, !hold_repeat(&f.state, w))
	testing.expect_value(t, pane.state.diff_scroll, limit)
}

@(test)
the_overview_strip_scrolls_the_diff_by_press_and_drag :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "Overview") {return}
	w := f.state.windows[0]
	app.window_resize(&f.state, w, 2400, 900)
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	lines := make([]turns.Diff_Line, 60)
	defer delete(lines)
	hunks: [1]turns.Hunk
	files := fill_four_files(&f, pane, lines, &hunks)
	defer delete(files)

	g := app.changes_geometry_of(&f.state, w, pane, shown)
	lane := g.overview
	if !testing.expect(t, lane.width > 0) {return}
	total, visible := pane.state.rows.total, int(g.diff.height)
	if !testing.expect(t, total > 2 * visible) {return}
	testing.expect_value(t, pane.state.diff_scroll, 0)

	// A press on the track below the thumb pages one view toward the pointer and holds nothing, as every
	// scrollbar's track press does.
	click(&f.state, w, {lane.x, lane.y + lane.height * 0.75 - 2, lane.width, 4})
	testing.expect(t, !pane.state.overview_drag.active)
	testing.expect_value(t, pane.state.diff_scroll, visible)

	// A press on the thumb holds it where it was grabbed, and moving the pointer scrolls by its distance.
	pane.state.diff_scroll = 0
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	thumb := ui.changes_overview_thumb(&pane.state, g)
	testing.expect(t, thumb.height >= 24)
	x, y := i32(lane.x + lane.width / 2), i32(lane.y + 3)
	app.handle_event(&f.state, input.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left, pressed = true})
	testing.expect(t, pane.state.overview_drag.active)
	testing.expect_value(t, pane.state.diff_scroll, 0)
	app.handle_event(&f.state, input.Mouse_Move_Event{window = w.id, x = x, y = y + 40, buttons = {.Left}})
	moved := pane.state.diff_scroll
	per_dip := f32(total - visible) / (lane.height - thumb.height)
	testing.expect(t, abs(f32(moved) - 40 * per_dip) <= per_dip + 2)
	app.handle_event(&f.state, input.Mouse_Button_Event{window = w.id, x = x, y = y + 40, button = .Left})
	testing.expect(t, !pane.state.overview_drag.active)
	// Released, moving no longer scrolls.
	app.handle_event(&f.state, input.Mouse_Move_Event{window = w.id, x = x, y = y + 80})
	testing.expect_value(t, pane.state.diff_scroll, moved)
}

@(test)
the_turn_list_steps_in_front_of_the_file_list_and_gives_it_back :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "TurnList") {return}
	w := f.state.windows[0]
	app.window_resize(&f.state, w, 2400, 900)
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	view := &pane.model.view
	pane.scope, view.scope = .Repository, .Repository
	lines := make([]turns.Diff_Line, 4)
	defer delete(lines)
	for &line, i in lines {line = {kind = .Context, old_line = i32(i + 1), new_line = i32(i + 1), text = "line"}}
	hunks := []turns.Hunk{{old_start = 1, old_count = 4, new_start = 1, new_count = 4, lines = lines}}
	files := files_named({"a.odin", "b.odin"}, hunks)
	defer delete(files)
	rows := []app.Turn_Row{{id = 3, kind = .Turn, ended = 3}, {id = 2, kind = .Turn, ended = 2}, {id = 1, ended = 1}}
	q := app.Result_Query {
		pane     = pane.id,
		rows     = rows,
		selected = {3},
		diff     = {files = files},
	}
	app.changes_fill_query(&f.state, pane, &q, time.now(), true)

	g := app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.summary)
	testing.expect(t, pane.state.panel_open && !pane.state.files_open)
	// With the panel open and no list, the turn keys step turns.
	tap(&f.state, w, .Arrow_Left)
	testing.expect_value(t, pane.model.view.first, 1)
	tap(&f.state, w, .Arrow_Right)
	testing.expect_value(t, pane.model.view.first, 0)
	// The range label sits in the panel and opens the turn list over it.
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.range_label)
	testing.expect(t, pane.state.turn_list_open && pane.state.panel_open)
	// Escape closes the turn list first, then the panel.
	tap(&f.state, w, .Escape)
	testing.expect(t, !pane.state.turn_list_open && pane.state.panel_open)
	tap(&f.state, w, .Escape)
	testing.expect(t, !pane.state.panel_open)
}

@(private = "file")
type_text :: proc(state: ^app.App, w: ^app.Window, text: string) {
	app.handle_event(state, input.Text_Event{window = w.id, text = text})
}

@(test)
saved_filters_are_typed_picked_toggled_and_saved_from_the_filter_field :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "SavedFilters") {return}
	w := f.state.windows[0]
	app.window_resize(&f.state, w, 2400, 900)
	library := "No vendor | !^vendor/; Odin | \\.odin$"
	if !testing.expect(t, app.settings_save_value(&f.state, "turns.saved_filters", library, "Could not save.")) {
		return
	}
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	shown, found := changes_pane_of(&f.state, w)
	if !testing.expect(t, found) {return}
	view := &pane.model.view
	lines := []turns.Diff_Line{{kind = .Context, old_line = 1, new_line = 1, text = "line"}}
	hunks := []turns.Hunk{{old_start = 1, old_count = 1, new_start = 1, new_count = 1, lines = lines}}
	files := files_named({"src/a.odin", "vendor/b.odin", "docs/c.md"}, hunks)
	defer delete(files)
	plain := app.Result_Plain {
		pane = pane.id,
		diff = {files = files},
	}
	app.changes_fill_plain(&f.state, pane, &plain)

	g := app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.filter_button)
	if !testing.expect(t, pane.state.filter_open) {return}

	// An @ offers the saved filters in the user's order; Down and Enter complete with the second.
	type_text(&f.state, w, "@")
	testing.expect(t, pane.filter_typing)
	testing.expect_value(t, len(pane.filter_picks), 2)
	testing.expect_value(t, view.hidden_count, 0)
	tap(&f.state, w, .Arrow_Down)
	testing.expect_value(t, pane.filter_pick_row, 1)
	tap(&f.state, w, .Enter)
	testing.expect_value(t, app.changes_filter_text(pane), "@Odin ")
	testing.expect(t, !pane.filter_typing)
	testing.expect(t, pane.state.filter_open)
	testing.expect_value(t, len(pane.filter_tokens), 1)
	testing.expect_value(t, view.hidden_count, 1)

	// The field's @ button lists what is left, and a click on a row inserts it at the caret; a filter in the
	// field is not offered again, and Escape closes the list before it closes the popover.
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.filter_at)
	testing.expect(t, pane.filter_typing)
	testing.expect_value(t, len(pane.filter_picks), 1)
	testing.expect_value(t, pane.filter_picks[0].label, "No vendor")
	testing.expect_value(t, pane.filter_picks[0].hides, 1)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	if !testing.expect_value(t, len(g.filter_picks), 1) {return}
	click(&f.state, w, g.filter_picks[0])
	testing.expect_value(t, app.changes_filter_text(pane), "@Odin @\"No vendor\" ")
	testing.expect(t, !pane.filter_typing)
	testing.expect_value(t, view.hidden_count, 2)
	g = app.changes_geometry_of(&f.state, w, pane, shown)
	click(&f.state, w, g.filter_at)
	testing.expect_value(t, len(pane.filter_picks), 0)
	tap(&f.state, w, .Escape)
	testing.expect(t, !pane.filter_typing && pane.state.filter_open)

	// Shift and Left select the last token as a whole, and Space turns it off and keeps it selected.
	chord(&f.state, w, .Arrow_Left, {.Shift})
	low, high := ui.field_selection(&pane.filter_editor)
	testing.expect_value(t, app.changes_filter_text(pane)[low:high], " ")
	tap(&f.state, w, .Home)
	chord(&f.state, w, .Arrow_Right, {.Shift})
	low, high = ui.field_selection(&pane.filter_editor)
	testing.expect_value(t, app.changes_filter_text(pane)[low:high], "@Odin")
	app.handle_event(&f.state, input.Key_Event{window = w.id, key = .Space, pressed = true, text = " "})
	testing.expect_value(t, app.changes_filter_text(pane), "~@Odin @\"No vendor\" ")
	testing.expect_value(t, pane.filter_tokens[0].off, true)
	testing.expect_value(t, view.hidden_count, 1)

	// A token is one character: Backspace after it takes it out whole.
	tap(&f.state, w, .End)
	tap(&f.state, w, .Backspace)
	tap(&f.state, w, .Backspace)
	testing.expect_value(t, app.changes_filter_text(pane), "~@Odin ")
	type_text(&f.state, w, "src")
	testing.expect_value(t, app.changes_filter_text(pane), "~@Odin src")
	testing.expect(t, pane.filter_savable)

	// Ctrl+S saves the terms as a filter without asking for a name; it shows its pattern, and its token
	// takes their place.
	chord(&f.state, w, .S, {.Control})
	testing.expect_value(
		t, f.state.settings.turns.saved_filters, strings.concatenate({library, "; | src"}, context.temp_allocator),
	)
	testing.expect_value(t, app.changes_filter_text(pane), "~@Odin @src")
	testing.expect_value(t, view.hidden_count, 2)
	testing.expect(t, !pane.filter_savable)

	// A pane opened from this one copies the tokens, and Clear empties the field, tokens included.
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 2) {return}
	testing.expect_value(t, app.changes_filter_text(f.state.changes_panes[1]), "~@Odin @src")
	testing.expect_value(t, len(f.state.changes_panes[1].filter_tokens), 2)
	app.changes_filter_clear(&f.state, w, pane)
	testing.expect_value(t, app.changes_filter_text(pane), "")
	testing.expect_value(t, len(pane.filter_tokens), 0)
	testing.expect_value(t, view.hidden_count, 0)
}
