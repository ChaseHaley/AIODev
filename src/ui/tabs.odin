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
	// The pane the mark stands for, 0 when unknown: two marks that look alike still stand for different panes.
	pane:  u64,
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

// A tab's label turning to the pane focus moved to (WORK-483): its marks ride a small sphere that spins along
// the move, the front mark going round away from `toward` and back, the way the old title leaves, while the
// mark behind comes round from the side `toward` points to, to the front; and the old title slides out of its
// line while the new one slides in from that side.
Tab_Turn :: struct {
	turning:  bool,
	// The label turned away from: its title and marks, drawn as the tile's own are.
	title:    string,
	badge:    Tab_Badge,
	behind:   Tab_Badge,
	// Eased from 0 to 1, so it may overshoot.
	progress: f32,
	// A unit step along x or y: the side the pane focus moved to lies on, which the new title and the mark
	// coming to the front enter from.
	toward:   [2]f32,
	// Where the old title starts, in title lines from its place: away from zero when a turn took over from
	// another part way through.
	start:    [2]f32,
}

// The sphere the marks ride, as how far a mark swings out along the move halfway round, in DIPs.
TAB_SPIN_RADIUS :: f32(6)
// How much smaller and dimmer a mark is on the far side of the sphere, against its resting self.
TAB_SPIN_SHRINK :: f32(0.35)
TAB_SPIN_DIM :: f32(0.6)
// How far beyond the badge column the spinning marks may draw, in DIPs, short of the title's gap.
TAB_SPIN_MARGIN :: f32(3)
// The room above and below the title's line that sliding titles keep, in DIPs.
TAB_TURN_LINE_PAD :: f32(2)

// Where the old and new titles draw at `turn`'s progress, in pixels from their place, for a title line of
// `size`.
tab_turn_offsets :: proc(turn: Tab_Turn, size: [2]f32) -> (leaving, entering: [2]f32) {
	p := turn.progress
	return (turn.start * (1 - p) - turn.toward * p) * size, turn.toward * (1 - p) * size
}

// Where a tab's marks rest in the leading column of `tile`: the front mark and, in a stack, the one behind.
// A single mark rests at the column's left at full size; its back is where a stack's would be.
tab_mark_places :: proc(tile: render.Rect, stacked: bool, scale: f32) -> (front, back: render.Rect) {
	left := tile.x + CONTROL_INSET * scale
	top := tile.y + (tile.height - ICON_BUTTON * scale) / 2
	size := TAB_STACK_MARK * scale
	back = {left, top, size, size}
	if !stacked {return {left, top, ICON_BUTTON * scale, ICON_BUTTON * scale}, back}
	return {left + TAB_STACK_OFFSET.x * scale, top + TAB_STACK_OFFSET.y * scale, size, size}, back
}

// One mark of a turning label: where it rests before and after, how it gets there, and where
// tab_spin_sample puts it.
Tab_Spin_Mark :: struct {
	badge:    Tab_Badge,
	from, to: render.Rect,
	// 1 goes from the front round the sphere away from `toward` to the back, -1 comes from the back round the
	// side `toward` points to, to the front, 0 stays on its side of the sphere.
	path:     f32,
	// 1 front or -1 back, for a mark that stays on its side.
	side:     f32,
	fade_in:  bool,
	fade_out: bool,
	rect:     render.Rect,
	opacity:  f32,
	// 1 at the front of the sphere, -1 at the back.
	depth:    f32,
}

