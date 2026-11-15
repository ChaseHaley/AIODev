package app_test

import "aio:input"
import "aio:platform"
import "aio:term"
import "aio:turns"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"

@(private = "file")
Comments_Fixture :: struct {
	state:     app.App,
	directory: string,
}

@(private = "file")
comments_fixture_start :: proc(t: ^testing.T, f: ^Comments_Fixture, name: string) -> bool {
	directory, err := os.make_directory_temp("", "aio-comments-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return false}
	f.directory = directory
	settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	text := idle_shell_settings(t, "cursor.blink = false\n")
	if !testing.expect_value(t, os.write_entire_file(settings_path, text), nil) {return false}
	f.state = {options = {data_dir = f.directory, inactive = true}}
	f.state.app_id = fmt.aprintf("AIODev.Test.Comments.%s.%d", name, os.get_pid())
	app.layout_state_enable(&f.state, strings.concatenate({f.directory, "/layout.json"}))
	initialized := platform.init(&f.state.platform, f.state.app_id)
	if !testing.expect_value(t, initialized, platform.Init_Result.Primary) {return false}
	f.state.platform_ready = true
	return testing.expect(t, app.app_init(&f.state))
}

// Two hunks of one file. Flat lines: 0 " a" (10/10), 1 "-b" (11/-), 2 "+c" (-/11), 3 "+d" (-/12),
// 4 " e" (12/13), then 5 "-x" (20/-) and 6 the no-newline marker. With `lead`, a hunk adding line 1
// comes first, which moves every flat index down by one while the line numbers stay.
@(private = "file")
comments_files :: proc(path: string, lead := false) -> []turns.Diff_File {
	first := make([]turns.Diff_Line, 5, context.temp_allocator)
	first[0] = {kind = .Context, old_line = 10, new_line = 10, text = "a"}
	first[1] = {kind = .Removed, old_line = 11, text = "b"}
	first[2] = {kind = .Added, new_line = 11, text = "c"}
	first[3] = {kind = .Added, new_line = 12, text = "d"}
	first[4] = {kind = .Context, old_line = 12, new_line = 13, text = "e"}
	second := make([]turns.Diff_Line, 2, context.temp_allocator)
	second[0] = {kind = .Removed, old_line = 20, text = "x"}
	second[1] = {kind = .No_Newline}
	hunks := make([dynamic]turns.Hunk, context.temp_allocator)
	if lead {
		added := make([]turns.Diff_Line, 1, context.temp_allocator)
		added[0] = {kind = .Added, new_line = 1, text = "z"}
		append(&hunks, turns.Hunk{lines = added})
	}
	append(&hunks, turns.Hunk{lines = first}, turns.Hunk{lines = second})
	files := make([]turns.Diff_File, 1, context.temp_allocator)
	files[0] = {old_path = path, new_path = path, hunks = hunks[:]}
	return files
}

@(private = "file")
comments_press :: proc(
	state: ^app.App,
	w: ^app.Window,
	pane: ^app.Changes_Pane,
	hit: ui.Changes_Hit,
	shift := false,
) {
	e := input.Mouse_Button_Event {
		button  = .Left,
		pressed = true,
	}
	if shift {e.modifiers = {.Shift}}
	_ = app.changes_comments_press(state, w, pane, hit, e)
	app.changes_comments_release(state, w, pane)
}

@(private = "file")
comments_key :: proc(state: ^app.App, w: ^app.Window, pane: ^app.Changes_Pane, key: input.Key) -> bool {
	return app.changes_comments_key(state, w, pane, {key = key, pressed = true})
}

// Selects flat lines 2 and 3 (+c, +d) by a press and a Shift press, then writes `text` and saves it.
@(private = "file")
comments_write :: proc(state: ^app.App, w: ^app.Window, pane: ^app.Changes_Pane, text: string) {
	comments_press(state, w, pane, {part = .Line, index = 0, line = 2})
	comments_press(state, w, pane, {part = .Line, index = 0, line = 3}, shift = true)
	comments_press(state, w, pane, {part = .Comment_Button})
	_ = app.changes_comments_text(state, w, pane, text)
	_ = comments_key(state, w, pane, .Enter)
}

@(test)
comments_message_names_each_comment_lines_and_side_and_fences_its_quote :: proc(t: ^testing.T) {
	items := []app.Changes_Comment {
		{path = "src/foo.odin", side = .New, first = 12, last = 12, quote = "+d", text = "Why?"},
		{path = "src/bar.odin", side = .New, first = 12, last = 15, quote = " a\n+b", text = "Rename it."},
		{path = "old.odin", side = .Old, first = 3, last = 4, quote = "-x\n-y", text = "Keep these."},
		{path = "doc.md", side = .Old, first = 7, last = 7, quote = "-```odin", text = "Fence."},
	}
	message := app.changes_comments_message(items, context.temp_allocator)
	expected :=
		"Review comments on your changes:\n\n" +
		"1. src/foo.odin, line 12:\n```\n+d\n```\nWhy?\n\n" +
		"2. src/bar.odin, lines 12-15:\n```\n a\n+b\n```\nRename it.\n\n" +
		"3. old.odin, lines 3-4 before the change:\n```\n-x\n-y\n```\nKeep these.\n\n" +
		"4. doc.md, line 7 before the change:\n````\n-```odin\n````\nFence."
	testing.expect_value(t, message, expected)
	empty := app.changes_comments_message(nil, context.temp_allocator)
	testing.expect_value(t, empty, "Review comments on your changes:")
}

@(test)
comments_editor_saves_on_enter_and_cancels_on_escape :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_files("src/foo.odin")
	c := &pane.comments
	testing.expect_value(t, c.editing, -1)

	comments_press(&state, &w, pane, {part = .Line, index = 0, line = 2})
	comments_press(&state, &w, pane, {part = .Line, index = 0, line = 3}, shift = true)
	testing.expect_value(t, c.selection, ui.Changes_Selection{file = 0, first = 2, last = 3, active = true})
	testing.expect_value(t, pane.model.view.selection, c.selection)

	// Enter opens the editor on the selection; empty text saves nothing.
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	testing.expect_value(t, c.editing, 0)
	testing.expect_value(t, pane.model.view.editing, 0)
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	testing.expect_value(t, c.editing, -1)
	testing.expect_value(t, len(c.items), 0)

	comments_press(&state, &w, pane, {part = .Comment_Button})
	testing.expect_value(t, c.editing, 0)
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "Looks off."))
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	if !testing.expect_value(t, len(c.items), 1) {return}
	item := c.items[0]
	testing.expect_value(t, item.path, "src/foo.odin")
	testing.expect_value(t, item.side, app.Comment_Side.New)
	testing.expect_value(t, item.first, 11)
	testing.expect_value(t, item.last, 12)
	testing.expect_value(t, item.quote, "+c\n+d")
	testing.expect_value(t, item.text, "Looks off.")
	testing.expect_value(t, c.editing, -1)
	testing.expect(t, !c.selection.active, "saving ends the selection")
	testing.expect_value(t, len(pane.model.view.comments), 1)
	testing.expect_value(t, pane.model.view.comments[0].first, 2)
	testing.expect_value(t, pane.model.view.comments[0].last, 3)
	testing.expect_value(t, pane.model.view.send.count, 1)

	// Escape leaves the comment as it was.
	comments_press(&state, &w, pane, {part = .Comment_Card, index = 0})
	testing.expect_value(t, c.editing, 0)
	testing.expect(t, app.changes_comments_text(&state, &w, pane, " Really."))
	testing.expect(t, comments_key(&state, &w, pane, .Escape))
	testing.expect_value(t, c.editing, -1)
	testing.expect_value(t, c.items[0].text, "Looks off.")

	// Removed lines alone comment on the old side; Escape without an editor ends the selection.
	comments_press(&state, &w, pane, {part = .Hunk_Comment, index = 0, line = 5})
	testing.expect_value(t, c.selection, ui.Changes_Selection{file = 0, first = 5, last = 6, active = true})
	testing.expect_value(t, c.editing, 1)
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "Gone?"))
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	if !testing.expect_value(t, len(c.items), 2) {return}
	testing.expect_value(t, c.items[1].side, app.Comment_Side.Old)
	testing.expect_value(t, c.items[1].first, 20)
	testing.expect_value(t, c.items[1].quote, "-x")
	comments_press(&state, &w, pane, {part = .Line, index = 0, line = 0})
	testing.expect(t, comments_key(&state, &w, pane, .Escape))
	testing.expect(t, !c.selection.active)
	testing.expect(t, !comments_key(&state, &w, pane, .Escape), "Escape passes on with nothing selected")

	comments_press(&state, &w, pane, {part = .Comment_Delete, index = 0})
	testing.expect_value(t, len(c.items), 1)
	testing.expect_value(t, c.items[0].text, "Gone?")
	comments_press(&state, &w, pane, {part = .Discard})
	testing.expect_value(t, len(c.items), 0)
	testing.expect_value(t, pane.model.view.send.count, 0)
}

