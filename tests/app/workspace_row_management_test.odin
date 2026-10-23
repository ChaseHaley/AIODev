package app_test

import "base:runtime"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:font"
import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:ui"

@(private="file")
Workspace134_Fixture :: struct {
	state: app.App,
	w, owner: app.Window,
	tree: layout.Layout,
	current, target: ^app.Workspace,
}

@(private="file")
workspace134_init :: proc(t: ^testing.T, f: ^Workspace134_Fixture) -> bool {
	f.current, f.target = app.workspace_create_empty(&f.state), app.workspace_create_empty(&f.state)
	if !testing.expect(t, f.current != nil && f.target != nil) { return false }
	f.tree.root, f.tree.focus = layout.INVALID_NODE, layout.INVALID_NODE
	f.w = {id = 1, workspace = f.current, tree = &f.tree, width = 600, height = 400, scale = 1}
	f.owner = {id = 2, workspace = f.target, tree = &f.tree}
	append(&f.state.windows, &f.w, &f.owner)
	app.workspace_picker_open(&f.state, &f.w)
	return true
}

@(private="file")
workspace134_destroy :: proc(f: ^Workspace134_Fixture) {
	for workspace in f.state.workspaces { app.workspace_destroy(workspace) }
	delete(f.state.workspaces)
	delete(f.state.windows)
	delete(f.w.workspace_picker.rows)
	delete(f.w.workspace_picker.query.bytes)
	delete(f.w.workspace_picker.saved_query.bytes)
	delete(f.w.rename.bytes)
	delete(f.w.tab_controls)
	delete(f.w.tab_positions)
	delete(f.w.panes)
	delete(f.w.dividers)
	delete(f.w.close_confirm_workspace_name)
	delete(f.w.close_confirm_destination_name)
}

@(test)
workspace134_primary_actions_only_creation :: proc(t: ^testing.T) {
	testing.expect_value(t, len(app.WORKSPACE_ACTIONS), 2)
	if len(app.WORKSPACE_ACTIONS) == 2 {
		testing.expect_value(t, app.WORKSPACE_ACTIONS[0], app.Action.New_Workspace)
		testing.expect_value(t, app.WORKSPACE_ACTIONS[1], app.Action.New_Window)
	}
}

@(test)
workspace133_window_action_rechecks_requester_target_and_owner :: proc(t: ^testing.T) {
	f: Workspace134_Fixture
	defer workspace134_destroy(&f)
	if !workspace134_init(t, &f) {return}
	s, w := &f.state, &f.w
	ui.notices_init(&s.notices)
	defer ui.notices_destroy(&s.notices)
	testing.expect(t, !app.workspace_row_window_enabled(s, nil, f.target.id))
	testing.expect(t, !app.workspace_row_window_enabled(s, w, f.current.id))
	testing.expect(t, !app.workspace_open_window(s, w, f.current.id))
	testing.expect_value(t, len(s.windows), 2)
	testing.expect_value(t, app.workspace_row_window_title(s, f.target.id), "Show Existing Window")
	testing.expect(t, app.workspace_row_window_enabled(s, w, f.target.id))
	f.owner.preparing = true
	testing.expect(t, !app.workspace_open_window(s, w, f.target.id))
	f.owner.preparing = false
	w.preparing = true
	testing.expect(t, !app.workspace_open_window(s, w, f.target.id))
	w.preparing = false
	closed := app.Window{id = 99, workspace = f.current}
	testing.expect(t, !app.workspace_open_window(s, &closed, f.target.id))
	testing.expect(t, !app.workspace_open_window(s, w, max(u32)))
	testing.expect_value(t, len(s.notices.items), 0)
	app.workspace_row_menu_open(s, w, f.target.id)
	w.workspace = f.target
	w.workspace_picker.menu_selected = 2
	app.workspace_row_menu_choose(s, w)
	testing.expect_value(t, app.workspace_picker_target(&w.workspace_picker, .Menu), f.target.id)
	testing.expect(t, app.workspace_picker_active(&w.workspace_picker))
	testing.expect_value(t, len(s.windows), 2)
}

