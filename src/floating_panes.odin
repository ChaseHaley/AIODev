package main

import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:math"

// Floating panes (WORK-045). A floating pane draws above its tab's tiled panes, so opening, moving,
// minimizing or closing it never resizes or reflows them. It moves by its header, resizes by its edges,
// and minimizes to a capsule along the bottom of the tab; a click on the capsule brings it back. The tree
// keeps its slot, so session lifetime, status, saving and closing treat it as any other pane. See
// src/layout/floats.odin.

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

Float_Edge :: enum u8 {
	Left,
	Top,
	Right,
	Bottom,
}

// The edges a resize moves; none moves the whole pane.
Float_Edges :: bit_set[Float_Edge]

Float_Drag :: struct {
	pressed, active: bool,
	// Content survives the node renumbering a close elsewhere in the tree can cause.
	content:         layout.Content,
	edges:           Float_Edges,
	start:           [2]f32,
	// The pane's rectangle when the press began, in pixels.
	rect:            layout.Rect,
}

// Whether the window shows any floating pane, whose header controls then animate.
window_floats_shown :: proc(w: ^Window) -> bool {
	return len(w.panes) > 0 && w.panes[len(w.panes) - 1].floating
}

// The rectangle a new floating pane takes: centred over the tiled panes, stepped from any already shown so
// none hides another exactly.
@(private)
floating_bounds_new :: proc(app: ^App, w: ^Window, tree: ^layout.Layout) -> layout.Rect {
	bounds := layout.Rect{0.2, 0.15, 0.6, 0.6}
	if w == nil {return bounds}
	area := window_content_area(app, w)
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
	if !session_open(app, launch.command, launch.directory, launch.profile) {return 0, false}
	id := app.next_session_id
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
	shown := w != nil && !w.linked && w.workspace == workspace
	node, err := layout.float_new(&tab.tree, content, floating_bounds_new(app, shown ? w : nil, &tab.tree))
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

// New Floating Shell: a shell above the tab, started where the focused pane's program is working.
floating_new :: proc(app: ^App, w: ^Window) {
	launch: Pane_Launch
	if entry := focused_session(app, w); entry != nil {
		refused: bool
		launch.directory, refused = pane_directory(app, entry)
		if refused {notify_directory_refused(app)}
	}
	if _, ok := floating_open(app, w, w.workspace, w.workspace.selected, launch, true); !ok {
		notify(app, .Error, "Could not open a floating pane.")
	}
}

// Float or Dock Pane: lifts the focused tiled pane above the others, or docks a floating one back where
// it came from.
floating_toggle :: proc(app: ^App, w: ^Window) {
	node := w.tree.focus
	if layout.is_floating(w.tree, node) {
		if !layout.set_floating(w.tree, node, false) {return}
	} else if !layout.set_floating(w.tree, node, true, floating_bounds_new(app, w, w.tree)) {
		notify(app, .Info, "The tab keeps one tiled pane; split it before floating this one.")
		return
	}
	window_relayout(app, w)
	layout_state_touch(app)
}

// Minimizes the focused floating pane, or brings back the one minimized last.
floating_minimize_toggle :: proc(app: ^App, w: ^Window) {
	if layout.is_floating(w.tree, w.tree.focus) {
		floating_minimize(app, w, w.tree.focus)
		return
	}
	node := layout.float_latest(w.tree, true)
	if node == layout.INVALID_NODE {
		notify(app, .Info, "No floating pane in this tab is minimized.")
		return
	}
	pane_focus(app, w, node)
}

// Minimizes every shown floating pane, or when none is shown, brings every minimized one back.
floating_minimize_all_toggle :: proc(app: ^App, w: ^Window) {
	shown, minimized := layout.float_counts(w.tree)
	if shown == 0 && minimized == 0 {
		notify(app, .Info, "This tab has no floating panes.")
		return
	}
	focused := layout.is_floating(w.tree, w.tree.focus)
	if focused {focus_leave(app, w)}
	for _, i in w.tree.nodes {_ = layout.float_minimize(w.tree, layout.Node_Id(i), shown > 0)}
	if shown == 0 {
		latest := layout.float_latest(w.tree, false)
		if latest != layout.INVALID_NODE {pane_focus(app, w, latest)}
	}
	window_floats_layout(app, w)
	if focused {focus_enter(app, w)}
	layout_state_touch(app)
}

floating_minimize :: proc(app: ^App, w: ^Window, node: layout.Node_Id) {
	focused := w.tree.focus == node
	if focused {focus_leave(app, w)}
	if !layout.float_minimize(w.tree, node, true) {return}
	window_floats_layout(app, w)
	if focused {focus_enter(app, w)}
	layout_state_touch(app)
}

// Draws the shadow a floating card casts on the panes below it; the card itself draws as any pane's.
floating_frame_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return}
	r := pane.rect
	_ = ui.panel_draw(
		&w.list,
		{
			rect = {r.x, r.y, r.width, r.height},
			radius = window_pane_radius(app, w),
			scale = w.scale,
			shadow_y = 8,
			softness = 28,
			border = .Expanded,
		},
		app.theme,
	)
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

