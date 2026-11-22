package app_test

import "cosmos:input"
import "aio:markdown"
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

// Ctrl+Enter, which saves the note being written.
@(private = "file")
comments_save :: proc(state: ^app.App, w: ^app.Window, pane: ^app.Changes_Pane) -> bool {
	return app.changes_comments_key(state, w, pane, {key = .Enter, modifiers = {.Control}, pressed = true})
}

// What the editor holds.
@(private = "file")
comments_held :: proc(pane: ^app.Changes_Pane) -> string {
	return markdown.edit_string(&pane.comments.buffer)
}

// Selects flat lines 2 and 3 (+c, +d) by a press and a Shift press, opens the editor with Enter, then writes
// `text` and saves it with Ctrl+Enter.
@(private = "file")
comments_write :: proc(state: ^app.App, w: ^app.Window, pane: ^app.Changes_Pane, text: string) {
	comments_press(state, w, pane, {part = .Gutter, index = 0, line = 2})
	comments_press(state, w, pane, {part = .Gutter, index = 0, line = 3}, shift = true)
	_ = comments_key(state, w, pane, .Enter)
	_ = app.changes_comments_text(state, w, pane, text)
	_ = comments_save(state, w, pane)
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

// Selects flat lines `first` through `last` by presses on the numbers, then opens the editor with Enter.
@(private = "file")
comments_open :: proc(state: ^app.App, w: ^app.Window, pane: ^app.Changes_Pane, first, last: int) {
	comments_press(state, w, pane, {part = .Gutter, index = 0, line = first})
	if last != first {comments_press(state, w, pane, {part = .Gutter, index = 0, line = last}, shift = true)}
	_ = comments_key(state, w, pane, .Enter)
}

@(test)
comments_editor_saves_on_ctrl_enter_and_cancels_on_escape :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_files("src/foo.odin")
	c := &pane.comments
	testing.expect_value(t, c.editing, -1)

	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 2})
	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 3}, shift = true)
	testing.expect_value(t, c.selection, ui.Changes_Selection{file = 0, first = 2, last = 3, active = true})
	testing.expect_value(t, pane.model.view.selection, c.selection)

	// Enter opens the editor on the selection. Ctrl+Enter has nothing to save in an empty plain comment, so
	// the editor stays; Escape cancels it and leaves the selection.
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	testing.expect_value(t, c.editing, 0)
	testing.expect_value(t, pane.model.view.editing, 0)
	testing.expect(t, comments_save(&state, &w, pane))
	testing.expect_value(t, c.editing, 0)
	testing.expect_value(t, len(c.items), 0)
	testing.expect(t, comments_key(&state, &w, pane, .Escape))
	testing.expect_value(t, c.editing, -1)
	testing.expect(t, c.selection.active)

	// Enter in the editor breaks the line; Ctrl+Enter saves what was written.
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "Looks"))
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	testing.expect_value(t, c.editing, 0)
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "off."))
	testing.expect_value(t, comments_held(pane), "Looks\noff.")
	testing.expect(t, comments_save(&state, &w, pane))
	if !testing.expect_value(t, len(c.items), 1) {return}
	item := c.items[0]
	testing.expect_value(t, item.path, "src/foo.odin")
	testing.expect_value(t, item.side, app.Comment_Side.New)
	testing.expect_value(t, item.first, 11)
	testing.expect_value(t, item.last, 12)
	testing.expect_value(t, item.quote, "+c\n+d")
	testing.expect_value(t, item.text, "Looks\noff.")
	testing.expect_value(t, c.editing, -1)
	testing.expect(t, !c.selection.active, "saving ends the selection")
	testing.expect_value(t, len(pane.model.view.comments), 1)
	testing.expect_value(t, pane.model.view.comments[0].first, 2)
	testing.expect_value(t, pane.model.view.comments[0].last, 3)
	testing.expect_value(t, pane.model.view.send.count, 1)

	// Edit opens the note with its text, the caret at its end; Escape leaves it as it was.
	comments_press(&state, &w, pane, {part = .Comment_Edit, index = 0})
	testing.expect_value(t, c.editing, 0)
	testing.expect_value(t, comments_held(pane), "Looks\noff.")
	testing.expect_value(t, c.buffer.caret, len("Looks\noff."))
	testing.expect(t, app.changes_comments_text(&state, &w, pane, " Really."))
	testing.expect(t, comments_key(&state, &w, pane, .Escape))
	testing.expect_value(t, c.editing, -1)
	testing.expect_value(t, c.items[0].text, "Looks\noff.")

	// Edit then Ctrl+Enter replaces the text.
	comments_press(&state, &w, pane, {part = .Comment_Edit, index = 0})
	testing.expect(t, app.changes_comments_text(&state, &w, pane, " Really."))
	testing.expect(t, comments_save(&state, &w, pane))
	testing.expect_value(t, c.items[0].text, "Looks\noff. Really.")

	// Removed lines alone comment on the old side; Escape without an editor ends the selection.
	comments_press(&state, &w, pane, {part = .Hunk_Select, index = 0, line = 5})
	testing.expect_value(t, c.selection, ui.Changes_Selection{file = 0, first = 5, last = 6, active = true})
	testing.expect_value(t, c.editing, -1)
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	testing.expect_value(t, c.editing, 1)
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "Gone?"))
	testing.expect(t, comments_save(&state, &w, pane))
	if !testing.expect_value(t, len(c.items), 2) {return}
	testing.expect_value(t, c.items[1].side, app.Comment_Side.Old)
	testing.expect_value(t, c.items[1].first, 20)
	testing.expect_value(t, c.items[1].quote, "-x")
	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 0})
	testing.expect(t, comments_key(&state, &w, pane, .Escape))
	testing.expect(t, !c.selection.active)
	testing.expect(t, !comments_key(&state, &w, pane, .Escape), "Escape passes on with nothing selected")

	// Remove takes a note away, and Discard every note.
	comments_press(&state, &w, pane, {part = .Comment_Remove, index = 0})
	testing.expect_value(t, len(c.items), 1)
	testing.expect_value(t, c.items[0].text, "Gone?")
	comments_press(&state, &w, pane, {part = .Discard})
	testing.expect_value(t, len(c.items), 0)
	testing.expect_value(t, pane.model.view.send.count, 0)
}

