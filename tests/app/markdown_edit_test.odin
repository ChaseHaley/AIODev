package app_test

import "aio:input"
import "aio:markdown"
import "aio:platform"
import "aio:ui"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import app "../../src"

@(private = "file")
Edit_Fixture :: struct {
	state:     app.App,
	directory: string,
	file:      string,
}

@(private = "file")
edit_fixture_start :: proc(
	t: ^testing.T,
	f: ^Edit_Fixture,
	name, source: string,
) -> (
	^app.Window,
	^app.Markdown_Pane,
) {
	directory, err := os.make_directory_temp("", "aio-markdown-edit-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return nil, nil}
	f.directory = directory
	f.file = strings.concatenate({directory, "\\note.md"})
	settings := idle_shell_settings(t, "cursor.blink = false\n")
	settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings), nil) {return nil, nil}
	if !testing.expect_value(t, os.write_entire_file(f.file, source), nil) {return nil, nil}
	f.state = {options = {data_dir = f.directory, inactive = true}}
	f.state.app_id = fmt.aprintf("AIODev.Test.MarkdownEdit.%s.%d", name, os.get_pid())
	initialized := platform.init(&f.state.platform, f.state.app_id)
	if !testing.expect_value(t, initialized, platform.Init_Result.Primary) {
		return nil, nil
	}
	f.state.platform_ready = true
	f.state.animations = false
	if !testing.expect(t, app.app_init(&f.state)) {return nil, nil}
	w := f.state.windows[0]
	w.focused = true
	node := app.window_tree(w).focus
	if !app.markdown_open_at(&f.state, w, w.workspace, w.workspace.selected, node, f.file, focus = true) {
		testing.expect(t, false, "the file did not open")
		return nil, nil
	}
	if !testing.expect_value(t, len(f.state.markdown_panes), 1) {return nil, nil}
	pane := f.state.markdown_panes[0]
	if !testing.expect(t, app.markdown_focused(&f.state, w) == pane) {return nil, nil}
	return w, pane
}

@(private = "file")
edit_fixture_destroy :: proc(t: ^testing.T, f: ^Edit_Fixture) {
	app.app_destroy(&f.state)
	delete(f.file)
	testing.expect_value(t, os.remove_all(f.directory), nil)
	delete(f.directory)
}

@(private = "file")
file_text :: proc(t: ^testing.T, path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	return string(data)
}

// The pane laid out as its draw lays it out, and where its page sits.
@(private = "file")
edit_fitted :: proc(state: ^app.App, w: ^app.Window, pane: ^app.Markdown_Pane) -> (g: ui.Markdown_Geometry) {
	for shown in w.panes {
		if shown.content != {.Markdown, pane.id} {continue}
		g = ui.markdown_geometry(app.pane_body_rect(w, shown), w.scale, state.markdown_style.column)
		app.markdown_view_fitted(state, w, pane, app.markdown_document(pane), g)
	}
	return
}

// Clicks the checkbox of the task whose mark is at `mark`, wherever it shows.
@(private = "file")
task_click :: proc(t: ^testing.T, state: ^app.App, w: ^app.Window, pane: ^app.Markdown_Pane, mark: int) {
	g := edit_fitted(state, w, pane)
	document := app.markdown_document(pane)
	for y := g.top; y < g.area.y + g.area.height; y += 1 {
		for x := g.area.x; x < g.left + g.width; x += 1 {
			if ui.markdown_task_at(&pane.view, document, g, x, y) != mark {continue}
			for pressed in ([?]bool{true, false}) {
				app.handle_event(state, input.Mouse_Button_Event{window = w.id, x = i32(x), y = i32(y),
					button = .Left, pressed = pressed})
			}
			return
		}
	}
	testing.expect(t, false, "the checkbox is not on screen")
}

@(private = "file")
edit_press :: proc(state: ^app.App, w: ^app.Window, key: input.Key, modifiers: input.Modifiers = {}) {
	app.handle_event(state, input.Key_Event{window = w.id, key = key, modifiers = modifiers, pressed = true})
	app.handle_event(state, input.Key_Event{window = w.id, key = key, modifiers = modifiers})
}

