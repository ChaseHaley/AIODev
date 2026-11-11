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
			input.Mouse_Button_Event {
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
key :: proc(s: ^app.App, w: ^app.Window, which: input.Key, modifiers: input.Modifiers = {}) {
	app.handle_event(s, input.Key_Event{window = w.id, key = which, modifiers = modifiers, pressed = true})
	app.handle_event(s, input.Key_Event{window = w.id, key = which, modifiers = modifiers, pressed = false})
}

@(private = "file")
actions_shown :: proc(w: ^app.Window) -> bool {
	_, shown := app.document_menu_actions(w)
	return shown
}

// The right-click menu's row running `action`, or -1.
@(private = "file")
action_row :: proc(w: ^app.Window, action: app.Link_Action) -> int {
	actions := &w.document_menu.actions
	for item, i in actions.items {
		if !item.separator && (transmute(app.Link_Choice)item.payload).action == action {return i}
	}
	return -1
}

// Chooses `action` in the open right-click menu: Down to it and Enter, or a click on its row.
@(private = "file")
choose_action :: proc(s: ^app.App, w: ^app.Window, action: app.Link_Action, keyboard := false) {
	actions := &w.document_menu.actions
	row := action_row(w, action)
	if row < 0 {return}
	if keyboard {
		for _ in 0 ..< len(actions.items) {
			if ui.menu_selected(actions) == row {break}
			key(s, w, .Arrow_Down)
		}
		key(s, w, .Enter)
		return
	}
	r := ui.menu_row_rect(actions, row, f32(w.width), f32(w.height), w.scale)
	press(s, w, r.x + 40 * w.scale, r.y + r.height / 2)
}

// The open submenu's row for `placement`, or -1.
@(private = "file")
placement_row :: proc(w: ^app.Window, placement: app.Link_Placement) -> int {
	if !app.document_submenu_shown(w) {return -1}
	for item, i in w.document_menu.submenu.items {
		if (transmute(app.Link_Choice)item.payload).placement == placement {return i}
	}
	return -1
}

// Chooses `placement` from the submenu of row `row` of `parent`, the link menu or the right-click menu: the
// pointer rests on the row and clicks the placement, or the keyboard goes Down to the row, Right into its
// submenu, Down to the placement and Enter.
@(private = "file")
choose_placement :: proc(
	s: ^app.App,
	w: ^app.Window,
	parent: ^ui.Menu,
	row: int,
	placement: app.Link_Placement,
	keyboard := false,
) {
	if row < 0 {return}
	if keyboard {
		for _ in 0 ..< len(parent.items) {
			if ui.menu_selected(parent) == row {break}
			key(s, w, .Arrow_Down)
		}
		key(s, w, .Arrow_Right)
		submenu := &w.document_menu.submenu
		target := placement_row(w, placement)
		for _ in 0 ..< len(submenu.items) {
			if ui.menu_selected(submenu) == target {break}
			key(s, w, .Arrow_Down)
		}
		key(s, w, .Enter)
		return
	}
	point_at(s, w, parent, row)
	target := placement_row(w, placement)
	if target < 0 {return}
	p := ui.menu_row_rect(&w.document_menu.submenu, target, f32(w.width), f32(w.height), w.scale)
	press(s, w, p.x + 40 * w.scale, p.y + p.height / 2)
}

// Rests the pointer on row `row` of `parent`, which shows its placements.
@(private = "file")
point_at :: proc(s: ^app.App, w: ^app.Window, parent: ^ui.Menu, row: int) {
	r := ui.menu_row_rect(parent, row, f32(w.width), f32(w.height), w.scale)
	app.handle_event(s, input.Mouse_Move_Event{window = w.id, x = i32(r.x + 40 * w.scale), y = i32(r.y + r.height / 2)})
}

@(private = "file")
center :: proc(r: [4]f32) -> (f32, f32) {return r[0] + r[2] / 2, r[1] + r[3] / 2}

@(private = "file")
open_button :: proc(s: ^app.App, w: ^app.Window) {
	l := app.pane_header_layout(w, w.panes[0])
	x, y := center(transmute([4]f32)l.buttons[.Links])
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

@(private = "file")
shown_in :: proc(w: ^app.Window, $T: typeid) -> bool {
	state, shown := w.overlay.(app.Overlay_Document_Menu)
	if !shown {return false}
	_, in_mode := state.mode.(T)
	return in_mode
}

// The document a Pin or Link menu holds.
@(private = "file")
held_target :: proc(w: ^app.Window) -> string {
	state, _ := w.overlay.(app.Overlay_Document_Menu)
	#partial switch mode in state.mode {
	case app.Document_Menu_Pin: return mode.document.target
	case app.Document_Menu_Link: return mode.document.target
	}
	return ""
}

@(private = "file")
url_entry :: proc(w: ^app.Window) -> (entering, invalid: bool) {
	url, shown := app.document_menu_url_entry(w)
	return shown, url.invalid
}

@(private = "file")
popout_shown :: proc(w: ^app.Window) -> bool {
	_, shown := app.document_menu_popout(w)
	return shown
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
	s.opener.url = link_open_stub
	defer s.opener.url = nil
	menu := &w.document_menu

	// With nothing pinned the menu offers the ways to add, and what opened it keeps its place.
	open_button(s, w)
	if !testing.expect(t, app.document_menu_shown(w)) {return}
	testing.expect(t, shown_in(w, app.Document_Menu_List))
	testing.expect(t, row_of(w, .Add_File) >= 0 && row_of(w, .Add_Folder) >= 0 && row_of(w, .Add_Url) >= 0)
	testing.expect(t, row_of(w, .Open) < 0)

	// Add URL: a bad address stays in the field, a good one moves on to choosing its level.
	click_row(s, w, row_of(w, .Add_Url))
	entering, invalid := url_entry(w)
	testing.expect(t, entering)
	testing.expect(t, row_of(w, .Add_Url) < 0 && row_of(w, .Url_Field) >= 0)
	app.handle_event(s, input.Text_Event{window = w.id, text = "not a url"})
	testing.expect_value(t, ui.field_string(&menu.url), "not a url")
	key(s, w, .Enter)
	entering, invalid = url_entry(w)
	testing.expect(t, invalid && entering)
	ui.field_set(&menu.url, "")
	app.handle_event(s, input.Text_Event{window = w.id, text = "https://example.com/a"})
	entering, invalid = url_entry(w)
	testing.expect(t, entering && !invalid)
	key(s, w, .Enter)
	testing.expect(t, shown_in(w, app.Document_Menu_Pin))
	entering, _ = url_entry(w)
	testing.expect(t, !entering)
	testing.expect_value(t, held_target(w), "https://example.com/a")
	// Escape returns to the list without pinning.
	key(s, w, .Escape)
	testing.expect(t, shown_in(w, app.Document_Menu_List))

	scopes, found := app.document_scopes(s, w.panes[0].content)
	if !testing.expect(t, found) {return}
	testing.expect_value(t, len(scopes.pane) + len(scopes.tab) + len(scopes.workspace), 0)
	_ = app.document_pin(scopes, .Tab, {target = "https://example.com/a"})
	_ = app.document_pin(scopes, .Pane, {target = "https://example.com/b"})
	app.overlay_close(s, w)
	testing.expect(t, !app.document_menu_shown(w))
	open_button(s, w)

	// Levels are divided, and pane comes first.
	first, second := row_of(w, .Open, "https://example.com/b"), row_of(w, .Open, "https://example.com/a")
	if !testing.expect(t, first >= 0 && second > first) {return}
	testing.expect(t, menu.menu.items[first + 1].separator)

	// The level button opens the popout on the current level; choosing it only closes the popout.
	click_part(s, w, first, .Action)
	popout, popout_open := app.document_menu_popout(w)
	if !testing.expect(t, popout_open) {return}
	testing.expect_value(t, popout.pick, app.Document_Level.Pane)
	r := app.document_popout_button(w, .Pane)
	x, y := center(transmute([4]f32)r)
	press(s, w, x, y)
	testing.expect(t, !popout_shown(w))
	testing.expect_value(t, len(scopes.pane), 1)

	// Choosing another level moves the document there and keeps the menu open.
	click_part(s, w, row_of(w, .Open, "https://example.com/b"), .Action)
	r = app.document_popout_button(w, .Workspace)
	x, y = center(transmute([4]f32)r)
	testing.expect(t, r.y + r.height <= ui.menu_action_rect(&menu.menu, row_of(w, .Open, "https://example.com/b"), .Action, f32(w.width), f32(w.height), w.scale).y)
	press(s, w, x, y)
	testing.expect(t, app.document_menu_shown(w) && !popout_shown(w))
	testing.expect_value(t, len(scopes.pane), 0)
	testing.expect_value(t, len(scopes.workspace), 1)
	testing.expect_value(t, menu.entries[row_of(w, .Open, "https://example.com/b")].level, app.Document_Level.Workspace)

	// A press outside the popout closes only the popout.
	click_part(s, w, row_of(w, .Open, "https://example.com/a"), .Action)
	testing.expect(t, popout_shown(w))
	press(s, w, 2, f32(w.height) - 2)
	testing.expect(t, app.document_menu_shown(w) && !popout_shown(w))

	// Keyboard: Ctrl+Enter opens the selected row's right-click menu, arrows move, Enter chooses.
	ui.menu_select(&menu.menu, row_of(w, .Open, "https://example.com/a"))
	key(s, w, .Enter, {.Control})
	testing.expect(t, actions_shown(w))
	choose_action(s, w, .Move_Pane, keyboard = true)
	testing.expect(t, app.document_menu_shown(w) && !actions_shown(w))
	testing.expect_value(t, len(scopes.pane), 1)
	testing.expect_value(t, len(scopes.tab), 0)

	// Remove with the row's button, shown once selected, and from a right-click. The menu stays.
	row := row_of(w, .Open, "https://example.com/a")
	r = ui.menu_row_rect(&menu.menu, row, f32(w.width), f32(w.height), w.scale)
	app.handle_event(s, input.Mouse_Move_Event{window = w.id, x = i32(r.x + 40), y = i32(r.y + r.height / 2)})
	testing.expect_value(t, ui.menu_selected(&menu.menu), row)
	click_part(s, w, row, .Selected_Action)
	testing.expect_value(t, len(scopes.pane), 0)
	testing.expect(t, app.document_menu_shown(w))
	r = ui.menu_row_rect(&menu.menu, row_of(w, .Open, "https://example.com/b"), f32(w.width), f32(w.height), w.scale)
	press(s, w, r.x + 40 * w.scale, r.y + r.height / 2, .Right)
	testing.expect(t, actions_shown(w))
	choose_action(s, w, .Remove)
	testing.expect_value(t, len(scopes.workspace), 0)
	testing.expect(t, app.document_menu_shown(w) && row_of(w, .Open) < 0)

	// Typing searches: the field has the keyboard as the menu opens, Enter opens the one match, and Escape
	// clears a search before it closes the menu.
	_ = app.document_pin(scopes, .Tab, {target = "https://example.com/c"})
	_ = app.document_pin(scopes, .Tab, {target = "https://example.org/d"})
	app.overlay_close(s, w)
	open_button(s, w)
	app.handle_event(s, input.Text_Event{window = w.id, text = "org"})
	testing.expect_value(t, ui.field_string(&menu.search), "org")
	testing.expect(t, row_of(w, .Open, "https://example.org/d") >= 0 && row_of(w, .Open, "https://example.com/c") < 0)
	key(s, w, .Escape)
	testing.expect(t, app.document_menu_shown(w) && row_of(w, .Open, "https://example.com/c") >= 0)
	app.handle_event(s, input.Text_Event{window = w.id, text = "example"})
	key(s, w, ui.LIST_NEXT_KEY, {.Control})
	testing.expect_value(t, menu.entries[ui.menu_selected(&menu.menu)].target, "https://example.org/d")
	key(s, w, ui.LIST_PREVIOUS_KEY, {.Control})
	testing.expect_value(t, menu.entries[ui.menu_selected(&menu.menu)].target, "https://example.com/c")
	key(s, w, .Enter)
	testing.expect(t, !app.document_menu_shown(w))
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect_value(t, Open_Stub_State.uri, "https://example.com/c")

	// Clicking a row opens it and closes the menu.
	open_button(s, w)
	testing.expect_value(t, ui.field_string(&menu.search), "")
	click_row(s, w, row_of(w, .Open, "https://example.org/d"))
	testing.expect(t, !app.document_menu_shown(w))
	testing.expect_value(t, Open_Stub_State.calls, 2)
	testing.expect_value(t, Open_Stub_State.uri, "https://example.org/d")

	// A press outside closes the menu, and losing focus would too.
	open_button(s, w)
	press(s, w, 2, f32(w.height) - 2)
	testing.expect(t, !app.document_menu_shown(w))
	open_button(s, w)
	app.window_overlays_cancel(s, w)
	testing.expect(t, !app.document_menu_shown(w))
}

// Regression: the level popout could open over the address field, which then kept the keyboard while the
// popout showed. The popout now takes the list's one step and ends the address entry.
@(test)
document_menu_popout_takes_the_keyboard_from_the_address_field :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "documents-popout-url", false) {return}
	s, w := &f.state, f.state.windows[0]
	scopes, found := app.document_scopes(s, w.panes[0].content)
	if !testing.expect(t, found) {return}
	_ = app.document_pin(scopes, .Pane, {target = "https://example.com/a"})
	open_button(s, w)
	click_row(s, w, row_of(w, .Add_Url))
	entering, _ := url_entry(w)
	if !testing.expect(t, entering) {return}
	click_part(s, w, row_of(w, .Open, "https://example.com/a"), .Action)
	popout, shown := app.document_menu_popout(w)
	entering, _ = url_entry(w)
	if !testing.expect(t, shown && !entering) {return}
	testing.expect(t, row_of(w, .Url_Field) < 0 && row_of(w, .Add_Url) >= 0)
	testing.expect_value(t, popout.pick, app.Document_Level.Pane)
	key(s, w, .Arrow_Right)
	popout, shown = app.document_menu_popout(w)
	testing.expect(t, shown)
	testing.expect_value(t, popout.pick, app.Document_Level.Tab)
	testing.expect_value(t, ui.field_string(&w.document_menu.url), "")
	key(s, w, .Enter)
	testing.expect_value(t, len(scopes.pane), 0)
	testing.expect_value(t, len(scopes.tab), 1)
}