@(test)
comments_editor_tools_wrap_the_selection_and_insert_blocks_and_suggestions :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_files("src/foo.odin")
	c := &pane.comments
	ctrl_b := input.Key_Event{key = .B, modifiers = {.Control}, pressed = true}

	// Bold with nothing selected wraps a word that stays selected, so typing replaces it.
	comments_open(&state, &w, pane, 2, 3)
	comments_press(&state, &w, pane, {part = .Editor_Bold, index = 0})
	testing.expect_value(t, comments_held(pane), "**bold**")
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "word"))
	testing.expect_value(t, comments_held(pane), "**word**")
	// Inline code wraps a selection.
	markdown.edit_select_all(&c.buffer)
	comments_press(&state, &w, pane, {part = .Editor_Code, index = 0})
	testing.expect_value(t, comments_held(pane), "`**word**`")

	// Ctrl+B bolds from the keyboard.
	testing.expect(t, comments_key(&state, &w, pane, .Escape))
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	testing.expect(t, app.changes_comments_key(&state, &w, pane, ctrl_b))
	testing.expect_value(t, comments_held(pane), "**bold**")

	// A code block takes the file's language and leaves the body selected.
	testing.expect(t, comments_key(&state, &w, pane, .Escape))
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	comments_press(&state, &w, pane, {part = .Editor_Block, index = 0})
	testing.expect_value(t, comments_held(pane), "```odin\n\n```\n")

	// Suggest change inserts the selected lines as they are now, to edit.
	testing.expect(t, comments_key(&state, &w, pane, .Escape))
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	comments_press(&state, &w, pane, {part = .Editor_Suggest, index = 0})
	testing.expect_value(t, comments_held(pane), "```suggestion\nc\nd\n```\n")

	// Only removed lines have no new side to suggest from.
	testing.expect(t, comments_key(&state, &w, pane, .Escape))
	comments_open(&state, &w, pane, 1, 1)
	testing.expect_value(t, pane.model.view.span.old, true)
	comments_press(&state, &w, pane, {part = .Editor_Suggest, index = 0})
	testing.expect_value(t, comments_held(pane), "")
}

