package main

import "core:fmt"
import "core:math"
import "aio:commands"
import "aio:glyphs"
import "aio:layout"
import "aio:render"
import "aio:term"
import "aio:ui"

window_tab_bar :: proc(app: ^App, w: ^Window) -> ui.Tab_Bar {
	bar := ui.tab_bar_layout(max(0, f32(w.width)-218*w.scale), w.scale, len(w.workspace.tabs))
	bar.height = ui.TAB_HEIGHT*w.scale
	return bar
}

window_content_area :: proc(app: ^App, w: ^Window) -> layout.Rect {
	bar := window_tab_bar(app, w)
	r := ui.pane_area(f32(w.width), f32(w.height), bar.height, f32(app.settings.pane.gap), w.scale)
	return {r.x, r.y, r.width, r.height}
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
	window_shared_borders(app, w)
	bar := window_tab_bar(app, w)
	if render.push_layer(&w.list, {0, 0, f32(w.width), bar.height}) == .None {
		if render.push_rect(&w.list, {rect = {0, 0, f32(w.width), bar.height}, color = app.theme.chrome}) != .None {
			return .Ok
		}
	}
	if result := ui.caption_draw(&w.list, &app.ui_text, app.theme, f32(w.width), w.scale,
		w.caption_hover, w.caption_pressed, w.maximized); result != .Ok { return result }
	if bar.count == 0 { return .Ok }
	for pass in 0..<(w.tab_drag.active ? 2 : 1) {
		foreground := pass == 1
		for tab, i in w.workspace.tabs {
			if (w.tab_drag.active && tab.marked) != foreground { continue }
			title := fmt.tprintf("Tab %d", i+1)
			if tab.title != "" { title = tab.title }
			x := tab_position(w, i)*bar.tab_width
			if result := ui.tab_draw(&w.list, &app.ui_text, app.theme, bar, i, title,
				i == w.workspace.selected, w.scale,
				tab_control(w, i).hover.value, tab_control(w, i).press.value, 0, x, tab.marked);
				result != .Ok { return result }
		}
	}
	if render.push_layer(&w.list, {0, 0, f32(w.width), bar.height}) == .None {
		x := w.tab_underline.value*bar.tab_width+10*w.scale
		moving := w.tab_drag.active
		for position in w.tab_positions { moving ||= ui.motion_active(position) }
		if moving { x = tab_position(w, w.workspace.selected)*bar.tab_width+10*w.scale }
		if render.push_rect(&w.list, {rect = {x, 30*w.scale, max(0, bar.tab_width-20*w.scale), 2*w.scale},
			color = app.theme.accent, radius = w.scale}) != .None { return .Ok }
	}
	if w.pane_drag.active && w.pane_drag.new_tab { return .Ok }
	if result := ui.tab_draw(&w.list, &app.ui_text, app.theme, bar, bar.count, "+", false, w.scale,
		tab_control(w, bar.count).hover.value, tab_control(w, bar.count).press.value, 0); result != .Ok { return result }
	x := f32(bar.count)*bar.tab_width+bar.button_width
	if render.push_layer(&w.list, {x, 0, bar.button_width, bar.height}) != .None { return .Ok }
	return ui.draw_text(&app.ui_text, &w.list, "⌕", x+8*w.scale,
		(bar.height-app.ui_text.line_height)/2+app.ui_text.ascent, app.theme.muted, bar.button_width)
}

tab_position :: proc(w: ^Window, index: int) -> f32 {
	return index >= 0 && index < len(w.tab_positions) ? w.tab_positions[index].value : f32(index)
}

window_tab_hit :: proc(w: ^Window, bar: ui.Tab_Bar, x, y: f32) -> int {
	if x < 0 || x >= bar.width || y < 0 || y >= bar.height { return -1 }
	for pass in 0..<2 {
		for i := bar.count-1; i >= 0; i -= 1 {
			foreground := w.tab_drag.active && w.workspace.tabs[i].marked
			if foreground != (pass == 0) { continue }
			left := tab_position(w, i)*bar.tab_width
			if x >= left && x < left+bar.tab_width { return i }
		}
	}
	return ui.tab_bar_hit_test(bar, x, y) == bar.count ? bar.count : -1
}