// Only a Markdown file or a folder opens inside AIODev, so a web address's right-click menu offers no place;
// each place opens the file beside the pane the menu belongs to.
@(test)
right_click_menu_opens_a_markdown_link_beside_the_pane :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	directory, directory_error := os.make_directory_temp("", "aio-links-actions-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	// The app frees the temporary allocator each tick, so the path outlives it.
	file := strings.concatenate({directory, "\\Plan.md"})
	defer delete(file)
	if !testing.expect_value(t, os.write_entire_file(file, "# Plan\n"), nil) {return}
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "documents-actions", false) {return}
	s, w := &f.state, f.state.windows[0]
	scopes, found := app.document_scopes(s, w.panes[0].content)
	if !testing.expect(t, found) {return}
	_ = app.document_pin(scopes, .Pane, {target = file})
	_ = app.document_pin(scopes, .Pane, {target = "https://example.com/a"})
	right_click :: proc(s: ^app.App, w: ^app.Window, row: int) {
		r := ui.menu_row_rect(&w.document_menu.menu, row, f32(w.width), f32(w.height), w.scale)
		press(s, w, r.x + 40 * w.scale, r.y + r.height / 2, .Right)
	}
	open_button(s, w)
	right_click(s, w, row_of(w, .Open, "https://example.com/a"))
	testing.expect(t, actions_shown(w))
	open := action_row(w, .Open)
	testing.expect(t, open >= 0 && !w.document_menu.actions.items[open].submenu)
	// A press outside the right-click menu closes only it.
	press(s, w, 2, f32(w.height) - 2)
	testing.expect(t, app.document_menu_shown(w) && !actions_shown(w))

	right_click(s, w, row_of(w, .Open, file))
	open = action_row(w, .Open)
	testing.expect(t, open >= 0 && w.document_menu.actions.items[open].submenu, "a Markdown file opens in a pane")
	app.overlay_close(s, w)

	// From the keyboard, Open in Down Split puts the file under the pane.
	open_button(s, w)
	ui.menu_select(&w.document_menu.menu, row_of(w, .Open, file))
	key(s, w, .Enter, {.Control})
	choose_placement(s, w, &w.document_menu.actions, action_row(w, .Open), .Split_Down, keyboard = true)
	testing.expect(t, !app.document_menu_shown(w))
	if !testing.expect_value(t, len(w.panes), 2) {return}
	above, below := w.panes[0], w.panes[1]
	if above.content.kind == .Markdown {above, below = below, above}
	testing.expect_value(t, below.content.kind, layout.Content_Kind.Markdown)
	testing.expect(t, below.rect.y > above.rect.y)

	// Open in Float from the pointer adds a floating pane.
	open_button(s, w)
	right_click(s, w, row_of(w, .Open, file))
	choose_placement(s, w, &w.document_menu.actions, action_row(w, .Open), .Float)
	testing.expect(t, !app.document_menu_shown(w))
	tree := &app.selected_tab(w.workspace).tree
	floats := 0
	for _, id in tree.nodes {
		content, is_pane := layout.pane_content(tree, layout.Node_Id(id))
		if is_pane && content.kind == .Markdown && layout.is_floating(tree, layout.Node_Id(id)) {floats += 1}
	}
	testing.expect_value(t, floats, 1)
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
	s.opener.url = link_open_stub
	defer s.opener.url = nil
	link_feed(t, &f, "\x1b[2J\x1b[3J\x1b[Hhttps://example.com/one")
	point, ok := link_point(t, &f, 4, 0)
	if !ok {return}
	x, y := f32(point.x), f32(point.y)

	// A plain right-click is the terminal's.
	press(s, w, x, y, .Right)
	testing.expect(t, !app.document_menu_shown(w))

	press(s, w, x, y, .Right, {.Control})
	if !testing.expect(t, app.document_menu_shown(w)) {return}
	testing.expect(t, shown_in(w, app.Document_Menu_Link))
	testing.expect_value(t, held_target(w), "https://example.com/one")
	click_row(s, w, row_of(w, .Pin, level = .Tab))
	testing.expect(t, !app.document_menu_shown(w))
	scopes, found := app.document_scopes(s, w.panes[0].content)
	if !testing.expect(t, found) {return}
	if !testing.expect_value(t, len(scopes.tab), 1) {return}
	testing.expect_value(t, scopes.tab[0].target, "https://example.com/one")
	testing.expect_value(t, Open_Stub_State.calls, 0)

	press(s, w, x, y, .Right, {.Control})
	click_row(s, w, link_row(w, .Open))
	testing.expect(t, !app.document_menu_shown(w))
	testing.expect_value(t, Open_Stub_State.calls, 1)

	// Off any link it does nothing.
	far, far_ok := link_point(t, &f, 40, 5)
	if !far_ok {return}
	press(s, w, f32(far.x), f32(far.y), .Right, {.Control})
	testing.expect(t, !app.document_menu_shown(w))
}

