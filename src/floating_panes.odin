package main

import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:log"

// Floats (WORK-045). A float is a window of one or more panes above its tab's tiled panes, so opening,
// moving, minimizing or closing it never resizes or reflows them. Its float header moves it, and holds
// Minimize, Dock and Close; its edges resize it; it minimizes to a capsule. The tree keeps its slot, so
// session lifetime, status, saving and closing treat its panes as any other. See src/layout/floats.odin.

// The band across a floating pane's edge that resizes it, in DIPs, half inside the card and half outside.
FLOAT_EDGE :: f32(8)
// The smallest card a resize leaves, in DIPs.
FLOAT_MINIMUM_WIDTH :: f32(240)
FLOAT_MINIMUM_HEIGHT :: f32(120)
// How far each further floating pane opens down and right of the last, in DIPs.
FLOAT_CASCADE :: ui.SPACE_6
// A pointer travel shorter than this, in DIPs, is a click on the header rather than a move.
FLOAT_DRAG_THRESHOLD :: f32(3)
// Capsule widths, in DIPs; the title takes what lies between.
FLOAT_CAPSULE_MINIMUM :: f32(96)
FLOAT_CAPSULE_MAXIMUM :: f32(200)
// The strip along the top of every float, in DIPs. With every part of the frame outside its panes' cards
// it forms the float header, which moves the float and holds its buttons.
FLOAT_HEADER :: ui.HEADER_HEIGHT

// What a point on a float header does.
Float_Header_Action :: enum u8 {
	None,
	Minimize,
	Dock,
	Close,
	Move,
}

// A float header button: what it does and its icon. FLOAT_HEADER_BUTTONS lists them left to right, and
// their rectangles and motions keep its order.
Float_Header_Button :: struct {
	action: Float_Header_Action,
	icon:   ui.Icon,
}

@(rodata)
FLOAT_HEADER_BUTTONS := [?]Float_Header_Button {
	{action = .Minimize, icon = .Minimize},
	{action = .Dock, icon = .Float_Pane},
	{action = .Close, icon = .Close},
}

Float_Edge :: enum u8 {
	Left,
	Top,
	Right,
	Bottom,
}

// The edges a resize moves; none moves the whole pane.
Float_Edges :: bit_set[Float_Edge]

// What the float surface's held Left press is doing; nil when it holds none. Only this file writes it:
// floating_press begins it, the follow procs advance it, and floating_pointer_move, floating_release,
// floating_pointer_cancel and floating_drag_follow (when the float stops floating) end it.
Float_Press :: union {
	Float_Button_Press,
	Float_Header_Press,
	Float_Move,
	Float_Resize,
	Float_Capsules_Press,
	Float_Capsules_Move,
}

// A float header button, drawn pressed until the release, which fires it over the same button of the
// same float. Content names a pane of the float.
Float_Button_Press :: struct {
	content: layout.Content,
	action:  Float_Header_Action,
}

// Where a move or resize began: a pane of the float by its content, which survives the node renumbering a
// close elsewhere in the tree can cause; the pointer; and the float's rectangle, in pixels.
Float_Grab :: struct {
	content: layout.Content,
	start:   [2]f32,
	rect:    layout.Rect,
}

// A press on the float header that has not yet travelled FLOAT_DRAG_THRESHOLD, so is still a click.
Float_Header_Press :: struct {
	using grab: Float_Grab,
}

// The float follows the pointer from its header.
Float_Move :: struct {
	using grab: Float_Grab,
}

// The float's edges follow the pointer from the outer edge band.
Float_Resize :: struct {
	using grab: Float_Grab,
	edges:      Float_Edges,
}

// Where a capsule row move began: the pointer and the row, in pixels.
Float_Row_Grab :: struct {
	start: [2]f32,
	rect:  render.Rect,
}

// A press on the capsule row that has not yet travelled FLOAT_DRAG_THRESHOLD. On a capsule, it draws that
// capsule pressed and restores its float on a release over it; between capsules, it does nothing.
Float_Capsules_Press :: struct {
	using grab: Float_Row_Grab,
	capsule:    Maybe(layout.Content),
}

// The capsule row follows the pointer.
Float_Capsules_Move :: struct {
	using grab: Float_Row_Grab,
}

// A part of a float header under the pointer: the float's root and what that part does.
Float_Header_Spot :: struct {
	root:   layout.Node_Id,
	action: Float_Header_Action,
}

// A window's floating-pane presentation, which Window embeds; floating_window_init and
// floating_window_destroy are its lifetime, and this file is its only writer.
Float_Window_State :: struct {
	// The float surface's held Left press: a float header button, a float moving or resizing, or the
	// capsule row.
	float_press: Float_Press,
	// The float header part under the pointer, and the float the hover and press animation belongs to,
	// which it keeps while fading out.
	float_header_hover:    Maybe(Float_Header_Spot),
	float_header_shown:    layout.Node_Id,
	float_header_motion:   ui.Control_Motion,
	float_header_controls: [len(FLOAT_HEADER_BUTTONS)]ui.Control_Motion,
	// The minimized float whose capsule is under the pointer; where the user left the capsule row, as a
	// fraction of the room it can travel, or nil for the bottom-right; and the row's cached geometry.
	float_capsule_hover:      Maybe(layout.Content),
	float_capsule_anchor:     Maybe([2]f32),
	float_capsule_group:      render.Rect,
	float_capsules:           [dynamic]Float_Capsule,
	float_capsule_widths:     [dynamic]f32,
}