@(test)
workspace133_failed_open_preserves_filtered_row_and_runtime :: proc(t: ^testing.T) {
	f: Workspace134_Fixture
	defer workspace134_destroy(&f)
	if !workspace134_init(t, &f) {return}
	s, w := &f.state, &f.w
	ui.notices_init(&s.notices)
	defer ui.notices_destroy(&s.notices)
	ordered_remove(&s.windows, 1)
	ui.field_set(&w.workspace_picker.query, "Workspace 2")
	app.workspace_row_menu_open(s, w, f.target.id)
	testing.expect_value(t, app.workspace_row_window_title(s, f.target.id), "Open in New Window")
	testing.expect(t, app.workspace_row_window_enabled(s, w, f.target.id))
	w.workspace_picker.menu_selected = 2
	app.workspace_row_menu_choose(s, w)
	testing.expect_value(t, len(s.windows), 1)
	testing.expect_value(t, len(s.sessions), 0)
	testing.expect(t, w.workspace == f.current && app.workspace_picker_active(&w.workspace_picker))
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "Workspace 2")
	testing.expect_value(t, app.workspace_picker_target(&w.workspace_picker, .Menu), f.target.id)
	if testing.expect_value(t, len(s.notices.items), 1) {
		testing.expect_value(t, s.notices.items[0].kind, ui.Notice_Kind.Error)
	}
	if !testing.expect(t, app.workspace_discard_empty(s, f.target)) {return}
	f.target = nil
	app.workspace_row_menu_choose(s, w)
	testing.expect_value(t, len(s.windows), 1)
	testing.expect(t, w.workspace == f.current)
}

@(test)
workspace134_menu_targets_row_and_confirms_only_its_deletion :: proc(t: ^testing.T) {
	f: Workspace134_Fixture
	defer workspace134_destroy(&f)
	if !workspace134_init(t, &f) { return }
	s, w := &f.state, &f.w
	button := app.workspace_picker_menu_button_rect(w, 1)
	app.handle_event(s, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = i32(button.x+16), y = i32(button.y+16)})
	testing.expect_value(t, app.workspace_picker_target(&w.workspace_picker, .Menu), f.target.id)
	testing.expect(t, w.workspace == f.current && f.owner.workspace == f.target)
	app.workspace_picker_key(s, w, {key = .P, modifiers = {.Control}, pressed = true})
	testing.expect_value(t, w.workspace_picker.menu_selected, 3)
	app.workspace_picker_key(s, w, {key = .Enter, pressed = false})
	testing.expect(t, !w.close_confirm.open)
	app.workspace_picker_key(s, w, {key = .Enter, pressed = true})
	testing.expect(t, w.close_confirm.open && !app.workspace_picker_active(&w.workspace_picker))
	testing.expect_value(t, w.close_confirm_workspace, f.target.id)
	testing.expect_value(t, w.close_confirm_owner, f.owner.id)
	testing.expect(t, w.workspace == f.current && f.owner.workspace == f.target)
	app.handle_event(s, platform.Key_Event{window = w.id, key = .Escape, pressed = true})
	testing.expect(t, !w.close_confirm.open)
	testing.expect_value(t, len(s.workspaces), 2)
	testing.expect(t, w.workspace == f.current && f.owner.workspace == f.target)
	app.workspace_picker_open(s, w)
	app.workspace_row_menu_open(s, w, f.target.id)
	app.workspace_picker_key(s, w, {key = .Arrow_Left, pressed = true})
	testing.expect(t, app.workspace_picker_active(&w.workspace_picker) && app.workspace_picker_target(&w.workspace_picker, .Menu) == 0)
	testing.expect_value(t, w.workspace_picker.selected, 1)
	app.workspace_picker_key(s, w, {key = .F10, modifiers = {.Shift}, pressed = true})
	testing.expect_value(t, app.workspace_picker_target(&w.workspace_picker, .Menu), f.target.id)
	app.workspace_picker_click(s, w, 1, 1, false)
	testing.expect(t, app.workspace_picker_active(&w.workspace_picker) && app.workspace_picker_target(&w.workspace_picker, .Menu) == 0)
	app.workspace_picker_key(s, w, {key = .Arrow_Right, pressed = true})
	app.workspace_picker_key(s, w, {key = .Tab, modifiers = {.Shift}, pressed = true})
	testing.expect_value(t, w.workspace_picker.menu_selected, 3)
	app.workspace_picker_key(s, w, {key = .Escape, pressed = true})
	app.workspace_picker_key(s, w, {key = .N, modifiers = {.Control}, pressed = true})
	testing.expect_value(t, w.workspace_picker.selected, 2)
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "")
}

