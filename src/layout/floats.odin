package layout

import "base:runtime"
import "core:math"

// A floating pane draws above the tiled panes at its own rectangle, so opening, moving or closing it never
// resizes them. Like a linked pane it keeps a slot in the tree, which keeps every walk over a tab whole, and
// the slot takes no space. A pane floated from the tiling keeps its old slot and docks back into it; a new
// floating pane's slot sits beside the whole tree, so it docks along the right edge. See
// src/floating_panes.odin.

Float :: struct {
	// Position and size as fractions of the tab's content area, so the pane follows window resizes.
	bounds:    Rect,
	// Higher draws above. Focus raises a pane; minimizing one restacks it, which orders restores.
	stack:     u64,
	// Hidden behind a capsule. Its program keeps running.
	minimized: bool,
}

// The smallest share of the content area either side of a floating pane may take.
FLOAT_MINIMUM :: f32(0.08)

// Keeps a pane inside the content area and at least FLOAT_MINIMUM on each side.
float_bounds_clamp :: proc(bounds: Rect) -> Rect {
	b := bounds
	if math.is_nan(b.x) || math.is_nan(b.y) || math.is_nan(b.width) || math.is_nan(b.height) {
		return {0.2, 0.2, 0.6, 0.6}
	}
	b.width = clamp(b.width, FLOAT_MINIMUM, 1)
	b.height = clamp(b.height, FLOAT_MINIMUM, 1)
	b.x = clamp(b.x, 0, 1 - b.width)
	b.y = clamp(b.y, 0, 1 - b.height)
	return b
}

@(private)
pane_floating :: proc(l: ^Layout, node: Node_Id) -> bool {
	if int(node) >= len(l.nodes) {return false}
	pane, ok := l.nodes[node].(Pane)
	return ok && pane.floating
}

// Whether the node is a pane the tiling shows, outside any linked slot.
@(private)
pane_tiled :: proc(l: ^Layout, node: Node_Id) -> bool {
	if int(node) >= len(l.nodes) {return false}
	pane, ok := l.nodes[node].(Pane)
	return ok && !pane.floating && link_root(l, node) == INVALID_NODE
}

// A pane that joins a tree by a move arrives tiled and shown.
@(private)
pane_settle :: proc(pane: ^Pane) {
	pane.linked, pane.floating, pane.float = false, false, {}
}

@(private)
float_clear :: proc(l: ^Layout, node: Node_Id) {
	if pane, ok := &l.nodes[node].(Pane); ok {pane.floating, pane.float = false, {}}
}

@(private)
focus_valid :: proc(l: ^Layout, node: Node_Id) -> bool {
	if int(node) >= len(l.nodes) {return false}
	pane, ok := l.nodes[node].(Pane)
	if !ok || link_root(l, node) != INVALID_NODE {return false}
	return !pane.floating || !pane.float.minimized
}

// Where focus goes when a floating pane gives it up: the tiled pane it came from while that is still
// shown, otherwise the first shown pane.
@(private)
focus_behind :: proc(l: ^Layout) -> Node_Id {
	if pane_tiled(l, l.tiled_focus) {return l.tiled_focus}
	return l.root == INVALID_NODE ? INVALID_NODE : first_shown(l, l.root)
}

// The focused pane when it is tiled, otherwise the tiled pane focus returns to. Zoom and the single-pane
// views show this pane, whichever pane floats above it.
focus_tiled :: proc(l: ^Layout) -> Node_Id {
	if pane_tiled(l, l.focus) {return l.focus}
	return focus_behind(l)
}

is_floating :: proc(l: ^Layout, node: Node_Id) -> bool {
	return pane_floating(l, node)
}

float_of :: proc(l: ^Layout, node: Node_Id) -> (Float, bool) {
	if !pane_floating(l, node) {return {}, false}
	return l.nodes[node].(Pane).float, true
}

// Adds a floating pane above the tree. The tiled panes keep their places, focus and any zoom.
@(require_results)
float_new :: proc(l: ^Layout, content: Content, bounds: Rect) -> (Node_Id, runtime.Allocator_Error) {
	if l.root == INVALID_NODE {return INVALID_NODE, .Invalid_Argument}
	if err := reserve(&l.nodes, len(l.nodes) + 2); err != nil {return INVALID_NODE, err}
	l.next_pane_order += 1
	l.next_float_stack += 1
	added := allocate_node(
		l,
		Pane {
			content = content,
			order = l.next_pane_order,
			floating = true,
			float = {bounds = float_bounds_clamp(bounds), stack = l.next_float_stack},
		},
	)
	l.root = allocate_node(l, Split{axis = .Horizontal, ratio = 0.5, first = l.root, second = added})
	return added, nil
}

