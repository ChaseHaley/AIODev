package app_test

import "aio:input"
import "core:testing"
import app "../../src"
import "aio:layout"

// An active pane drag in w carrying `node` of `source`, as hovering would leave it over `destination`.
seed_pane_drag :: proc(
	w: ^app.Window,
	source: ^app.Tab,
	node: layout.Node_Id,
	destination: app.Pane_Destination = nil,
	preview: app.Tear_Off_Preview = nil,
) {
	visit := app.pane_destination_window(destination)
	if visit == 0 {visit = w.id}
	w.drag = app.Drag_Active {
		carry   = app.Pane_Carry{grab = {source, node}, destination = destination, visit = {window = visit}},
		preview = preview,
	}
}

// The prepared window of w's tear-off, or 0.
drag_preview :: proc(w: ^app.Window) -> input.Window_Id {
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
	testing.expect_value(t, app.pane_drag_label(grab, app.Pane_Drop{tab = &destination}), "Move pane here")
	edge := app.Pane_Drop{tab = &destination, place = .Edge}
	testing.expect_value(t, app.pane_drag_label(grab, edge), "Dock to workspace edge")
	testing.expect_value(t, app.pane_drag_label(grab, app.Pane_Drop{place = .Swap}), "Swap panes")
	new_tab := app.Pane_Drop{tab = &destination, place = .New_Tab}
	testing.expect_value(t, app.pane_drag_label(grab, new_tab), "+ New tab")
	grab.node = source.tree.root
	new_tab.tab = &source
	testing.expect_value(t, app.pane_drag_label(grab, new_tab), "Move tab to end")
}