@(test)
workspace134_inline_rename_edits_target_cancel_invalid_and_failure :: proc(t: ^testing.T) {
	f: Workspace134_Fixture
	defer workspace134_destroy(&f)
	if !workspace134_init(t, &f) { return }
	s, w := &f.state, &f.w
	app.workspace_row_menu_open(s, w, f.target.id)
	app.workspace_row_menu_choose(s, w)
	testing.expect(t, !w.rename_open && app.workspace_picker_active(&w.workspace_picker))
	testing.expect_value(t, app.workspace_picker_target(&w.workspace_picker, .Rename), f.target.id)
	testing.expect_value(t, ui.field_selected_text(&w.rename), "Workspace 2")
	app.workspace_picker_text(s, w, "  Build tools  ")
	app.workspace_picker_key(s, w, {key = .Enter, pressed = true})
	testing.expect_value(t, f.target.name, "Build tools")
	testing.expect_value(t, f.current.name, "Workspace 1")
	testing.expect(t, w.workspace == f.current && f.owner.workspace == f.target)
	testing.expect_value(t, app.workspace_picker_target(&w.workspace_picker, .Rename), u32(0))
	app.workspace_row_rename_open(s, w, f.target.id)
	app.workspace_picker_text(s, w, "   ")
	app.workspace_picker_key(s, w, {key = .Enter, pressed = true})
	testing.expect(t, w.workspace_picker.rename_error && app.workspace_picker_target(&w.workspace_picker, .Rename) == f.target.id)
	testing.expect_value(t, f.target.name, "Build tools")
	ui.field_set(&w.rename, "Retry")
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	app.workspace_picker_key(s, w, {key = .Enter, pressed = true})
	context.allocator = allocator
	testing.expect(t, w.workspace_picker.rename_error && app.workspace_picker_target(&w.workspace_picker, .Rename) == f.target.id)
	testing.expect_value(t, f.target.name, "Build tools")
	app.workspace_picker_key(s, w, {key = .Escape, pressed = true})
	testing.expect(t, app.workspace_picker_active(&w.workspace_picker) && app.workspace_picker_target(&w.workspace_picker, .Rename) == 0)
	app.workspace_row_rename_open(s, w, f.target.id)
	app.workspace_picker_key(s, w, {key = .Arrow_Left, pressed = true})
	testing.expect_value(t, w.rename.cursor, 0)
	app.workspace_picker_text(s, w, "My ")
	app.workspace_picker_key(s, w, {key = .End, modifiers = {.Shift}, pressed = true})
	testing.expect_value(t, ui.field_selected_text(&w.rename), "Build tools")
	app.workspace_picker_key(s, w, {key = .Backspace, pressed = true})
	app.workspace_picker_text(s, w, "project")
	app.workspace_picker_key(s, w, {key = .Tab, pressed = true})
	testing.expect_value(t, f.target.name, "My project")
	testing.expect(t, app.workspace_picker_target(&w.workspace_picker, .Rename) == 0 && !w.rename_open)
	app.workspace_row_rename_open(s, w, f.target.id)
	app.workspace_picker_text(s, w, "Cancel outside")
	app.handle_event(s, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true, x = 599, y = 399})
	testing.expect(t, !app.workspace_picker_active(&w.workspace_picker) && app.workspace_picker_target(&w.workspace_picker, .Rename) == 0)
	testing.expect_value(t, f.target.name, "My project")
	app.workspace_rename_open(s, w)
	testing.expect_value(t, app.workspace_picker_target(&w.workspace_picker, .Rename), f.current.id)
	app.workspace_picker_text(s, w, "Cancel blur")
	app.handle_event(s, platform.Focus_Event{window = w.id, focused = false})
	testing.expect(t, !app.workspace_picker_active(&w.workspace_picker) && app.workspace_picker_target(&w.workspace_picker, .Rename) == 0)
	testing.expect_value(t, f.current.name, "Workspace 1")
}

