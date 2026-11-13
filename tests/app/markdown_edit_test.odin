package app_test

import "aio:input"
import "aio:markdown"
import "aio:platform"
import "aio:ui"
import "core:fmt"
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
		r := shown.rect
		g = ui.markdown_geometry({r.x, r.y + w.header_height, r.width, r.height - w.header_height}, w.scale)
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