@(test)
comments_find_their_lines_after_a_refresh_and_detach_when_they_are_gone :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_files("src/foo.odin")
	c := &pane.comments
	comments_write(&state, &w, pane, "Looks off.")
	if !testing.expect_value(t, len(c.items), 1) {return}
	// A selection of the removed line rides along with the refresh too.
	comments_press(&state, &w, pane, {part = .Line, index = 0, line = 1})

	pane.model.view.files = comments_files("src/foo.odin", lead = true)
	app.changes_comments_reanchor(pane)
	testing.expect_value(t, c.items[0].file, 0)
	testing.expect_value(t, c.items[0].first_line, 3)
	testing.expect_value(t, c.items[0].last_line, 4)
	testing.expect_value(t, pane.model.view.comments[0].detached, false)
	testing.expect_value(t, c.selection, ui.Changes_Selection{file = 0, first = 2, last = 2, active = true})

	pane.model.view.files = comments_files("src/other.odin")
	app.changes_comments_reanchor(pane)
	testing.expect_value(t, c.items[0].file, -1)
	testing.expect_value(t, pane.model.view.comments[0].detached, true)
	testing.expect(t, !c.selection.active, "a selection whose lines are gone ends")
	testing.expect_value(t, c.items[0].text, "Looks off.")

	// Its lines coming back attach it again.
	pane.model.view.files = comments_files("src/foo.odin")
	app.changes_comments_reanchor(pane)
	testing.expect_value(t, c.items[0].file, 0)
	testing.expect_value(t, c.items[0].first_line, 2)
}