@(test)
workspace134_icon_target_preserves_filter_unicode_owner_and_cancel :: proc(t: ^testing.T) {
	f: Workspace134_Fixture
	defer workspace134_destroy(&f)
	if !workspace134_init(t, &f) { return }
	s, w := &f.state, &f.w
	app.workspace_picker_text(s, w, "Workspace 2")
	app.workspace_row_menu_open(s, w, f.target.id)
	app.workspace_picker_key(s, w, {key = .N, modifiers = {.Control}, pressed = true})
	app.workspace_picker_key(s, w, {key = .Enter, pressed = true})
	testing.expect_value(t, app.workspace_picker_target(&w.workspace_picker, .Icons), f.target.id)
	w.workspace_picker.selected = 7
	app.workspace_picker_key(s, w, {key = .Enter, pressed = true})
	testing.expect_value(t, f.target.icon.preset, 7)
	testing.expect_value(t, f.current.icon.preset, 0)
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "Workspace 2")
	testing.expect_value(t, len(w.workspace_picker.rows), 1)
	testing.expect_value(t, w.workspace_picker.rows[w.workspace_picker.selected].id, f.target.id)
	app.workspace_row_icon_open(s, w, f.target.id)
	app.workspace_picker_text(s, w, "👩🏽‍💻")
	app.workspace_picker_key(s, w, {key = .Escape, pressed = true})
	testing.expect_value(t, f.target.icon.emoji, "")
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "Workspace 2")
	app.workspace_row_icon_open(s, w, f.target.id)
	app.workspace_picker_text(s, w, "👩🏽‍💻")
	app.handle_event(s, platform.Focus_Event{window = w.id, focused = false})
	testing.expect(t, app.workspace_picker_active(&w.workspace_picker) && app.workspace_picker_icons(&w.workspace_picker))
	app.workspace_picker_key(s, w, {key = .Enter, pressed = true})
	testing.expect_value(t, f.target.icon.emoji, "👩🏽‍💻")
	testing.expect_value(t, f.current.icon.emoji, "")
	testing.expect(t, w.workspace == f.current && f.owner.workspace == f.target)
	app.workspace_row_icon_open(s, w, f.target.id)
	ui.field_set(&w.workspace_picker.query, "🏳️‍🌈")
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	changed := app.workspace_icon_set(s, f.target, 0, "🏳️‍🌈")
	context.allocator = allocator
	testing.expect(t, !changed)
	testing.expect_value(t, f.target.icon.emoji, "👩🏽‍💻")
}

@(test)
workspace134_stale_and_disabled_targets_never_fall_back_to_current :: proc(t: ^testing.T) {
	f: Workspace134_Fixture
	defer workspace134_destroy(&f)
	if !workspace134_init(t, &f) { return }
	s, w := &f.state, &f.w
	app.workspace_row_menu_open(s, w, f.target.id)
	f.owner.preparing = true
	app.workspace_picker_key(s, w, {key = .Enter, pressed = true})
	testing.expect(t, app.workspace_picker_target(&w.workspace_picker, .Rename) == 0 && app.workspace_picker_target(&w.workspace_picker, .Menu) == 0)
	app.workspace_row_menu_open(s, w, f.target.id)
	testing.expect_value(t, app.workspace_picker_target(&w.workspace_picker, .Menu), u32(0))
	f.owner.preparing = false
	app.workspace_row_rename_open(s, w, f.target.id)
	app.workspace_picker_text(s, w, "Stale")
	f.owner.workspace = nil
	testing.expect(t, app.workspace_discard_empty(s, f.target))
	f.target = nil
	app.workspace_picker_key(s, w, {key = .Enter, pressed = true})
	testing.expect_value(t, f.current.name, "Workspace 1")
	testing.expect(t, app.workspace_picker_target(&w.workspace_picker, .Rename) == 0 && !w.rename_open)
	other := app.workspace_create_empty(s)
	if !testing.expect(t, other != nil) { return }
	app.workspace_row_icon_open(s, w, other.id)
	app.workspace_picker_text(s, w, "🌟")
	testing.expect(t, app.workspace_discard_empty(s, other))
	app.workspace_picker_key(s, w, {key = .Enter, pressed = true})
	testing.expect_value(t, f.current.icon.emoji, "")
	testing.expect(t, !app.workspace_picker_icons(&w.workspace_picker))
	other = app.workspace_create_empty(s)
	if !testing.expect(t, other != nil) { return }
	app.workspace_row_menu_open(s, w, other.id)
	w.workspace_picker.menu_selected = 3
	testing.expect(t, app.workspace_discard_empty(s, other))
	app.workspace_row_menu_choose(s, w)
	testing.expect(t, !w.close_confirm.open)
	testing.expect_value(t, len(s.workspaces), 1)
}

