package main

import "aio:colour"
import "aio:commands"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:math"
import "core:time"

// The title bar's own controls under the pointer and held: the title actions, the tab orientation
// button, the native caption buttons and the workspace button. Window embeds it; the pointer surfaces
// set it and window_chrome_draw draws from it.
Title_Controls :: struct {
	title_action_hover:             Title_Action,
	title_action_armed:             ui.Armed(Title_Action),
	tab_orientation_button_hovered: bool,
	tab_orientation_button_armed:   ui.Armed(bool),
	caption_hover:                  Maybe(platform.Caption_Button),
	caption_armed:                  ui.Armed(Maybe(platform.Caption_Button)),
	workspace_hovered:              bool,
	workspace_motion:               ui.Control_Motion,
}

// Only the workspace button animates its hover; true when the window must draw again.
title_controls_animate :: proc(app: ^App, w: ^Window, now: time.Tick) -> bool {
	return ui.control_update(&w.workspace_motion, w.workspace_hovered, false, app.animations, now)
}

title_controls_animating :: proc(w: ^Window) -> bool {
	return ui.control_active(w.workspace_motion)
}

// Whether `pane` presents as the window's focused pane: its outline, header, full contrast and focused
// cursor all follow this. Its cursor also needs the keyboard; see pane_has_keyboard.
pane_shows_focus :: proc(w: ^Window, pane: layout.Pane_Rect) -> bool {
	return w.focused && pane.node == window_tree(w).focus
}

// The focused pane takes typing unless the palette or the find bar holds the keyboard.
pane_has_keyboard :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) -> bool {
	return pane_shows_focus(w, pane) && !palette_active(app, w) && !ui.find_has_keyboard(&w.find)
}

window_content_area :: proc(app: ^App, w: ^Window) -> layout.Rect {
	return window_content_area_in(app, w, w.pane_fill)
}

// The content area w has when its pane fill is `fill`, which need not be the fill it has now.
window_content_area_in :: proc(app: ^App, w: ^Window, fill: layout.Pane_Fill) -> layout.Rect {
	if fill == .Screen {return {0, 0, f32(w.width), f32(w.height)}}
	r := ui.pane_area(
		f32(w.width),
		f32(w.height),
		window_title_height_in(w, fill),
		f32(app.settings.pane.gap),
		w.scale,
	)
	if !w.tabs_horizontal && rail_docked_in(w, fill) && w.phase != .Preparing {
		rail_width := min(rail_width_pixels(w), r.width)
		r.x += rail_width
		r.width -= rail_width
	}
	dock_width := status_panel_dock_width_in(app, w, fill)
	r.width = max(0, r.width - dock_width)
	if app.settings.status.panel_side == .Left {r.x += dock_width}
	return {r.x, r.y, r.width, r.height}
}

// The geometry w places its panes with when its pane fill is `fill`. Floating groups keep the window's
// own floating area whatever the fill.
window_geometry :: proc(app: ^App, w: ^Window, fill: layout.Pane_Fill) -> layout.Geometry {
	return {
		tiled = window_content_area_in(app, w, fill),
		floating = floating_area(w),
		gap = window_gap(app, w),
		header = floating_header_height(w),
	}
}

window_chrome_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	window_shared_borders(app, w)
	bar_height := window_title_height(w)
	if render.push_layer(&w.list, {0, 0, f32(w.width), bar_height}) == .None {
		if render.push_rect(
			   &w.list,
			   {rect = {0, 0, f32(w.width), bar_height}, color = app.theme.tab_bar},
		   ) !=
		   .None {
			return .Ok
		}
	}
	caption_pressed: Maybe(platform.Caption_Button)
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
	if window_linked(w) {return pane_link_title_draw(app, w)}
	if result := workspace_button_draw(app, w); result != .Ok {return result}
	if result := status_pill_draw(app, w); result != .Ok {return result}
	title_actions_draw(app, w)
	if result := tab_orientation_button_draw(app, w); result != .Ok {return result}
	if w.tabs_horizontal {return window_tab_strip_draw(app, w)}
	return .Ok
}

window_gap :: proc(app: ^App, w: ^Window) -> f32 {
	return ui.pane_gap(f32(app.settings.pane.gap), w.scale)
}

// Fullscreen has no surrounding card to reveal at rounded corners.
window_pane_radius :: proc(app: ^App, w: ^Window) -> f32 {
	if w.pane_fill == .Screen {return 0}
	return f32(app.settings.pane.corner_radius) * w.scale
}

