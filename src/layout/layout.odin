package layout

import "base:runtime"
import "core:math"

Content_Kind :: enum u8 {
	Terminal,
	Settings,
}

// A reference to content owned elsewhere; panes display content, they never own it.
Content :: struct {
	kind: Content_Kind,
	id: u32,
}

Axis :: enum u8 {
	Horizontal,
	Vertical,
}

Node_Id :: distinct u32

INVALID_NODE :: Node_Id(max(u32))
Direction :: enum { Left, Right, Up, Down }
Vacant :: struct {}

Divider :: struct {
	node: Node_Id,
	axis: Axis,
	area, rect: Rect,
}

Pane :: struct {
	content: Content,
	order: u64,
}

Split :: struct {
	axis: Axis,
	ratio: f32,
	first, second: Node_Id,
}

Node :: union {
	Vacant,
	Pane,
	Split,
}

Rect :: struct {
	x, y, width, height: f32,
}

Pane_Rect :: struct {
	node: Node_Id,
	content: Content,
	rect: Rect,
	order: u64,
}

Layout :: struct {
	nodes: [dynamic]Node,
	root, focus: Node_Id,
	next_pane_order: u64,
	zoomed: bool,
}

init :: proc(l: ^Layout, content: Content, allocator := context.allocator) -> runtime.Allocator_Error {
	l.nodes = make([dynamic]Node, allocator)
	_, err := append(&l.nodes, Pane{content = content, order = 1})
	l.root, l.focus = 0, 0
	l.next_pane_order = 1
	return err
}

destroy :: proc(l: ^Layout) {
	delete(l.nodes)
	l^ = {}
}

@(private)
allocate_node :: proc(l: ^Layout, value: Node) -> Node_Id {
	for node, i in l.nodes {
		if _, vacant := node.(Vacant); vacant {
			l.nodes[i] = value
			return Node_Id(i)
		}
	}
	id := Node_Id(len(l.nodes))
	append(&l.nodes, value)
	return id
}

@(private)
parent_of :: proc(l: ^Layout, child: Node_Id) -> Node_Id {
	for node, i in l.nodes {
		if s, ok := node.(Split); ok && (s.first == child || s.second == child) {
			return Node_Id(i)
		}
	}
	return INVALID_NODE
}

@(require_results)
split :: proc(
	l: ^Layout,
	node: Node_Id,
	axis: Axis,
	ratio: f32,
	content: Content,
) -> (Node_Id, runtime.Allocator_Error) {
	assert(int(node) < len(l.nodes))
	_, is_pane := l.nodes[node].(Pane)
	assert(is_pane, "only panes can be split")
	if err := reserve(&l.nodes, len(l.nodes)+2); err != nil { return INVALID_NODE, err }
	parent := parent_of(l, node)
	l.next_pane_order += 1
	added := allocate_node(l, Pane{content = content, order = l.next_pane_order})
	branch := allocate_node(l, Split{axis, clamp(ratio, 0.05, 0.95), node, added})
	if parent == INVALID_NODE {
		l.root = branch
	} else {
		s := l.nodes[parent].(Split)
		if s.first == node { s.first = branch } else { s.second = branch }
		l.nodes[parent] = s
	}
	l.zoomed = false
	return added, nil
}

@(require_results)
split_direction :: proc(
	l: ^Layout, node: Node_Id, direction: Direction, ratio: f32, content: Content,
) -> (Node_Id, runtime.Allocator_Error) {
	before := direction == .Left || direction == .Up
	axis: Axis = direction == .Left || direction == .Right ? .Horizontal : .Vertical
	share := clamp(ratio, 0.05, 0.95)
	added, err := split(l, node, axis, before ? share : 1-share, content)
	if err != nil { return INVALID_NODE, err }
	if before {
		parent := parent_of(l, added)
		s := l.nodes[parent].(Split)
		s.first, s.second = s.second, s.first
		l.nodes[parent] = s
	}
	return added, nil
}

