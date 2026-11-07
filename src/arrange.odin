package main

import "aio:layout"
import "aio:render"
import "aio:ui"
import "core:time"

// A pane drag from a header: where the pointer is resolves to a Pane_Drop, the trial measures the move it
// plans (pane_moves.odin), the outline shows it and the release carries it out.

@(private)
GHOST_DURATION :: 120 * time.Millisecond

// A pane drag is the app's only one, so a press here cancels a pane drag held in any other window.
pane_drag_press :: proc(app: ^App, w: ^Window, node: layout.Node_Id, x, y: f32) {
	for i := len(app.windows) - 1; i >= 0; i -= 1 {
		if i < len(app.windows) && app.windows[i] != w {pane_drag_cancel(app, app.windows[i])}
	}
	drag_press(w, x, y, Pane_Grab{selected_tab(w.workspace), node})
}

// The active pane drag in w, or nil.
@(private)
pane_drag_state :: proc(w: ^Window) -> (^Drag_Active, ^Pane_Carry) {
	a := drag_active(w)
	if a == nil {return nil, nil}
	carry, pane := &a.carry.(Pane_Carry)
	if !pane {return nil, nil}
	return a, carry
}

@(private)
pane_drag_show_source :: proc(app: ^App, w: ^Window, source: ^Tab) {
	for tab, i in w.workspace.tabs {if tab == source {tab_select(app, w, i, .Preserve_Marks); break}}
}

// Shows the tabs the drag found: the source's in its own window, and the original one in the window it
// visits.
@(private)
pane_drag_restore :: proc(app: ^App, w: ^Window, carry: ^Pane_Carry) {
	visit := carry.visit
	if destination := window_find(app, visit.window); destination != nil && destination != w {
		for tab, i in destination.workspace.tabs {
			if tab == visit.original {tab_select(app, destination, i, .Preserve_Marks); break}
		}
		if destination.workspace.selected != visit.original_index &&
		   visit.original_index >= 0 &&
		   visit.original_index < len(destination.workspace.tabs) {
			tab_select(app, destination, visit.original_index, .Preserve_Marks)
		}
		destination.dirty = true
	}
	pane_drag_show_source(app, w, carry.source)
}

pane_drag_cancel :: proc(app: ^App, w: ^Window) {
	grab, held := pane_drag_grab(w)
	if !held {return}
	d := drag_end(w)
	a, active := &d.(Drag_Active)
	if !active {
		pane_drag_show_source(app, w, grab.source)
		return
	}
	drag_let_go(app, w, a)
	pane_drag_restore(app, w, &a.carry.(Pane_Carry))
}

// The edge of `r` nearest to the point, as the side the dragged pane will take.
@(private)
nearest_side :: proc(r: layout.Rect, x, y: f32) -> layout.Direction {
	left, right := (x - r.x) / max(1, r.width), (r.x + r.width - x) / max(1, r.width)
	top, bottom := (y - r.y) / max(1, r.height), (r.y + r.height - y) / max(1, r.height)
	nearest := min(left, right, top, bottom)
	switch nearest {
	case left:
		return .Left
	case right:
		return .Right
	case top:
		return .Up
	}
	return .Down
}

// Where the dragged pane would land on `drop` in w, and whether it fits there: the target's card for a swap,
// the new tab's place, otherwise the pane's card in a trial of the move the drop would make.
@(private)
pane_drag_preview :: proc(
	app: ^App,
	source_window: ^Window,
	carry: ^Pane_Carry,
	w: ^Window,
	drop: Pane_Drop,
) -> (
	layout.Rect,
	Drop_Fit,
) {
	switch drop.place {
	case .New_Tab:
		pane := carry.source.tree.nodes[carry.node].(layout.Pane)
		panes := [?]layout.Pane_Rect{{content = pane.content, rect = window_content_area(app, w)}}
		reorders_tab :=
			pane_source_workspace(app, carry.source) == w.workspace && carry.node == carry.source.tree.root
		if !reorders_tab && !pane_minimum_allows(app, w, panes[:], nil, notify_failure = false) {
			return {}, .Too_Small
		}
		if w.tabs_horizontal {
			r := ui.tab_drop_region(window_tab_bar(app, w), f32(w.width), w.scale)
			return {
					r.x + 2 * w.scale,
					(ui.TITLE_BAR_HEIGHT - ui.HEIGHT_TOOLBAR) / 2 * w.scale,
					max(0, min(180 * w.scale, r.width) - 4 * w.scale),
					ui.HEIGHT_TOOLBAR * w.scale,
				},
				.Fits
		}
		r := rail_new_tab_rect(w)
		inset := 2 * w.scale
		return {
				r.x + inset,
				r.y + inset,
				max(0, min(180 * w.scale, r.width) - 2 * inset),
				max(0, r.height - 2 * inset),
			},
			.Fits
	case .Swap:
		for pane in w.panes {if pane.node == drop.target {return pane.rect, .Fits}}
		return {}, .Refused
	case .Beside, .Edge:
	}
	op, resolved := pane_drop_operation(app, source_window, carry.source, carry.node, w, drop)
	if !resolved {return {}, pane_drop_refusal(source_window, carry.source, w, drop)}
	result := pane_trial_operation(app, w, op)
	#partial switch result.error {
	case .None:
		return result.rect, .Fits
	case .Minimum:
		return result.rect, .Too_Small
	}
	return result.rect, .Refused
}

