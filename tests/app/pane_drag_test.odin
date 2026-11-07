package app_test

import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"

// An active pane drag in w carrying `node` of `source`, as hovering would leave it over `destination`.
seed_pane_drag :: proc(
	w: ^app.Window,
	source: ^app.Tab,
	node: layout.Node_Id,
	destination: app.Drag_Destination = nil,
	preview: app.Tear_Off_Preview = nil,
) {
	visit := app.drag_destination_window(destination)
	if visit == 0 {visit = w.id}
	w.drag = app.Drag_Active {
		carry       = app.Pane_Carry{grab = {source, node}, visit = {window = visit}},
		destination = destination,
		preview     = preview,
	}
}

// The prepared window of w's tear-off, or 0.
drag_preview :: proc(w: ^app.Window) -> platform.Window_Id {
	a := app.drag_active(w)
	if a == nil {return 0}
	ready, _ := a.preview.(app.Preview_Ready)
	return ready.window
}

@(test)
pane_drag_label_names_each_drop :: proc(t: ^testing.T) {
	source := app.Tab{}
	destination := app.Tab{}
	grab := app.Pane_Grab{source = &source, node = 1}
	testing.expect_value(t, app.pane_drag_label(grab, app.Drop_Pane{tab = &destination}), "Move pane here")
	testing.expect_value(t, app.pane_drag_label(grab, app.Drop_Dock_Root{tab = &destination}), "Dock to workspace edge")
	testing.expect_value(t, app.pane_drag_label(grab, app.Drop_Swap{}), "Swap panes")
	testing.expect_value(t, app.pane_drag_label(grab, app.Drop_New_Tab{tab = &destination}), "+ New tab")
	grab.node = source.tree.root
	testing.expect_value(t, app.pane_drag_label(grab, app.Drop_New_Tab{tab = &source}), "Move tab to end")
}