@(require_results)
swap :: proc(l: ^Layout, first, second: Node_Id) -> bool {
	if int(first) >= len(l.nodes) || int(second) >= len(l.nodes) || first == second { return false }
	a, a_ok := l.nodes[first].(Pane)
	b, b_ok := l.nodes[second].(Pane)
	if !a_ok || !b_ok { return false }
	a.content, b.content = b.content, a.content
	l.nodes[first], l.nodes[second] = a, b
	if l.focus == first { l.focus = second } else if l.focus == second { l.focus = first }
	return true
}

balance :: proc(l: ^Layout) {
	for node, i in l.nodes {
		if s, ok := node.(Split); ok {
			s.ratio = 0.5
			l.nodes[i] = s
		}
	}
}

@(private)
first_pane :: proc(l: ^Layout, id: Node_Id) -> Node_Id {
	if s, ok := l.nodes[id].(Split); ok { return first_pane(l, s.first) }
	return id
}

@(require_results)
remove :: proc(l: ^Layout, node: Node_Id) -> bool {
	if int(node) >= len(l.nodes) { return false }
	if _, ok := l.nodes[node].(Pane); !ok { return false }
	if l.focus == node { l.zoomed = false }
	parent := parent_of(l, node)
	if parent == INVALID_NODE {
		l.root, l.focus = INVALID_NODE, INVALID_NODE
	} else {
		branch := l.nodes[parent].(Split)
		sibling := branch.first == node ? branch.second : branch.first
		grandparent := parent_of(l, parent)
		if grandparent == INVALID_NODE {
			l.root = sibling
		} else {
			s := l.nodes[grandparent].(Split)
			if s.first == parent { s.first = sibling } else { s.second = sibling }
			l.nodes[grandparent] = s
		}
		if l.focus == node { l.focus = first_pane(l, sibling) }
		l.nodes[parent] = Vacant{}
	}
	l.nodes[node] = Vacant{}
	return true
}

@(require_results)
focus_direction :: proc(rects: []Pane_Rect, focus: Node_Id, direction: Direction) -> Node_Id {
	origin: Rect
	found := false
	for pane in rects {
		if pane.node == focus { origin, found = pane.rect, true; break }
	}
	if !found { return focus }
	best := f32(1e30)
	result := focus
	x, y := origin.x+origin.width/2, origin.y+origin.height/2
	for pane in rects {
		if pane.node == focus { continue }
		r := pane.rect
		dx, dy := r.x+r.width/2-x, r.y+r.height/2-y
		primary, secondary, overlap: f32
		switch direction {
		case .Left: primary, secondary = -dx, abs(dy)
		case .Right: primary, secondary = dx, abs(dy)
		case .Up: primary, secondary = -dy, abs(dx)
		case .Down: primary, secondary = dy, abs(dx)
		}
		if direction == .Left || direction == .Right {
			overlap = min(origin.y+origin.height, r.y+r.height)-max(origin.y, r.y)
		} else {
			overlap = min(origin.x+origin.width, r.x+r.width)-max(origin.x, r.x)
		}
		if primary <= 0 || overlap <= 0 { continue }
		score := primary+secondary
		if score < best { best, result = score, pane.node }
	}
	return result
}

@(require_results)
resize :: proc(l: ^Layout, node: Node_Id, axis: Axis, delta: f32) -> bool {
	parent := parent_of(l, node)
	for parent != INVALID_NODE {
		s := l.nodes[parent].(Split)
		if s.axis == axis {
			s.ratio = clamp(s.ratio+delta, 0.05, 0.95)
			l.nodes[parent] = s
			return true
		}
		parent = parent_of(l, parent)
	}
	return false
}

@(require_results)
resize_pixels :: proc(l: ^Layout, node: Node_Id, axis: Axis, delta: f32, dividers: []Divider) -> bool {
	parent := parent_of(l, node)
	for parent != INVALID_NODE {
		s := l.nodes[parent].(Split)
		if s.axis == axis {
			for d in dividers {
				if d.node != parent { continue }
				available := axis == .Horizontal ? d.area.width-d.rect.width : d.area.height-d.rect.height
				if available <= 0 { return false }
				return resize(l, node, axis, delta/available)
			}
			return false
		}
		parent = parent_of(l, parent)
	}
	return false
}