// Whether the outline shows: a destination the pane fits, or a tear-off with its window prepared.
@(private)
pane_drag_ghost_shown :: proc(a: ^Drag_Active) -> bool {
	switch d in a.carry.(Pane_Carry).destination {
	case Drop_Tear_Off:
		_, ready := a.preview.(Preview_Ready)
		return ready
	case Pane_Drop:
		return d.fit == .Fits
	case Drop_Workspace_Dropdown:
	}
	return false
}

// The same place to land, whatever the fit.
@(private)
pane_destination_same :: proc(a, b: Pane_Destination) -> bool {
	switch x in a {
	case nil:
		return b == nil
	case Pane_Drop:
		y, ok := b.(Pane_Drop)
		return ok && x.window == y.window && x.tab == y.tab && x.place == y.place && x.target == y.target &&
			x.direction == y.direction
	case Drop_Workspace_Dropdown, Drop_Tear_Off:
	}
	return false
}

// Tracks a header drag; returns whether the drag owns the pointer.
pane_drag_move :: proc(app: ^App, w: ^Window, x, y: f32, swap: bool) -> bool {
	if grab, passed := drag_threshold_passed(w, x, y); passed {
		pane, is_pane := grab.(Pane_Grab)
		if !is_pane {return false}
		visit := Drag_Visit{window = w.id, original_index = w.workspace.selected}
		_ = drag_activate(w, Pane_Carry{grab = pane, visit = visit}, x, y)
	}
	a, carry := pane_drag_state(w)
	if a == nil {return false}
	a.pointer = {x, y}
	point, point_ok := drag_point(app, w, x, y)
	if !point_ok {pane_drag_cancel(app, w); return true}
	destination := point.window
	changed_window := pane_drag_visit(app, w, carry, destination)
	if destination == nil {
		pane_drag_outside(app, w, a, carry, swap, point)
		return true
	}
	return pane_drag_target_move(app, w, a, carry, destination, f32(point.x), f32(point.y), swap, changed_window)
}

// Moves the visit to the window under the pointer, showing again the tab the previous one showed. Returns
// whether the window changed.
@(private)
pane_drag_visit :: proc(app: ^App, w: ^Window, carry: ^Pane_Carry, destination: ^Window) -> bool {
	visit := &carry.visit
	previous := visit.window
	if previous == w.id && destination != w && selected_tab(w.workspace) != carry.source {
		pane_drag_show_source(app, w, carry.source)
	}
	id := destination == nil ? 0 : destination.id
	if id == previous {return false}
	if old := window_find(app, previous); old != nil && old != w {
		for tab, i in old.workspace.tabs {
			if tab == visit.original {tab_select(app, old, i, .Preserve_Marks); break}
		}
		old.dirty = true
	}
	visit.window, visit.original, visit.hover = id, nil, nil
	if destination != nil && destination != w {
		visit.original = selected_tab(destination.workspace)
		visit.original_index = destination.workspace.selected
	}
	return true
}

