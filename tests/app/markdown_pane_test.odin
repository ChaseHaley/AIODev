package app_test

import "aio:cli_protocol"
import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:markdown"
import "aio:platform"
import "aio:term"
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
	file:      string,
}

@(private = "file")
fixture_start :: proc(t: ^testing.T, f: ^Fixture, name: string, keep_directory := false) -> bool {
	if !keep_directory {
		directory, err := os.make_directory_temp("", "aio-markdown-*", context.allocator)
		if !testing.expect_value(t, err, nil) {return false}
		f.directory = directory
		f.file = strings.concatenate({directory, "\\doc.md"})
		settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
		settings := idle_shell_settings(t, "cursor.blink = false\n")
		if !testing.expect_value(t, os.write_entire_file(settings_path, settings), nil) {return false}
		if !testing.expect_value(t, os.write_entire_file(f.file, "# First\n\n[other](other.md)\n"), nil) {return false}
	}
	f.state = {options = {data_dir = f.directory, inactive = true}}
	f.state.app_id = fmt.aprintf("AIODev.Test.Markdown.%s.%d", name, os.get_pid())
	app.layout_state_enable(&f.state, strings.concatenate({f.directory, "/layout.json"}))
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	return testing.expect(t, app.app_init(&f.state))
}

@(private = "file")
fixture_destroy :: proc(t: ^testing.T, f: ^Fixture) {
	app.app_destroy(&f.state)
	delete(f.file)
	testing.expect_value(t, os.remove_all(f.directory), nil)
	delete(f.directory)
}

@(private = "file")
open :: proc(state: ^app.App, path: string, focus := false) -> app.Outcome {
	args := focus ? []string{"pane.open_markdown", "--focus", path} : []string{"pane.open_markdown", path}
	invocation, err := commands.parse_invocation(&state.registry, args, context.temp_allocator)
	if err.advice != "" {return {status = .Usage, message = err.advice}}
	return app.command_execute(state, app.Control_Request{state.sessions[0].id}, invocation)
}

// Runs the poll now rather than waiting for its interval.
@(private = "file")
poll :: proc(state: ^app.App) {
	state.markdown_deadline = time.tick_now()
	app.markdown_tick(state)
}

// The pane's load variant by name, so a failed expectation says which it was.
@(private = "file")
load_name :: proc(pane: ^app.Markdown_Pane) -> string {
	switch _ in pane.load {
	case app.Markdown_Missing:
		return "Missing"
	case app.Markdown_Loaded:
		return "Loaded"
	case app.Markdown_Too_Large:
		return "Too_Large"
	case app.Markdown_Failed:
		return "Failed"
	case nil:
	}
	return "Unverified"
}

@(test)
markdown_paths_are_recognized_by_extension :: proc(t: ^testing.T) {
	testing.expect(t, app.markdown_is_path("C:\\a\\Plan.md"))
	testing.expect(t, app.markdown_is_path("C:\\a\\PLAN.MARKDOWN"))
	testing.expect(t, !app.markdown_is_path("C:\\a\\plan.txt"))
	testing.expect(t, !app.markdown_is_path("C:\\a.md\\plan"))
}

@(test)
opening_splits_beside_the_caller_and_keeps_focus_in_the_terminal :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Open") {return}
	w := f.state.windows[0]
	before := app.window_tree(w).focus
	opened := open(&f.state, f.file)
	testing.expect_value(t, opened.status, cli_protocol.Status.Ok)
	testing.expect_value(t, app.window_tree(w).focus, before)
	if !testing.expect_value(t, len(f.state.markdown_panes), 1) {return}
	pane := f.state.markdown_panes[0]
	testing.expect_value(t, load_name(pane), "Loaded")
	testing.expect_value(t, pane.title, "doc.md")
	testing.expect(t, app.workspace_has_content(w.workspace, {.Markdown, pane.id}))
	testing.expect_value(t, len(f.state.sessions), 1)
}

@(private = "file")
find_settle :: proc(state: ^app.App) {
	for app.find_pending(state) {app.find_tick(state)}
}

@(private = "file")
find_count :: proc(w: ^app.Window, pane: ^app.Markdown_Pane) -> string {
	label, _ := app.find_presentation(w, pane)
	return label
}

