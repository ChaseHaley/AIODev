package layout

import "base:runtime"
import "core:math"

// A floating pane draws above the tiled panes at its own rectangle, so opening, moving or closing it never
// resizes them. Like a linked pane it keeps a slot in the tree, which keeps every walk over a tab whole, and
// the slot takes no space. A pane floated from the tiling keeps its old slot and docks back into it; a new
// floating pane's slot sits beside the whole tree, so it docks along the right edge. See
// src/floating_panes.odin.

Float :: struct {
	// Position and size as fractions of the window work area, so the group follows window resizes.
	bounds:    Rect,
	// Higher draws above. Focus raises a pane; minimizing one restacks it, which orders restores.
	stack:     u64,
	// Hidden behind a capsule. Its program keeps running.
	minimized: bool,
	// Names the group while it floats, through every split and close inside it; nonzero.
	id:        u64,
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
node_float :: proc(l: ^Layout, id: Node_Id) -> (^Float, bool) {
	if int(id) >= len(l.nodes) {return nil, false}
	#partial switch &node in l.nodes[id] {
	case Pane:
		if node.floating {return &node.float, true}
	case Split:
		if node.floating {return &node.float, true}
	}
	return nil, false
}

@(private)
node_set_float :: proc(l: ^Layout, id: Node_Id, floating: bool, value: Float = {}) {
	if int(id) >= len(l.nodes) {return}
	#partial switch &node in l.nodes[id] {
	case Pane:
		node.floating, node.float = floating, floating ? value : Float{}
	case Split:
		node.floating, node.float = floating, floating ? value : Float{}
	}
}

// The marked root of the floating pane group holding `id`, or INVALID_NODE when the pane is tiled.
float_root :: proc(l: ^Layout, id: Node_Id) -> Node_Id {
	if int(id) >= len(l.nodes) {return INVALID_NODE}
	for node := id; node != INVALID_NODE; node = parent_of(l, node) {
		if _, floating := node_float(l, node); floating {return node}
	}
	return INVALID_NODE
}

float_is_root :: proc(l: ^Layout, id: Node_Id) -> bool {
	_, floating := node_float(l, id)
	return floating
}

@(private)
pane_first :: proc(l: ^Layout, id: Node_Id) -> Node_Id {
	if int(id) >= len(l.nodes) {return INVALID_NODE}
	switch node in l.nodes[id] {
	case Vacant:
	case Pane:
		return id
	case Split:
		if pane := pane_first(l, node.first); pane != INVALID_NODE {return pane}
		return pane_first(l, node.second)
	}
	return INVALID_NODE
}

// A pane inside the floating group holding `id`, for focus and capsule restoration.
float_pane :: proc(l: ^Layout, id: Node_Id) -> Node_Id {
	root := float_root(l, id)
	return root == INVALID_NODE ? INVALID_NODE : pane_first(l, root)
}

@(private)
pane_order_first :: proc(l: ^Layout, id: Node_Id) -> u64 {
	switch node in l.nodes[id] {
	case Vacant:
		return max(u64)
	case Pane:
		return node.order
	case Split:
		return min(pane_order_first(l, node.first), pane_order_first(l, node.second))
	}
	return max(u64)
}

float_order :: proc(l: ^Layout, id: Node_Id) -> u64 {
	root := float_root(l, id)
	return root == INVALID_NODE ? max(u64) : pane_order_first(l, root)
}

// Whether the node is a pane the tiling shows, outside any linked or floating slot.
@(private)
pane_tiled :: proc(l: ^Layout, node: Node_Id) -> bool {
	if int(node) >= len(l.nodes) {return false}
	_, pane := l.nodes[node].(Pane)
	return pane && float_root(l, node) == INVALID_NODE && link_root(l, node) == INVALID_NODE
}

// A pane that joins a tree by a move arrives tiled and shown.
@(private)
pane_settle :: proc(pane: ^Pane) {
	pane.linked, pane.floating, pane.float = false, false, {}
}

@(private)
focus_valid :: proc(l: ^Layout, node: Node_Id) -> bool {
	if int(node) >= len(l.nodes) {return false}
	if _, pane := l.nodes[node].(Pane); !pane || link_root(l, node) != INVALID_NODE {return false}
	root := float_root(l, node)
	if root == INVALID_NODE {return true}
	floating, _ := node_float(l, root)
	return !floating.minimized
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
	return float_root(l, node) != INVALID_NODE
}

float_of :: proc(l: ^Layout, node: Node_Id) -> (Float, bool) {
	root := float_root(l, node)
	if root == INVALID_NODE {return {}, false}
	floating, _ := node_float(l, root)
	return floating^, true
}

