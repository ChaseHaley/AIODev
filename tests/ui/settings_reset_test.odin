package ui_test

import "aio:ui"
import "core:testing"

@(test)
settings_reset_all_button_is_available_with_no_matching_rows :: proc(t: ^testing.T) {
	for width in ([?]f32{360, 800, 1400}) {
		p: ui.Editor
		defer ui.editor_destroy(&p)
		l := ui.editor_layout({0, 0, width, 700}, 1)
		r := ui.editor_reset_all_rect(l)
		testing.expect(t, r.x >= 0 && r.x + r.width <= width)
		testing.expect_value(t, ui.editor_press(&p, l, nil, r.x + 4, r.y + 4, false), ui.Editor_Outcome.Reset_All)
	}
}

@(test)
settings_reset_all_button_accepts_keyboard_focus_without_rows :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	testing.expect_value(t, ui.editor_key(&p, {key = .Tab, pressed = true, modifiers = {.Shift}}), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.focus, ui.Editor_Focus.Reset_All)
	testing.expect_value(t, ui.editor_key(&p, {key = .Enter, pressed = true}), ui.Editor_Outcome.Reset_All)
	testing.expect_value(t, ui.editor_key(&p, {key = .Tab, pressed = true}), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.focus, ui.Editor_Focus.Search)
}