@(require_results)
focus_cycle :: proc(rects: []Pane_Rect, focus: Node_Id, delta: int) -> Node_Id {
	if len(rects) == 0 { return focus }
	order: u64
	found := false
	for pane in rects {
		if pane.node == focus { order, found = pane.order, true; break }
	}
	if !found { return focus }
	steps := delta%len(rects)
	result := focus
	for steps != 0 {
		forward := steps > 0
		wrap := rects[0]
		candidate: Pane_Rect
		have_candidate := false
		for pane in rects {
			if forward ? pane.order < wrap.order : pane.order > wrap.order { wrap = pane }
			eligible := forward ? pane.order > order : pane.order < order
			if eligible && (!have_candidate || (forward ? pane.order < candidate.order :
				pane.order > candidate.order)) {
				candidate, have_candidate = pane, true
			}
		}
		if !have_candidate { candidate = wrap }
		result, order = candidate.node, candidate.order
		steps += forward ? -1 : 1
	}
	return result
}

compute :: proc(l: ^Layout, area: Rect, gap: f32, out: ^[dynamic]Pane_Rect, honor_zoom := true) {
	clear(out)
	if l.root != INVALID_NODE { place(l, l.zoomed && honor_zoom ? l.focus : l.root, area, gap, out) }
}

@(private)
place :: proc(l: ^Layout, id: Node_Id, area: Rect, gap: f32, out: ^[dynamic]Pane_Rect) {
	switch node in l.nodes[id] {
	case Vacant:
	case Pane:
		append(out, Pane_Rect{id, node.content, area, node.order})
	case Split:
		first, second := area, area
		switch node.axis {
		case .Horizontal:
			available := max(0, area.width - gap)
			first.width = clamp(math.round(available * node.ratio), 0, available)
			second.x = area.x + first.width + gap
			second.width = available - first.width
		case .Vertical:
			available := max(0, area.height - gap)
			first.height = clamp(math.round(available * node.ratio), 0, available)
			second.y = area.y + first.height + gap
			second.height = available - first.height
		}
		place(l, node.first, first, gap, out)
		place(l, node.second, second, gap, out)
	}
}

dividers :: proc(l: ^Layout, area: Rect, gap: f32, out: ^[dynamic]Divider) {
	clear(out)
	if l.root != INVALID_NODE && !l.zoomed { place_dividers(l, l.root, area, gap, out) }
}

@(private)
place_dividers :: proc(l: ^Layout, id: Node_Id, area: Rect, gap: f32, out: ^[dynamic]Divider) {
	if s, ok := l.nodes[id].(Split); ok {
		first, second, bar := area, area, area
		if s.axis == .Horizontal {
			first.width = clamp(math.round(max(0, area.width-gap)*s.ratio), 0, max(0, area.width-gap))
			second.x, second.width = area.x+first.width+gap, max(0, area.width-gap)-first.width
			bar.x, bar.width = area.x+first.width, gap
		} else {
			first.height = clamp(math.round(max(0, area.height-gap)*s.ratio), 0, max(0, area.height-gap))
			second.y, second.height = area.y+first.height+gap, max(0, area.height-gap)-first.height
			bar.y, bar.height = area.y+first.height, gap
		}
		append(out, Divider{id, s.axis, area, bar})
		place_dividers(l, s.first, first, gap, out)
		place_dividers(l, s.second, second, gap, out)
	}
}

@(require_results)
divider_hit_test :: proc(dividers: []Divider, x, y, tolerance: f32) -> (Divider, bool) {
	for d in dividers {
		r := d.rect
		if d.axis == .Horizontal { r.x -= tolerance; r.width += 2*tolerance }
		else { r.y -= tolerance; r.height += 2*tolerance }
		if x >= r.x && x < r.x+r.width && y >= r.y && y < r.y+r.height { return d, true }
	}
	return {}, false
}

