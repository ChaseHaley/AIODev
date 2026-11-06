package main

import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:log"

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
// The strip along the top of a split floating window that moves the whole window, in DIPs. Its panes'
// headers rearrange them instead.
FLOAT_GRIP :: ui.SPACE_3

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
	// The press began on a split floating window's grip.
	grip:            bool,
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

// Floating panes can cover the workspace chrome below the native title bar, including the vertical tab
// rail and Activity panel.
floating_area :: proc(w: ^Window) -> layout.Rect {
	top := window_title_height(w)
	return {0, top, f32(w.width), max(0, f32(w.height) - top)}
}

floating_grip :: proc(w: ^Window) -> f32 {return FLOAT_GRIP * w.scale}

// The grip strip of the topmost split floating window under the point.
floating_grip_at :: proc(w: ^Window, x, y: f32) -> (root: layout.Node_Id, ok: bool) {
	group, frame, found := floating_frame_at(w, x, y)
	if !found {return layout.INVALID_NODE, false}
	content := layout.float_content_rect(w.tree, group, frame, floating_grip(w))
	if y >= content.y {return layout.INVALID_NODE, false}
	return group, true
}

// Draws a split floating window's grip strip, just before its panes. The strip is a flat control: it takes
// the shared hover fill, pointer gloss and pressed fill without lifting, and its handle brightens with
// them.
floating_grip_draw :: proc(app: ^App, w: ^Window, root: layout.Node_Id) {
	frame, found := layout.float_rect(w.tree, root, floating_area(w))
	if !found {return}
	content := layout.float_content_rect(w.tree, root, frame, floating_grip(w))
	if content.y <= frame.y {return}
	height := content.y - frame.y
	radius := window_pane_radius(app, w)
	if render.push_layer(&w.list, {frame.x, frame.y, frame.width, height}) != .None {return}
	ui.draw_rect(
		&w.list,
		{
			rect = {frame.x, frame.y, frame.width, height + radius},
			color = color(app.settings.colors.background),
			radius = radius,
		},
	)
	s := w.scale
	hover, press: f32
	if w.float_grip_shown == root {
		hover, press = w.float_grip_motion.hover.value, w.float_grip_motion.press.value
	}
	flat := app.theme
	flat.hover_lift = 0
	face_rect := render.Rect {
		frame.x + ui.SPACE_1 * s,
		frame.y + s,
		max(0, frame.width - 2 * ui.SPACE_1 * s),
		max(0, height - 2 * s),
	}
	face, ink, err := ui.button_draw(
		&w.list,
		flat,
		{rect = face_rect, hover = hover, press = press, radius = face_rect.height / 2 / s},
		s,
		w.pointer,
	)
	if err != .None {return}
	if hover <= 0 && press <= 0 {ink = app.theme.faint}
	dot := max(1, 2 * s)
	cx, cy := face.x + face.width / 2, face.y + face.height / 2
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
	} else if !layout.set_floating(w.tree, node, true, floating_bounds_new(w, w.tree)) {
		notify(app, .Info, "The tab keeps one tiled pane; split it before floating this one.")
		return
	}
	window_relayout(app, w)
	layout_state_touch(app)
}

// Minimizes the focused floating group, or brings back the group minimized last.
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

// Minimizes every shown floating group, or when none is shown, brings every minimized one back.
floating_minimize_all_toggle :: proc(app: ^App, w: ^Window) {
	shown, minimized := layout.float_counts(w.tree)
	if shown == 0 && minimized == 0 {
		notify(app, .Info, "This tab has no floating panes.")
		return
	}
	focused := layout.is_floating(w.tree, w.tree.focus)
	if focused {focus_leave(app, w)}
	for _, i in w.tree.nodes {
		root := layout.Node_Id(i)
		if layout.float_is_root(w.tree, root) {_ = layout.float_minimize(w.tree, root, shown > 0)}
	}
	if shown == 0 {
		latest := layout.float_latest(w.tree, false)
		if latest != layout.INVALID_NODE {pane_focus(app, w, latest)}
	}
	window_floats_layout(app, w)
	if focused {focus_enter(app, w)}
	layout_state_touch(app)
}

floating_minimize :: proc(app: ^App, w: ^Window, node: layout.Node_Id) {
	focused := layout.float_root(w.tree, w.tree.focus) == layout.float_root(w.tree, node)
	if focused {focus_leave(app, w)}
	if !layout.float_minimize(w.tree, node, true) {return}
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

// The topmost floating group whose frame contains the point.
floating_frame_at :: proc(w: ^Window, x, y: f32) -> (root: layout.Node_Id, rect: layout.Rect, ok: bool) {
	last := layout.INVALID_NODE
	#reverse for candidate in floating_rects(w) {
		group := layout.float_root(w.tree, candidate.node)
		if group == last {continue}
		last = group
		frame, found := layout.float_rect(w.tree, group, floating_area(w))
		if found && x >= frame.x && x < frame.x + frame.width &&
		   y >= frame.y && y < frame.y + frame.height {return group, frame, true}
	}
	return layout.INVALID_NODE, {}, false
}

