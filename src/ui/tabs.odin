package ui

import "aio:render"
import "core:math"

// The horizontal title-bar tab strip. It shares the title-bar height so the strip, the workspace
// chip and the caption controls all sit in the same 40 DIP row.
TAB_HEIGHT :: TITLE_BAR_HEIGHT

Tab_Bar :: struct {
	x, width, height, tab_width, button_width: f32,
	// Where the tabs end, which is where the new-tab button starts.
	end:                                       f32,
	count:                                     int,
}

// A strip tab is never wider than this; it shares the strip's room below it.
TAB_MAX_WIDTH :: f32(220)

// The strip spans `width` from `x`. Its `count` tabs show in `slots` places (a folded group's take none) and
// share their width with `incoming` tabs a drag offers, which hold their space without counting as tabs
// yet, and with the `chips` pixels group chips take. Slots -1 is one per tab.
tab_bar_layout :: proc(
	x, width, scale: f32,
	count: int,
	incoming := 0,
	slots := -1,
	chips: f32 = 0,
) -> Tab_Bar {
	bar := Tab_Bar{x = x, end = x, height = TAB_HEIGHT * scale}
	places := (slots < 0 ? count : slots) + incoming
	if count + incoming < 1 {return bar}
	bar.width, bar.count = width, count
	bar.button_width = min(width, TITLE_BUTTON_WIDTH * scale)
	room := max(0, width - bar.button_width - chips)
	bar.tab_width = min(TAB_MAX_WIDTH * scale, room / f32(max(1, places)))
	bar.end = x + f32(places - incoming) * bar.tab_width + chips
	return bar
}

tab_drop_region :: proc(bar: Tab_Bar, width, scale: f32) -> render.Rect {
	return {bar.end, 0, max(0, width - CAPTION_WIDTH * scale - bar.end), bar.height}
}

tab_drop_hit :: proc(bar: Tab_Bar, width, scale, x, y: f32) -> bool {
	r := tab_drop_region(bar, width, scale)
	return r.width > 0 && render.rect_contains(r, x, y)
}

// The new-tab button, just after the last tab.
tab_new_rect :: proc(bar: Tab_Bar) -> render.Rect {
	return {bar.end, 0, bar.button_width, bar.height}
}

// The picture at the start of a tab: a content kind's icon, else the session's program badge.
Tab_Badge :: struct {
	icon:  Icon,
	shell: string,
	atlas: render.Rect,
}

tab_badge_shown :: proc(b: Tab_Badge) -> bool {
	return b.icon != .None || b.shell != "" || b.atlas.width > 0
}

// A tab with several panes stacks two smaller marks: its focused pane's in front, offset right and
// down from the mark behind, which stands for the tab's most telling other pane.
TAB_STACK_MARK :: f32(13)
TAB_STACK_OFFSET :: [2]f32{7, 3}
// The space cut from the mark behind around the one in front.
TAB_STACK_GAP :: f32(1.5)

// Every tab's leading badge column fits a stack, so titles line up whether a tab stacks or not.
// A single mark sits at the column's left, where the mark behind a stack sits.
TAB_BADGE_COLUMN :: TAB_STACK_OFFSET[0] + TAB_STACK_MARK

// What a tab shows in the strip and the rail. Each orientation lays it out with its own geometry.
Tab_Tile :: struct {
	title:        string,
	badge:        Tab_Badge,
	// The mark stacked behind the badge for a tab with several panes; none for a single pane.
	behind:       Tab_Badge,
	status:       Status_Mark,
	status_phase: f32,
	// Tab status indicators are on: the status keeps its place, so titles do not reflow as
	// programs start and stop working.
	status_slot:  bool,
	selected:     bool,
	marked:       bool,
	// The tab's part of its group's tray, transparent for none, closed at the ends in `tray_ends`.
	tray:         render.Color,
	tray_ends:    Tray_Ends,
	tray_state:   Tray_State,
	turn:         Tab_Turn,
}