@(require_results)
drag_divider :: proc(l: ^Layout, d: Divider, x, y, gap: f32) -> bool {
	if int(d.node) >= len(l.nodes) { return false }
	s, ok := l.nodes[d.node].(Split)
	if !ok { return false }
	available := d.axis == .Horizontal ? d.area.width-gap : d.area.height-gap
	if available <= 0 { return false }
	position := d.axis == .Horizontal ? x-d.area.x-gap/2 : y-d.area.y-gap/2
	s.ratio = clamp(position/available, 0.05, 0.95)
	l.nodes[d.node] = s
	return true
}

hit_test :: proc(rects: []Pane_Rect, x, y: f32) -> (Pane_Rect, bool) {
	for r in rects {
		if x >= r.rect.x && x < r.rect.x + r.rect.width && y >= r.rect.y && y < r.rect.y + r.rect.height {
			return r, true
		}
	}
	return {}, false
}

// The topmost split of the run of same-axis splits containing `node`: panes side by side along one axis,
// however their splits nested.
@(private)
run_top :: proc(l: ^Layout, node: Node_Id, axis: Axis) -> Node_Id {
	top := node
	for parent := parent_of(l, top); parent != INVALID_NODE; parent = parent_of(l, parent) {
		s, ok := l.nodes[parent].(Split)
		if !ok || s.axis != axis { break }
		top = parent
	}
	return top
}

@(private)
run_units :: proc(l: ^Layout, id: Node_Id, axis: Axis) -> int {
	if s, ok := l.nodes[id].(Split); ok && s.axis == axis {
		return run_units(l, s.first, axis)+run_units(l, s.second, axis)
	}
	return 1
}

@(private)
balance_run :: proc(l: ^Layout, id: Node_Id, axis: Axis) {
	s, ok := l.nodes[id].(Split)
	if !ok || s.axis != axis { return }
	first := run_units(l, s.first, axis)
	s.ratio = clamp(f32(first)/f32(first+run_units(l, s.second, axis)), 0.05, 0.95)
	l.nodes[id] = s
	balance_run(l, s.first, axis)
	balance_run(l, s.second, axis)
}

// Gives every region in the divider's same-axis run an equal share; other layout regions keep their sizes.
@(require_results)
balance_related :: proc(l: ^Layout, node: Node_Id) -> bool {
	if int(node) >= len(l.nodes) { return false }
	s, ok := l.nodes[node].(Split)
	if !ok { return false }
	balance_run(l, run_top(l, node, s.axis), s.axis)
	return true
}

// Moves a pane beside `target`, keeping its content and focus order; the split it leaves collapses.
@(require_results)
move_pane :: proc(l: ^Layout, node, target: Node_Id, direction: Direction) -> (Node_Id, bool) {
	if node == target || int(node) >= len(l.nodes) || int(target) >= len(l.nodes) { return INVALID_NODE, false }
	pane, ok := l.nodes[node].(Pane)
	if _, target_ok := l.nodes[target].(Pane); !ok || !target_ok { return INVALID_NODE, false }
	focused := l.focus == node
	if !remove(l, node) { return INVALID_NODE, false }
	added := place_pane(l, target, pane, direction)
	if focused { l.focus = added }
	return added, true
}

@(private)
place_pane :: proc(l: ^Layout, target: Node_Id, pane: Pane, direction: Direction) -> Node_Id {
	parent := parent_of(l, target)
	added := allocate_node(l, pane)
	before := direction == .Left || direction == .Up
	axis: Axis = direction == .Left || direction == .Right ? .Horizontal : .Vertical
	branch := allocate_node(l, Split{axis, 0.5, before ? added : target, before ? target : added})
	if parent == INVALID_NODE { l.root = branch } else {
		s := l.nodes[parent].(Split)
		if s.first == target { s.first = branch } else { s.second = branch }
		l.nodes[parent] = s
	}
	l.zoomed = false
	return added
}

