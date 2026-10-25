package app_test

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
	f.w.tree = &f.workspace.tabs[0].tree
	f.state.settings.tab.confirm_close = true
	return true
}

menu_fixture_destroy :: proc(f: ^Menu_Fixture) {
	for tab in f.workspace.tabs {
		layout.destroy(&tab.tree)
		delete(tab.title)
		delete(tab.name)
		free(tab)
	}
	delete(f.workspace.tabs)
	delete(f.state.windows)
	delete(f.w.close_restore)
	delete(f.w.rename.bytes)
	delete(f.w.panes)
	delete(f.w.dividers)
	ui.editor_destroy(&f.w.editor)
	_ = platform.destroy(&f.state.platform)
}

menu_key :: proc(f: ^Menu_Fixture, key: platform.Key_Event) {
	e := key
	e.window, e.pressed = f.w.id, true
	app.handle_event(&f.state, e)
	e.pressed = false
	app.handle_event(&f.state, e)
}

@(test)
tab_menu_exact_single_rows :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 1) { return }
	w := &f.w
	app.tab_menu_open(&f.state, w, 0, 10, 20)
	if !testing.expect_value(t, w.tab_menu.count, 8) { return }
	labels := [?]string{"Rename", "Duplicate", "", "Close to the Right", "Close Others", "Close", "", "Tab Settings"}
	actions := [?]app.Action{.Rename_Tab, .Duplicate_Tab, {}, .Close_Right_Tabs,
		.Close_Other_Tabs, .Close_Tab, {}, .Tab_Settings}
	for label, i in labels {
		testing.expect_value(t, app.tab_menu_label(w, i), label)
		testing.expect_value(t, w.tab_menu.separators[i], label == "")
		if label != "" { testing.expect_value(t, w.tab_menu.actions[i], actions[i]) }
	}
	testing.expect(t, !app.tab_menu_enabled(w, 3) && !app.tab_menu_enabled(w, 4))
	for index in ([?]int{2, 3, 4, 6}) {
		w.tab_menu.selected = index
		app.tab_menu_choose(&f.state, w)
		testing.expect(t, w.tab_menu.open)
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
	r, _ := app.tab_menu_rect(w)
	testing.expect_value(t, r.x, f32(40))
	testing.expect_value(t, r.y, f32(20))
	testing.expect(t, r.y < ui.caption_claim_height(w.scale))
	app.tab_menu_open(&f.state, w, 0, 1300, 1100)
	r, _ = app.tab_menu_rect(w)
	testing.expect_value(t, r.x, f32(w.width)-r.width-8*w.scale)
	testing.expect_value(t, r.y, f32(w.height)-r.height-8*w.scale)
	testing.expect(t, r.x+r.width <= f32(w.width) && r.y+r.height <= f32(w.height))
	app.tab_menu_open(&f.state, w, 0, -50, -50)
	r, _ = app.tab_menu_rect(w)
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
	testing.expect_value(t, w.tab_menu.count, 4)
	testing.expect_value(t, app.tab_menu_label(w, 0), "Close Others")
	testing.expect_value(t, app.tab_menu_label(w, 1), "Close 2 Selected Tabs")
	testing.expect(t, w.tab_menu.separators[2])
	testing.expect_value(t, app.tab_menu_label(w, 3), "Tab Settings")
	testing.expect(t, f.workspace.tabs[0].marked && f.workspace.tabs[2].marked)
	testing.expect_value(t, f.workspace.selected, 2)
	app.tab_menu_open(&f.state, w, 1, 10, 20)
	testing.expect_value(t, w.tab_menu.count, 8)
	testing.expect(t, !f.workspace.tabs[0].marked && !f.workspace.tabs[2].marked)
	testing.expect(t, app.tab_menu_enabled(w, 3) && app.tab_menu_enabled(w, 4))
	settings_tab := f.workspace.tabs[1]
	layout.destroy(&settings_tab.tree)
	testing.expect_value(t, layout.init(&settings_tab.tree, {.Settings, 0}), nil)
	app.tab_menu_open(&f.state, w, 1, 10, 20)
	testing.expect_value(t, w.tab_menu.count, 8)
	for label, i in ([?]string{"Rename", "Duplicate", "", "Close to the Right",
		"Close Others", "Close", "", "Tab Settings"}) {
		testing.expect_value(t, app.tab_menu_label(w, i), label)
	}
	// A settings pane has no runtime to duplicate, but its tab still renames and closes normally.
	testing.expect(t, app.tab_menu_enabled(w, 0) && !app.tab_menu_enabled(w, 1))
	for tab in f.workspace.tabs { tab.marked = true }
	app.tab_menu_open(&f.state, w, 1, 10, 20)
	testing.expect_value(t, w.tab_menu.count, 4)
	testing.expect(t, !app.tab_menu_enabled(w, 0))
	testing.expect_value(t, w.tab_menu.selected, 1)
}