floating_window_init :: proc(s: ^Float_Window_State) {
	s.float_header_shown = layout.INVALID_NODE
}

floating_window_destroy :: proc(s: ^Float_Window_State) {
	delete(s.float_capsules)
	delete(s.float_capsule_widths)
}

// A float moves or resizes with the pointer.
floating_dragging :: proc(w: ^Window) -> bool {
	#partial switch _ in w.float_press {
	case Float_Move, Float_Resize:
		return true
	}
	return false
}

// The float whose header holds the press, by a pane's content, while a press there may still move it.
floating_header_held :: proc(w: ^Window) -> (layout.Content, bool) {
	#partial switch p in w.float_press {
	case Float_Header_Press:
		return p.content, true
	case Float_Move:
		return p.content, true
	}
	return {}, false
}

floating_button_pressed :: proc(w: ^Window, action: Float_Header_Action) -> bool {
	p, ok := w.float_press.(Float_Button_Press)
	return ok && p.action == action
}

// The float header under the pointer, or the one moving its float, takes the animation; a header the
// pointer left keeps it while it fades. True when the window must draw again.
floating_header_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	header := layout.INVALID_NODE
	spot, spotted := w.float_header_hover.?
	if spotted {header = spot.root}
	held, moving := floating_header_held(w)
	if moving {
		tree := window_tree(w)
		header = layout.float_root(tree, layout.find_content(tree, held))
	}
	if header != layout.INVALID_NODE {w.float_header_shown = header}
	active := header != layout.INVALID_NODE
	changed := ui.control_update(&w.float_header_motion, active, moving, app.animations, frame)
	for &control, i in w.float_header_controls {
		action := FLOAT_HEADER_BUTTONS[i].action
		over := spotted && spot.action == action
		pressed := floating_button_pressed(w, action)
		changed = ui.control_update(&control, over, pressed, app.animations, frame) || changed
	}
	return changed
}

floating_header_animating :: proc(w: ^Window) -> bool {
	if ui.control_active(w.float_header_motion) {return true}
	for control in w.float_header_controls {if ui.control_active(control) {return true}}
	return false
}

@(private)
floating_capsule_pressed :: proc(w: ^Window, content: layout.Content) -> bool {
	p, ok := w.float_press.(Float_Capsules_Press)
	return ok && p.capsule == content
}

// The pointer left the floats: no capsule or header part is hovered.
floating_hover_clear :: proc(w: ^Window) {
	w.float_capsule_hover, w.float_header_hover = nil, nil
}

// Whether the window shows any floating pane, whose header controls then animate.
window_floats_shown :: proc(w: ^Window) -> bool {
	return len(w.panes) > 0 && w.panes[len(w.panes) - 1].floating
}

// Floating panes can cover the workspace chrome below the native title bar, including the vertical tab
// rail and Activity panel.
floating_area :: proc(w: ^Window) -> layout.Rect {
	top := window_title_height(w)
	return {0, top, f32(w.width), max(0, f32(w.height) - top)}
}

floating_header_height :: proc(w: ^Window) -> f32 {return FLOAT_HEADER * w.scale}

// The float header's buttons, right-aligned in the strip above the panes in FLOAT_HEADER_BUTTONS' order.
floating_header_buttons :: proc(w: ^Window, frame: layout.Rect) -> [len(FLOAT_HEADER_BUTTONS)]render.Rect {
	s := w.scale
	size := ui.HEIGHT_COMPACT * s
	strip := min(floating_header_height(w), frame.height)
	y := frame.y + max(0, (strip - size) / 2)
	end := frame.x + frame.width - ui.SPACE_1 * s
	buttons: [len(FLOAT_HEADER_BUTTONS)]render.Rect
	#reverse for &button in buttons {
		end -= size
		button = {max(frame.x, end), y, size, min(size, strip)}
	}
	return buttons
}

// Whether the point lies on a card with rounded corners; the corners outside the arcs are not on it.
@(private)
rounded_contains :: proc(r: layout.Rect, radius, x, y: f32) -> bool {
	if x < r.x || x >= r.x + r.width || y < r.y || y >= r.y + r.height {return false}
	rr := min(radius, r.width / 2, r.height / 2)
	cx := clamp(x, r.x + rr, r.x + r.width - rr)
	cy := clamp(y, r.y + rr, r.y + r.height - rr)
	return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= rr * rr
}

