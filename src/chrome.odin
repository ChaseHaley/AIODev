package main

import "aio:commands"
import "aio:glyphs"
import "aio:layout"
import "aio:render"
import "aio:term"
import "aio:ui"
import "core:math"

window_content_area :: proc(app: ^App, w: ^Window) -> layout.Rect {
	r := ui.pane_area(
		f32(w.width),
		f32(w.height),
		ui.TITLE_BAR_HEIGHT * w.scale,
		f32(app.settings.pane.gap),
		w.scale,
	)
	if !w.tabs_horizontal && rail_docked(w) && !w.preparing {
		rail_width := min(rail_width_pixels(w), r.width)
		r.x += rail_width
		r.width -= rail_width
	}
	r.width = max(0, r.width - status_panel_dock_width(app, w))
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
	bar_height := ui.TITLE_BAR_HEIGHT * w.scale
	if render.push_layer(&w.list, {0, 0, f32(w.width), bar_height}) == .None {
		if render.push_rect(
			   &w.list,
			   {rect = {0, 0, f32(w.width), bar_height}, color = app.theme.tab_bar},
		   ) !=
		   .None {
			return .Ok
		}
	}
	// A disarmed caption control must not be drawn as button 0.
	caption_pressed := -1
	if ui.armed_down(w.caption_armed) {caption_pressed = ui.armed_target(w.caption_armed)}
	if result := ui.caption_draw(
		&w.list,
		&w.ui_text,
		app.theme,
		f32(w.width),
		w.scale,
		w.caption_hover,
		caption_pressed,
		w.maximized,
		w.pointer,
	); result != .Ok {return result}
	if result := workspace_button_draw(app, w); result != .Ok {return result}
	if result := status_pill_draw(app, w); result != .Ok {return result}
	if result := tab_orientation_button_draw(app, w); result != .Ok {return result}
	if w.tabs_horizontal {return window_tab_strip_draw(app, w)}
	return .Ok
}

window_gap :: proc(app: ^App, w: ^Window) -> f32 {
	return ui.pane_gap(f32(app.settings.pane.gap), w.scale)
}

window_leader_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	if w.leader_until == {} {return .Ok}
	leader, enabled := app.leader.?
	if !enabled {return .Ok}
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	label := commands.shortcut_text(leader, buffer[:])
	for pane in w.panes {
		if pane.node != w.tree.focus {continue}
		r := pane.rect
		return ui.leader_status_draw(
			&w.list,
			&w.ui_text,
			app.theme,
			{r.x, r.y, r.width, r.height},
			label,
			w.scale,
		)
	}
	return .Ok
}

window_card_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	r := pane.rect
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return}
	radius := f32(app.settings.pane.corner_radius) * w.scale
	if render.push_rect(
		   &w.list,
		   {
			   rect = {r.x, r.y, r.width, r.height},
			   color = color(app.settings.colors.background),
			   radius = radius,
		   },
	   ) !=
	   .None {return}
}

window_card_outline :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	r := pane.rect
	clip := render.Rect{0, 0, f32(w.width), f32(w.height)}
	if app.settings.pane.gap == 0 {
		clip = {r.x, r.y, r.width, r.height}
		edge := math.ceil(max(1, w.scale))
		for d in w.dividers {
			if d.axis == .Horizontal {
				if r.x == d.rect.x + d.rect.width {clip.x += edge; clip.width -= edge}
				if r.x + r.width == d.rect.x {clip.width -= edge}
			} else {
				if r.y == d.rect.y + d.rect.height {clip.y += edge; clip.height -= edge}
				if r.y + r.height == d.rect.y {clip.height -= edge}
			}
		}
	}
	if render.push_layer(&w.list, clip) != .None {return}
	radius := f32(app.settings.pane.corner_radius) * w.scale
	border := pane.node == w.tree.focus ? app.theme.pane_focus : app.theme.pane_border
	if render.push_rect(
		   &w.list,
		   {
			   rect = {r.x, r.y, r.width, r.height},
			   color = border,
			   radius = radius,
			   stroke = max(1, w.scale),
		   },
	   ) !=
	   .None {return}
}

@(private)
window_shared_borders :: proc(app: ^App, w: ^Window) {
	if app.settings.pane.gap != 0 || len(w.dividers) == 0 {return}
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return}
	for d in w.dividers {
		r := d.rect
		if render.push_rect(
			   &w.list,
			   {rect = {r.x, r.y, r.width, r.height}, color = app.theme.pane_border},
		   ) !=
		   .None {return}
		for pane in w.panes {
			if pane.node != w.tree.focus {continue}
			p := pane.rect
			segment := r
			if d.axis == .Horizontal {
				if p.x + p.width != r.x && p.x != r.x + r.width {continue}
				segment.y = max(r.y, p.y)
				segment.height = max(0, min(r.y + r.height, p.y + p.height) - segment.y)
			} else {
				if p.y + p.height != r.y && p.y != r.y + r.height {continue}
				segment.x = max(r.x, p.x)
				segment.width = max(0, min(r.x + r.width, p.x + p.width) - segment.x)
			}
			if render.push_rect(
				   &w.list,
				   {
					   rect = {segment.x, segment.y, segment.width, segment.height},
					   color = app.theme.pane_focus,
				   },
			   ) !=
			   .None {return}
		}
	}
}