// Lets the pending save fall due and runs the timer that saves it.
@(private = "file")
save_now :: proc(state: ^app.App, pane: ^app.Markdown_Pane) {
	if pane.editor != nil && pane.editor.save_at != {} {pane.editor.save_at = time.tick_now()}
	app.markdown_tick(state)
}

// A checkbox click writes only the task's mark, keeping the file's line endings, whether the pane reads
// or edits the file; while editing, undo takes it back.
@(test)
ticking_a_task_writes_only_its_mark :: proc(t: ^testing.T) {
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	source := "# Tasks\r\n\r\n- [ ] first\r\n- [x] second\r\n"
	w, pane := edit_fixture_start(t, &f, "Tick", source)
	if pane == nil {return}
	first := strings.index(source, "[ ]") + 1
	task_click(t, &f.state, w, pane, first)
	testing.expect_value(t, file_text(t, f.file), "# Tasks\r\n\r\n- [x] first\r\n- [x] second\r\n")
	document := app.markdown_document(pane)
	done := 0
	for block in document.blocks {if block.task == .Done {done += 1}}
	testing.expect_value(t, done, 2)

	app.run_action(&f.state, w, .Edit_Markdown)
	if !testing.expect(t, app.markdown_editing(pane)) {return}
	second := strings.index(source, "[x]") + 1
	task_click(t, &f.state, w, pane, second)
	save_now(&f.state, pane)
	testing.expect_value(t, file_text(t, f.file), "# Tasks\r\n\r\n- [x] first\r\n- [ ] second\r\n")
	edit_press(&f.state, w, .Z, {.Control})
	save_now(&f.state, pane)
	testing.expect_value(t, file_text(t, f.file), "# Tasks\r\n\r\n- [x] first\r\n- [x] second\r\n")
}

// Typing changes the file only once the save falls due; turning edit mode off saves what waits and
// shows the saved text rendered.
@(test)
edits_save_after_a_pause_and_when_editing_ends :: proc(t: ^testing.T) {
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	w, pane := edit_fixture_start(t, &f, "Save", "# Title\n\n- item\n")
	if pane == nil {return}
	app.run_action(&f.state, w, .Edit_Markdown)
	if !testing.expect(t, app.markdown_editing(pane)) {return}
	edit_press(&f.state, w, .End, {.Control})
	edit_press(&f.state, w, .Arrow_Left)
	edit_press(&f.state, w, .Enter)
	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "next"})
	testing.expect(t, pane.editor.save_at != {})
	testing.expect_value(t, file_text(t, f.file), "# Title\n\n- item\n")
	save_now(&f.state, pane)
	testing.expect_value(t, file_text(t, f.file), "# Title\n\n- item\n- next\n")
	testing.expect(t, pane.editor.save_at == {})
	// Its own save does not read the file back over the caret.
	app.markdown_tick(&f.state)
	testing.expect_value(t, pane.editor.buffer.caret, len("# Title\n\n- item\n- next"))

	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "!"})
	app.run_action(&f.state, w, .Edit_Markdown)
	testing.expect(t, !app.markdown_editing(pane))
	testing.expect_value(t, file_text(t, f.file), "# Title\n\n- item\n- next!\n")
	document := app.markdown_document(pane)
	testing.expect(t, !document.live)
	testing.expect(t, strings.contains(string(document.text[:]), "next!"))
}

// While editing, the caret's line shows its markup and the other lines show rendered.
@(test)
the_caret_line_shows_its_markup_while_the_rest_renders :: proc(t: ^testing.T) {
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	w, pane := edit_fixture_start(t, &f, "Live", "# Title\n\nSome **bold** text")
	if pane == nil {return}
	app.run_action(&f.state, w, .Edit_Markdown)
	if !testing.expect(t, app.markdown_editing(pane)) {return}
	edit_press(&f.state, w, .End, {.Control})
	text := string(app.markdown_document(pane).text[:])
	testing.expect(t, strings.has_prefix(text, "Title\n"), text)
	testing.expect(t, strings.contains(text, "Some **bold** text"), text)
	edit_press(&f.state, w, .Home, {.Control})
	text = string(app.markdown_document(pane).text[:])
	testing.expect(t, strings.has_prefix(text, "# Title\n"), text)
	testing.expect(t, strings.contains(text, "Some bold text"), text)
}

