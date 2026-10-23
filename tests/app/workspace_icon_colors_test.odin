package app_test

import "core:testing"
import app "../../src"
import "aio:render"
import "aio:settings"
import "aio:term_view"
import "aio:ui"

@(test)
workspace143_tint_validation_reset_and_icon_changes_preserve_identity :: proc(t: ^testing.T) {
	state: app.App
	workspace := app.Workspace{id = 7, name = "Original"}
	stale := app.Workspace{id = 7}
	append(&state.workspaces, &workspace)
	defer delete(state.workspaces)
	defer delete(workspace.icon.emoji)
	testing.expect(t, !app.workspace_icon_color_set(&state, nil, 1))
	testing.expect(t, !app.workspace_icon_color_set(&state, &stale, 1))
	for tint in ([?]int{-1, len(app.WORKSPACE_ICON_COLORS)}) {
		testing.expect(t, !app.workspace_icon_color_set(&state, &workspace, tint))
		testing.expect_value(t, workspace.icon.tint, 0)
	}
	for tint in 0..<len(app.WORKSPACE_ICON_COLORS) {
		testing.expect(t, app.workspace_icon_color_set(&state, &workspace, tint))
		testing.expect(t, app.workspace_icon_set(&state, &workspace, 2, "🌈"))
		testing.expect_value(t, workspace.icon.tint, tint)
		testing.expect_value(t, workspace.icon.emoji, "🌈")
		testing.expect(t, app.workspace_icon_set(&state, &workspace, 3, ""))
		testing.expect_value(t, workspace.icon.tint, tint)
	}
	testing.expect(t, app.workspace_icon_color_set(&state, &workspace, 0))
	testing.expect_value(t, workspace.icon.tint, 0)
	testing.expect_value(t, workspace.id, u32(7))
	testing.expect_value(t, workspace.name, "Original")
	testing.expect_value(t, len(state.sessions), 0)
}

@(test)
workspace143_colors_have_contrast_in_all_builtin_themes_and_selection_states :: proc(t: ^testing.T) {
	for name in settings.Theme_Name {
		for mode in settings.Theme_Mode {
			theme := ui.theme_from(settings.theme_resolve({name, mode}))
			testing.expect_value(t, app.workspace_icon_tint(0, theme.text), theme.text)
			testing.expect_value(t, app.workspace_icon_tint(-1, theme.text), theme.text)
			for tint in 1..<len(app.WORKSPACE_ICON_COLORS) {
				color := app.workspace_icon_tint(tint, theme.text)
				for base in ([?]render.Color{theme.pane, theme.surface}) {
					testing.expect(t, term_view.contrast_ratio(color, base) >= 3)
					selected := base
					for i in 0..<3 { selected[i] = theme.selection[i]*theme.selection.a+base[i]*(1-theme.selection.a) }
					testing.expect(t, term_view.contrast_ratio(color, selected) >= 3)
				}
			}
		}
	}
	transparent := render.Color{1, 1, 1, 0.5}
	testing.expect_value(t, app.workspace_icon_tint(6, transparent).a, f32(0.5))
}

