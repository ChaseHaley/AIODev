package app_test

import "core:testing"
import app "../../src"

@(test)
pane_drag_label_names_each_drop :: proc(t: ^testing.T) {
	source := app.Tab{}
	destination := app.Tab{}
	drag := app.Pane_Drag{source = &source}
	testing.expect_value(t, app.pane_drag_label(&drag), "Move pane here")
	drag.root = true
	testing.expect_value(t, app.pane_drag_label(&drag), "Dock to workspace edge")
	drag.swap = true
	testing.expect_value(t, app.pane_drag_label(&drag), "Swap panes")
	drag.new_tab = true
	drag.destination = &destination
	drag.node = 1
	testing.expect_value(t, app.pane_drag_label(&drag), "+ New tab")
	drag.destination = &source
	drag.node = source.tree.root
	testing.expect_value(t, app.pane_drag_label(&drag), "Move tab to end")
	drag.new_window = true
	testing.expect_value(t, app.pane_drag_label(&drag), "+ New window")
}