// A tab's label turning to the pane focus moved to (WORK-483): its marks swivel about the badge column's
// vertical axis, the old face turning away edge on and the new one turning in, while the old title slides out
// of its box and the new one slides in from the side `toward` points to.
Tab_Turn :: struct {
	turning:  bool,
	// The label turned away from: its title and marks, drawn as the tile's own are.
	title:    string,
	badge:    Tab_Badge,
	behind:   Tab_Badge,
	// Eased from 0 to 1, so it may overshoot.
	progress: f32,
	// A unit step along x or y, the side the new title enters from; the old one leaves the other way.
	toward:   [2]f32,
	// Where the old title starts, in title boxes from its place: away from zero when a turn took over from
	// another part way through.
	start:    [2]f32,
}

// How bright a mark seen edge on is, against 1 facing: the turned card catches less light.
TAB_TURN_SHADE :: f32(0.45)
// The fade at each end of the title's box while titles slide across it, in DIPs.
TAB_TURN_FADE :: f32(12)
// The room above and below the title's line that sliding titles keep, in DIPs.
TAB_TURN_LINE_PAD :: f32(2)

// How wide the turning marks draw at `progress`, 1 facing to 0 edge on halfway through.
tab_turn_width :: proc(progress: f32) -> f32 {
	return abs(math.cos(math.PI * clamp(progress, 0, 1)))
}

// Where the old and new titles draw at `turn`'s progress, in pixels from their place, for a title box of
// `size`.
tab_turn_offsets :: proc(turn: Tab_Turn, size: [2]f32) -> (leaving, entering: [2]f32) {
	p := turn.progress
	return (turn.start * (1 - p) - turn.toward * p) * size, turn.toward * (1 - p) * size
}

// Draws the badge in the leading icon column of `tile`, stacked over the mark behind it when the tab
// has one. While the label turns, the face showing (the old marks for the first half, then the new) is
// squeezed about its own centre and shaded as it turns edge on.
tab_badge_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	tile: render.Rect,
	t: Tab_Tile,
	scale: f32,
) -> render.Build_Status {
	ink := t.selected ? theme.tab_active_text : theme.tab_text
	if !t.turn.turning {return tab_marks_draw(list, text, theme, tile, t.badge, t.behind, ink, scale)}
	old := t.turn.progress < 0.5
	front, behind := old ? t.turn.badge : t.badge, old ? t.turn.behind : t.behind
	if !tab_badge_shown(front) {return .Ok}
	current := list.layers[len(list.layers) - 1]
	mark := render.draw_mark(list)
	result := tab_marks_draw(list, text, theme, tile, front, behind, ink, scale)
	if result != .Ok {return result}
	width := tab_turn_width(t.turn.progress)
	face := tab_badge_shown(behind) ? TAB_BADGE_COLUMN : ICON_BUTTON
	render.draw_squeeze(list, mark, tile.x + (CONTROL_INSET + face / 2) * scale, width)
	fade_draw(list, mark, {opacity = TAB_TURN_SHADE + (1 - TAB_TURN_SHADE) * width})
	// A stack's clips were squeezed with it; what follows draws in the tab's own again.
	if len(list.layers) > mark.layers {_ = render.push_layer(list, current.clip, current.radius)}
	return .Ok
}