@(private = "file")
press :: proc(state: ^app.App, w: ^app.Window, key: input.Key, modifiers: input.Modifiers = {}) {
	app.handle_event(state, input.Key_Event{window = w.id, key = key, modifiers = modifiers, pressed = true})
	app.handle_event(state, input.Key_Event{window = w.id, key = key, modifiers = modifiers})
}

// Drives the bar through the real dispatcher: the keys and bar of terminal find, reading top down.
@(test)
find_in_a_document_uses_the_terminal_bar_and_reads_top_down :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Find") {return}
	body := strings.repeat("paragraph\n\n", 80, context.temp_allocator)
	source := strings.concatenate({"needle first\n\n", body, "NEEDLE middle\n\n", body, "needle last\n"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(f.file, source), nil) {return}
	testing.expect_value(t, open(&f.state, f.file, true).status, cli_protocol.Status.Ok)
	w := f.state.windows[0]
	if !testing.expect(t, app.markdown_active(w)) {return}
	pane := f.state.markdown_panes[0]
	document := app.markdown_document(pane)
	if !testing.expect(t, document != nil) {return}
	ui.markdown_view_fit(&pane.view, document, pane.revision, &w.ui_text, f.state.family, 600, w.scale)

	app.run_action(&f.state, w, .Find)
	testing.expect(t, ui.find_has_keyboard(&w.find))
	testing.expect_value(t, find_count(w, pane), "0 of 0")
	app.handle_event(&f.state, input.Text_Event{w.id, "needle"})
	testing.expect_value(t, ui.field_string(&w.find.query), "needle")
	find_settle(&f.state)
	testing.expect_value(t, find_count(w, pane), "0 of 3")
	testing.expect_value(t, pane.view.scroll, 0)

	// Enter walks down from the first match, which already shows; Shift+Enter goes back, both wrapping.
	press(&f.state, w, .Enter)
	testing.expect_value(t, find_count(w, pane), "1 of 3")
	testing.expect_value(t, pane.search.selected, 0)
	testing.expect_value(t, pane.view.scroll, 0)
	press(&f.state, w, .Enter)
	testing.expect_value(t, find_count(w, pane), "2 of 3")
	scrolled := pane.view.scroll
	testing.expect(t, scrolled > 0)
	press(&f.state, w, .Enter)
	testing.expect_value(t, find_count(w, pane), "3 of 3")
	testing.expect(t, pane.view.scroll > scrolled)
	press(&f.state, w, .Enter)
	testing.expect_value(t, find_count(w, pane), "1 of 3")
	press(&f.state, w, .Enter, {.Shift})
	testing.expect_value(t, find_count(w, pane), "3 of 3")
	testing.expect_value(t, pane.search.selected, 2)

	// The bar's arrows move the way they point, whichever way Enter goes.
	l, _ := app.find_controls(w, pane)
	for down in ([2]bool{true, false}) {
		app.handle_event(&f.state, input.Mouse_Button_Event{window = w.id, x = i32(l.up.x + 16),
			y = i32(l.up.y + 16), button = .Left, pressed = down})
	}
	testing.expect_value(t, find_count(w, pane), "2 of 3")
	for down in ([2]bool{true, false}) {
		app.handle_event(&f.state, input.Mouse_Button_Event{window = w.id, x = i32(l.down.x + 16),
			y = i32(l.down.y + 16), button = .Left, pressed = down})
	}
	testing.expect_value(t, find_count(w, pane), "3 of 3")

	// Keys stay with the query rather than the document.
	before := pane.view.scroll
	press(&f.state, w, .End)
	testing.expect_value(t, pane.view.scroll, before)

	// Case and expression toggles, on their usual keys.
	press(&f.state, w, .C, {.Alt})
	testing.expect(t, w.find.options.case_sensitive)
	find_settle(&f.state)
	testing.expect_value(t, find_count(w, pane), "0 of 2")
	press(&f.state, w, .C, {.Alt})
	press(&f.state, w, .R, {.Alt})
	testing.expect(t, w.find.options.regex)
	app.handle_event(&f.state, input.Text_Event{w.id, "("})
	find_settle(&f.state)
	testing.expect_value(t, find_count(w, pane), "Invalid expression")
	press(&f.state, w, .Backspace)
	press(&f.state, w, .R, {.Alt})
	find_settle(&f.state)
	testing.expect_value(t, find_count(w, pane), "0 of 3")

	// Closing ends the search, leaves the view where it is and remembers the query.
	press(&f.state, w, .Enter)
	press(&f.state, w, .Enter)
	kept := pane.view.scroll
	testing.expect(t, kept > 0)
	press(&f.state, w, .Escape)
	testing.expect(t, !ui.find_is_open(&w.find) && pane.search.phase == .Off)
	testing.expect_value(t, pane.view.scroll, kept)
	app.run_action(&f.state, w, .Find)
	testing.expect_value(t, ui.field_string(&w.find.query), "")
	press(&f.state, w, .Arrow_Up)
	testing.expect_value(t, ui.field_string(&w.find.query), "needle")

	// A press on the document hands it the keyboard; the bar and its matches stay.
	find_settle(&f.state)
	press(&f.state, w, .Enter)
	shown: layout.Pane_Rect
	for candidate in w.panes {if candidate.content.kind == .Markdown {shown = candidate}}
	if !testing.expect_value(t, shown.content.kind, layout.Content_Kind.Markdown) {return}
	x, y := i32(shown.rect.x + shown.rect.width / 2), i32(shown.rect.y + shown.rect.height / 2)
	for down in ([2]bool{true, false}) {
		app.handle_event(&f.state, input.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left, pressed = down})
	}
	testing.expect(t, ui.find_is_open(&w.find) && !ui.find_has_keyboard(&w.find) && pane.search.phase != .Off)
	press(&f.state, w, .Escape)
	testing.expect(t, ui.find_is_open(&w.find))
	press(&f.state, w, .Home)
	testing.expect_value(t, pane.view.scroll, 0)

	// A rewrite keeps the search and its place, and a missing file has nothing to find.
	testing.expect_value(t, find_count(w, pane), "1 of 3")
	testing.expect_value(t, os.write_entire_file(f.file, "# Rewritten\n\nneedle first\n\nneedle last, longer\n"), nil)
	poll(&f.state)
	find_settle(&f.state)
	testing.expect_value(t, find_count(w, pane), "1 of 2")
	testing.expect_value(t, os.remove(f.file), nil)
	poll(&f.state)
	testing.expect_value(t, load_name(pane), "Missing")
	testing.expect_value(t, find_count(w, pane), "0 of 0")
	// A new query does not read the document the missing file left behind; the file's return does.
	app.run_action(&f.state, w, .Find)
	press(&f.state, w, .End)
	app.handle_event(&f.state, input.Text_Event{w.id, " last"})
	testing.expect_value(t, ui.field_string(&w.find.query), "needle last")
	testing.expect(t, !app.find_pending(&f.state))
	app.find_tick(&f.state)
	testing.expect_value(t, pane.search.next, 0)
	testing.expect_value(t, find_count(w, pane), "0 of 0")
	testing.expect_value(t, os.write_entire_file(f.file, "needle last\n"), nil)
	poll(&f.state)
	find_settle(&f.state)
	testing.expect_value(t, find_count(w, pane), "0 of 1")

	// Focus leaving the pane closes find and ends the search, as it does between terminals.
	app.run_action(&f.state, w, .Focus_Next)
	testing.expect(t, !app.markdown_active(w))
	testing.expect(t, !ui.find_is_open(&w.find) && pane.search.phase == .Off)
	testing.expect(t, term.search_summary(f.state.sessions[0].session).progress == .Off)
}