float_rect :: proc(l: ^Layout, node: Node_Id, area: Rect) -> (Rect, bool) {
	floating, ok := float_of(l, node)
	if !ok {return {}, false}
	b := float_bounds_clamp(floating.bounds)
	return Rect {
		math.round(area.x + b.x * area.width),
		math.round(area.y + b.y * area.height),
		math.round(b.width * area.width),
		math.round(b.height * area.height),
	}, true
}

// Adds a floating pane above the tree. The tiled panes keep their places, focus and any zoom.
@(require_results)
float_new :: proc(l: ^Layout, content: Content, bounds: Rect) -> (Node_Id, runtime.Allocator_Error) {
	if l.root == INVALID_NODE {return INVALID_NODE, .Invalid_Argument}
	if err := reserve(&l.nodes, len(l.nodes) + 2); err != nil {return INVALID_NODE, err}
	l.next_pane_order += 1
	l.next_float_stack += 1
	l.next_float_id += 1
	added := allocate_node(
		l,
		Pane {
			content = content,
			order = l.next_pane_order,
			floating = true,
			float = {bounds = float_bounds_clamp(bounds), stack = l.next_float_stack, id = l.next_float_id},
		},
	)
	l.root = allocate_node(l, Split{axis = .Horizontal, ratio = 0.5, first = l.root, second = added})
	return added, nil
}

// Floats a tiled pane above the others, or docks its whole floating group back into the slot. Floating
// takes the slot out of the tiling, so the tiling must keep another pane to show.
@(require_results)
set_floating :: proc(l: ^Layout, node: Node_Id, floating: bool, bounds: Rect = {}) -> bool {
	if int(node) >= len(l.nodes) {return false}
	if _, pane := l.nodes[node].(Pane); !pane {return false}
	root := float_root(l, node)
	if floating {
		if root != INVALID_NODE || !pane_tiled(l, node) || l.root == INVALID_NODE ||
		   shown_count(l, l.root) <= 1 {return false}
		l.next_float_stack += 1
		l.next_float_id += 1
		node_set_float(
			l,
			node,
			true,
			{bounds = float_bounds_clamp(bounds), stack = l.next_float_stack, id = l.next_float_id},
		)
		// Focus stays on the lifted pane; behind it is the tiled pane last focused, or its neighbour.
		if l.focus == node && !pane_tiled(l, l.tiled_focus) {
			sibling, _, _, _, _ := placement(l, node)
			l.tiled_focus = first_shown(l, sibling)
		}
	} else {
		if root == INVALID_NODE {return false}
		node_set_float(l, root, false)
	}
	panes_changed(l)
	links_repair(l)
	return true
}

@(require_results)
float_set_bounds :: proc(l: ^Layout, node: Node_Id, bounds: Rect) -> bool {
	root := float_root(l, node)
	if root == INVALID_NODE {return false}
	floating, _ := node_float(l, root)
	clamped := float_bounds_clamp(bounds)
	if floating.bounds == clamped {return false}
	floating.bounds = clamped
	return true
}

// Hides a floating group behind one capsule, or shows it again. Focus on a group that hides returns to
// the tiled pane it came from. A shown group goes to the top.
@(require_results)
float_minimize :: proc(l: ^Layout, node: Node_Id, minimized: bool) -> bool {
	root := float_root(l, node)
	if root == INVALID_NODE {return false}
	floating, _ := node_float(l, root)
	if floating.minimized == minimized {return false}
	floating.minimized = minimized
	l.next_float_stack += 1
	floating.stack = l.next_float_stack
	if minimized && float_root(l, l.focus) == root {l.focus = focus_behind(l)}
	return true
}

// Moves focus to a pane, remembering the tiled pane a floating group was opened over. A floating group
// comes to the top and out of its capsule; the result reports the presentation change.
focus_set :: proc(l: ^Layout, node: Node_Id) -> (floats_changed: bool) {
	if int(node) >= len(l.nodes) {return false}
	if _, pane := l.nodes[node].(Pane); !pane {return false}
	if pane_tiled(l, node) {
		l.tiled_focus = node
	} else if pane_tiled(l, l.focus) {
		l.tiled_focus = l.focus
	}
	if root := float_root(l, node); root != INVALID_NODE {
		floating, _ := node_float(l, root)
		if floating.minimized {floating.minimized, floats_changed = false, true}
		if floating.stack != l.next_float_stack {
			l.next_float_stack += 1
			floating.stack, floats_changed = l.next_float_stack, true
		}
	}
	l.focus = node
	return
}