// The float header of the topmost float under the point: its frame anywhere outside its panes' cards.
floating_header_at :: proc(
	app: ^App,
	w: ^Window,
	x, y: f32,
) -> (
	root: layout.Node_Id,
	action: Float_Header_Action,
	ok: bool,
) {
	group, frame, found := floating_frame_at(w, x, y)
	if !found {return layout.INVALID_NODE, .None, false}
	radius := window_pane_radius(app, w)
	tree := window_tree(w)
	for pane in floating_rects(w) {
		if layout.float_root(tree, pane.node) != group {continue}
		if rounded_contains(pane.rect, radius, x, y) {return layout.INVALID_NODE, .None, false}
	}
	for button, i in floating_header_buttons(w, frame) {
		if render.rect_contains(button, x, y) {return group, FLOAT_HEADER_BUTTONS[i].action, true}
	}
	return group, .Move, true
}

// Draws a float's frame before its panes, which cover all of it but the float header. The header takes
// the title bar's colour and behaves as one flat control: the shared hover fill, pointer gloss and pressed
// fill without lifting, over the whole frame, with its handle and buttons in the strip at the top.
floating_header_draw :: proc(app: ^App, w: ^Window, root: layout.Node_Id) {
	frame, found := layout.float_rect(window_tree(w), root, floating_area(w))
	if !found {return}
	s := w.scale
	radius := window_pane_radius(app, w)
	r := render.Rect{frame.x, frame.y, frame.width, frame.height}
	if render.push_layer(&w.list, r, radius) != .None {return}
	ui.draw_rect(&w.list, {rect = r, color = app.theme.tab_bar})
	shown := w.float_header_shown == root
	hover, press: f32
	if shown {hover, press = w.float_header_motion.hover.value, w.float_header_motion.press.value}
	_, ink, err := ui.button_draw(
		&w.list,
		app.theme,
		{rect = r, hover = hover, press = press, radius = max(radius / s, 0.01), surface = .Flat},
		s,
		w.pointer,
	)
	if err != .None {return}
	ui.draw_rect(&w.list, {rect = r, color = app.theme.pane_border, radius = radius, stroke = max(1, s)})
	if hover <= 0 && press <= 0 {ink = app.theme.faint}
	strip := min(floating_header_height(w), frame.height)
	dot := max(1, 2 * s)
	cx, cy := frame.x + frame.width / 2, frame.y + strip / 2
	for row in 0 ..< 2 {
		for column in 0 ..< 3 {
			ui.draw_rect(
				&w.list,
				{
					rect = {
						cx + (f32(column) - 1) * 4 * s - dot / 2,
						cy + (f32(row) - 0.5) * 4 * s - dot / 2,
						dot,
						dot,
					},
					color = ink,
					radius = dot / 2,
				},
			)
		}
	}
	for rect, i in floating_header_buttons(w, frame) {
		button := FLOAT_HEADER_BUTTONS[i]
		b := ui.Button{rect = rect}
		if shown {
			b.hover = w.float_header_controls[i].hover.value
			b.press = w.float_header_controls[i].press.value
		}
		if button.action == .Close {
			danger := app.theme.error
			danger.a *= 0.14
			b.press_color = danger
		}
		face, button_ink, button_err := ui.button_draw(&w.list, app.theme, b, s, w.pointer)
		if button_err != .None {return}
		ui.icon_draw(&w.list, button.icon, face, button_ink, ui.ICON_BUTTON, s)
	}
}

// Closes every pane of a float, each as a close Reopen Closed can undo.
floating_close :: proc(app: ^App, w: ^Window, root: layout.Node_Id) {
	contents := make([dynamic]layout.Content, context.temp_allocator)
	layout.contents(window_tree(w), root, &contents)
	workspace, tab := w.workspace, w.workspace.selected
	for content in contents {
		node := layout.find_content(&workspace.tabs[tab].tree, content)
		if node != layout.INVALID_NODE {pane_close_at(app, workspace, tab, node)}
	}
}

@(private)
floating_header_fire :: proc(app: ^App, w: ^Window, content: layout.Content, action: Float_Header_Action) {
	tree := window_tree(w)
	node := layout.find_content(tree, content)
	if !layout.is_floating(tree, node) {return}
	switch action {
	case .None, .Move:
	case .Minimize:
		floating_minimize(app, w, node)
	case .Dock:
		if !layout.set_floating(tree, node, false) {return}
		window_relayout(app, w)
		layout_state_touch(app)
	case .Close:
		floating_close(app, w, layout.float_root(tree, node))
	}
}

// The rectangle a new floating pane takes: centred over the window work area, stepped from any already
// shown so none hides another exactly.
@(private)
floating_bounds_new :: proc(w: ^Window, tree: ^layout.Layout) -> layout.Rect {
	bounds := layout.Rect{0.2, 0.15, 0.6, 0.6}
	if w == nil {return bounds}
	area := floating_area(w)
	if area.width <= 0 || area.height <= 0 {return bounds}
	shown, _ := layout.float_counts(tree)
	step := f32(shown % 6) * FLOAT_CASCADE * w.scale
	bounds.x += step / area.width
	bounds.y += step / area.height
	return bounds
}