// Draws `badge` in the leading icon column of `tile`, stacked over `behind` when that shows. The mark
// behind is clipped short of the front mark, so the gap shows whatever lies under the tab: its hover,
// selection or marked fill.
@(private = "file")
tab_marks_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	tile: render.Rect,
	badge, behind: Tab_Badge,
	ink: render.Color,
	scale: f32,
) -> render.Build_Status {
	left := tile.x + CONTROL_INSET * scale
	top := tile.y + (tile.height - ICON_BUTTON * scale) / 2
	if !tab_badge_shown(behind) {
		size := ICON_BUTTON * scale
		return tab_mark_draw(list, text, theme, {left, top, size, size}, badge, ink, ICON_BUTTON, scale)
	}
	size := TAB_STACK_MARK * scale
	back := render.Rect{left, top, size, size}
	front := render.Rect{left + TAB_STACK_OFFSET.x * scale, top + TAB_STACK_OFFSET.y * scale, size, size}
	cut_x := front.x - TAB_STACK_GAP * scale
	cut_y := front.y - TAB_STACK_GAP * scale
	current := list.layers[len(list.layers) - 1]
	// Left of the cut-out, then above it.
	clips := [2]render.Rect {
		{back.x, back.y, cut_x - back.x, back.height},
		{cut_x, back.y, back.x + back.width - cut_x, cut_y - back.y},
	}
	for clip in clips {
		if render.push_layer(list, rect_within(clip, current.clip)) != .None {return .Ok}
		if result := tab_mark_draw(list, text, theme, back, behind, ink, TAB_STACK_MARK, scale);
		   result != .Ok {return result}
	}
	if render.push_layer(list, current.clip, current.radius) != .None {return .Ok}
	return tab_mark_draw(list, text, theme, front, badge, ink, TAB_STACK_MARK, scale)
}

// Draws a tab's title in `box`, centred on its height and fading out at its end when it does not fit. While
// the label turns to another title, the old one slides out of the title's line and the new one slides in,
// both clipped to the line, fading over a short band at either end on the way. The line spans the longer
// title and its fade band, at most the box, so sideways the titles travel their own length rather than the
// whole tab; up or down it is the text's height, which keeps the titles clear of the tab's edges and
// underline.
tab_title_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	t: Tab_Tile,
	box: render.Rect,
	color: render.Color,
	scale: f32,
) -> render.Build_Status {
	baseline := box.y + (box.height - text.line_height) / 2 + text.ascent
	if !t.turn.turning || t.turn.title == t.title {
		return draw_fading_text(text, list, t.title, box.x, baseline, color, box.width)
	}
	pad := TAB_TURN_LINE_PAD * scale
	longer := max(text_width(text, t.turn.title), text_width(text, t.title))
	width := min(box.width, longer + TAB_TURN_FADE * scale)
	line := render.Rect{box.x, baseline - text.ascent - pad, width, text.line_height + 2 * pad}
	current := list.layers[len(list.layers) - 1]
	if render.push_layer(list, rect_within(line, current.clip)) != .None {return .Ok}
	leaving, entering := tab_turn_offsets(t.turn, {line.width, line.height})
	mark := render.draw_mark(list)
	if result := draw_fading_text(text, list, t.turn.title, box.x, baseline, color, box.width);
	   result != .Ok {return result}
	tab_title_slide(list, mark, line, leaving, scale)
	mark = render.draw_mark(list)
	if result := draw_fading_text(text, list, t.title, box.x, baseline, color, box.width); result != .Ok {
		return result
	}
	tab_title_slide(list, mark, line, entering, scale)
	_ = render.push_layer(list, current.clip, current.radius)
	return .Ok
}

// Moves the title glyphs drawn since `mark` by `offset` within `box`, whose ends stay where they fade: a
// glyph in the box's first half fades toward its left end, one in the second half toward its right end,
// keeping the fade a title too long for the box already has there. Sliding up or down fades the title as
// it leaves.
@(private = "file")
tab_title_slide :: proc(
	list: ^render.Draw_List,
	mark: render.Draw_Mark,
	box: render.Rect,
	offset: [2]f32,
	scale: f32,
) {
	band := min(TAB_TURN_FADE * scale, box.width / 4)
	right := box.x + box.width
	for &glyph in list.glyphs[mark.glyphs:] {
		glyph.rect.x += offset.x
		glyph.rect.y += offset.y
		if offset.y != 0 {glyph.color.a *= clamp(1 - abs(offset.y) / max(1, box.height), 0, 1)}
		if offset.x == 0 {continue}
		if glyph.rect.x + glyph.rect.width / 2 < box.x + box.width / 2 {
			glyph.flags |= render.GLYPH_FADE
			glyph.fade_start, glyph.fade_end = box.x + band, box.x
		} else if glyph.flags & render.GLYPH_FADE == 0 {
			glyph.flags |= render.GLYPH_FADE
			glyph.fade_start, glyph.fade_end = right - band, right
		}
	}
}

