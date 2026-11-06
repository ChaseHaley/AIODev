package main

import "aio:glyphs"
import "aio:input"
import "aio:layout"
import "aio:perf"
import "aio:platform"
import "aio:render"
import "aio:term"
import "aio:term_view"
import "aio:ui"
import "core:log"
import "core:time"

@(private)
CURSOR_BLINK_INTERVAL :: 530 * time.Millisecond
@(private)
AUTOSCROLL_INTERVAL :: 30 * time.Millisecond
@(private)
FRAME_WAIT_MS :: 100

Pane_View :: struct {
	content: layout.Content,
	view: term_view.View,
	cache: render.Draw_List,
	valid: bool,
	generation, atlas_generation, builds: u64,
	image_epoch: u64,
	style: term_view.Style,
	frame: term_view.Frame,
	header_controls: [ui.HEADER_BUTTONS]ui.Control_Motion,
	header_hover:   ui.Header_Action,
	header_armed:   ui.Armed(ui.Header_Action),
	hover:          Maybe(term.Link_Range),
}

Window :: struct {
	id: platform.Window_Id,
	surface: ^render.Surface,
	ui_text: ui.Text,
	// The Markdown pane holding a selection or scrollbar drag, or 0.
	markdown_held: u32,
	using resources: Workspace_View_Resources,
	gesture: Gesture_State,
	scroll_drag: ui.Scroll_Drag,
	scroll_session: u32,
	scroll_hover: u32,
	dragging: Divider_Drag,
	divider_click_node: layout.Node_Id,
	divider_click_ns: i64,
	pane_drag: Pane_Drag,
	tab_drag: Tab_Drag,
	// A floating pane moved by its header or resized by an edge; see floating_panes.odin.
	float_drag: Float_Drag,
	// The split floating window whose grip strip is under the pointer, and the grip the hover and press
	// animation belongs to, which it keeps while fading out.
	float_grip_hover:  layout.Node_Id,
	float_grip_shown:  layout.Node_Id,
	float_grip_motion: ui.Control_Motion,
	// The minimized floating pane whose capsule is under the pointer, and their movable row.
	float_capsule_hover:      Maybe(layout.Content),
	float_capsule_armed:      ui.Armed(layout.Content),
	float_capsule_drag:       Float_Capsule_Drag,
	float_capsule_group:      render.Rect,
	float_capsule_anchor:     [2]f32,
	float_capsule_positioned: bool,
	float_capsules:           [dynamic]Float_Capsule,
	float_capsule_widths:     [dynamic]f32,
	tab_incoming: Tab_Incoming,
	// A single pane has no header row, so its split controls appear while the pointer is near its top.
	split_overlay: bool,
	list: render.Draw_List,
	width, height: i32,
	header_height: f32,
	header_buttons: input.Mouse_Buttons,
	scale: f32,
	metrics: term_view.Metrics,
	focused, dirty: bool,
	focus_order: u64,
	preparing: bool,
	// Shows part of a tab instead of a workspace; see pane_links.odin. w.workspace is then a private
	// view of those panes, and link_workspace is the id of the workspace that really holds them.
	linked, link_shown: bool,
	link_activate, link_maximize: bool,
	link_workspace: u32,
	generation: u64,
	selecting: bool,
	// While a selection drag is past the top or bottom edge, history scrolls a row per AUTOSCROLL_INTERVAL.
	autoscrolling: bool,
	autoscroll_deadline: time.Tick,
	pointer: [2]f32,
	tooltip: string,
	tooltip_text: [TOOLTIP_LIMIT]u8,
	tooltip_deadline: time.Tick,
	tooltip_warm_until: time.Tick,
	tooltip_anchor: [2]f32,
	tooltip_visible: bool,
	pointer_shape: platform.Cursor_Shape,
	// The last frame drew a pointer-following rim, so pointer movement must repaint it.
	gloss_hovered: bool,
	find: ui.Find_Bar,
	leader_until: time.Tick,
	// Tab placement: horizontal restores the title-bar strip and the presentation arrays below.
	tabs_horizontal: bool,
	tab_underline:   ui.Motion,
	tab_hover:       int,
	tab_pressed:     bool,
	// Vertical tab rail: rows, scroll, adaptive visibility and the overlay slide.
	rail_rows:           [dynamic]Rail_Row,
	rail_auto:           bool,
	rail_override:       Rail_Override,
	rail_scroll:         f32,
	rail_hover:          int,
	rail_pressed:        int,
	rail_width:          f32,
	// tabs.rail_width, the width a double-click on the rail edge returns to.
	rail_default_width:  f32,
	rail_resizing:       bool,
	dock_left_width:     f32,
	title_action_hover: Title_Action,
	title_action_armed: ui.Armed(Title_Action),
	notice_hover: u64,
	notice_armed: ui.Armed(u64),
	notice_buttons: input.Mouse_Buttons,
	tab_orientation_button_hovered: bool,
	tab_orientation_button_armed:   ui.Armed(bool),
	rail_slide:          ui.Motion,
	// True while an overlay is visible or sliding out, so a docked rail hidden by a width
	// crossing cannot leave a phantom rail over the pane.
	rail_was_overlay:    bool,
	tab_close_armed:     ui.Armed(int),
	// Asks before a destructive close and holds its subject, live counts and presentation state.
	pending_close: Pending_Close,
	pending_swap:  Pane_Swap,
	settings_reset_confirm: ui.Confirm,
	settings_reset_source: string,
	profile_remove_confirm: ui.Confirm,
	profile_remove_id: string,
	process_remove_confirm: ui.Confirm,
	process_remove_name: string,
	process_remove_source: string,
	process_remove_id: int,
	pending_file:  Pending_File,
	close_restore: [dynamic]u32,
	tab_menu: Tab_Menu,
	profile_menu: Profile_Menu,
	document_menu: Document_Menu,
	rename: ui.Text_Field,
	rename_open: bool,
	rename_target: Rename_Target,
	rename_mode: Rename_Mode,
	rename_error: bool,
	workspace_button_press_ns: i64,
	workspace_picker: Workspace_Picker,
	workspace_hovered: bool,
	workspace_motion: ui.Control_Motion,
	caption_hover: int,
	caption_armed: ui.Armed(int),
	maximized: bool,
	pane_fill: layout.Pane_Fill,
	paste_confirm_until: time.Tick,
	suppressed_key: Maybe(platform.Key_Event),
	wheel_remainder: f32,
	blinking, cursor_phase_visible: bool,
	blink_deadline: time.Tick,
	// A frame that drew a spinner requests display-paced frames until one does not.
	status_spinning: bool,
	taskbar_state: platform.Progress_State,
	taskbar_percent: int,
	taskbar_workspace: ^Workspace,
	status: Status_Overview,
	// The rail height the activity panel takes in vertical view, refreshed on every relayout.
	status_rail_reserve: f32,
}