@(test)
a_pane_without_a_search_costs_no_wakeups :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Idle") {return}
	testing.expect_value(t, open(&f.state, f.file, true).status, cli_protocol.Status.Ok)
	testing.expect(t, !app.find_pending(&f.state))
}

@(test)
opening_a_shown_file_again_reuses_its_pane :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Reuse") {return}
	testing.expect_value(t, open(&f.state, f.file).status, cli_protocol.Status.Ok)
	testing.expect_value(t, open(&f.state, strings.to_upper(f.file, context.temp_allocator)).status, cli_protocol.Status.Ok)
	testing.expect_value(t, len(f.state.markdown_panes), 1)
	testing.expect_value(t, app.tab_pane_count(f.state.windows[0].workspace.tabs[0]), 2)
}

@(test)
opening_refuses_unavailable_files_and_active_types :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Refuse") {return}
	missing := strings.concatenate({f.directory, "\\missing.md"}, context.temp_allocator)
	testing.expect_value(t, open(&f.state, missing).status, cli_protocol.Status.Failed)
	testing.expect_value(t, open(&f.state, "\\\\server\\share\\doc.md").status, cli_protocol.Status.Failed)
	testing.expect_value(t, open(&f.state, "relative.md").status, cli_protocol.Status.Failed)
	script := strings.concatenate({f.directory, "\\run.cmd"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(script, "echo hi"), nil)
	testing.expect_value(t, open(&f.state, script).status, cli_protocol.Status.Failed)
	testing.expect_value(t, len(f.state.markdown_panes), 0)
}

