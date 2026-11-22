package main

import "cosmos:render"
import "aio:settings"
import "aio:ui"
import "core:math"
import "core:time"
import "cosmos:motion"

// Changing the tab orientation passes the tabs between the docked rail and the title-bar strip through
// the corner where the two meet, as walking off one edge of a maze brings you back at another, turned a
// quarter. Going to the strip, the rail's rows and its New tab footer rise together into the title bar.
// As each goes, its strip counterpart comes out of the right side of the workspace chip by the same
// share, sliding out from behind the tab before it to its own slot, so the strip fills in order; New tab
// and the profile chevron come last, while the rail leaves and the panes take its space. Going to the
// rail is the same in reverse, the rail arriving while New tab goes in, so it is in place before the
// first row comes down. Only drawing moves: hit testing takes the new orientation at once. Window embeds
// it; only this file writes it.
Tab_Flip :: struct {
	// How far the tabs have gone over to the strip: 0 all in the rail, 1 all in the strip.
	flip:         ui.Motion,
	// Going to the strip, the rail's area as it was, where it keeps drawing until it has left, and the
	// height the Activity panel took from it then.
	flip_rail:    render.Rect,
	flip_reserve: f32,
}

// Easing in and out alike, so the first and last tabs through the corner pass as gently as each other.
@(private = "file")
TAB_FLIP_CURVE :: motion.Curve{p = {0.45, 0, 0.55, 1}}

// The share of the Rail and Activity panel motion's duration each tab takes to pass, and the bounds of the
// whole passage in those durations, so a few tabs do not rush and many do not drag.
@(private = "file")
TAB_FLIP_PER_TAB :: f32(0.5)
@(private = "file")
TAB_FLIP_SHORTEST :: f32(2)
@(private = "file")
TAB_FLIP_LONGEST :: f32(4)

// The rail's items as they rise: the title bar's bottom edge they pass, the row height, the first row's
// top, and New tab's top and height, which counts as one padding after the last row even when the list is
// cut short above it; `span` is how far all of them rise to be gone.
@(private = "file")
Tab_Flip_Items :: struct {
	top, row, first, footer, footer_height, span: f32,
}

@(private = "file")
tab_flip_items :: proc(layout: ui.Rail_Layout) -> Tab_Flip_Items {
	padding := ui.RAIL_PADDING * layout.scale
	first := layout.list.y + padding - layout.scroll
	footer := first + f32(layout.count) * layout.row_height + padding
	return {
		top = layout.area.y,
		row = layout.row_height,
		first = first,
		footer = footer,
		footer_height = layout.footer.height,
		span = max(0, footer + layout.footer.height - layout.area.y),
	}
}

// The share of the item at `y`, `height` tall, that has gone into the title bar once the rail rose `rise`.
@(private = "file")
tab_flip_gone :: proc(items: Tab_Flip_Items, y, height, rise: f32) -> f32 {
	if height <= 0 {return rise >= y - items.top ? 1 : 0}
	return clamp((rise - (y - items.top)) / height, 0, 1)
}

tab_flip_active :: proc(w: ^Window) -> bool {
	return ui.motion_active(w.flip)
}

tab_flip_animate :: proc(w: ^Window, frame: ui.Frame_Time) -> bool {
	return ui.motion_update(&w.flip, frame)
}

// The rail the tabs pass through: the docked rail in vertical view, and going to the strip, the rail as
// it was.
@(private = "file")
tab_flip_rail_layout :: proc(w: ^Window) -> (ui.Rail_Layout, bool) {
	if w.workspace == nil {return {}, false}
	if !w.tabs_horizontal {return rail_layout_query(w)}
	area := w.flip_rail
	area.height = max(0, area.height - w.flip_reserve)
	return ui.rail_layout(area, w.scale, tab_layout(nil, w, false).slots, w.rail_scroll), true
}

// How far the rows of the rail laid out as `layout` have risen into the title bar, in whole pixels: all
// the way while the tabs are in the strip, so a rail still leaving after the tabs arrived shows none.
tab_flip_rise :: proc(w: ^Window, layout: ui.Rail_Layout) -> f32 {
	return math.round(w.flip.value * tab_flip_items(layout).span)
}

// The share of TAB_FLIP_CURVE's time at which it has eased `share` of the way.
@(private = "file")
tab_flip_time_at :: proc(share: f32) -> f32 {
	if share <= 0 {return 0}
	if share >= 1 {return 1}
	low, high: f32 = 0, 1
	for _ in 0 ..< 24 {
		middle := (low + high) / 2
		if motion.ease(TAB_FLIP_CURVE, middle) < share {low = middle} else {high = middle}
	}
	return high
}

