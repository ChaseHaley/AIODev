package main

import "aio:layout"
import "aio:render"
import "aio:ui"
import "core:math"
import "core:time"

// When a split or a close changes a tab's panes, they ease from where they were drawn to their new
// rectangles together, each within its container, the tiling or its floating group; nothing here depends
// on which. A new pane opens out of the side of the pane it divides, and a closed pane keeps showing its
// last frame while it collapses under the neighbour taking its place. Only drawing moves: grids, hit
// targets and input take the new layout at once (a closed pane's session ends at once too), and each
// pane's content keeps its new size, anchored to the moving frame's corner and clipped to it.
Pane_Motion :: struct {
	moving: ui.Layout_Motion,
	// The tab layout the window last placed; placing another one, a tab switch, never moves.
	tree:   ^layout.Layout,
	// The next placement of this tab layout moves: a split or close changed it.
	armed:  ^layout.Layout,
	// The bars between tiled panes as drawn; see pane_bars.
	bars:   [dynamic]layout.Edge,
	// Where each pane's drawing sits in the window's last frame, so a closed pane can keep it.
	drawn:  [dynamic]Pane_Drawn,
	// Closed panes collapsing away, each drawn from a copy of its last frame.
	ghosts: [dynamic]Pane_Ghost,
}

@(private = "file")
Pane_Drawn :: struct {
	key:      u64,
	from, to: render.Draw_Mark,
	rect:     layout.Rect,
}

@(private = "file")
Pane_Ghost :: struct {
	// The closed pane, and the pane it collapses beneath.
	key, successor: u64,
	// Where the copied drawing was drawn, and the glyph atlas it refers to.
	rect:           layout.Rect,
	list:           render.Draw_List,
	atlas:          u64,
}

PANE_MOTION_DURATION :: 160 * time.Millisecond

// The next relayout of w's visible tab eases its panes to their new places.
pane_motion_arm :: proc(w: ^Window) {
	w.pane_motion.armed = window_tree(w)
}

pane_motion_destroy :: proc(w: ^Window) {
	ui.layout_motion_destroy(&w.pane_motion.moving)
	pane_ghosts_clear(&w.pane_motion)
	delete(w.pane_motion.bars)
	delete(w.pane_motion.drawn)
	delete(w.pane_motion.ghosts)
}

pane_motion_animating :: proc(w: ^Window) -> bool {
	return ui.layout_motion_active(&w.pane_motion.moving)
}

pane_motion_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	changed := ui.layout_motion_update(&w.pane_motion.moving, frame)
	if changed {pane_bars_refresh(app, w)}
	if !pane_motion_animating(w) {pane_ghosts_clear(&w.pane_motion)}
	return changed
}

// Where a pane draws this frame; its layout rectangle when nothing moves.
pane_motion_rect :: proc(w: ^Window, pane: layout.Pane_Rect) -> layout.Rect {
	r := pane.rect
	key := pane_motion_key(pane.content)
	shown := ui.layout_motion_rect(&w.pane_motion.moving, key, {r.x, r.y, r.width, r.height})
	return {shown.x, shown.y, shown.width, shown.height}
}

// The panes as drawn now, collected before a relayout replaces w.panes.
@(require_results)
pane_motion_shown :: proc(w: ^Window) -> []ui.Layout_Place {
	return pane_motion_places(w, true)
}

// After a relayout placed w.panes: an armed change of the same tab starts the motion from `shown`, any
// other change of that tab carries a running motion to the new rectangles, and another tab stops it.
pane_motion_placed :: proc(app: ^App, w: ^Window, shown: []ui.Layout_Place) {
	m := &w.pane_motion
	tree := window_tree(w)
	armed := m.armed != nil && m.armed == tree && m.tree == tree
	m.armed = nil
	defer m.tree = tree
	if m.tree != tree {
		ui.layout_motion_stop(&m.moving)
		pane_ghosts_clear(m)
		return
	}
	targets := pane_motion_places(w, false)
	if !armed {
		ui.layout_motion_retarget(&m.moving, targets)
		return
	}
	pane_ghosts_clear(m)
	ui.layout_motion_begin(&m.moving, shown, targets, PANE_MOTION_DURATION, .Decelerate, app.animations)
	if !pane_motion_animating(w) {return}
	for place in shown {
		successor, leaving := ui.layout_motion_successor(&m.moving, place.key)
		if leaving {pane_ghost_capture(app, w, place.key, successor)}
	}
}

// Notes where build_frame drew a pane, from `from` to the list's end.
pane_motion_drawn :: proc(w: ^Window, pane: layout.Pane_Rect, from: render.Draw_Mark) {
	key, to := pane_motion_key(pane.content), render.draw_mark(&w.list)
	// Without room to note it, a closed pane collapses as background instead.
	_, _ = append(&w.pane_motion.drawn, Pane_Drawn{key, from, to, pane_motion_rect(w, pane)})
}

// A new frame starts recording where the panes draw.
pane_motion_drawn_reset :: proc(w: ^Window) {
	clear(&w.pane_motion.drawn)
}

// Draws the last frame of each closed pane collapsing beneath `pane`, just before `pane` draws, so it sits
// in the same container and stacking position: moved with its collapsing rectangle and clipped to it.
pane_ghosts_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	m := &w.pane_motion
	if len(m.ghosts) == 0 {return}
	atlas := render.atlas_generation(app.device)
	key := pane_motion_key(pane.content)
	for &ghost in m.ghosts {
		if ghost.successor != key {continue}
		shown := ui.layout_motion_rect(&m.moving, ghost.key, {})
		if shown.width < 1 || shown.height < 1 || ghost.atlas != atlas {continue}
		mark := render.draw_mark(&w.list)
		if render.append_list(&w.list, &ghost.list) != .None {return}
		offset := [2]f32{math.round(shown.x - ghost.rect.x), math.round(shown.y - ghost.rect.y)}
		render.draw_translate(&w.list, mark, offset, shown)
	}
}