// Clicks link `link` of the pane where it first shows, and says whether it was on screen.
@(private = "file")
edit_link_click :: proc(state: ^app.App, w: ^app.Window, pane: ^app.Markdown_Pane, link: int) -> bool {
	g := edit_fitted(state, w, pane)
	for y := g.top; y < g.area.y + g.area.height; y += 1 {
		for x := g.left; x < g.left + g.width; x += 2 {
			if ui.markdown_link_at(&pane.view, g, x, y) != link {continue}
			for pressed in ([?]bool{true, false}) {
				app.handle_event(state, input.Mouse_Button_Event{window = w.id, x = i32(x), y = i32(y),
					button = .Left, pressed = pressed})
			}
			return true
		}
	}
	return false
}

// While editing, a click opens a rendered link, but on the caret's line, shown as source, it moves the
// caret into the link's text instead.
@(test)
a_click_opens_a_rendered_link_but_edits_one_shown_as_source :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	w, pane := edit_fixture_start(t, &f, "EditLink", "See [site](https://example.com)\n\nend")
	if pane == nil {return}
	Open_Stub_State = {}
	f.state.opener.url = link_open_stub
	defer f.state.opener.url = nil
	app.run_action(&f.state, w, .Edit_Markdown)
	if !testing.expect(t, app.markdown_editing(pane)) {return}
	edit_press(&f.state, w, .Home, {.Control})
	if !testing.expect(t, edit_link_click(&f.state, w, pane, 0)) {return}
	testing.expect_value(t, Open_Stub_State.calls, 0)
	caret := pane.editor.buffer.caret
	testing.expect(t, caret >= len("See [") && caret <= len("See [site"), fmt.tprint(caret))

	edit_press(&f.state, w, .End, {.Control})
	if !testing.expect(t, edit_link_click(&f.state, w, pane, 0)) {return}
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect_value(t, Open_Stub_State.uri, "https://example.com")
}

// A change on disk replaces the editor's text when nothing waits to save, and loses to edits that do.
@(test)
a_file_changed_on_disk_reloads_unless_edits_wait :: proc(t: ^testing.T) {
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	w, pane := edit_fixture_start(t, &f, "Reload", "one\n")
	if pane == nil {return}
	app.run_action(&f.state, w, .Edit_Markdown)
	if !testing.expect(t, app.markdown_editing(pane)) {return}
	// A stamp the poll has not seen, whatever the clock's resolution.
	if !testing.expect_value(t, os.write_entire_file(f.file, "two, from disk\n"), nil) {return}
	f.state.markdown_deadline = time.tick_now()
	app.markdown_tick(&f.state)
	testing.expect_value(t, markdown.edit_string(&pane.editor.buffer), "two, from disk\n")

	app.handle_event(&f.state, input.Text_Event{window = w.id, text = "mine "})
	if !testing.expect_value(t, os.write_entire_file(f.file, "three, longer from disk\n"), nil) {return}
	f.state.markdown_deadline = time.tick_now()
	app.markdown_tick(&f.state)
	testing.expect(t, strings.contains(markdown.edit_string(&pane.editor.buffer), "mine "))
	save_now(&f.state, pane)
	testing.expect(t, strings.contains(file_text(t, f.file), "mine "))
}