@(private = "file")
tab_mark_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	area: render.Rect,
	badge: Tab_Badge,
	ink: render.Color,
	size, scale: f32,
) -> render.Build_Status {
	if badge.icon != .None {
		icon_draw(list, badge.icon, area, ink, size, scale)
		return .Ok
	}
	return shell_badge_draw(list, text, theme, area, badge.shell, scale, badge.atlas)
}

// The part of `r` inside `bounds`, empty when they do not overlap.
@(private = "file")
rect_within :: proc(r, bounds: render.Rect) -> render.Rect {
	x := clamp(r.x, bounds.x, bounds.x + bounds.width)
	y := clamp(r.y, bounds.y, bounds.y + bounds.height)
	right := clamp(r.x + r.width, bounds.x, bounds.x + bounds.width)
	bottom := clamp(r.y + r.height, bounds.y, bounds.y + bounds.height)
	return {x, y, right - x, bottom - y}
}

// Draws the status progress along the bottom of `band`, inset from the tile's rounded ends.
tab_progress_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	band: render.Rect,
	status: Status_Mark,
	scale: f32,
) {
	bar := render.Rect{band.x + 8 * scale, band.y, max(0, band.width - 16 * scale), band.height}
	status_progress_draw(list, theme, bar, status, scale)
}

// The selected tab's underline under the tab drawn at `x`, raised by the tab's hover `lift`.
tab_underline_rect :: proc(bar: Tab_Bar, x, lift, scale: f32) -> render.Rect {
	return {x + 10 * scale, 30 * scale - lift, max(0, bar.tab_width - 20 * scale), 2 * scale}
}

// The toolbar-height tile every strip control (tabs, new tab, profiles) draws on, raised by its hover.
tab_tile_rect :: proc(bar: Tab_Bar, x, width, lift, scale: f32) -> render.Rect {
	tile_height := HEIGHT_TOOLBAR * scale
	return {x + 2 * scale, (bar.height - tile_height) / 2 - lift, max(0, width - 4 * scale), tile_height}
}

