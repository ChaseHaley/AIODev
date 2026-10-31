package main

import "aio:layout"
import "core:fmt"

pane_minimum_allows :: proc(
	app: ^App,
	w: ^Window,
	rects: []layout.Pane_Rect,
	before: []layout.Pane_Rect,
	notify_failure: bool,
) -> bool {
	minimum := app.settings.pane
	if minimum.minimum_columns == 0 && minimum.minimum_rows == 0 {return true}
	for pane in rects {
		unchanged := false
		for old in before {
			if old.content == pane.content &&
			   old.rect.width <= pane.rect.width &&
			   old.rect.height <= pane.rect.height {unchanged = true; break}
		}
		if unchanged {continue}
		insets := pane_insets(app, w.scale, session_find(app, pane.content.id))
		box := pane_box(w.metrics, pane.rect, insets)
		if int(box.columns) < minimum.minimum_columns || int(box.rows) < minimum.minimum_rows {
			if notify_failure {
				notify(
					app,
					.Warning,
					fmt.tprintf(
						"Can't create this pane: %d × %d content cells; minimum %d × %d. " +
						"Change Minimum Pane Width and Height in Settings.",
						box.columns,
						box.rows,
						minimum.minimum_columns,
						minimum.minimum_rows,
					),
				)
			}
			return false
		}
	}
	return true
}

pane_minimum_single :: proc(app: ^App, w: ^Window, notify_failure := true) -> bool {
	area := window_content_area(app, w)
	rects := [?]layout.Pane_Rect{{content = {.Terminal, 0}, rect = area}}
	return pane_minimum_allows(app, w, rects[:], nil, notify_failure)
}
