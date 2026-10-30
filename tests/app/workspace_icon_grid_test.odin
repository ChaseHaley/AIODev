package app_test

import "core:testing"
import app "../../src"
import "aio:font"
import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"

@(test)
workspace_icon_grid_layout_fits_dpi_and_scrolls_only_presets :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75, 2}) {
		for width in ([?]i32{140, 244, 272, 600}) {
			for height in ([?]i32{240, 300, 800}) {
				w := app.Window{width = i32(f32(width)*scale), height = i32(f32(height)*scale), scale = scale}
				w.workspace_picker.mode = .Icons
				g := app.workspace_icon_picker_layout(&w)
				testing.expect(t, g.columns >= 2 && g.columns <= 5)
				testing.expect(t, g.panel.x+g.panel.width <= f32(w.width))
				testing.expect(t, g.panel.y+g.panel.height <= f32(w.height))
				testing.expect(t, g.grid.y+g.grid.height < g.divider.y)
				testing.expect(t, g.divider.y < g.field.y && g.field.y+g.field.height < g.apply.y)
				testing.expect(t, g.apply.y+g.apply.height <= g.panel.y+g.panel.height)
				for i in 0..<len(app.WORKSPACE_ICONS) {
					app.workspace_picker_select(&w, i)
					cell := app.workspace_picker_row_rect(&w, i)
					testing.expect_value(t, cell.width, 44*scale)
					testing.expect(t, cell.x >= g.grid.x && cell.x+cell.width <= g.grid.x+g.grid.width)
					testing.expect(t, cell.y >= g.grid.y && cell.y+cell.height <= g.grid.y+g.grid.height)
					testing.expect_value(t, app.workspace_picker_hit(&w, cell.x+22*scale, cell.y+22*scale), i)
					testing.expect_value(t, app.workspace_picker_hit(&w, cell.x+45*scale, cell.y+22*scale), -1)
				}
				testing.expect_value(t, app.workspace_picker_hit(&w, g.field.x+1, g.field.y+1), -1)
				testing.expect_value(t, app.workspace_picker_hit(&w, g.apply.x+1, g.apply.y+1), len(app.WORKSPACE_ICONS)+1)
				testing.expect_value(t, app.workspace_picker_hit(&w, g.divider.x+1, g.divider.y), -1)
				if w.workspace_picker.scroll > 0 {
					hidden := app.workspace_picker_row_rect(&w, 0)
					testing.expect_value(t, app.workspace_picker_hit(&w, hidden.x+22*scale, hidden.y+22*scale), -1)
				}
				if width >= 272 && height >= 300 {
					testing.expect_value(t, g.columns, 5)
					testing.expect_value(t, g.rows, 2)
					testing.expect_value(t, g.panel.height, 242*scale)
				}
			}
		}
	}
}

@(test)
workspace_icon_grid_keys_keep_grid_and_custom_editing_accessible :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 600, height = 300, scale = 1}
	w.workspace_picker.mode = .Icons
	defer delete(w.workspace_picker.query.bytes)
	key :: proc(state: ^app.App, w: ^app.Window, e: platform.Key_Event, selected: int, t: ^testing.T) {
		app.workspace_picker_key(state, w, e)
		testing.expect_value(t, w.workspace_picker.selected, selected)
	}
	n := len(app.WORKSPACE_ICONS)
	key(&state, &w, {key = .Arrow_Right, pressed = true}, 1, t)
	key(&state, &w, {key = .Arrow_Down, pressed = true}, 6, t)
	key(&state, &w, {key = .Arrow_Up, pressed = true}, 1, t)
	key(&state, &w, {key = .Arrow_Left, pressed = false}, 1, t)
	key(&state, &w, {key = .End, pressed = true}, n-1, t)
	key(&state, &w, {key = .Arrow_Down, pressed = true}, n, t)
	app.workspace_picker_text(&state, &w, "👩🏽‍💻")
	key(&state, &w, {key = .Arrow_Left, pressed = true}, n, t)
	testing.expect(t, w.workspace_picker.query.cursor < len(w.workspace_picker.query.bytes))
	key(&state, &w, {key = .Tab, pressed = true}, n+1, t)
	key(&state, &w, {key = .Arrow_Left, pressed = true}, n, t)
	key(&state, &w, {key = .Tab, pressed = true}, n+1, t)
	key(&state, &w, {key = .Tab, modifiers = {.Shift}, pressed = true}, n, t)
	key(&state, &w, {key = .Arrow_Down, pressed = true}, n+1, t)
	key(&state, &w, {key = .Arrow_Down, pressed = true}, n+2, t)
	key(&state, &w, {key = .Arrow_Down, pressed = true}, 0, t)
	key(&state, &w, {key = .P, modifiers = {.Control}, pressed = true}, n+2, t)
	key(&state, &w, {key = .N, modifiers = {.Control}, pressed = true}, 0, t)
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "👩🏽‍💻")
	key(&state, &w, {key = .Arrow_Up, pressed = true}, n+2, t)
	key(&state, &w, {key = .Arrow_Up, pressed = true}, n+1, t)
	key(&state, &w, {key = .Arrow_Up, pressed = true}, n, t)
	key(&state, &w, {key = .Arrow_Up, pressed = true}, n-1, t)
	w.width, w.height, w.workspace_picker.selected = 140, 240, 0
	key(&state, &w, {key = .End, pressed = true}, n-1, t)
	testing.expect(t, w.workspace_picker.scroll > 0)
	key(&state, &w, {key = .Home, pressed = true}, 0, t)
	testing.expect_value(t, w.workspace_picker.scroll, 0)
}

