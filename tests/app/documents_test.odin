package app_test

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import app "../../src"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:ui"

@(private = "file")
Lists :: struct {
	pane, tab, workspace: app.Document_List,
}

@(private = "file")
lists_scopes :: proc(l: ^Lists) -> app.Document_Scopes {return {&l.pane, &l.tab, &l.workspace}}

@(private = "file")
lists_destroy :: proc(l: ^Lists) {
	app.documents_destroy(&l.pane)
	app.documents_destroy(&l.tab)
	app.documents_destroy(&l.workspace)
}

@(test)
document_labels_name_the_file_or_host_and_keep_what_tells_them_apart :: proc(t: ^testing.T) {
	cases := [?]struct {
		document:     app.Document,
		name, detail: string,
	} {
		{{target = "https://www.example.com/docs/a?b=1"}, "example.com", "/docs/a?b=1"},
		{{target = "https://example.com/"}, "example.com", ""},
		{{target = "http://localhost:8080"}, "localhost:8080", ""},
	}
	for c in cases {
		name, detail := app.document_label(c.document, context.temp_allocator)
		testing.expect_value(t, name, c.name)
		testing.expect_value(t, detail, c.detail)
	}
	name, detail := app.document_label({target = `C:\Projects\site\README.md`}, context.temp_allocator)
	testing.expect_value(t, name, "README.md")
	testing.expect_value(t, detail, `Projects\site`)
	name, detail = app.document_label({target = `C:\deep\er\still\page.md`}, context.temp_allocator)
	testing.expect_value(t, detail, `er\still`)
	name, _ = app.document_label({target = `C:\Projects\site\`, folder = true}, context.temp_allocator)
	testing.expect_value(t, name, "site")
}

@(test)
document_icons_follow_the_kind_of_target :: proc(t: ^testing.T) {
	testing.expect_value(t, app.document_icon({target = "https://example.com"}), ui.Icon.Globe)
	testing.expect_value(t, app.document_icon({target = `C:\a`, folder = true}), ui.Icon.Folder)
	testing.expect_value(t, app.document_icon({target = `C:\a.md`}), ui.Icon.Markdown)
	testing.expect_value(t, app.document_icon({target = `C:\a.html`}), ui.Icon.Document)
}

@(test)
documents_sort_by_level_then_name_and_show_once_at_the_narrowest :: proc(t: ^testing.T) {
	l: Lists
	defer lists_destroy(&l)
	scopes := lists_scopes(&l)
	pins := [?]struct {
		level:  app.Document_Level,
		target: string,
	} {
		{.Workspace, `C:\w\Beta.md`},
		{.Workspace, `C:\w\alpha.md`},
		{.Pane, `C:\p\zeta.md`},
		{.Tab, `C:\t\middle.md`},
		{.Pane, `C:\p\Apple.md`},
	}
	for pin in pins {
		testing.expect_value(t, app.document_pin(scopes, pin.level, {target = pin.target}), app.Document_Pin_Result.Pinned)
	}
	// Another pane may have pinned this at the tab; this pane's own copy is the one it shows.
	app.documents_copy(&l.tab, {{target = `c:\P\ZETA.md`}})
	rows := app.documents_visible(scopes)
	expected := [?]string{`C:\p\Apple.md`, `C:\p\zeta.md`, `C:\t\middle.md`, `C:\w\alpha.md`, `C:\w\Beta.md`}
	levels := [?]app.Document_Level{.Pane, .Pane, .Tab, .Workspace, .Workspace}
	if !testing.expect_value(t, len(rows), len(expected)) {return}
	for row, i in rows {
		testing.expect_value(t, row.document.target, expected[i])
		testing.expect_value(t, row.level, levels[i])
	}
}

@(test)
pinning_again_moves_a_document_and_a_full_level_changes_nothing :: proc(t: ^testing.T) {
	l: Lists
	defer lists_destroy(&l)
	scopes := lists_scopes(&l)
	_ = app.document_pin(scopes, .Pane, {target = `C:\a.md`})
	testing.expect_value(t, app.document_pin(scopes, .Workspace, {target = `c:\A.MD`}), app.Document_Pin_Result.Pinned)
	testing.expect_value(t, len(l.pane), 0)
	testing.expect_value(t, len(l.workspace), 1)
	// Moving a borrowed row, which the move itself frees.
	testing.expect_value(t, app.document_pin(scopes, .Tab, l.workspace[0]), app.Document_Pin_Result.Pinned)
	testing.expect_value(t, l.tab[0].target, `c:\A.MD`)
	// Web addresses differ by case past the host.
	_ = app.document_pin(scopes, .Pane, {target = "https://example.com/A"})
	_ = app.document_pin(scopes, .Pane, {target = "https://example.com/a"})
	testing.expect_value(t, len(l.pane), 2)
	for i in 0 ..< app.DOCUMENT_LEVEL_LIMIT {
		_ = app.document_pin(scopes, .Workspace, {target = fmt.tprintf(`C:\full\%d.md`, i)})
	}
	testing.expect_value(t, app.document_pin(scopes, .Workspace, {target = `C:\tab-copy.md`}), app.Document_Pin_Result.Level_Full)
	testing.expect_value(t, app.document_pin(scopes, .Workspace, l.pane[0]), app.Document_Pin_Result.Level_Full)
	testing.expect_value(t, len(l.pane), 2)
	testing.expect_value(t, len(l.workspace), app.DOCUMENT_LEVEL_LIMIT)
	// One already at the full level stays pinned.
	testing.expect_value(t, app.document_pin(scopes, .Workspace, {target = `C:\full\3.md`}), app.Document_Pin_Result.Pinned)
	testing.expect_value(t, len(l.workspace), app.DOCUMENT_LEVEL_LIMIT)
	testing.expect(t, app.document_remove(scopes, .Pane, "https://example.com/A"))
	testing.expect(t, !app.document_remove(scopes, .Pane, "https://example.com/A"))
	empty := app.Document_Scopes{tab = &l.tab, workspace = &l.workspace}
	testing.expect_value(t, app.document_pin(empty, .Pane, {target = `C:\b.md`}), app.Document_Pin_Result.Failed)
}

@(test)
restoring_documents_keeps_only_targets_a_link_could_open :: proc(t: ^testing.T) {
	list: app.Document_List
	defer app.documents_destroy(&list)
	saved := []app.Document {
		{target = `C:\ok.md`},
		{target = "https://example.com"},
		{target = `C:\OK.MD`},
		{target = `\\server\share\remote.md`},
		{target = "file:///C:/a.md"},
		{target = "javascript:alert(1)"},
		{target = `relative\a.md`},
		{target = ""},
		{target = `C:\folder`, folder = true},
	}
	app.documents_restore(&list, saved)
	if !testing.expect_value(t, len(list), 3) {return}
	testing.expect_value(t, list[0].target, `C:\ok.md`)
	testing.expect_value(t, list[1].target, "https://example.com")
	testing.expect(t, list[2].folder)
}

@(test)
document_state_round_trips_through_the_saved_layout :: proc(t: ^testing.T) {
	state: app.App
	defer {
		for workspace in state.workspaces {app.workspace_destroy(workspace)}
		delete(state.workspaces)
	}
	workspace := app.workspace_create_empty(&state)
	if !testing.expect(t, workspace != nil) {return}
	tab := new(app.Tab)
	if !testing.expect_value(t, layout.init(&tab.tree, {.Settings, 0}), nil) {free(tab); return}
	append(&workspace.tabs, tab)
	app.documents_copy(&workspace.documents, {{target = "https://example.com/w"}})
	app.documents_copy(&tab.documents, {{target = `C:\t`, folder = true}})
	text, ok := app.layout_state_encode(&state, context.temp_allocator)
	if !testing.expect(t, ok) {return}
	decoded: app.Layout_State
	if !testing.expect_value(t, json.unmarshal(transmute([]u8)text, &decoded, allocator = context.temp_allocator), nil) {
		return
	}
	saved := decoded.workspaces[0]
	if !testing.expect_value(t, len(saved.documents), 1) {return}
	testing.expect_value(t, saved.documents[0].target, "https://example.com/w")
	testing.expect_value(t, saved.documents[0].folder, false)
	if !testing.expect_value(t, len(saved.tabs[0].documents), 1) {return}
	testing.expect(t, saved.tabs[0].documents[0].folder)
	testing.expect(t, strings.contains(text, `"documents"`))
	// A layout with nothing pinned stays free of the new keys.
	app.documents_destroy(&workspace.documents)
	app.documents_destroy(&tab.documents)
	plain, plain_ok := app.layout_state_encode(&state, context.temp_allocator)
	testing.expect(t, plain_ok)
	testing.expect(t, !strings.contains(plain, `"documents"`))
}

@(private = "file")
press :: proc(s: ^app.App, w: ^app.Window, x, y: f32, button: input.Mouse_Button = .Left, modifiers: input.Modifiers = {}) {
	for pressed in ([?]bool{true, false}) {
		app.handle_event(
			s,
			platform.Mouse_Button_Event {
				window = w.id,
				button = button,
				pressed = pressed,
				x = i32(x),
				y = i32(y),
				modifiers = modifiers,
				time_ns = 1_000_000_000,
			},
		)
	}
}

@(private = "file")
key :: proc(s: ^app.App, w: ^app.Window, which: input.Key) {
	app.handle_event(s, platform.Key_Event{window = w.id, key = which, pressed = true})
	app.handle_event(s, platform.Key_Event{window = w.id, key = which, pressed = false})
}

@(private = "file")
center :: proc(r: [4]f32) -> (f32, f32) {return r[0] + r[2] / 2, r[1] + r[3] / 2}

@(private = "file")
open_button :: proc(s: ^app.App, w: ^app.Window) {
	r := w.panes[0].rect
	l := ui.header_layout({r.x, r.y, r.width, r.height}, w.scale)
	x, y := center(transmute([4]f32)l.buttons[int(ui.Header_Action.Documents) - 1])
	press(s, w, x, y)
}

// The row whose action is `action`, and whose target or level match when given.
@(private = "file")
row_of :: proc(w: ^app.Window, action: app.Document_Menu_Action, target := "", level := app.Document_Level.Pane) -> int {
	menu := &w.document_menu
	for i in 0 ..< menu.count {
		entry := menu.entries[i]
		if entry.action != action {continue}
		if target != "" && entry.target != target {continue}
		if action == .Pin && entry.level != level {continue}
		return i
	}
	return -1
}

@(private = "file")
click_row :: proc(s: ^app.App, w: ^app.Window, row: int) {
	r := ui.menu_row_rect(&w.document_menu.menu, row, f32(w.width), f32(w.height), w.scale)
	press(s, w, r.x + 40 * w.scale, r.y + r.height / 2)
}

@(private = "file")
click_part :: proc(s: ^app.App, w: ^app.Window, row: int, part: ui.Menu_Row_Part) {
	r := ui.menu_action_rect(&w.document_menu.menu, row, part, f32(w.width), f32(w.height), w.scale)
	x, y := center(transmute([4]f32)r)
	press(s, w, x, y)
}

@(test)
document_menu_lists_opens_moves_and_removes_from_the_pane_header :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "documents-menu", false) {return}
	s, w := &f.state, f.state.windows[0]
	Open_Stub_State = {}
	s.open_url = link_open_stub
	defer s.open_url = nil
	menu := &w.document_menu
	testing.expect(t, !app.documents_any(s, w, w.panes[0].content))

	// With nothing pinned the menu offers the ways to add, and what opened it keeps its place.
	open_button(s, w)
	if !testing.expect(t, menu.menu.open) {return}
	testing.expect_value(t, menu.mode, app.Document_Menu_Mode.List)
	testing.expect(t, row_of(w, .Add_File) >= 0 && row_of(w, .Add_Folder) >= 0 && row_of(w, .Add_Url) >= 0)
	testing.expect(t, row_of(w, .Open) < 0)

	// Add URL: a bad address stays in the field, a good one moves on to choosing its level.
	click_row(s, w, row_of(w, .Add_Url))
	testing.expect(t, menu.url_open)
	testing.expect(t, row_of(w, .Add_Url) < 0 && row_of(w, .Url_Field) >= 0)
	app.handle_event(s, platform.Text_Event{window = w.id, text = "not a url"})
	testing.expect_value(t, ui.field_string(&menu.url), "not a url")
	key(s, w, .Enter)
	testing.expect(t, menu.url_invalid && menu.url_open)
	ui.field_set(&menu.url, "")
	app.handle_event(s, platform.Text_Event{window = w.id, text = "https://example.com/a"})
	testing.expect(t, !menu.url_invalid)
	key(s, w, .Enter)
	testing.expect_value(t, menu.mode, app.Document_Menu_Mode.Pin)
	testing.expect(t, !menu.url_open)
	testing.expect_value(t, menu.pending.target, "https://example.com/a")
	// Escape returns to the list without pinning.
	key(s, w, .Escape)
	testing.expect_value(t, menu.mode, app.Document_Menu_Mode.List)
	testing.expect(t, menu.menu.open)
	testing.expect(t, !app.documents_any(s, w, w.panes[0].content))

	scopes, found := app.document_scopes(s, w.panes[0].content)
	if !testing.expect(t, found) {return}
	_ = app.document_pin(scopes, .Tab, {target = "https://example.com/a"})
	_ = app.document_pin(scopes, .Pane, {target = "https://example.com/b"})
	app.document_menu_close(w)
	testing.expect(t, !menu.menu.open)
	open_button(s, w)
	testing.expect(t, app.documents_any(s, w, w.panes[0].content))

	// Levels are divided, and pane comes first.
	first, second := row_of(w, .Open, "https://example.com/b"), row_of(w, .Open, "https://example.com/a")
	if !testing.expect(t, first >= 0 && second > first) {return}
	testing.expect(t, menu.menu.items[first + 1].separator)

	// The level button opens the popout on the current level; choosing it only closes the popout.
	click_part(s, w, first, .Action)
	if !testing.expect(t, menu.popout) {return}
	testing.expect_value(t, menu.popout_pick, app.Document_Level.Pane)
	r := app.document_popout_button(w, .Pane)
	x, y := center(transmute([4]f32)r)
	press(s, w, x, y)
	testing.expect(t, !menu.popout)
	testing.expect_value(t, len(scopes.pane), 1)

	// Choosing another level moves the document there and keeps the menu open.
	click_part(s, w, row_of(w, .Open, "https://example.com/b"), .Action)
	r = app.document_popout_button(w, .Workspace)
	x, y = center(transmute([4]f32)r)
	testing.expect(t, r.y + r.height <= ui.menu_action_rect(&menu.menu, row_of(w, .Open, "https://example.com/b"), .Action, f32(w.width), f32(w.height), w.scale).y)
	press(s, w, x, y)
	testing.expect(t, menu.menu.open && !menu.popout)
	testing.expect_value(t, len(scopes.pane), 0)
	testing.expect_value(t, len(scopes.workspace), 1)
	testing.expect_value(t, menu.entries[row_of(w, .Open, "https://example.com/b")].level, app.Document_Level.Workspace)

	// A press outside the popout closes only the popout.
	click_part(s, w, row_of(w, .Open, "https://example.com/a"), .Action)
	testing.expect(t, menu.popout)
	press(s, w, 2, f32(w.height) - 2)
	testing.expect(t, menu.menu.open && !menu.popout)

	// Keyboard: Right opens the popout, arrows choose, Enter applies.
	menu.menu.selected = row_of(w, .Open, "https://example.com/a")
	key(s, w, .Arrow_Right)
	testing.expect(t, menu.popout)
	key(s, w, .Arrow_Left)
	key(s, w, .Enter)
	testing.expect_value(t, len(scopes.pane), 1)
	testing.expect_value(t, len(scopes.tab), 0)

	// Remove with the row's button, shown once selected, and with Delete. The menu stays.
	row := row_of(w, .Open, "https://example.com/a")
	r = ui.menu_row_rect(&menu.menu, row, f32(w.width), f32(w.height), w.scale)
	app.handle_event(s, platform.Mouse_Move_Event{window = w.id, x = i32(r.x + 40), y = i32(r.y + r.height / 2)})
	testing.expect_value(t, menu.menu.selected, row)
	click_part(s, w, row, .Selected_Action)
	testing.expect_value(t, len(scopes.pane), 0)
	testing.expect(t, menu.menu.open)
	menu.menu.selected = row_of(w, .Open, "https://example.com/b")
	key(s, w, .Delete)
	testing.expect_value(t, len(scopes.workspace), 0)
	testing.expect(t, menu.menu.open && row_of(w, .Open) < 0)

	// Clicking a row opens it and closes the menu.
	_ = app.document_pin(scopes, .Tab, {target = "https://example.com/c"})
	app.document_menu_close(w)
	open_button(s, w)
	click_row(s, w, row_of(w, .Open, "https://example.com/c"))
	testing.expect(t, !menu.menu.open)
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect_value(t, Open_Stub_State.uri, "https://example.com/c")

	// A press outside closes the menu, and losing focus would too.
	open_button(s, w)
	press(s, w, 2, f32(w.height) - 2)
	testing.expect(t, !menu.menu.open)
	open_button(s, w)
	app.window_overlays_cancel(s, w)
	testing.expect(t, !menu.menu.open)
}

@(test)
ctrl_right_click_on_a_terminal_link_offers_to_open_or_pin_it :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "documents-link", false) {return}
	s, w := &f.state, f.state.windows[0]
	Open_Stub_State = {}
	s.open_url = link_open_stub
	defer s.open_url = nil
	menu := &w.document_menu
	link_feed(t, &f, "\x1b[2J\x1b[3J\x1b[Hhttps://example.com/one")
	point, ok := link_point(t, &f, 4, 0)
	if !ok {return}
	x, y := f32(point.x), f32(point.y)

	// A plain right-click is the terminal's.
	press(s, w, x, y, .Right)
	testing.expect(t, !menu.menu.open)

	press(s, w, x, y, .Right, {.Control})
	if !testing.expect(t, menu.menu.open) {return}
	testing.expect_value(t, menu.mode, app.Document_Menu_Mode.Link)
	testing.expect_value(t, menu.pending.target, "https://example.com/one")
	click_row(s, w, row_of(w, .Pin, level = .Tab))
	testing.expect(t, !menu.menu.open)
	scopes, found := app.document_scopes(s, w.panes[0].content)
	if !testing.expect(t, found) {return}
	if !testing.expect_value(t, len(scopes.tab), 1) {return}
	testing.expect_value(t, scopes.tab[0].target, "https://example.com/one")
	testing.expect_value(t, Open_Stub_State.calls, 0)

	press(s, w, x, y, .Right, {.Control})
	click_row(s, w, row_of(w, .Open_Link))
	testing.expect(t, !menu.menu.open)
	testing.expect_value(t, Open_Stub_State.calls, 1)

	// Off any link it does nothing.
	far, far_ok := link_point(t, &f, 40, 5)
	if !far_ok {return}
	press(s, w, f32(far.x), f32(far.y), .Right, {.Control})
	testing.expect(t, !menu.menu.open)
}

@(test)
closed_and_duplicated_panes_keep_their_documents :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-documents-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	settings := idle_shell_settings(t, "cursor.blink = false\ntab.confirm_close = false\n")
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings), nil) {return}
	state: app.App
	state.options = {data_dir = directory, inactive = true}
	state.app_id = fmt.aprintf("AIODev.Test.Documents.%d", os.get_pid())
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		delete(state.app_id)
		return
	}
	state.platform_ready = true
	defer app.app_destroy(&state)
	if !testing.expect(t, app.app_init(&state)) {return}
	w := state.windows[0]
	workspace := w.workspace
	app.pane_split(&state, w, .Right, 0.5)
	tree := &workspace.tabs[0].tree
	node := layout.Node_Id(tree.focus)
	content := tree.nodes[node].(layout.Pane).content
	scopes, found := app.document_scopes(&state, content)
	if !testing.expect(t, found) {return}
	_ = app.document_pin(scopes, .Pane, {target = "https://example.com/pane"})
	_ = app.document_pin(scopes, .Tab, {target = "https://example.com/tab"})

	// A pane's list goes when it closes and comes back with Reopen.
	app.pane_close_at(&state, workspace, 0, node)
	app.closed_reopen(&state, w)
	tree = &workspace.tabs[0].tree
	content = tree.nodes[tree.focus].(layout.Pane).content
	scopes, found = app.document_scopes(&state, content)
	if !testing.expect(t, found) {return}
	if !testing.expect_value(t, len(scopes.pane), 1) {return}
	testing.expect_value(t, scopes.pane[0].target, "https://example.com/pane")

	// Duplicating a tab copies the tab's list and its focused pane's.
	app.tab_duplicate(&state, w, 0)
	if !testing.expect_value(t, len(workspace.tabs), 2) {return}
	last := workspace.tabs[1]
	testing.expect_value(t, len(last.documents), 1)
	copied := last.tree.nodes[last.tree.focus].(layout.Pane).content
	copied_scopes, copied_found := app.document_scopes(&state, copied)
	if !testing.expect(t, copied_found) {return}
	testing.expect_value(t, len(copied_scopes.pane), 1)
	// Each pane owns its copy.
	_ = app.document_remove(copied_scopes, .Pane, "https://example.com/pane")
	testing.expect_value(t, len(scopes.pane), 1)

	// A pane moved to a new tab keeps its own list; the tab's list stays behind.
	testing.expect_value(t, len(scopes.tab), 1)
	app.tab_select(&state, w, 0)
	app.pane_split(&state, w, .Right, 0.5)
	source := workspace.tabs[0]
	moved := source.tree.nodes[source.tree.focus].(layout.Pane).content
	moved_scopes, moved_found := app.document_scopes(&state, moved)
	if !testing.expect(t, moved_found) {return}
	_ = app.document_pin(moved_scopes, .Pane, {target = "https://example.com/moved"})
	if !testing.expect(t, app.pane_to_tab(&state, w, source, source.tree.focus)) {return}
	moved_scopes, moved_found = app.document_scopes(&state, moved)
	if !testing.expect(t, moved_found) {return}
	testing.expect_value(t, len(moved_scopes.pane), 1)
	testing.expect_value(t, len(moved_scopes.tab), 0)
}
