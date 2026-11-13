package app_test

import "core:testing"
import app "../../src"
import "aio:layout"

@(private = "file")
pane_session :: proc(w: ^app.Window, node: layout.Node_Id) -> u32 {
	content, _ := layout.pane_content(app.window_tree(w), node)
	return content.id
}

// Status and focus jumps show a tiled pane uncovered and leave the floats beside a floating one alone.
@(test)
showing_a_pane_minimizes_the_floats_that_would_cover_it :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "session-show-floats", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	tree := app.window_tree(w)
	tiled := w.panes[0].node
	app.floating_new(s, w)
	app.floating_new(s, w)
	if !testing.expect_value(t, len(w.panes), 3) {return}
	first, second := w.panes[1].node, w.panes[2].node
	testing.expect_value(t, tree.focus, second)

	// The tiled pane takes focus with every float minimized above it.
	if !testing.expect(t, app.session_show(s, w, pane_session(w, tiled))) {return}
	testing.expect_value(t, tree.focus, tiled)
	shown, minimized := layout.float_counts(tree)
	testing.expect_value(t, shown, 0)
	testing.expect_value(t, minimized, 2)

	// A floating pane comes back alone; the other float stays in its capsule.
	if !testing.expect(t, app.session_show(s, w, pane_session(w, first))) {return}
	testing.expect_value(t, tree.focus, first)
	shown, minimized = layout.float_counts(tree)
	testing.expect_value(t, shown, 1)
	testing.expect_value(t, minimized, 1)

	// With both floats shown, showing one keeps the other shown.
	app.pane_focus(s, w, second)
	if !testing.expect(t, app.session_show(s, w, pane_session(w, first))) {return}
	testing.expect_value(t, tree.focus, first)
	shown, minimized = layout.float_counts(tree)
	testing.expect_value(t, shown, 2)
	testing.expect_value(t, minimized, 0)
}