// A second pane showing the file reads what the first edits as it is typed or pasted, not once the save
// falls due and the poll reads it, and does not read its own file back after that save.
@(test)
a_pane_reading_the_file_shows_edits_before_they_save :: proc(t: ^testing.T) {
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	w, reader := edit_fixture_start(t, &f, "Follow", "# Title\n\nbody\n")
	if reader == nil {return}
	node := app.window_tree(w).focus
	if !testing.expect(t, app.markdown_open_placed(&f.state, w, node, f.file, .Split_Down)) {return}
	if !testing.expect_value(t, len(f.state.markdown_panes), 2) {return}
	editor := f.state.markdown_panes[1]
	if !testing.expect(t, app.markdown_focused(&f.state, w) == editor) {return}
	app.run_action(&f.state, w, .Edit_Markdown)
	if !testing.expect(t, app.markdown_editing(editor)) {return}

	edit_press(&f.state, w, .End, {.Control})
	if !testing.expect(t, platform.clipboard_set_text(&f.state.platform, "pasted\n\n- more\n")) {return}
	edit_press(&f.state, w, .V, {.Control})
	if !testing.expect(t, strings.contains(markdown.edit_string(&editor.editor.buffer), "- more")) {return}
	testing.expect_value(t, file_text(t, f.file), "# Title\n\nbody\n")
	app.tick(&f.state)
	shown := string(app.markdown_document(reader).text[:])
	testing.expect(t, strings.contains(shown, "pasted"), shown)
	testing.expect(t, strings.contains(shown, "more"), shown)
	testing.expect_value(t, file_text(t, f.file), "# Title\n\nbody\n")

	revision := reader.revision
	save_now(&f.state, editor)
	testing.expect_value(t, file_text(t, f.file), "# Title\n\nbody\npasted\n\n- more\n")
	f.state.markdown_deadline = time.tick_now()
	app.markdown_tick(&f.state)
	testing.expect_value(t, reader.revision, revision)
}

// A save by another program shows in the pane when the folder reports it, without waiting for the poll.
@(test)
a_change_on_disk_shows_without_waiting_for_the_poll :: proc(t: ^testing.T) {
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	_, pane := edit_fixture_start(t, &f, "Watch", "one\n")
	if pane == nil {return}
	testing.expect(t, pane.watch != 0)
	// The poll is an hour away, so only the watch can bring the new text in.
	f.state.markdown_deadline = time.tick_add(time.tick_now(), time.Hour)
	if !testing.expect_value(t, os.write_entire_file(f.file, "two, from disk\n"), nil) {return}
	shown := false
	for _ in 0 ..< 300 {
		time.sleep(10 * time.Millisecond)
		app.markdown_tick(&f.state)
		if strings.contains(string(app.markdown_document(pane).text[:]), "two, from disk") {
			shown = true
			break
		}
	}
	testing.expect(t, shown, "the pane never showed the saved text")
}

// Pasted text takes the buffer's own line endings, whichever it arrives with, and goes in whole when it
// already has them.
@(test)
pasted_text_takes_the_files_line_endings :: proc(t: ^testing.T) {
	cases := [?]struct {
		source, clipboard, want: string,
	} {
		{"a\n", "x\r\ny\rz\nw", "a\nx\ny\nz\nw"},
		{"a\r\n", "x\ny\rz\r\nw", "a\r\nx\r\ny\r\nz\r\nw"},
		{"a\n", "x\ny\n", "a\nx\ny\n"},
		{"a\r\n", "x\r\ny\r\n", "a\r\nx\r\ny\r\n"},
	}
	for c in cases {
		f: Edit_Fixture
		defer edit_fixture_destroy(t, &f)
		w, pane := edit_fixture_start(t, &f, "Paste", c.source)
		if pane == nil {return}
		app.run_action(&f.state, w, .Edit_Markdown)
		if !testing.expect(t, app.markdown_editing(pane)) {return}
		edit_press(&f.state, w, .End, {.Control})
		if !testing.expect(t, platform.clipboard_set_text(&f.state.platform, c.clipboard)) {return}
		edit_press(&f.state, w, .V, {.Control})
		testing.expect_value(t, markdown.edit_string(&pane.editor.buffer), c.want)
	}
}

// Windows delivers a typed character as its key's text, not as a text event of its own; AltGr's
// Ctrl+Alt types, while a Ctrl chord's control character does not.
@(test)
keys_type_the_text_windows_gives_them :: proc(t: ^testing.T) {
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	w, pane := edit_fixture_start(t, &f, "Keys", "")
	if pane == nil {return}
	app.run_action(&f.state, w, .Edit_Markdown)
	if !testing.expect(t, app.markdown_editing(pane)) {return}
	typed := [?]struct {
		key:       input.Key,
		modifiers: input.Modifiers,
		text:      string,
	}{{.H, {}, "h"}, {.A, {}, "a"}, {.Digit_1, {.Shift}, "!"}, {.E, {.Control, .Alt}, "€"}, {.B, {.Control}, "\x02"}}
	for k in typed {
		app.handle_event(&f.state, input.Key_Event{window = w.id, key = k.key, modifiers = k.modifiers,
			pressed = true, text = k.text})
		app.handle_event(&f.state, input.Key_Event{window = w.id, key = k.key, modifiers = k.modifiers})
	}
	testing.expect_value(t, markdown.edit_string(&pane.editor.buffer), "ha!€")
}

