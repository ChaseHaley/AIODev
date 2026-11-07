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
}

Window :: struct {
	id: input.Window_Id,
	surface: Window_Surface,
	ui_text: ui.Text,
	// The pointer's hold on a Markdown pane and what it is over; markdown_pane.odin writes both.
	markdown_gesture: Markdown_Gesture,
	markdown_hover: Markdown_Hover,
	using resources: Workspace_View_Resources,
	gesture: Gesture_State,
	// A held terminal scrollbar thumb; see terminal_scrollbar.odin.
	scroll_drag: Maybe(Terminal_Scroll_Drag),
	scroll_hover: u32,
	// A divider press, drag or the first click of a double-click; see arrange.odin.
	divider: Divider_Gesture,
	// The pane or tab drag this window's pointer holds; see drag.odin.
	drag: Drag,
	// The float surface's held Left press: a float header button, a float moving or resizing, or the
	// capsule row; see floating_panes.odin.
	float_press: Float_Press,
	// The float header part under the pointer, and the float the hover and press animation belongs to,
	// which it keeps while fading out.
	float_header_hover:    Maybe(Float_Header_Spot),
	float_header_shown:    layout.Node_Id,
	float_header_motion:   ui.Control_Motion,
	float_header_controls: [FLOAT_HEADER_BUTTONS]ui.Control_Motion,
	// The minimized float whose capsule is under the pointer; where the user left the capsule row, as a
	// fraction of the room it can travel, or nil for the bottom-right; and the row's cached geometry.
	float_capsule_hover:      Maybe(layout.Content),
	float_capsule_anchor:     Maybe([2]f32),
	float_capsule_group:      render.Rect,
	float_capsules:           [dynamic]Float_Capsule,
	float_capsule_widths:     [dynamic]f32,
	tab_incoming: Tab_Incoming,
	// A single pane has no header row, so its split controls appear while the pointer is near its top.
	split_overlay: bool,
	list: render.Draw_List,
	width, height: i32,
	header_height: f32,
	scale: f32,
	metrics: term_view.Metrics,
	focused, dirty: bool,
	focus_order: u64,
	focus_bracket: Focus_Bracket,
	phase: Window_Phase,
	// Set once, when pane_link_window_create makes the window; see Window_Link.
	link: Maybe(Window_Link),
	generation: u64,
	// A terminal text selection drag; see terminal_selection.odin.
	selection: Selection_Drag,
	// The terminal link under the pointer; see term_links.odin.
	link_hover: Maybe(Link_Hover),
	pointer: [2]f32,
	// See tooltip.odin; tooltip_text stores the label the state names.
	tooltip: Tooltip,
	tooltip_text: [TOOLTIP_LIMIT]u8,
	pointer_shape: platform.Cursor_Shape,
	// The last frame drew a pointer-following rim, so pointer movement must repaint it.
	gloss_hovered: bool,
	find: ui.Find_Bar,
	// Leader chord mode and the keys whose releases are swallowed; input.odin is their only writer.
	leader: Leader,
	suppressed: Suppressed_Keys,
	// Tab placement: horizontal restores the title-bar strip and the presentation arrays below.
	tabs_horizontal: bool,
	tab_underline:   ui.Motion,
	tab_hover:       int,
	// Vertical tab rail: rows, scroll and its presentation with the automatic policy; see rail.odin.
	rail_rows:           [dynamic]Rail_Row,
	rail:                Rail_Presentation,
	rail_wide:           bool,
	rail_scroll:         f32,
	rail_hover:          int,
	rail_width:          f32,
	// tabs.rail_width, the width a double-click on the rail edge returns to.
	rail_default_width:  f32,
	dock_left_width:     f32,
	title_action_hover: Title_Action,
	title_action_armed: ui.Armed(Title_Action),
	tab_orientation_button_hovered: bool,
	tab_orientation_button_armed:   ui.Armed(bool),
	tab_close_armed:     ui.Armed(int),
	// The question asked before a destructive change, with its subject; see confirmation.odin.
	confirmation: Maybe(Confirmation),
	// The surface over the content that takes input; see window_overlay.odin. The menus' rows and the
	// rename field below are storage the surfaces reuse.
	overlay: Window_Overlay,
	tab_menu: Tab_Menu,
	profile_menu: Profile_Menu,
	document_menu: Document_Menu,
	rename: ui.Text_Field,
	workspace_picker: Workspace_Picker,
	workspace_hovered: bool,
	workspace_motion: ui.Control_Motion,
	caption_hover: int,
	caption_armed: ui.Armed(int),
	maximized: bool,
	pane_fill: layout.Pane_Fill,
	paste_confirm: Paste_Confirm,
	wheel_remainder: f32,
	cursor_blink: Cursor_Blink,
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
	if !window_commit(app, w) {window_close(app, w); return false}
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
	w.phase = .Preparing
	w.scale = f32(platform.primary_dpi(&app.platform)) / 96
	w.ui_text = app.ui_text
	w.metrics = window_metrics(app, w.scale)
	w.rail_default_width = f32(app.settings.tabs.rail_width)
	w.list = render.draw_list_init()
	w.rail_rows = make([dynamic]Rail_Row)
	ui.find_init(&w.find)
	profile_menu_init(&w.profile_menu)
	document_menu_init(&w.document_menu)
	w.tab_hover, w.rail_hover = -1, -1
	w.caption_hover = -1
	w.float_header_shown = layout.INVALID_NODE
	w.pointer_shape = .Text
	w.dirty = true
	if !workspace_view_init(app, &w.resources, workspace) {window_free(w); return nil}
	focus_init(w)
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
	if render_error := window_surface_create(app, w); render_error != .None {
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

// Preparing → Shown: the window owns its content from here and takes input. A show the OS refuses leaves it
// Preparing, so callers commit before moving content in and can still discard the window.
@(require_results)
window_commit :: proc(app: ^App, w: ^Window) -> bool {
	assert(w.phase == .Preparing)
	show_error := platform.window_show_inactive(&app.platform, w.id)
	if show_error != .None {
		log.errorf("showing the window failed: %v", show_error)
		return false
	}
	w.phase, w.dirty = .Shown, true
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
	if w.phase == .Closing {return}
	// A window still Preparing (a preview, or one whose show failed) stays Preparing through the cancel:
	// cancelling the drag that made a preview is how it is discarded, and that discard closes it from
	// inside this call. Any other window is Closing first, so nothing the cancel sets off takes it for a
	// live window or closes it again.
	if w.phase != .Preparing {w.phase = .Closing}
	if !gesture_cancel(app, w) {return}
	w.phase = .Closing
	window_overlays_cancel(app, w)
	file_dialogs_window_closed(app, w.id)
	view, id := window_linked(w) ? w.workspace : nil, w.id
	for i in 0 ..< len(app.windows) {
		if app.windows[i] == w {
			ordered_remove(&app.windows, i)
			break
		}
	}
	window_surface_release(w)
	if platform.window_destroy(&app.platform, w.id) != .None {
		log.error("destroying the window failed")
	}
	window_free(w)
	if view != nil {workspace_destroy(view)}
	window_notices_sync(app)
	// A destroyed window never reports losing focus, so the jump list follows the notices to the window
	// focused most recently.
	if app.focus_jumps.window == id {app.focus_jumps.window = app.notice_window}
}

@(private)
window_free :: proc(w: ^Window) {
	workspace_view_destroy(&w.resources)
	drag_destroy(w)
	delete(w.rail_rows)
	ui.find_destroy(&w.find)
	profile_menu_destroy(&w.profile_menu)
	document_menu_destroy(w)
	delete(w.rename.bytes)
	workspace_picker_destroy(w)
	delete(w.float_capsules)
	delete(w.float_capsule_widths)
	confirmation_clear(w)
	render.draw_list_destroy(&w.list)
	free(w)
}

window_find :: proc(app: ^App, id: input.Window_Id) -> ^Window {
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
	horizontal := window_linked(w) || app.settings.tabs.orientation == .Horizontal
	placement_changed := horizontal != w.tabs_horizontal
	w.tabs_horizontal = horizontal
	if placement_changed {
		rail_resize_cancel(w)
		w.tab_hover = -1
		gesture_tab_unpress(w)
	}
	if placement_changed && !horizontal {
		// Returning from the strip restores the rail's automatic state; a manual hide or overlay
		// does not survive the mode switch.
		rail_auto_reset(w)
	}
	if placement_changed && horizontal {
		// The rail rows hold workspace pointers from the old surface and are not read again until
		// the rail returns, when relayout rebuilds them.
		clear(&w.rail_rows)
		w.rail_hover = -1
	}
	window_relayout(app, w)
}

window_resize :: proc(app: ^App, w: ^Window, width, height: i32) {
	w.maximized = platform.window_maximized(&app.platform, w.id)
	w.width, w.height = width, height
	if window_minimized(w) {
		return
	}
	rail_adaptive_update(w)
	window_surface_resize(app, w, width, height)
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
	if w.phase == .Preparing || window_minimized(w) {return}
	bar_height := window_title_height(w)
	tab_count := w.workspace != nil ? len(w.workspace.tabs) : 0
	if tab_count != len(w.tab_positions) {
		w.tab_hover = -1
		// Only the strip's presses draw from the tab positions.
		if w.tabs_horizontal {gesture_tab_unpress(w)}
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
	layout.floats_place(w.tree, floating_area(w), gap, floating_header_height(w), &w.panes)
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
	if w.phase == .Preparing || window_minimized(w) || w.tree == nil {return}
	tiled := len(window_tiled_rects(w))
	resize(&w.panes, tiled)
	layout.floats_place(w.tree, floating_area(w), window_gap(app, w), floating_header_height(w), &w.panes)
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

window_render :: proc(app: ^App, w: ^Window) {
	if w.width <= 0 || w.height <= 0 {return}
	if !window_surface_ready(app, w) {return}
	surface := window_surface(w)
	if err := render.frame_wait(surface, FRAME_WAIT_MS); err == .Wait_Failed {
		log.error("waiting for the swap chain failed")
	}
	background := app.theme.window
	build_start := time.tick_now()
	if !window_build_frame(app, w) {return}
	perf.mark_built(&app.perf)
	build_ms := perf.since_ms(build_start)
	w.gloss_hovered = ui.hover_rim_present(&w.list)
	render_start := time.tick_now()
	err := render.frame_render(app.device, surface, &w.list, background)
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
		// Each float's frame and header draw with it, so a higher float covers a lower one's.
		if root := layout.float_root(w.tree, pane.node); root != group {
			group = root
			floating_header_draw(app, w, root)
		}
		result: glyphs.Result
		frame, result = pane_draw(app, w, pane, &blinking)
		if result != .Ok {return frame, result}
	}
	if result := floating_capsules_draw(app, w); result != .Ok {return frame, result}
	cursor_blink_observe(w, blinking)
	if result := pane_drag_draw(app, w); result != .Ok {return frame, result}
	if result := tab_drag_draw(app, w); result != .Ok {return frame, result}
	if result := window_leader_draw(app, w); result != .Ok {return frame, result}
	size := [2]f32{f32(w.width), f32(w.height)}
	if ui.find_is_open(&w.find) {
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
	#partial switch _ in w.overlay {
	case Overlay_Rename, Overlay_Chip_Name:
		if result := rename_draw(app, w); result != .Ok {return frame, result}
	}
	if result := confirmation_draw(app, w); result != .Ok {return frame, result}
	#partial switch _ in w.overlay {
	case Overlay_Tab_Menu, Overlay_Divider_Menu:
		if result := tab_menu_draw(app, w); result != .Ok {return frame, result}
	case Overlay_Profile_Menu:
		if result := profile_menu_draw(app, w); result != .Ok {return frame, result}
	case Overlay_Document_Menu:
		if result := document_menu_draw(app, w); result != .Ok {return frame, result}
	}
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
	if entry == nil || view == nil {return frame, .Ok}
	c := app.settings.colors
	selection_foreground: Maybe(render.Color)
	if fg, ok := c.selection_foreground.?; ok {selection_foreground = color(fg)}
	content_focused :=
		w.focused && pane.node == w.tree.focus && !palette_active(app, w) &&
		!ui.find_has_keyboard(&w.find)
	hover := link_hover_range(w, pane.content)
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
		cursor_phase_visible = !content_focused || cursor_visible(w),
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