// Opens a terminal floating above the panes of the workspace's tab at `tab_index`, returning its session
// id. w shows the workspace, or is nil when no window does.
@(require_results)
floating_open :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	tab_index: int,
	launch: Pane_Launch,
	focus: bool,
) -> (
	u32,
	bool,
) {
	if tab_index < 0 || tab_index >= len(workspace.tabs) {return 0, false}
	id, opened := session_open(app, launch.command, launch.directory, launch.profile)
	if !opened {return 0, false}
	if !floating_attach(app, w, workspace, tab_index, {.Terminal, id}, focus) {
		session_close(app, id)
		return 0, false
	}
	return id, true
}

// Floats existing content, which no pane shows yet, above the tab's panes.
@(require_results)
floating_attach :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	tab_index: int,
	content: layout.Content,
	focus: bool,
) -> bool {
	tab := workspace.tabs[tab_index]
	shown := w != nil && !window_linked(w) && w.workspace == workspace
	node, err := layout.float_new(&tab.tree, content, floating_bounds_new(shown ? w : nil, &tab.tree))
	if err != nil {return false}
	layout_state_touch(app)
	if !shown {return true}
	if focus {
		if workspace.selected != tab_index {tab_select(app, w, tab_index)}
		pane_focus(app, w, node)
	}
	if workspace.selected == tab_index {window_floats_layout(app, w)}
	return true
}

// New Shell Float: a shell in a new float above the tab, started where the focused pane's program is working.
floating_new :: proc(app: ^App, w: ^Window) {
	launch: Pane_Launch
	if entry := focused_session(app, w); entry != nil {
		refused: bool
		launch.directory, refused = pane_directory(app, entry)
		if refused {notify_directory_refused(app)}
	}
	if _, ok := floating_open(app, w, w.workspace, w.workspace.selected, launch, true); !ok {
		notify(app, .Error, "Could not open a float.")
	}
}

// Float or Dock Pane: lifts the focused tiled pane above the others, or docks a floating one back where
// it came from.
floating_toggle :: proc(app: ^App, w: ^Window) {
	tree := window_tree(w)
	node := tree.focus
	if layout.is_floating(tree, node) {
		if !layout.set_floating(tree, node, false) {return}
	} else if !layout.set_floating(tree, node, true, floating_bounds_new(w, tree)) {
		notify(app, .Info, "The tab keeps one tiled pane; split it before floating this one.")
		return
	}
	window_relayout(app, w)
	layout_state_touch(app)
}

// Minimizes the focused floating group, or brings back the group minimized last.
floating_minimize_toggle :: proc(app: ^App, w: ^Window) {
	tree := window_tree(w)
	if layout.is_floating(tree, tree.focus) {
		floating_minimize(app, w, tree.focus)
		return
	}
	node := layout.float_latest(tree, true)
	if node == layout.INVALID_NODE {
		notify(app, .Info, "No float in this tab is minimized.")
		return
	}
	pane_focus(app, w, node)
}

// Minimizes every shown floating group, or when none is shown, brings every minimized one back.
floating_minimize_all_toggle :: proc(app: ^App, w: ^Window) {
	tree := window_tree(w)
	shown, minimized := layout.float_counts(tree)
	if shown == 0 && minimized == 0 {
		notify(app, .Info, "This tab has no floats.")
		return
	}
	focused := layout.is_floating(tree, tree.focus)
	if focused {focus_leave(app, w)}
	for _, i in tree.nodes {
		root := layout.Node_Id(i)
		if layout.float_is_root(tree, root) {_ = layout.float_minimize(tree, root, shown > 0)}
	}
	if shown == 0 {
		latest := layout.float_latest(tree, false)
		if latest != layout.INVALID_NODE {pane_focus(app, w, latest)}
	}
	window_floats_layout(app, w)
	if focused {focus_enter(app, w)}
	layout_state_touch(app)
}

floating_minimize :: proc(app: ^App, w: ^Window, node: layout.Node_Id) {
	tree := window_tree(w)
	focused := layout.float_root(tree, tree.focus) == layout.float_root(tree, node)
	if focused {focus_leave(app, w)}
	if !layout.float_minimize(tree, node, true) {return}
	window_floats_layout(app, w)
	if focused {focus_enter(app, w)}
	layout_state_touch(app)
}

// Floating panes are the last of the window's panes, topmost last.
floating_rects :: proc(w: ^Window) -> []layout.Pane_Rect {
	return w.panes[len(window_tiled_rects(w)):]
}

// The tiled panes the window shows, which come before any floating pane.
window_tiled_rects :: proc(w: ^Window) -> []layout.Pane_Rect {
	tiled := len(w.panes)
	for tiled > 0 && w.panes[tiled - 1].floating {tiled -= 1}
	return w.panes[:tiled]
}

// The topmost floating group whose frame, grown by `margin` on every side, holds the point: a pane of the
// group, its root and its frame.
@(private)
floating_group_at :: proc(
	w: ^Window,
	x, y, margin: f32,
) -> (
	pane: layout.Pane_Rect,
	root: layout.Node_Id,
	frame: layout.Rect,
	ok: bool,
) {
	last := layout.INVALID_NODE
	tree := window_tree(w)
	#reverse for candidate in floating_rects(w) {
		group := layout.float_root(tree, candidate.node)
		if group == last {continue}
		last = group
		r, found := layout.float_rect(tree, group, floating_area(w))
		if found && x >= r.x - margin && x < r.x + r.width + margin &&
		   y >= r.y - margin && y < r.y + r.height + margin {return candidate, group, r, true}
	}
	return {}, layout.INVALID_NODE, {}, false
}