// Clicks the fold chevron of the heading whose text starts at `offset`, wherever it shows.
@(private = "file")
chevron_click :: proc(t: ^testing.T, state: ^app.App, w: ^app.Window, pane: ^app.Markdown_Pane, offset: int) {
	g := edit_fitted(state, w, pane)
	document := app.markdown_document(pane)
	heading := markdown.block_at(document, offset)
	for y := g.top; y < g.area.y + g.area.height; y += 1 {
		for x := g.area.x; x < g.left; x += 1 {
			found, on := ui.markdown_fold_at(&pane.view, document, g, x, y)
			if found != heading || !on {continue}
			for pressed in ([?]bool{true, false}) {
				app.handle_event(state, input.Mouse_Button_Event{window = w.id, x = i32(x), y = i32(y),
					button = .Left, pressed = pressed})
			}
			return
		}
	}
	testing.expect(t, false, "the chevron is not on screen")
}

// A heading's chevron folds its section, up to the next heading of its level, and folds it back out.
// While editing, the caret moving into a folded section unfolds it.
@(test)
headings_fold_their_sections :: proc(t: ^testing.T) {
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	source := "# Top\n\n## One\n\nhidden text\n\n### Deeper\n\nalso hidden\n\n## Two\n\nshown\n"
	w, pane := edit_fixture_start(t, &f, "Fold", source)
	if pane == nil {return}
	edit_fitted(&f.state, w, pane)
	tall := pane.view.height
	chevron_click(t, &f.state, w, pane, strings.index(string(app.markdown_document(pane).text[:]), "One"))
	testing.expect_value(t, len(pane.folds.folds), 1)
	edit_fitted(&f.state, w, pane)
	testing.expect(t, pane.view.height < tall, "the section's lines are gone")
	// A hidden offset finds the first shown line after it: the next heading of the folded one's level.
	document := app.markdown_document(pane)
	hidden, _ := ui.markdown_offset_top(&pane.view, strings.index(string(document.text[:]), "also hidden"))
	two, _ := ui.markdown_offset_top(&pane.view, strings.index(string(document.text[:]), "Two"))
	testing.expect_value(t, hidden, two)

	app.run_action(&f.state, w, .Edit_Markdown)
	if !testing.expect(t, app.markdown_editing(pane)) {return}
	testing.expect_value(t, len(pane.folds.folds), 1)
	// From the start of "## Two", Left steps back into the folded section above it.
	edit_press(&f.state, w, .End, {.Control})
	for _ in 0 ..< 3 {edit_press(&f.state, w, .Arrow_Up)}
	edit_press(&f.state, w, .Home)
	testing.expect(t, strings.has_prefix(source[pane.editor.buffer.caret:], "## Two"))
	testing.expect_value(t, len(pane.folds.folds), 1)
	edit_press(&f.state, w, .Arrow_Left)
	testing.expect_value(t, len(pane.folds.folds), 0)
}

// Open in Default App hands the pane's file to the system's handler.
@(test)
open_in_default_app_hands_over_the_pane_file :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	w, pane := edit_fixture_start(t, &f, "External", "# Note\n")
	if pane == nil {return}
	Open_Stub_State = {}
	f.state.opener.file = link_file_stub
	defer f.state.opener.file = nil
	testing.expect(t, app.action_available(&f.state, w, .Open_Markdown_Default_App))
	app.run_action(&f.state, w, .Open_Markdown_Default_App)
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect(t, strings.equal_fold(Open_Stub_State.uri, pane.path), Open_Stub_State.uri)
}

// Where the caret at source offset `source` stands, in window coordinates, laid out as the pane draws.
@(private = "file")
edit_caret_point :: proc(
	state: ^app.App,
	w: ^app.Window,
	pane: ^app.Markdown_Pane,
	source: int,
) -> (
	x, y, height: f32,
	found: bool,
) {
	g := edit_fitted(state, w, pane)
	document := app.markdown_document(pane)
	rect, _, shown := ui.markdown_caret_at(&pane.view, document, markdown.live_display(document, source))
	return g.left + rect.x, g.top - f32(pane.view.scroll) + rect.y, rect.height, shown
}