@(test)
a_markdown_id_is_never_read_as_a_session :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Collide") {return}
	w := f.state.windows[0]
	testing.expect_value(t, open(&f.state, f.file, true).status, cli_protocol.Status.Ok)
	pane := f.state.markdown_panes[0]
	// Both id spaces start at 1, so without the kind check this would find the first shell.
	testing.expect(t, app.session_find(&f.state, pane.id) != nil)
	testing.expect(t, app.workspace_session_for_content(&f.state, {.Markdown, pane.id}) == nil)
	testing.expect(t, app.focused_session(&f.state, w) == nil)
	testing.expect(t, app.markdown_active(w))
	testing.expect(t, app.markdown_focused(&f.state, w) == pane)
	counts := app.workspace_pane_counts(w.workspace)
	testing.expect_value(t, counts.panes, 2)
	testing.expect_value(t, counts.sessions, 1)
}

// The palette and `command edit.copy` ask action_available, so it must agree with the keyboard, which
// copies a document's selection.
@(test)
copy_is_available_in_a_document_with_a_selection :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Copy") {return}
	w := f.state.windows[0]
	testing.expect_value(t, open(&f.state, f.file, true).status, cli_protocol.Status.Ok)
	if !testing.expect(t, app.markdown_active(w)) {return}
	pane := f.state.markdown_panes[0]
	document := app.markdown_document(pane)
	if !testing.expect(t, document != nil) {return}
	testing.expect(t, !app.action_available(&f.state, w, .Copy))
	ui.markdown_select_all(&pane.view, document)
	testing.expect(t, app.action_available(&f.state, w, .Copy))
	ui.markdown_selection_clear(&pane.view)
	testing.expect(t, !app.action_available(&f.state, w, .Copy))
}

@(test)
the_poll_follows_changes_to_the_file :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Poll") {return}
	testing.expect_value(t, open(&f.state, f.file).status, cli_protocol.Status.Ok)
	pane := f.state.markdown_panes[0]
	revision := pane.revision
	poll(&f.state)
	testing.expect_value(t, pane.revision, revision)
	testing.expect_value(t, os.write_entire_file(f.file, "# Rewritten with different length\n"), nil)
	poll(&f.state)
	testing.expect_value(t, pane.revision, revision + 1)
	if !testing.expect_value(t, load_name(pane), "Loaded") {return}
	testing.expect_value(t, string(app.markdown_document(pane).text[:]), "Rewritten with different length")
	testing.expect_value(t, os.remove(f.file), nil)
	poll(&f.state)
	testing.expect_value(t, load_name(pane), "Missing")
	testing.expect_value(t, os.write_entire_file(f.file, "back"), nil)
	poll(&f.state)
	if !testing.expect_value(t, load_name(pane), "Loaded") {return}
	testing.expect_value(t, string(app.markdown_document(pane).text[:]), "back")
}