@(require_results)
dock_pane :: proc(l: ^Layout, node: Node_Id, direction: Direction) -> (Node_Id, bool) {
	if node == l.root || int(node) >= len(l.nodes) { return INVALID_NODE, false }
	pane, ok := l.nodes[node].(Pane)
	if !ok { return INVALID_NODE, false }
	focused := l.focus == node
	if !remove(l, node) { return INVALID_NODE, false }
	added := place_pane(l, l.root, pane, direction)
	if focused { l.focus = added }
	return added, true
}

// Reserve before detaching, so allocation failure leaves both trees untouched.
@(require_results)
separate_pane :: proc(source: ^Layout, node: Node_Id, allocator := context.allocator) -> (Layout, bool) {
	if int(node) >= len(source.nodes) { return {}, false }
	pane, ok := source.nodes[node].(Pane)
	if !ok || pane.content.kind != .Terminal { return {}, false }
	destination: Layout
	if init(&destination, pane.content, allocator) != nil { destroy(&destination); return {}, false }
	if !remove(source, node) { destroy(&destination); return {}, false }
	destination.nodes[0] = pane
	destination.next_pane_order = pane.order
	return destination, true
}

// Reserve before detaching, so allocation failure leaves both trees untouched.
@(require_results)
transfer_pane :: proc(source, destination: ^Layout, node, target: Node_Id,
	direction: Direction, root: bool) -> (Node_Id, bool) {
	if source == destination || int(node) >= len(source.nodes) ||
	   int(target) >= len(destination.nodes) { return INVALID_NODE, false }
	pane, ok := source.nodes[node].(Pane)
	if !ok || pane.content.kind != .Terminal { return INVALID_NODE, false }
	if _, target_ok := destination.nodes[target].(Pane); !target_ok { return INVALID_NODE, false }
	for n in destination.nodes {
		if p, is_pane := n.(Pane); is_pane && (p.content.kind != .Terminal || p.content == pane.content) {
			return INVALID_NODE, false
		}
	}
	if reserve(&destination.nodes, len(destination.nodes)+2) != nil { return INVALID_NODE, false }
	if !remove(source, node) { return INVALID_NODE, false }
	destination.next_pane_order += 1
	pane.order = destination.next_pane_order
	added := place_pane(destination, root ? destination.root : target, pane, direction)
	destination.focus = added
	return added, true
}

// Every divider within `tolerance` of the point, so a junction of splits can be dragged as one.
divider_hit_all :: proc(dividers: []Divider, x, y, tolerance: f32, out: []Divider,
	junction_radius: f32 = 0, alignment: f32 = 0) -> int {
	junction: [2]f32
	closest := junction_radius+1
	if junction_radius > 0 {
		for vertical in dividers {
			if vertical.axis != .Horizontal { continue }
			for horizontal in dividers {
				if horizontal.axis != .Vertical { continue }
				v, h := vertical.rect, horizontal.rect
				cx, cy := v.x+v.width/2, h.y+h.height/2
				joins := h.x <= v.x+v.width+alignment && h.x+h.width >= v.x-alignment &&
					cy >= v.y-alignment && cy <= v.y+v.height+alignment
				distance := max(abs(x-cx), abs(y-cy))
				if joins && distance <= junction_radius && distance < closest {
					junction, closest = {cx, cy}, distance
				}
			}
		}
	}
	count := 0
	for d in dividers {
		r := d.rect
		r.x, r.width = r.x-tolerance, r.width+2*tolerance
		r.y, r.height = r.y-tolerance, r.height+2*tolerance
		hit := x >= r.x && x < r.x+r.width && y >= r.y && y < r.y+r.height
		if closest <= junction_radius {
			if d.axis == .Horizontal {
				hit = abs(d.rect.x+d.rect.width/2-junction[0]) <= alignment &&
					junction[1] >= d.rect.y-alignment && junction[1] <= d.rect.y+d.rect.height+alignment
			} else {
				hit = abs(d.rect.y+d.rect.height/2-junction[1]) <= alignment &&
					junction[0] >= d.rect.x-tolerance-d.rect.height &&
					junction[0] <= d.rect.x+d.rect.width+tolerance+d.rect.height
			}
		}
		if count < len(out) && hit {
			out[count] = d
			count += 1
		}
	}
	return count
}