window_metrics :: proc(app: ^App, scale: f32) -> term_view.Metrics {
	size_px := app.font_points * scale * 96 / 72
	return term_view.compute_metrics(
		app.fonts,
		app.family,
		size_px,
		f32(app.settings.font.line_height),
	)
}

@(require_results)
window_open :: proc(app: ^App, workspace: ^Workspace) -> bool {
	if workspace == nil || selected_tab(workspace) == nil {return false}
	if existing := window_for_workspace(app, workspace); existing != nil {
		return window_activate(app, existing)
	}
	w := window_prepare(app, workspace)
	if w == nil {return false}
	if !window_show_prepared(app, w) {window_close(app, w); return false}
	w.preparing = false
	window_apply_settings(app, w)
	if !app.options.inactive {_ = window_activate(app, w)}
	return true
}

@(require_results)
window_prepare :: proc(app: ^App, workspace: ^Workspace) -> ^Window {
	if workspace == nil ||
	   selected_tab(workspace) == nil ||
	   window_for_workspace(app, workspace) != nil {
		return nil
	}
	if reserve(&app.windows, len(app.windows) + 1) != nil {return nil}
	w, allocation_error := new(Window)
	if allocation_error != nil {
		return nil
	}
	w.preparing = true
	w.scale = f32(platform.primary_dpi(&app.platform)) / 96
	w.ui_text = app.ui_text
	w.metrics = window_metrics(app, w.scale)
	w.rail_default_width = f32(app.settings.tabs.rail_width)
	w.list = render.draw_list_init()
	w.rail_rows = make([dynamic]Rail_Row)
	ui.find_init(&w.find)
	profile_menu_init(&w.profile_menu)
	document_menu_init(&w.document_menu)
	w.tab_hover, w.rail_hover, w.rail_pressed = -1, -1, -1
	w.caption_hover = -1
	w.divider_click_node, w.float_grip_hover = layout.INVALID_NODE, layout.INVALID_NODE
	w.float_grip_shown = layout.INVALID_NODE
	w.pointer_shape = .Text
	w.cursor_phase_visible = true
	w.dirty = true
	if !workspace_view_init(app, &w.resources, workspace) {window_free(w); return nil}
	if w.workspace.selection_anchor == 0 {tab_select_one(w.workspace, w.workspace.selected)}
	w.tab_underline = {
		value  = f32(w.workspace.selected),
		target = f32(w.workspace.selected),
	}
	// Every new window opens at the configured size, whatever window its content last filled.
	g := initial_geometry(app)
	desc := platform.Window_Desc {
		title = app.app_id,
		inactive = app.options.inactive,
		hidden = true,
		tabbed_title_bar = true,
		width = i32(g.surface_width),
		height = i32(g.surface_height),
	}
	id, err := platform.window_create(&app.platform, desc)
	if err != .None {
		log.errorf("creating the window failed: %v", err)
		window_free(w)
		return nil
	}
	w.id = id
	w.width, w.height = desc.width, desc.height
	append(&app.windows, w)
	native := platform.window_native_handle(&app.platform, id)
	render_error: render.Error
	w.surface, render_error = render.surface_create(app.device, native, w.width, w.height)
	if render_error != .None {
		log.errorf("creating the window surface failed: %v", render_error)
		window_close(app, w)
		return nil
	}
	window_set_dpi(app, w, platform.window_dpi(&app.platform, id))
	window_apply_settings(app, w)
	rail_reveal_active(w)
	if platform.window_set_cursor(&app.platform, id, .Text) != .None {
		log.error("setting the window cursor failed")
	}
	window_update_title(app, w)
	return w
}