@(test)
workspace134_short_dpi_layout_animation_and_hit_targets :: proc(t: ^testing.T) {
	f: Workspace134_Fixture
	defer workspace134_destroy(&f)
	if !workspace134_init(t, &f) { return }
	s, w := &f.state, &f.w
	for _ in 0..<18 { workspace := app.workspace_create_empty(s); testing.expect(t, workspace != nil) }
	for scale in ([?]f32{1, 1.5, 1.75, 2}) {
		w.scale, w.width, w.height = scale, i32(280*scale), i32(240*scale)
		id := s.workspaces[len(s.workspaces)-1].id
		s.animations = false
		app.workspace_row_rename_open(s, w, id)
		testing.expect_value(t, w.workspace_picker.rename_motion.value, f32(1))
		panel, _ := app.workspace_picker_rect(w)
		row := app.workspace_picker_row_rect(w, w.workspace_picker.selected)
		field := app.workspace_row_rename_field_rect(w)
		testing.expect(t, row.y >= panel.y+app.workspace_picker_header(w))
		testing.expect(t, field.y >= row.y+row.height && field.y+field.height+24*scale <= panel.y+panel.height)
		testing.expect(t, panel.y+panel.height <= f32(w.height))
		testing.expect_value(t, app.workspace_picker_hit(w, field.x+1, field.y+1), -1)
		app.workspace_row_menu_open(s, w, id)
		button := app.workspace_picker_menu_button_rect(w, w.workspace_picker.selected)
		testing.expect_value(t, button.width, 32*scale)
		testing.expect_value(t, button.height, 32*scale)
		menu := app.workspace_row_menu_rect(w)
		testing.expect(t, menu.x >= 0 && menu.y >= 0 && menu.x+menu.width <= f32(w.width))
		testing.expect(t, menu.y+menu.height <= f32(w.height))
		for i in 0..<len(app.WORKSPACE_ROW_ACTIONS) {
			item := app.workspace_row_menu_item_rect(w, i)
			testing.expect_value(t, app.workspace_row_menu_hit(w, item.x+1, item.y+1), i)
		}
		s.animations = true
		app.workspace_row_rename_open(s, w, id)
		motion := &w.workspace_picker.rename_motion
		testing.expect_value(t, motion.value, f32(0))
		testing.expect(t, ui.motion_active(motion^))
		ui.motion_update(motion, time.tick_add(motion.started, 70*time.Millisecond))
		testing.expect(t, motion.value > 0 && motion.value < 1)
		ui.motion_update(motion, time.tick_add(motion.started, 140*time.Millisecond))
		testing.expect_value(t, motion.value, f32(1))
		app.workspace_row_rename_finish(s, w, false)
		indicator := app.workspace_button_indicator_rect(w)
		testing.expect_value(t, indicator.width, 28*scale)
		testing.expect(t, indicator.x+indicator.width <= app.workspace_button_width(w))
	}
}

@(test)
workspace134_header_name_never_paints_into_indicator :: proc(t: ^testing.T) {
	f: Workspace134_Fixture
	defer workspace134_destroy(&f)
	if !workspace134_init(t, &f) { return }
	fonts, font_error := font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	device, device_error := render.device_create()
	if !testing.expect_value(t, device_error, render.Error.None) { return }
	defer render.device_destroy(device)
	surface, surface_error := render.surface_create_offscreen(device, 512, 96)
	if !testing.expect_value(t, surface_error, render.Error.None) { return }
	defer render.surface_destroy(surface)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	s, w := &f.state, &f.w
	w.list = render.draw_list_init()
	defer render.draw_list_destroy(&w.list)
	if !testing.expect(t, ui.text_init(&w.ui_text, fonts, &cache, 14)) { return }
	name := f.current.name
	defer f.current.name = name
	for scale in ([?]f32{1, 1.5, 2}) {
		w.scale = scale
		ui.text_set_size(&w.ui_text, 14*scale)
		for mode in settings.Theme_Mode {
			s.theme = ui.theme_from(settings.theme_resolve({.Studio, mode}))
			for width in ([?]i32{360, 460, 600, 900}) {
				w.width = i32(f32(width)*scale)
				f.current.name = ""
				render.draw_list_reset(&w.list)
				testing.expect_value(t, app.workspace_button_draw(s, w), glyphs.Result.Ok)
				testing.expect_value(t, render.frame_render(device, surface, &w.list, s.theme.window), render.Error.None)
				baseline, error := render.surface_read_pixels(device, surface, context.allocator)
				if !testing.expect_value(t, error, render.Error.None) { return }
				defer delete(baseline)
				f.current.name = "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW"
				render.draw_list_reset(&w.list)
				testing.expect_value(t, app.workspace_button_draw(s, w), glyphs.Result.Ok)
				testing.expect_value(t, render.frame_render(device, surface, &w.list, s.theme.window), render.Error.None)
				pixels, pixel_error := render.surface_read_pixels(device, surface, context.allocator)
				if !testing.expect_value(t, pixel_error, render.Error.None) { return }
				defer delete(pixels)
				indicator := app.workspace_button_indicator_rect(w)
				clear := true
				for y in int(indicator.y)..<int(indicator.y+indicator.height) {
					for x in int(indicator.x-4*scale)..<int(indicator.x+indicator.width) {
						at := (y*512+x)*4
						for channel in 0..<4 { clear &&= pixels[at+channel] == baseline[at+channel] }
					}
				}
				testing.expect(t, clear, "workspace label must leave the indicator and its gap unchanged")
			}
		}
	}
}