@(test)
comments_editor_untags_and_adds_text_to_a_label_or_a_deletion :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_files("src/foo.odin")
	c := &pane.comments
	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 2})
	label := app.Changes_Note {
		kind              = .Label,
		label_name        = "Verify",
		label_colour      = "#ff8800",
		label_instruction = "Check it",
	}
	testing.expect(t, app.changes_comment_add(pane, label))

	// A label note opens with its tag, and its text is optional: Ctrl+Enter saves it empty.
	comments_press(&state, &w, pane, {part = .Comment_Edit, index = 0})
	testing.expect_value(t, c.draft, ui.Changes_Note_Kind.Label)
	testing.expect_value(t, pane.model.view.draft, ui.Changes_Note_Kind.Label)
	testing.expect_value(t, ui.changes_editor_placeholder(.Label), "Add to the label (optional)")
	testing.expect(t, comments_save(&state, &w, pane))
	testing.expect_value(t, c.editing, -1)
	testing.expect_value(t, c.items[0].kind, ui.Changes_Note_Kind.Label)
	testing.expect_value(t, c.items[0].text, "")
	// Words added to it are part of the note, which stays a label.
	comments_press(&state, &w, pane, {part = .Comment_Edit, index = 0})
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "Because."))
	testing.expect(t, comments_save(&state, &w, pane))
	testing.expect_value(t, c.items[0].text, "Because.")
	testing.expect_value(t, c.items[0].kind, ui.Changes_Note_Kind.Label)
	testing.expect_value(t, c.items[0].label_instruction, "Check it")

	// The × makes it a plain comment, which needs words: with none, Save does nothing.
	comments_press(&state, &w, pane, {part = .Comment_Edit, index = 0})
	comments_press(&state, &w, pane, {part = .Editor_Untag, index = 0})
	testing.expect_value(t, c.draft, ui.Changes_Note_Kind.Comment)
	testing.expect_value(t, pane.model.view.draft, ui.Changes_Note_Kind.Comment)
	markdown.edit_select_all(&c.buffer)
	testing.expect(t, comments_key(&state, &w, pane, .Delete))
	testing.expect_value(t, comments_held(pane), "")
	testing.expect_value(t, ui.changes_editor_can_save(&pane.model.view), false)
	testing.expect(t, comments_save(&state, &w, pane))
	testing.expect_value(t, c.editing, 0)
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "Plain."))
	testing.expect(t, comments_save(&state, &w, pane))
	testing.expect_value(t, c.items[0].kind, ui.Changes_Note_Kind.Comment)
	testing.expect_value(t, c.items[0].text, "Plain.")
	testing.expect_value(t, c.items[0].label_name, "")
	testing.expect_value(t, c.items[0].label_colour, "")
	testing.expect_value(t, c.items[0].label_instruction, "")
	message := app.changes_comments_message(c.items[:], context.temp_allocator)
	testing.expect(t, strings.has_suffix(message, "Plain."))
	testing.expect(t, !strings.contains(message, "Verify"))

	// A deletion is the same: it opens with its tag and its own prompt, and Escape keeps it a deletion even
	// after the ×.
	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 4})
	testing.expect(t, app.changes_comment_add(pane, {kind = .Delete}))
	comments_press(&state, &w, pane, {part = .Comment_Edit, index = 1})
	testing.expect_value(t, ui.changes_editor_placeholder(c.draft), "Why delete it? (optional)")
	comments_press(&state, &w, pane, {part = .Editor_Untag, index = 1})
	testing.expect(t, comments_key(&state, &w, pane, .Escape))
	testing.expect_value(t, c.items[1].kind, ui.Changes_Note_Kind.Delete)
}

@(test)
comments_editor_buttons_and_pressing_away :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_files("src/foo.odin")
	c := &pane.comments

	// Cancel drops the text and keeps the selection; Add note on a new comment saves it.
	comments_open(&state, &w, pane, 2, 3)
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "First."))
	comments_press(&state, &w, pane, {part = .Editor_Cancel, index = 0})
	testing.expect_value(t, c.editing, -1)
	testing.expect_value(t, len(c.items), 0)
	testing.expect(t, c.selection.active)
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "Second."))
	comments_press(&state, &w, pane, {part = .Editor_Save, index = 0})
	if !testing.expect_value(t, len(c.items), 1) {return}
	testing.expect_value(t, c.items[0].text, "Second.")

	// Save does nothing for an empty plain comment.
	comments_open(&state, &w, pane, 0, 0)
	comments_press(&state, &w, pane, {part = .Editor_Save, index = 1})
	testing.expect_value(t, c.editing, 1)
	testing.expect_value(t, len(c.items), 1)

	// Pressing on another line keeps what the editor holds, and starts the next selection.
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "Away."))
	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 4})
	testing.expect_value(t, c.editing, -1)
	if !testing.expect_value(t, len(c.items), 2) {return}
	testing.expect_value(t, c.items[1].text, "Away.")
	testing.expect_value(t, c.items[1].first_line, 0)
	testing.expect_value(t, c.selection, ui.Changes_Selection{file = 0, first = 4, last = 4, active = true})

	// The editor card reports the lines it is for.
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	testing.expect_value(t, pane.model.view.span, ui.Changes_Span{first = 13, last = 13, old = false})
	comments_press(&state, &w, pane, {part = .Comment_Edit, index = 0})
	testing.expect_value(t, pane.model.view.span, ui.Changes_Span{first = 11, last = 12, old = false})
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
	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 1})

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
	// Antigravity CLI: its arguments start the harness whatever its status says.
	can_send, _ = app.changes_send_verdict(true, "agy", .Agy, nil, {}, false, "")
	testing.expect(t, can_send)
	can_send, reason = app.changes_send_verdict(true, "agy", .Agy, nil, {}, false, "claude")
	testing.expect(t, !can_send)
	testing.expect_value(t, reason, not_running)
}

