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

// How many panes the tree shows in its own window; panes in a linked slot show in theirs.
@(require_results)
shown_pane_count :: proc(l: ^Layout) -> int {
	return l.root == INVALID_NODE ? 0 : shown_count(l, l.root)
}

// Whether `slot` is still the marked root of a slot. A move that emptied it leaves a vacant node.
@(require_results)
slot_valid :: proc(l: ^Layout, slot: Node_Id) -> bool {
	return int(slot) < len(l.nodes) && node_linked(l, slot)
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
		pane_settle(&pane)
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
		branch.linked, branch.floating, branch.float = false, false, {}
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
	node_replace(home, parent, slot, root)
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
	return place_pane(l, remaining, pane, direction_of(axis, before)), true
}

// Adds a pane to a slot, so it shows in the slot's window with the panes already there. `target` is a
// pane inside the slot, or INVALID to take an edge of the slot itself. Wrapping the slot's root moves
// the mark to the new split, which keeps every pane under it in the window.
@(require_results)
slot_insert_pane :: proc(
	l: ^Layout,
	slot: Node_Id,
	pane: Pane,
	target: Node_Id,
	direction: Direction,
	root: bool,
) -> (Node_Id, bool) {
	if !slot_valid(l, slot) {return INVALID_NODE, false}
	target_node := target
	if target_node == INVALID_NODE {target_node = slot}
	if int(target_node) >= len(l.nodes) {return INVALID_NODE, false}
	// The slot marks the panes it holds, not each pane; a pane inside it stays plain.
	inserted := pane
	pane_settle(&inserted)
	joins_slot := root || target_node == slot
	if !joins_slot && link_root(l, target_node) != slot {return INVALID_NODE, false}
	if reserve(&l.nodes, len(l.nodes) + 2) != nil {return INVALID_NODE, false}
	// Taking the slot's edge moves its mark to the new split, so the old slot's panes and the added pane
	// all stay in the window.
	return place_pane(l, joins_slot ? slot : target_node, inserted, direction, joins_slot), true
}

// Moves a pane from the same tree into a slot, which may be the one it is already in or another. A pane
// from another slot leaves that slot behind; the pane shows only in the destination window.
@(require_results)
slot_take_pane :: proc(
	l: ^Layout,
	node, slot, target: Node_Id,
	direction: Direction,
	root: bool,
) -> (Node_Id, bool) {
	if !slot_valid(l, slot) || int(node) >= len(l.nodes) {return INVALID_NODE, false}
	pane, is_pane := l.nodes[node].(Pane)
	if !is_pane {return INVALID_NODE, false}
	// Moving within one slot is an arrangement change, which belongs to its window.
	current := link_root(l, node)
	if current == slot {return INVALID_NODE, false}
	if target != INVALID_NODE {
		if int(target) >= len(l.nodes) {return INVALID_NODE, false}
		if !root && link_root(l, target) != slot {return INVALID_NODE, false}
	}
	// A shown pane leaving its tab must leave a pane the tab can still show.
	if current == INVALID_NODE && shown_count(l, l.root) <= 1 {return INVALID_NODE, false}
	if reserve(&l.nodes, len(l.nodes) + 2) != nil {return INVALID_NODE, false}
	if !remove(l, node) {return INVALID_NODE, false}
	added, inserted := slot_insert_pane(l, slot, pane, target, direction, root)
	if !inserted {return INVALID_NODE, false}
	return added, true
}

// Moves a pane from another tree into a slot. Reserve before detaching, so allocation failure leaves
// both trees untouched.
@(require_results)
transfer_pane_to_slot :: proc(
	source, destination: ^Layout,
	node, slot, target: Node_Id,
	direction: Direction,
	root: bool,
) -> (Node_Id, bool) {
	if source == destination || !slot_valid(destination, slot) {return INVALID_NODE, false}
	if int(node) >= len(source.nodes) {return INVALID_NODE, false}
	if target != INVALID_NODE && int(target) >= len(destination.nodes) {
		return INVALID_NODE, false
	}
	pane, is_pane := source.nodes[node].(Pane)
	if !is_pane {return INVALID_NODE, false}
	if target != INVALID_NODE && !root && link_root(destination, target) != slot {
		return INVALID_NODE, false
	}
	// A tab must keep a pane it can show when it still holds linked panes.
	if link_root(source, node) == INVALID_NODE &&
	   shown_count(source, source.root) <= 1 &&
	   pane_count(source) > 1 {return INVALID_NODE, false}
	// Content is a reference owned elsewhere, so it may appear once in a tree.
	if find_content(destination, pane.content) != INVALID_NODE {return INVALID_NODE, false}
	if reserve(&destination.nodes, len(destination.nodes) + 2) != nil {return INVALID_NODE, false}
	if !remove(source, node) {return INVALID_NODE, false}
	destination.next_pane_order += 1
	pane_settle(&pane)
	pane.order = destination.next_pane_order
	added, inserted := slot_insert_pane(destination, slot, pane, target, direction, root)
	if !inserted {return INVALID_NODE, false}
	return added, true
}