window_tab_close_hit :: proc(w: ^Window, bar: ui.Tab_Bar, x, y: f32) -> int {
	index := window_tab_hit(w, bar, x, y)
	r := ui.tab_close_rect(bar, index, w.scale)
	r.x += (tab_position(w, index)-f32(index))*bar.tab_width
	if r.width > 0 && x >= r.x && x < r.x+r.width && y >= r.y && y < r.y+r.height { return index }
	return -1
}

window_gap :: proc(app: ^App, w: ^Window) -> f32 {
	return ui.pane_gap(f32(app.settings.pane.gap), w.scale)
}

window_leader_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	if w.leader_until == {} { return .Ok }
	leader, enabled := app.leader.?
	if !enabled { return .Ok }
	buffer: [128]u8
	label, err := commands.shortcut_label(leader, buffer[:])
	if err != .None { return .Ok }
	for pane in w.panes {
		if pane.node != w.tree.focus { continue }
		r := pane.rect
		return ui.leader_status_draw(&w.list, &app.ui_text, app.theme,
			{r.x, r.y, r.width, r.height}, label, w.scale)
	}
	return .Ok
}

window_card_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	r := pane.rect
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None { return }
	radius := f32(app.settings.pane.corner_radius)*w.scale
	if render.push_rect(&w.list, {rect = {r.x, r.y, r.width, r.height},
		color = color(app.settings.colors.background), radius = radius}) != .None { return }
}

window_card_outline :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	r := pane.rect
	clip := render.Rect{0, 0, f32(w.width), f32(w.height)}
	if app.settings.pane.gap == 0 {
		clip = {r.x, r.y, r.width, r.height}
		edge := math.ceil(max(1, w.scale))
		for d in w.dividers {
			if d.axis == .Horizontal {
				if r.x == d.rect.x+d.rect.width { clip.x += edge; clip.width -= edge }
				if r.x+r.width == d.rect.x { clip.width -= edge }
			} else {
				if r.y == d.rect.y+d.rect.height { clip.y += edge; clip.height -= edge }
				if r.y+r.height == d.rect.y { clip.height -= edge }
			}
		}
	}
	if render.push_layer(&w.list, clip) != .None { return }
	radius := f32(app.settings.pane.corner_radius)*w.scale
	border := pane.node == w.tree.focus ? app.theme.focus : app.theme.border
	if render.push_rect(&w.list, {rect = {r.x, r.y, r.width, r.height}, color = border,
		radius = radius, stroke = max(1, w.scale)}) != .None { return }
}

@(private)
tab_control :: proc(w: ^Window, index: int) -> ui.Control_Motion {
	if index < 0 || index >= len(w.tab_controls) { return {} }
	return w.tab_controls[index]
}

@(private)
window_shared_borders :: proc(app: ^App, w: ^Window) {
	if app.settings.pane.gap != 0 || len(w.dividers) == 0 { return }
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None { return }
	for d in w.dividers {
		r := d.rect
		if render.push_rect(&w.list, {rect = {r.x, r.y, r.width, r.height}, color = app.theme.border}) != .None { return }
		for pane in w.panes {
			if pane.node != w.tree.focus { continue }
			p := pane.rect
			segment := r
			if d.axis == .Horizontal {
				if p.x+p.width != r.x && p.x != r.x+r.width { continue }
				segment.y = max(r.y, p.y)
				segment.height = max(0, min(r.y+r.height, p.y+p.height)-segment.y)
			} else {
				if p.y+p.height != r.y && p.y != r.y+r.height { continue }
				segment.x = max(r.x, p.x)
				segment.width = max(0, min(r.x+r.width, p.x+p.width)-segment.x)
			}
			if render.push_rect(&w.list, {rect = {segment.x, segment.y, segment.width, segment.height},
				color = app.theme.focus}) != .None { return }
		}
	}
}