@(private = "file")
link_row :: proc(w: ^app.Window, action: app.Link_Action) -> int {
	menu := &w.document_menu
	for i in 0 ..< menu.count {
		if menu.entries[i].action == .Link && menu.entries[i].link.action == action {return i}
	}
	return -1
}

// Reopens the menu on the link printed at the top of the terminal pane, wherever the last choice moved focus.
@(private = "file")
menu_on_path :: proc(t: ^testing.T, f: ^Palette_Fixture, terminal: layout.Content, modifiers: input.Modifiers) -> bool {
	s, w := &f.state, f.state.windows[0]
	if w.workspace.selected != 0 {app.tab_select(s, w, 0)}
	app.pane_focus(s, w, layout.find_content(app.window_tree(w), terminal))
	point, ok := link_point(t, f, 4, 0)
	if !ok {return false}
	press(s, w, f32(point.x), f32(point.y), .Right, modifiers)
	return testing.expect(t, shown_in(w, app.Document_Menu_Link))
}

// The axis of the split holding the focused pane: Horizontal side by side, Vertical stacked.
@(private = "file")
focus_axis :: proc(tree: ^layout.Layout) -> layout.Axis {
	for node in tree.nodes {
		split, is_split := node.(layout.Split)
		if is_split && (split.first == tree.focus || split.second == tree.focus) {return split.axis}
	}
	return {}
}

