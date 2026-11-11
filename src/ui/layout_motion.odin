package ui

import "aio:render"
import "aio:settings"
import "core:math"
import "core:time"

// A layout's items easing together, as one motion, from where they were drawn to where the layout now
// puts them. The layout itself changes at once: callers keep hit testing, sizing and input on the new
// rectangles and only draw at layout_motion_rect.
Layout_Motion :: struct {
	progress: Motion,
	items:    [dynamic]Layout_Item,
}

// Where an item is, under a key that names the same item before and after the change. Items move within
// their container (a window's tiling, one floating group): a new or leaving item only ever takes its edge
// from items in the same container.
Layout_Place :: struct {
	key:       u64,
	rect:      render.Rect,
	container: u64,
}

// Where an item that enters comes from, or where one that leaves goes, in place of the edge it shares with
// a neighbour in its container: a float growing out of its capsule, or shrinking into it.
Layout_Hint :: struct {
	key:  u64,
	rect: render.Rect,
}

// How an entering or leaving item presents itself this frame (see layout_motion_look): `amount` runs from
// 0, hidden, to 1, fully shown, along the motion's curve and may overshoot either end; `from` is the edge
// the item would grow from or collapse onto, which a sliding item moves across.
Layout_Look :: struct {
	effect: settings.Motion_Effect,
	amount: f32,
	from:   render.Rect,
}

@(private)
Layout_Item :: struct {
	key:       u64,
	from, to:  render.Rect,
	// The layout no longer has the item; it collapses away beneath `successor`, the item taking its place,
	// or, sent away by a hint, on its own.
	leaving:   bool,
	successor: Maybe(u64),
	// An entering or leaving item with an effect other than .Edge stays at one rectangle and presents
	// itself by layout_motion_look instead, against `edge`, where .Edge would grow or collapse it.
	effect:    settings.Motion_Effect,
	edge:      render.Rect,
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
// that takes its place; the caller draws what it last showed there (see layout_motion_rect). A hint for a
// key replaces either edge with its rectangle. Entering and leaving items without a hint take `enter` and
// `leave`: any effect but .Edge keeps them at their target or shown rectangle, and layout_motion_look says
// how to present them. Disabled animations, or nothing to move, end any motion.
layout_motion_begin :: proc(
	m: ^Layout_Motion,
	shown, targets: []Layout_Place,
	duration: time.Duration,
	curve: settings.Motion_Curve,
	enabled: bool,
	hints: []Layout_Hint = nil,
	enter: settings.Motion_Effect = .Edge,
	leave: settings.Motion_Effect = .Edge,
) {
	clear(&m.items)
	moving := false
	if enabled {
		for target in targets {
			item := Layout_Item{key = target.key, to = target.rect}
			found, hinted: bool
			item.from, found = layout_place_rect(shown, target.key)
			if !found {item.from, hinted = layout_hint_rect(hints, target.key)}
			if !found && !hinted {
				item.edge, _ = layout_enter_rect(shown, target)
				item.from, item.effect = item.edge, enter
				if enter != .Edge {item.from = target.rect}
			}
			if _, err := append(&m.items, item); err != nil {
				// Without room to remember the motion, the layout takes its place at once.
				moving = false
				break
			}
			moving ||= item.from != item.to || item.effect != .Edge
		}
		for place in shown {
			if _, kept := layout_place_rect(targets, place.key); kept {continue}
			item := Layout_Item{key = place.key, from = place.rect, leaving = true}
			hinted: bool
			item.to, hinted = layout_hint_rect(hints, place.key)
			if !hinted {
				item.edge, item.successor = layout_enter_rect(targets, place)
				// Nothing takes its place, so there is nothing for it to collapse beneath.
				if item.successor == nil {continue}
				item.to, item.effect = item.edge, leave
				if leave != .Edge {item.to = place.rect}
			}
			if _, err := append(&m.items, item); err != nil {
				moving = false
				break
			}
			moving ||= item.from != item.to || item.effect != .Edge
		}
	}
	if !moving {
		layout_motion_stop(m)
		return
	}
	m.progress = {}
	motion_target_curve(&m.progress, 1, duration, curve, true)
}

// How `key` presents itself now: an entering or leaving item with an effect other than .Edge, shown by
// the amount the motion has reached; any other item, or none, fully shown as itself.
layout_motion_look :: proc(m: ^Layout_Motion, key: u64) -> Layout_Look {
	if !motion_active(m.progress) {return {.Edge, 1, {}}}
	for item in m.items {
		if item.key != key {continue}
		if item.effect == .Edge {break}
		t := m.progress.value
		return {item.effect, item.leaving ? 1 - t : t, item.edge}
	}
	return {.Edge, 1, {}}
}

// The layout changed under a running motion for a reason of its own, such as a window resize: moving items
// keep their starts and progress and head for their new targets, items standing still stay still at their
// new rectangles, and leaving items keep leaving. New items appear in place.
layout_motion_retarget :: proc(m: ^Layout_Motion, targets: []Layout_Place) {
	if !motion_active(m.progress) {return}
	kept := 0
	for item in m.items {
		if item.leaving {
			m.items[kept] = item
			kept += 1
		} else if to, found := layout_place_rect(targets, item.key); found {
			// One presenting itself by its effect, or standing still, keeps to its rectangle, now the new one.
			from := item.effect == .Edge && item.from != item.to ? item.from : to
			m.items[kept] = {item.key, from, to, false, nil, item.effect, item.edge}
			kept += 1
		}
	}
	resize(&m.items, kept)
	for target in targets {
		if layout_item_moving(m.items[:kept], target.key) {continue}
		item := Layout_Item{key = target.key, from = target.rect, to = target.rect}
		if _, err := append(&m.items, item); err != nil {
			layout_motion_stop(m)
			return
		}
	}
}

// Whether `key` is leaving, and the item it collapses beneath: draw it just before that item so it sits in
// the same container and stacking position. A leaving item sent away by a hint has none.
layout_motion_leaving :: proc(m: ^Layout_Motion, key: u64) -> (successor: Maybe(u64), leaving: bool) {
	if !motion_active(m.progress) {return nil, false}
	for item in m.items {
		if item.key == key && item.leaving {return item.successor, true}
	}
	return nil, false
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
layout_hint_rect :: proc(hints: []Layout_Hint, key: u64) -> (render.Rect, bool) {
	for hint in hints {
		if hint.key == key {return hint.rect, true}
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

// The zero-size rectangle a new item grows from, or a leaving one collapses to: on the edge of `item` that
// lies on an edge of the item of its container in `others` it overlaps most, across the axis where the
// two differ; with that item's key, or nil when it overlaps nothing there.
@(private = "file")
layout_enter_rect :: proc(others: []Layout_Place, item: Layout_Place) -> (render.Rect, Maybe(u64)) {
	target := item.rect
	best: render.Rect
	best_key: Maybe(u64)
	best_area := f32(0)
	for place in others {
		if place.container != item.container {continue}
		r := place.rect
		width := min(r.x + r.width, target.x + target.width) - max(r.x, target.x)
		height := min(r.y + r.height, target.y + target.height) - max(r.y, target.y)
		if width > 0 && height > 0 && width * height > best_area {
			best, best_key, best_area = r, place.key, width * height
		}
	}
	if best_area == 0 {return target, nil}
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
	return r, best_key
}