// The floating pane whose edge band holds the point, and which edges it would move. A point inside a
// card, away from its edges, belongs to that card, and so does any edge of a card below it.
floating_edge_at :: proc(w: ^Window, x, y: f32) -> (pane: layout.Pane_Rect, edges: Float_Edges, ok: bool) {
	band := FLOAT_EDGE * w.scale / 2
	floats := floating_rects(w)
	#reverse for candidate in floats {
		r := candidate.rect
		if x < r.x - band || x >= r.x + r.width + band || y < r.y - band || y >= r.y + r.height + band {
			continue
		}
		if x < r.x + band {edges += {.Left}}
		if x >= r.x + r.width - band {edges += {.Right}}
		if y < r.y + band {edges += {.Top}}
		if y >= r.y + r.height - band {edges += {.Bottom}}
		if edges == {} {return {}, {}, false}
		return candidate, edges, true
	}
	return {}, {}, false
}

// Whether a floating pane, its edge band or a capsule covers the point, hiding the dividers below it.
floating_covers :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if _, _, edge := floating_edge_at(w, x, y); edge {return true}
	if pane, found := layout.hit_test(w.panes[:], x, y); found && pane.floating {return true}
	_, capsule := floating_capsule_at(app, w, x, y).?
	return capsule
}

floating_drag_press :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect, edges: Float_Edges, x, y: f32) {
	w.float_drag = {
		pressed = true,
		active  = edges != {},
		content = pane.content,
		edges   = edges,
		start   = {x, y},
		rect    = pane.rect,
	}
}

// Follows the pointer while a floating pane moves or resizes. False when no such drag is held.
floating_drag_move :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	d := &w.float_drag
	if !d.pressed {return false}
	dx, dy := x - d.start.x, y - d.start.y
	if !d.active {
		if max(abs(dx), abs(dy)) < FLOAT_DRAG_THRESHOLD * w.scale {return true}
		d.active = true
		pane_header_cancel(w)
	}
	node := layout.find_content(w.tree, d.content)
	if !layout.is_floating(w.tree, node) {w.float_drag = {}; return false}
	area := window_content_area(app, w)
	if area.width <= 0 || area.height <= 0 {return true}
	r := d.rect
	if d.edges == {} {
		r.x = clamp(r.x + dx, area.x, area.x + area.width - r.width)
		r.y = clamp(r.y + dy, area.y, area.y + area.height - r.height)
	} else {
		min_width := min(FLOAT_MINIMUM_WIDTH * w.scale, area.width)
		min_height := min(FLOAT_MINIMUM_HEIGHT * w.scale, area.height)
		right, bottom := r.x + r.width, r.y + r.height
		if .Left in d.edges {r.x = clamp(r.x + dx, area.x, right - min_width)}
		if .Right in d.edges {right = clamp(right + dx, r.x + min_width, area.x + area.width)}
		if .Top in d.edges {r.y = clamp(r.y + dy, area.y, bottom - min_height)}
		if .Bottom in d.edges {bottom = clamp(bottom + dy, r.y + min_height, area.y + area.height)}
		r.width, r.height = right - r.x, bottom - r.y
	}
	bounds := layout.Rect {
		(r.x - area.x) / area.width,
		(r.y - area.y) / area.height,
		r.width / area.width,
		r.height / area.height,
	}
	if layout.float_set_bounds(w.tree, node, bounds) {window_floats_layout(app, w)}
	return true
}

floating_drag_release :: proc(app: ^App, w: ^Window, x, y: f32) {
	if !w.float_drag.pressed {return}
	moved := w.float_drag.active
	if moved {_ = floating_drag_move(app, w, x, y)}
	w.float_drag = {}
	if moved {layout_state_touch(app)}
}

@(private)
floating_edge_cursor :: proc(edges: Float_Edges) -> platform.Cursor_Shape {
	horizontal := edges & {.Left, .Right} != {}
	vertical := edges & {.Top, .Bottom} != {}
	if horizontal && vertical {return .Resize_All}
	return horizontal ? .Resize_Horizontal : .Resize_Vertical
}

// Capsules

Float_Capsule :: struct {
	node:    layout.Node_Id,
	content: layout.Content,
	rect:    render.Rect,
}

