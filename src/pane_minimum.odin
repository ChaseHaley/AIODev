package main

import "core:fmt"
import "core:math"
import "aio:layout"
import "aio:term_view"
import "aio:ui"

pane_minimum_allows :: proc(app: ^App, w: ^Window, rects: []layout.Pane_Rect,
	before: []layout.Pane_Rect, notify_failure: bool) -> bool {
	minimum := app.settings.pane
	if minimum.minimum_columns == 0 && minimum.minimum_rows == 0 { return true }
	for pane in rects {
		unchanged := false
		for old in before {
			if old.content == pane.content && old.rect.width <= pane.rect.width &&
			   old.rect.height <= pane.rect.height { unchanged = true; break }
		}
		if unchanged { continue }
		padding := math.round(f32(app.settings.window.padding)*w.scale)
		if entry := session_find(app, pane.content.id); entry != nil { padding = pane_padding(app, w, entry) }
		header := app.settings.pane.show_headers ? math.round(ui.HEADER_HEIGHT*w.scale) : 0
		columns, rows := term_view.grid_size(w.metrics, pane.rect.width, max(0, pane.rect.height-header), padding)
		if int(columns) < minimum.minimum_columns || int(rows) < minimum.minimum_rows {
			if notify_failure {
				notify(app, .Info, fmt.tprintf("Can't create this pane: %d × %d content cells; minimum %d × %d. "+
					"Change Minimum Pane Width and Height in Settings.", columns, rows,
					minimum.minimum_columns, minimum.minimum_rows))
			}
			return false
		}
	}
	return true
}

pane_minimum_single :: proc(app: ^App, w: ^Window) -> bool {
	area := window_content_area(app, w)
	rects := [?]layout.Pane_Rect{{rect = area}}
	return pane_minimum_allows(app, w, rects[:], nil, true)
}

pane_minimum_split :: proc(app: ^App, w: ^Window, direction: layout.Direction, ratio: f32) -> bool {
	trial := w.tree^
	trial.zoomed = false
	trial.nodes = make([dynamic]layout.Node, len(trial.nodes), len(trial.nodes)+2, context.temp_allocator)
	copy(trial.nodes[:], w.tree.nodes[:])
	if _, err := layout.split_direction(&trial, trial.focus, direction, ratio, {.Terminal, app.next_session_id+1});
	   err != nil { notify(app, .Error, "Could not check the new pane size."); return false }
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	before := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	area, gap := window_content_area(app, w), window_gap(app, w)
	layout.compute(&trial, area, gap, &rects)
	original := w.tree^
	original.zoomed = false
	layout.compute(&original, area, gap, &before)
	return pane_minimum_allows(app, w, rects[:], before[:], true)
}