// A partial selection names the text it covers after its line range, whitespace collapsed and clipped to
// 100 characters.
@(test)
comments_message_quotes_the_text_of_a_partial_selection :: proc(t: ^testing.T) {
	long := strings.repeat("a", 150, context.temp_allocator)
	exact := strings.repeat("é", 100, context.temp_allocator)
	items := []app.Changes_Comment {
		{
			path = "a.odin", side = .New, first = 5, last = 5, quote = "+x := compute(a,   b)", text = "Why?",
			partial = true, first_offset = 5, last_offset = 20,
		},
		{
			path = "b.odin", side = .New, first = 3, last = 5, quote = " if ok {\n+\treturn  a\n+}",
			text = "Hm.", partial = true, first_offset = 3, last_offset = 1,
		},
		{
			path = "c.odin", side = .Old, first = 9, last = 9, quote = strings.concatenate({"-", long}, context.temp_allocator),
			text = "Long.", partial = true, first_offset = 0, last_offset = 150,
		},
		{
			path = "d.odin", side = .New, first = 2, last = 2, quote = strings.concatenate({"+", exact}, context.temp_allocator),
			text = "Exact.", partial = true, first_offset = 0, last_offset = len(exact),
		},
	}
	message := app.changes_comments_message(items, context.temp_allocator)
	clipped := strings.concatenate({strings.repeat("a", 99, context.temp_allocator), "…"}, context.temp_allocator)
	expected := strings.concatenate(
		{
			"Review comments on your changes:\n\n",
			"1. a.odin, line 5, at \"compute(a, b)\":\n```\n+x := compute(a,   b)\n```\nWhy?\n\n",
			"2. b.odin, lines 3-5, at \"ok { return a }\":\n```\n if ok {\n+\treturn  a\n+}\n```\nHm.\n\n",
			"3. c.odin, line 9 before the change, at \"", clipped, "\":\n```\n-", long, "\n```\nLong.\n\n",
			"4. d.odin, line 2, at \"", exact, "\":\n```\n+", exact, "\n```\nExact.",
		},
		context.temp_allocator,
	)
	testing.expect_value(t, message, expected)
}

// A label sends its name, then its instruction, then the note on its own line; a deletion says what to
// delete, then the note.
@(test)
comments_message_words_labels_and_deletions :: proc(t: ^testing.T) {
	items := []app.Changes_Comment {
		{path = "a.odin", side = .New, first = 1, last = 1, quote = "+a", kind = .Label, label_name = "Looks good"},
		{
			path = "a.odin", side = .New, first = 2, last = 3, quote = "+b\n+c", kind = .Label,
			label_name = "Verify this", label_instruction = "Check the claim before relying on it.",
		},
		{
			path = "a.odin", side = .New, first = 4, last = 4, quote = "+d", kind = .Label, label_name = "Out of scope",
			text = "Leave it for the next change.",
		},
		{
			path = "a.odin", side = .New, first = 5, last = 5, quote = "+e", kind = .Label, label_name = "Clarify this",
			label_instruction = "Explain why.", text = "The name hides it.",
		},
		{path = "a.odin", side = .Old, first = 6, last = 6, quote = "-f", kind = .Delete},
		{path = "a.odin", side = .Old, first = 7, last = 8, quote = "-g\n-h", kind = .Delete, text = "Dead code."},
		{
			path = "a.odin", side = .New, first = 9, last = 9, quote = "+i := 1", kind = .Delete, partial = true,
			first_offset = 0, last_offset = 1, text = "Unused.",
		},
	}
	message := app.changes_comments_message(items, context.temp_allocator)
	expected :=
		"Review comments on your changes:\n\n" +
		"1. a.odin, line 1:\n```\n+a\n```\nLooks good.\n\n" +
		"2. a.odin, lines 2-3:\n```\n+b\n+c\n```\nVerify this. Check the claim before relying on it.\n\n" +
		"3. a.odin, line 4:\n```\n+d\n```\nOut of scope.\nLeave it for the next change.\n\n" +
		"4. a.odin, line 5:\n```\n+e\n```\nClarify this. Explain why.\nThe name hides it.\n\n" +
		"5. a.odin, line 6 before the change:\n```\n-f\n```\nDelete this line.\n\n" +
		"6. a.odin, lines 7-8 before the change:\n```\n-g\n-h\n```\nDelete these lines. Dead code.\n\n" +
		"7. a.odin, line 9, at \"i\":\n```\n+i := 1\n```\nDelete the selected text. Unused."
	testing.expect_value(t, message, expected)
}