// One capsule per minimized floating pane, centred along the bottom of the tab's panes in temporary memory.
floating_capsules :: proc(app: ^App, w: ^Window) -> []Float_Capsule {
	if w.tree == nil || w.linked {return nil}
	nodes := make([dynamic]layout.Node_Id, context.temp_allocator)
	layout.floats_minimized(w.tree, &nodes)
	if len(nodes) == 0 {return nil}
	area := window_content_area(app, w)
	s := w.scale
	label := ui.text_styled(&w.ui_text, .Body)
	capsules := make([]Float_Capsule, len(nodes), context.temp_allocator)
	height, gap := ui.HEIGHT_STANDARD * s, ui.SPACE_2 * s
	total := -gap
	for node, i in nodes {
		content := w.tree.nodes[node].(layout.Pane).content
		text := ui.text_width(&label, floating_title(app, content))
		width := clamp(text + (ui.SPACE_3 + ui.ICON_BUTTON + ui.SPACE_2 + ui.SPACE_3) * s,
			FLOAT_CAPSULE_MINIMUM * s, FLOAT_CAPSULE_MAXIMUM * s)
		capsules[i] = {node = node, content = content, rect = {0, 0, math.round(width), height}}
		total += math.round(width) + gap
	}
	x := math.round(area.x + max(0, (area.width - total) / 2))
	y := math.round(area.y + area.height - height - ui.SPACE_3 * s)
	for &capsule in capsules {
		capsule.rect.x, capsule.rect.y = x, y
		x += capsule.rect.width + gap
	}
	return capsules
}

@(private)
floating_capsule_at :: proc(app: ^App, w: ^Window, x, y: f32) -> Maybe(Float_Capsule) {
	for capsule in floating_capsules(app, w) {
		if rect_contains(capsule.rect, x, y) {return capsule}
	}
	return nil
}

// The name a pane's header shows.
floating_title :: proc(app: ^App, content: layout.Content) -> string {
	if entry := workspace_session_for_content(app, content); entry != nil {
		return entry.name != "" ? entry.name : pane_header_title(&entry.header)
	}
	return content_title(app, content)
}

floating_capsules_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	capsules := floating_capsules(app, w)
	if len(capsules) == 0 {return .Ok}
	s := w.scale
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	label := ui.text_styled(&w.ui_text, .Body)
	for capsule in capsules {
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
				press = ui.armed_is(w.float_capsule_armed, capsule.content) ? 1 : 0,
				radius = radius / s,
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
		switch capsule.content.kind {
		case .Terminal:
			entry := workspace_session_for_content(app, capsule.content)
			badge, atlas, found := pane_icon(app, entry, ui.ICON_BUTTON * s)
			if found != .Ok {return found}
			if result := ui.shell_badge_draw(&w.list, &w.ui_text, app.theme, icon, badge, s, atlas);
			   result != .Ok {return result}
		case .Markdown:
			ui.icon_draw(&w.list, .Markdown, icon, ink, ui.ICON_BUTTON, s)
		case .Settings:
			ui.icon_draw(&w.list, .Settings, icon, ink, ui.ICON_BUTTON, s)
		}
		text_x := icon.x + icon.width + ui.SPACE_2 * s
		if result := ui.draw_fading_text(
			&label,
			&w.list,
			floating_title(app, capsule.content),
			text_x,
			face.y + (face.height - label.line_height) / 2 + label.ascent,
			ink,
			max(0, face.x + face.width - ui.SPACE_3 * s - text_x),
		); result != .Ok {return result}
	}
	return .Ok
}

// Pointer surface: floating pane edges and capsules. Headers, content and scrollbars of a floating pane
// are reached through their own surfaces, which test the topmost pane.

floating_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if _, _, edge := floating_edge_at(w, x, y); edge {return true}
	_, capsule := floating_capsule_at(app, w, x, y).?
	return capsule
}

floating_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	hover: Maybe(layout.Content)
	if owner == .Floating {
		if capsule, found := floating_capsule_at(app, w, x, y).?; found {hover = capsule.content}
	}
	if hover != w.float_capsule_hover {w.float_capsule_hover, w.dirty = hover, true}
	if owner != .Floating {return}
	if hover != nil {
		pointer_set(app, w, .Hand)
	} else if _, edges, edge := floating_edge_at(w, x, y); edge {
		pointer_set(app, w, floating_edge_cursor(edges))
	}
}

floating_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button != .Left {return}
	x, y := f32(e.x), f32(e.y)
	if capsule, found := floating_capsule_at(app, w, x, y).?; found {
		ui.armed_press(&w.float_capsule_armed, capsule.content)
		w.dirty = true
		return
	}
	pane, edges, edge := floating_edge_at(w, x, y)
	if !edge {return}
	pane_focus(app, w, pane.node)
	// Focus raises the pane, which a resize then follows from its current rectangle.
	for shown in w.panes {if shown.content == pane.content {pane = shown}}
	floating_drag_press(app, w, pane, edges, x, y)
}

floating_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left {return false}
	x, y := f32(e.x), f32(e.y)
	if w.float_drag.pressed {
		floating_drag_release(app, w, x, y)
		w.header_buttons -= {.Left}
		pane_header_cancel(w)
		return true
	}
	if !ui.armed_down(w.float_capsule_armed) {return false}
	under: layout.Content
	capsule, found := floating_capsule_at(app, w, x, y).?
	if found {under = capsule.content}
	fired, ok := ui.armed_release(&w.float_capsule_armed, under)
	w.dirty = true
	if ok && found {
		pane_focus(app, w, layout.find_content(w.tree, fired))
		layout_state_touch(app)
	}
	return true
}

floating_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	_, capsule := floating_capsule_at(app, w, x, y).?
	return capsule ? "Restore floating pane" : ""
}
