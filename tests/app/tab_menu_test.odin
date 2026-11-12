package app_test

import "aio:commands"
import "aio:input"
import "core:fmt"
import "core:os"
import "core:testing"
import app "../../src"
import fixtures "../fixtures"
import "aio:font"
import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:ui"

@(init)
menu_warm :: proc "contextless" () {
	fixtures.warm_directwrite()
}

Menu_Fixture :: struct {
	state: app.App,
	workspace: app.Workspace,
	w: app.Window,
}

menu_fixture_init :: proc(t: ^testing.T, f: ^Menu_Fixture, count: int) -> bool {
	if !testing.expect_value(t, platform.init(&f.state.platform,
		fmt.tprintf("AIODev.Test.TabMenu.%d.%p", os.get_pid(), f)), platform.Init_Result.Primary) { return false }
	id, err := platform.window_create(&f.state.platform, {hidden = true, width = 800, height = 600})
	if !testing.expect_value(t, err, platform.Error.None) { return false }
	f.w = {id = id, workspace = &f.workspace, scale = 1}
	append(&f.state.windows, &f.w)
	for i in 0..<count {
		tab := new(app.Tab)
		tab.id, tab.marked = u32(i+1), i == 0
		testing.expect_value(t, layout.init(&tab.tree, {.Terminal, 0}), nil)
		append(&f.workspace.tabs, tab)
	}
	f.workspace.next_tab_id = u32(count)
	// Commands name a tab by its workspace's id, so the workspace is registered as a shown one always is.
	f.workspace.id = 1
	append(&f.state.workspaces, &f.workspace)
	f.state.settings.interface.confirm = {.Close_Split_Tab}
	f.state.registry = commands.create()
	return testing.expect_value(t, app.register_actions(&f.state.registry), commands.Error.None)
}

menu_fixture_destroy :: proc(f: ^Menu_Fixture) {
	for tab in f.workspace.tabs {
		layout.destroy(&tab.tree)
		delete(tab.title)
		delete(tab.name)
		free(tab)
	}
	delete(f.workspace.tabs)
	app.tab_menu_destroy(&f.w.tab_menu)
	delete(f.state.windows)
	delete(f.state.workspaces)
	app.confirmation_clear(&f.w)
	delete(f.w.rename.bytes)
	delete(f.w.panes)
	delete(f.w.dividers)
	ui.editor_destroy(&f.w.editor)
	_ = platform.destroy(&f.state.platform)
	commands.destroy(&f.state.registry)
}

menu_key :: proc(f: ^Menu_Fixture, key: input.Key_Event) {
	e := key
	e.window, e.pressed = f.w.id, true
	app.handle_event(&f.state, e)
	e.pressed = false
	app.handle_event(&f.state, e)
}

// Menu `m` shown in window `w`: its rect and visible row count.
window_menu_rect :: proc(w: ^app.Window, m: ^ui.Menu) -> (render.Rect, int) {
	return ui.menu_layout(m, f32(w.width), f32(w.height), w.scale)
}

window_menu_row :: proc(w: ^app.Window, m: ^ui.Menu, index: int) -> render.Rect {
	return ui.menu_row_rect(m, index, f32(w.width), f32(w.height), w.scale)
}

@(test)
tab_menu_exact_single_rows :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 1) { return }
	w := &f.w
	app.tab_menu_open(&f.state, w, 0, 10, 20)
	if !testing.expect_value(t, len(w.tab_menu.items), 10) { return }
	labels := [?]string{"Rename", "Duplicate", "", "Move Tab to Workspace…", "Move Tab to New Workspace",
		"Close to the Right", "Close Others", "Close", "", "Tab Settings"}
	actions := [?]app.Action{.Rename_Tab, .Duplicate_Tab, {}, .Move_Tab_Workspace, .Move_Tab_New_Workspace, .Close_Right_Tabs,
		.Close_Other_Tabs, .Close_Tab, {}, .Tab_Settings}
	for label, i in labels {
		testing.expect_value(t, w.tab_menu.items[i].label, label)
		testing.expect_value(t, w.tab_menu.items[i].separator, label == "")
		if label != "" { testing.expect_value(t, app.Action(w.tab_menu.items[i].payload), actions[i]) }
	}
	testing.expect(t, !app.tab_menu_enabled(w, 5) && !app.tab_menu_enabled(w, 6))
	for index in ([?]int{2, 5, 6, 8}) {
		ui.menu_select(&w.tab_menu.menu, index)
		app.tab_menu_choose(&f.state, w)
		testing.expect(t, app.tab_menu_shown(w))
		testing.expect_value(t, len(f.workspace.tabs), 1)
	}
}

