package layout

import "base:runtime"

// A slot is the node marked linked: one pane, or a split and every pane under it. Its panes stay in this
// tree, which keeps walks over a tab whole, and a linked window arranges a copy of them in a tree of its own.
// Panes join and leave in the tab's tree; the window's copy holds the arrangement. See src/pane_links.odin.

@(private)
node_linked :: proc(l: ^Layout, id: Node_Id) -> bool {
	#partial switch node in l.nodes[id] {
	case Pane:
		return node.linked
	case Split:
		return node.linked
	}
	return false
}

@(private)
node_set_linked :: proc(l: ^Layout, id: Node_Id, linked: bool) {
	#partial switch &node in l.nodes[id] {
	case Pane:
		node.linked = linked
	case Split:
		node.linked = linked
	}
}

// The slot holding `id`, which may be the slot itself, or INVALID_NODE when this tree shows it.
link_root :: proc(l: ^Layout, id: Node_Id) -> Node_Id {
	if int(id) >= len(l.nodes) {return INVALID_NODE}
	for node := id; node != INVALID_NODE; node = parent_of(l, node) {
		if node_linked(l, node) {return node}
	}
	return INVALID_NODE
}

pane_count :: proc(l: ^Layout) -> int {
	count := 0
	for node in l.nodes {if _, ok := node.(Pane); ok {count += 1}}
	return count
}

find_content :: proc(l: ^Layout, content: Content) -> Node_Id {
	for node, i in l.nodes {
		if pane, ok := node.(Pane); ok && pane.content == content {return Node_Id(i)}
	}
	return INVALID_NODE
}

// Whether two subtrees are arranged identically, ratios included.
same_arrangement :: proc(a: ^Layout, a_id: Node_Id, b: ^Layout, b_id: Node_Id) -> bool {
	switch x in a.nodes[a_id] {
	case Vacant:
		return false
	case Pane:
		y, ok := b.nodes[b_id].(Pane)
		return ok && x.content == y.content
	case Split:
		y, ok := b.nodes[b_id].(Split)
		return(
			ok &&
			x.axis == y.axis &&
			x.ratio == y.ratio &&
			same_arrangement(a, x.first, b, y.first) &&
			same_arrangement(a, x.second, b, y.second) \
		)
	}
	return false
}

// Whether two subtrees hold the same panes, however arranged.
same_panes :: proc(a: ^Layout, a_id: Node_Id, b: ^Layout, b_id: Node_Id) -> bool {
	first := make([dynamic]Content, context.temp_allocator)
	second := make([dynamic]Content, context.temp_allocator)
	contents(a, a_id, &first)
	contents(b, b_id, &second)
	if len(first) != len(second) {return false}
	for content in first {
		found := false
		for other in second {found ||= other == content}
		if !found {return false}
	}
	return true
}

// Copies a subtree into nodes already reserved, without its link mark. With `adopt_order`, a pane `dest`
// already holds keeps its place in `dest`'s focus order and a new one goes last; otherwise each takes
// `source`'s order.
@(private)
node_copy :: proc(dest, source: ^Layout, id: Node_Id, adopt_order: bool) -> Node_Id {
	switch node in source.nodes[id] {
	case Vacant:
	case Pane:
		pane := node
		pane.linked = false
		if adopt_order {
			if existing := find_content(dest, pane.content); existing != INVALID_NODE {
				pane.order = dest.nodes[existing].(Pane).order
			} else {
				dest.next_pane_order += 1
				pane.order = dest.next_pane_order
			}
		} else {
			dest.next_pane_order = max(dest.next_pane_order, pane.order)
		}
		return allocate_node(dest, pane)
	case Split:
		branch := node
		branch.linked = false
		branch.first = node_copy(dest, source, node.first, adopt_order)
		branch.second = node_copy(dest, source, node.second, adopt_order)
		return allocate_node(dest, branch)
	}
	return INVALID_NODE
}

@(private)
node_vacate :: proc(l: ^Layout, id: Node_Id) {
	if branch, ok := l.nodes[id].(Split); ok {
		node_vacate(l, branch.first)
		node_vacate(l, branch.second)
	}
	l.nodes[id] = Vacant{}
}

// Makes `view` a copy of the slot, keeping its focused pane when the slot still holds it.
link_view_load :: proc(view, home: ^Layout, slot: Node_Id) -> runtime.Allocator_Error {
	if err := reserve(&view.nodes, len(home.nodes)); err != nil {return err}
	focused := Content{}
	if int(view.focus) < len(view.nodes) {
		if pane, ok := view.nodes[view.focus].(Pane); ok {focused = pane.content}
	}
	clear(&view.nodes)
	view.next_pane_order = 0
	view.root = node_copy(view, home, slot, false)
	view.focus = find_content(view, focused)
	if view.focus == INVALID_NODE {view.focus = first_shown(view, view.root)}
	panes_changed(view)
	return nil
}

// Replaces the slot with a copy of `view`, returning the slot's node. Failure leaves the tree as it was.
@(require_results)
link_view_store :: proc(home: ^Layout, slot: Node_Id, view: ^Layout) -> (Node_Id, bool) {
	if view.root == INVALID_NODE {return slot, false}
	if reserve(&home.nodes, len(home.nodes) + len(view.nodes)) != nil {return slot, false}
	parent := parent_of(home, slot)
	root := node_copy(home, view, view.root, true)
	node_vacate(home, slot)
	node_set_linked(home, root, true)
	if parent == INVALID_NODE {
		home.root = root
	} else {
		s := home.nodes[parent].(Split)
		if s.first == slot {s.first = root} else {s.second = root}
		home.nodes[parent] = s
	}
	return root, true
}

// Brings one pane out of its slot and back into this tree's view, returning where it now is. The slot's only
// pane returns to its exact place; any other pane sits beside the slot, which takes no space while it stays
// linked, so the pane fills the slot's area.
@(require_results)
link_return_pane :: proc(l: ^Layout, node: Node_Id) -> (Node_Id, bool) {
	slot := link_root(l, node)
	if slot == INVALID_NODE {return node, false}
	if slot == node {return node, set_linked(l, node, false)}
	pane, is_pane := l.nodes[node].(Pane)
	if !is_pane {return node, false}
	sibling, axis, before, _, _ := placement(l, node)
	if !remove(l, node) {return node, false}
	remaining := link_root(l, sibling)
	direction: Direction
	if axis == .Horizontal {direction = before ? .Left : .Right} else {direction = before ? .Up : .Down}
	return place_pane(l, remaining, pane, direction), true
}