@(private)
float_next :: proc(
	l: ^Layout,
	after_stack: u64,
	after_index: int,
	minimized: Maybe(bool) = nil,
) -> (Node_Id, u64) {
	found := INVALID_NODE
	best_stack := max(u64)
	best_index := max(int)
	wanted, filtered := minimized.?
	for _, i in l.nodes {
		floating, ok := node_float(l, Node_Id(i))
		if !ok || (filtered && floating.minimized != wanted) {continue}
		if floating.stack < after_stack || (floating.stack == after_stack && i <= after_index) {continue}
		if floating.stack < best_stack || (floating.stack == best_stack && i < best_index) {
			found, best_stack, best_index = Node_Id(i), floating.stack, i
		}
	}
	return found, best_stack
}

@(private)
float_place :: proc(l: ^Layout, id: Node_Id, area: Rect, gap: f32, group: u64, out: ^[dynamic]Pane_Rect) {
	switch node in l.nodes[id] {
	case Vacant:
	case Pane:
		if !node.linked {append(out, Pane_Rect{id, node.content, area, node.order, true, group})}
	case Split:
		p := partition(area, node.axis, node.ratio, gap)
		float_place(l, node.first, p.first, gap, group, out)
		float_place(l, node.second, p.second, gap, group, out)
	}
}

// The part of a float's frame its panes fill, below the `header` strip that moves, minimizes, docks and
// closes the float. The rest of the frame belongs to the float header too.
float_content_rect :: proc(frame: Rect, header: f32) -> Rect {
	h := min(header, frame.height)
	return {frame.x, frame.y + h, frame.width, frame.height - h}
}

// Appends every shown floating group, bottom first, and every pane inside it.
floats_place :: proc(l: ^Layout, area: Rect, gap, header: f32, out: ^[dynamic]Pane_Rect) {
	stack: u64
	index := -1
	for {
		root, next_stack := float_next(l, stack, index, false)
		if root == INVALID_NODE {return}
		rect, _ := float_rect(l, root, area)
		floating, _ := node_float(l, root)
		float_place(l, root, float_content_rect(rect, header), gap, floating.id, out)
		stack, index = next_stack, int(root)
	}
}

@(private)
float_place_dividers :: proc(l: ^Layout, id: Node_Id, area: Rect, gap: f32, out: ^[dynamic]Divider) {
	if split, ok := l.nodes[id].(Split); ok {
		p := partition(area, split.axis, split.ratio, gap)
		append(out, Divider{id, split.axis, area, p.bar})
		float_place_dividers(l, split.first, p.first, gap, out)
		float_place_dividers(l, split.second, p.second, gap, out)
	}
}

// Appends dividers inside every shown floating group, bottom groups first.
floats_dividers :: proc(l: ^Layout, area: Rect, gap, header: f32, out: ^[dynamic]Divider) {
	stack: u64
	index := -1
	for {
		root, next_stack := float_next(l, stack, index, false)
		if root == INVALID_NODE {return}
		rect, _ := float_rect(l, root, area)
		float_place_dividers(l, root, float_content_rect(rect, header), gap, out)
		stack, index = next_stack, int(root)
	}
}

// The floating pane to show or hide next: the most recently minimized one when `minimized`, otherwise the
// topmost shown one; INVALID_NODE when there is none.
float_latest :: proc(l: ^Layout, minimized: bool) -> Node_Id {
	found := INVALID_NODE
	best: u64
	for _, i in l.nodes {
		floating, ok := node_float(l, Node_Id(i))
		if !ok || floating.minimized != minimized {continue}
		if found == INVALID_NODE || floating.stack > best {found, best = Node_Id(i), floating.stack}
	}
	return found == INVALID_NODE ? INVALID_NODE : pane_first(l, found)
}

// How many floating groups are shown and how many are minimized.
float_counts :: proc(l: ^Layout) -> (shown, minimized: int) {
	for _, i in l.nodes {
		floating, ok := node_float(l, Node_Id(i))
		if !ok {continue}
		if floating.minimized {minimized += 1} else {shown += 1}
	}
	return
}

// Continues stacking above the highest saved floating group, once an imported tree holds them, and names
// any group that came without a name.
@(private)
float_stack_restore :: proc(l: ^Layout) {
	for _, i in l.nodes {
		if floating, ok := node_float(l, Node_Id(i)); ok {
			l.next_float_stack = max(l.next_float_stack, floating.stack)
			l.next_float_id = max(l.next_float_id, floating.id)
		}
	}
	for _, i in l.nodes {
		if floating, ok := node_float(l, Node_Id(i)); ok && floating.id == 0 {
			l.next_float_id += 1
			floating.id = l.next_float_id
		}
	}
}