// Starts the tabs toward the orientation w now has, from wherever they are. Call it after w took the new
// orientation and before the relayout that places it, with the rail as it was: its `area`, the Activity
// panel's height in it, `reserve`, and whether it was docked. Without a docked rail on the vertical side,
// a window that has not drawn, or motion off, the tabs land at once.
tab_flip_begin :: proc(app: ^App, w: ^Window, area: render.Rect, reserve: f32, was_docked: bool) {
	target: f32 = w.tabs_horizontal ? 1 : 0
	motion := settings.motion_resolve(&app.settings, .Chrome)
	chrome := settings.motion_duration(&app.settings, motion)
	docked := w.tabs_horizontal ? was_docked : rail_docked(w)
	tabs := w.workspace == nil ? 0 : len(w.workspace.tabs)
	if !app.animations || !motion.on || chrome <= 0 || !docked || tabs == 0 || !pane_motion_has_drawn(w) {
		w.flip = {value = target, target = target}
		return
	}
	if w.tabs_horizontal {w.flip_rail, w.flip_reserve = area, reserve}
	layout, _ := tab_flip_rail_layout(w)
	items := tab_flip_items(layout)
	per_tab := f32(chrome) * TAB_FLIP_PER_TAB * f32(tabs + 1)
	duration := time.Duration(clamp(per_tab, f32(chrome) * TAB_FLIP_SHORTEST, f32(chrome) * TAB_FLIP_LONGEST))
	from := w.flip.value
	ui.motion_target_curve(&w.flip, target, duration, TAB_FLIP_CURVE, true)
	// The rail comes or goes while New tab passes: the last stretch going to the strip, the first coming
	// back. Its motion holds the panes where they are until then.
	rows := items.span > 0 ? 1 - items.footer_height / items.span : 1
	arm := Pane_Chrome_Arm{rail_slides = true}
	if w.tabs_horizontal {
		start := tab_flip_time_at(from < 1 ? (rows - from) / (1 - from) : 1)
		arm.delay = time.Duration(f32(duration) * start)
		arm.duration = duration - arm.delay
		arm.live = PANE_MOTION_RAIL
	} else {
		arm.duration = time.Duration(f32(duration) * tab_flip_time_at(from > 0 ? (from - rows) / from : 1))
	}
	// Never shorter than a quarter of the usual motion, as when the passage reverses with the rail in place.
	arm.duration = max(arm.duration, chrome / 4)
	pane_motion_arm_chrome(w, arm)
}

// Going to the strip, the rail keeps drawing live where it was, its rows rising into the title bar,
// until the motion taking it away has taken it.
tab_flip_rail_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if _, leaving := ui.layout_motion_leaving(&w.pane_motion.moving, PANE_MOTION_RAIL); !leaving {return .Ok}
	layout, ok := tab_flip_rail_layout(w)
	if !ok {return .Ok}
	region := pane_motion_region_begin(w, PANE_MOTION_RAIL, w.flip_rail)
	defer pane_motion_region_end(w, &region)
	if render.push_layer(&w.list, region.shown) != .None {return .Ok}
	ui.draw_rect(&w.list, {rect = region.shown, color = app.theme.tab_bar})
	pane_motion_region_content(w, &region)
	return rail_body_draw(app, w, layout)
}

// One thing passing through the corner: a tab, a group's chip or New tab with the profile chevron. It rests
// in the strip at `left`, `width` wide, its row starts at `row` in the rail before it rises, and it draws
// `shift` from where it rests.
@(private = "file")
Tab_Flip_Piece :: struct {
	kind:        Tab_Flip_Piece_Kind,
	tab:         int,
	run:         Tab_Run,
	left, width: f32,
	row, shift:  f32,
}

@(private = "file")
Tab_Flip_Piece_Kind :: enum u8 {
	Tab,
	Chip,
	New_Tab,
}

