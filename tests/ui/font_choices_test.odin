package ui_test

import "aio:ui"
import "core:testing"
import "core:fmt"

@(test)
long_choice_list_scroll_hit_testing_and_keyboard :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	choices: [40]string
	for &choice, i in choices {choice = fmt.tprintf("Font %02d", i)}
	testing.expect_value(t, ui.editor_add(&p, {
		key = "font.family", title = "Shell Font", kind = .Choice,
		value = choices[0], choices = choices[:],
	}, "Font"), nil)
	p.open = true
	ui.editor_filter(&p)
	testing.expect(t, ui.editor_select_key(&p, "font.family"))
	l := page(&p)
	ui.editor_key(&p, key({key = .Enter}))
	popup := ui.editor_popup_rect(&p, l)
	testing.expect(t, popup.height <= 8*30+8)
	testing.expect(t, popup.y >= l.page.y && popup.y+popup.height <= l.page.y+l.page.height)
	ui.editor_wheel(&p, l, popup.x+10, popup.y+10, -12)
	testing.expect_value(t, p.popup_scroll, 12)
	testing.expect(t, ui.editor_hover(&p, l, popup.x+10, popup.y+4+30*1.5))
	testing.expect_value(t, p.popup_index, 13)
	testing.expect_value(t, ui.editor_press(&p, l, nil, popup.x+10, popup.y+4+30*1.5, false), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "Font 13")
	ui.editor_key(&p, key({key = .Enter}))
	for _ in 0..<26 {ui.editor_key(&p, key({key = .Arrow_Down}))}
	popup = ui.editor_popup_rect(&p, l)
	testing.expect_value(t, p.popup_index, 39)
	testing.expect_value(t, p.popup_scroll, 32)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "Font 39")
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_key(&p, key({key = .Escape}))
	testing.expect_value(t, ui.field_string(&p.value), "Font 39")
}