@(test)
comments_send_is_refused_for_a_closed_pane :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	gone := app.changes_pane_create(&state, {pane_key = "pane-that-closed"}, "C:/work/odin", .Repository)
	if !testing.expect(t, gone != nil) {return}
	entry, can_send, reason := app.changes_send_target(&state, gone)
	testing.expect(t, entry == nil)
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, "The agent's pane is closed.")

	unbound := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, unbound != nil) {return}
	_, can_send, reason = app.changes_send_target(&state, unbound)
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, "The agent's pane is closed.")
}

@(test)
comments_send_is_refused_for_a_pane_at_a_shell_prompt :: proc(t: ^testing.T) {
	f: Comments_Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !comments_fixture_start(t, &f, "Shell") {return}
	if !testing.expect(t, len(f.state.sessions) > 0) {return}
	w := f.state.windows[0]
	key := f.state.sessions[0].key
	if !testing.expect(t, key != "") {return}
	pane := app.changes_pane_create(&f.state, {pane_key = key}, f.directory, .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_files("src/foo.odin")
	comments_write(&f.state, w, pane, "Looks off.")
	if !testing.expect_value(t, len(pane.comments.items), 1) {return}

	entry, can_send, reason := app.changes_send_target(&f.state, pane)
	testing.expect(t, entry == &f.state.sessions[0])
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, "The agent isn't running in its pane.")
	app.changes_comments_view(&f.state, pane)
	testing.expect(t, !pane.model.view.send.can_send)
	testing.expect_value(t, pane.model.view.send.reason, "The agent isn't running in its pane.")

	// A refused Send keeps the comments.
	comments_press(&f.state, w, pane, {part = .Send})
	testing.expect_value(t, len(pane.comments.items), 1)
}