@(require_results)
window_show_prepared :: proc(app: ^App, w: ^Window) -> bool {
	show_error := platform.window_show_inactive(&app.platform, w.id)
	if show_error != .None {
		log.errorf("showing the window failed: %v", show_error)
		return false
	}
	w.dirty = true
	return true
}

@(require_results)
window_activate :: proc(app: ^App, w: ^Window) -> bool {
	err: platform.Error
	if app.options.inactive {
		err = platform.window_show_inactive(&app.platform, w.id)
	} else {
		err = platform.window_focus(&app.platform, w.id)
	}
	if err != .None {
		log.errorf("activating the workspace window failed: %v", err)
		notify(app, .Error, "Could not activate the existing workspace window.")
		return false
	}
	return true
}

window_for_workspace :: proc(app: ^App, workspace: ^Workspace) -> ^Window {
	for w in app.windows {if w.workspace == workspace {return w}}
	return nil
}

window_close :: proc(app: ^App, w: ^Window) {
	if !gesture_cancel(app, w) {return}
	window_overlays_cancel(app, w)
	view := w.linked ? w.workspace : nil
	for i in 0 ..< len(app.windows) {
		if app.windows[i] == w {
			ordered_remove(&app.windows, i)
			break
		}
	}
	if w.surface != nil {
		render.surface_destroy(w.surface)
	}
	if platform.window_destroy(&app.platform, w.id) != .None {
		log.error("destroying the window failed")
	}
	window_free(w)
	if view != nil {workspace_destroy(view)}
	window_notices_sync(app)
}

@(private)
window_free :: proc(w: ^Window) {
	workspace_view_destroy(&w.resources)
	delete(w.tab_drag.order)
	delete(w.rail_rows)
	ui.find_destroy(&w.find)
	profile_menu_destroy(&w.profile_menu)
	document_menu_destroy(&w.document_menu)
	delete(w.rename.bytes)
	workspace_picker_destroy(w)
	delete(w.close_restore)
	delete(w.float_capsules)
	delete(w.float_capsule_widths)
	confirmation_clear(w)
	render.draw_list_destroy(&w.list)
	free(w)
}