// The topmost floating group whose frame contains the point.
floating_frame_at :: proc(w: ^Window, x, y: f32) -> (root: layout.Node_Id, rect: layout.Rect, ok: bool) {
	_, root, rect, ok = floating_group_at(w, x, y, 0)
	return
}

// The floating group whose outer edge band holds the point. Internal split edges remain dividers.
floating_edge_at :: proc(w: ^Window, x, y: f32) -> (pane: layout.Pane_Rect, edges: Float_Edges, ok: bool) {
	band := FLOAT_EDGE * w.scale / 2
	candidate, _, r, found := floating_group_at(w, x, y, band)
	if !found {return {}, {}, false}
	if x < r.x + band {edges += {.Left}}
	if x >= r.x + r.width - band {edges += {.Right}}
	if y < r.y + band {edges += {.Top}}
	if y >= r.y + r.height - band {edges += {.Bottom}}
	if edges == {} {return {}, {}, false}
	pane = candidate
	pane.rect = r
	return pane, edges, true
}

// Whether a floating group, its edge band or the capsule row covers the point.
floating_covers :: proc(w: ^Window, x, y: f32) -> bool {
	if _, _, edge := floating_edge_at(w, x, y); edge {return true}
	if _, _, frame := floating_frame_at(w, x, y); frame {return true}
	return render.rect_contains(w.float_capsule_group, x, y)
}

// Where a move or resize of the float holding the pane begins; false when the pane no longer floats.
@(private)
floating_grab :: proc(w: ^Window, pane: layout.Pane_Rect, x, y: f32) -> (Float_Grab, bool) {
	rect, found := layout.float_rect(window_tree(w), pane.node, floating_area(w))
	return {content = pane.content, start = {x, y}, rect = rect}, found
}

floating_drag_rect :: proc(
	area, original: layout.Rect,
	delta: [2]f32,
	edges: Float_Edges,
	scale: f32,
) -> layout.Rect {
	r := original
	if edges == {} {
		r.x = clamp(r.x + delta.x, area.x, area.x + area.width - r.width)
		r.y = clamp(r.y + delta.y, area.y, area.y + area.height - r.height)
		return r
	}
	min_width := min(FLOAT_MINIMUM_WIDTH * scale, area.width)
	min_height := min(FLOAT_MINIMUM_HEIGHT * scale, area.height)
	right, bottom := r.x + r.width, r.y + r.height
	if .Left in edges {r.x = clamp(r.x + delta.x, area.x, right - min_width)}
	if .Right in edges {right = clamp(right + delta.x, r.x + min_width, area.x + area.width)}
	if .Top in edges {r.y = clamp(r.y + delta.y, area.y, bottom - min_height)}
	if .Bottom in edges {bottom = clamp(bottom + delta.y, r.y + min_height, area.y + area.height)}
	r.width, r.height = right - r.x, bottom - r.y
	return r
}

floating_bounds_for_rect :: proc(area, rect: layout.Rect) -> layout.Rect {
	return {
		(rect.x - area.x) / area.width,
		(rect.y - area.y) / area.height,
		rect.width / area.width,
		rect.height / area.height,
	}
}

// Follows the pointer while a float moves or resizes: a header press past FLOAT_DRAG_THRESHOLD becomes a
// move. False when no such press is held, or its float no longer floats, which ends it.
@(private)
floating_drag_follow :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	grab: Float_Grab
	edges: Float_Edges
	#partial switch p in w.float_press {
	case Float_Header_Press:
		if max(abs(x - p.start.x), abs(y - p.start.y)) < FLOAT_DRAG_THRESHOLD * w.scale {return true}
		w.float_press = Float_Move{p.grab}
		pane_header_cancel(w)
		grab = p.grab
	case Float_Move:
		grab = p.grab
	case Float_Resize:
		grab, edges = p.grab, p.edges
	case:
		return false
	}
	tree := window_tree(w)
	node := layout.find_content(tree, grab.content)
	if !layout.is_floating(tree, node) {w.float_press = nil; return false}
	area := floating_area(w)
	if area.width <= 0 || area.height <= 0 {return true}
	r := floating_drag_rect(area, grab.rect, {x - grab.start.x, y - grab.start.y}, edges, w.scale)
	bounds := floating_bounds_for_rect(area, r)
	if layout.float_set_bounds(tree, node, bounds) {window_floats_layout(app, w)}
	return true
}