// Floats a tiled pane above the others, or docks a floating one back into its slot. Floating takes a pane
// out of the tiling, so the tiling must keep another pane to show, and a pane in a linked window stays there.
@(require_results)
set_floating :: proc(l: ^Layout, node: Node_Id, floating: bool, bounds: Rect = {}) -> bool {
	if int(node) >= len(l.nodes) {return false}
	pane, ok := l.nodes[node].(Pane)
	if !ok || pane.floating == floating {return false}
	if floating {
		if !pane_tiled(l, node) || l.root == INVALID_NODE || shown_count(l, l.root) <= 1 {return false}
		l.next_float_stack += 1
		pane.floating, pane.float = true, {bounds = float_bounds_clamp(bounds), stack = l.next_float_stack}
		l.nodes[node] = pane
		// Focus stays on the lifted pane; behind it is the tiled pane last focused, or its neighbour.
		if l.focus == node && !pane_tiled(l, l.tiled_focus) {
			sibling, _, _, _, _ := placement(l, node)
			l.tiled_focus = first_shown(l, sibling)
		}
	} else {
		pane.floating, pane.float = false, {}
	}
	l.nodes[node] = pane
	panes_changed(l)
	links_repair(l)
	return true
}

@(require_results)
float_set_bounds :: proc(l: ^Layout, node: Node_Id, bounds: Rect) -> bool {
	if !pane_floating(l, node) {return false}
	pane := &l.nodes[node].(Pane)
	clamped := float_bounds_clamp(bounds)
	if pane.float.bounds == clamped {return false}
	pane.float.bounds = clamped
	return true
}

// Hides a floating pane behind its capsule, or shows it again. Focus on a pane that hides returns to the
// tiled pane it came from. A shown pane goes to the top.
@(require_results)
float_minimize :: proc(l: ^Layout, node: Node_Id, minimized: bool) -> bool {
	if !pane_floating(l, node) {return false}
	pane := &l.nodes[node].(Pane)
	if pane.float.minimized == minimized {return false}
	pane.float.minimized = minimized
	l.next_float_stack += 1
	pane.float.stack = l.next_float_stack
	if minimized && l.focus == node {l.focus = focus_behind(l)}
	return true
}

// Moves focus to a pane, remembering the tiled pane a floating one was opened over. A floating pane comes
// to the top and out of its capsule; the result reports that change, which only the floats' layout shows.
focus_set :: proc(l: ^Layout, node: Node_Id) -> (floats_changed: bool) {
	if int(node) >= len(l.nodes) {return false}
	pane, ok := &l.nodes[node].(Pane)
	if !ok {return false}
	if pane_tiled(l, node) {
		l.tiled_focus = node
	} else if pane_tiled(l, l.focus) {
		l.tiled_focus = l.focus
	}
	if pane.floating {
		if pane.float.minimized {pane.float.minimized, floats_changed = false, true}
		if pane.float.stack != l.next_float_stack {
			l.next_float_stack += 1
			pane.float.stack, floats_changed = l.next_float_stack, true
		}
	}
	l.focus = node
	return
}

// Appends every shown floating pane, bottom first, with its rectangle inside `area`.
floats_place :: proc(l: ^Layout, area: Rect, out: ^[dynamic]Pane_Rect) {
	start := len(out)
	for node, i in l.nodes {
		pane := node.(Pane) or_continue
		if !pane.floating || pane.float.minimized {continue}
		b := float_bounds_clamp(pane.float.bounds)
		rect := Rect {
			math.round(area.x + b.x * area.width),
			math.round(area.y + b.y * area.height),
			math.round(b.width * area.width),
			math.round(b.height * area.height),
		}
		append(out, Pane_Rect{Node_Id(i), pane.content, rect, pane.order, true})
		// Few panes float at once, so an insertion keeps them in stacking order.
		for j := len(out) - 1; j > start; j -= 1 {
			if float_stack(l, out[j - 1].node) <= float_stack(l, out[j].node) {break}
			out[j - 1], out[j] = out[j], out[j - 1]
		}
	}
}

@(private)
float_stack :: proc(l: ^Layout, node: Node_Id) -> u64 {
	return l.nodes[node].(Pane).float.stack
}


// The floating pane to show or hide next: the most recently minimized one when `minimized`, otherwise the
// topmost shown one; INVALID_NODE when there is none.
float_latest :: proc(l: ^Layout, minimized: bool) -> Node_Id {
	found := INVALID_NODE
	best: u64
	for node, i in l.nodes {
		pane := node.(Pane) or_continue
		if !pane.floating || pane.float.minimized != minimized {continue}
		if found == INVALID_NODE || pane.float.stack > best {found, best = Node_Id(i), pane.float.stack}
	}
	return found
}

// How many floating panes are shown and how many are minimized.
float_counts :: proc(l: ^Layout) -> (shown, minimized: int) {
	for node in l.nodes {
		pane := node.(Pane) or_continue
		if !pane.floating {continue}
		if pane.float.minimized {minimized += 1} else {shown += 1}
	}
	return
}

// Continues stacking above the highest saved floating pane, once a decoded tree holds them.
float_stack_restore :: proc(l: ^Layout) {
	for node in l.nodes {
		pane := node.(Pane) or_continue
		if pane.floating {l.next_float_stack = max(l.next_float_stack, pane.float.stack)}
	}
}