window_find :: proc(app: ^App, id: platform.Window_Id) -> ^Window {
	for w in app.windows {
		if w.id == id {
			return w
		}
	}
	return nil
}

window_set_dpi :: proc(app: ^App, w: ^Window, dpi: u32) {
	if dpi == 0 {
		return
	}
	w.scale = f32(dpi) / 96
	rail_adaptive_update(w)
	window_apply_settings(app, w)
}

window_apply_settings :: proc(app: ^App, w: ^Window) {
	w.ui_text = app.ui_text
	ui.text_set_size(&w.ui_text, f32(app.settings.interface.font_size) * w.scale * 96 / 72)
	w.metrics = window_metrics(app, w.scale)
	w.rail_default_width = f32(app.settings.tabs.rail_width)
	colors := app.settings.active_theme.colors
	if platform.window_set_frame_color(&app.platform, w.id, colors[.Tab_Bar].rgb, colors[.Text].rgb) !=
	   .None {
		log.error("setting the window frame color failed")
	}
	// A linked window has no tabs to place, and the rail is the only placement that takes pane space.
	horizontal := w.linked || app.settings.tabs.orientation == .Horizontal
	placement_changed := horizontal != w.tabs_horizontal
	w.tabs_horizontal = horizontal
	if placement_changed {
		rail_resize_cancel(w)
		w.tab_hover, w.tab_pressed = -1, false
	}
	if placement_changed && !horizontal {
		// Returning from the strip restores the rail's automatic state; a manual hide or overlay
		// does not survive the mode switch.
		w.rail_override, w.rail_was_overlay = .Auto, false
		rail_adaptive_update(w)
		if w.rail_auto {
			w.rail_slide.value, w.rail_slide.target = 1, 1
		} else {
			w.rail_slide.value, w.rail_slide.target = 0, 0
		}
	}
	if placement_changed && horizontal {
		// The rail rows hold workspace pointers from the old surface and are not read again until
		// the rail returns, when relayout rebuilds them.
		clear(&w.rail_rows)
		w.rail_hover, w.rail_pressed = -1, -1
	}
	window_relayout(app, w)
}

window_resize :: proc(app: ^App, w: ^Window, width, height: i32) {
	w.maximized = platform.window_maximized(&app.platform, w.id)
	w.width, w.height = width, height
	if width <= 0 || height <= 0 {
		return
	}
	rail_adaptive_update(w)
	if err := render.surface_resize(app.device, w.surface, width, height); err != .None {
		log.errorf("resizing the window surface failed: %v", err)
		if err == .Device_Lost {
			recover_device(app)
		}
	}
	window_relayout(app, w)
}

// Recomputes pane rectangles and resizes every session to the grid that fits its pane.
window_relayout :: proc(app: ^App, w: ^Window) {
	pane_view_sync(app, w)
	w.dirty = true
	w.dock_left_width = app.settings.status.panel_side == .Left ? status_panel_dock_width(app, w) : 0
	w.status_rail_reserve = status_panel_rail_height(app, w)
	workspace_picker_layout_changed(w)
	if palette_visible(app, w) {
		ui.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
	}
	if w.preparing { return }
	if w.width <= 0 || w.height <= 0 {
		return
	}
	bar_height := window_title_height(w)
	tab_count := w.workspace != nil ? len(w.workspace.tabs) : 0
	if tab_count != len(w.tab_positions) {
		w.tab_hover, w.tab_pressed = -1, false
	}
	if !tab_presentation_resize(&w.presentation, tab_count) {
		log.error("resizing tab presentation values failed")
	}
	platform.window_title_bar(
		&app.platform,
		w.id,
		i32(bar_height),
		i32(window_title_controls_end(app, w)),
	)
	if !w.tabs_horizontal {
		rail_layout_state, rail_ok := rail_current_layout(w)
		if rail_ok {w.rail_scroll = rail_layout_state.scroll}
	}
	pane_header_cancel(w)
	for &view in w.views {view.header_controls = {}}
	w.header_height = pane_insets(app, w.scale, nil).header
	area := window_content_area(app, w)
	gap := window_gap(app, w)
	if pane_view_solo(w) {
		layout.compute_focused(w.tree, area, &w.panes)
	} else {
		layout.compute(w.tree, area, gap, &w.panes)
	}
	layout.floats_place(w.tree, floating_area(w), gap, floating_grip(w), &w.panes)
	window_dividers(app, w)
	window_views_prune(w)
	for &view in w.views {view.valid = false}
	for pane in w.panes {pane_fit(app, w, pane)}
	floating_capsules_refresh(app, w)
	rail_reveal_active(w)
}