// Draws a tab at `x`, its place in the strip as it moves.
tab_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	bar: Tab_Bar,
	x: f32,
	t: Tab_Tile,
	hover, pressed, scale: f32,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	width := bar.tab_width
	// The tab's room meets its neighbours' on a whole pixel, so a group's tray runs on through them evenly.
	left := math.round(x)
	room := render.Rect{left, 0, math.round(x + width) - left, bar.height}
	if render.push_layer(list, room) != .None {return .Ok}
	draw_rect(list, {rect = room, color = theme.tab_bar})
	if t.tray.a > 0 {
		y, height := tab_tray_band(bar.height, scale)
		slice := render.Rect{room.x, y, room.width, height}
		if tab_tray_draw(list, slice, t.tray, t.tray_ends, t.tray_state, false, scale) != .None {return .Ok}
	}
	// Every tab rises on hover; the selected tab keeps its pane fill while it moves.
	lift := hover_lift_at(theme, hover, scale)
	tile := tab_tile_rect(bar, x, width, lift, scale)
	radius := RADIUS_CONTROL * scale
	indicator := ICON_INDICATOR * scale
	if lift > 0 {
		if result := hover_shadow_draw(list, theme, tile, radius, hover, scale); result != .None {return .Ok}
	}
	if t.selected {
		draw_rect(list, {rect = tile, color = theme.tab_active, radius = radius})
		draw_rect(list, {rect = tile, color = theme.border, radius = radius, stroke = scale})
	}
	if t.marked && !t.selected {
		draw_rect(list, {rect = tile, color = theme.selection, radius = radius})
		draw_rect(list, {rect = tile, color = theme.accent, radius = radius, stroke = scale})
	}
	fill := theme.hover
	fill.a *= hover
	// A marked tab already carries the selection tint; an opaque paper fill would paint over
	// it, while a translucent dark fill can pass over without hiding it.
	skip_fill := hover_fill_opaque(theme) && t.marked && !t.selected
	if !skip_fill {
		draw_rect(list, {rect = tile, color = fill, radius = radius})
	}
	fill = theme.pressed
	fill.a *= pressed
	draw_rect(list, {rect = tile, color = fill, radius = radius})
	if width <= 16 * scale {return .Ok}
	if close := tab_close_rect(bar, x, scale); close.width > 0 {
		close.y -= lift
		icon_draw(list, .Close, close, theme.tab_text, ICON_INDICATOR, scale)
	}
	icon_width, status_width := f32(0), f32(0)
	if t.status.glyph != .None {
		tab_progress_draw(list, theme, {tile.x, tile.y, tile.width, tile.height - scale}, t.status, scale)
	}
	// Status sits just before Close; a tab narrower than 90 DIPs keeps no empty slot for it.
	if width >= 56 * scale && (t.status_slot && width >= 90 * scale || t.status.glyph != .None) {
		status_width = (ICON_INDICATOR + SPACE_1) * scale
		if t.status.glyph != .None {
			if result := status_glyph_draw(
				list,
				text,
				theme,
				{x + width - 44 * scale, tile.y + (tile.height - indicator) / 2, indicator, indicator},
				t.status,
				t.status_phase,
				scale,
			); result != .Ok {return result}
		}
	}
	// A tab too narrow for both drops the program icon before the status.
	if width >= 72 * scale + status_width && tab_badge_shown(t.badge) {
		icon_width = (TAB_BADGE_COLUMN + SPACE_2) * scale
		if result := tab_badge_draw(list, text, theme, tile, t, scale); result != .Ok {return result}
	}
	title := render.Rect {
		tile.x + CONTROL_INSET * scale + icon_width,
		tile.y,
		max(0, width - 44 * scale - icon_width - status_width),
		tile.height,
	}
	ink := t.selected ? theme.tab_active_text : theme.tab_text
	if result := tab_title_draw(list, text, t, title, ink, scale); result != .Ok {return result}
	if hover > 0 {
		if result := hover_rim_draw(list, theme, tile, radius, hover, scale, pointer, !skip_fill);
		   result != .None {return .Ok}
	}
	return .Ok
}

// Draws the new-tab button after the last tab.
tab_new_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	bar: Tab_Bar,
	hover, pressed, scale: f32,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	r := tab_new_rect(bar)
	if render.push_layer(list, r) != .None {return .Ok}
	draw_rect(list, {rect = r, color = theme.tab_bar})
	lift := hover_lift_at(theme, hover, scale)
	tile := tab_tile_rect(bar, r.x, r.width, lift, scale)
	radius := RADIUS_CONTROL * scale
	if lift > 0 {
		if result := hover_shadow_draw(list, theme, tile, radius, hover, scale); result != .None {return .Ok}
	}
	fill := theme.hover
	fill.a *= hover
	draw_rect(list, {rect = tile, color = fill, radius = radius})
	fill = theme.pressed
	fill.a *= pressed
	draw_rect(list, {rect = tile, color = fill, radius = radius})
	if r.width <= 16 * scale {return .Ok}
	icon_draw(list, .Add, tile, hover > 0 || pressed > 0 ? theme.text : theme.muted, ICON_BUTTON, scale)
	if hover > 0 {
		if result := hover_rim_draw(list, theme, tile, radius, hover, scale, pointer, true, compact = true);
		   result != .None {return .Ok}
	}
	return .Ok
}

// The close button of the tab drawn at `x`; none on a tab too narrow to show it.
tab_close_rect :: proc(bar: Tab_Bar, x, scale: f32) -> render.Rect {
	if bar.count == 0 || bar.tab_width < 56 * scale {return {}}
	button := HEIGHT_COMPACT * scale
	return {x + bar.tab_width - 4 * scale - button, (bar.height - button) / 2, button, button}
}