// Moves while the float surface holds Left: the float or the capsule row follows the pointer. False when
// no drag is held, so the move reaches the surfaces; a move without Left ends the drag the release missed.
floating_pointer_move :: proc(app: ^App, w: ^Window, e: input.Mouse_Move_Event) -> bool {
	switch _ in w.float_press {
	case nil, Float_Button_Press:
		return false
	case Float_Header_Press, Float_Move, Float_Resize, Float_Capsules_Press, Float_Capsules_Move:
	}
	if .Left not_in e.buttons {w.float_press = nil; return false}
	x, y := f32(e.x), f32(e.y)
	if floating_capsules_follow(w, x, y) {
		pointer_set(app, w, .Arrow)
		return true
	}
	if !floating_drag_follow(app, w, x, y) {return false}
	resize, resizing := w.float_press.(Float_Resize)
	pointer_set(app, w, resizing ? floating_edge_cursor(resize.edges) : .Arrow)
	return true
}

@(private)
floating_edge_cursor :: proc(edges: Float_Edges) -> platform.Cursor_Shape {
	if (.Left in edges && .Top in edges) || (.Right in edges && .Bottom in edges) {
		return .Resize_Northwest_Southeast
	}
	if (.Right in edges && .Top in edges) || (.Left in edges && .Bottom in edges) {
		return .Resize_Northeast_Southwest
	}
	return edges & {.Left, .Right} != {} ? .Resize_Horizontal : .Resize_Vertical
}

Float_Capsule :: struct {
	root:    layout.Node_Id,
	content: layout.Content,
	rect:    render.Rect,
	order:   u64,
}

floating_capsule_row_fit :: proc(widths: []f32, area_width, preferred_gap: f32) -> (start, gap: f32) {
	if len(widths) == 0 || area_width <= 0 {return}
	gap = preferred_gap
	total := gap * f32(len(widths) - 1)
	for width in widths {total += width}
	if total > area_width {
		gap = len(widths) > 1 ? min(preferred_gap, area_width / f32(len(widths) * 4)) : 0
		limit := max(0, (area_width - gap * f32(len(widths) - 1)) / f32(len(widths)))
		total = gap * f32(len(widths) - 1)
		for &width in widths {
			width = min(width, limit)
			total += width
		}
	}
	start = max(0, area_width - total)
	return
}

// Cached geometry keeps title measurement and allocation out of frame building and pointer hit tests.
floating_capsules_refresh :: proc(app: ^App, w: ^Window) {
	clear(&w.float_capsules)
	clear(&w.float_capsule_widths)
	w.float_capsule_group = {}
	tree := window_tree(w)
	if tree == nil || window_linked(w) {return}
	s := w.scale
	for _, i in tree.nodes {
		root := layout.Node_Id(i)
		if !layout.float_is_root(tree, root) {continue}
		floating, ok := layout.float_of(tree, root)
		if !ok || !floating.minimized {continue}
		pane_id := layout.float_pane(tree, root)
		if pane_id == layout.INVALID_NODE {continue}
		content, is_pane := layout.pane_content(tree, pane_id)
		if !is_pane {continue}
		capsule := Float_Capsule {
			root = root,
			content = content,
			order = layout.float_order(tree, root),
		}
		if _, err := append(&w.float_capsules, capsule); err != nil {
			clear(&w.float_capsules)
			log.error("storing float capsules failed")
			return
		}
		for j := len(w.float_capsules) - 1; j > 0 &&
		     w.float_capsules[j - 1].order > capsule.order; j -= 1 {
			w.float_capsules[j - 1], w.float_capsules[j] = w.float_capsules[j], w.float_capsules[j - 1]
		}
	}
	if len(w.float_capsules) == 0 {return}
	label := ui.text_styled(&w.ui_text, .Body)
	if err := resize(&w.float_capsule_widths, len(w.float_capsules)); err != nil {
		clear(&w.float_capsules)
		log.error("storing float capsule widths failed")
		return
	}
	area := floating_area(w)
	margin := ui.SPACE_3 * s
	for &capsule, i in w.float_capsules {
		entry := workspace_session_for_content(app, capsule.content)
		text := ui.text_width(&label, content_pane_title(app, entry, capsule.content))
		w.float_capsule_widths[i] = clamp(
			text + (ui.SPACE_3 + ui.ICON_BUTTON + ui.SPACE_2 + ui.SPACE_3) * s,
			FLOAT_CAPSULE_MINIMUM * s,
			FLOAT_CAPSULE_MAXIMUM * s,
		)
		capsule.rect.height = ui.HEIGHT_STANDARD * s
	}
	start, gap := floating_capsule_row_fit(
		w.float_capsule_widths[:],
		max(0, area.width - 2 * margin),
		ui.SPACE_2 * s,
	)
	row_width := gap * f32(len(w.float_capsules) - 1)
	for width in w.float_capsule_widths {row_width += width}
	height := ui.HEIGHT_STANDARD * s
	x := area.x + margin + start
	y := area.y + area.height - height - margin
	if anchor, placed := w.float_capsule_anchor.?; placed {
		x = area.x + anchor.x * max(0, area.width - row_width)
		y = area.y + anchor.y * max(0, area.height - height)
	}
	x = clamp(x, area.x, max(area.x, area.x + area.width - row_width))
	y = clamp(y, area.y, max(area.y, area.y + area.height - height))
	w.float_capsule_group = {x, y, row_width, height}
	for &capsule, i in w.float_capsules {
		capsule.rect.x, capsule.rect.y, capsule.rect.width = x, y, w.float_capsule_widths[i]
		x += w.float_capsule_widths[i] + gap
	}
}