// Lays out only the floating panes, after one opened, moved, resized, rose or was minimized. The tiled
// panes keep their rectangles, grids and cached drawing.
window_floats_layout :: proc(app: ^App, w: ^Window) {
	if w.preparing || w.width <= 0 || w.height <= 0 || w.tree == nil {return}
	tiled := len(window_tiled_rects(w))
	resize(&w.panes, tiled)
	layout.floats_place(w.tree, floating_area(w), window_gap(app, w), floating_grip(w), &w.panes)
	window_dividers(app, w)
	window_views_prune(w)
	for pane in w.panes[tiled:] {
		pane_fit(app, w, pane)
		for &view in w.views {if view.content == pane.content {view.valid = false}}
	}
	floating_capsules_refresh(app, w)
	w.dirty = true
}

// Releases the views of content the window no longer shows.
@(private)
window_views_prune :: proc(w: ^Window) {
	for i := len(w.views) - 1; i >= 0; i -= 1 {
		visible := false
		for pane in w.panes {visible ||= pane.content == w.views[i].content}
		if visible {continue}
		if pane_owns_session(w.views[i].content.kind) {
			term_view.destroy(&w.views[i].view)
			render.draw_list_destroy(&w.views[i].cache)
		}
		ordered_remove(&w.views, i)
	}
}

// Sizes a pane's terminal to its rectangle and makes sure the window keeps a view for it.
@(private)
pane_fit :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	entry := workspace_session_for_content(app, pane.content)
	if entry == nil {
		if pane_view(w, pane.content) == nil {
			cached := Pane_View{content = pane.content}
			if _, err := append(&w.views, cached); err != nil {
				log.error("storing a pane's header state failed")
			}
		}
		return
	}
	box := pane_box(
		w.metrics,
		pane.rect,
		pane_insets(app, w.scale, entry, pane.floating),
	)
	g := term.Geometry {
		columns = box.columns,
		rows = box.rows,
		cell_width = u32(w.metrics.cell_width),
		cell_height = u32(w.metrics.cell_height),
		surface_width = u32(w.width),
		surface_height = u32(w.height),
		padding_left = u32(box.origin.x),
		padding_top = u32(box.origin.y),
	}
	// A floating pane that only moved keeps its grid, so its program sees no resize.
	if g != term.geometry(entry.session) && !(pane.floating && term.reposition(entry.session, g)) {
		term.resize(entry.session, g)
	}
	if pane_view(w, pane.content) == nil {
		view: term_view.View
		if !term_view.create(&view) {
			log.error("creating a terminal view failed")
			return
		}
		cached := Pane_View {
			content = pane.content,
			view    = view,
			cache   = render.draw_list_init(),
		}
		if _, err := append(&w.views, cached); err != nil {
			term_view.destroy(&view)
			render.draw_list_destroy(&cached.cache)
			log.error("storing a terminal view failed")
		}
	}
}

@(private)
pane_view :: proc(w: ^Window, content: layout.Content) -> ^term_view.View {
	for &pane in w.views {
		if pane.content == content {
			return &pane.view
		}
	}
	return nil
}

// The session shown in the focused pane, which receives keyboard input.
focused_session :: proc(app: ^App, w: ^Window) -> ^Session_Entry {
	if w.tree == nil || w.tree.focus == layout.INVALID_NODE {return nil}
	pane, is_pane := w.tree.nodes[w.tree.focus].(layout.Pane)
	if !is_pane {
		return nil
	}
	return workspace_session_for_content(app, pane.content)
}

update_blink :: proc(w: ^Window) {
	if !w.blinking {
		w.cursor_phase_visible = true
		return
	}
	now := time.tick_now()
	if time.tick_diff(w.blink_deadline, now) >= 0 {
		w.cursor_phase_visible = !w.cursor_phase_visible
		w.blink_deadline = time.tick_add(now, CURSOR_BLINK_INTERVAL)
		w.dirty = true
	}
}