@(test)
link_menu_opens_a_markdown_file_in_each_place_copies_it_and_shows_its_folder :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "documents-link-places", false) {return}
	root, root_error := os.make_directory_temp("", "aio-link-places-*", context.allocator)
	if !testing.expect_value(t, root_error, nil) {return}
	defer {testing.expect_value(t, os.remove_all(root), nil); delete(root)}
	path := fmt.aprintf(`%s\notes.md`, root)
	defer delete(path)
	if !testing.expect_value(t, os.write_entire_file(path, transmute([]u8)string("# Notes\n")), nil) {return}
	s, w := &f.state, f.state.windows[0]
	Open_Stub_State = {}
	s.opener.file = link_file_stub
	s.opener.url = link_open_stub
	defer {s.opener.file = nil; s.opener.url = nil}
	terminal := w.panes[0].content
	link_feed(t, &f, fmt.tprintf("\x1b[2J\x1b[3J\x1b[H%s", path))
	// Shift+right-click shows the menu Ctrl+right-click shows, with every place a Markdown file can open.
	if !menu_on_path(t, &f, terminal, {.Shift}) {return}
	open := link_row(w, .Open)
	testing.expect(t, open >= 0 && w.document_menu.menu.items[open].submenu)
	testing.expect(t, link_row(w, .Open_External) >= 0 && link_row(w, .Copy) >= 0 && link_row(w, .Open_Folder) >= 0)
	// Its placements, the default marked: a split, as pane.markdown_floating is off.
	point_at(s, w, &w.document_menu.menu, open)
	testing.expect(t, app.document_submenu_shown(w))
	testing.expect_value(t, w.document_menu.submenu.items[placement_row(w, .Split_Right)].shortcut, "Default")
	testing.expect_value(t, len(w.document_menu.submenu.items), 5)
	held := strings.clone(held_target(w))
	defer delete(held)

	// Every choice opens its own pane, though the file already shows in another.
	choose_placement(s, w, &w.document_menu.menu, link_row(w, .Open), .Split_Right)
	tree := app.window_tree(w)
	testing.expect_value(t, layout.pane_count(tree), 2)
	focused, _ := layout.focused_content(tree)
	testing.expect_value(t, focused.kind, layout.Content_Kind.Markdown)
	testing.expect(t, !layout.is_floating(tree, tree.focus))
	testing.expect_value(t, focus_axis(tree), layout.Axis.Horizontal)

	if !menu_on_path(t, &f, terminal, {.Control}) {return}
	choose_placement(s, w, &w.document_menu.menu, link_row(w, .Open), .Split_Down, keyboard = true)
	testing.expect_value(t, layout.pane_count(tree), 3)
	testing.expect_value(t, focus_axis(tree), layout.Axis.Vertical)

	if !menu_on_path(t, &f, terminal, {.Control}) {return}
	choose_placement(s, w, &w.document_menu.menu, link_row(w, .Open), .Float)
	testing.expect_value(t, len(app.floating_rects(w)), 1)
	focused, _ = layout.focused_content(app.window_tree(w))
	testing.expect_value(t, focused.kind, layout.Content_Kind.Markdown)

	if !menu_on_path(t, &f, terminal, {.Control}) {return}
	choose_placement(s, w, &w.document_menu.menu, link_row(w, .Open), .Tab)
	testing.expect_value(t, len(w.workspace.tabs), 2)
	testing.expect_value(t, w.workspace.selected, 1)

	if !menu_on_path(t, &f, terminal, {.Control}) {return}
	choose_placement(s, w, &w.document_menu.menu, link_row(w, .Open), .Linked_Window)
	linked: ^app.Window
	for window in s.windows {if app.window_linked(window) {linked = window}}
	if testing.expect(t, linked != nil) {
		shown, _ := layout.focused_content(app.window_tree(linked))
		testing.expect_value(t, shown.kind, layout.Content_Kind.Markdown)
		testing.expect_value(t, app.pane_link_window_of(s, shown), linked)
	}
	testing.expect_value(t, len(s.markdown_panes), 5)

	// The system's handler, the copy and the folder each act on the file the menu holds.
	if !menu_on_path(t, &f, terminal, {.Control}) {return}
	click_row(s, w, link_row(w, .Open_External))
	testing.expect_value(t, Open_Stub_State.calls, 1)
	testing.expect(t, strings.has_suffix(Open_Stub_State.uri, `notes.md`), Open_Stub_State.uri)
	testing.expect(t, !Open_Stub_State.confirmed)

	if !menu_on_path(t, &f, terminal, {.Control}) {return}
	click_row(s, w, link_row(w, .Copy))
	copied, copied_ok := platform.clipboard_get_text(&s.platform, context.allocator)
	testing.expect(t, copied_ok)
	testing.expect_value(t, copied, held)
	delete(copied)

	if !menu_on_path(t, &f, terminal, {.Control}) {return}
	click_row(s, w, link_row(w, .Open_Folder))
	testing.expect_value(t, Open_Stub_State.calls, 2)
	testing.expect(t, !strings.has_suffix(Open_Stub_State.uri, `notes.md`), Open_Stub_State.uri)
	testing.expect(t, strings.has_prefix(held, Open_Stub_State.uri), Open_Stub_State.uri)

	// A web address can only open in the browser, so it offers no pane, program or folder.
	link_feed(t, &f, "\x1b[2J\x1b[3J\x1b[Hhttps://example.com/two")
	if !menu_on_path(t, &f, terminal, {.Shift}) {return}
	open = link_row(w, .Open)
	testing.expect(t, open >= 0 && !w.document_menu.menu.items[open].submenu)
	testing.expect(t, link_row(w, .Open_External) < 0 && link_row(w, .Open_Folder) < 0)
	testing.expect(t, link_row(w, .Copy) >= 0)
}

