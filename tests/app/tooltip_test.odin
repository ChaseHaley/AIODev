package app_test

import app "../../src"
import "core:testing"
import "core:time"

@(test)
tooltip_waits_for_its_hover_deadline :: proc(t: ^testing.T) {
	w := app.Window{tooltip = "Split right"}
	w.tooltip_deadline = time.tick_add(time.tick_now(), 700 * time.Millisecond)
	app.tooltip_tick(&w)
	testing.expect(t, !w.tooltip_visible)
	testing.expect(t, w.tooltip_deadline != {})

	w.tooltip_deadline = time.tick_add(time.tick_now(), -time.Millisecond)
	app.tooltip_tick(&w)
	testing.expect(t, w.tooltip_visible)
	testing.expect(t, w.tooltip_deadline == {})
}
