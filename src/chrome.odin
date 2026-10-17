package main

import "core:fmt"
import "core:log"
import "aio:glyphs"
import "aio:layout"
import "aio:render"
import "aio:term"
import "aio:ui"

window_content_area :: proc(w: ^Window) -> layout.Rect {
	bar := ui.tab_bar_layout(f32(w.width), w.scale, len(w.workspace.tabs))
	return {0, bar.height, f32(w.width), max(0, f32(w.height)-bar.height)}
}

window_generation :: proc(app: ^App, w: ^Window) -> u64 {
	generation: u64
	for pane in w.panes {
		if entry := session_find(app, pane.content.id); entry != nil {
			generation += term.generation(entry.session)
		}
	}
	return generation
}

window_chrome_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	if len(w.dividers) > 0 {
		if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) == .None {
			for d in w.dividers {
				r := d.rect
				if render.push_rect(&w.list, {rect = {r.x, r.y, r.width, r.height},
					color = app.theme.border}) != .None { log.error("drawing a divider failed") }
			}
		}
	}
	bar := ui.tab_bar_layout(f32(w.width), w.scale, len(w.workspace.tabs))
	if bar.count < 2 { return .Ok }
	for tab, i in w.workspace.tabs {
		title := fmt.tprintf("Tab %d", i+1)
		pane := tab.tree.nodes[tab.tree.focus].(layout.Pane)
		if entry := session_find(app, pane.content.id); entry != nil {
			if value := term.title(entry.session, context.temp_allocator); value != "" { title = value }
		}
		if result := ui.tab_draw(&w.list, &app.ui_text, app.theme, bar, i, title,
			i == w.workspace.selected, w.scale); result != .Ok { return result }
	}
	return ui.tab_draw(&w.list, &app.ui_text, app.theme, bar, bar.count, "+", false, w.scale)
}