// A folder opens a new shell there in each place, from a printed path or from its pin, with the profile of the
// pane the menu came from.
@(test)
link_menu_opens_a_shell_in_a_folder_in_each_place_with_the_pane_profile :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "documents-link-shell", false) {return}
	root, root_error := os.make_directory_temp("", "aio-link-shell-*", context.allocator)
	if !testing.expect_value(t, root_error, nil) {return}
	defer {testing.expect_value(t, os.remove_all(root), nil); delete(root)}
	s, w := &f.state, f.state.windows[0]
	source := app.focused_session(s, w)
	if !testing.expect(t, source != nil) {return}
	terminal := w.panes[0].content
	// The source pane runs another profile than the default; the id need not resolve to be carried over.
	delete(source.profile_id)
	source.profile_id = strings.clone("alternate")
	link_feed(t, &f, fmt.tprintf("\x1b[2J\x1b[3J\x1b[H%s", root))
	opened_here :: proc(t: ^testing.T, s: ^app.App, before: int, root: string) -> ^app.Session_Entry {
		if !testing.expect_value(t, len(s.sessions), before + 1) {return nil}
		opened := &s.sessions[len(s.sessions) - 1]
		testing.expect_value(t, opened.profile_id, "alternate")
		testing.expect(t, strings.equal_fold(opened.header.launch_directory, root), opened.header.launch_directory)
		return opened
	}

	for placement in app.Link_Placement.Split_Right ..= app.Link_Placement.Linked_Window {
		if !menu_on_path(t, &f, terminal, {.Shift}) {return}
		testing.expect(t, link_row(w, .Open) < 0 && link_row(w, .Open_Folder) < 0)
		testing.expect(t, link_row(w, .Open_External) >= 0)
		before := len(s.sessions)
		choose_placement(s, w, &w.document_menu.menu, link_row(w, .Open_Shell), placement)
		testing.expect(t, !app.document_menu_shown(w))
		opened := opened_here(t, s, before, root)
		if opened == nil {return}
		content := layout.Content{.Terminal, opened.id}
		#partial switch placement {
		case .Split_Right, .Split_Down:
			tree := app.window_tree(w)
			focused, _ := layout.focused_content(tree)
			testing.expect_value(t, focused, content)
			testing.expect_value(t, focus_axis(tree), placement == .Split_Down ? layout.Axis.Vertical : .Horizontal)
		case .Float:
			tree := app.window_tree(w)
			testing.expect(t, layout.is_floating(tree, layout.find_content(tree, content)))
		case .Tab:
			testing.expect_value(t, w.workspace.selected, 1)
			focused, _ := layout.focused_content(app.window_tree(w))
			testing.expect_value(t, focused, content)
		case .Linked_Window:
			linked := app.pane_link_window_of(s, content)
			testing.expect(t, linked != nil && app.window_linked(linked))
		}
	}

	// Clicking Open in Shell itself opens its default, a right split.
	if !menu_on_path(t, &f, terminal, {.Shift}) {return}
	before := len(s.sessions)
	click_row(s, w, link_row(w, .Open_Shell))
	if opened := opened_here(t, s, before, root); opened != nil {
		tree := app.window_tree(w)
		focused, _ := layout.focused_content(tree)
		testing.expect_value(t, focused, layout.Content{.Terminal, opened.id})
		testing.expect_value(t, focus_axis(tree), layout.Axis.Horizontal)
	}

	// The folder pinned to the pane opens the same way from its right-click menu.
	menu_on_path(t, &f, terminal, {.Shift})
	held := strings.clone(held_target(w))
	defer delete(held)
	app.overlay_close(s, w)
	scopes, found := app.document_scopes(s, terminal)
	if !testing.expect(t, found) {return}
	_ = app.document_pin(scopes, .Pane, {target = held, folder = true})
	app.pane_focus(s, w, layout.find_content(app.window_tree(w), terminal))
	app.document_menu_open_focused(s, w)
	ui.menu_select(&w.document_menu.menu, row_of(w, .Open, held))
	key(s, w, .Enter, {.Control})
	before = len(s.sessions)
	choose_placement(s, w, &w.document_menu.actions, action_row(w, .Open_Shell), .Split_Down, keyboard = true)
	testing.expect(t, !app.document_menu_shown(w))
	opened_here(t, s, before, root)
}