// Starts or stops edge autoscroll after the selection drag moved to `pointer`.
autoscroll_follow :: proc(w: ^Window, entry: ^Session_Entry) {
	active := term.selection_autoscroll(entry.session) != .None
	if active && !w.autoscrolling {
		w.autoscroll_deadline = time.tick_add(time.tick_now(), AUTOSCROLL_INTERVAL)
	}
	w.autoscrolling = active
}

update_autoscroll :: proc(app: ^App, w: ^Window) {
	if !w.autoscrolling {
		return
	}
	entry := pane_at(app, w, i32(w.pointer.x), i32(w.pointer.y))
	if !w.selecting || entry == nil {
		w.autoscrolling = false
		return
	}
	now := time.tick_now()
	if time.tick_diff(w.autoscroll_deadline, now) < 0 {
		return
	}
	term.selection_autoscroll_tick(entry.session, w.pointer.x, w.pointer.y)
	w.autoscroll_deadline = time.tick_add(now, AUTOSCROLL_INTERVAL)
	w.dirty = true
	autoscroll_follow(w, entry)
}

// Restarts the blink cycle with the cursor shown, so typing never hides the cursor.
reset_blink :: proc(w: ^Window) {
	w.cursor_phase_visible = true
	w.blink_deadline = time.tick_add(time.tick_now(), CURSOR_BLINK_INTERVAL)
}

window_render :: proc(app: ^App, w: ^Window) {
	if w.width <= 0 || w.height <= 0 || w.surface == nil {
		return
	}
	if err := render.frame_wait(w.surface, FRAME_WAIT_MS); err == .Wait_Failed {
		log.error("waiting for the swap chain failed")
	}
	background := app.theme.window
	build_start := time.tick_now()
	if !window_build_frame(app, w) {return}
	perf.mark_built(&app.perf)
	build_ms := perf.since_ms(build_start)
	w.gloss_hovered = ui.hover_rim_present(&w.list)
	render_start := time.tick_now()
	err := render.frame_render(app.device, w.surface, &w.list, background)
	render_ms := perf.since_ms(render_start)
	if err == .Device_Lost {
		recover_device(app)
		return
	}
	if err != .None {
		log.errorf("rendering a frame failed: %v", err)
	}
	// A failed render still built a draw list, but only a presented frame can carry an input
	// latency sample; counting successes alone keeps frames.presented meaningful. The render
	// start tick is the idle predicate's clock, so a frame reads the clock only twice.
	if err == .None {
		perf.record_frame(&app.perf, build_ms, render_ms, perf.idle_at(&app.perf, render_start))
	}
	w.dirty = false
}

// Only a completed draw list may be submitted or counted as built. Failed construction keeps
// the window dirty, so a later healthy attempt can recover without waiting for new terminal output.
@(require_results)
window_build_frame :: proc(app: ^App, w: ^Window) -> bool {
	build := render.frame_build_begin(&w.list, app.device)
	for {
		_, _ = build_frame(app, w)
		switch render.frame_build_finish(&build) {
		case .Ready: return true
		case .Retry:
		case .Failed: return false
		}
	}
}

