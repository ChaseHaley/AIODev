package main

import "aio:layout"
import "core:fmt"

// How every refusal for the minimum pane size ends: where the user changes it.
@(private)
PANE_MINIMUM_HINT :: "Change Minimum Pane Width and Height in Settings."

// Whether every pane in `rects` keeps the minimum pane size, measured with the header each pane is drawn
// with, as pane fitting measures it. A pane no smaller than it was in `before` keeps what it had.
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
		entry := workspace_session_for_content(app, pane.content)
		box := pane_box(w.metrics, pane.rect, pane_insets(app, w, entry, pane))
		if int(box.columns) < minimum.minimum_columns || int(box.rows) < minimum.minimum_rows {
			if notify_failure {
				notify(
					app,
					.Warning,
					fmt.tprintf(
						"Can't create this pane: %d × %d content cells; minimum %d × %d. " + PANE_MINIMUM_HINT,
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

// A pane drop refused because a pane would end up below the minimum pane size.
pane_minimum_dock_refused :: proc(app: ^App) {
	minimum := app.settings.pane
	notify(
		app,
		.Warning,
		fmt.tprintf(
			"Can't dock: minimum %d × %d content cells. " + PANE_MINIMUM_HINT,
			minimum.minimum_columns,
			minimum.minimum_rows,
		),
	)
}

pane_minimum_single :: proc(app: ^App, w: ^Window, notify_failure := true) -> bool {
	area := window_content_area(app, w)
	rects := [?]layout.Pane_Rect{{content = PANE_MEASUREMENT_CONTENT, rect = area}}
	return pane_minimum_allows(app, w, rects[:], nil, notify_failure)
}
