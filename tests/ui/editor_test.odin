package ui_test

import "core:testing"
import "aio:ui"

@(test)
editor_filters_edits_cancels_and_keeps_utf8_boundaries :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	testing.expect_value(t, ui.editor_add(&p, {"font.family", "Font family", "Typeface", "Mono", "Mono"}), nil)
	testing.expect_value(t, ui.editor_add(&p, {"cursor.blink", "Blink", "Cursor animation", "false", "false"}), nil)
	p.open = true
	ui.editor_filter(&p)
	testing.expect_value(t, len(p.matches), 2)
	ui.editor_text(&p, "CURSOR")
	testing.expect_value(t, len(p.matches), 1)
	testing.expect_value(t, ui.editor_row(&p).key, "cursor.blink")
	testing.expect_value(t, ui.editor_key(&p, key({key = .Tab})), ui.Editor_Outcome.Changed)
	ui.editor_key(&p, key({key = .A, modifiers = {.Control}}))
	ui.editor_text(&p, "aé🙂z")
	ui.editor_key(&p, key({key = .Arrow_Left}))
	ui.editor_key(&p, key({key = .Backspace}))
	testing.expect_value(t, string(p.value.bytes[:]), "aéz")
	ui.editor_key(&p, key({key = .Home}))
	ui.editor_key(&p, key({key = .Delete}))
	testing.expect_value(t, string(p.value.bytes[:]), "éz")
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.editor_row(&p).value, "false")
	testing.expect_value(t, ui.editor_key(&p, key({key = .Escape})), ui.Editor_Outcome.Closed)
	testing.expect(t, !p.open)
}

@(test)
editor_layout_hit_targets_scale :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.75, 2}) {
		l := ui.editor_layout(1200*scale, 900*scale, scale)
		testing.expect(t, l.rows > 0)
		testing.expect(t, l.value.y > l.list.y+l.list.height)
		testing.expect(t, l.close.x+l.close.width < l.panel.x+l.panel.width)
		p: ui.Editor
		defer ui.editor_destroy(&p)
		testing.expect_value(t, ui.editor_add(&p, {"x", "X", "", "", ""}), nil)
		ui.editor_filter(&p)
		testing.expect_value(t, ui.editor_click(&p, l, l.save.x+1, l.save.y+1), ui.Editor_Outcome.Save)
		testing.expect_value(t, ui.editor_click(&p, l, l.reset.x+1, l.reset.y+1), ui.Editor_Outcome.Reset)
		testing.expect_value(t, ui.editor_click(&p, l, l.close.x+1, l.close.y+1), ui.Editor_Outcome.Closed)
	}
}