// Parsing fails only for want of memory, so the pane is put in Failed for the file as it stands.
@(test)
a_file_that_failed_to_parse_is_read_again_only_once_it_changes :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Failed") {return}
	testing.expect_value(t, open(&f.state, f.file).status, cli_protocol.Status.Ok)
	pane := f.state.markdown_panes[0]
	loaded, ok := pane.load.(app.Markdown_Loaded)
	if !testing.expect(t, ok) {return}
	markdown.document_destroy(&loaded.document)
	// Parse OOM cannot be triggered deterministically here without also failing the file read, so
	// install its result for the unchanged file and exercise the real poll from that state.
	pane.load = app.Markdown_Failed{loaded.stamp}
	revision := pane.revision
	poll(&f.state)
	poll(&f.state)
	testing.expect_value(t, load_name(pane), "Failed")
	testing.expect_value(t, pane.revision, revision)
	testing.expect_value(t, os.write_entire_file(f.file, "# Fixed at another length\n"), nil)
	poll(&f.state)
	testing.expect_value(t, load_name(pane), "Loaded")
	testing.expect_value(t, pane.revision, revision + 1)
}

@(test)
files_past_the_limit_are_not_read :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Limit") {return}
	testing.expect_value(t, open(&f.state, f.file).status, cli_protocol.Status.Ok)
	pane := f.state.markdown_panes[0]
	large := make([]u8, 16 * 1024 * 1024 + 1)
	defer delete(large)
	testing.expect_value(t, os.write_entire_file(f.file, large), nil)
	poll(&f.state)
	testing.expect_value(t, load_name(pane), "Too_Large")
}

@(test)
closing_the_pane_frees_it_and_stops_the_poll :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Close") {return}
	w := f.state.windows[0]
	testing.expect_value(t, open(&f.state, f.file, true).status, cli_protocol.Status.Ok)
	testing.expect(t, f.state.markdown_deadline != {})
	app.pane_close_at(&f.state, w.workspace, w.workspace.selected, app.window_tree(w).focus)
	testing.expect_value(t, len(f.state.markdown_panes), 1)
	poll(&f.state)
	testing.expect_value(t, len(f.state.markdown_panes), 0)
	testing.expect(t, f.state.markdown_deadline == {})
}

@(test)
only_one_per_workspace_content_is_refused_a_second_pane :: proc(t: ^testing.T) {
	first, second: layout.Layout
	testing.expect_value(t, layout.init(&first, {.Settings, 0}), nil)
	defer layout.destroy(&first)
	testing.expect_value(t, layout.init(&second, {.Markdown, 1}), nil)
	defer layout.destroy(&second)
	tabs := [2]app.Tab{{tree = first}, {tree = second}}
	workspace: app.Workspace
	append(&workspace.tabs, &tabs[0], &tabs[1])
	defer delete(workspace.tabs)
	testing.expect(t, !app.pane_content_can_join({.Settings, 0}, &workspace, nil))
	testing.expect(t, app.pane_content_can_join({.Markdown, 1}, &workspace, nil))
	testing.expect(t, app.pane_content_can_join({.Markdown, 2}, &workspace, nil))
}

@(test)
layout_restore_reopens_files_and_keeps_a_pane_for_a_missing_one :: proc(t: ^testing.T) {
	first: Fixture
	if !fixture_start(t, &first, "RestoreA") {return}
	defer delete(first.file)
	defer delete(first.directory)
	defer testing.expect_value(t, os.remove_all(first.directory), nil)
	testing.expect_value(t, open(&first.state, first.file).status, cli_protocol.Status.Ok)
	app.layout_state_save(&first.state)
	app.app_destroy(&first.state)

	second := Fixture{directory = first.directory}
	if !fixture_start(t, &second, "RestoreB", true) {return}
	if !testing.expect_value(t, len(second.state.markdown_panes), 1) {
		app.app_destroy(&second.state)
		return
	}
	restored := second.state.markdown_panes[0]
	testing.expect_value(t, load_name(restored), "Unverified")
	poll(&second.state)
	testing.expect_value(t, load_name(restored), "Loaded")
	testing.expect(t, strings.equal_fold(restored.title, "doc.md"))
	app.layout_state_save(&second.state)
	app.app_destroy(&second.state)

	testing.expect_value(t, os.remove(first.file), nil)
	third := Fixture{directory = first.directory}
	if !fixture_start(t, &third, "RestoreC", true) {return}
	defer app.app_destroy(&third.state)
	if !testing.expect_value(t, len(third.state.markdown_panes), 1) {return}
	poll(&third.state)
	testing.expect_value(t, load_name(third.state.markdown_panes[0]), "Unverified")
}