// Copies what the last frame drew for the pane under `key` before its drawing is lost.
@(private = "file")
pane_ghost_capture :: proc(app: ^App, w: ^Window, key, successor: u64) {
	m := &w.pane_motion
	for drawn in m.drawn {
		if drawn.key != key {continue}
		ghost := Pane_Ghost {
			key       = key,
			successor = successor,
			rect      = drawn.rect,
			list      = render.draw_list_init(),
			atlas     = render.atlas_generation(app.device),
		}
		if render.draw_list_copy(&ghost.list, &w.list, drawn.from, drawn.to) != .None {
			render.draw_list_destroy(&ghost.list)
			return
		}
		if _, err := append(&m.ghosts, ghost); err != nil {render.draw_list_destroy(&ghost.list)}
		return
	}
}

@(private = "file")
pane_ghosts_clear :: proc(m: ^Pane_Motion) {
	for &ghost in m.ghosts {render.draw_list_destroy(&ghost.list)}
	clear(&m.ghosts)
}

@(private = "file")
pane_motion_places :: proc(w: ^Window, drawn: bool) -> []ui.Layout_Place {
	places := make([dynamic]ui.Layout_Place, 0, len(w.panes), context.temp_allocator)
	for pane in w.panes {
		r := drawn ? pane_motion_rect(w, pane) : pane.rect
		place := ui.Layout_Place{pane_motion_key(pane.content), {r.x, r.y, r.width, r.height}, pane.group}
		append(&places, place)
	}
	return places[:]
}

@(private = "file")
pane_motion_key :: proc(content: layout.Content) -> u64 {
	return u64(content.kind) << 32 | u64(content.id)
}

// What a pane draws while its frame moves away from its layout rectangle: the frame, header and
// outline at `shown`, and the content laid out at the layout rectangle, then moved with the frame's
// corner and clipped to the frame.
Pane_Frame :: struct {
	shown:  layout.Rect,
	offset: [2]f32,
	moving: bool,
}

pane_frame :: proc(w: ^Window, pane: layout.Pane_Rect) -> Pane_Frame {
	shown := pane_motion_rect(w, pane)
	if shown == pane.rect {return {shown = shown}}
	// Whole pixels, so text drawn at the layout rectangle stays sharp.
	offset := [2]f32{math.round(shown.x - pane.rect.x), math.round(shown.y - pane.rect.y)}
	return {shown, offset, true}
}

// Moves the content drawn since `mark` with the frame and keeps it inside the frame.
pane_frame_content :: proc(w: ^Window, f: Pane_Frame, mark: render.Draw_Mark) {
	if !f.moving {return}
	render.draw_translate(&w.list, mark, f.offset, {f.shown.x, f.shown.y, f.shown.width, f.shown.height})
}

// The bars between tiled panes as drawn: the layout's dividers, or while panes move, the strips between
// drawn panes whose facing sides are one gap apart, so a gapless layout keeps one shared border between
// neighbours throughout. Panes that are not neighbours yet draw their own full outlines.
pane_bars :: proc(w: ^Window) -> []layout.Edge {
	return w.pane_motion.bars[:]
}

// Rebuilds pane_bars after the dividers or the drawn panes changed; the buffer is kept, so drawing
// allocates nothing.
pane_bars_refresh :: proc(app: ^App, w: ^Window) {
	bars := &w.pane_motion.bars
	clear(bars)
	if !pane_motion_animating(w) {
		for d in w.dividers {append(bars, layout.Edge{d.axis, d.rect})}
		return
	}
	gap := window_gap(app, w)
	for a in w.panes {
		if a.floating {continue}
		ra := pane_motion_rect(w, a)
		for b in w.panes {
			if b.floating {continue}
			rb := pane_motion_rect(w, b)
			if abs(rb.x - (ra.x + ra.width) - gap) < 0.5 {
				top, bottom := max(ra.y, rb.y), min(ra.y + ra.height, rb.y + rb.height)
				if bottom > top {pane_bar_add(bars, {.Horizontal, {ra.x + ra.width, top, gap, bottom - top}})}
			}
			if abs(rb.y - (ra.y + ra.height) - gap) < 0.5 {
				left, right := max(ra.x, rb.x), min(ra.x + ra.width, rb.x + rb.width)
				if right > left {pane_bar_add(bars, {.Vertical, {left, ra.y + ra.height, right - left, gap}})}
			}
		}
	}
}

// Joins a strip to a collinear one it meets or crosses, so a bar beside several panes stays whole.
@(private = "file")
pane_bar_add :: proc(bars: ^[dynamic]layout.Edge, bar: layout.Edge) {
	for &other in bars {
		if other.axis != bar.axis {continue}
		a, b := other.rect, bar.rect
		if bar.axis == .Horizontal {
			if a.x != b.x || b.y > a.y + a.height + a.width || a.y > b.y + b.height + b.width {continue}
			top, bottom := min(a.y, b.y), max(a.y + a.height, b.y + b.height)
			other.rect.y, other.rect.height = top, bottom - top
		} else {
			if a.y != b.y || b.x > a.x + a.width + a.height || a.x > b.x + b.width + b.height {continue}
			left, right := min(a.x, b.x), max(a.x + a.width, b.x + b.width)
			other.rect.x, other.rect.width = left, right - left
		}
		return
	}
	append(bars, bar)
}