// The floating group whose outer edge band holds the point. Internal split edges remain dividers.
floating_edge_at :: proc(w: ^Window, x, y: f32) -> (pane: layout.Pane_Rect, edges: Float_Edges, ok: bool) {
	band := FLOAT_EDGE * w.scale / 2
	last := layout.INVALID_NODE
	#reverse for candidate in floating_rects(w) {
		group := layout.float_root(w.tree, candidate.node)
		if group == last {continue}
		last = group
		r, found := layout.float_rect(w.tree, group, floating_area(w))
		if !found ||
		   x < r.x - band || x >= r.x + r.width + band ||
		   y < r.y - band || y >= r.y + r.height + band {continue}
		if x < r.x + band {edges += {.Left}}
		if x >= r.x + r.width - band {edges += {.Right}}
		if y < r.y + band {edges += {.Top}}
		if y >= r.y + r.height - band {edges += {.Bottom}}
		if edges == {} {return {}, {}, false}
		pane = candidate
		pane.rect = r
		return pane, edges, true
	}
	return {}, {}, false
}

// Whether a floating group, its edge band or the capsule row covers the point.
floating_covers :: proc(w: ^Window, x, y: f32) -> bool {
	if _, _, edge := floating_edge_at(w, x, y); edge {return true}
	if _, _, frame := floating_frame_at(w, x, y); frame {return true}
	return rect_contains(w.float_capsule_group, x, y)
}

