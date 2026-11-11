package layout

// How much of a window a tab's focused pane takes. The tab owns this beside Layout.zoomed, so each tab
// keeps its own view; the window applies the view of the tab it shows.
Pane_Fill :: enum u8 {
	None,
	// The focused pane fills everything under the title bar.
	Content,
	// The focused pane fills the monitor, with the title bar hidden too.
	Screen,
}

// What a tab shows of its panes. Zoom, fill and fullscreen are one choice: the one the owner last made is
// the one in force, and turning it off clears the tab's zoom as well as its fill.
Pane_View :: enum u8 {
	Split,
	Zoom,
	Fill,
	Fill_Over_Zoom,
	Screen,
	Screen_Over_Zoom,
}

Pane_View_Event :: enum u8 {
	Toggle_Zoom,
	Toggle_Fill,
	Toggle_Screen,
	// The tab gained a pane, or lost its focused one: its panes must be seen, so every view ends.
	Panes_Changed,
}

// The only definition of how views change. The enumerated arrays make it a compile error to leave a
// state or an event without an answer. Switching tab, workspace or focused pane is not an event: each
// tab keeps its view, and a single-pane view shows whatever pane is now focused.
@(rodata)
PANE_VIEW_TRANSITIONS := [Pane_View][Pane_View_Event]Pane_View {
	.Split = {
		.Toggle_Zoom = .Zoom,
		.Toggle_Fill = .Fill,
		.Toggle_Screen = .Screen,
		.Panes_Changed = .Split,
	},
	.Zoom = {
		.Toggle_Zoom = .Split,
		.Toggle_Fill = .Fill_Over_Zoom,
		.Toggle_Screen = .Screen_Over_Zoom,
		.Panes_Changed = .Split,
	},
	.Fill = {
		.Toggle_Zoom = .Zoom,
		.Toggle_Fill = .Split,
		.Toggle_Screen = .Screen,
		.Panes_Changed = .Split,
	},
	.Fill_Over_Zoom = {
		.Toggle_Zoom = .Zoom,
		.Toggle_Fill = .Split,
		.Toggle_Screen = .Screen_Over_Zoom,
		.Panes_Changed = .Split,
	},
	.Screen = {
		.Toggle_Zoom = .Zoom,
		.Toggle_Fill = .Fill,
		.Toggle_Screen = .Split,
		.Panes_Changed = .Split,
	},
	.Screen_Over_Zoom = {
		.Toggle_Zoom = .Zoom,
		.Toggle_Fill = .Fill_Over_Zoom,
		.Toggle_Screen = .Split,
		.Panes_Changed = .Split,
	},
}

@(require_results)
pane_view_of :: proc(fill: Pane_Fill, zoomed: bool) -> Pane_View {
	switch fill {
	case .None:
		return zoomed ? .Zoom : .Split
	case .Content:
		return zoomed ? .Fill_Over_Zoom : .Fill
	case .Screen:
		return zoomed ? .Screen_Over_Zoom : .Screen
	}
	return .Split
}

@(require_results)
pane_view_parts :: proc(view: Pane_View) -> (fill: Pane_Fill, zoomed: bool) {
	switch view {
	case .Split:
		return .None, false
	case .Zoom:
		return .None, true
	case .Fill:
		return .Content, false
	case .Fill_Over_Zoom:
		return .Content, true
	case .Screen:
		return .Screen, false
	case .Screen_Over_Zoom:
		return .Screen, true
	}
	return .None, false
}

// Records a change no single-pane view can show. The tab's zoom, and a fill showing a floating pane, end
// now; the window showing the tab learns of it at its next layout, whichever change or mutation path
// caused it, and ends the fill.
@(private)
panes_changed :: proc(l: ^Layout) {
	l.zoomed = false
	l.fill_float = 0
	l.panes_changed = true
}

// Places only the focused tiled pane in `area`.
compute_focused :: proc(l: ^Layout, area: Rect, out: ^[dynamic]Pane_Rect) {
	clear(out)
	if l.root != INVALID_NODE {place(l, focus_tiled(l), area, 0, out)}
}

// A view acts on the container of the pane it is chosen on: the tiling, or that pane's floating group.
// Zoom fills the container; Fill window and Fullscreen show the pane alone, over every other pane and
// float. Each container has its own zoom, and the tab one fill, which belongs to the container it was
// chosen in.

// The floating pane the tab's fill shows alone: the focused pane, while the fill belongs to its group.
// INVALID_NODE when the fill, if any, shows the tiled pane with the floats above it.
fill_floating :: proc(l: ^Layout) -> Node_Id {
	if l.fill == .None || l.fill_float == 0 {return INVALID_NODE}
	floating, ok := float_of(l, l.focus)
	if !ok || floating.minimized || floating.id != l.fill_float {return INVALID_NODE}
	return l.focus
}

// The view of the container holding `node`: its zoom, and the tab's fill when it belongs there.
@(require_results)
pane_view_at :: proc(l: ^Layout, node: Node_Id) -> Pane_View {
	filled := fill_floating(l)
	root := float_root(l, node)
	if root == INVALID_NODE {return pane_view_of(filled == INVALID_NODE ? l.fill : .None, l.zoomed)}
	floating, _ := node_float(l, root)
	return pane_view_of(float_root(l, filled) == root ? l.fill : .None, floating.zoomed)
}

// Where `event` takes the view of the container holding `node`, and the fill the tab then has: a change
// that leaves the container's fill alone leaves the tab's, which may belong to another container.
@(require_results)
pane_view_next :: proc(
	l: ^Layout,
	node: Node_Id,
	event: Pane_View_Event,
) -> (
	to: Pane_View,
	fill: Pane_Fill,
) {
	from := pane_view_at(l, node)
	to = PANE_VIEW_TRANSITIONS[from][event]
	from_fill, _ := pane_view_parts(from)
	fill, _ = pane_view_parts(to)
	if fill == from_fill {fill = l.fill}
	return
}

// Gives the container holding `node` the view `to`, as pane_view_next found it.
pane_view_set :: proc(l: ^Layout, node: Node_Id, to: Pane_View) {
	from_fill, _ := pane_view_parts(pane_view_at(l, node))
	fill, zoomed := pane_view_parts(to)
	group: u64
	if root := float_root(l, node); root == INVALID_NODE {
		l.zoomed = zoomed
	} else {
		floating, _ := node_float(l, root)
		floating.zoomed, group = zoomed, floating.id
	}
	if fill != from_fill {l.fill, l.fill_float = fill, fill == .None ? 0 : group}
}