@(private)
build_frame :: proc(app: ^App, w: ^Window) -> (term_view.Frame, glyphs.Result) {
	frame: term_view.Frame
	blinking := false
	w.status_spinning = false
	// Floating panes draw after the chrome, whose shared pane borders would otherwise cross them.
	for pane in w.panes {
		if pane.floating {continue}
		result: glyphs.Result
		frame, result = pane_draw(app, w, pane, &blinking)
		if result != .Ok {return frame, result}
	}
	if w.pane_fill != .Screen {
		if result := window_chrome_draw(app, w); result != .Ok {return frame, result}
	}
	if result := rail_draw(app, w); result != .Ok {return frame, result}
	if result := status_panel_draw(app, w); result != .Ok {return frame, result}
	group := layout.INVALID_NODE
	for pane in w.panes {
		if !pane.floating {continue}
		// Each floating window's grip draws with it, so a higher window covers a lower one's grip.
		if root := layout.float_root(w.tree, pane.node); root != group {
			group = root
			floating_grip_draw(app, w, root)
		}
		result: glyphs.Result
		frame, result = pane_draw(app, w, pane, &blinking)
		if result != .Ok {return frame, result}
	}
	if result := floating_capsules_draw(app, w); result != .Ok {return frame, result}
	if blinking != w.blinking {
		w.blinking = blinking
		reset_blink(w)
	}
	if result := pane_drag_draw(app, w); result != .Ok {return frame, result}
	if result := tab_drag_draw(app, w); result != .Ok {return frame, result}
	if result := window_leader_draw(app, w); result != .Ok {return frame, result}
	size := [2]f32{f32(w.width), f32(w.height)}
	if w.find.open {
		status, enabled := find_presentation(w, find_target(app, w))
		result := ui.find_draw(
			&w.find,
			&w.list,
			&w.ui_text,
			app.theme,
			status,
			enabled,
			size.x,
			size.y,
			w.scale,
			w.pointer,
		)
		if result != .Ok {
			return frame, result
		}
	}
	if palette_visible(app, w) {
		opacity, rise := ui.presence_fade(app.palette.presence, 4 * w.scale)
		result := ui.palette_draw(
			&app.palette, &w.list, &w.ui_text, app.theme, size.x, size.y, w.scale,
			opacity, rise, w.pointer,
		)
		if result != .Ok { return frame, result }
	}
	if w.rename_open {
		if result := rename_draw(app, w); result != .Ok {return frame, result}
	}
	if result := confirmation_draw(app, w); result != .Ok {return frame, result}
	if w.tab_menu.open {
		if result := tab_menu_draw(app, w); result != .Ok {return frame, result}
	}
	if w.profile_menu.open {
		if result := profile_menu_draw(app, w); result != .Ok {return frame, result}
	}
	if result := document_menu_draw(app, w); result != .Ok {return frame, result}
	if workspace_picker_active(&w.workspace_picker) {
		if result := workspace_picker_draw(app, w); result != .Ok {return frame, result}
	}
	if result := status_inbox_draw(app, w); result != .Ok {return frame, result}
	if result := tooltip_draw(app, w); result != .Ok {return frame, result}
	if app.notice_window != w.id {return frame, .Ok}
	return frame, ui.notices_draw(
		&app.notices,
		&w.list,
		&w.ui_text,
		app.theme,
		size.x,
		size.y,
		w.scale,
		w.notice_hover,
		ui.armed_target(w.notice_armed),
		w.pointer,
	)
}

// Draws one pane's card, content, header, scrollbar, dimming and outline.
@(private)
pane_draw :: proc(
	app: ^App,
	w: ^Window,
	pane: layout.Pane_Rect,
	blinking: ^bool,
) -> (
	frame: term_view.Frame,
	result: glyphs.Result,
) {
	card := len(w.list.rects)
	window_card_draw(app, w, pane)
	switch pane.content.kind {
	case .Terminal:
	case .Settings:
		return frame, settings_pane_draw(app, w, pane, card)
	case .Markdown:
		return frame, markdown_pane_draw(app, w, pane, card)
	}
	entry := workspace_session_for_content(app, pane.content)
	view := pane_view(w, pane.content)
	state := link_pane(w, pane.content)
	if entry == nil || view == nil {return frame, .Ok}
	c := app.settings.colors
	selection_foreground: Maybe(render.Color)
	if fg, ok := c.selection_foreground.?; ok {selection_foreground = color(fg)}
	content_focused :=
		w.focused && pane.node == w.tree.focus && !palette_active(app, w) &&
		!ui.find_has_keyboard(&w.find)
	hover: Maybe(term.Link_Range)
	if state != nil {
		hover = state.hover
	}
	minimum_contrast := f32(1)
	if app.settings.active_theme.terminal_light {
		minimum_contrast = f32(app.settings.terminal.minimum_contrast)
	}
	style := term_view.Style {
		family = app.family,
		selection_background = color(c.selection_background),
		selection_foreground = selection_foreground,
		search_foreground = color(c.search_foreground),
		search_background = color(c.search_background),
		search_selected_background = color(c.search_selected_background),
		cursor_text = color(c.cursor_text),
		minimum_contrast = minimum_contrast,
		focused = content_focused,
		cursor_phase_visible = !content_focused || w.cursor_phase_visible,
		hover = hover,
	}
	box := pane_box(
		w.metrics,
		pane.rect,
		pane_insets(app, w.scale, entry, pane.floating),
	)
	frame, result = build_pane(app, w, pane, entry, view, box.origin, style)
	if result != .Ok {return frame, result}
	if card < len(w.list.rects) {w.list.rects[card].color = frame.background}
	blinking^ ||= frame.cursor_blinking && content_focused
	if entry.status != .Running {
		message := session_message(term.status(entry.session))
		if message_result := ui.pane_message_draw(
			&w.list,
			&w.ui_text,
			app.theme,
			{pane.rect.x, pane.rect.y, pane.rect.width, pane.rect.height},
			message,
			w.scale,
			window_pane_radius(app, w),
		); message_result != .Ok {return frame, message_result}
	}
	if header_result := pane_header_draw(app, w, pane, entry);
	   header_result != .Ok {return frame, header_result}
	terminal_scrollbar_draw(app, w, pane, entry)
	window_card_dim(app, w, pane, frame.background)
	window_card_outline(app, w, pane)
	return frame, .Ok
}