// The menu keeps the pointer as its anchor, clamped into the client, so it may sit
// inside the caption band; its press handling runs before the caption's.
@(test)
tab_menu_anchors_at_the_pointer_inside_the_client :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 1) { return }
	w := &f.w
	w.width, w.height = 800, 600
	app.tab_menu_open(&f.state, w, 0, 40, 20)
	r, _ := window_menu_rect(w, &w.tab_menu.menu)
	testing.expect_value(t, r.x, f32(40))
	testing.expect_value(t, r.y, f32(20))
	testing.expect(t, r.y < ui.caption_claim_height(w.scale))
	app.tab_menu_open(&f.state, w, 0, 1300, 1100)
	r, _ = window_menu_rect(w, &w.tab_menu.menu)
	testing.expect_value(t, r.x, f32(w.width)-r.width-8*w.scale)
	testing.expect_value(t, r.y, f32(w.height)-r.height-8*w.scale)
	testing.expect(t, r.x+r.width <= f32(w.width) && r.y+r.height <= f32(w.height))
	app.tab_menu_open(&f.state, w, 0, -50, -50)
	r, _ = window_menu_rect(w, &w.tab_menu.menu)
	testing.expect_value(t, r.x, 8*w.scale)
	testing.expect_value(t, r.y, 8*w.scale)
}

@(test)
tab_menu_group_and_settings_capabilities :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 3) { return }
	w := &f.w
	f.workspace.tabs[2].marked = true
	app.tab_menu_open(&f.state, w, 2, 10, 20)
	testing.expect_value(t, len(w.tab_menu.items), 4)
	testing.expect_value(t, w.tab_menu.items[0].label, "Close Others")
	testing.expect_value(t, w.tab_menu.items[1].label, "Close 2 Selected Tabs")
	testing.expect(t, w.tab_menu.items[2].separator)
	testing.expect_value(t, w.tab_menu.items[3].label, "Tab Settings")
	testing.expect(t, f.workspace.tabs[0].marked && f.workspace.tabs[2].marked)
	// Right-clicking never activates a tab or changes the marks.
	testing.expect_value(t, f.workspace.selected, 0)
	app.tab_menu_open(&f.state, w, 1, 10, 20)
	testing.expect_value(t, len(w.tab_menu.items), 10)
	testing.expect(t, f.workspace.tabs[0].marked && f.workspace.tabs[2].marked && !f.workspace.tabs[1].marked)
	// An unmarked target shows as the only marked tab while its menu is open.
	testing.expect(t, app.tab_marked_shown(w, 1) && !app.tab_marked_shown(w, 0) && !app.tab_marked_shown(w, 2))
	testing.expect(t, app.tab_menu_enabled(w, 3) && app.tab_menu_enabled(w, 4))
	settings_tab := f.workspace.tabs[1]
	layout.destroy(&settings_tab.tree)
	testing.expect_value(t, layout.init(&settings_tab.tree, {.Settings, 0}), nil)
	app.tab_menu_open(&f.state, w, 1, 10, 20)
	testing.expect_value(t, len(w.tab_menu.items), 10)
	for label, i in ([?]string{"Rename", "Duplicate", "", "Move Tab to Workspace…", "Move Tab to New Workspace", "Close to the Right",
		"Close Others", "Close", "", "Tab Settings"}) {
		testing.expect_value(t, w.tab_menu.items[i].label, label)
	}
	// A settings pane has no runtime to duplicate, but its tab still renames and closes normally.
	testing.expect(t, app.tab_menu_enabled(w, 0) && !app.tab_menu_enabled(w, 1))
	for tab in f.workspace.tabs { tab.marked = true }
	app.tab_menu_open(&f.state, w, 1, 10, 20)
	testing.expect_value(t, len(w.tab_menu.items), 4)
	testing.expect(t, !app.tab_menu_enabled(w, 0))
	testing.expect_value(t, ui.menu_selected(&w.tab_menu.menu), 1)
}