@(test)
workspace_icon_grid_pointer_apply_cancel_and_invalid_custom_preserve_identity :: proc(t: ^testing.T) {
	state: app.App
	workspace := app.Workspace{id = 7, name = "Workspace seven"}
	other := app.Workspace{id = 9, name = "Other"}
	w := app.Window{id = 1, workspace = &workspace, width = 600, height = 300, scale = 1}
	owner := app.Window{id = 2, workspace = &other}
	append(&state.workspaces, &workspace, &other)
	append(&state.windows, &w, &owner)
	defer delete(state.workspaces)
	defer delete(state.windows)
	defer delete(w.workspace_picker.rows)
	defer delete(w.workspace_picker.saved_query.bytes)
	defer delete(w.workspace_picker.query.bytes)
	defer delete(workspace.icon.emoji)
	ui.notices_init(&state.notices)
	defer ui.notices_destroy(&state.notices)
	app.workspace_icon_open(&state, &w)
	g := app.workspace_icon_picker_layout(&w)
	cell := app.workspace_picker_row_rect(&w, 7)
	app.handle_event(&state, platform.Mouse_Move_Event{window = w.id, x = i32(cell.x+22), y = i32(cell.y+22)})
	testing.expect_value(t, w.workspace_picker.selected, 7)
	testing.expect_value(t, workspace.icon.preset, 0)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = i32(cell.x+22), y = i32(cell.y+22)})
	testing.expect_value(t, workspace.icon.preset, 7)
	testing.expect(t, app.workspace_picker_active(&w.workspace_picker) && !app.workspace_picker_icons(&w.workspace_picker))
	app.workspace_icon_open(&state, &w)
	app.workspace_picker_click(&state, &w, g.field.x+5, g.field.y+5, false)
	testing.expect_value(t, w.workspace_picker.selected, len(app.WORKSPACE_ICONS))
	app.workspace_picker_text(&state, &w, "👩🏽‍💻")
	app.workspace_picker_key(&state, &w, {key = .Escape, pressed = true})
	testing.expect_value(t, workspace.icon.preset, 7)
	testing.expect_value(t, workspace.icon.emoji, "")
	app.workspace_icon_open(&state, &w)
	for invalid in ([?]string{"", "two words", "123456789012345678901234567890123"}) {
		ui.field_set(&w.workspace_picker.query, invalid)
		app.workspace_picker_click(&state, &w, g.apply.x+8, g.apply.y+8, false)
		testing.expect(t, app.workspace_picker_icons(&w.workspace_picker))
		testing.expect(t, len(state.notices.items) > 0)
		if len(state.notices.items) > 0 { testing.expect_value(t, state.notices.items[0].kind, ui.Notice_Kind.Error) }
		testing.expect_value(t, workspace.icon.preset, 7)
		testing.expect_value(t, workspace.icon.emoji, "")
	}
	ui.field_set(&w.workspace_picker.query, "🏳️‍🌈")
	app.workspace_picker_click(&state, &w, g.apply.x+8, g.apply.y+8, false)
	testing.expect_value(t, workspace.icon.emoji, "🏳️‍🌈")
	app.workspace_icon_open(&state, &w)
	testing.expect_value(t, w.workspace_picker.selected, len(app.WORKSPACE_ICONS))
	testing.expect_value(t, ui.field_selected_text(&w.workspace_picker.query), "🏳️‍🌈")
	app.workspace_picker_text(&state, &w, "1️⃣")
	app.workspace_picker_key(&state, &w, {key = .Enter, pressed = true})
	testing.expect_value(t, workspace.icon.emoji, "1️⃣")
	w.width, w.height = 140, 240
	app.workspace_icon_open(&state, &w)
	w.workspace_picker.selected = 0
	for i in 1..<5 {
		app.handle_event(&state, platform.Mouse_Wheel_Event{window = w.id, x = 30, y = 100, delta_y = -1})
		testing.expect_value(t, w.workspace_picker.selected, i)
	}
	testing.expect(t, w.workspace_picker.scroll > 0)
	g = app.workspace_icon_picker_layout(&w)
	app.workspace_picker_click(&state, &w, g.divider.x+1, g.divider.y, false)
	testing.expect(t, app.workspace_picker_icons(&w.workspace_picker))
	testing.expect_value(t, workspace.icon.emoji, "1️⃣")
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true, x = 1, y = 41})
	testing.expect(t, !app.workspace_picker_active(&w.workspace_picker))
	testing.expect_value(t, workspace.icon.emoji, "1️⃣")
	testing.expect(t, w.workspace == &workspace && owner.workspace == &other)
	testing.expect(t, app.window_for_workspace(&state, &workspace) == &w)
	testing.expect_value(t, workspace.id, u32(7))
	testing.expect_value(t, workspace.name, "Workspace seven")
	testing.expect_value(t, len(state.workspaces), 2)
	testing.expect_value(t, len(state.sessions), 0)
}