// Rebuilds every graphics object after the GPU was reset or removed; sessions are untouched.
recover_device :: proc(app: ^App) {
	log.warn("the graphics device was lost; recreating it")
	for w in app.windows {
		render.surface_destroy(w.surface)
		w.surface = nil
	}
	render.device_destroy(app.device)
	device, err := render.device_create()
	if err != .None {
		log.errorf("recreating the graphics device failed: %v", err)
		app.device = nil
		app.running = false
		return
	}
	app.device = device
	apply_text_gamma(app)
	glyphs.reset_device(&app.cache, device)
	for w in app.windows {
		native := platform.window_native_handle(&app.platform, w.id)
		surface, surface_error := render.surface_create(
			device,
			native,
			max(w.width, 1),
			max(w.height, 1),
		)
		if surface_error != .None {
			log.errorf("recreating a window surface failed: %v", surface_error)
			continue
		}
		w.surface = surface
		for &pane in w.views {pane.valid = false}
		w.dirty = true
	}
}

@(private)
build_pane :: proc(
	app: ^App,
	w: ^Window,
	pane: layout.Pane_Rect,
	entry: ^Session_Entry,
	view: ^term_view.View,
	origin: [2]f32,
	style: term_view.Style,
) -> (
	term_view.Frame,
	glyphs.Result,
) {
	clip := render.Rect{pane.rect.x, pane.rect.y, pane.rect.width, pane.rect.height}
	radius := window_pane_radius(app, w)
	for &cached in w.views {
		if cached.content != pane.content {continue}
		if len(w.panes) == 1 {
			if render.push_layer(&w.list, clip, radius) != .None {return {}, .Ok}
			cached.builds += 1
			return term_view.build(
				view,
				entry.session,
				app.fonts,
				&app.cache,
				&w.list,
				origin,
				w.metrics,
				style,
			)
		}
		generation := term.generation(entry.session)
		atlas := render.atlas_generation(app.device)
		if !cached.valid ||
		   cached.generation != generation ||
		   cached.atlas_generation != atlas ||
		   cached.image_epoch != render.image_epoch(app.device) ||
		   cached.style != style {
			cached.valid = false
			render.draw_list_reset(&cached.cache)
			_ = render.push_layer(&cached.cache, clip, radius)
			frame, result := term_view.build(
				view,
				entry.session,
				app.fonts,
				&app.cache,
				&cached.cache,
				origin,
				w.metrics,
				style,
			)
			if result != .Ok {return frame, result}
			if cached.cache.error == .None {
				cached.frame, cached.style = frame, style
				cached.generation, cached.atlas_generation =
					generation, render.atlas_generation(app.device)
				cached.image_epoch = render.image_epoch(app.device)
				cached.valid = true
				cached.builds += 1
			}
		}
		_ = render.append_list(&w.list, &cached.cache)
		return cached.frame, .Ok
	}
	return {}, .Ok
}