// The agent exited back to a shell that marks no prompts, so its main status record never ended: the
// record alone must not let Send paste at the shell prompt.
@(test)
comments_send_is_refused_at_a_shell_whose_agent_record_stayed_open :: proc(t: ^testing.T) {
	f: Comments_Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !comments_fixture_start(t, &f, "Stale") {return}
	if !testing.expect(t, len(f.state.sessions) > 0) {return}
	entry := &f.state.sessions[0]
	if !testing.expect(t, entry.key != "") {return}
	// The idle shell's process runs; only its frame copy of the phase may lag.
	entry.status = .Running
	records := make([]term.Program_Status, 1)
	records[0] = {app = strings.clone("claude"), title = strings.clone("Working"), state = .Working}
	term.destroy_program_status(entry.statuses)
	entry.statuses = records
	pane := app.changes_pane_create(&f.state, {pane_key = entry.key, harness = "claude"}, f.directory, .Agent)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_files("src/foo.odin")
	comments_write(&f.state, f.state.windows[0], pane, "Looks off.")
	if !testing.expect_value(t, len(pane.comments.items), 1) {return}

	found, can_send, reason := app.changes_send_target(&f.state, pane)
	testing.expect(t, found == entry)
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, "The agent isn't running in its pane.")
	app.changes_comments_view(&f.state, pane)
	testing.expect(t, !pane.model.view.send.can_send)
	testing.expect_value(t, pane.model.view.send.reason, "The agent isn't running in its pane.")
}

@(test)
comments_send_verdict_trusts_only_the_reporting_agent_and_never_answers_a_prompt :: proc(t: ^testing.T) {
	not_running :: "The agent isn't running in its pane."
	working := term.Program_Status {
		app   = "claude",
		state = .Working,
	}
	blocked := working
	blocked.state = .Blocked
	ended := working
	ended.ended = true
	reporters := []string{"claude"}

	// The reporter itself with its record open.
	can_send, reason := app.changes_send_verdict(true, "claude", .None, reporters, working, true, "claude")
	testing.expect(t, can_send)
	testing.expect_value(t, reason, "")
	// A launcher whose arguments start the pane's harness, with no record at all.
	can_send, _ = app.changes_send_verdict(true, "node", .Claude, nil, {}, false, "claude")
	testing.expect(t, can_send)

	// Only the shell runs.
	can_send, reason = app.changes_send_verdict(false, "", .None, reporters, working, true, "claude")
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, not_running)
	// The agent exited to a nested shell or a bridge, and its record stayed open.
	can_send, reason = app.changes_send_verdict(true, "bash", .None, reporters, working, true, "claude")
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, not_running)
	can_send, reason = app.changes_send_verdict(true, "wsl", .None, reporters, working, true, "claude")
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, not_running)
	// An ended record counts for nothing.
	can_send, reason = app.changes_send_verdict(true, "claude", .None, reporters, ended, true, "claude")
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, not_running)

	// Enter would answer a permission or question prompt.
	can_send, reason = app.changes_send_verdict(true, "claude", .None, reporters, blocked, true, "claude")
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, "The agent is waiting for an answer.")
	can_send, reason = app.changes_send_verdict(true, "node", .Claude, reporters, blocked, true, "claude")
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, "The agent is waiting for an answer.")

	// Another agent started in the pane.
	can_send, reason = app.changes_send_verdict(true, "node", .Codex, nil, {}, false, "claude")
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, not_running)
	codex := []string{"codex"}
	can_send, reason = app.changes_send_verdict(true, "codex", .None, codex, working, true, "claude")
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, not_running)
	// With the pane's harness unknown, any agent harness counts.
	can_send, _ = app.changes_send_verdict(true, "node", .Codex, nil, {}, false, "")
	testing.expect(t, can_send)
}
