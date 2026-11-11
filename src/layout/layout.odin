package layout

import "base:runtime"
import "core:math"

Content_Kind :: enum u8 {
	Terminal,
	Settings,
	Markdown,
}

// A reference to content owned elsewhere; panes display content, they never own it.
Content :: struct {
	kind: Content_Kind,
	id:   u32,
}

Axis :: enum u8 {
	Horizontal,
	Vertical,
}

Node_Id :: distinct u32

INVALID_NODE :: Node_Id(max(u32))
Direction :: enum {
	Left,
	Right,
	Up,
	Down,
}

// Either side of a split takes at least SPLIT_SHARE_MIN of it and at most SPLIT_SHARE_MAX. Every ratio a
// split holds stays in this range, whether a new split, a resize, a balance or a saved layout set it, and
// every share a command accepts is in it too.
SPLIT_SHARE_MIN :: f32(0.05)
SPLIT_SHARE_MAX :: f32(0.95)

@(require_results)
split_share_clamp :: proc(share: f32) -> f32 {
	return clamp(share, SPLIT_SHARE_MIN, SPLIT_SHARE_MAX)
}

// The axis a direction runs along, and whether it points before what it is beside: left of or above it.
@(require_results)
direction_parts :: proc(direction: Direction) -> (axis: Axis, before: bool) {
	switch direction {
	case .Left:
		return .Horizontal, true
	case .Right:
		return .Horizontal, false
	case .Up:
		return .Vertical, true
	case .Down:
		return .Vertical, false
	}
	return .Horizontal, false
}

// The direction a side placed `before` or after along `axis` points; the inverse of direction_parts.
@(private, require_results)
direction_of :: proc(axis: Axis, before: bool) -> Direction {
	if axis == .Horizontal {return before ? .Left : .Right}
	return before ? .Up : .Down
}

Vacant :: struct {}

Divider :: struct {
	node:       Node_Id,
	axis:       Axis,
	area, rect: Rect,
}

// A bar the pointer can grab beside a layout's own dividers, such as an edge of the surrounding chrome.
Edge :: struct {
	axis: Axis,
	rect: Rect,
}

Pane :: struct {
	content:  Content,
	order:    u64,
	// Shown in its own window. The pane keeps its slot and takes no space here; see set_linked.
	linked:   bool,
	// Drawn above the tiled panes at its own rectangle. It too keeps its slot and takes no space;
	// see floats.odin.
	floating: bool,
	float:    Float,
}

Split :: struct {
	axis:          Axis,
	ratio:         f32,
	first, second: Node_Id,
	// Shown in its own window with every pane under it, which are not marked themselves; see links.odin.
	linked:        bool,
	// Drawn as one floating pane group with every pane under it; see floats.odin.
	floating:      bool,
	float:         Float,
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
	node:     Node_Id,
	content:  Content,
	rect:     Rect,
	order:    u64,
	floating: bool,
	// The floating group the pane is in (its Float.id), zero for a tiled pane: panes in the same group,
	// or all tiled panes, share one container.
	group:    u64,
}

@(private)
Partition :: struct {
	available:          f32,
	first, second, bar: Rect,
}

Layout :: struct {
	nodes:            [dynamic]Node,
	root, focus:      Node_Id,
	next_pane_order:  u64,
	// The tab's view, kept while other tabs show; see Pane_View.
	fill:             Pane_Fill,
	zoomed:           bool,
	// See panes_changed.
	panes_changed:    bool,
	// The tiled pane focus returns to when a floating pane gives it up; see focus_set.
	tiled_focus:      Node_Id,
	next_float_stack: u64,
	next_float_id:    u64,
}