// A suggestion block becomes a replacement for the note's lines; other fenced blocks keep their language,
// and text around them stays.
@(test)
comments_message_turns_a_suggestion_into_a_replacement :: proc(t: ^testing.T) {
	items := []app.Changes_Comment {
		{
			path = "a.odin", side = .New, first = 12, last = 15, quote = "+a\n+b", text = "Use this:\n```suggestion\nreturn x\n```\nThen test.",
		},
		{
			path = "a.odin", side = .New, first = 7, last = 7, quote = "+c", kind = .Label, label_name = "Consider alternatives",
			text = "```suggestion\n\tx := 1\n\ty := 2\n```",
		},
		{
			path = "a.odin", side = .New, first = 8, last = 8, quote = "+d",
			text = "Like so ```odin\nfoo()\n``` and:\n```suggestion\n```",
		},
		{path = "a.odin", side = .New, first = 9, last = 9, quote = "+e", text = "Unclosed ```odin\nfoo()"},
	}
	message := app.changes_comments_message(items, context.temp_allocator)
	expected :=
		"Review comments on your changes:\n\n" +
		"1. a.odin, lines 12-15:\n```\n+a\n+b\n```\n" +
		"Use this:\nSuggested replacement for lines 12-15:\n```\nreturn x\n```\nThen test.\n\n" +
		"2. a.odin, line 7:\n```\n+c\n```\n" +
		"Consider alternatives.\nSuggested replacement for line 7:\n```\n\tx := 1\n\ty := 2\n```\n\n" +
		"3. a.odin, line 8:\n```\n+d\n```\n" +
		"Like so ```odin\nfoo()\n``` and:\nSuggested replacement for line 8:\n```\n\n```\n\n" +
		"4. a.odin, line 9:\n```\n+e\n```\nUnclosed ```odin\nfoo()"
	testing.expect_value(t, message, expected)
}

// One hunk: a context line of `text`, then an added line. With `lead`, a hunk adding a line comes first.
@(private = "file")
comments_text_files :: proc(text: string, lead := false) -> []turns.Diff_File {
	lines := make([]turns.Diff_Line, 2, context.temp_allocator)
	lines[0] = {kind = .Context, old_line = 4, new_line = 4, text = text}
	lines[1] = {kind = .Added, new_line = 5, text = "tail"}
	hunks := make([dynamic]turns.Hunk, context.temp_allocator)
	if lead {
		added := make([]turns.Diff_Line, 1, context.temp_allocator)
		added[0] = {kind = .Added, new_line = 1, text = "z"}
		append(&hunks, turns.Hunk{lines = added})
	}
	append(&hunks, turns.Hunk{lines = lines})
	files := make([]turns.Diff_File, 1, context.temp_allocator)
	files[0] = {old_path = "src/foo.odin", new_path = "src/foo.odin", hunks = hunks[:]}
	return files
}

// Saves a note on the context line with the editor, after `select` is set as the selection.
@(private = "file")
comments_save_selected :: proc(
	state: ^app.App, w: ^app.Window, pane: ^app.Changes_Pane, select: ui.Changes_Selection, text: string,
) {
	pane.comments.selection = select
	_ = comments_key(state, w, pane, .Enter)
	_ = app.changes_comments_text(state, w, pane, text)
	_ = comments_save(state, w, pane)
}