// Markdown style settings lay an open pane out again as they change. While editing, the caret still
// stands on its character: a click where it is drawn puts it back on the same offset, and a heading's
// fold chevron follows its taller line.
@(test)
markdown_style_changes_keep_the_caret_and_folds_mapped :: proc(t: ^testing.T) {
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	source := "# Title\n\nbody text here\n\n## Next\n\nmore"
	w, pane := edit_fixture_start(t, &f, "Style", source)
	if pane == nil {return}
	app.run_action(&f.state, w, .Edit_Markdown)
	if !testing.expect(t, app.markdown_editing(pane)) {return}
	caret := len("# Title\n\nbody te")
	edit_press(&f.state, w, .End, {.Control})
	_, before_y, before_height, before_found := edit_caret_point(&f.state, w, pane, caret)
	if !testing.expect(t, before_found) {return}
	g := edit_fitted(&f.state, w, pane)
	before_width := g.width
	// Half the column, in whole DIPs, whatever the test window's size.
	half := fmt.tprintf("%d", int(g.width / w.scale / 2))

	changes := [?][2]string {
		{"markdown.h1_size", "3"},
		{"markdown.font_size", "15"},
		{"markdown.line_height", "2"},
		{"markdown.text_width", half},
	}
	for change in changes {
		if !testing.expect(t, app.settings_save_value(&f.state, change[0], change[1], "set")) {return}
	}
	testing.expect_value(t, f.state.markdown_style.headings[0], 3)
	x, y, height, found := edit_caret_point(&f.state, w, pane, caret)
	if !testing.expect(t, found) {return}
	g = edit_fitted(&f.state, w, pane)
	testing.expect(t, g.width < before_width, "the text width applies")
	testing.expect(t, y > before_y && height > before_height, "the sizes apply")
	for pressed in ([?]bool{true, false}) {
		app.handle_event(&f.state, input.Mouse_Button_Event{window = w.id, x = i32(math.round(x)),
			y = i32(y + height / 2), button = .Left, pressed = pressed})
	}
	testing.expect_value(t, pane.editor.buffer.caret, caret)
	// The same holds for keys: End lands at the line's end, where the layout says it is.
	edit_press(&f.state, w, .End)
	end := len("# Title\n\nbody text here")
	testing.expect_value(t, pane.editor.buffer.caret, end)
	end_x, end_y, _, end_found := edit_caret_point(&f.state, w, pane, end)
	testing.expect(t, end_found && end_x > x && end_y == y)

	chevron_click(t, &f.state, w, pane, strings.index(string(app.markdown_document(pane).text[:]), "Next"))
	testing.expect_value(t, len(pane.folds.folds), 1)
}

@(private = "file")
Click_Step :: struct {
	x, y:      f32,
	time_ns:   i64,
	button:    input.Mouse_Button,
	modifiers: input.Modifiers,
}

// A press and release of a mouse button at the window point, `time_ns` after the clock's start.
@(private = "file")
mouse_click :: proc(state: ^app.App, w: ^app.Window, step: Click_Step, release := true) {
	for pressed in ([?]bool{true, false}) {
		if !pressed && !release {break}
		app.handle_event(state, input.Mouse_Button_Event{window = w.id, x = i32(math.round(step.x)),
			y = i32(math.round(step.y)), button = step.button, pressed = pressed,
			modifiers = step.modifiers, time_ns = step.time_ns})
	}
}

// The window point just inside the left edge of the character at source offset `source`, which a click
// takes as the boundary before it, with the pane laid out as its draw lays it out now.
@(private = "file")
char_point :: proc(
	t: ^testing.T,
	state: ^app.App,
	w: ^app.Window,
	pane: ^app.Markdown_Pane,
	source: int,
) -> (x, y: f32, ok: bool) {
	g := edit_fitted(state, w, pane)
	document := app.markdown_document(pane)
	display := markdown.live_display(document, source)
	rect, _, found := ui.markdown_caret_at(&pane.view, document, display)
	if !testing.expect(t, found, "the character is not on screen") {return}
	return g.left + rect.x + 1, g.top - f32(pane.view.scroll) + rect.y + rect.height / 2, true
}

