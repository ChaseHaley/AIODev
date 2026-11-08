package ui

import "aio:render"
import "core:math"
import "core:time"

// A layout's items easing together, as one motion, from where they were drawn to where the layout now
// puts them. The layout itself changes at once: callers keep hit testing, sizing and input on the new
// rectangles and only draw at layout_motion_rect.
Layout_Motion :: struct {
	progress: Motion,
	items:    [dynamic]Layout_Item,
}

// Where an item is, under a key that names the same item before and after the change.
Layout_Place :: struct {
	key:  u64,
	rect: render.Rect,
}

@(private)
Layout_Item :: struct {
	key:      u64,
	from, to: render.Rect,
	// The layout no longer has the item; it collapses away while the others take its place.
	leaving:  bool,
}

// Edges this close are the same edge; layout rounds to whole pixels.
@(private = "file")
EDGE_TOLERANCE :: f32(0.5)

layout_motion_active :: proc(m: ^Layout_Motion) -> bool {
	return motion_active(m.progress)
}

layout_motion_update :: proc(m: ^Layout_Motion, frame: Frame_Time) -> bool {
	changed := motion_update(&m.progress, frame)
	if changed && !motion_active(m.progress) {clear(&m.items)}
	return changed
}

// Where `key` draws now: between its start and its target, each moving edge on a whole pixel so lines
// stay sharp and edges that do not move exactly where they were; `target` when the key is not moving.
layout_motion_rect :: proc(m: ^Layout_Motion, key: u64, target: render.Rect) -> render.Rect {
	if !motion_active(m.progress) {return target}
	edge :: proc(from, to, t: f32) -> f32 {return from == to ? to : math.round(math.lerp(from, to, t))}
	for item in m.items {
		if item.key != key {continue}
		a, b, t := item.from, item.to, m.progress.value
		left, top := edge(a.x, b.x, t), edge(a.y, b.y, t)
		right := edge(a.x + a.width, b.x + b.width, t)
		bottom := edge(a.y + a.height, b.y + b.height, t)
		return {left, top, max(0, right - left), max(0, bottom - top)}
	}
	return target
}

// Starts moving every item of `targets` from where `shown` drew it before the layout changed; `shown`
// should come from layout_motion_rect, so a change during a motion continues from the drawn rectangles.
// An item that was not drawn grows out of the edge it shares with the drawn item it overlaps most, as a
// new split pane opens from the side of the pane it divides; one that overlaps nothing appears in place.
// An item with no target leaves the same way in reverse, collapsing onto the edge it shares with the item
// that takes its place; the caller draws what it last showed there (see layout_motion_rect). Disabled
// animations, or nothing to move, end any motion.
layout_motion_begin :: proc(
	m: ^Layout_Motion,
	shown, targets: []Layout_Place,
	duration: time.Duration,
	easing: Easing,
	enabled: bool,
) {
	clear(&m.items)
	moving := false
	if enabled {
		for target in targets {
			from, found := layout_place_rect(shown, target.key)
			if !found {from = layout_enter_rect(shown, target.rect)}
			if _, err := append(&m.items, Layout_Item{target.key, from, target.rect, false}); err != nil {
				// Without room to remember the motion, the layout takes its place at once.
				moving = false
				break
			}
			moving ||= from != target.rect
		}
		for place in shown {
			if _, kept := layout_place_rect(targets, place.key); kept {continue}
			to := layout_enter_rect(targets, place.rect)
			if _, err := append(&m.items, Layout_Item{place.key, place.rect, to, true}); err != nil {
				moving = false
				break
			}
			moving ||= to != place.rect
		}
	}
	if !moving {
		layout_motion_stop(m)
		return
	}
	m.progress = {}
	motion_target(&m.progress, 1, duration, easing, true)
}

// The layout changed under a running motion for a reason of its own, such as a window resize: items keep
// their starts and progress and head for their new targets, and leaving items keep leaving. New items
// appear in place.
layout_motion_retarget :: proc(m: ^Layout_Motion, targets: []Layout_Place) {
	if !motion_active(m.progress) {return}
	kept := 0
	for item in m.items {
		if item.leaving {
			m.items[kept] = item
			kept += 1
		} else if to, found := layout_place_rect(targets, item.key); found {
			m.items[kept] = {item.key, item.from, to, false}
			kept += 1
		}
	}
	resize(&m.items, kept)
	for target in targets {
		if layout_item_moving(m.items[:kept], target.key) {continue}
		if _, err := append(&m.items, Layout_Item{target.key, target.rect, target.rect, false}); err != nil {
			layout_motion_stop(m)
			return
		}
	}
}

// Every item lands on its target now.
layout_motion_stop :: proc(m: ^Layout_Motion) {
	clear(&m.items)
	m.progress = {}
}

layout_motion_destroy :: proc(m: ^Layout_Motion) {
	delete(m.items)
	m^ = {}
}

@(private = "file")
layout_place_rect :: proc(places: []Layout_Place, key: u64) -> (render.Rect, bool) {
	for place in places {
		if place.key == key {return place.rect, true}
	}
	return {}, false
}

@(private = "file")
layout_item_moving :: proc(items: []Layout_Item, key: u64) -> bool {
	for item in items {
		if item.key == key {return true}
	}
	return false
}

// The zero-size rectangle a new item grows from, or a leaving one collapses to: on the edge of `target`
// that lies on an edge of the item in `shown` it overlaps most, across the axis where the two differ.
@(private = "file")
layout_enter_rect :: proc(shown: []Layout_Place, target: render.Rect) -> render.Rect {
	best: render.Rect
	best_area := f32(0)
	for place in shown {
		r := place.rect
		width := min(r.x + r.width, target.x + target.width) - max(r.x, target.x)
		height := min(r.y + r.height, target.y + target.height) - max(r.y, target.y)
		if width > 0 && height > 0 && width * height > best_area {best, best_area = r, width * height}
	}
	if best_area == 0 {return target}
	same :: proc(a, b: f32) -> bool {return abs(a - b) <= EDGE_TOLERANCE}
	across_x := same(target.y, best.y) && same(target.y + target.height, best.y + best.height)
	across_y := same(target.x, best.x) && same(target.x + target.width, best.x + best.width)
	r := target
	if across_x && !across_y {
		if same(target.x + target.width, best.x + best.width) {r.x = target.x + target.width}
		else if !same(target.x, best.x) {r.x = target.x + target.width / 2}
		r.width = 0
	} else if across_y && !across_x {
		if same(target.y + target.height, best.y + best.height) {r.y = target.y + target.height}
		else if !same(target.y, best.y) {r.y = target.y + target.height / 2}
		r.height = 0
	}
	return r
}