@(test)
comments_keep_the_offsets_of_a_partial_selection_unless_they_span_the_line :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	text := "  value := compute(a)"
	pane.model.view.files = comments_text_files(text)
	c := &pane.comments

	// "compute" is a part of the line: the note keeps its offsets, and the view carries them.
	comments_save_selected(
		&state, &w, pane, {file = 0, first = 0, last = 0, active = true, partial = true, first_offset = 11, last_offset = 18},
		"Name it.",
	)
	if !testing.expect_value(t, len(c.items), 1) {return}
	item := c.items[0]
	testing.expect(t, item.partial)
	testing.expect_value(t, item.first_offset, 11)
	testing.expect_value(t, item.last_offset, 18)
	testing.expect_value(t, item.kind, ui.Changes_Note_Kind.Comment)
	view := pane.model.view.comments[0]
	testing.expect(t, view.partial)
	testing.expect_value(t, view.first_offset, 11)
	testing.expect_value(t, view.last_offset, 18)

	// Offsets that span the trimmed text, indent and trailing space aside, select the whole line.
	comments_save_selected(
		&state, &w, pane, {file = 0, first = 0, last = 0, active = true, partial = true, first_offset = 2, last_offset = len(text)},
		"Whole.",
	)
	if !testing.expect_value(t, len(c.items), 2) {return}
	testing.expect(t, !c.items[1].partial)
	testing.expect_value(t, c.items[1].first_offset, 0)
	testing.expect_value(t, c.items[1].last_offset, 0)

	// A line selection has no offsets.
	comments_save_selected(&state, &w, pane, {file = 0, first = 0, last = 0, active = true}, "Line.")
	if !testing.expect_value(t, len(c.items), 3) {return}
	testing.expect(t, !c.items[2].partial)

	// Offsets out of order on one line are put in order, and offsets past the text held inside it.
	comments_save_selected(
		&state, &w, pane, {file = 0, first = 0, last = 0, active = true, partial = true, first_offset = 18, last_offset = 11},
		"Swapped.",
	)
	comments_save_selected(
		&state, &w, pane, {file = 0, first = 0, last = 0, active = true, partial = true, first_offset = 11, last_offset = 99},
		"Past.",
	)
	if !testing.expect_value(t, len(c.items), 5) {return}
	testing.expect_value(t, c.items[3].first_offset, 11)
	testing.expect_value(t, c.items[3].last_offset, 18)
	testing.expect_value(t, c.items[4].first_offset, 11)
	testing.expect_value(t, c.items[4].last_offset, len(text))
}

@(test)
comments_follow_a_refresh_with_their_offsets_held_inside_the_new_text :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_text_files("  value := compute(a)")
	c := &pane.comments
	comments_save_selected(
		&state, &w, pane, {file = 0, first = 0, last = 0, active = true, partial = true, first_offset = 11, last_offset = 18},
		"Name it.",
	)
	if !testing.expect_value(t, len(c.items), 1) {return}

	// A selection by text rides along too: held by its offsets, found again with them.
	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 0})
	c.selection.partial, c.selection.first_offset, c.selection.last_offset = true, 11, 18
	c.held.partial, c.held.first_offset, c.held.last_offset = true, 11, 18

	// The line is shorter now and one flat index further down: the view holds the offsets inside it, while
	// the note keeps the ones its quote is cut by.
	pane.model.view.files = comments_text_files("  value := comp", lead = true)
	app.changes_comments_reanchor(pane)
	testing.expect_value(t, c.items[0].first_line, 1)
	testing.expect(t, c.items[0].partial)
	testing.expect_value(t, c.items[0].first_offset, 11)
	testing.expect_value(t, c.items[0].last_offset, 18)
	testing.expect(t, pane.model.view.comments[0].partial)
	testing.expect_value(t, pane.model.view.comments[0].last_offset, 15)
	testing.expect_value(
		t, c.selection,
		ui.Changes_Selection{file = 0, first = 1, last = 1, active = true, partial = true, first_offset = 11, last_offset = 15},
	)
	message := app.changes_comments_message(c.items[:], context.temp_allocator)
	testing.expect(t, strings.contains(message, "line 4, at \"compute\":"), message)

	// A line emptied since the note was made leaves nothing to select in the view but the line itself.
	pane.model.view.files = comments_text_files("", lead = true)
	app.changes_comments_reanchor(pane)
	testing.expect(t, c.items[0].partial)
	testing.expect_value(t, c.items[0].last_offset, 18)
	testing.expect(t, !pane.model.view.comments[0].partial)
	testing.expect(t, !c.selection.partial)
	message = app.changes_comments_message(c.items[:], context.temp_allocator)
	testing.expect(t, strings.contains(message, "line 4, at \"compute\":"), message)

	// The line coming back brings the part back with it.
	pane.model.view.files = comments_text_files("  value := compute(a)", lead = true)
	app.changes_comments_reanchor(pane)
	testing.expect(t, pane.model.view.comments[0].partial)
	testing.expect_value(t, pane.model.view.comments[0].last_offset, 18)
}

