package ui_test

import "core:testing"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:ui"
import fixtures "../fixtures"

@(test)
tab_bar_caps_widths_and_hit_tests_tabs_actions_and_empty_space :: proc(t: ^testing.T) {
	bar := ui.tab_bar_layout(500, 1, 3)
	testing.expect_value(t, bar.count, 3)
	testing.expect_value(t, bar.height, ui.TITLE_BAR_HEIGHT)
	testing.expect(t, bar.tab_width > 0 && bar.tab_width <= 220)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, bar.x+2, 20), 0)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, bar.x+bar.tab_width+2, 20), 1)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, bar.x+2, bar.height), -1)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, 1, 20), 0)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, -1, 20), -1)

	new_tab := bar.x + f32(bar.count)*bar.tab_width + 2
	testing.expect_value(t, ui.tab_bar_hit_test(bar, new_tab, 20), bar.count)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, new_tab+bar.button_width, 20), -1)

	close := ui.tab_close_rect(bar, 1, 1)
	testing.expect_value(t, close.width, f32(22))
	testing.expect_value(t, ui.tab_close_hit(bar, close.x+close.width/2, close.y+close.height/2, 1), 1)

	drop := ui.tab_drop_region(bar, 900, 1)
	testing.expect(t, ui.tab_drop_hit(bar, 900, 1, drop.x+2, 20))
	testing.expect(t, !ui.tab_drop_hit(bar, 900, 1, 2, 20))
}

@(test)
tab_bar_with_no_tabs_has_no_hit_surface :: proc(t: ^testing.T) {
	bar := ui.tab_bar_layout(500, 1, 0)
	testing.expect_value(t, bar.count, 0)
	testing.expect_value(t, bar.tab_width, f32(0))
	testing.expect_value(t, ui.tab_bar_hit_test(bar, 40, 20), -1)
}

// The program icon stays at the left and status sits just before Close; a tab too narrow for both
// keeps the status.
@(test)
tab_draw_keeps_the_program_icon_left_and_status_before_close :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	device, device_error := render.device_create()
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 14)) {return}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	resolved, ok := fixtures.shipped_theme_file(fixtures.SHIPPED_THEMES[0])
	if !testing.expect(t, ok) {return}
	theme := ui.theme_from(resolved)
	done := ui.Status_Mark{glyph = .Done, progress = -1}
	for scale in ([?]f32{1, 1.5, 2}) {
		ui.text_set_size(&text, 14 * scale)
		for width, i in ([?]f32{200, 80}) {
			bar := ui.tab_bar_layout(width * 2 * scale + 32 * scale, scale, 2)
			render.draw_list_reset(&list)
			testing.expect_value(t, ui.tab_draw(&list, &text, theme, bar, 1, "Title", false, scale,
				icon_atlas = {0, 0, 14 * scale, 14 * scale}, status = done, status_slot = true), glyphs.Result.Ok)
			left := bar.x + bar.tab_width
			close := ui.tab_close_rect(bar, 1, scale)
			icon_found, status_found := false, false
			for g in list.glyphs {
				if g.flags & render.GLYPH_COLOR == 0 {continue}
				icon_found = true
				testing.expect(t, g.rect.x >= left + 8 * scale && g.rect.x + g.rect.width <= left + 26 * scale)
			}
			for r in list.rects {
				if r.color != ui.status_color(theme, .Done) || r.rect.width != 14 * scale {continue}
				status_found = true
				testing.expect(t, r.rect.x >= left + bar.tab_width - 46 * scale && r.rect.x + r.rect.width <= close.x + 4 * scale)
			}
			testing.expect_value(t, icon_found, i == 0)
			testing.expect(t, status_found)
			// Without a status to show, a narrow tab keeps its icon.
			render.draw_list_reset(&list)
			testing.expect_value(t, ui.tab_draw(&list, &text, theme, bar, 1, "Title", false, scale,
				icon_atlas = {0, 0, 14 * scale, 14 * scale}, status_slot = true), glyphs.Result.Ok)
			icon_found = false
			for g in list.glyphs {icon_found ||= g.flags & render.GLYPH_COLOR != 0}
			testing.expect(t, icon_found)
		}
	}
}
