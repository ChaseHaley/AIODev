package views_test

import "cosmos:render"
import "aio:views"
import "cosmos:platform"
import "core:testing"
import "core:fmt"
import "cosmos:ui"

// How many options the selected row's open dropdown shows.
@(private)
choice_count :: proc(p: ^views.Editor) -> int {
	return ui.dropdown_count(&p.dropdown, views.editor_dropdown_choices(p, views.editor_row(p)))
}

@(test)
long_choice_list_scroll_hit_testing_and_keyboard :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	choices: [40]string
	for &choice, i in choices {choice = fmt.tprintf("Font %02d", i)}
	testing.expect_value(t, views.editor_add(&p, {
		key = "font.family", title = "Shell Font", kind = .Choice, searchable = true,
		font_filter = true, choice_min_width = 360,
		value = choices[0], choices = choices[:],
	}, "Font"), nil)
	views.editor_filter(&p)
	testing.expect(t, views.editor_select_key(&p, "font.family"))
	l := page(&p)
	views.editor_key(&p, key({key = .Enter}))
	popup := views.editor_popup_rect(&p, l)
	testing.expect(t, popup.height <= 8*32+8+68)
	testing.expect(t, popup.y >= l.page.y && popup.y+popup.height <= l.page.y+l.page.height)
	views.editor_wheel(&p, l, popup.x+10, popup.y+10, -12)
	testing.expect_value(t, p.dropdown.list.scroll, 12)
	testing.expect(t, views.editor_hover(&p, l, popup.x+10, popup.y+68+4+32*1.5))
	testing.expect_value(t, p.dropdown.list.index, 13)
	testing.expect_value(t, views.editor_press(&p, l, nil, popup.x+10, popup.y+68+4+32*1.5, false), views.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "Font 13")
	views.editor_key(&p, key({key = .Enter}))
	for _ in 0..<26 {views.editor_key(&p, key({key = .Arrow_Down}))}
	popup = views.editor_popup_rect(&p, l)
	testing.expect_value(t, p.dropdown.list.index, 39)
	testing.expect_value(t, p.dropdown.list.scroll, 32)
	testing.expect_value(t, views.editor_key(&p, key({key = .Enter})), views.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "Font 39")
	views.editor_key(&p, key({key = .Enter}))
	views.editor_key(&p, key({key = .Escape}))
	testing.expect_value(t, ui.field_string(&p.value), "Font 39")
}

@(test)
font_search_filters_selects_and_cancels_without_editing_settings_search :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	choices := [?]string{"Cascadia Mono", "Consolas", "Cove Nerd Font", "Cove Nerd Font Mono", "Segoe UI"}
	for font_key in ([?]string{"font.family", "interface.font_family"}) {
		testing.expect_value(t, views.editor_add(&p, {
			key = font_key, title = "Font", kind = .Choice, searchable = true,
			font_filter = font_key == "font.family", choice_min_width = 360,
			value = "Consolas", choices = choices[:],
		}, "Fonts"), nil)
	}
	views.editor_filter(&p)
	for font_key in ([?]string{"font.family", "interface.font_family"}) {
		testing.expect(t, views.editor_select_key(&p, font_key))
		views.editor_key(&p, key({key = .Enter}))
		views.editor_text(&p, "nErD FoNt")
		testing.expect_value(t, choice_count(&p), 2)
		testing.expect_value(t, ui.field_string(&p.filter), "")
		testing.expect_value(t, ui.field_string(&p.value), "Consolas")
		views.editor_key(&p, key({key = .Arrow_Down}))
		testing.expect_value(t, views.editor_key(&p, key({key = .Enter})), views.Editor_Outcome.Save)
		testing.expect_value(t, ui.field_string(&p.value), "Cove Nerd Font Mono")
		views.editor_key(&p, key({key = .Enter}))
		testing.expect_value(t, ui.field_string(&p.dropdown.search), "")
		views.editor_text(&p, "missing font 12345")
		testing.expect_value(t, choice_count(&p), 0)
		testing.expect_value(t, views.editor_key(&p, key({key = .Enter})), views.Editor_Outcome.None)
		views.editor_key(&p, key({key = .End}))
		views.editor_key(&p, key({key = .Arrow_Down}))
		testing.expect_value(t, views.editor_popup(&p), views.Editor_Popup.Choice)
		views.editor_key(&p, key({key = .A, modifiers = {.Control}}))
		testing.expect_value(t, views.editor_selection(&p), "missing font 12345")
		views.editor_cut(&p)
		testing.expect_value(t, choice_count(&p), 5)
		views.editor_paste(&p, "Segoe\r\nignored")
		testing.expect_value(t, choice_count(&p), 1)
		views.editor_key(&p, key({key = .Backspace}))
		testing.expect_value(t, ui.field_string(&p.dropdown.search), "Sego")
		l := page(&p)
		popup := views.editor_popup_rect(&p, l)
		testing.expect_value(t, views.editor_pointer(&p, l, popup.x+14, popup.y+14), platform.Cursor_Shape.Text)
		header := font_key == "font.family" ? 68 : 36
		testing.expect_value(t, views.editor_press(&p, l, nil, popup.x+14, popup.y+f32(header)+19, false), views.Editor_Outcome.Save)
		testing.expect_value(t, ui.field_string(&p.value), "Segoe UI")
		views.editor_key(&p, key({key = .Enter}))
		views.editor_text(&p, "Cascadia")
		views.editor_key(&p, key({key = .Escape}))
		testing.expect_value(t, ui.field_string(&p.value), "Segoe UI")
	}
}