// Past every app window the drag offers a window of its own, when its source can lose the pane; while Shift
// is held it offers nothing there.
@(private)
pane_drag_outside :: proc(
	app: ^App,
	w: ^Window,
	a: ^Drag_Active,
	carry: ^Pane_Carry,
	swap: bool,
	point: Drag_Point,
) {
	next: Pane_Destination
	if swap {
	} else if pane_window_source_can_lose(app, carry.source, carry.node) {
		next = Drop_Tear_Off{}
		_ = tear_off_preview_ensure(app, a, true)
	} else {
		tear_off_preview_discard(app, a)
	}
	pane_drag_retarget(app, w, a, next)
	_, tear_off := next.(Drop_Tear_Off)
	shown := pane_drag_ghost_shown(a)
	pane_drag_thumbnail_sync(app, w, a, carry, shown, point.screen_x, point.screen_y)
	rect: layout.Rect
	if tear_off {for pane in w.panes {if pane.node == carry.node {rect = pane.rect; break}}}
	values := [4]f32{rect.x, rect.y, rect.width, rect.height}
	for &m, i in carry.ghost {ui.motion_target(&m, values[i], 0, .Linear, false, time.tick_now())}
	w.dirty = true
}

@(private)
pane_drag_target_move :: proc(
	app: ^App,
	source_window: ^Window,
	a: ^Drag_Active,
	carry: ^Pane_Carry,
	w: ^Window,
	x, y: f32,
	swap, changed_window: bool,
) -> bool {
	if !window_linked(w) && pane_workspace_drag_move(app, source_window, w, x, y, swap) {return true}
	title_height := window_title_height(w)
	destination := selected_tab(w.workspace)
	now := time.tick_now()
	on_tab := -1
	over_rail, rail_new_tab := false, false
	if w.tabs_horizontal {
		if tab, ok := window_tab_hit(app, w, window_tab_bar(app, w), x, y).(Tab_Chrome_Tab); ok {
			on_tab, destination = tab.index, w.workspace.tabs[tab.index]
		}
	} else {
		rail_tab, new_tab_target, over := rail_pane_target(w, x, y)
		over_rail, rail_new_tab = over, new_tab_target
		if over && rail_tab >= 0 {
			on_tab = rail_tab
			if rail_tab < len(w.workspace.tabs) {destination = w.workspace.tabs[rail_tab]}
		}
	}
	// A floating window covers the rail and the tiling's edge bands: a drop over it lands on its panes.
	_, _, over_float := floating_frame_at(w, x, y)
	if over_float {
		on_tab, over_rail, rail_new_tab = -1, false, false
		destination = selected_tab(w.workspace)
	}
	new_tab := !swap && !window_linked(w) &&
		(w.tabs_horizontal
				? ui.tab_drop_hit(window_tab_bar(app, w), f32(w.width), w.scale, x, y)
				: over_rail && rail_new_tab)
	pane_drag_hover(app, source_window, carry, w, destination, on_tab, swap, now)
	target, direction := layout.INVALID_NODE, layout.Direction.Left
	root := false
	area := window_content_area(app, w)
	band := min(24 * w.scale, area.width / 5, area.height / 5)
	if destination != nil && on_tab >= 0 && on_tab < len(w.workspace.tabs) {
		if destination != carry.source && !swap {target, direction = destination.tree.focus, .Right}
	} else if !over_rail &&
	   destination != nil &&
	   x >= 0 &&
	   x < f32(w.width) &&
	   y >= title_height &&
	   y < f32(w.height) {
		if !swap && !over_float &&
		   (x < area.x + band ||
				   x >= area.x + area.width - band ||
				   y < area.y + band ||
				   y >= area.y + area.height - band) {
			root, direction, target = true, nearest_side(area, x, y), destination.tree.focus
			if destination == carry.source &&
			   carry.node == destination.tree.root {target, root = layout.INVALID_NODE, false}
		} else if pane, found := layout.hit_test(w.panes[:], x, y);
		   found && (destination != carry.source || pane.node != carry.node) {
			target, direction = pane.node, nearest_side(pane.rect, x, y)
		}
	}
	if swap && destination != carry.source {target = layout.INVALID_NODE}
	// Each place keeps only the fields it uses, so the same place compares equal wherever the pointer is.
	next: Pane_Destination
	switch {
	case new_tab:
		next = Pane_Drop{w.id, destination, .New_Tab, layout.INVALID_NODE, .Left, .Fits}
	case target == layout.INVALID_NODE:
	case swap:
		next = Pane_Drop{w.id, destination, .Swap, target, .Left, .Fits}
	case root:
		next = Pane_Drop{w.id, destination, .Edge, target, direction, .Fits}
	case:
		next = Pane_Drop{w.id, destination, .Beside, target, direction, .Fits}
	}
	if pane_destination_same(carry.destination, next) && !changed_window {return true}
	rect: layout.Rect
	if drop, placed := &next.(Pane_Drop); placed {
		rect, drop.fit = pane_drag_preview(app, source_window, carry, w, drop^)
	}
	shown := pane_drag_ghost_shown(a)
	pane_drag_retarget(app, source_window, a, next)
	// The ghost fades in on every drop kind, so crossing between the tab strip and a pane
	// never flashes between faded and opaque.
	ui.motion_target(&carry.reveal, 1, GHOST_DURATION, .Decelerate, app.animations, now)
	w.dirty = true
	source_window.dirty = true
	values := [4]f32{rect.x, rect.y, rect.width, rect.height}
	for &m, i in carry.ghost {
		ui.motion_target(&m, values[i], GHOST_DURATION, .Decelerate, app.animations && shown, now)
	}
	return true
}

