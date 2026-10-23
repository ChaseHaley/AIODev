package app_test

import "core:testing"
import app "../../src"
import "aio:platform"

// The rim is centred on the live pointer, so a window showing one must take a frame from
// pointer movement even when no hover state changes.
@(test)
pointer_movement_repaints_a_visible_rim_without_changing_hover :: proc(t: ^testing.T) {
	state := app.App{}
	w := app.Window {
		id = 7,
		// Preparing keeps the gesture path out of this test; the pointer still moves.
		preparing = true,
		pointer = {10, 10},
	}
	defer delete(state.windows)
	if _, err := append(&state.windows, &w); err != nil {
		testing.expect_value(t, err, nil)
		return
	}
	app.handle_event(&state, platform.Mouse_Move_Event{window = w.id, x = 20, y = 10})
	testing.expect(t, !w.dirty, "a move with no rim and no hover change must not repaint")
	testing.expect_value(t, w.pointer, [2]f32{20, 10})

	w.gloss_hovered = true
	app.handle_event(&state, platform.Mouse_Move_Event{window = w.id, x = 30, y = 10})
	testing.expect(t, w.dirty, "a move while a rim is visible must repaint it")
	testing.expect_value(t, w.pointer, [2]f32{30, 10})

	w.dirty = false
	app.handle_event(&state, platform.Mouse_Move_Event{window = w.id, x = 30, y = 10})
	testing.expect(t, !w.dirty, "an unchanged pointer position must not repaint")
}
