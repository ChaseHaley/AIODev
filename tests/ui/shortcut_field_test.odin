package ui_test

import "aio:commands"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:ui"
import "core:testing"
import fixtures "../fixtures"

@(test)
shortcut_summary_keeps_only_the_first_label_and_the_additional_count :: proc(t: ^testing.T) {
	for test in ([?]struct {value, first: string, additional: int} {
		{"", "", 0}, {"none", "", 0}, {"Ctrl+K", "Ctrl+K", 0},
		{"Ctrl+K, Ctrl+Shift+K", "Ctrl+K", 1},
		{" Ctrl+K , Ctrl+Shift+K, Alt+K ", "Ctrl+K", 2},
		{"Ctrl+K, , Alt+K", "Ctrl+K", 1},
	}) {
		summary := ui.shortcut_summary(test.value)
		testing.expect_value(t, summary.first, test.first)
		testing.expect_value(t, summary.additional, test.additional)
	}
}

@(test)
shortcut_field_font_and_width_stay_constant_when_palette_edit_opens :: proc(t: ^testing.T) {
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
	p: ui.Palette
	r := binding_palette(t, &p)
	defer commands.destroy(&r)
	defer ui.palette_destroy(&p)
	testing.expect_value(t, commands.set_shortcuts(&r, 1, {{.K, {.Control}}}), commands.Error.None)
	theme := ui.theme_from(fixtures.shipped_theme("studio-dark"))
	for scale in ([?]f32{1, 1.5, 2}) {
		ui.text_set_size(&text, 14 * scale)
		l := ui.palette_layout(&p, 1000 * scale, 800 * scale, scale)
		row := render.Rect{l.list.x, l.list.y, l.list.width, l.row_height}
		render.draw_list_reset(&list)
		_ = render.push_layer(&list, l.viewport)
		testing.expect_value(t, ui.palette_binding_draw(&p, &r.items[0], 0, row, &list, &text, theme, l, {}),
		                     render.Build_Status.Ok)
		if !testing.expect(t, len(list.glyphs) > 0) {return}
		idle := list.glyphs[0].rect
		parts := ui.palette_binding_parts(row, scale)
		testing.expect(t, parts.field.width <= 176 * scale)
		render.draw_list_reset(&list)
		_ = render.push_layer(&list, l.viewport)
		input := ui.text_styled(&text, .Body)
		testing.expect_value(t, ui.draw_text(&input, &list, "Ctrl+K", parts.field.x + ui.CONTROL_INSET * scale,
		                     parts.field.y + (parts.field.height - input.line_height) / 2 + input.ascent,
		                     theme.text), render.Build_Status.Ok)
		if testing.expect(t, len(list.glyphs) > 0) {testing.expect_value(t, list.glyphs[0].rect, idle)}
		ui.palette_key(&p, &r, press(.Enter, {.Control}))
		render.draw_list_reset(&list)
		_ = render.push_layer(&list, l.viewport)
		testing.expect_value(t, ui.palette_binding_draw(&p, &r.items[0], 0, row, &list, &text, theme, l, {}),
		                     render.Build_Status.Ok)
		if testing.expect(t, len(list.glyphs) > 0) {
			testing.expect_value(t, list.glyphs[0].rect, idle)
		}
		ui.palette_key(&p, &r, press(.Escape))

		// Compare the actual glyphs with the requested compact label, then with Settings.
		testing.expect_value(t, commands.set_shortcuts(&r, 1, {{.K, {.Control}}, {.K, {.Alt}}}), commands.Error.None)
		render.draw_list_reset(&list)
		_ = render.push_layer(&list, l.viewport)
		testing.expect_value(t, ui.draw_text(&input, &list, "Ctrl+K, +1", parts.field.x + ui.CONTROL_INSET * scale,
		                     parts.field.y + (parts.field.height - input.line_height) / 2 + input.ascent,
		                     theme.text), render.Build_Status.Ok)
		expected := make([]render.Glyph_Instance, len(list.glyphs), context.temp_allocator)
		copy(expected, list.glyphs[:])
		for editing in ([?]bool{false, true}) {
			if editing {ui.palette_key(&p, &r, press(.Enter, {.Control}))}
			render.draw_list_reset(&list)
			_ = render.push_layer(&list, l.viewport)
			testing.expect_value(t, ui.palette_binding_draw(&p, &r.items[0], 0, row, &list, &text, theme, l, {}),
			                     render.Build_Status.Ok)
			testing.expect_value(t, len(list.glyphs), len(expected))
			for glyph, i in list.glyphs {
				if i < len(expected) {testing.expect_value(t, glyph.atlas, expected[i].atlas)}
			}
			if editing {
				if b := binding_editor(&p); testing.expect(t, b != nil) {
					testing.expect_value(t, ui.editor_row(b).value, "Ctrl+K, Alt+K")
				}
				ui.palette_key(&p, &r, press(.Escape))
			}
		}
		e: ui.Editor
		defer ui.editor_destroy(&e)
		testing.expect_value(t, ui.editor_add(&e, {key = "keys.test.alpha", title = "Alpha", kind = .Shortcut,
		                                        value = "Ctrl+K, Alt+K"}, "Shortcuts"), nil)
		ui.editor_filter(&e)
		page := ui.editor_layout({0, 0, 1000 * scale, 800 * scale}, scale)
		e.visible_rows = page.rows
		for selected in ([?]bool{false, true}) {
			if selected {ui.editor_select_key(&e, "keys.test.alpha")} else {e.selected = 0}
			e.scroll = 0
			field := ui.editor_row_parts(&e, page, 1).field
			testing.expect_value(t, field.width, parts.field.width)
			render.draw_list_reset(&list)
			testing.expect_value(t, ui.editor_draw(&e, page, &list, &text, theme, true), render.Build_Status.Ok)
			count := 0
			for glyph in list.glyphs {
				center := [2]f32{glyph.rect.x + glyph.rect.width / 2, glyph.rect.y + glyph.rect.height / 2}
				if center.x < field.x || center.x >= field.x + field.width ||
				   center.y < field.y || center.y >= field.y + field.height {continue}
				if count < len(expected) {testing.expect_value(t, glyph.atlas, expected[count].atlas)}
				count += 1
			}
			testing.expect_value(t, count, len(expected))
		}
		testing.expect_value(t, e.rows[0].value, "Ctrl+K, Alt+K")
		testing.expect_value(t, commands.set_shortcuts(&r, 1, {{.K, {.Control}}}), commands.Error.None)
	}
}