@(test)
workspace_icon_grid_offscreen_draw_retains_selection_and_theme_feedback :: proc(t: ^testing.T) {
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
	workspace := app.Workspace{id = 1, icon = {preset = 2}}
	w := app.Window{workspace = &workspace}
	w.workspace_picker.mode, w.workspace_picker.selected = .Icons, 7
	w.workspace_picker.target_id = workspace.id
	w.list = render.draw_list_init()
	defer render.draw_list_destroy(&w.list)
	defer delete(w.workspace_picker.query.bytes)
	if !testing.expect(t, ui.text_init(&w.ui_text, fonts, &cache, 14)) { return }
	for scale in ([?]f32{1, 1.5, 1.75, 2}) {
		w.scale, w.width, w.height = scale, i32(600*scale), i32(400*scale)
		ui.text_set_size(&w.ui_text, 14*scale)
		for id in ([?]string{"studio-dark", "studio-light"}) {
			state := app.App{theme = ui.theme_from(shipped_theme(id))}
			append(&state.workspaces, &workspace)
			defer delete(state.workspaces)
			render.draw_list_reset(&w.list)
			testing.expect_value(t, app.workspace_picker_draw(&state, &w), glyphs.Result.Ok)
			g := app.workspace_icon_picker_layout(&w)
			selected := app.workspace_icon_picker_cell(&w, g, 7)
			current := app.workspace_icon_picker_cell(&w, g, 2)
			mark := render.Rect{current.x+14*scale, current.y+38*scale, 16*scale, 2*scale}
			has_selection, has_current, has_divider := false, false, false
			for rect in w.list.rects {
				has_selection ||= rect.rect == selected && rect.color == state.theme.selection
				has_current ||= rect.rect == mark && rect.color == state.theme.accent
				has_divider ||= rect.rect == g.divider && rect.color == state.theme.border
			}
			testing.expect(t, has_selection && has_current && has_divider)
			testing.expect(t, len(w.list.glyphs) > 10)
			testing.expect_value(t, render.frame_render(device, surface, &w.list, state.theme.window), render.Error.None)
			pixels, pixel_error := render.surface_read_pixels(device, surface, context.allocator)
			if testing.expect_value(t, pixel_error, render.Error.None) {
				at := (int(mark.y+scale)*1200+int(mark.x+8*scale))*4
				for channel in 0..<3 {
					expected := int(state.theme.accent[2-channel]*255+0.5)
					testing.expect(t, abs(int(pixels[at+channel])-expected) <= 1)
				}
				delete(pixels)
			}
		}
	}
}