init :: proc(
	l: ^Layout,
	content: Content,
	allocator := context.allocator,
) -> runtime.Allocator_Error {
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

// Hangs `replacement` where `child` hung from `parent`, or makes it the root when `child` had no parent.
@(private)
node_replace :: proc(l: ^Layout, parent, child, replacement: Node_Id) {
	if parent == INVALID_NODE {
		l.root = replacement
		return
	}
	s := l.nodes[parent].(Split)
	if s.first == child {s.first = replacement} else {s.second = replacement}
	l.nodes[parent] = s
}

@(require_results)
split :: proc(
	l: ^Layout,
	node: Node_Id,
	axis: Axis,
	ratio: f32,
	content: Content,
) -> (
	Node_Id,
	runtime.Allocator_Error,
) {
	assert(int(node) < len(l.nodes))
	_, is_pane := l.nodes[node].(Pane)
	assert(is_pane, "only panes can be split")
	return wrap(l, node, axis, false, split_share_clamp(ratio), content)
}

// Places a new pane beside `node`, which may be a pane or a whole split, taking `share` of the
// space they then divide; `before` puts it left of or above the node. Reopening a closed pane uses
// this to return it beside the panes it was split from. With `join_slot` the pane joins the slot
// `node` is in, even when `node` is the slot itself.
@(require_results)
insert_beside :: proc(
	l: ^Layout,
	node: Node_Id,
	axis: Axis,
	before: bool,
	share: f32,
	content: Content,
	join_slot := false,
) -> (
	Node_Id,
	runtime.Allocator_Error,
) {
	if int(node) >= len(l.nodes) {return INVALID_NODE, .Invalid_Argument}
	if _, vacant := l.nodes[node].(Vacant); vacant {return INVALID_NODE, .Invalid_Argument}
	return wrap(l, node, axis, before, beside_ratio(share, before), content, join_slot)
}

// The ratio of a split that gives `share` to a new side placed before or after the other; a split's ratio
// is its first side's share.
@(private)
beside_ratio :: proc(share: f32, before: bool) -> f32 {
	part := split_share_clamp(share)
	return split_share_clamp(before ? part : 1 - part)
}

// Where a pane sits against the rest of its parent split: the sibling node, the split's axis,
// whether the pane comes first, and the pane's share. False for a lone root pane.
placement :: proc(
	l: ^Layout,
	node: Node_Id,
) -> (
	sibling: Node_Id,
	axis: Axis,
	before: bool,
	share: f32,
	ok: bool,
) {
	parent := parent_of(l, node)
	if parent == INVALID_NODE {return}
	s := l.nodes[parent].(Split)
	before = s.first == node
	sibling = before ? s.second : s.first
	share = before ? s.ratio : 1 - s.ratio
	return sibling, s.axis, before, share, true
}

// The content shown by the pane at `node`; false when `node` is out of range or not a pane.
pane_content :: proc(l: ^Layout, node: Node_Id) -> (Content, bool) {
	if int(node) >= len(l.nodes) {return {}, false}
	pane, is_pane := l.nodes[node].(Pane)
	return pane.content, is_pane
}

// The content of the focused pane; false when nothing holds focus.
focused_content :: proc(l: ^Layout) -> (Content, bool) {
	return pane_content(l, l.focus)
}

// Appends the content of every pane under `node`, first to second.
contents :: proc(l: ^Layout, node: Node_Id, out: ^[dynamic]Content) {
	if int(node) >= len(l.nodes) {return}
	switch n in l.nodes[node] {
	case Vacant:
	case Pane:
		append(out, n.content)
	case Split:
		contents(l, n.first, out)
		contents(l, n.second, out)
	}
}

// The smallest node whose panes are exactly `group`, in any order, or INVALID_NODE.
find_group :: proc(l: ^Layout, group: []Content) -> Node_Id {
	if len(group) == 0 || l.root == INVALID_NODE || int(l.root) >= len(l.nodes) {return INVALID_NODE}
	found := INVALID_NODE
	group_match(l, l.root, group, &found)
	return found
}

// Counts the panes under `node` when all of them are in `group`, or -1; the first node whose count
// equals the group's size is the deepest such node.
@(private)
group_match :: proc(l: ^Layout, node: Node_Id, group: []Content, found: ^Node_Id) -> int {
	count := -1
	switch n in l.nodes[node] {
	case Vacant:
	case Pane:
		for content in group {if content == n.content {count = 1; break}}
	case Split:
		first := group_match(l, n.first, group, found)
		second := group_match(l, n.second, group, found)
		if first >= 0 && second >= 0 {count = first + second}
	}
	if count == len(group) && found^ == INVALID_NODE {found^ = node}
	return count
}

// Adds a new pane for `content` beside `node`; `ratio` is the first side's share.
@(private, require_results)
wrap :: proc(
	l: ^Layout,
	node: Node_Id,
	axis: Axis,
	before: bool,
	ratio: f32,
	content: Content,
	join_slot := false,
) -> (
	Node_Id,
	runtime.Allocator_Error,
) {
	if err := reserve(&l.nodes, len(l.nodes) + 2); err != nil {return INVALID_NODE, err}
	l.next_pane_order += 1
	pane := Pane{content = content, order = l.next_pane_order}
	added := node_wrap(l, node, pane, axis, before, ratio, join_slot)
	return added, nil
}

// Puts a split where `node` is, holding `node` and `pane` side by side along `axis`, the pane first when
// `before`; `ratio` is the first side's share. A floating group's frame moves from `node` to the split, so
// the group keeps every pane under it; with `join_slot`, a slot's link mark moves the same way. Allocates
// two nodes, which the caller has reserved or just freed.
@(private)
node_wrap :: proc(
	l: ^Layout,
	node: Node_Id,
	pane: Pane,
	axis: Axis,
	before: bool,
	ratio: f32,
	join_slot := false,
) -> Node_Id {
	// Before the new split exists: it also holds `node`, and a vacant node can put it first in the scan.
	parent := parent_of(l, node)
	frame: Float
	floating, was_floating := node_float(l, node)
	if was_floating {frame = floating^; node_set_float(l, node, false)}
	linked := join_slot && node_linked(l, node)
	if linked {node_set_linked(l, node, false)}
	added := allocate_node(l, pane)
	first, second := node, added
	if before {first, second = added, node}
	branch := allocate_node(
		l,
		Split {
			axis = axis, ratio = ratio, first = first, second = second,
			linked = linked, floating = was_floating, float = frame,
		},
	)
	node_replace(l, parent, node, branch)
	panes_changed(l)
	return added
}

// Places a moved pane beside `target`, taking half the space they then divide.
@(private)
place_pane :: proc(
	l: ^Layout,
	target: Node_Id,
	pane: Pane,
	direction: Direction,
	join_slot := false,
) -> Node_Id {
	axis, before := direction_parts(direction)
	return node_wrap(l, target, pane, axis, before, 0.5, join_slot)
}

// Splits the pane at `node`; the new pane takes `ratio` on the `direction` side. With `join_slot` the new
// pane joins the slot `node` is in, even when `node` is the slot itself.
@(require_results)
split_direction :: proc(
	l: ^Layout,
	node: Node_Id,
	direction: Direction,
	ratio: f32,
	content: Content,
	join_slot := false,
) -> (
	Node_Id,
	runtime.Allocator_Error,
) {
	assert(int(node) < len(l.nodes))
	_, is_pane := l.nodes[node].(Pane)
	assert(is_pane, "only panes can be split")
	axis, before := direction_parts(direction)
	return wrap(l, node, axis, before, beside_ratio(ratio, before), content, join_slot)
}

@(require_results)
swap :: proc(l: ^Layout, first, second: Node_Id) -> bool {
	if int(first) >= len(l.nodes) || int(second) >= len(l.nodes) || first == second {return false}
	a, a_ok := l.nodes[first].(Pane)
	b, b_ok := l.nodes[second].(Pane)
	// Contents trade places; each slot keeps whether it floats, so a swap never reshapes either layout.
	if !a_ok || !b_ok {return false}
	a.content, b.content = b.content, a.content
	l.nodes[first], l.nodes[second] = a, b
	if l.focus == first {l.focus = second} else if l.focus == second {l.focus = first}
	return true
}

balance :: proc(l: ^Layout) {
	for node, i in l.nodes {
		// A slot's arrangement belongs to the window showing it.
		if s, ok := node.(Split); ok && link_root(l, Node_Id(i)) == INVALID_NODE {
			s.ratio = 0.5
			l.nodes[i] = s
		}
	}
}

@(private)
first_shown :: proc(l: ^Layout, id: Node_Id) -> Node_Id {
	switch node in l.nodes[id] {
	case Vacant:
	case Pane:
		if !node.linked && !node.floating {return id}
	case Split:
		if node.linked || node.floating {return INVALID_NODE}
		if found := first_shown(l, node.first); found != INVALID_NODE {return found}
		return first_shown(l, node.second)
	}
	return INVALID_NODE
}

@(private)
shown_count :: proc(l: ^Layout, id: Node_Id) -> int {
	switch node in l.nodes[id] {
	case Vacant:
	case Pane:
		return node.linked || node.floating ? 0 : 1
	case Split:
		return node.linked || node.floating ? 0 : shown_count(l, node.first) + shown_count(l, node.second)
	}
	return 0
}

// Whether both sides of a split take space, which is what gives it a divider and a ratio that shows.
@(private)
split_divides :: proc(l: ^Layout, s: Split) -> bool {
	return first_shown(l, s.first) != INVALID_NODE && first_shown(l, s.second) != INVALID_NODE
}

// Moves a pane, or a whole slot on its way back, to or from its own window. Its slot stays, so it returns
// exactly where it was. A tree must keep one pane it can show and focus, so the last shown pane cannot leave.
@(require_results)
set_linked :: proc(l: ^Layout, node: Node_Id, linked: bool) -> bool {
	if int(node) >= len(l.nodes) {return false}
	if _, vacant := l.nodes[node].(Vacant); vacant || node_linked(l, node) == linked {return false}
	if linked && is_floating(l, node) {return false}
	if linked && (l.root == INVALID_NODE || shown_count(l, l.root) <= 1) {return false}
	sibling, _, _, _, placed := placement(l, node)
	node_set_linked(l, node, linked)
	if linked && l.focus == node {l.focus = placed ? first_shown(l, sibling) : INVALID_NODE}
	links_repair(l)
	panes_changed(l)
	return true
}

// Restores what the rest of the package relies on: some pane is shown, and focus is on a shown pane or a
// floating pane that is not minimized. Linked and floating panes return to the tree when no other pane
// would be left, as when the last shown pane closes.
links_repair :: proc(l: ^Layout) {
	if l.root == INVALID_NODE {return}
	if first_shown(l, l.root) == INVALID_NODE {
		for _, i in l.nodes {
			node_set_linked(l, Node_Id(i), false)
			node_set_float(l, Node_Id(i), false)
		}
	}
	if focus_valid(l, l.focus) {return}
	l.focus = focus_behind(l)
}

@(require_results)
remove :: proc(l: ^Layout, node: Node_Id) -> bool {
	if int(node) >= len(l.nodes) {return false}
	_, ok := l.nodes[node].(Pane)
	if !ok {return false}
	float_group := float_root(l, node)
	// A floating pane takes no part in the tiled arrangement, so its close leaves any zoom in place.
	if l.focus == node && float_group == INVALID_NODE {panes_changed(l)}
	parent := parent_of(l, node)
	if parent == INVALID_NODE {
		l.root, l.focus = INVALID_NODE, INVALID_NODE
	} else {
		branch := l.nodes[parent].(Split)
		sibling := branch.first == node ? branch.second : branch.first
		node_replace(l, parent_of(l, parent), parent, sibling)
		// The last two panes of a linked or floating slot: the one that stays is the slot now.
		if branch.linked {node_set_linked(l, sibling, true)}
		if branch.floating {node_set_float(l, sibling, true, branch.float)}
		if l.focus == node {
			if float_group != INVALID_NODE && float_group != node {
				l.focus = pane_first(l, sibling)
			} else {
				l.focus = float_group != INVALID_NODE ? INVALID_NODE : first_shown(l, sibling)
			}
		}
		l.nodes[parent] = Vacant{}
	}
	l.nodes[node] = Vacant{}
	links_repair(l)
	return true
}

@(require_results)
focus_direction :: proc(rects: []Pane_Rect, focus: Node_Id, direction: Direction) -> Node_Id {
	origin: Rect
	found := false
	for pane in rects {
		if pane.node == focus {origin, found = pane.rect, true; break}
	}
	if !found {return focus}
	best := f32(1e30)
	result := focus
	x, y := origin.x + origin.width / 2, origin.y + origin.height / 2
	for pane in rects {
		if pane.node == focus {continue}
		r := pane.rect
		dx, dy := r.x + r.width / 2 - x, r.y + r.height / 2 - y
		primary, secondary, overlap: f32
		switch direction {
		case .Left:
			primary, secondary = -dx, abs(dy)
		case .Right:
			primary, secondary = dx, abs(dy)
		case .Up:
			primary, secondary = -dy, abs(dx)
		case .Down:
			primary, secondary = dy, abs(dx)
		}
		if axis, _ := direction_parts(direction); axis == .Horizontal {
			overlap = min(origin.y + origin.height, r.y + r.height) - max(origin.y, r.y)
		} else {
			overlap = min(origin.x + origin.width, r.x + r.width) - max(origin.x, r.x)
		}
		if primary <= 0 || overlap <= 0 {continue}
		score := primary + secondary
		if score < best {best, result = score, pane.node}
	}
	return result
}

@(require_results)
resize :: proc(l: ^Layout, node: Node_Id, axis: Axis, delta: f32) -> bool {
	parent := parent_of(l, node)
	for parent != INVALID_NODE {
		s := l.nodes[parent].(Split)
		if s.axis == axis && split_divides(l, s) {
			s.ratio = split_share_clamp(s.ratio + delta)
			l.nodes[parent] = s
			return true
		}
		parent = parent_of(l, parent)
	}
	return false
}

@(require_results)
resize_pixels :: proc(
	l: ^Layout,
	node: Node_Id,
	axis: Axis,
	delta: f32,
	dividers: []Divider,
) -> bool {
	parent := parent_of(l, node)
	for parent != INVALID_NODE {
		s := l.nodes[parent].(Split)
		if s.axis == axis && split_divides(l, s) {
			for d in dividers {
				if d.node != parent {continue}
				p := partition(d.area, axis, s.ratio, extent(d.rect, axis))
				if p.available <= 0 {return false}
				return resize(l, node, axis, delta / p.available)
			}
			return false
		}
		parent = parent_of(l, parent)
	}
	return false
}

@(require_results)
focus_cycle :: proc(rects: []Pane_Rect, focus: Node_Id, delta: int) -> Node_Id {
	if len(rects) == 0 {return focus}
	order: u64
	found := false
	for pane in rects {
		if pane.node == focus {order, found = pane.order, true; break}
	}
	if !found {return focus}
	steps := delta % len(rects)
	result := focus
	for steps != 0 {
		forward := steps > 0
		wrap := rects[0]
		candidate: Pane_Rect
		have_candidate := false
		for pane in rects {
			if forward ? pane.order < wrap.order : pane.order > wrap.order {wrap = pane}
			eligible := forward ? pane.order > order : pane.order < order
			if eligible &&
			   (!have_candidate ||
					   (forward ? pane.order < candidate.order : pane.order > candidate.order)) {
				candidate, have_candidate = pane, true
			}
		}
		if !have_candidate {candidate = wrap}
		result, order = candidate.node, candidate.order
		steps += forward ? -1 : 1
	}
	return result
}

// Where a window places a tree: tiled panes share `tiled` with `gap` between them, and floating groups are
// fractions of `floating`, each under a `header` strip. A window's layout and a trial of a change read the
// same value, so a trial judges the placement the change would get.
Geometry :: struct {
	tiled, floating: Rect,
	gap, header:     f32,
}

// Places the panes a window shows: every tiled pane, or only the focused one when `solo`, then the floating
// groups above them. The window's view decides what shows alone, not the tab's zoom.
place_shown :: proc(l: ^Layout, g: Geometry, solo: bool, out: ^[dynamic]Pane_Rect) {
	if solo {compute_focused(l, g.tiled, out)} else {compute(l, g.tiled, g.gap, out)}
	floats_place(l, g.floating, g.gap, g.header, out)
}

// The dividers a window shows: those between tiled panes unless one shows alone, then those inside
// floating groups.
dividers_shown :: proc(l: ^Layout, g: Geometry, solo: bool, out: ^[dynamic]Divider) {
	if solo {clear(out)} else {dividers(l, g.tiled, g.gap, out)}
	floats_dividers(l, g.floating, g.gap, g.header, out)
}

// Places the tiled panes; floats_place adds the floating ones above them.
compute :: proc(l: ^Layout, area: Rect, gap: f32, out: ^[dynamic]Pane_Rect) {
	clear(out)
	if l.root == INVALID_NODE {return}
	place(l, l.root, area, gap, out)
}

@(private)
extent :: proc(r: Rect, axis: Axis) -> f32 {
	return axis == .Horizontal ? r.width : r.height
}

@(private, require_results)
partition :: proc(area: Rect, axis: Axis, ratio: f32, gap: f32) -> Partition {
	p := Partition{first = area, second = area, bar = area}
	switch axis {
	case .Horizontal:
		p.available = max(0, area.width - gap)
		p.first.width = clamp(math.round(p.available * ratio), 0, p.available)
		p.second.x, p.second.width = area.x + p.first.width + gap, p.available - p.first.width
		p.bar.x, p.bar.width = area.x + p.first.width, gap
	case .Vertical:
		p.available = max(0, area.height - gap)
		p.first.height = clamp(math.round(p.available * ratio), 0, p.available)
		p.second.y, p.second.height = area.y + p.first.height + gap, p.available - p.first.height
		p.bar.y, p.bar.height = area.y + p.first.height, gap
	}
	return p
}

@(private)
place :: proc(l: ^Layout, id: Node_Id, area: Rect, gap: f32, out: ^[dynamic]Pane_Rect) {
	switch node in l.nodes[id] {
	case Vacant:
	case Pane:
		if !node.linked && !node.floating {
			append(out, Pane_Rect{id, node.content, area, node.order, false, 0})
		}
	case Split:
		if node.floating {return}
		if !split_divides(l, node) {
			place(l, first_shown(l, node.first) != INVALID_NODE ? node.first : node.second, area, gap, out)
			return
		}
		p := partition(area, node.axis, node.ratio, gap)
		place(l, node.first, p.first, gap, out)
		place(l, node.second, p.second, gap, out)
	}
}

dividers :: proc(l: ^Layout, area: Rect, gap: f32, out: ^[dynamic]Divider) {
	clear(out)
	if l.root != INVALID_NODE {place_dividers(l, l.root, area, gap, out)}
}

@(private)
place_dividers :: proc(l: ^Layout, id: Node_Id, area: Rect, gap: f32, out: ^[dynamic]Divider) {
	if s, ok := l.nodes[id].(Split); ok {
		if s.floating {return}
		if !split_divides(l, s) {
			shown := first_shown(l, s.first) != INVALID_NODE ? s.first : s.second
			place_dividers(l, shown, area, gap, out)
			return
		}
		p := partition(area, s.axis, s.ratio, gap)
		append(out, Divider{id, s.axis, area, p.bar})
		place_dividers(l, s.first, p.first, gap, out)
		place_dividers(l, s.second, p.second, gap, out)
	}
}

@(require_results)
drag_divider :: proc(l: ^Layout, d: Divider, x, y, gap: f32) -> bool {
	if int(d.node) >= len(l.nodes) {return false}
	s, ok := l.nodes[d.node].(Split)
	if !ok {return false}
	p := partition(d.area, d.axis, s.ratio, gap)
	if p.available <= 0 {return false}
	thickness := extent(p.bar, d.axis)
	position :=
		d.axis == .Horizontal ? x - d.area.x - thickness / 2 : y - d.area.y - thickness / 2
	s.ratio = split_share_clamp(position / p.available)
	l.nodes[d.node] = s
	return true
}

// The topmost pane at the point. Tiled panes never overlap, and floating panes follow them in stacking
// order, so the last match is the one drawn on top.
hit_test :: proc(rects: []Pane_Rect, x, y: f32) -> (Pane_Rect, bool) {
	#reverse for r in rects {
		if x >= r.rect.x &&
		   x < r.rect.x + r.rect.width &&
		   y >= r.rect.y &&
		   y < r.rect.y + r.rect.height {
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
	floating := float_root(l, node)
	for parent := parent_of(l, top); parent != INVALID_NODE; parent = parent_of(l, parent) {
		if top == floating {break}
		s, ok := l.nodes[parent].(Split)
		if !ok || s.axis != axis {break}
		top = parent
	}
	return top
}

@(private)
run_units :: proc(l: ^Layout, id: Node_Id, axis: Axis) -> int {
	if s, ok := l.nodes[id].(Split); ok && s.axis == axis && !s.linked {
		return run_units(l, s.first, axis) + run_units(l, s.second, axis)
	}
	return first_shown(l, id) != INVALID_NODE ? 1 : 0
}

@(private)
balance_run :: proc(l: ^Layout, id: Node_Id, axis: Axis) {
	s, ok := l.nodes[id].(Split)
	if !ok || s.axis != axis || s.linked {return}
	first, second := run_units(l, s.first, axis), run_units(l, s.second, axis)
	// A side in its own window keeps the share it returns to.
	if first > 0 && second > 0 {
		s.ratio = split_share_clamp(f32(first) / f32(first + second))
		l.nodes[id] = s
	}
	balance_run(l, s.first, axis)
	balance_run(l, s.second, axis)
}

// Gives every region in the divider's same-axis run an equal share; other layout regions keep their sizes.
@(require_results)
balance_related :: proc(l: ^Layout, node: Node_Id) -> bool {
	if int(node) >= len(l.nodes) {return false}
	s, ok := l.nodes[node].(Split)
	if !ok {return false}
	balance_run(l, run_top(l, node, s.axis), s.axis)
	return true
}

// Moves a pane beside `target`, keeping its content and focus order; the split it leaves collapses. The
// pane joins whatever layout the target belongs to, so a move can take it into or out of a floating
// group. The tiling must keep a pane to show.
@(require_results)
move_pane :: proc(l: ^Layout, node, target: Node_Id, direction: Direction) -> (Node_Id, bool) {
	if node == target ||
	   int(node) >= len(l.nodes) ||
	   int(target) >= len(l.nodes) {return INVALID_NODE, false}
	pane, ok := l.nodes[node].(Pane)
	target_pane, target_ok := l.nodes[target].(Pane)
	if !ok || !target_ok || target_pane.linked {return INVALID_NODE, false}
	if pane_tiled(l, node) && !pane_tiled(l, target) && shown_count(l, l.root) <= 1 {
		return INVALID_NODE, false
	}
	pane_settle(&pane)
	focused := l.focus == node
	if !remove(l, node) {return INVALID_NODE, false}
	added := place_pane(l, target, pane, direction)
	if focused {l.focus = added}
	return added, true
}

// Docks a pane along an edge of the whole tiling, which takes a floating pane out of its group.
@(require_results)
dock_pane :: proc(l: ^Layout, node: Node_Id, direction: Direction) -> (Node_Id, bool) {
	if node == l.root || int(node) >= len(l.nodes) {return INVALID_NODE, false}
	pane, ok := l.nodes[node].(Pane)
	// Removing the only shown pane would bring linked panes back; docking has nothing to dock beside.
	if !ok || (pane_tiled(l, node) && shown_count(l, l.root) <= 1) {return INVALID_NODE, false}
	pane_settle(&pane)
	focused := l.focus == node
	if !remove(l, node) {return INVALID_NODE, false}
	added := place_pane(l, l.root, pane, direction)
	if focused {l.focus = added}
	return added, true
}

// Reserve before detaching, so allocation failure leaves both trees untouched.
@(require_results)
separate_pane :: proc(
	source: ^Layout,
	node: Node_Id,
	allocator := context.allocator,
) -> (
	Layout,
	bool,
) {
	if int(node) >= len(source.nodes) {return {}, false}
	pane, ok := source.nodes[node].(Pane)
	if !ok {return {}, false}
	destination: Layout
	if init(&destination, pane.content, allocator) != nil {destroy(&destination); return {}, false}
	if !remove(source, node) {destroy(&destination); return {}, false}
	pane_adopt(&destination, pane)
	return destination, true
}

// Makes a one-pane tree show `pane`, which arrives tiled and shown and keeps its place in focus order. A
// pane that leaves its tree for a window of its own lands this way.
pane_adopt :: proc(l: ^Layout, pane: Pane) {
	adopted := pane
	pane_settle(&adopted)
	l.nodes[l.root] = adopted
	l.next_pane_order = adopted.order
}

// Reserve before detaching, so allocation failure leaves both trees untouched.
@(require_results)
transfer_pane :: proc(
	source, destination: ^Layout,
	node, target: Node_Id,
	direction: Direction,
	root: bool,
) -> (
	Node_Id,
	bool,
) {
	if source == destination ||
	   int(node) >= len(source.nodes) ||
	   int(target) >= len(destination.nodes) {return INVALID_NODE, false}
	pane, ok := source.nodes[node].(Pane)
	if !ok {return INVALID_NODE, false}
	pane_settle(&pane)
	if _, target_ok := destination.nodes[target].(Pane); !target_ok {return INVALID_NODE, false}
	// Content is a reference owned elsewhere, so it may appear once in a tree.
	if find_content(destination, pane.content) != INVALID_NODE {return INVALID_NODE, false}
	if reserve(&destination.nodes, len(destination.nodes) + 2) != nil {return INVALID_NODE, false}
	if !remove(source, node) {return INVALID_NODE, false}
	destination.next_pane_order += 1
	pane.order = destination.next_pane_order
	added := place_pane(destination, root ? destination.root : target, pane, direction)
	destination.focus = added
	return added, true
}

// Every bar within `tolerance` of the point, so a junction of bars can be dragged as one. The bars are
// `edges` followed by `dividers`; `out` receives the indices of those hit in that order.
divider_hit_all :: proc(
	edges: []Edge,
	dividers: []Divider,
	x, y, tolerance: f32,
	out: []int,
	junction_radius: f32 = 0,
	alignment: f32 = 0,
) -> int {
	bar :: proc(edges: []Edge, dividers: []Divider, i: int) -> Edge {
		if i < len(edges) {return edges[i]}
		d := dividers[i - len(edges)]
		return {d.axis, d.rect}
	}
	bars := len(edges) + len(dividers)
	junction: [2]f32
	closest := junction_radius + 1
	if junction_radius > 0 {
		for i in 0 ..< bars {
			vertical := bar(edges, dividers, i)
			if vertical.axis != .Horizontal {continue}
			for j in 0 ..< bars {
				horizontal := bar(edges, dividers, j)
				if horizontal.axis != .Vertical {continue}
				v, h := vertical.rect, horizontal.rect
				cx, cy := v.x + v.width / 2, h.y + h.height / 2
				joins :=
					h.x <= v.x + v.width + alignment &&
					h.x + h.width >= v.x - alignment &&
					cy >= v.y - alignment &&
					cy <= v.y + v.height + alignment
				distance := max(abs(x - cx), abs(y - cy))
				if joins && distance <= junction_radius && distance < closest {
					junction, closest = {cx, cy}, distance
				}
			}
		}
	}
	count := 0
	for i in 0 ..< bars {
		d := bar(edges, dividers, i)
		r := d.rect
		r.x, r.width = r.x - tolerance, r.width + 2 * tolerance
		r.y, r.height = r.y - tolerance, r.height + 2 * tolerance
		hit := x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
		if closest <= junction_radius {
			if d.axis == .Horizontal {
				hit =
					abs(d.rect.x + d.rect.width / 2 - junction[0]) <= alignment &&
					junction[1] >= d.rect.y - alignment &&
					junction[1] <= d.rect.y + d.rect.height + alignment
			} else {
				hit =
					abs(d.rect.y + d.rect.height / 2 - junction[1]) <= alignment &&
					junction[0] >= d.rect.x - tolerance - d.rect.height &&
					junction[0] <= d.rect.x + d.rect.width + tolerance + d.rect.height
			}
		}
		if count < len(out) && hit {
			out[count] = i
			count += 1
		}
	}
	return count
}
