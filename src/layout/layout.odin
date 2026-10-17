package layout

import "base:runtime"
import "core:math"

Content_Kind :: enum u8 {
	Terminal,
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
}

Layout :: struct {
	nodes: [dynamic]Node,
	root, focus: Node_Id,
}

init :: proc(l: ^Layout, content: Content, allocator := context.allocator) -> runtime.Allocator_Error {
	l.nodes = make([dynamic]Node, allocator)
	_, err := append(&l.nodes, Pane{content})
	l.root, l.focus = 0, 0
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
	added := allocate_node(l, Pane{content})
	branch := allocate_node(l, Split{axis, clamp(ratio, 0.05, 0.95), node, added})
	if parent == INVALID_NODE {
		l.root = branch
	} else {
		s := l.nodes[parent].(Split)
		if s.first == node { s.first = branch } else { s.second = branch }
		l.nodes[parent] = s
	}
	return added, nil
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

compute :: proc(l: ^Layout, area: Rect, gap: f32, out: ^[dynamic]Pane_Rect) {
	clear(out)
	if l.root != INVALID_NODE { place(l, l.root, area, gap, out) }
}

@(private)
place :: proc(l: ^Layout, id: Node_Id, area: Rect, gap: f32, out: ^[dynamic]Pane_Rect) {
	switch node in l.nodes[id] {
	case Vacant:
	case Pane:
		append(out, Pane_Rect{id, node.content, area})
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
	if l.root != INVALID_NODE { place_dividers(l, l.root, area, gap, out) }
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