@(private)
floating_capsule_at :: proc(w: ^Window, x, y: f32) -> Maybe(Float_Capsule) {
	for capsule in w.float_capsules {
		if render.rect_contains(capsule.rect, x, y) {return capsule}
	}
	return nil
}

// Follows the pointer while the capsule row moves: a press past FLOAT_DRAG_THRESHOLD becomes a move, which
// places the row where the user leaves it. False when no row press is held.
@(private)
floating_capsules_follow :: proc(w: ^Window, x, y: f32) -> bool {
	grab: Float_Row_Grab
	#partial switch p in w.float_press {
	case Float_Capsules_Press:
		if max(abs(x - p.start.x), abs(y - p.start.y)) < FLOAT_DRAG_THRESHOLD * w.scale {return true}
		w.float_press = Float_Capsules_Move{p.grab}
		grab = p.grab
	case Float_Capsules_Move:
		grab = p.grab
	case:
		return false
	}
	area := floating_area(w)
	r := grab.rect
	r.x = clamp(r.x + x - grab.start.x, area.x, max(area.x, area.x + area.width - r.width))
	r.y = clamp(r.y + y - grab.start.y, area.y, max(area.y, area.y + area.height - r.height))
	shift := [2]f32{r.x - w.float_capsule_group.x, r.y - w.float_capsule_group.y}
	w.float_capsule_group = r
	for &capsule in w.float_capsules {
		capsule.rect.x += shift.x
		capsule.rect.y += shift.y
	}
	x_travel, y_travel := max(0, area.width - r.width), max(0, area.height - r.height)
	w.float_capsule_anchor = [2]f32 {
		x_travel > 0 ? (r.x - area.x) / x_travel : 0,
		y_travel > 0 ? (r.y - area.y) / y_travel : 0,
	}
	w.dirty = true
	return true
}

floating_capsules_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if len(w.float_capsules) == 0 {return .Ok}
	s := w.scale
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	label := ui.text_styled(&w.ui_text, .Body)
	for capsule in w.float_capsules {
		r := capsule.rect
		radius := ui.pill_radius(r)
		panel := ui.popover_panel(r, s)
		panel.radius = radius
		if ui.panel_draw(&w.list, panel, app.theme) != .None {return .Ok}
		hovered := w.float_capsule_hover == capsule.content
		face, ink, err := ui.button_draw(
			&w.list,
			app.theme,
			{
				rect = r,
				hover = hovered ? 1 : 0,
				press = floating_capsule_pressed(w, capsule.content) ? 1 : 0,
				radius = radius / s,
				surface = .Flat_Unfilled,
			},
			s,
			w.pointer,
		)
		if err != .None {return .Ok}
		icon := render.Rect {
			face.x + ui.SPACE_3 * s,
			face.y + (face.height - ui.ICON_BUTTON * s) / 2,
			ui.ICON_BUTTON * s,
			ui.ICON_BUTTON * s,
		}
		entry := workspace_session_for_content(app, capsule.content)
		badge, found := content_badge(app, entry, capsule.content.kind, ui.ICON_BUTTON * s)
		if found != .Ok {return found}
		if badge.icon != .None {
			ui.icon_draw(&w.list, badge.icon, icon, ink, ui.ICON_BUTTON, s)
		} else if result := ui.shell_badge_draw(
			&w.list,
			&w.ui_text,
			app.theme,
			icon,
			badge.glyph,
			s,
			badge.atlas,
		); result != .Ok {return result}
		text_x := icon.x + icon.width + ui.SPACE_2 * s
		if result := ui.draw_fading_text(
			&label,
			&w.list,
			content_pane_title(app, entry, capsule.content),
			text_x,
			face.y + (face.height - label.line_height) / 2 + label.ascent,
			ink,
			max(0, face.x + face.width - ui.SPACE_3 * s - text_x),
		); result != .Ok {return result}
	}
	return .Ok
}

// Pointer surface: float edges, float headers and the movable capsule row. Headers, content and scrollbars
// of the panes in a float are reached through their own surfaces, which test the topmost pane.

floating_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if _, _, edge := floating_edge_at(w, x, y); edge {return true}
	if _, _, header := floating_header_at(app, w, x, y); header {return true}
	return render.rect_contains(w.float_capsule_group, x, y)
}