// One hunk: a removed line, then an added line, each with `text`'s two versions.
@(private = "file")
comments_changed_files :: proc(removed, added: string) -> []turns.Diff_File {
	lines := make([]turns.Diff_Line, 2, context.temp_allocator)
	lines[0] = {kind = .Removed, old_line = 4, text = removed}
	lines[1] = {kind = .Added, new_line = 4, text = added}
	hunks := make([]turns.Hunk, 1, context.temp_allocator)
	hunks[0] = {lines = lines}
	files := make([]turns.Diff_File, 1, context.temp_allocator)
	files[0] = {old_path = "src/foo.odin", new_path = "src/foo.odin", hunks = hunks}
	return files
}

@(test)
a_partial_note_from_a_removed_line_into_an_added_one_keeps_its_text_through_a_refresh :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_changed_files("  value := compute(a)", "  value := compute(b)")
	c := &pane.comments
	comments_save_selected(
		&state, &w, pane, {file = 0, first = 0, last = 1, active = true, partial = true, first_offset = 11, last_offset = 18},
		"Both.",
	)
	if !testing.expect_value(t, len(c.items), 1) {return}
	testing.expect(t, pane.model.view.comments[0].partial)

	// The same diff again: the ends resolve to the added line alone, so offsets of the removed line's text
	// must not be applied to it; the note's own offsets and message stay.
	app.changes_comments_reanchor(pane)
	testing.expect(t, !pane.model.view.comments[0].partial)
	testing.expect_value(t, c.items[0].first_offset, 11)
	testing.expect_value(t, c.items[0].last_offset, 18)
	message := app.changes_comments_message(c.items[:], context.temp_allocator)
	testing.expect(t, strings.contains(message, "at \"compute(a) value := compute\""), message)
}

@(test)
comments_keep_a_copy_of_the_label_they_were_made_with :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_files("src/foo.odin")
	c := &pane.comments
	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 2})
	name := strings.clone("Verify this")
	colour := strings.clone("#ff8800")
	instruction := strings.clone("Check the claim.")
	defer delete(name)
	defer delete(colour)
	defer delete(instruction)
	note := app.Changes_Note {
		kind              = .Label,
		label_name        = name,
		label_colour      = colour,
		label_instruction = instruction,
	}
	testing.expect(t, app.changes_comment_add(pane, note))
	if !testing.expect_value(t, len(c.items), 1) {return}
	item := c.items[0]
	testing.expect_value(t, item.kind, ui.Changes_Note_Kind.Label)
	testing.expect_value(t, item.label_name, "Verify this")
	testing.expect_value(t, item.label_colour, "#ff8800")
	testing.expect_value(t, item.label_instruction, "Check the claim.")
	testing.expect_value(t, item.text, "")
	// The note owns its strings: the label can change without touching it.
	testing.expect(t, raw_data(item.label_name) != raw_data(name))
	testing.expect(t, raw_data(item.label_instruction) != raw_data(instruction))
	testing.expect(t, !c.selection.active, "adding a note ends the selection")

	app.changes_comments_view(&state, pane)
	view := pane.model.view.comments[0]
	testing.expect_value(t, view.kind, ui.Changes_Note_Kind.Label)
	testing.expect_value(t, view.label_name, "Verify this")
	testing.expect_value(t, view.label_colour, "#ff8800")

	// A deletion with no text is a note too, and the message tells the agent to delete the line.
	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 1})
	testing.expect(t, app.changes_comment_add(pane, {kind = .Delete}))
	if !testing.expect_value(t, len(c.items), 2) {return}
	message := app.changes_comments_message(c.items[:], context.temp_allocator)
	testing.expect(t, strings.has_suffix(message, "Delete this line."))
	testing.expect(t, strings.contains(message, "Verify this. Check the claim."))
}

