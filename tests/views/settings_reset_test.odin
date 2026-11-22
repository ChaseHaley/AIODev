package views_test

import "aio:views"
import "core:testing"

@(test)
settings_reset_all_button_is_available_with_no_matching_rows :: proc(t: ^testing.T) {
	for width in ([?]f32{360, 800, 1400}) {
		p: views.Editor
		defer views.editor_destroy(&p)
		l := views.editor_layout({0, 0, width, 700}, 1)
		r := views.editor_reset_all_rect(l)
		testing.expect(t, r.x >= 0 && r.x + r.width <= width)
		testing.expect_value(t, views.editor_press(&p, l, nil, r.x + 4, r.y + 4, false), views.Editor_Outcome.Reset_All)
	}
}

@(test)
settings_reset_all_button_accepts_keyboard_focus_without_rows :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	testing.expect_value(t, views.editor_key(&p, {key = .Tab, pressed = true, modifiers = {.Shift}}), views.Editor_Outcome.Changed)
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Reset_All)
	testing.expect_value(t, views.editor_key(&p, {key = .Enter, pressed = true}), views.Editor_Outcome.Reset_All)
	testing.expect_value(t, views.editor_key(&p, {key = .Tab, pressed = true}), views.Editor_Outcome.Changed)
	testing.expect_value(t, views.editor_focus(&p), views.Editor_Focus.Search)
}