@(test)
font_search_accepts_translated_text_on_key_events :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	choices := [?]string{"Cascadia Mono", "Consolas"}
	for font_key in ([?]string{"font.family", "interface.font_family"}) {
		testing.expect_value(t, views.editor_add(&p, {
			key = font_key, title = "Font", kind = .Choice, searchable = true, value = "Consolas", choices = choices[:],
			font_filter = font_key == "font.family", choice_min_width = 360,
		}, "Fonts"), nil)
	}
	views.editor_filter(&p)
	for font_key in ([?]string{"font.family", "interface.font_family"}) {
		testing.expect(t, views.editor_select_key(&p, font_key))
		views.editor_key(&p, key({key = .Enter}))
		views.editor_key(&p, key({key = .A, text = "a"}))
		testing.expect_value(t, ui.field_string(&p.dropdown.search), "a")
		views.editor_key(&p, key({key = .B, text = "b"}))
		testing.expect_value(t, ui.field_string(&p.dropdown.search), "ab")
		views.editor_key(&p, key({key = .Space, text = " "}))
		testing.expect_value(t, ui.field_string(&p.dropdown.search), "ab ")
		views.editor_key(&p, key({key = .C, modifiers = {.Shift}, text = "C"}))
		testing.expect_value(t, ui.field_string(&p.dropdown.search), "ab C")
		testing.expect_value(t, ui.field_string(&p.filter), "")
		testing.expect_value(t, ui.field_string(&p.value), "Consolas")
		views.editor_key(&p, key({key = .Escape}))
	}
}

@(test)
font_popup_toggle_keeps_search_and_family_and_supports_pointer_and_keyboard :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	mono := [?]string{"Consolas", "Cove Nerd Font Mono"}
	testing.expect_value(t, views.editor_add(&p, {
		key = "font.family", title = "Shell Font", kind = .Choice, searchable = true, value = "Consolas",
		font_filter = true, choice_min_width = 360,
		choices = mono[:],
	}, "Fonts"), nil)
	views.editor_filter(&p)
	testing.expect(t, views.editor_select_key(&p, "font.family"))
	views.editor_key(&p, key({key = .Enter}))
	views.editor_text(&p, "Segoe")
	testing.expect_value(t, choice_count(&p), 0)
	views.editor_key(&p, key({key = .Tab}))
	testing.expect(t, views.editor_choice_toggle_focused(&p))
	testing.expect_value(t, views.editor_key(&p, key({key = .Space, text = " "})), views.Editor_Outcome.Font_Filter)
	testing.expect_value(t, views.editor_popup(&p), views.Editor_Popup.Choice)
	testing.expect_value(t, ui.field_string(&p.dropdown.search), "Segoe")
	testing.expect_value(t, ui.field_string(&p.value), "Consolas")
	// The page keeps its fonts until the owner saves the filter and publishes the other list.
	testing.expect_value(t, choice_count(&p), 0)
	testing.expect(t, !views.editor_row(&p).show_all_fonts)
	l := page(&p)
	popup := views.editor_popup_rect(&p, l)
	testing.expect_value(t, views.editor_pointer(&p, l, popup.x+14, popup.y+50), platform.Cursor_Shape.Hand)
	testing.expect_value(t, views.editor_press(&p, l, nil, popup.x+14, popup.y+50, false), views.Editor_Outcome.Font_Filter)
	testing.expect_value(t, choice_count(&p), 0)
	views.editor_key(&p, key({key = .Tab}))
	testing.expect(t, !views.editor_choice_toggle_focused(&p))
	views.editor_key(&p, key({key = .A, modifiers = {.Control}}))
	views.editor_key(&p, key({key = .Backspace}))
	testing.expect_value(t, choice_count(&p), 2)
	views.editor_key(&p, key({key = .Escape}))
	testing.expect_value(t, ui.field_string(&p.value), "Consolas")
}

@(test)
searchable_dropdown_shows_the_text_cursor_only_over_its_search_field :: proc(t: ^testing.T) {
	d: ui.Dropdown
	defer ui.dropdown_destroy(&d)
	choices := [?]string{"a.odin", "b.odin", "c.odin"}
	c := ui.Dropdown_Choices{choices = choices[:], labels = choices[:], searchable = true, min_width = 240}
	field := render.Rect{600, 40, 24, 24}
	a := ui.Dropdown_Anchor{field = field, row = field, bounds = render.Rect{0, 0, 900, 700}, align_end = true}
	ui.dropdown_open(&d, c)
	r := ui.dropdown_rect(&d, c, a, 1)
	testing.expect(t, r.height > 0)
	testing.expect_value(t, ui.dropdown_pointer(&d, c, a, r.x + 12, r.y + 14, 1), platform.Cursor_Shape.Text)
	// Above the list, beside the button that opened it, and to either side of the search field.
	testing.expect_value(t, ui.dropdown_pointer(&d, c, a, r.x + 12, r.y - 6, 1), platform.Cursor_Shape.Arrow)
	testing.expect_value(t, ui.dropdown_pointer(&d, c, a, field.x - 30, field.y + 4, 1), platform.Cursor_Shape.Arrow)
	testing.expect_value(t, ui.dropdown_pointer(&d, c, a, r.x - 20, r.y + 14, 1), platform.Cursor_Shape.Arrow)
	testing.expect_value(t, ui.dropdown_pointer(&d, c, a, r.x + r.width + 20, r.y + 14, 1), platform.Cursor_Shape.Arrow)
}