// What the editor and the toolbar write, end to end: a text selection with a suggestion from the tool, a label
// from its key and a deletion from its key, in the message Send and Copy give.
@(test)
comments_message_follows_the_editor_the_label_key_and_the_delete_key :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	state.settings.turns.quick_labels = "Clarify | blue | Explain why"
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_text_files("  value := compute(a)")
	c := &pane.comments

	// "compute" with a comment and the suggestion tool, saved with Ctrl+Enter.
	c.selection = {file = 0, first = 0, last = 0, active = true, partial = true, first_offset = 11, last_offset = 18}
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	testing.expect(t, app.changes_comments_text(&state, &w, pane, "Rename it:"))
	comments_press(&state, &w, pane, {part = .Editor_Suggest, index = 0})
	testing.expect(t, comments_save(&state, &w, pane))
	// The added line takes a label with Alt+1, and the context line a deletion with Delete.
	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 1})
	testing.expect(t, app.changes_comments_key(&state, &w, pane, {key = .Digit_1, modifiers = {.Alt}, pressed = true}))
	comments_press(&state, &w, pane, {part = .Gutter, index = 0, line = 0})
	testing.expect(t, comments_key(&state, &w, pane, .Delete))
	if !testing.expect_value(t, len(c.items), 3) {return}
	testing.expect_value(t, c.items[0].text, "Rename it:\n```suggestion\n  value := compute(a)\n```")

	message := app.changes_comments_message(c.items[:], context.temp_allocator)
	testing.expect(t, strings.contains(message, "1. src/foo.odin, line 4, at \"compute\":\n"), message)
	testing.expect(
		t, strings.contains(message, "Rename it:\nSuggested replacement for line 4:\n```\n  value := compute(a)\n```"),
		message,
	)
	testing.expect(t, strings.contains(message, "2. src/foo.odin, line 5:\n```\n+tail\n```\nClarify. Explain why"), message)
	testing.expect(t, strings.has_suffix(message, "3. src/foo.odin, line 4:\n```\n   value := compute(a)\n```\nDelete this line."), message)
}

@(test)
a_left_cell_note_over_removed_and_context_lines_reanchors_whole :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	lines := make([]turns.Diff_Line, 3, context.temp_allocator)
	lines[0] = {kind = .Removed, old_line = 3, text = "old"}
	lines[1] = {kind = .Added, new_line = 3, text = "new"}
	lines[2] = {kind = .Context, old_line = 4, new_line = 4, text = "same"}
	hunks := make([]turns.Hunk, 1, context.temp_allocator)
	hunks[0] = {lines = lines}
	files := make([]turns.Diff_File, 1, context.temp_allocator)
	files[0] = {old_path = "src/foo.odin", new_path = "src/foo.odin", hunks = hunks}
	pane.model.view.files = files
	c := &pane.comments
	comments_save_selected(
		&state, &w, pane, {file = 0, first = 0, last = 2, active = true, half = .Left}, "Left.",
	)
	if !testing.expect_value(t, len(c.items), 1) {return}
	// The left cell is the old file: the context line counts by its old number, so both ends are found again.
	testing.expect_value(t, c.items[0].side, app.Comment_Side.Old)
	testing.expect_value(t, c.items[0].first, i32(3))
	testing.expect_value(t, c.items[0].last, i32(4))
	app.changes_comments_reanchor(pane)
	testing.expect_value(t, c.items[0].first_line, 0)
	testing.expect_value(t, c.items[0].last_line, 2)
}

@(test)
context_lines_selected_in_the_left_cell_stay_on_the_new_side_and_take_a_suggestion :: proc(t: ^testing.T) {
	state: app.App
	defer app.changes_app_destroy(&state.changes_state)
	w: app.Window
	pane := app.changes_pane_create(&state, {}, "C:/work/odin", .Repository)
	if !testing.expect(t, pane != nil) {return}
	pane.model.view.files = comments_text_files("  value := compute(a)")
	c := &pane.comments
	c.selection = {file = 0, first = 0, last = 0, active = true, half = .Left}
	testing.expect(t, comments_key(&state, &w, pane, .Enter))
	testing.expect_value(t, pane.model.view.span.old, false)
	comments_press(&state, &w, pane, {part = .Editor_Suggest, index = 0})
	testing.expect(t, strings.contains(markdown.edit_string(&c.buffer), "```suggestion"))
	testing.expect(t, comments_save(&state, &w, pane))
	if !testing.expect_value(t, len(c.items), 1) {return}
	testing.expect_value(t, c.items[0].side, app.Comment_Side.New)
}
