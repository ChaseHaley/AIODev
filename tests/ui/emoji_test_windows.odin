package ui_test

import "core:testing"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:ui"

@(test)
emoji_icon_shapes_variation_zwj_flags_and_skin_tones_as_color_glyphs :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) { return }
	defer font.system_destroy(fonts)
	device, device_error := render.device_create()
	if !testing.expect_value(t, device_error, render.Error.None) { return }
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 14)) { return }
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	for emoji in ([?]string{"👩🏽‍💻", "🏳️‍🌈", "1️⃣", "👨‍👩‍👧‍👦", "✈️"}) {
		render.draw_list_reset(&list)
		testing.expect_value(t, render.push_layer(&list, {0, 0, 32, 32}), render.Error.None)
		testing.expect_value(t, ui.draw_cluster_centered(&text, &list, emoji, {0, 0, 32, 32},
			{1, 1, 1, 1}, 20), glyphs.Result.Ok)
		if emoji != "👨‍👩‍👧‍👦" { testing.expect_value(t, len(list.glyphs), 1) }
		// Segoe UI Emoji may show a family as separate figures; preserve them all and fit the slot.
		if !testing.expect(t, len(list.glyphs) > 0 && len(list.glyphs) <= 64) { continue }
		before: [64]render.Glyph_Instance
		count := len(list.glyphs)
		copy(before[:], list.glyphs[:])
		for g in list.glyphs {
			testing.expect_value(t, g.flags, render.GLYPH_COLOR)
			testing.expect(t, g.rect.width > 0 && g.rect.x >= -1 && g.rect.x+g.rect.width <= 33)
		}
		render.draw_list_reset(&list)
		testing.expect_value(t, render.push_layer(&list, {0, 0, 32, 32}), render.Error.None)
		testing.expect_value(t, ui.draw_cluster_centered(&text, &list, emoji, {0, 0, 32, 32},
			{1, 1, 1, 1}, 20), glyphs.Result.Ok)
		testing.expect_value(t, len(list.glyphs), count)
		for g, i in list.glyphs { testing.expect_value(t, g, before[i]) }
	}
}