@(test)
a_tampered_layout_path_is_never_read :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Tampered") {return}
	pane := app.markdown_pane_create(&f.state, "\\\\server\\share\\doc.md", false)
	if !testing.expect(t, pane != nil) {return}
	workspace := f.state.windows[0].workspace
	tree := &workspace.tabs[0].tree
	_, err := layout.split_direction(tree, tree.focus, .Right, 0.5, {.Markdown, pane.id})
	testing.expect_value(t, err, nil)
	poll(&f.state)
	testing.expect_value(t, load_name(pane), "Unverified")
	testing.expect_value(t, pane.revision, u64(0))
}

// A press holds its pane until release: the drag selects in it, and hover waits. Between presses one
// value says what the pointer is over, so leaving the pane leaves nothing hovered.
@(test)
a_press_holds_its_pane_until_release_and_hover_has_one_owner :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(t, &f)
	if !fixture_start(t, &f, "Pointer") {return}
	source := "first paragraph\n\nsecond paragraph\n\n[link](https://a.example) after\n"
	if !testing.expect_value(t, os.write_entire_file(f.file, source), nil) {return}
	testing.expect_value(t, open(&f.state, f.file, true).status, cli_protocol.Status.Ok)
	w := f.state.windows[0]
	testing.expect(t, w.markdown_hover == nil, "a newly opened pane must not hover its first link")
	pane := f.state.markdown_panes[0]
	document := app.markdown_document(pane)
	if !testing.expect(t, document != nil) {return}
	shown, terminal: layout.Pane_Rect
	for candidate in w.panes {
		if candidate.content.kind == .Markdown {shown = candidate} else {terminal = candidate}
	}
	if !testing.expect_value(t, shown.content.kind, layout.Content_Kind.Markdown) {return}
	r := shown.rect
	g := ui.markdown_geometry({r.x, r.y + w.header_height, r.width, r.height - w.header_height}, w.scale)
	ui.markdown_view_fit(&pane.view, document, pane.revision, &w.ui_text, f.state.family, g.width, w.scale)
	line := f32(ui.markdown_line(&pane.view))
	y := g.top + line / 2

	button := proc(state: ^app.App, w: ^app.Window, x, y: f32, pressed: bool) {
		app.handle_event(state, input.Mouse_Button_Event{window = w.id, x = i32(x), y = i32(y),
			button = .Left, pressed = pressed})
	}
	button(&f.state, w, g.left + 1, y, true)
	held, selecting := w.markdown_gesture.(app.Markdown_Selecting)
	testing.expect(t, selecting && held.pane == pane.id)
	app.handle_event(&f.state, input.Mouse_Move_Event{window = w.id, x = i32(g.left + g.width),
		y = i32(y), buttons = {.Left}})
	testing.expect_value(t, ui.markdown_selected_text(&pane.view, document), "first paragraph")
	testing.expect(t, w.markdown_hover == nil)
	button(&f.state, w, g.left + g.width, y, false)
	testing.expect(t, w.markdown_gesture == nil)
	testing.expect_value(t, ui.markdown_selected_text(&pane.view, document), "first paragraph")

	link_y := y
	for ui.markdown_link_at(&pane.view, g, g.left + 5, link_y) < 0 && link_y < g.area.y + g.area.height {
		link_y += 1
	}
	app.handle_event(&f.state, input.Mouse_Move_Event{window = w.id, x = i32(g.left + 5), y = i32(link_y)})
	link, over := w.markdown_hover.(app.Markdown_Link_Hover)
	testing.expect(t, over && link.pane == pane.id && link.link == 0)
	t_rect := terminal.rect
	app.handle_event(&f.state, input.Mouse_Move_Event{window = w.id,
		x = i32(t_rect.x + t_rect.width / 2), y = i32(t_rect.y + t_rect.height / 2)})
	testing.expect(t, w.markdown_hover == nil)
}
