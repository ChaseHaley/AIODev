package layout

import "base:runtime"

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

Pane :: struct {
	content: Content,
}

Split :: struct {
	axis: Axis,
	ratio: f32,
	first, second: Node_Id,
}

Node :: union {
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

// Replaces the pane at `node` with a split holding the original pane and a new pane for `content`.
split :: proc(
	l: ^Layout,
	node: Node_Id,
	axis: Axis,
	ratio: f32,
	content: Content,
) -> (Node_Id, runtime.Allocator_Error) {
	assert(int(node) < len(l.nodes))
	pane, is_pane := l.nodes[node].(Pane)
	assert(is_pane, "only panes can be split")
	moved := Node_Id(len(l.nodes))
	added := moved + 1
	if _, err := append(&l.nodes, pane, Pane{content}); err != nil {
		return 0, err
	}
	l.nodes[node] = Split{axis, clamp(ratio, 0.05, 0.95), moved, added}
	if l.focus == node {
		l.focus = moved
	}
	return added, nil
}

compute :: proc(l: ^Layout, area: Rect, gap: f32, out: ^[dynamic]Pane_Rect) {
	clear(out)
	place(l, l.root, area, gap, out)
}

@(private)
place :: proc(l: ^Layout, id: Node_Id, area: Rect, gap: f32, out: ^[dynamic]Pane_Rect) {
	switch node in l.nodes[id] {
	case Pane:
		append(out, Pane_Rect{id, node.content, area})
	case Split:
		first, second := area, area
		switch node.axis {
		case .Horizontal:
			available := max(0, area.width - gap)
			first.width = available * node.ratio
			second.x = area.x + first.width + gap
			second.width = available - first.width
		case .Vertical:
			available := max(0, area.height - gap)
			first.height = available * node.ratio
			second.y = area.y + first.height + gap
			second.height = available - first.height
		}
		place(l, node.first, first, gap, out)
		place(l, node.second, second, gap, out)
	}
}

hit_test :: proc(rects: []Pane_Rect, x, y: f32) -> (Pane_Rect, bool) {
	for r in rects {
		if x >= r.rect.x && x < r.rect.x + r.rect.width && y >= r.rect.y && y < r.rect.y + r.rect.height {
			return r, true
		}
	}
	return {}, false
}