// The strip while the tabs change orientation, in place of window_tab_strip_draw: each tab and group chip
// as far out of the workspace chip as its rail row has gone into the title bar, then New tab with the
// profile chevron as far as the rail's footer has. Until a piece starts out it waits behind the one before
// it, and later pieces draw beneath earlier ones, so each comes out from behind the one before it. The
// tabs' positions belong to whichever orientation w has now, so both ends come from their resting layouts.
tab_flip_strip_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	bar := window_tab_bar(app, w)
	layout, ok := tab_flip_rail_layout(w)
	if bar.count == 0 || !ok {return .Ok}
	items := tab_flip_items(layout)
	rise := tab_flip_rise(w, layout)
	strip, rail := tab_layout(app, w, true), tab_layout(nil, w, false)
	pieces := make([dynamic]Tab_Flip_Piece, 0, bar.count + len(strip.runs) + 1, context.temp_allocator)
	run := 0
	for i in 0 ..< min(bar.count, len(strip.places), len(rail.places)) {
		x := bar.x + strip.places[i].slot * bar.tab_width + strip.places[i].offset * w.scale
		row := items.first + rail.places[i].slot * items.row
		for run < len(strip.runs) && strip.runs[run].carried {run += 1}
		if run < len(strip.runs) && strip.runs[run].first == i {
			width := strip.runs[run].width * w.scale
			chip := Tab_Flip_Piece{kind = .Chip, run = strip.runs[run], left = x - width, width = width}
			chip.row = row - items.row
			append(&pieces, chip)
			run += 1
		}
		if !tab_shown(w.workspace, i) {continue}
		append(&pieces, Tab_Flip_Piece{kind = .Tab, tab = i, left = x, width = bar.tab_width, row = row})
	}
	new_tab := ui.tab_new_rect(bar)
	footer := Tab_Flip_Piece{kind = .New_Tab, left = new_tab.x, width = 2 * bar.button_width, row = items.footer}
	append(&pieces, footer)
	previous: f32
	for &piece, i in pieces {
		height := piece.kind == .New_Tab ? items.footer_height : items.row
		gone := tab_flip_gone(items, piece.row, height, rise)
		at := math.round(piece.left - piece.width * (1 - gone))
		if gone <= 0 && i > 0 {at = min(at, previous)}
		piece.shift, previous = at - piece.left, at
	}
	clip := render.Rect{bar.x, 0, max(0, f32(w.width) - bar.x), bar.height}
	for i := len(pieces) - 1; i >= 0; i -= 1 {
		mark := render.draw_mark(&w.list)
		result := tab_flip_piece_draw(app, w, bar, pieces[i])
		render.draw_translate(&w.list, mark, {pieces[i].shift, 0}, clip)
		if result != .Ok {return result}
	}
	return .Ok
}

// Draws `piece` where it rests in the strip, on the title bar's colour, so pieces behind it stay hidden.
@(private = "file")
tab_flip_piece_draw :: proc(
	app: ^App,
	w: ^Window,
	bar: ui.Tab_Bar,
	piece: Tab_Flip_Piece,
) -> render.Build_Status {
	x := piece.left
	if render.push_layer(&w.list, {x, 0, piece.width, bar.height}) != .None {return .Ok}
	ui.draw_rect(&w.list, {rect = {x, 0, piece.width, bar.height}, color = app.theme.tab_bar})
	switch piece.kind {
	case .Chip:
		margin := ui.TAB_CHIP_MARGIN * w.scale
		chip := render.Rect{x + margin, 0, max(0, piece.width - 2 * margin), bar.height}
		return tab_chip_strip_draw(app, w, bar, piece.run, chip)
	case .New_Tab:
		new_tab := tab_control(w, Tab_Chrome_New{})
		hover, press := new_tab.hover.value, new_tab.press.value
		if result := ui.tab_new_draw(&w.list, app.theme, bar, hover, press, w.scale, w.pointer); result != .Ok {
			return result
		}
		chevron := tab_chevron_rect(app, w)
		if render.push_layer(&w.list, chevron) != .None {return .Ok}
		profiles := tab_control(w, Tab_Chrome_Profiles{})
		tile := ui.tab_tile_rect(bar, chevron.x, chevron.width, 0, w.scale)
		_ = ui.icon_button_draw(&w.list, app.theme, tile, .Chevron_Down, profiles.hover.value,
			profiles.press.value, w.scale, w.pointer, ui.ICON_INDICATOR)
		return .Ok
	case .Tab:
	}
	tile, built := tab_tile(app, w, piece.tab)
	if built != .Ok {return built}
	if result := ui.tab_draw(&w.list, &w.ui_text, app.theme, bar, x, tile, 0, 0, w.scale, w.pointer);
	   result != .Ok {return result}
	if piece.tab != w.workspace.selected {return .Ok}
	underline := ui.tab_underline_rect(bar, x, 0, w.scale)
	if render.push_layer(&w.list, {x, 0, bar.tab_width, bar.height}) != .None {return .Ok}
	radius := ui.pill_radius(underline)
	ui.draw_rect(&w.list, {rect = underline, color = app.theme.tab_indicator, radius = radius})
	return .Ok
}