@(private = "file")
selected :: proc(pane: ^app.Markdown_Pane) -> string {
	return markdown.edit_selected_text(&pane.editor.buffer)
}

// The first click of a double click moves the caret onto a rendered line, which then shows its markup and
// shifts the text under the pointer. The second click still selects the word the first one hit, the third
// the line, a drag after either grows by words or lines, and the keys then adjust the selection from the
// anchor.
@(test)
a_double_click_selects_the_word_the_first_click_hit_and_shift_arrows_adjust_it :: proc(t: ^testing.T) {
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	source := "# Title\n\nalpha **bold** gamma\n\nlast line here\n"
	w, pane := edit_fixture_start(t, &f, "Words", source)
	if pane == nil {return}
	app.run_action(&f.state, w, .Edit_Markdown)
	if !testing.expect(t, app.markdown_editing(pane)) {return}
	b := &pane.editor.buffer
	gamma := strings.index(source, "gamma")
	line := strings.index(source, "alpha")
	line_end := strings.index(source[line:], "\n") + line

	// The line is rendered, so its words sit where the markup is hidden.
	x, y, found := char_point(t, &f.state, w, pane, gamma + 2)
	if !found {return}
	mouse_click(&f.state, w, {x, y, 1_000_000, .Left, {}})
	testing.expect_value(t, b.caret, gamma + 2)
	// The caret's line now shows its markup, which moves the word right: the same point is on other text.
	shifted, _, _ := char_point(t, &f.state, w, pane, gamma + 2)
	testing.expect(t, shifted > x + 1, "the first click should have shifted the line")

	mouse_click(&f.state, w, {x, y, 101_000_000, .Left, {}}, release = false)
	testing.expect_value(t, selected(pane), "gamma")
	// Dragging with the button held keeps the word and grows by words.
	ax, ay, _ := char_point(t, &f.state, w, pane, line + 2)
	app.handle_event(&f.state, input.Mouse_Move_Event{window = w.id, x = i32(ax), y = i32(ay), buttons = {.Left}})
	testing.expect_value(t, selected(pane), source[line:line_end])
	testing.expect_value(t, b.anchor, line_end)
	bx, by, _ := char_point(t, &f.state, w, pane, gamma + 2)
	app.handle_event(&f.state, input.Mouse_Move_Event{window = w.id, x = i32(bx), y = i32(by), buttons = {.Left}})
	testing.expect_value(t, selected(pane), "gamma")
	app.handle_event(&f.state, input.Mouse_Button_Event{window = w.id, x = i32(bx), y = i32(by),
		button = .Left, time_ns = 102_000_000})

	// Shift+arrows adjust the word from its anchor, at its start.
	edit_press(&f.state, w, .Arrow_Left, {.Shift})
	testing.expect_value(t, selected(pane), "gamm")
	edit_press(&f.state, w, .Arrow_Right, {.Shift, .Control})
	testing.expect_value(t, selected(pane), "gamma")
	edit_press(&f.state, w, .Home, {.Shift})
	testing.expect_value(t, selected(pane), source[line:gamma])
	testing.expect_value(t, b.anchor, gamma)
	edit_press(&f.state, w, .End, {.Shift})
	testing.expect_value(t, selected(pane), "gamma")
	edit_press(&f.state, w, .Arrow_Down, {.Shift})
	testing.expect_value(t, selected(pane), "gamma\n")
	testing.expect_value(t, b.anchor, gamma)

	// Leave the line so it renders again; then three clicks in a run on it, the layout redrawn between.
	edit_press(&f.state, w, .End, {.Control})
	x, y, _ = char_point(t, &f.state, w, pane, gamma + 2)
	mouse_click(&f.state, w, {x, y, 2_000_000_000, .Left, {}})
	_ = edit_fitted(&f.state, w, pane)
	mouse_click(&f.state, w, {x, y, 2_100_000_000, .Left, {}})
	testing.expect_value(t, selected(pane), "gamma")
	_ = edit_fitted(&f.state, w, pane)
	mouse_click(&f.state, w, {x, y, 2_200_000_000, .Left, {}})
	testing.expect_value(t, selected(pane), "alpha **bold** gamma\n")
	// A click too late for the run starts over.
	mouse_click(&f.state, w, {x, y, 3_000_000_000, .Left, {}})
	testing.expect_value(t, selected(pane), "")

	// Shift+click extends from the anchor instead of counting.
	edit_press(&f.state, w, .Home)
	anchor := b.anchor
	lx, ly, _ := char_point(t, &f.state, w, pane, strings.index(source, "last") + 2)
	mouse_click(&f.state, w, {lx, ly, 4_000_000_000, .Left, {.Shift}})
	testing.expect_value(t, b.anchor, anchor)
	testing.expect_value(t, b.caret, strings.index(source, "last") + 2)
}