@(test)
workspace134_offscreen_menu_inline_field_and_drawn_indicator :: proc(t: ^testing.T) {
	f: Workspace134_Fixture
	defer workspace134_destroy(&f)
	if !workspace134_init(t, &f) { return }
	fonts, font_error := font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	device, device_error := render.device_create()
	if !testing.expect_value(t, device_error, render.Error.None) { return }
	defer render.device_destroy(device)
	surface, surface_error := render.surface_create_offscreen(device, 1200, 800)
	if !testing.expect_value(t, surface_error, render.Error.None) { return }
	defer render.surface_destroy(surface)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	s, w := &f.state, &f.w
	w.list = render.draw_list_init()
	defer render.draw_list_destroy(&w.list)
	if !testing.expect(t, ui.text_init(&w.ui_text, fonts, &cache, 14)) { return }
	for scale in ([?]f32{1, 1.5, 1.75, 2}) {
		w.scale, w.width, w.height = scale, i32(600*scale), i32(400*scale)
		ui.text_set_size(&w.ui_text, 14*scale)
		for mode in settings.Theme_Mode {
			s.theme = ui.theme_from(settings.theme_resolve({.Studio, mode}))
			for rename in ([?]bool{false, true}) {
				render.draw_list_reset(&w.list)
				app.workspace_row_menu_open(s, w, f.target.id)
				if rename { app.workspace_row_menu_choose(s, w) }
				testing.expect_value(t, app.workspace_button_draw(s, w), glyphs.Result.Ok)
				testing.expect_value(t, len(w.list.rects), 13)
				testing.expect_value(t, app.workspace_picker_draw(s, w), glyphs.Result.Ok)
				sample := rename ? app.workspace_row_rename_field_rect(w) : app.workspace_row_menu_item_rect(w, 0)
				testing.expect_value(t, render.frame_render(device, surface, &w.list, s.theme.window), render.Error.None)
				pixels, pixel_error := render.surface_read_pixels(device, surface, context.allocator)
				if testing.expect_value(t, pixel_error, render.Error.None) {
					color := rename ? s.theme.pane : s.theme.selection
					at := (int(sample.y+sample.height/2)*1200+int(sample.x+sample.width-10*scale))*4
					for channel in 0..<3 {
						expected := color[2-channel]*color.a+s.theme.surface[2-channel]*(1-color.a)
						testing.expect(t, abs(int(pixels[at+channel])-int(expected*255+0.5)) <= 1)
					}
					delete(pixels)
				}
				testing.expect(t, !w.rename_open && w.workspace == f.current)
				if rename {
					app.handle_event(s, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
						x = i32(sample.x+8*scale), y = i32(sample.y+16*scale)})
					testing.expect_value(t, w.rename.cursor, 0)
					app.workspace_picker_pointer(s, w, sample.x+sample.width-8*scale, false, true)
					testing.expect_value(t, ui.field_selected_text(&w.rename), f.target.name)
					app.handle_event(s, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = false,
						x = i32(sample.x+sample.width-8*scale), y = i32(sample.y+16*scale)})
					testing.expect(t, !w.rename.dragging)
				}
			}
		}
	}
}
