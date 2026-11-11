package main

import "aio:layout"
import "aio:platform"
import "aio:ui"

// The window's half of layout.PANE_VIEW_TRANSITIONS. Each tab owns its view, tree.fill and the zooms of
// its tiling and floats, and keeps it while other tabs show; only pane_view_apply changes it. A view acts
// on the focused pane's container, tiled or floating. The window applies the view of the tab it shows:
// w.pane_fill is the fill it lays out with, which pane_view_sync takes from that tab at every layout, so it
// differs from the tab's only between a tab change and the layout that follows.

// The tab's view as its tiling holds it, which is the window's fill whatever pane it shows. The shown tree
// is nil only for the moment a window has lost its last tab.
pane_view_current :: proc(w: ^Window) -> layout.Pane_View {
	tree := window_tree(w)
	if tree == nil {return .Split}
	return layout.pane_view_of(tree.fill, tree.zoomed)
}

// Whether the tiling shows its focused pane alone, or nothing beside a filling floating pane.
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

// The owner chose a view for the focused pane. The window follows at once, unless the operating system
// refused, and the pane eases there above everything else, growing over the window or shrinking back off
// it.
pane_view_toggle :: proc(app: ^App, w: ^Window, event: layout.Pane_View_Event) {
	tree := window_tree(w)
	node := tree.focus
	if !pane_view_apply(app, w, node, event) {return}
	content, _ := layout.pane_content(tree, node)
	pane_motion_arm(w, .View, content)
	window_relayout(app, w)
}

// Runs at the top of every layout, which every change to a shown tree reaches, so no caller can forget
// to end a view. A tab changed while hidden ends its view when it is next shown. A window showing another
// tab takes that tab's view.
pane_view_sync :: proc(app: ^App, w: ^Window) {
	tree := window_tree(w)
	if tree == nil {return}
	if tree.panes_changed {_ = pane_view_apply(app, w, layout.focus_tiled(tree), .Panes_Changed)}
	if tree.fill == w.pane_fill || pane_fill_set(app, w, tree.fill) {return}
	// The window stayed in or out of full screen, so the tab takes the fill the window can give it.
	tree.fill = w.pane_fill == .Screen ? .Screen : .None
	w.pane_fill = tree.fill
}

// The operating system goes first, so a refusal leaves every part of the view as it was. The tab's panes
// changing ends the fill whichever container held it, since layout hands such a fill to the tiling.
@(private = "file", require_results)
pane_view_apply :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	event: layout.Pane_View_Event,
) -> bool {
	tree := window_tree(w)
	tree.panes_changed = false
	to, fill := layout.pane_view_next(tree, node, event)
	if to == layout.pane_view_at(tree, node) {return false}
	if !pane_fill_set(app, w, fill) {return false}
	layout.pane_view_set(tree, node, to)
	divider_cancel(w)
	return true
}

// Lays the window out with `fill`, going full screen or back first when it must. The panes' next motion
// starts from where they were on the screen, as the window's client area moves with it.
@(private = "file", require_results)
pane_fill_set :: proc(app: ^App, w: ^Window, fill: layout.Pane_Fill) -> bool {
	if (fill == .Screen) != (w.pane_fill == .Screen) {
		x, y, before := platform.window_to_screen(&app.platform, w.id, 0, 0)
		if platform.window_set_screen(&app.platform, w.id, fill == .Screen) != .None {
			notify(app, .Error, "Could not change the window to full screen.")
			return false
		}
		moved_x, moved_y, after := platform.window_to_screen(&app.platform, w.id, 0, 0)
		if before == .None && after == .None {pane_motion_shift(w, {f32(x - moved_x), f32(y - moved_y)})}
	}
	w.pane_fill = fill
	return true
}