// D-085: a link's right-click menu and its pin's offer the same actions, apart from pinning, moving and
// removing, for every kind of link.
@(test)
link_and_pinned_menus_offer_the_same_actions :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "documents-link-parity", false) {return}
	root, root_error := os.make_directory_temp("", "aio-link-parity-*", context.allocator)
	if !testing.expect_value(t, root_error, nil) {return}
	defer {testing.expect_value(t, os.remove_all(root), nil); delete(root)}
	markdown := fmt.aprintf(`%s\notes.md`, root)
	defer delete(markdown)
	text := fmt.aprintf(`%s\notes.txt`, root)
	defer delete(text)
	testing.expect_value(t, os.write_entire_file(markdown, transmute([]u8)string("# Notes\n")), nil)
	testing.expect_value(t, os.write_entire_file(text, transmute([]u8)string("x")), nil)
	s, w := &f.state, f.state.windows[0]
	terminal := w.panes[0].content
	shared :: bit_set[app.Link_Action]{.Open, .Open_Shell, .Program, .Open_External, .Copy, .Open_Folder}
	for printed in ([?]string{markdown, text, root, "https://example.com/parity"}) {
		link_feed(t, &f, fmt.tprintf("\x1b[2J\x1b[3J\x1b[H%s", printed))
		if !menu_on_path(t, &f, terminal, {.Shift}) {return}
		from_link: bit_set[app.Link_Action]
		for i in 0 ..< w.document_menu.count {
			if entry := w.document_menu.entries[i]; entry.action == .Link {from_link += {entry.link.action}}
		}
		state, _ := w.overlay.(app.Overlay_Document_Menu)
		link, _ := state.mode.(app.Document_Menu_Link)
		document := app.Document{strings.clone(link.document.target, context.temp_allocator), link.document.folder}
		app.overlay_close(s, w)
		scopes, found := app.document_scopes(s, terminal)
		if !testing.expect(t, found) {return}
		_ = app.document_pin(scopes, .Pane, document)
		app.document_menu_open_focused(s, w)
		ui.menu_select(&w.document_menu.menu, row_of(w, .Open, document.target))
		key(s, w, .Enter, {.Control})
		from_pin: bit_set[app.Link_Action]
		for item in w.document_menu.actions.items {
			if !item.separator {from_pin += {(transmute(app.Link_Choice)item.payload).action}}
		}
		testing.expectf(t, from_link == from_pin & shared, "%s: link %v, pin %v", printed, from_link, from_pin)
		testing.expect(t, card(from_link) > 1)
		app.overlay_close(s, w)
		testing.expect(t, app.document_remove(scopes, .Pane, document.target))
	}
}

