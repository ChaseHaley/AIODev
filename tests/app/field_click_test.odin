package app_test

import app "../../src"
import "aio:ui"
import "core:testing"

@(test)
field_presses_count_double_and_triple_clicks_by_time_and_distance :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, "https://github.com/odin-lang")
	soon := app.DOUBLE_CLICK_NS / 2
	count :: proc(f: ^ui.Text_Field, x: f32, time_ns: i64, extend := false) -> int {
		return app.click_mark_press(&f.clicks, x, time_ns, extend)
	}
	testing.expect_value(t, count(&f, 100, 1_000), 1)
	testing.expect_value(t, count(&f, 102, 1_000 + soon), 2)
	testing.expect_value(t, count(&f, 102, 1_000 + 2 * soon), 3)
	testing.expect_value(t, count(&f, 102, 1_000 + 3 * soon), 1)
	// Too far apart, too late, or extending: a new run.
	testing.expect_value(t, count(&f, 150, 1_000 + 4 * soon), 1)
	testing.expect_value(t, count(&f, 150, 1_000 + 4 * soon + app.DOUBLE_CLICK_NS + 1), 1)
	testing.expect_value(t, count(&f, 150, 1_000 + 5 * soon + app.DOUBLE_CLICK_NS), 2)
	testing.expect_value(t, count(&f, 150, 1_000 + 6 * soon + app.DOUBLE_CLICK_NS, true), 1)
	testing.expect_value(t, count(&f, 150, 1_000 + 7 * soon + app.DOUBLE_CLICK_NS), 1)
	// An event without a time never repeats.
	testing.expect_value(t, count(&f, 150, 0), 1)
	testing.expect_value(t, count(&f, 150, 0), 1)
}

@(test)
field_press_selects_a_word_then_the_field_and_its_drag_grows_by_words :: proc(t: ^testing.T) {
	f: ui.Text_Field
	defer delete(f.bytes)
	ui.field_set(&f, "https://github.com/odin-lang")
	github := 8
	app.field_press(&f, github + 2, 50, false, 10)
	testing.expect_value(t, ui.field_selected_text(&f), "")
	app.field_press(&f, github + 2, 50, false, 20)
	testing.expect_value(t, ui.field_selected_text(&f), "github")
	ui.field_pointer(&f, len(ui.field_string(&f)), false, true)
	testing.expect_value(t, ui.field_selected_text(&f), "github.com/odin-lang")
	testing.expect(t, ui.field_release(&f))
	app.field_press(&f, github + 2, 50, false, 30)
	testing.expect_value(t, ui.field_selected_text(&f), ui.field_string(&f))
	// A Shift press keeps extending from the anchor and never starts a run.
	ui.field_release(&f)
	app.field_press(&f, 0, 50, false, 1_000_000_000)
	ui.field_release(&f)
	app.field_press(&f, github + 2, 80, true, 1_000_000_100)
	testing.expect_value(t, ui.field_selected_text(&f), "https://gi")
}