window_leader_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if !leader_armed(w) {return .Ok}
	leader, enabled := app.leader.?
	if !enabled {return .Ok}
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	label := commands.shortcut_text(leader, buffer[:])
	tree := window_tree(w)
	if tree == nil {return .Ok}
	for pane in w.panes {
		if pane.node != tree.focus {continue}
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
	radius := window_pane_radius(app, w)
	if render.push_rect(
		   &w.list,
		   {
			   rect = {r.x, r.y, r.width, r.height},
			   color = colour.rgba(app.settings.colors.background),
			   radius = radius,
		   },
	   ) !=
	   .None {return}
}

window_card_outline :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	if w.pane_fill == .Screen {return}
	r := pane.rect
	clip := render.Rect{0, 0, f32(w.width), f32(w.height)}
	if app.settings.pane.gap == 0 && !pane.floating {
		clip = {r.x, r.y, r.width, r.height}
		edge := math.ceil(max(1, w.scale))
		for bar in w.dock_edges.bars[:w.dock_edges.count] {card_clip_shared(&clip, r, bar, edge)}
		for d in w.dividers {card_clip_shared(&clip, r, {d.axis, d.rect}, edge)}
	}
	if render.push_layer(&w.list, clip) != .None {return}
	radius := window_pane_radius(app, w)
	border, stroke := app.theme.pane_border, max(1, w.scale)
	if window_focus_outlined(app, w, pane) {
		border, stroke = app.theme.pane_focus, max(1, f32(app.settings.pane.focus_border) * w.scale)
	}
	if render.push_rect(
		   &w.list,
		   {rect = {r.x, r.y, r.width, r.height}, color = border, radius = radius, stroke = stroke},
	   ) !=
	   .None {return}
}

// Leaves out the side of a pane rectangle `r` that touches `bar`, whose shared border draws it.
@(private = "file")
card_clip_shared :: proc(clip: ^render.Rect, r: layout.Rect, bar: layout.Edge, edge: f32) {
	leading, trailing := bar_adjacent(r, bar)
	if bar.axis == .Horizontal {
		if leading {clip.x += edge; clip.width -= edge}
		if trailing {clip.width -= edge}
	} else {
		if leading {clip.y += edge; clip.height -= edge}
		if trailing {clip.height -= edge}
	}
}

// Which sides of pane rectangle `r` lie along `bar` on the bar's axis: its leading side just after the
// bar, its trailing side just before it. With no gap those sides draw once, as the bar's shared border.
@(private = "file")
bar_adjacent :: proc(r: layout.Rect, bar: layout.Edge) -> (leading, trailing: bool) {
	if bar.axis == .Horizontal {
		return r.x == bar.rect.x + bar.rect.width, r.x + r.width == bar.rect.x
	}
	return r.y == bar.rect.y + bar.rect.height, r.y + r.height == bar.rect.y
}

@(private)
window_focus_outlined :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) -> bool {
	return pane_shows_focus(w, pane) && app.settings.pane.focus_border > 0
}

// Fades an unfocused pane, header included, toward its own background so the focused pane alone
// keeps full contrast; the outline drawn after it stays crisp.
window_card_dim :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect, background: render.Color) {
	dim := app.settings.pane.unfocused_dim
	if dim <= 0 || pane_shows_focus(w, pane) {return}
	r := render.Rect{pane.rect.x, pane.rect.y, pane.rect.width, pane.rect.height}
	if render.push_layer(&w.list, r, window_pane_radius(app, w)) != .None {return}
	veil := background
	veil.a = f32(dim) / 100
	if render.push_rect(&w.list, {rect = r, color = veil}) != .None {return}
}

@(private)
window_shared_borders :: proc(app: ^App, w: ^Window) {
	if app.settings.pane.gap != 0 || (len(w.dividers) == 0 && w.dock_edges.count == 0) {return}
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return}
	for bar in w.dock_edges.bars[:w.dock_edges.count] {
		if !window_shared_border(app, w, bar) {return}
	}
	for d in w.dividers {
		if !window_shared_border(app, w, {d.axis, d.rect}) {return}
	}
}

// One bar's border, with the stretch beside a focus-outlined pane in the focus colour; false when the
// draw list is full.
@(private = "file")
window_shared_border :: proc(app: ^App, w: ^Window, bar: layout.Edge) -> bool {
	r := bar.rect
	if render.push_rect(
		   &w.list,
		   {rect = {r.x, r.y, r.width, r.height}, color = app.theme.pane_border},
	   ) !=
	   .None {return false}
	for pane in w.panes {
		if pane.floating || !window_focus_outlined(app, w, pane) {continue}
		p := pane.rect
		if leading, trailing := bar_adjacent(p, bar); !leading && !trailing {continue}
		segment := r
		if bar.axis == .Horizontal {
			segment.y = max(r.y, p.y)
			segment.height = max(0, min(r.y + r.height, p.y + p.height) - segment.y)
		} else {
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
		   .None {return false}
	}
	return true
}