@(test)
tab_menu_event_navigation_and_dismissal :: proc(t: ^testing.T) {
	f: Menu_Fixture
	defer menu_fixture_destroy(&f)
	if !menu_fixture_init(t, &f, 1) { return }
	w := &f.w
	menu_key(&f, {key = .Context_Menu})
	testing.expect(t, w.tab_menu.open)
	menu_key(&f, {key = .Arrow_Down})
	testing.expect_value(t, w.tab_menu.selected, 1)
	menu_key(&f, {key = .Arrow_Down})
	testing.expect_value(t, w.tab_menu.selected, 5)
	menu_key(&f, {key = .Arrow_Down})
	testing.expect_value(t, w.tab_menu.selected, 7)
	menu_key(&f, {key = .N, modifiers = {.Control}})
	testing.expect_value(t, w.tab_menu.selected, 0)
	menu_key(&f, {key = .Y, unshifted = 'p', modifiers = {.Control}})
	testing.expect_value(t, w.tab_menu.selected, 7)
	menu_key(&f, {key = .Home})
	testing.expect_value(t, w.tab_menu.selected, 0)
	menu_key(&f, {key = .End})
	testing.expect_value(t, w.tab_menu.selected, 7)
	menu_key(&f, {key = .Escape})
	testing.expect(t, !w.tab_menu.open && w.suppressed_key == nil)
	menu_key(&f, {key = .F10, modifiers = {.Shift}})
	testing.expect(t, w.tab_menu.open)
	menu_key(&f, {key = .Context_Menu})
	testing.expect(t, !w.tab_menu.open)
	menu_key(&f, {key = .Context_Menu})
	app.handle_event(&f.state, platform.Focus_Event{w.id, false})
	testing.expect(t, !w.tab_menu.open)
	menu_key(&f, {key = .Context_Menu})
	w.width, w.height = 800, 600
	row := app.tab_menu_row_rect(w, 2)
	app.handle_event(&f.state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = i32(row.x+10), y = i32(row.y+row.height/2)})
	testing.expect(t, w.tab_menu.open && !w.rename_open)
	menu_key(&f, {key = .Home})
	app.handle_event(&f.state, platform.Mouse_Wheel_Event{window = w.id, delta_y = -1})
	testing.expect_value(t, w.tab_menu.selected, 1)
	app.handle_event(&f.state, platform.Mouse_Wheel_Event{window = w.id, delta_y = -1})
	testing.expect_value(t, w.tab_menu.selected, 5)
	app.handle_event(&f.state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = 799, y = 599})
	testing.expect(t, !w.tab_menu.open)
	w.width, w.height = 0, 0
	menu_key(&f, {key = .Context_Menu})
	menu_key(&f, {key = .Enter})
	testing.expect(t, !w.tab_menu.open && w.rename_open && w.rename_target.kind == app.Rename_Kind.Tab)
	testing.expect_value(t, w.rename_target.id, f.workspace.tabs[0].id)
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
		for candidate, i in w.tab_menu.actions[:w.tab_menu.count] {
			if !w.tab_menu.separators[i] && candidate == action { w.tab_menu.selected = i; break }
		}
		app.tab_menu_choose(&f.state, w)
		testing.expect(t, w.pending_close.confirm.open && !w.tab_menu.open)
		menu_key(&f, {key = .Escape})
		testing.expect(t, !w.pending_close.confirm.open)
		testing.expect_value(t, len(f.workspace.tabs), 3)
		for tab, i in f.workspace.tabs { testing.expect_value(t, tab.marked, i == f.workspace.selected) }
		testing.expect_value(t, len(w.close_restore), 0)
	}
	app.tab_menu_open(&f.state, w, 0, 10, 20)
	w.tab_menu.selected = 3
	app.tab_menu_choose(&f.state, w)
	menu_key(&f, {key = .Enter})
	testing.expect_value(t, len(f.workspace.tabs), 1)
	testing.expect(t, f.workspace.tabs[0].marked && !w.pending_close.confirm.open)
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
	testing.expect(t, w.pending_close.confirm.open && f.workspace.tabs[2].marked)
	menu_key(&f, {key = .Escape})
	testing.expect(t, f.workspace.tabs[0].marked && f.workspace.tabs[1].marked && !f.workspace.tabs[2].marked)
	testing.expect_value(t, f.workspace.selected, 1)
	settings_tab := f.workspace.tabs[2]
	layout.destroy(&settings_tab.tree)
	testing.expect_value(t, layout.init(&settings_tab.tree, {.Settings, 0}), nil)
	testing.expect_value(t, ui.editor_add(&w.editor,
		{key = "tab.confirm_close", title = "Confirm Close", value = "true"}, "Tabs"), nil)
	ui.field_set(&w.editor.filter, "unrelated query")
	ui.editor_filter(&w.editor)
	app.tab_menu_open(&f.state, w, 1, 10, 20)
	menu_key(&f, {key = .End})
	menu_key(&f, {key = .Enter})
	testing.expect(t, app.settings_active(w) && !w.tab_menu.open)
	testing.expect_value(t, ui.field_string(&w.editor.filter), "")
	if row := ui.editor_row(&w.editor); testing.expect(t, row != nil) {
		testing.expect_value(t, row.key, "tab.confirm_close")
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
	device, device_error := render.device_create()
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
		testing.expect_value(t, app.tab_menu_draw(&f.state, w), glyphs.Result.Ok)
		y := app.tab_menu_row_rect(w, 0).y
		labels := [?]string{"Rename", "Duplicate", "", "Close to the Right",
			"Close Others", "Close", "", "Tab Settings"}
		for label, i in labels {
			row := app.tab_menu_row_rect(w, i)
			testing.expect_value(t, row.y, y)
			testing.expect_value(t, row.height, (label == "" ? 10 : 30)*scale)
			y += row.height
			testing.expect_value(t, app.tab_menu_hit(w, row.x+1, row.y+row.height/2), i)
			if label == "" {
				divider := w.list.rects[i == 2 ? 4 : 5]
				testing.expect_value(t, divider.rect, render.Rect{row.x+10*scale, row.y+4*scale, row.width-20*scale, scale})
				continue
			}
			testing.expect_value(t, ui.draw_text(&w.ui_text, &expected, label, row.x+10*scale,
				row.y+(row.height-w.ui_text.line_height)/2+w.ui_text.ascent,
				i == 3 || i == 4 ? f.state.theme.muted : f.state.theme.text,
				max(1, row.width-20*scale)), glyphs.Result.Ok)
		}
		testing.expect_value(t, len(w.list.glyphs), len(expected.glyphs))
		for glyph, i in w.list.glyphs { testing.expect_value(t, glyph, expected.glyphs[i]) }
		w.height = i32(120*scale)
		menu_key(&f, {key = .End})
		render.draw_list_reset(&w.list)
		testing.expect_value(t, app.tab_menu_draw(&f.state, w), glyphs.Result.Ok)
		r, rows := app.tab_menu_rect(w)
		testing.expect(t, w.tab_menu.scroll > 0 && w.tab_menu.scroll+rows > w.tab_menu.selected)
		testing.expect(t, r.y+r.height <= f32(w.height))
		menu_key(&f, {key = .Home})
		render.draw_list_reset(&w.list)
		testing.expect_value(t, app.tab_menu_draw(&f.state, w), glyphs.Result.Ok)
		testing.expect_value(t, w.tab_menu.scroll, 0)
	}
}
