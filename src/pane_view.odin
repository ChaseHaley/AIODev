package main

import "aio:layout"
import "aio:platform"
import "aio:ui"

// The window's half of layout.PANE_VIEW_TRANSITIONS. Everything here reads w.pane_fill and tree.zoomed
// through pane_view_current, and only pane_view_apply writes them, apart from the zoom a tab loses as
// the window stops showing it.

// The tab a window laid out last, by ids that outlive a closed tab's record; zero before its first layout.
Shown_Tab :: struct {
	workspace, tab: u32,
}

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

// The owner chose a view. The window follows at once, unless the operating system refused, and the panes
// ease there, the focused one above the others as it grows over them or shrinks back off them.
pane_view_toggle :: proc(app: ^App, w: ^Window, event: layout.Pane_View_Event) {
	if !pane_view_apply(app, w, event) {return}
	tree := window_tree(w)
	content, _ := layout.pane_content(tree, layout.focus_tiled(tree))
	pane_motion_arm(w, .View, content)
	window_relayout(app, w)
}

// Runs at the top of every layout, which every change to a shown tree reaches, so no caller can forget
// to end a view. A tab changed while hidden ends the view when it is next shown. Showing another tab
// ends the view and the left tab's zoom, so either tab shows split; a window's first tab keeps its zoom.
pane_view_sync :: proc(app: ^App, w: ^Window) {
	tab := selected_tab(w.workspace)
	if tab == nil {return}
	shown := Shown_Tab{w.workspace.id, tab.id}
	left := w.shown_tab
	w.shown_tab = shown
	if left != {} && left != shown {
		pane_view_unzoom_left(app, left)
		_ = pane_view_apply(app, w, .Tab_Changed)
	} else if tab.tree.panes_changed {
		_ = pane_view_apply(app, w, .Panes_Changed)
	}
}

// A left tab another window now shows keeps its zoom: that window owns its view.
@(private = "file")
pane_view_unzoom_left :: proc(app: ^App, left: Shown_Tab) {
	for workspace in app.workspaces {
		if workspace.id != left.workspace {continue}
		index := tab_index_by_id(workspace, left.tab)
		if index < 0 {return}
		if index == workspace.selected && window_for_workspace(app, workspace) != nil {return}
		workspace.tabs[index].tree.zoomed = false
		return
	}
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
