package main

import "aio:layout"
import "aio:platform"
import "aio:ui"

// The window's half of layout.PANE_VIEW_TRANSITIONS. Everything here reads w.pane_fill and tree.zoomed
// through pane_view_current, and only pane_view_apply writes them.

// w.tree is nil only for the moment a window has lost its last tab.
pane_view_current :: proc(w: ^Window) -> layout.Pane_View {
	return layout.pane_view_of(w.pane_fill, w.tree != nil && w.tree.zoomed)
}

// Whether the window shows the focused pane alone.
pane_view_solo :: proc(w: ^Window) -> bool {
	return pane_view_current(w) != .Split
}

pane_fill_active :: proc(w: ^Window) -> bool {
	return w.pane_fill != .None
}

// window_title_height is the title bar space the window reserves; Screen fills the monitor without it.
window_title_height :: proc(w: ^Window) -> f32 {
	if w.pane_fill == .Screen {return 0}
	return ui.TITLE_BAR_HEIGHT * w.scale
}

// The owner chose a view. The window follows at once, unless the operating system refused.
pane_view_toggle :: proc(app: ^App, w: ^Window, event: layout.Pane_View_Event) {
	if pane_view_apply(app, w, event) {window_relayout(app, w)}
}

// Runs at the top of every layout, which every change to a shown tree reaches, so no caller can forget
// to end a view. A tab changed while hidden ends the view when it is next shown.
pane_view_sync :: proc(app: ^App, w: ^Window) {
	if w.tree != nil && w.tree.panes_changed {_ = pane_view_apply(app, w, .Panes_Changed)}
}

// The area panes return to once a change to them has ended any fill, which size checks must judge by.
pane_view_split_area :: proc(app: ^App, w: ^Window) -> layout.Rect {
	fill := w.pane_fill
	w.pane_fill = .None
	defer w.pane_fill = fill
	return window_content_area(app, w)
}

// The operating system goes first, so a refusal leaves every part of the view as it was.
@(private = "file", require_results)
pane_view_apply :: proc(app: ^App, w: ^Window, event: layout.Pane_View_Event) -> bool {
	w.tree.panes_changed = false
	to := layout.PANE_VIEW_TRANSITIONS[pane_view_current(w)][event]
	if to == pane_view_current(w) {return false}
	fill, zoomed := layout.pane_view_parts(to)
	if (fill == .Screen) != (w.pane_fill == .Screen) {
		if platform.window_set_screen(&app.platform, w.id, fill == .Screen) != .None {
			notify(app, .Error, "Could not change the window to full screen.")
			return false
		}
	}
	w.pane_fill, w.tree.zoomed = fill, zoomed
	w.dragging = {}
	return true
}
