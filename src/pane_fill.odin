package main

import "aio:platform"
import "aio:ui"

// Pane_Fill widens the focused pane beyond its split area. Maximize (zoom) keeps the rail and activity panel.
Pane_Fill :: enum {
	None,
	// The focused pane fills everything under the title bar.
	Content,
	// The focused pane fills the monitor, with the title bar hidden too.
	Screen,
}

pane_fill_active :: proc(w: ^Window) -> bool {
	return w.pane_fill != .None
}

// window_title_height is the title bar space the window reserves; Screen fills the monitor without it.
window_title_height :: proc(w: ^Window) -> f32 {
	if w.pane_fill == .Screen {return 0}
	return ui.TITLE_BAR_HEIGHT * w.scale
}

// pane_fill_toggle enters mode, or leaves it when already in mode. Leaving restores the prior zoom.
pane_fill_toggle :: proc(app: ^App, w: ^Window, mode: Pane_Fill) {
	next := w.pane_fill == mode ? Pane_Fill.None : mode
	if (next == .Screen) != (w.pane_fill == .Screen) {
		if err := platform.window_set_screen(&app.platform, w.id, next == .Screen); err != .None {
			notify(app, .Error, "Could not change the window to full screen.")
			return
		}
	}
	if w.pane_fill == .None && next != .None {
		w.pane_fill_zoom = w.tree.zoomed
		w.tree.zoomed = true
	}
	if next == .None {w.tree.zoomed = w.pane_fill_zoom}
	w.pane_fill = next
	w.dragging = {}
	window_relayout(app, w)
}