// Resting on another tab of the window shows it after a moment; it must not move the tab marked selection.
// A drag from a linked window never arms the switch: pane_links_sync shows a linked window only while its own
// tab is on screen, so switching away would hide the window being dragged from.
pane_drag_hover :: proc(
	app: ^App,
	source_window: ^Window,
	carry: ^Pane_Carry,
	w: ^Window,
	destination: ^Tab,
	on_tab: int,
	swap: bool,
	now: time.Tick,
) {
	visit := &carry.visit
	if destination == nil ||
	   destination == selected_tab(w.workspace) ||
	   on_tab < 0 ||
	   swap ||
	   window_linked(source_window) {
		visit.hover = nil
		return
	}
	hover, armed := visit.hover.?
	if !armed || hover.tab != destination {
		visit.hover = Drag_Hover{destination, time.tick_add(now, DRAG_HOVER_DELAY)}
	} else if time.tick_diff(now, hover.at) <= 0 {
		tab_select(app, w, on_tab, .Preserve_Marks)
		visit.hover = nil
	}
}

// Finishes a header drag; a drop outside another pane leaves the layout unchanged.
pane_drag_release :: proc(app: ^App, w: ^Window) -> bool {
	if _, held := pane_drag_grab(w); !held {return false}
	d := drag_end(w)
	a, active := &d.(Drag_Active)
	if !active {return false}
	carry := &a.carry.(Pane_Carry)
	drag_thumbnail_destroy(&a.thumbnail)
	drop: Pane_Drop
	switch destination in carry.destination {
	case Drop_Workspace_Dropdown:
		pane_workspace_drag_release(app, w, a, destination)
		return true
	case Drop_Tear_Off:
		_, ready := a.preview.(Preview_Ready)
		if ready && tear_off_commit(app, w, a) {
			drag_free(app, a)
			return true
		}
		drag_let_go(app, w, a)
		pane_drag_restore(app, w, carry)
		if ready {notify(app, .Error, "Could not move the pane. The source was preserved.")}
		return true
	case nil:
		drag_let_go(app, w, a)
		pane_drag_restore(app, w, carry)
		return true
	case Pane_Drop:
		drop = destination
	}
	drag_let_go(app, w, a)
	destination_window := window_find(app, drop.window)
	if destination_window == nil {pane_drag_restore(app, w, carry); return true}
	destination_window.dirty = true
	if destination_window != w {pane_drag_show_source(app, w, carry.source)}
	if drop.fit != .Fits {
		pane_drop_refused(app, drop.fit)
		pane_drag_restore(app, w, carry)
		return true
	}
	if pane_drop_commit(app, w, carry.grab, destination_window, drop) {return true}
	pane_drag_restore(app, w, carry)
	if drop.place != .New_Tab {
		pane_drop_refused(app, pane_drop_refusal(w, carry.source, destination_window, drop))
	}
	return true
}

// Tells the user why a released drop moved nothing, once, for the refusals that need saying.
@(private)
pane_drop_refused :: proc(app: ^App, fit: Drop_Fit) {
	switch fit {
	case .Too_Small:
		pane_minimum_dock_refused(app)
	case .Refused_Source_Kept:
		notify(app, .Error, "Could not move the pane. The source was preserved.")
	case .Refused_Tabs_Kept:
		notify(app, .Error, "Could not move the pane. Both tabs were preserved.")
	case .Fits, .Refused:
	}
}

// A rest on another tab switches to it when its moment is up.
pane_drag_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	at, armed := drag_hover_deadline(w)
	if !armed || time.tick_diff(now, at) > 0 {return}
	a := drag_active(w)
	_ = pane_drag_move(app, w, a.pointer.x, a.pointer.y, false)
}