@(test)
tab_menu_event_navigation_and_dismissal :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 1) { return }
	w := &f.w
	menu_key(&f, {key = .Context_Menu})
	testing.expect(t, app.tab_menu_shown(w))
	menu_key(&f, {key = .Arrow_Down})
	testing.expect_value(t, ui.menu_selected(&w.tab_menu.menu), 1)
	menu_key(&f, {key = .Arrow_Down})
	testing.expect_value(t, ui.menu_selected(&w.tab_menu.menu), 3)
	menu_key(&f, {key = .Arrow_Down})
	testing.expect_value(t, ui.menu_selected(&w.tab_menu.menu), 4)
	menu_key(&f, {key = .N, modifiers = {.Control}})
	testing.expect_value(t, ui.menu_selected(&w.tab_menu.menu), 7)
	menu_key(&f, {key = .Y, unshifted = 'p', modifiers = {.Control}})
	testing.expect_value(t, ui.menu_selected(&w.tab_menu.menu), 4)
	menu_key(&f, {key = .Home})
	testing.expect_value(t, ui.menu_selected(&w.tab_menu.menu), 0)
	menu_key(&f, {key = .End})
	testing.expect_value(t, ui.menu_selected(&w.tab_menu.menu), 9)
	menu_key(&f, {key = .Escape})
	testing.expect(t, !app.tab_menu_shown(w) && !app.key_suppressed(w, .Escape))
	menu_key(&f, {key = .F10, modifiers = {.Shift}})
	testing.expect(t, app.tab_menu_shown(w))
	menu_key(&f, {key = .Context_Menu})
	testing.expect(t, !app.tab_menu_shown(w))
	menu_key(&f, {key = .Context_Menu})
	app.handle_event(&f.state, platform.Focus_Event{w.id, false})
	testing.expect(t, !app.tab_menu_shown(w))
	menu_key(&f, {key = .Context_Menu})
	w.width, w.height = 800, 600
	row := window_menu_row(w, &w.tab_menu.menu, 2)
	app.handle_event(&f.state, input.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = i32(row.x+10), y = i32(row.y+row.height/2)})
	testing.expect(t, app.tab_menu_shown(w) && !app.rename_shown(w))
	menu_key(&f, {key = .Home})
	app.handle_event(&f.state, input.Mouse_Wheel_Event{window = w.id, delta_y = -1})
	testing.expect_value(t, ui.menu_selected(&w.tab_menu.menu), 1)
	app.handle_event(&f.state, input.Mouse_Wheel_Event{window = w.id, delta_y = -1})
	testing.expect_value(t, ui.menu_selected(&w.tab_menu.menu), 3)
	app.handle_event(&f.state, input.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = 799, y = 599})
	testing.expect(t, !app.tab_menu_shown(w))
	w.width, w.height = 0, 0
	menu_key(&f, {key = .Context_Menu})
	menu_key(&f, {key = .Enter})
	dialog, shown := w.overlay.(app.Overlay_Rename)
	target, naming_tab := dialog.target.(app.Rename_Tab_Target)
	testing.expect(t, !app.tab_menu_shown(w) && shown && naming_tab)
	testing.expect_value(t, target.tab, f.workspace.tabs[0].id)
	testing.expect_value(t, target.workspace, f.workspace.id)
}

