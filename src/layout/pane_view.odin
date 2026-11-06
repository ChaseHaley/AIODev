package layout

// How much of a window its focused pane takes. The window owns this; Layout.zoomed belongs to the tab.
Pane_Fill :: enum u8 {
	None,
	// The focused pane fills everything under the title bar.
	Content,
	// The focused pane fills the monitor, with the title bar hidden too.
	Screen,
}

// What a window shows of its selected tab. Zoom, fill and fullscreen are one choice: the one the owner
// last made is the one in force, and turning it off clears the tab's zoom as well as the window's fill.
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
// state or an event without an answer. Switching tabs, workspaces or focused panes is not an event:
// the view stays, and shows whatever pane is now focused.
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

// Records a change no single-pane view can show. The tab's zoom ends now; the window showing the tab
// learns of it at its next layout, whichever change or mutation path caused it.
@(private)
panes_changed :: proc(l: ^Layout) {
	l.zoomed = false
	l.panes_changed = true
}

// Places only the focused tiled pane in `area`.
compute_focused :: proc(l: ^Layout, area: Rect, out: ^[dynamic]Pane_Rect) {
	clear(out)
	if l.root != INVALID_NODE {place(l, focus_tiled(l), area, 0, out)}
}
