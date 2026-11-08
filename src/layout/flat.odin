package layout

import "base:runtime"
import "core:math"

// Copies, saved layouts and other trees built outside this package go through the procedures here, which
// keep the node representation, focus order, stacking and detached-group invariants inside the package.

// An exact copy of `l` in `allocator`, with room to add a pane without growing. A trial changes a copy to
// measure a change without making it.
@(require_results)
clone :: proc(l: ^Layout, allocator := context.allocator) -> (Layout, runtime.Allocator_Error) {
	copied := l^
	nodes, err := make([dynamic]Node, len(l.nodes), len(l.nodes) + 2, allocator)
	if err != nil {return {}, err}
	copy(nodes[:], l.nodes[:])
	copied.nodes = nodes
	return copied, nil
}

// One node of a tree flattened root first: a split comes before its first subtree, which comes before its
// second, and names both by index, so the first pane under any node is the first pane at or after it.
// `linked` and `floating` mark the root of a linked slot or a floating group.
Flat_Node :: struct {
	split:         bool,
	axis:          Axis,
	ratio:         f32,
	first, second: int,
	content:       Content,
	linked:        bool,
	floating:      bool,
	float:         Float,
}

// Appends the tree in flat form and returns the index of its focused pane, 0 when focus is elsewhere.
// False for a tree that has lost its shape.
@(require_results)
flatten :: proc(l: ^Layout, out: ^[dynamic]Flat_Node) -> (focus: int, ok: bool) {
	ok = flatten_node(l, l.root, out, &focus) >= 0
	return
}

@(private)
flatten_node :: proc(l: ^Layout, id: Node_Id, out: ^[dynamic]Flat_Node, focus: ^int) -> int {
	if int(id) >= len(l.nodes) {return -1}
	index := len(out)
	switch node in l.nodes[id] {
	case Vacant:
		return -1
	case Pane:
		flat := Flat_Node {
			content  = node.content,
			linked   = node.linked,
			floating = node.floating,
			float    = node.float,
		}
		append(out, flat)
		if id == l.focus {focus^ = index}
	case Split:
		flat := Flat_Node {
			split    = true,
			axis     = node.axis,
			ratio    = node.ratio,
			linked   = node.linked,
			floating = node.floating,
			float    = node.float,
		}
		append(out, flat)
		first := flatten_node(l, node.first, out, focus)
		second := flatten_node(l, node.second, out, focus)
		if first < 0 || second < 0 {return -1}
		out[index].first, out[index].second = first, second
	}
	return index
}

// Rebuilds `l` from flat nodes; node i of the tree is flat node i, so the caller can find each pane again.
// Every node must be reached exactly once from the root at 0, so cycles, shared children and orphans fail,
// as do unknown content kinds and axes and NaN ratios. Ratios and floating bounds are brought into range,
// focus order follows the flat order, and focus starts on `focus` or else the first pane. A linked or
// floating group holds no other group, a slot holds only `linkable` content, and a tree left with no shown
// pane takes its detached panes back. A failure frees the nodes it allocated.
@(require_results)
unflatten :: proc(
	l: ^Layout,
	flat: []Flat_Node,
	focus: int,
	zoomed: bool,
	linkable: bit_set[Content_Kind],
	allocator := context.allocator,
) -> bool {
	count := len(flat)
	if count == 0 {return false}
	visited, visited_error := make([]bool, count, context.temp_allocator)
	if visited_error != nil {return false}
	nodes, nodes_error := make([dynamic]Node, count, allocator)
	if nodes_error != nil {return false}
	l^ = {nodes = nodes}
	if !unflatten_node(l, flat, 0, visited, linkable, false, false) {
		destroy(l)
		return false
	}
	for reached in visited {if !reached {destroy(l); return false}}
	l.root = 0
	focused := focus
	if focused < 0 || focused >= count || flat[focused].split {
		for node, i in flat {if !node.split {focused = i; break}}
	}
	l.focus = Node_Id(focused)
	l.zoomed = zoomed
	float_stack_restore(l)
	links_repair(l)
	return true
}

@(private, require_results)
unflatten_node :: proc(
	l: ^Layout,
	flat: []Flat_Node,
	index: int,
	visited: []bool,
	linkable: bit_set[Content_Kind],
	in_slot, in_float: bool,
) -> bool {
	if index < 0 || index >= len(flat) || visited[index] {return false}
	visited[index] = true
	node := flat[index]
	if !node.split {
		if node.content.kind > max(Content_Kind) {return false}
		l.next_pane_order += 1
		// A pane inside a linked or floating group cannot introduce another detached group.
		floating := node.floating && !in_slot && !in_float && !node.linked
		linked := node.linked && !in_slot && !in_float && node.content.kind in linkable
		l.nodes[index] = Pane {
			content  = node.content,
			order    = l.next_pane_order,
			linked   = linked,
			floating = floating,
			float    = floating ? float_import(node.float) : {},
		}
		return true
	}
	if node.axis != .Horizontal && node.axis != .Vertical {return false}
	if math.is_nan(node.ratio) {return false}
	// A linked or floating slot holds no nested slots; only linkable content can have a linked window.
	floating := node.floating && !in_slot && !in_float && !node.linked
	linked := node.linked && !in_slot && !in_float && !floating
	nested_slot, nested_float := in_slot || linked, in_float || floating
	if !unflatten_node(l, flat, node.first, visited, linkable, nested_slot, nested_float) ||
	   !unflatten_node(l, flat, node.second, visited, linkable, nested_slot, nested_float) {
		return false
	}
	if linked {
		linked = contents_in(l, Node_Id(node.first), linkable) && contents_in(l, Node_Id(node.second), linkable)
	}
	l.nodes[index] = Split {
		axis     = node.axis,
		ratio    = split_share_clamp(node.ratio),
		first    = Node_Id(node.first),
		second   = Node_Id(node.second),
		linked   = linked,
		floating = floating,
		float    = floating ? float_import(node.float) : {},
	}
	return true
}

@(private)
float_import :: proc(saved: Float) -> Float {
	return {bounds = float_bounds_clamp(saved.bounds), stack = saved.stack, minimized = saved.minimized}
}

// Whether every pane under `id` shows content of a kind in `kinds`.
@(private)
contents_in :: proc(l: ^Layout, id: Node_Id, kinds: bit_set[Content_Kind]) -> bool {
	switch node in l.nodes[id] {
	case Vacant:
	case Pane:
		return node.content.kind in kinds
	case Split:
		return contents_in(l, node.first, kinds) && contents_in(l, node.second, kinds)
	}
	return true
}