// The marks of `t`'s turn at its progress, farthest first, so drawing them in order puts the nearest on top.
// A mark in both stacks travels from its old place to its new one: the front mark round the sphere to the
// back and the one behind round to the front when they trade places. A mark only in the new stack comes in
// from the hidden back of the sphere, fading in, and one only in the old stack goes out to it, fading away.
// Marks for the same pane (or, when no pane is known, that look alike) count as the same mark, so marks that
// do not change keep still; two panes whose marks look alike still trade places.
tab_spin_marks :: proc(tile: render.Rect, t: Tab_Tile, scale: f32) -> (marks: [4]Tab_Spin_Mark, count: int) {
	turn := t.turn
	old_stacked, new_stacked := tab_badge_shown(turn.behind), tab_badge_shown(t.behind)
	old_front, old_back := tab_mark_places(tile, old_stacked, scale)
	new_front, new_back := tab_mark_places(tile, new_stacked, scale)
	front_used, back_used := !tab_badge_shown(turn.badge), !old_stacked
	add :: proc(marks: ^[4]Tab_Spin_Mark, count: ^int, mark: Tab_Spin_Mark) {
		marks[count^] = mark
		count^ += 1
	}
	if tab_badge_shown(t.badge) {
		switch {
		case !front_used && t.badge == turn.badge:
			add(&marks, &count, {badge = t.badge, from = old_front, to = new_front, side = 1})
			front_used = true
		case !back_used && t.badge == turn.behind:
			add(&marks, &count, {badge = t.badge, from = old_back, to = new_front, path = -1})
			back_used = true
		case:
			add(&marks, &count, {badge = t.badge, from = old_back, to = new_front, path = -1, fade_in = true})
		}
	}
	if new_stacked {
		switch {
		case !back_used && t.behind == turn.behind:
			add(&marks, &count, {badge = t.behind, from = old_back, to = new_back, side = -1})
			back_used = true
		case !front_used && t.behind == turn.badge:
			add(&marks, &count, {badge = t.behind, from = old_front, to = new_back, path = 1})
			front_used = true
		case:
			add(&marks, &count, {badge = t.behind, from = new_back, to = new_back, side = -1, fade_in = true})
		}
	}
	if !front_used {
		add(&marks, &count, {badge = turn.badge, from = old_front, to = new_back, path = 1, fade_out = true})
	}
	if !back_used {
		add(&marks, &count, {badge = turn.behind, from = old_back, to = old_back, side = -1, fade_out = true})
	}
	for &mark in marks[:count] {tab_spin_sample(&mark, turn, scale)}
	// Farthest first; at most four, so insertion sort.
	for i in 1 ..< count {
		for j := i; j > 0 && marks[j].depth < marks[j - 1].depth; j -= 1 {
			marks[j], marks[j - 1] = marks[j - 1], marks[j]
		}
	}
	return
}

// Places `mark` at `turn`'s progress. The sphere has turned half a revolution at the end; a mark on its way
// round swings out along the move by the sphere's radius halfway, shrinking and dimming toward the far side.
@(private = "file")
tab_spin_sample :: proc(mark: ^Tab_Spin_Mark, turn: Tab_Turn, scale: f32) {
	mix :: proc(a, b, t: f32) -> f32 {return a + (b - a) * t}
	angle := math.PI * clamp(turn.progress, 0, 1)
	travel := (1 - math.cos(angle)) / 2
	swing := math.sin(angle)
	centre := [2]f32 {
		mix(mark.from.x + mark.from.width / 2, mark.to.x + mark.to.width / 2, travel),
		mix(mark.from.y + mark.from.height / 2, mark.to.y + mark.to.height / 2, travel),
	}
	size := mix(mark.from.width, mark.to.width, travel)
	mark.opacity = 1
	mark.depth = mark.side
	if mark.path != 0 {
		mark.depth = mark.path * math.cos(angle)
		centre -= mark.path * TAB_SPIN_RADIUS * scale * swing * turn.toward
		away := (1 - mark.depth) / 2 * swing
		size *= 1 - TAB_SPIN_SHRINK * away
		mark.opacity = 1 - TAB_SPIN_DIM * away
	}
	if mark.fade_in {mark.opacity *= travel}
	if mark.fade_out {mark.opacity *= 1 - travel}
	mark.rect = {centre.x - size / 2, centre.y - size / 2, size, size}
}