// What the own-window launcher was last asked to start; the test frees the strings.
@(private = "file")
Program_Stub :: struct {
	calls:                   int,
	command_line, directory: string,
}

@(private = "file")
program_stub_state: Program_Stub

@(private = "file")
program_stub :: proc(command_line, directory: string) -> bool {
	delete(program_stub_state.command_line)
	delete(program_stub_state.directory)
	program_stub_state.calls += 1
	program_stub_state.command_line = strings.clone(command_line)
	program_stub_state.directory = strings.clone(directory)
	return true
}

// The labels of the link menu's program rows, in order.
@(private = "file")
program_labels :: proc(w: ^app.Window) -> []string {
	labels := make([dynamic]string, context.temp_allocator)
	menu := &w.document_menu
	for i in 0 ..< menu.count {
		if menu.entries[i].action == .Link && menu.entries[i].link.action == .Program {
			append(&labels, menu.menu.items[i].label)
		}
	}
	return labels[:]
}

// The link menu's row labelled `label`, or -1.
@(private = "file")
labelled_row :: proc(w: ^app.Window, label: string) -> int {
	for item, i in w.document_menu.menu.items {
		if item.label == label {return i}
	}
	return -1
}

// WORK-381: a Link Programs entry runs on a file or folder in a new pane, at its default placement on a click
// or at any other from its submenu, or as a window of its own; it starts in the link's folder. A program
// for folders only is not offered for a file.
@(test)
link_programs_open_links_in_panes_and_in_their_own_windows :: proc(t: ^testing.T) {
	sync.mutex_lock(&Link_Test_Lock)
	defer sync.mutex_unlock(&Link_Test_Lock)
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "documents-link-programs", false) {return}
	root, root_error := os.make_directory_temp("", "aio-link-programs-*", context.allocator)
	if !testing.expect_value(t, root_error, nil) {return}
	defer {testing.expect_value(t, os.remove_all(root), nil); delete(root)}
	file := fmt.aprintf(`%s\notes.txt`, root)
	defer delete(file)
	if !testing.expect_value(t, os.write_entire_file(file, transmute([]u8)string("x")), nil) {return}
	s, w := &f.state, f.state.windows[0]
	existing, read_error := os.read_entire_file(f.path, context.allocator)
	if !testing.expect_value(t, read_error, nil) {return}
	defer delete(existing)
	programs := "\nopener.echo.name = Echo\nopener.echo.command = cmd.exe /d /k rem %1\nopener.echo.placement = down\n" +
		"opener.dirs.name = Folder Tool\nopener.dirs.command = cmd.exe /d /k rem\nopener.dirs.offers = folders\n" +
		"opener.view.name = Viewer\nopener.view.command = cmd.exe /d /c rem \"%1\"\nopener.view.placement = window\n"
	updated := strings.concatenate({string(existing), programs}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(f.path, transmute([]u8)updated), nil) {return}
	app.reload_settings(s, false)
	program_stub_state = {}
	s.opener.program = program_stub
	defer {
		s.opener.program = nil
		delete(program_stub_state.command_line)
		delete(program_stub_state.directory)
		program_stub_state = {}
	}
	terminal := w.panes[0].content
	link_feed(t, &f, fmt.tprintf("\x1b[2J\x1b[3J\x1b[H%s", file))

	// A file is offered the programs for files, in settings' order, after Open; only pane programs have
	// placements.
	if !menu_on_path(t, &f, terminal, {.Shift}) {return}
	labels := program_labels(w)
	if !testing.expect_value(t, len(labels), 2) {return}
	testing.expect_value(t, labels[0], "Open in Echo")
	testing.expect_value(t, labels[1], "Open in Viewer")
	testing.expect(t, w.document_menu.menu.items[labelled_row(w, "Open in Echo")].submenu)
	testing.expect(t, !w.document_menu.menu.items[labelled_row(w, "Open in Viewer")].submenu)

	// Clicking a program opens it at its default, a down split, running its command in the file's folder.
	before := len(s.sessions)
	click_row(s, w, labelled_row(w, "Open in Echo"))
	if !testing.expect_value(t, len(s.sessions), before + 1) {return}
	opened := &s.sessions[len(s.sessions) - 1]
	// The program is named by the path found for it, so nothing searches for it again.
	command := opened.header.command
	testing.expect(t, strings.has_prefix(command, `"`), command)
	testing.expect(t, strings.has_suffix(command, fmt.tprintf(`\cmd.exe" /d /k rem %s`, file)), command)
	testing.expect(t, strings.equal_fold(opened.header.launch_directory, root), opened.header.launch_directory)
	testing.expect_value(t, focus_axis(app.window_tree(w)), layout.Axis.Vertical)

	// Its submenu marks that default and opens it anywhere else.
	if !menu_on_path(t, &f, terminal, {.Shift}) {return}
	point_at(s, w, &w.document_menu.menu, labelled_row(w, "Open in Echo"))
	testing.expect_value(t, w.document_menu.submenu.items[placement_row(w, .Split_Down)].shortcut, "Default")
	// Moving straight down to the next row is not heading for the submenu: that row takes the hover at once.
	point_at(s, w, &w.document_menu.menu, labelled_row(w, "Open in Viewer"))
	testing.expect_value(t, ui.menu_selected(&w.document_menu.menu), labelled_row(w, "Open in Viewer"))
	testing.expect(t, !app.document_submenu_shown(w), "the submenu gives way")
	point_at(s, w, &w.document_menu.menu, labelled_row(w, "Open in Echo"))
	choose_placement(s, w, &w.document_menu.menu, labelled_row(w, "Open in Echo"), .Float)
	testing.expect_value(t, len(app.floating_rects(w)), 1)

	// A windowed program starts on its own, its quotes kept, and opens no pane.
	if !menu_on_path(t, &f, terminal, {.Shift}) {return}
	before = len(s.sessions)
	click_row(s, w, labelled_row(w, "Open in Viewer"))
	testing.expect_value(t, len(s.sessions), before)
	testing.expect_value(t, program_stub_state.calls, 1)
	started := program_stub_state.command_line
	testing.expect(t, strings.has_suffix(started, fmt.tprintf(`\cmd.exe" /d /c rem "%s"`, file)), started)
	testing.expect(t, strings.equal_fold(program_stub_state.directory, root), program_stub_state.directory)

	// A folder is offered the folder program as well, after Open in Shell.
	link_feed(t, &f, fmt.tprintf("\x1b[2J\x1b[3J\x1b[H%s", root))
	if !menu_on_path(t, &f, terminal, {.Shift}) {return}
	labels = program_labels(w)
	if !testing.expect_value(t, len(labels), 3) {return}
	testing.expect_value(t, labels[0], "Open in Folder Tool")
	testing.expect(t, link_row(w, .Open_Shell) < labelled_row(w, "Open in Folder Tool"))
	app.overlay_close(s, w)
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
