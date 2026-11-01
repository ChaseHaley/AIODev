package ui_test

import "aio:ui"
import "aio:platform"
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
	testing.expect(t, popup.height <= 8*30+8+66)
	testing.expect(t, popup.y >= l.page.y && popup.y+popup.height <= l.page.y+l.page.height)
	ui.editor_wheel(&p, l, popup.x+10, popup.y+10, -12)
	testing.expect_value(t, p.popup_scroll, 12)
	testing.expect(t, ui.editor_hover(&p, l, popup.x+10, popup.y+66+4+30*1.5))
	testing.expect_value(t, p.popup_index, 13)
	testing.expect_value(t, ui.editor_press(&p, l, nil, popup.x+10, popup.y+66+4+30*1.5, false), ui.Editor_Outcome.Save)
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

@(test)
font_search_filters_selects_and_cancels_without_editing_settings_search :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	choices := [?]string{"Cascadia Mono", "Consolas", "Cove Nerd Font", "Cove Nerd Font Mono", "Segoe UI"}
	for font_key in ([?]string{"font.family", "interface.font_family"}) {
		testing.expect_value(t, ui.editor_add(&p, {
			key = font_key, title = "Font", kind = .Choice,
			value = "Consolas", choices = choices[:],
		}, "Fonts"), nil)
	}
	p.open = true
	ui.editor_filter(&p)
	for font_key in ([?]string{"font.family", "interface.font_family"}) {
		testing.expect(t, ui.editor_select_key(&p, font_key))
		ui.editor_key(&p, key({key = .Enter}))
		ui.editor_text(&p, "nErD FoNt")
		testing.expect_value(t, ui.editor_choice_count(&p, ui.editor_row(&p)), 2)
		testing.expect_value(t, ui.field_string(&p.filter), "")
		testing.expect_value(t, ui.field_string(&p.value), "Consolas")
		ui.editor_key(&p, key({key = .Arrow_Down}))
		testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
		testing.expect_value(t, ui.field_string(&p.value), "Cove Nerd Font Mono")
		ui.editor_key(&p, key({key = .Enter}))
		testing.expect_value(t, ui.field_string(&p.choice_search), "")
		ui.editor_text(&p, "missing font 12345")
		testing.expect_value(t, ui.editor_choice_count(&p, ui.editor_row(&p)), 0)
		testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.None)
		ui.editor_key(&p, key({key = .End}))
		ui.editor_key(&p, key({key = .Arrow_Down}))
		testing.expect_value(t, p.popup, ui.Editor_Popup.Choice)
		ui.editor_key(&p, key({key = .A, modifiers = {.Control}}))
		testing.expect_value(t, ui.editor_selection(&p), "missing font 12345")
		ui.editor_cut(&p)
		testing.expect_value(t, ui.editor_choice_count(&p, ui.editor_row(&p)), 5)
		ui.editor_paste(&p, "Segoe\r\nignored")
		testing.expect_value(t, ui.editor_choice_count(&p, ui.editor_row(&p)), 1)
		ui.editor_key(&p, key({key = .Backspace}))
		testing.expect_value(t, ui.field_string(&p.choice_search), "Sego")
		l := page(&p)
		popup := ui.editor_popup_rect(&p, l)
		testing.expect_value(t, ui.editor_pointer(&p, l, popup.x+14, popup.y+14), platform.Cursor_Shape.Text)
		header := font_key == "font.family" ? 66 : 36
		testing.expect_value(t, ui.editor_press(&p, l, nil, popup.x+14, popup.y+f32(header)+19, false), ui.Editor_Outcome.Save)
		testing.expect_value(t, ui.field_string(&p.value), "Segoe UI")
		ui.editor_key(&p, key({key = .Enter}))
		ui.editor_text(&p, "Cascadia")
		ui.editor_key(&p, key({key = .Escape}))
		testing.expect_value(t, ui.field_string(&p.value), "Segoe UI")
	}
}

@(test)
font_search_accepts_translated_text_on_key_events :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	choices := [?]string{"Cascadia Mono", "Consolas"}
	for font_key in ([?]string{"font.family", "interface.font_family"}) {
		testing.expect_value(t, ui.editor_add(&p, {
			key = font_key, title = "Font", kind = .Choice, value = "Consolas", choices = choices[:],
		}, "Fonts"), nil)
	}
	p.open = true
	ui.editor_filter(&p)
	for font_key in ([?]string{"font.family", "interface.font_family"}) {
		testing.expect(t, ui.editor_select_key(&p, font_key))
		ui.editor_key(&p, key({key = .Enter}))
		ui.editor_key(&p, key({key = .A, text = "a"}))
		testing.expect_value(t, ui.field_string(&p.choice_search), "a")
		ui.editor_key(&p, key({key = .B, text = "b"}))
		testing.expect_value(t, ui.field_string(&p.choice_search), "ab")
		ui.editor_key(&p, key({key = .Space, text = " "}))
		testing.expect_value(t, ui.field_string(&p.choice_search), "ab ")
		ui.editor_key(&p, key({key = .C, modifiers = {.Shift}, text = "C"}))
		testing.expect_value(t, ui.field_string(&p.choice_search), "ab C")
		testing.expect_value(t, ui.field_string(&p.filter), "")
		testing.expect_value(t, ui.field_string(&p.value), "Consolas")
		ui.editor_key(&p, key({key = .Escape}))
	}
}

@(test)
font_popup_toggle_keeps_search_and_family_and_supports_pointer_and_keyboard :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	mono := [?]string{"Consolas", "Cove Nerd Font Mono"}
	all := [?]string{"Consolas", "Cove Nerd Font", "Cove Nerd Font Mono", "Segoe UI"}
	testing.expect_value(t, ui.editor_add(&p, {
		key = "font.family", title = "Shell Font", kind = .Choice, value = "Consolas",
		choices = mono[:], other_font_choices = all[:],
	}, "Fonts"), nil)
	p.open = true
	ui.editor_filter(&p)
	testing.expect(t, ui.editor_select_key(&p, "font.family"))
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_text(&p, "Segoe")
	testing.expect_value(t, ui.editor_choice_count(&p, ui.editor_row(&p)), 0)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect(t, p.choice_toggle_focus)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Space, text = " "})), ui.Editor_Outcome.Font_Filter)
	testing.expect_value(t, p.popup, ui.Editor_Popup.Choice)
	testing.expect_value(t, ui.field_string(&p.choice_search), "Segoe")
	testing.expect_value(t, ui.field_string(&p.value), "Consolas")
	testing.expect_value(t, ui.editor_choice_count(&p, ui.editor_row(&p)), 1)
	testing.expect(t, ui.editor_row(&p).show_all_fonts)
	l := page(&p)
	popup := ui.editor_popup_rect(&p, l)
	testing.expect_value(t, ui.editor_pointer(&p, l, popup.x+14, popup.y+50), platform.Cursor_Shape.Hand)
	testing.expect_value(t, ui.editor_press(&p, l, nil, popup.x+14, popup.y+50, false), ui.Editor_Outcome.Font_Filter)
	testing.expect_value(t, ui.editor_choice_count(&p, ui.editor_row(&p)), 0)
	testing.expect(t, !ui.editor_row(&p).show_all_fonts)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect(t, !p.choice_toggle_focus)
	ui.editor_key(&p, key({key = .A, modifiers = {.Control}}))
	ui.editor_key(&p, key({key = .Backspace}))
	testing.expect_value(t, ui.editor_choice_count(&p, ui.editor_row(&p)), 2)
	ui.editor_key(&p, key({key = .Escape}))
	testing.expect_value(t, ui.field_string(&p.value), "Consolas")
}