floating_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	hover: Maybe(layout.Content)
	header: Maybe(Float_Header_Spot)
	action := Float_Header_Action.None
	edges, edge := Float_Edges{}, false
	if owner == .Floating {
		if capsule, found := floating_capsule_at(w, x, y).?; found {hover = capsule.content}
		_, edges, edge = floating_edge_at(w, x, y)
		if hover == nil && !edge {
			if root, at, over := floating_header_at(app, w, x, y); over {
				header, action = Float_Header_Spot{root, at}, at
			}
		}
	}
	if hover != w.float_capsule_hover {w.float_capsule_hover, w.dirty = hover, true}
	if header != w.float_header_hover {w.float_header_hover, w.dirty = header, true}
	if owner != .Floating {return}
	switch {
	case hover != nil, action != .None && action != .Move:
		pointer_set(app, w, .Hand)
	case edge:
		pointer_set(app, w, floating_edge_cursor(edges))
	case:
		pointer_set(app, w, .Arrow)
	}
}

floating_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if e.button != .Left {return}
	x, y := f32(e.x), f32(e.y)
	if render.rect_contains(w.float_capsule_group, x, y) {
		press := Float_Capsules_Press {
			grab = {start = {x, y}, rect = w.float_capsule_group},
		}
		if capsule, found := floating_capsule_at(w, x, y).?; found {press.capsule = capsule.content}
		w.float_press = press
		w.dirty = true
		return
	}
	pane, edges, edge := floating_edge_at(w, x, y)
	if !edge {
		root, action, header := floating_header_at(app, w, x, y)
		if !header {return}
		tree := window_tree(w)
		node := tree.focus
		if layout.float_root(tree, node) != root {node = layout.float_pane(tree, root)}
		w.dirty = true
		if action != .Move {
			// A button fires on release over itself, like every other control.
			content, _ := layout.pane_content(tree, node)
			w.float_press = Float_Button_Press{content, action}
			return
		}
		pane_focus(app, w, node)
		for shown in w.panes {
			if shown.node != node {continue}
			if grab, found := floating_grab(w, shown, x, y); found {w.float_press = Float_Header_Press{grab}}
			break
		}
		return
	}
	pane_focus(app, w, pane.node)
	// Focus raises the pane, which a resize then follows from its current rectangle.
	for shown in w.panes {if shown.content == pane.content {pane = shown}}
	if grab, found := floating_grab(w, pane, x, y); found {w.float_press = Float_Resize{grab, edges}}
}

floating_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Left {return false}
	x, y := f32(e.x), f32(e.y)
	switch p in w.float_press {
	case nil:
		return false
	case Float_Header_Press, Float_Move, Float_Resize:
		moved := floating_dragging(w)
		if moved {_ = floating_drag_follow(app, w, x, y)}
		w.float_press = nil
		if moved {layout_state_touch(app)}
		pane_header_cancel(w)
	case Float_Button_Press:
		under := Float_Header_Action.None
		tree := window_tree(w)
		target := layout.float_root(tree, layout.find_content(tree, p.content))
		if root, action, over := floating_header_at(app, w, x, y); over && root == target {under = action}
		w.float_press = nil
		w.dirty = true
		if under == p.action {floating_header_fire(app, w, p.content, p.action)}
	case Float_Capsules_Move:
		_ = floating_capsules_follow(w, x, y)
		w.float_press = nil
	case Float_Capsules_Press:
		w.float_press = nil
		pressed, armed := p.capsule.?
		if !armed {return true}
		w.dirty = true
		if capsule, found := floating_capsule_at(w, x, y).?; found && capsule.content == pressed {
			pane_focus(app, w, layout.find_content(window_tree(w), pressed))
			layout_state_touch(app)
		}
	}
	return true
}

// Capture loss ends any press. A move or resize leaves the float where it stands, which the layout then
// saves as it does on a release.
floating_pointer_cancel :: proc(app: ^App, w: ^Window) {
	if floating_dragging(w) {layout_state_touch(app)}
	w.float_press = nil
	floating_hover_clear(w)
}

floating_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	if _, capsule := floating_capsule_at(w, x, y).?; capsule {return "Restore float"}
	_, action, header := floating_header_at(app, w, x, y)
	if !header {return ""}
	switch action {
	case .Minimize: return "Minimize float"
	case .Dock: return "Dock into the tab"
	case .Close: return "Close float"
	case .Move, .None:
	}
	return "Move float"
}

when AIO_CONTROL {
	floating_state_report :: proc(r: ^State_Report, w: ^Window) {
		hover := (w.float_header_hover.? or_else Float_Header_Spot{}).action
		state_value(r, "panes.floating", len(floating_rects(w)))
		state_value(r, "panes.capsules", len(w.float_capsules))
		state_rect(r, "panes.capsule_group", w.float_capsule_group)
		state_value(r, "panes.float_dragging", floating_dragging(w))
		state_value(r, "panes.float_header_hover", hover)
		state_valuef(r, "panes.float_header_hover_value", "%g", w.float_header_motion.hover.value)
		state_valuef(r, "panes.float_header_press_value", "%g", w.float_header_motion.press.value)
	}
}

// Floating pane pointer surface: leave and held drag

@(private)
floating_leave :: proc(_: ^App, w: ^Window) {
	floating_hover_clear(w)
}

@(private)
floating_held :: proc(app: ^App, w: ^Window, _: Pointer_Target, e: input.Mouse_Move_Event) -> Pointer_Held {
	return floating_pointer_move(app, w, e) ? .Taken : .Free
}