// The menu keys are the defaults of Show Tab Menu, so a rebinding moves them like any other shortcut.
@(test)
tab_context_menu_is_a_rebindable_command :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 1) { return }
	w := &f.w
	command := commands.find(&f.state.registry, "tab.context_menu")
	if !testing.expect(t, command != nil) { return }
	defaults := commands.active_shortcuts(command)
	if testing.expect_value(t, len(defaults), 2) {
		testing.expect_value(t, defaults[0], commands.Shortcut{.Context_Menu, {}})
		testing.expect_value(t, defaults[1], commands.Shortcut{.F10, {.Shift}})
	}
	bindings := [?]commands.Shortcut{{.M, {.Control, .Alt}}}
	overrides := [?]commands.Override{{command.id, bindings[:]}}
	errors: [1]commands.Error
	testing.expect_value(t, commands.rebind(&f.state.registry, overrides[:], errors[:]), commands.Error.None)
	menu_key(&f, {key = .Context_Menu})
	menu_key(&f, {key = .F10, modifiers = {.Shift}})
	testing.expect(t, !app.tab_menu_shown(w))
	menu_key(&f, {key = .M, modifiers = {.Control, .Alt}})
	testing.expect(t, app.tab_menu_shown(w))
	testing.expect_value(t, app.tab_menu_target(w), 0)
	menu_key(&f, {key = .Escape})
	app.run_action(&f.state, w, .Tab_Context_Menu)
	testing.expect(t, app.tab_menu_shown(w))
}

@(test)
tab_menu_close_subset_cancel_restores_selection :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 3) { return }
	w := &f.w
	_, split_error := layout.split_direction(&f.workspace.tabs[2].tree,
		f.workspace.tabs[2].tree.root, .Right, 0.5, {.Terminal, 0})
	testing.expect_value(t, split_error, nil)
	for action in ([?]app.Action{.Close_Right_Tabs, .Close_Other_Tabs, .Close_Tab}) {
		app.tab_menu_open(&f.state, w, action == .Close_Tab ? 2 : 0, 10, 20)
		for item, i in w.tab_menu.items {
			if item.separator || app.Action(item.payload) != action { continue }
			ui.menu_select(&w.tab_menu.menu, i)
			break
		}
		app.tab_menu_choose(&f.state, w)
		testing.expect(t, app.confirmation_asking(w, app.Pending_Close) != nil && !app.tab_menu_shown(w))
		menu_key(&f, {key = .Escape})
		testing.expect(t, app.confirmation_current(w) == nil)
		testing.expect_value(t, len(f.workspace.tabs), 3)
		for tab, i in f.workspace.tabs { testing.expect_value(t, tab.marked, i == f.workspace.selected) }
		// The answer took the marks it put back, so the closing question holds none.
		if closing := app.confirmation_subject(w, app.Pending_Close); closing != nil {
			held, _ := closing.target.(app.Close_Tab)
			testing.expect_value(t, len(held.restore), 0)
		}
	}
	app.tab_menu_open(&f.state, w, 0, 10, 20)
	ui.menu_select(&w.tab_menu.menu, 5)
	app.tab_menu_choose(&f.state, w)
	menu_key(&f, {key = .Enter})
	testing.expect_value(t, len(f.workspace.tabs), 1)
	testing.expect(t, f.workspace.tabs[0].marked && app.confirmation_current(w) == nil)
}

// Regression: a close subset requested while a tab-close question is open (a command can do this) must
// replace the question with its own marks, not have the replaced question's cancel restore them.
@(test)
tab_close_subset_replaces_an_open_close_question_with_its_marks :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 3) { return }
	w := &f.w
	_, split_error := layout.split_direction(&f.workspace.tabs[2].tree,
		f.workspace.tabs[2].tree.root, .Right, 0.5, {.Terminal, 0})
	testing.expect_value(t, split_error, nil)
	app.pending_close_open_tab(&f.state, w, 2)
	pc := app.confirmation_asking(w, app.Pending_Close)
	if !testing.expect(t, pc != nil && pc.tabs == 1) { return }
	app.tab_close_subset(&f.state, w, true, 0)
	pc = app.confirmation_asking(w, app.Pending_Close)
	if !testing.expect(t, pc != nil) { return }
	testing.expect_value(t, pc.tabs, 2)
	testing.expect(t, f.workspace.tabs[1].marked && f.workspace.tabs[2].marked)
	menu_key(&f, {key = .Enter})
	if !testing.expect_value(t, len(f.workspace.tabs), 1) { return }
	testing.expect_value(t, f.workspace.tabs[0].id, 1)
}

