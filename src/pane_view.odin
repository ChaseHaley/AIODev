package main

import "aio:layout"
import "aio:platform"
import "aio:ui"

// The window's half of layout.PANE_VIEW_TRANSITIONS. Everything here reads w.pane_fill and tree.zoomed
// through pane_view_current, and only pane_view_apply writes them.

// The shown tree is nil only for the moment a window has lost its last tab.
pane_view_current :: proc(w: ^Window) -> layout.Pane_View {
	tree := window_tree(w)
	return layout.pane_view_of(w.pane_fill, tree != nil && tree.zoomed)
}

// Whether the window shows the focused pane alone.
pane_view_solo :: proc(w: ^Window) -> bool {
	return pane_view_current(w) != .Split
}

pane_fill_active :: proc(w: ^Window) -> bool {
	return w.pane_fill != .None
}

window_title_height :: proc(w: ^Window) -> f32 {
	return window_title_height_in(w, w.pane_fill)
}

// The title bar space the window reserves under `fill`; Screen fills the monitor without it.
window_title_height_in :: proc(w: ^Window, fill: layout.Pane_Fill) -> f32 {
	if fill == .Screen {return 0}
	return ui.TITLE_BAR_HEIGHT * w.scale
}

// The owner chose a view. The window follows at once, unless the operating system refused.
pane_view_toggle :: proc(app: ^App, w: ^Window, event: layout.Pane_View_Event) {
	if pane_view_apply(app, w, event) {window_relayout(app, w)}
}

// Runs at the top of every layout, which every change to a shown tree reaches, so no caller can forget
// to end a view. A tab changed while hidden ends the view when it is next shown.
pane_view_sync :: proc(app: ^App, w: ^Window) {
	if tree := window_tree(w); tree != nil && tree.panes_changed {_ = pane_view_apply(app, w, .Panes_Changed)}
}

// The operating system goes first, so a refusal leaves every part of the view as it was.
@(private = "file", require_results)
pane_view_apply :: proc(app: ^App, w: ^Window, event: layout.Pane_View_Event) -> bool {
	tree := window_tree(w)
	tree.panes_changed = false
	to := layout.PANE_VIEW_TRANSITIONS[pane_view_current(w)][event]
	if to == pane_view_current(w) {return false}
	fill, zoomed := layout.pane_view_parts(to)
	if (fill == .Screen) != (w.pane_fill == .Screen) {
		if platform.window_set_screen(&app.platform, w.id, fill == .Screen) != .None {
			notify(app, .Error, "Could not change the window to full screen.")
			return false
		}
	}
	w.pane_fill, tree.zoomed = fill, zoomed
	divider_cancel(w)
	return true
}