@(test)
workspace143_targeted_pointer_keyboard_cancel_and_saved_filter :: proc(t: ^testing.T) {
	state: app.App
	current := app.Workspace{id = 1, name = "Current"}
	target := app.Workspace{id = 2, name = "Target"}
	w := app.Window{id = 1, workspace = &current, width = 600, height = 300, scale = 1}
	append(&state.workspaces, &current, &target)
	append(&state.windows, &w)
	defer delete(state.workspaces)
	defer delete(state.windows)
	defer delete(w.workspace_picker.rows)
	defer delete(w.workspace_picker.query.bytes)
	defer delete(w.workspace_picker.saved_query.bytes)
	defer delete(target.icon.emoji)
	app.workspace_picker_open(&state, &w)
	app.workspace_picker_text(&state, &w, "Target")
	app.workspace_row_icon_open(&state, &w, target.id)
	button := app.workspace_icon_color_button(&w)
	app.workspace_picker_click(&state, &w, button.x+button.width/2, button.y+button.height/2, false)
	testing.expect(t, (w.workspace_picker.mode == .Tint))
	testing.expect_value(t, app.workspace_picker_count(&w), len(app.WORKSPACE_ICON_COLORS)+1)
	app.workspace_picker_key(&state, &w, {key = .Arrow_Down, pressed = true})
	testing.expect_value(t, w.workspace_picker.selected, 5)
	app.workspace_picker_key(&state, &w, {key = .Arrow_Up, pressed = true})
	testing.expect_value(t, w.workspace_picker.selected, 0)
	app.workspace_picker_key(&state, &w, {key = .Arrow_Right, pressed = true})
	app.workspace_picker_text(&state, &w, "ignored")
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "")
	app.workspace_picker_key(&state, &w, {key = .Escape, pressed = true})
	testing.expect(t, !(w.workspace_picker.mode == .Tint) && app.workspace_picker_icons(&w.workspace_picker))
	testing.expect_value(t, target.icon.tint, 0)
	testing.expect_value(t, w.workspace_picker.selected, len(app.WORKSPACE_ICONS)+2)
	app.workspace_picker_key(&state, &w, {key = .Enter, pressed = true})
	app.workspace_picker_key(&state, &w, {key = .End, pressed = true})
	app.workspace_picker_key(&state, &w, {key = .Enter, pressed = true})
	testing.expect_value(t, target.icon.tint, len(app.WORKSPACE_ICON_COLORS)-1)
	testing.expect_value(t, current.icon.tint, 0)
	testing.expect(t, !app.workspace_picker_icons(&w.workspace_picker) && !(w.workspace_picker.mode == .Tint))
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "Target")
	testing.expect(t, w.workspace == &current)
	app.workspace_row_icon_open(&state, &w, target.id)
	app.workspace_icon_color_open(&state, &w)
	app.workspace_picker_key(&state, &w, {key = .Home, pressed = true})
	cell := app.workspace_picker_row_rect(&w, 0)
	app.workspace_picker_click(&state, &w, cell.x+cell.width/2, cell.y+cell.height/2, false)
	testing.expect_value(t, target.icon.tint, 0)
	app.workspace_row_icon_open(&state, &w, target.id)
	app.workspace_icon_color_open(&state, &w)
	app.workspace_picker_open(&state, &w)
	testing.expect(t, !(w.workspace_picker.mode == .Tint) && !app.workspace_picker_icons(&w.workspace_picker))
}

@(test)
workspace143_stale_color_target_never_changes_current_workspace :: proc(t: ^testing.T) {
	state: app.App
	defer {
		for workspace in state.workspaces { app.workspace_destroy(workspace) }
		delete(state.workspaces)
		delete(state.windows)
	}
	current := app.workspace_create_empty(&state)
	target := app.workspace_create_empty(&state)
	if !testing.expect(t, current != nil && target != nil) { return }
	w := app.Window{id = 1, workspace = current, width = 600, height = 300, scale = 1}
	append(&state.windows, &w)
	defer delete(w.workspace_picker.rows)
	defer delete(w.workspace_picker.query.bytes)
	defer delete(w.workspace_picker.saved_query.bytes)
	app.workspace_picker_open(&state, &w)
	app.workspace_row_icon_open(&state, &w, target.id)
	app.workspace_icon_color_open(&state, &w)
	w.workspace_picker.selected = 6
	testing.expect(t, app.workspace_discard_empty(&state, target))
	app.workspace_picker_key(&state, &w, {key = .Enter, pressed = true})
	testing.expect_value(t, current.icon.tint, 0)
	testing.expect(t, !(w.workspace_picker.mode == .Tint) && !app.workspace_picker_icons(&w.workspace_picker))
	testing.expect(t, w.workspace == current)
}

@(test)
workspace143_short_color_grid_keeps_all_choices_and_back_reachable :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75, 2}) {
		for width in ([?]i32{140, 244, 272, 600}) {
			for height in ([?]i32{240, 300, 800}) {
				w := app.Window{width = i32(f32(width)*scale), height = i32(f32(height)*scale), scale = scale}
				w.workspace_picker.mode = .Tint
				g := app.workspace_icon_picker_layout(&w)
				testing.expect(t, g.panel.x+g.panel.width <= f32(w.width))
				testing.expect(t, g.apply.y+g.apply.height <= g.panel.y+g.panel.height)
				testing.expect_value(t, app.workspace_picker_field_rect(&w).width, f32(0))
				for i in 0..<len(app.WORKSPACE_ICON_COLORS) {
					app.workspace_picker_select(&w, i)
					cell := app.workspace_picker_row_rect(&w, i)
					testing.expect(t, cell.y >= g.grid.y && cell.y+cell.height <= g.grid.y+g.grid.height)
					testing.expect_value(t, app.workspace_picker_hit(&w, cell.x+cell.width/2, cell.y+cell.height/2), i)
				}
				testing.expect_value(t, app.workspace_picker_hit(&w, g.apply.x+1, g.apply.y+1), len(app.WORKSPACE_ICON_COLORS))
			}
		}
	}
}