// Regression: a close subset requested while another subset's question asks rewrites that question, and
// dismissing it puts back the marks from before the first subset rather than the first subset's own.
@(test)
tab_close_subset_over_a_subset_question_restores_the_original_marks :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 3) { return }
	w := &f.w
	_, split_error := layout.split_direction(&f.workspace.tabs[2].tree,
		f.workspace.tabs[2].tree.root, .Right, 0.5, {.Terminal, 0})
	testing.expect_value(t, split_error, nil)
	app.tab_close_subset(&f.state, w, true, 0)
	testing.expect(t, !f.workspace.tabs[0].marked && f.workspace.tabs[1].marked && f.workspace.tabs[2].marked)
	app.tab_close_subset(&f.state, w, true, 1)
	testing.expect(t, !f.workspace.tabs[0].marked && !f.workspace.tabs[1].marked && f.workspace.tabs[2].marked)
	menu_key(&f, {key = .Escape})
	testing.expect_value(t, len(f.workspace.tabs), 3)
	for tab, i in f.workspace.tabs { testing.expect_value(t, tab.marked, i == 0) }
}

@(test)
tab_menu_close_others_acts_on_an_unmarked_target :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 3) { return }
	w := &f.w
	_, split_error := layout.split_direction(&f.workspace.tabs[2].tree,
		f.workspace.tabs[2].tree.root, .Right, 0.5, {.Terminal, 0})
	testing.expect_value(t, split_error, nil)
	app.tab_menu_open(&f.state, w, 1, 10, 20)
	for item, i in w.tab_menu.items {
		if item.separator || app.Action(item.payload) != .Close_Other_Tabs { continue }
		ui.menu_select(&w.tab_menu.menu, i)
		break
	}
	app.tab_menu_choose(&f.state, w)
	testing.expect_value(t, f.workspace.selected, 0)
	testing.expect(t, app.confirmation_asking(w, app.Pending_Close) != nil && f.workspace.tabs[0].marked &&
		!f.workspace.tabs[1].marked && f.workspace.tabs[2].marked)
	menu_key(&f, {key = .Enter})
	if !testing.expect_value(t, len(f.workspace.tabs), 1) { return }
	testing.expect_value(t, f.workspace.tabs[0].id, 2)
	testing.expect(t, f.workspace.tabs[0].marked)
}

@(test)
tab_menu_group_cancel_and_settings_destination :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 3) { return }
	w := &f.w
	f.workspace.tabs[1].marked = true
	_, split_error := layout.split_direction(&f.workspace.tabs[2].tree,
		f.workspace.tabs[2].tree.root, .Right, 0.5, {.Terminal, 0})
	testing.expect_value(t, split_error, nil)
	app.tab_menu_open(&f.state, w, 1, 10, 20)
	app.tab_menu_choose(&f.state, w)
	testing.expect(t, app.confirmation_asking(w, app.Pending_Close) != nil && f.workspace.tabs[2].marked)
	menu_key(&f, {key = .Escape})
	testing.expect(t, f.workspace.tabs[0].marked && f.workspace.tabs[1].marked && !f.workspace.tabs[2].marked)
	testing.expect_value(t, f.workspace.selected, 0)
	settings_tab := f.workspace.tabs[2]
	layout.destroy(&settings_tab.tree)
	testing.expect_value(t, layout.init(&settings_tab.tree, {.Settings, 0}), nil)
	testing.expect_value(t, ui.editor_add(&w.editor,
		{key = "interface.confirm", title = "Confirm Before", value = "Closing Split Tabs"}, "Interface"), nil)
	ui.field_set(&w.editor.filter, "unrelated query")
	ui.editor_filter(&w.editor)
	app.tab_menu_open(&f.state, w, 1, 10, 20)
	menu_key(&f, {key = .End})
	menu_key(&f, {key = .Enter})
	testing.expect(t, app.settings_active(w) && !app.tab_menu_shown(w))
	testing.expect_value(t, ui.field_string(&w.editor.filter), "")
	if row := ui.editor_row(&w.editor); testing.expect(t, row != nil) {
		testing.expect_value(t, row.key, "interface.confirm")
	}
}

