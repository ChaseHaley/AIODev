package app_test

import "base:runtime"
import "core:testing"
import "core:unicode/utf8"
import app "../../src"
import "aio:platform"
import "aio:ui"

@(test)
workspace_dropdown_geometry_keeps_anchor_divider_and_rows_at_dpi :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75, 2}) {
		for width in ([?]f32{260, 600, 1600}) {
			w := app.Window{width = i32(width*scale), height = i32(800*scale), scale = scale}
			defer delete(w.workspace_picker.rows)
			append(&w.workspace_picker.rows, app.Workspace_Row{1, ""}, app.Workspace_Row{2, ""})
			r, visible := app.workspace_picker_rect(&w)
			testing.expect_value(t, r.x, 5*scale)
			testing.expect_value(t, r.y, ui.TAB_HEIGHT*scale)
			testing.expect(t, r.x+r.width <= f32(w.width) && r.y+r.height <= f32(w.height))
			testing.expect_value(t, visible, 2+len(app.WORKSPACE_ACTIONS))
			for i in 0..<visible {
				row := app.workspace_picker_row_rect(&w, i)
				testing.expect_value(t, app.workspace_picker_hit(&w, row.x+1, row.y+1), i)
			}
			last := app.workspace_picker_row_rect(&w, 1)
			testing.expect_value(t, app.workspace_picker_hit(&w, last.x+1, last.y+last.height+3*scale), -1)
			testing.expect_value(t, app.workspace_picker_hit(&w, r.x-1, r.y+100*scale), -1)
			w.workspace_picker.mode = .Icons
			r, _ = app.workspace_picker_rect(&w)
			testing.expect(t, r.x+r.width <= f32(w.width) && r.y+r.height <= f32(w.height))
			w.height = i32(300*scale)
			r, visible = app.workspace_picker_rect(&w)
			testing.expect(t, visible >= 1 && visible < len(app.WORKSPACE_ICONS))
			testing.expect(t, r.y+r.height <= f32(w.height))
		}
	}
}

@(test)
workspace_icons_preserve_whole_unicode_sequences_transactionally :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.workspaces)
	workspace := app.workspace_create_empty(&state)
	if !testing.expect(t, workspace != nil) { return }
	defer testing.expect(t, app.workspace_discard_empty(&state, workspace))
	for emoji in ([?]string{"👩🏽‍💻", "🏳️‍🌈", "🇺🇦", "1️⃣", "👨‍👩‍👧‍👦", "✈️"}) {
		testing.expect(t, app.workspace_icon_set(&state, workspace, 0, emoji))
		testing.expect_value(t, workspace.icon.emoji, emoji)
		w := app.Window{workspace = workspace}
		w.workspace_picker.mode = .Icons
		defer delete(w.workspace_picker.query.bytes)
		for r in emoji {
			// Windows delivers WM_CHAR-derived text one Unicode scalar at a time.
			buffer, n := utf8.encode_rune(r)
			app.workspace_picker_text(&state, &w, string(buffer[:n]))
		}
		testing.expect_value(t, ui.field_string(&w.workspace_picker.query), emoji)
		testing.expect_value(t, w.workspace_picker.selected, len(app.WORKSPACE_ICONS))
	}
	prior := workspace.icon.emoji
	for invalid in ([?]string{"x y", "\n", "\xff", "123456789012345678901234567890123"}) {
		testing.expect(t, !app.workspace_icon_set(&state, workspace, 0, invalid))
		testing.expect_value(t, workspace.icon.emoji, prior)
	}
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	failed := app.workspace_icon_set(&state, workspace, 0, "🌟")
	context.allocator = allocator
	testing.expect(t, !failed)
	testing.expect_value(t, workspace.icon.emoji, prior)
	testing.expect(t, app.workspace_icon_set(&state, workspace, 3, ""))
	testing.expect_value(t, workspace.icon.emoji, "")
	testing.expect_value(t, workspace.icon.preset, 3)
}

@(test)
workspace_navigation_wraps_actions_and_consumes_closing_key_release :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{id = 1}
	append(&state.windows, &w)
	defer delete(state.windows)
	defer delete(w.workspace_picker.rows)
	defer delete(w.workspace_picker.query.bytes)
	w.workspace_picker.mode = .List
	append(&w.workspace_picker.rows, app.Workspace_Row{1, ""})
	count := app.workspace_picker_count(&w)
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .P, modifiers = {.Control}, pressed = true})
	testing.expect_value(t, w.workspace_picker.selected, count-1)
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .N, modifiers = {.Control}, pressed = true})
	testing.expect_value(t, w.workspace_picker.selected, 0)
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Y, unshifted = 'p',
		modifiers = {.Control}, pressed = true})
	testing.expect_value(t, w.workspace_picker.selected, count-1)
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "")
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Escape, pressed = true})
	testing.expect(t, !app.workspace_picker_active(&w.workspace_picker))
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Escape, pressed = false})
	testing.expect(t, w.suppressed_key == nil)
	w.tab_menu.open, w.tab_menu.count = true, 3
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .P, modifiers = {.Control}, pressed = true})
	testing.expect_value(t, w.tab_menu.selected, 2)
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .N, modifiers = {.Control}, pressed = true})
	testing.expect_value(t, w.tab_menu.selected, 0)
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Enter, pressed = false})
	testing.expect(t, w.tab_menu.open)
}

@(test)
workspace_index_excludes_provisional_and_preparing_workspaces :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.workspaces)
	defer delete(state.windows)
	for i in 0..<4 {
		workspace := app.workspace_create_empty(&state)
		if !testing.expect(t, workspace != nil) { return }
		workspace.provisional = i == 1
	}
	defer { for workspace in state.workspaces { app.workspace_destroy(workspace) } }
	preparing := app.Window{workspace = state.workspaces[2], preparing = true}
	append(&state.windows, &preparing)
	testing.expect(t, app.workspace_index(&state, 0) == state.workspaces[0])
	testing.expect(t, app.workspace_index(&state, 1) == state.workspaces[3])
	testing.expect(t, app.workspace_index(&state, -1) == nil && app.workspace_index(&state, 2) == nil)
}