// A right-click on the editor's text opens the edit menu: the caret goes under the pointer unless it is
// inside the selection, and rows that would do nothing are disabled.
@(test)
a_right_click_opens_the_edit_menu_with_what_it_can_do :: proc(t: ^testing.T) {
	f: Edit_Fixture
	defer edit_fixture_destroy(t, &f)
	source := "alpha beta\n\ngamma\n"
	w, pane := edit_fixture_start(t, &f, "Menu", source)
	if pane == nil {return}
	app.run_action(&f.state, w, .Edit_Markdown)
	if !testing.expect(t, app.markdown_editing(pane)) {return}
	b := &pane.editor.buffer
	testing.expect(t, platform.clipboard_set_text(&f.state.platform, "pasted"))
	beta := strings.index(source, "beta")

	x, y, found := char_point(t, &f.state, w, pane, beta + 1)
	if !found {return}
	mouse_click(&f.state, w, {x, y, 1_000_000, .Right, {}})
	_, shown := w.overlay.(app.Overlay_Edit_Menu)
	if !testing.expect(t, shown, "the edit menu should be open") {return}
	testing.expect_value(t, b.caret, beta + 1)
	rows := map[string]bool{}
	defer delete(rows)
	for item in w.edit_menu.items {if !item.separator {rows[item.label] = item.enabled}}
	testing.expect_value(t, len(rows), 6)
	testing.expect(t, !rows["Undo"] && !rows["Redo"] && !rows["Cut"] && !rows["Copy"], "nothing to do yet")
	testing.expect(t, rows["Paste"] && rows["Select all"])
	app.overlay_close(&f.state, w)

	// Inside a selection the right-click keeps it, and Cut and Copy are on.
	edit_press(&f.state, w, .Home, {.Control})
	edit_press(&f.state, w, .Arrow_Right, {.Control})
	edit_press(&f.state, w, .Arrow_Right, {.Control, .Shift})
	x, y, _ = char_point(t, &f.state, w, pane, beta + 2)
	mouse_click(&f.state, w, {x, y, 2_000_000, .Right, {}})
	testing.expect_value(t, selected(pane), "beta")
	for item in w.edit_menu.items {
		if item.label == "Cut" || item.label == "Copy" {testing.expect(t, item.enabled, item.label)}
	}
	for item, index in w.edit_menu.items {
		if item.label != "Copy" {continue}
		ui.menu_select(&w.edit_menu, index)
		app.edit_menu_choose(&f.state, w)
	}
	copied, ok := platform.clipboard_get_text(&f.state.platform, context.temp_allocator)
	testing.expect(t, ok && copied == "beta", copied)
	_, still := w.overlay.(app.Overlay_Edit_Menu)
	testing.expect(t, !still, "choosing a row closes the menu")

	// Outside it the caret moves first, and Paste then goes in there.
	gamma := strings.index(source, "gamma")
	x, y, _ = char_point(t, &f.state, w, pane, gamma + 1)
	mouse_click(&f.state, w, {x, y, 3_000_000, .Right, {}})
	testing.expect_value(t, b.caret, gamma + 1)
	testing.expect_value(t, selected(pane), "")
	for item, index in w.edit_menu.items {
		if item.label != "Paste" {continue}
		ui.menu_select(&w.edit_menu, index)
		app.edit_menu_choose(&f.state, w)
	}
	testing.expect_value(t, string(b.text[:]), "alpha beta\n\ngbetaamma\n")
}