@(test)
tab_menu_draw_matches_labels_separators_and_disabled_rows :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 1) { return }
	w := &f.w
	app.tab_menu_open(&f.state, w, 0, 10, 20)
	fonts, font_error := font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) { return }
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&w.ui_text, fonts, &cache, 14)) { return }
	w.list = render.draw_list_init()
	defer render.draw_list_destroy(&w.list)
	expected := render.draw_list_init()
	defer render.draw_list_destroy(&expected)
	f.state.theme = {text = {1, 1, 1, 1}, muted = {0.5, 0.5, 0.5, 1}, border = {0.2, 0.2, 0.2, 1}}
	for scale in ([?]f32{1, 1.5, 2}) {
		w.scale, w.width, w.height = scale, i32(800*scale), i32(600*scale)
		render.draw_list_reset(&w.list)
		render.draw_list_reset(&expected)
		testing.expect_value(t, render.push_layer(&expected, {0, 0, f32(w.width), f32(w.height)}), render.Error.None)
		testing.expect_value(t, app.tab_menu_draw(&f.state, w), render.Build_Status.Ok)
		y := window_menu_row(w, &w.tab_menu.menu, 0).y
		labels := [?]string{"Rename", "Duplicate", "", "Move Tab to Workspace…", "Move Tab to New Workspace", "Close to the Right",
			"Close Others", "Close", "", "Tab Settings"}
		for label, i in labels {
			row := window_menu_row(w, &w.tab_menu.menu, i)
			testing.expect_value(t, row.y, y)
			testing.expect_value(t, row.height, (label == "" ? ui.MENU_SEPARATOR_HEIGHT : ui.MENU_ROW_HEIGHT)*scale)
			y += row.height
			testing.expect_value(t, app.tab_menu_hit(w, row.x+1, row.y+row.height/2), i)
			if label == "" {
				divider := w.list.rects[i == 2 ? 4 : 5]
				testing.expect_value(t, divider.rect, render.Rect{row.x+ui.CONTROL_INSET*scale, row.y+4*scale, row.width-2*ui.CONTROL_INSET*scale, scale})
				continue
			}
			testing.expect_value(t, ui.draw_text(&w.ui_text, &expected, label, row.x+ui.CONTROL_INSET*scale,
				row.y+(row.height-w.ui_text.line_height)/2+w.ui_text.ascent,
				i == 5 || i == 6 ? f.state.theme.muted : f.state.theme.text,
				max(1, row.width-2*ui.CONTROL_INSET*scale)), render.Build_Status.Ok)
		}
		testing.expect_value(t, len(w.list.glyphs), len(expected.glyphs))
		for glyph, i in w.list.glyphs { testing.expect_value(t, glyph, expected.glyphs[i]) }
		w.height = i32(120*scale)
		menu_key(&f, {key = .End})
		render.draw_list_reset(&w.list)
		testing.expect_value(t, app.tab_menu_draw(&f.state, w), render.Build_Status.Ok)
		r, rows := window_menu_rect(w, &w.tab_menu.menu)
		scroll, selected := w.tab_menu.scroll, ui.menu_selected(&w.tab_menu.menu)
		testing.expect(t, scroll > 0 && scroll+rows > selected)
		testing.expect(t, r.y+r.height <= f32(w.height))
		menu_key(&f, {key = .Home})
		render.draw_list_reset(&w.list)
		testing.expect_value(t, app.tab_menu_draw(&f.state, w), render.Build_Status.Ok)
		testing.expect_value(t, w.tab_menu.scroll, 0)
	}
}