// Draws the badge in the leading icon column of `tile`, stacked over the mark behind it when the tab
// has one. While the label turns, its marks spin round as tab_spin_marks places them, inside the column,
// the others kept clear of the nearest by the stack's gap as the mark behind is at rest.
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
	marks, count := tab_spin_marks(tile, t, scale)
	if count == 0 {return .Ok}
	current := list.layers[len(list.layers) - 1]
	margin := TAB_SPIN_MARGIN * scale
	left := tile.x + CONTROL_INSET * scale
	column := render.Rect{left - margin, tile.y, TAB_BADGE_COLUMN * scale + 2 * margin, tile.height}
	column = rect_within(column, current.clip)
	// The cut-out shrinks with a fading mark, so a mark coming or going leaves no hole where it is not seen.
	top := marks[count - 1]
	gap := TAB_STACK_GAP * scale
	reach := top.opacity
	cut := render.Rect {
		top.rect.x - gap + (top.rect.width + 2 * gap) * (1 - reach) / 2,
		top.rect.y - gap + (top.rect.height + 2 * gap) * (1 - reach) / 2,
		(top.rect.width + 2 * gap) * reach,
		(top.rect.height + 2 * gap) * reach,
	}
	right, bottom := column.x + column.width, column.y + column.height
	beside := [4]render.Rect {
		{column.x, column.y, cut.x - column.x, column.height},
		{cut.x + cut.width, column.y, right - cut.x - cut.width, column.height},
		{cut.x, column.y, cut.width, cut.y - column.y},
		{cut.x, cut.y + cut.height, cut.width, bottom - cut.y - cut.height},
	}
	for mark, i in marks[:count] {
		if mark.opacity <= 0 {continue}
		if i == count - 1 || cut.width <= 0 {
			result := tab_spin_mark_draw(list, text, theme, mark, column, ink, scale)
			if result != .Ok {return result}
			continue
		}
		for clip in beside {
			if clip.width <= 0 || clip.height <= 0 {continue}
			result := tab_spin_mark_draw(list, text, theme, mark, rect_within(clip, column), ink, scale)
			if result != .Ok {return result}
		}
	}
	_ = render.push_layer(list, current.clip, current.radius)
	return .Ok
}

// Draws one spinning mark in `clip`: at the size it comes to rest at, then scaled to its place and faded.
@(private = "file")
tab_spin_mark_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	mark: Tab_Spin_Mark,
	clip: render.Rect,
	ink: render.Color,
	scale: f32,
) -> render.Build_Status {
	if render.push_layer(list, clip) != .None {return .Ok}
	at := render.draw_mark(list)
	base := mark.to.width
	r := mark.rect
	centre := [2]f32{r.x + r.width / 2, r.y + r.height / 2}
	area := render.Rect{centre.x - base / 2, centre.y - base / 2, base, base}
	if result := tab_mark_draw(list, text, theme, area, mark.badge, ink, base / scale, scale); result != .Ok {
		return result
	}
	render.draw_scale(list, at, centre, r.width / base)
	fade_draw(list, at, {opacity = mark.opacity})
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
	front, back := tab_mark_places(tile, tab_badge_shown(behind), scale)
	if !tab_badge_shown(behind) {return tab_mark_draw(list, text, theme, front, badge, ink, ICON_BUTTON, scale)}
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
// clipped to the line: sideways across the box's width, up or down a line's height, which keeps the titles
// clear of the tab's edges and underline. A title fades only where titles fade at rest, toward the box's
// right end (see tab_title_slid).
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
	line := render.Rect{box.x, baseline - text.ascent - pad, box.width, text.line_height + 2 * pad}
	current := list.layers[len(list.layers) - 1]
	if render.push_layer(list, rect_within(line, current.clip)) != .None {return .Ok}
	leaving, entering := tab_turn_offsets(t.turn, {line.width, line.height})
	if result := tab_title_slid(list, text, t.turn.title, box, baseline, color, leaving); result != .Ok {
		return result
	}
	if result := tab_title_slid(list, text, t.title, box, baseline, color, entering); result != .Ok {
		return result
	}
	_ = render.push_layer(list, current.clip, current.radius)
	return .Ok
}

// Draws `title` moved by `offset` in a `box` that stays put, faded as the box fades titles at rest: a title
// too long for the box over the box's last fifth, as draw_fading_text does, and a shorter one from its own
// end or that last fifth, whichever is further right, to the box's end, so where it rests it does not fade.
// Moved left, it draws on to fill the box.
@(private = "file")
tab_title_slid :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	title: string,
	box: render.Rect,
	baseline: f32,
	color: render.Color,
	offset: [2]f32,
) -> render.Build_Status {
	mark := render.draw_mark(list)
	if result := draw_fading_text(text, list, title, box.x, baseline, color, max(0, box.width - offset.x));
	   result != .Ok {return result}
	width := text_width(text, title)
	fade := width > box.width ? box.width * 0.8 : max(box.width * 0.8, width)
	for &glyph in list.glyphs[mark.glyphs:] {
		glyph.rect.x += offset.x
		glyph.rect.y += offset.y
		glyph.flags |= render.GLYPH_FADE
		glyph.fade_start, glyph.fade_end = box.x + fade, box.x + box.width
	}
	return .Ok
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