floating_drag_press :: proc(_: ^App, w: ^Window, pane: layout.Pane_Rect, edges: Float_Edges, x, y: f32) {
	rect, found := layout.float_rect(w.tree, pane.node, floating_area(w))
	if !found {return}
	w.float_drag = {
		pressed = true,
		active  = edges != {},
		content = pane.content,
		edges   = edges,
		start   = {x, y},
		rect    = rect,
	}
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
	area := floating_area(w)
	if area.width <= 0 || area.height <= 0 {return true}
	r := floating_drag_rect(area, d.rect, {dx, dy}, d.edges, w.scale)
	bounds := floating_bounds_for_rect(area, r)
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

Float_Capsule_Drag :: struct {
	pressed, active: bool,
	start:           [2]f32,
	rect:            render.Rect,
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
	if w.tree == nil || w.linked {return}
	s := w.scale
	for _, i in w.tree.nodes {
		root := layout.Node_Id(i)
		if !layout.float_is_root(w.tree, root) {continue}
		floating, ok := layout.float_of(w.tree, root)
		if !ok || !floating.minimized {continue}
		pane_id := layout.float_pane(w.tree, root)
		if pane_id == layout.INVALID_NODE {continue}
		pane := w.tree.nodes[pane_id].(layout.Pane) or_continue
		capsule := Float_Capsule {
			root = root,
			content = pane.content,
			order = layout.float_order(w.tree, root),
		}
		if _, err := append(&w.float_capsules, capsule); err != nil {
			clear(&w.float_capsules)
			log.error("storing floating pane capsules failed")
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
		log.error("storing floating pane capsule widths failed")
		return
	}
	area := floating_area(w)
	margin := ui.SPACE_3 * s
	for &capsule, i in w.float_capsules {
		text := ui.text_width(&label, floating_title(app, capsule.content))
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
	if w.float_capsule_positioned {
		x = area.x + w.float_capsule_anchor.x * max(0, area.width - row_width)
		y = area.y + w.float_capsule_anchor.y * max(0, area.height - height)
	}
	x = clamp(x, area.x, max(area.x, area.x + area.width - row_width))
	y = clamp(y, area.y, max(area.y, area.y + area.height - height))
	w.float_capsule_group = {x, y, row_width, height}
	for &capsule, i in w.float_capsules {
		capsule.rect.x, capsule.rect.y, capsule.rect.width = x, y, w.float_capsule_widths[i]
		x += w.float_capsule_widths[i] + gap
	}
}

floating_capsules :: proc(w: ^Window) -> []Float_Capsule {
	return w.float_capsules[:]
}

@(private)
floating_capsule_at :: proc(w: ^Window, x, y: f32) -> Maybe(Float_Capsule) {
	for capsule in floating_capsules(w) {
		if rect_contains(capsule.rect, x, y) {return capsule}
	}
	return nil
}

floating_capsule_drag_press :: proc(w: ^Window, x, y: f32) -> bool {
	if !rect_contains(w.float_capsule_group, x, y) {return false}
	w.float_capsule_drag = {pressed = true, start = {x, y}, rect = w.float_capsule_group}
	return true
}

// Follows the pointer while the minimized-pane row moves. False when no row drag is held.
floating_capsule_drag_move :: proc(w: ^Window, x, y: f32) -> bool {
	d := &w.float_capsule_drag
	if !d.pressed {return false}
	dx, dy := x - d.start.x, y - d.start.y
	if !d.active {
		if max(abs(dx), abs(dy)) < FLOAT_DRAG_THRESHOLD * w.scale {return true}
		d.active = true
		ui.armed_cancel(&w.float_capsule_armed)
	}
	area := floating_area(w)
	r := d.rect
	r.x = clamp(r.x + dx, area.x, max(area.x, area.x + area.width - r.width))
	r.y = clamp(r.y + dy, area.y, max(area.y, area.y + area.height - r.height))
	shift := [2]f32{r.x - w.float_capsule_group.x, r.y - w.float_capsule_group.y}
	w.float_capsule_group = r
	for &capsule in w.float_capsules {
		capsule.rect.x += shift.x
		capsule.rect.y += shift.y
	}
	x_travel, y_travel := max(0, area.width - r.width), max(0, area.height - r.height)
	w.float_capsule_anchor = {
		x_travel > 0 ? (r.x - area.x) / x_travel : 0,
		y_travel > 0 ? (r.y - area.y) / y_travel : 0,
	}
	w.float_capsule_positioned = true
	w.dirty = true
	return true
}

floating_title :: proc(app: ^App, content: layout.Content) -> string {
	if entry := workspace_session_for_content(app, content); entry != nil {
		return entry.name != "" ? entry.name : pane_header_title(&entry.header)
	}
	return content_title(app, content)
}

floating_capsules_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	capsules := floating_capsules(w)
	if len(capsules) == 0 {return .Ok}
	s := w.scale
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	label := ui.text_styled(&w.ui_text, .Body)
	capsule_theme := app.theme
	capsule_theme.hover_lift = 0
	capsule_theme.hover = {}
	for capsule in capsules {
		r := capsule.rect
		radius := ui.pill_radius(r)
		panel := ui.popover_panel(r, s)
		panel.radius = radius
		if ui.panel_draw(&w.list, panel, app.theme) != .None {return .Ok}
		hovered := w.float_capsule_hover == capsule.content
		face, ink, err := ui.button_draw(
			&w.list,
			capsule_theme,
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

// Pointer surface: floating pane edges, the grip of a split floating window and the movable capsule row.
// Headers, content and scrollbars of a floating pane are reached through their own surfaces, which test
// the topmost pane.

floating_claims :: proc(_: ^App, w: ^Window, x, y: f32) -> bool {
	if _, _, edge := floating_edge_at(w, x, y); edge {return true}
	if _, grip := floating_grip_at(w, x, y); grip {return true}
	return rect_contains(w.float_capsule_group, x, y)
}

floating_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	hover: Maybe(layout.Content)
	grip := layout.INVALID_NODE
	if owner == .Floating {
		if capsule, found := floating_capsule_at(w, x, y).?; found {hover = capsule.content}
		if root, over := floating_grip_at(w, x, y); over {grip = root}
	}
	if hover != w.float_capsule_hover {w.float_capsule_hover, w.dirty = hover, true}
	if grip != w.float_grip_hover {w.float_grip_hover, w.dirty = grip, true}
	if owner != .Floating {return}
	if hover != nil {
		pointer_set(app, w, .Hand)
	} else if _, edges, edge := floating_edge_at(w, x, y); edge {
		pointer_set(app, w, floating_edge_cursor(edges))
	} else {
		pointer_set(app, w, .Arrow)
	}
}

floating_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if e.button != .Left {return}
	x, y := f32(e.x), f32(e.y)
	if floating_capsule_drag_press(w, x, y) {
		if capsule, found := floating_capsule_at(w, x, y).?; found {
			ui.armed_press(&w.float_capsule_armed, capsule.content)
		}
		w.dirty = true
		return
	}
	pane, edges, edge := floating_edge_at(w, x, y)
	if !edge {
		root, grip := floating_grip_at(w, x, y)
		if !grip {return}
		node := w.tree.focus
		if layout.float_root(w.tree, node) != root {node = layout.float_pane(w.tree, root)}
		pane_focus(app, w, node)
		for shown in w.panes {
			if shown.node != node {continue}
			floating_drag_press(app, w, shown, {}, x, y)
			w.float_drag.grip = w.float_drag.pressed
			w.dirty = true
			break
		}
		return
	}
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
	capsule_pressed := w.float_capsule_drag.pressed
	capsule_moved := capsule_pressed && w.float_capsule_drag.active
	if capsule_moved {_ = floating_capsule_drag_move(w, x, y)}
	if capsule_pressed {w.float_capsule_drag = {}}
	if capsule_moved {return true}
	if !ui.armed_down(w.float_capsule_armed) {return capsule_pressed}
	under: layout.Content
	capsule, found := floating_capsule_at(w, x, y).?
	if found {under = capsule.content}
	fired, ok := ui.armed_release(&w.float_capsule_armed, under)
	w.dirty = true
	if ok && found {
		pane_focus(app, w, layout.find_content(w.tree, fired))
		layout_state_touch(app)
	}
	return true
}

floating_tooltip :: proc(_: ^App, w: ^Window, x, y: f32) -> string {
	if _, capsule := floating_capsule_at(w, x, y).?; capsule {return "Restore floating pane"}
	if _, grip := floating_grip_at(w, x, y); grip {return "Move floating window"}
	return ""
}
