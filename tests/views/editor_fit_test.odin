package views_test

import "aio:views"
import "core:fmt"
import "core:testing"
import "cosmos:ui"

@(test)
editor_fit_pages_and_clamps_scroll_before_any_draw :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	for i in 0 ..< 30 {
		testing.expect_value(t, views.editor_add(&p, {
			key = fmt.tprintf("row.%d", i), title = "Row", kind = .Toggle, value = "false",
		}, "Group"), nil)
	}
	views.editor_filter(&p)
	for height in ([?]f32{450, 700, 240}) {
		l := views.editor_layout({0, 0, 1000, height}, 1)
		views.editor_fit(&p, l)
		views.editor_select_key(&p, "row.0")
		first := p.selected
		views.editor_key(&p, key({key = .Page_Down}))
		testing.expect_value(t, p.selected, first + l.rows)
		testing.expect(t, p.selected >= p.scroll && p.selected < p.scroll + l.rows)
		p.scroll = 1000
		views.editor_fit(&p, l)
		testing.expect_value(t, p.scroll, len(p.items) - l.rows)
	}
}

@(test)
editor_fit_profiles_uses_current_row_geometry_without_drawing :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	profile_editor_fixture(t, &p)
	l := views.editor_layout({500, 40, 300, 700}, 1)
	views.editor_fit(&p, l)
	views.editor_select_key(&p, "profile.beta")
	views.editor_key(&p, key({key = .Context_Menu}))
	_, open := p.mode.(views.Editor_Profile_Menu)
	testing.expect(t, open)
	testing.expect_value(t, p.profile_menu.bounds, l.page)
	views.editor_key(&p, key({key = .Escape}))
	views.editor_key(&p, key({key = .Arrow_Left}))
	testing.expect_value(t, p.profile_control, views.Profile_Control.Expand)
	views.editor_key(&p, key({key = .Arrow_Left}))
	testing.expect_value(t, p.profile_control, views.Profile_Control.More)
	views.editor_key(&p, key({key = .Enter}))
	_, open = p.mode.(views.Editor_Profile_Menu)
	testing.expect(t, open)
	views.editor_key(&p, key({key = .Escape}))
	wide := views.editor_layout({0, 40, 1200, 1400}, 1)
	views.editor_fit(&p, wide)
	p.profile_control = .Expand
	views.editor_key(&p, key({key = .Arrow_Right}))
	testing.expect_value(t, p.profile_control, views.Profile_Control.Radio)
}

@(test)
editor_fit_updates_outline_without_drawing :: proc(t: ^testing.T) {
	p: views.Editor
	defer views.editor_destroy(&p)
	for i in 0 ..< 20 {
		testing.expect_value(t, views.editor_add(&p, {
			key = fmt.tprintf("row.%d", i), title = "Row", kind = .Toggle, value = "false",
		}, fmt.tprintf("Group %d", i)), nil)
	}
	views.editor_filter(&p)
	l := views.editor_layout({0, 0, 1000, 240}, 1)
	views.editor_fit(&p, l)
	views.editor_jump(&p, 19)
	views.editor_fit(&p, l)
	testing.expect_value(t, p.outline_active, 19)
	testing.expect(t, p.outline_scroll > 0)
}

@(test)
editor_short_dropdown_keyboard_keeps_highlight_in_real_visible_rows :: proc(t: ^testing.T) {
	@(static, rodata)
	choices := [?]string{"F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"}
	for shortcuts in ([?]bool{false, true}) {
		p: views.Editor
		defer views.editor_destroy(&p)
		testing.expect_value(t, views.editor_add(&p, {
			key = "test", title = "Test", kind = shortcuts ? .Shortcut : .Choice,
			value = shortcuts ? "F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12" : "F1",
			choices = choices[:],
		}, "Test"), nil)
		views.editor_filter(&p)
		l := views.editor_layout({0, 0, 400, 160}, 1)
		views.editor_fit(&p, l)
		views.editor_key(&p, key({key = .Enter}))
		visible := ui.choice_list_rows(shortcuts ? 13 : 12, l.page.height, l.scale)
		testing.expect(t, visible < ui.CHOICE_LIST_ROWS)
		for _ in 0 ..< 10 {
			views.editor_key(&p, key({key = .Arrow_Down}))
			list := shortcuts ? p.capture.alternatives : p.dropdown.list
			testing.expect(t, list.index >= list.scroll && list.index < list.scroll + visible)
		}
	}
}