pane_drag_animating :: proc(w: ^Window) -> bool {
	_, carry := pane_drag_state(w)
	if carry == nil {return false}
	if ui.motion_active(carry.reveal) {return true}
	for m in carry.ghost {if ui.motion_active(m) {return true}}
	return false
}

pane_drag_animate :: proc(app: ^App, w: ^Window, enabled: bool, now: time.Tick) {
	_, carry := pane_drag_state(w)
	if carry == nil {return}
	if !enabled && pane_drag_animating(w) {
		for &m in carry.ghost {m.value = m.target}
		carry.reveal.value = carry.reveal.target
		w.dirty = true
		return
	}
	if ui.motion_update(&carry.reveal, now) {w.dirty = true}
	for &m in carry.ghost {if ui.motion_update(&m, now) {w.dirty = true}}
	if w.dirty {
		if target := window_find(app, carry.visit.window); target != nil {target.dirty = true}
	}
}

// The label a drop would produce, independent of its drawing.
@(require_results)
pane_drag_label :: proc(grab: Pane_Grab, drop: Pane_Drop) -> string {
	switch drop.place {
	case .New_Tab:
		if drop.tab == grab.source && grab.node == grab.source.tree.root {
			return "Move tab to end"
		}
		return "+ New tab"
	case .Swap:
		return "Swap panes"
	case .Edge:
		return "Dock to workspace edge"
	case .Beside:
	}
	return "Move pane here"
}

// The outline of a pane drop: in the window it lands in, or around the pane a tear-off takes from its own.
pane_drag_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	a, carry := pane_drag_state(w)
	if a != nil && !drag_tearing_off(a) {a = nil}
	for source in app.windows {
		if sa, sc := pane_drag_state(source); sa != nil && pane_destination_window(sc.destination) == w.id {
			a, carry = sa, sc
			break
		}
	}
	if a == nil || !pane_drag_ghost_shown(a) {return .Ok}
	r := render.Rect{carry.ghost[0].value, carry.ghost[1].value, carry.ghost[2].value, carry.ghost[3].value}
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	radius := f32(app.settings.pane.corner_radius) * w.scale
	// The thumbnail copies this pane live, so a tear-off marks it with an outline and nothing over its text.
	drop, placed := carry.destination.(Pane_Drop)
	if !placed {
		_ = render.push_rect(
			&w.list,
			{rect = r, color = app.theme.accent, radius = radius, stroke = 2 * w.scale},
		)
		return .Ok
	}
	opacity := carry.reveal.value
	fill := app.theme.accent
	fill.a = 0.16 * opacity
	if render.push_rect(&w.list, {rect = r, color = fill, radius = radius}) != .None {return .Ok}
	r = {carry.ghost[0].target, carry.ghost[1].target, carry.ghost[2].target, carry.ghost[3].target}
	accent := app.theme.accent
	accent.a *= opacity
	if render.push_rect(
		   &w.list,
		   {rect = r, color = accent, radius = radius, stroke = 2 * w.scale},
	   ) !=
	   .None {return .Ok}
	label := pane_drag_label(carry.grab, drop)
	text := ui.text_styled(&w.ui_text, .Strong)
	width := ui.text_width(&text, label)
	label_color := app.theme.text
	label_color.a *= opacity
	return ui.draw_text(
		&text,
		&w.list,
		label,
		r.x + (r.width - width) / 2,
		r.y + (r.height - text.line_height) / 2 + text.ascent,
		label_color,
		max(1, r.width - 16 * w.scale),
	)
}

// Ends every pointer arrangement gesture, restoring a dragged tab to its starting position. A drag from
// another window that reaches w ends too.
arrange_cancel :: proc(app: ^App, w: ^Window) {
	id := w.id
	// Cancellation may destroy a preview and remove it from the registry.
	for i := len(app.windows) - 1; i >= 0; i -= 1 {
		if i >= len(app.windows) {continue}
		other := app.windows[i]
		if other != w && drag_involves(other, id) {
			gesture_clear(app, other)
			pane_drag_cancel(app, other)
			tab_drag_cancel(app, other)
		}
	}
	if window_find(app, id) == nil {return}
	divider_cancel(w)
	tab_drag_cancel(app, w)
	pane_drag_cancel(app, w)
}
