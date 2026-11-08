package main

import "aio:input"
import "aio:colour"
import "aio:layout"
import "aio:perf"
import "aio:platform"
import "aio:render"
import "aio:term"
import "aio:term_view"
import "aio:ui"
import "core:log"
import "core:time"

// perf is used only when FRAME_STATS is set.
_ :: perf

@(private)
FRAME_WAIT_MS :: 100

// Frame timing and counters for `aioctl perf` and the frame construction tests. Release builds
// compile none of it, so their frames read no clock and fill no sample ring.
@(private)
FRAME_STATS :: AIO_CONTROL || ODIN_TEST

// A pane's state in one window: header controls for every pane and, for a terminal, its drawing view,
// cached draw list and the links on its screen (see term_links.odin). pane_view_create makes one and
// pane_view_destroy releases it.
Pane_View :: struct {
	content: layout.Content,
	view: term_view.View,
	cache: render.Draw_List,
	links: term.Link_Map,
	valid: bool,
	generation, atlas_generation, builds: u64,
	image_epoch: u64,
	style: term_view.Style,
	frame: term_view.Frame,
	header_controls: [Pane_Header_Button]ui.Control_Motion,
	header_hover:   Pane_Header_Target,
	header_armed:   ui.Armed(Pane_Header_Target),
}

Window :: struct {
	id: input.Window_Id,
	surface: Window_Surface,
	ui_text: ui.Text,
	using markdown_pointer: Markdown_Pointer,
	using resources: Workspace_View_Resources,
	gesture: Gesture_State,
	// The pane scrollbar under the pointer and a held thumb; see pane_scrollbar.odin.
	scrollbars: Pane_Scrollbars,
	// A divider press, drag or the first click of a double-click; see divider_drag.odin.
	divider: Divider_Gesture,
	// The pane or tab drag this window's pointer holds; see drag.odin.
	drag: Drag,
	using floats: Float_Window_State,
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
	using tooltip_state: Tooltip_State,
	pointer_shape: platform.Cursor_Shape,
	// The last frame drew a pointer-following rim, so pointer movement must repaint it.
	gloss_hovered: bool,
	find: ui.Find_Bar,
	using keys: Key_State,
	// Tab placement: horizontal restores the title-bar strip and the presentation arrays below.
	tabs_horizontal: bool,
	using tab_chrome: Tab_Chrome_State,
	using rail_state: Rail_State,
	// The Activity panel's width left of the rail; see window_dock_reserve.
	dock_left_width: f32,
	using title_controls: Title_Controls,
	// The question asked before a destructive change, with its subject; see confirmation.odin.
	confirmation: Maybe(Confirmation),
	using surfaces: Overlay_Surfaces,
	workspace_picker: Workspace_Picker,
	maximized: bool,
	pane_fill: layout.Pane_Fill,
	paste_confirm: Paste_Confirm,
	wheel_remainder: f32,
	cursor_blink: Cursor_Blink,
	using frame_wakes: Frame_Wakes,
	taskbar: Status_Taskbar,
	status: Status_Overview,
	// The rail height the activity panel takes in vertical view; see window_dock_reserve.
	status_rail_reserve: f32,
	// The dock edges shown beside the layout's dividers, refreshed with them by window_dividers.
	dock_edges: Dock_Edges_Shown,
}

// What the last frame drew that asks for another frame. build_frame clears it and drawing fills it in,
// because only drawing knows which of these it showed; the loop's wake inventory reads it.
Frame_Wakes :: struct {
	// A spinner drew, so frames follow the display until one draws none; see status_spin_active.
	status_spinning: bool,
	// The earliest end of a synchronized-output hold the frame drew through: the frame showed the held
	// screen, so the window draws again then even if the program writes nothing more.
	capture_hold: Maybe(time.Tick),
}

// Windows reports DPI with 96 as 100%.
dpi_scale :: proc(dpi: u32) -> f32 {
	return f32(dpi) / 96
}

// Font points to pixels at a window scale: a point is 1/72 inch and scale 1 is 96 pixels per inch.
points_pixels :: proc(points, scale: f32) -> f32 {
	return points * scale * 96 / 72
}

window_metrics :: proc(app: ^App, scale: f32) -> term_view.Metrics {
	return term_view.compute_metrics(
		app.fonts,
		app.family,
		points_pixels(app.font_points, scale),
		f32(app.settings.font.line_height),
	)
}

// --no-activate runs the app for automation without taking the user's focus: no window activates or
// maximizes itself, window_activate only shows one, and a drag treats its own occluded window as under
// the pointer. Every such decision asks here.
activation_suppressed :: proc(app: ^App) -> bool {
	return app.options.inactive
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
	// Settings applied while Preparing; a shown window lays out all of its chrome and panes.
	window_relayout(app, w)
	if !activation_suppressed(app) {_ = window_activate(app, w)}
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
	w.scale = dpi_scale(platform.primary_dpi(&app.platform))
	w.list = render.draw_list_init()
	ui.find_init(&w.find)
	overlay_surfaces_init(&w.surfaces)
	floating_window_init(&w.floats)
	w.pointer_shape = .Text
	w.dirty = true
	if !workspace_view_init(app, &w.resources, workspace) {window_free(w); return nil}
	focus_init(w)
	if w.workspace.selection_anchor == 0 {tab_select_one(w.workspace, w.workspace.selected)}
	tab_chrome_reset(w)
	// Every new window opens at the configured size, whatever window its content last filled.
	g := initial_geometry(app)
	desc := platform.Window_Desc {
		title = app.app_id,
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
	// The settings apply once, at the scale of the monitor the window opened on.
	if dpi := platform.window_dpi(&app.platform, id); dpi != 0 {
		window_set_dpi(app, w, dpi)
	} else {
		window_apply_settings(app, w)
	}
	rail_reveal_active(w)
	if platform.window_set_cursor(&app.platform, id, .Text) != .None {
		log.error("setting the window cursor failed")
	}
	window_update_title(app, w)
	return w
}

// Preparing → Shown: the window owns its content from here and takes input. A show the OS refuses leaves it
// Preparing, so callers commit before moving content in and can still discard the window. A Preparing
// window skips most of window_relayout, title-bar hit area included, so every caller lays the shown
// window out before returning to the loop: window_open at once, a tear-off once its content has moved.
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
	if activation_suppressed(app) {
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

// The layout w shows, derived from its workspace's selected tab; nil while it has no tab to show.
window_tree :: proc(w: ^Window) -> ^layout.Layout {
	return w == nil ? nil : workspace_view_tree(&w.resources)
}

window_close :: proc(app: ^App, w: ^Window) {
	switch w.phase {
	case .Closing:
		return
	case .Preparing:
		// A window still Preparing (a preview, or one whose show failed) stays Preparing through the
		// cancel: cancelling the drag that made a preview is how it is discarded, and that discard closes
		// it from inside this call, which leaves nothing more to do here.
		if !gesture_cancel(app, w) {return}
		w.phase = .Closing
	case .Shown, .Hidden:
		// Closing first, so nothing the cancel sets off takes w for a live window or closes it again;
		// window_close returns at once for a Closing window, so w outlives the cancel.
		w.phase = .Closing
		_ = gesture_cancel(app, w)
	}
	window_overlays_cancel(app, w)
	// A file dialog belongs to its native window, so it closes before the window does.
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
	// A linked window's workspace is its private view of the tab's panes.
	if view != nil {workspace_destroy(view)}
	// The notices and the jump list move on to the window focused most recently.
	window_notices_sync(app)
	focus_jumps_window_closed(app, id)
}

// Each feature releases what it keeps in w; zero state is safe, so a window that failed part way
// through window_prepare is freed the same way.
@(private)
window_free :: proc(w: ^Window) {
	workspace_view_destroy(&w.resources)
	drag_destroy(w)
	ui.find_destroy(&w.find)
	overlay_surfaces_destroy(w)
	workspace_picker_destroy(w)
	floating_window_destroy(&w.floats)
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
	w.scale = dpi_scale(dpi)
	rail_adaptive_update(w)
	window_apply_settings(app, w)
}

// After the OS placed w, as a tear-off drop or a restored linked window does, w takes the DPI of the
// monitor it landed on and the client size it now has. False when the size cannot be read.
@(require_results)
window_sync_placement :: proc(app: ^App, w: ^Window) -> bool {
	if dpi := platform.window_dpi(&app.platform, w.id); dpi != 0 && dpi_scale(dpi) != w.scale {
		window_set_dpi(app, w, dpi)
	}
	width, height, size_error := platform.window_client_size(&app.platform, w.id)
	if size_error != .None {return false}
	if width != w.width || height != w.height {window_resize(app, w, width, height)}
	return true
}

// What a window derives from the settings at a scale, without side effects. window_apply_settings
// stores it, apart from header_height, which window_relayout stores as it places the panes;
// initial_geometry sizes the first window by it before any window exists.
Window_Settings_Fields :: struct {
	metrics:            term_view.Metrics,
	rail_default_width: f32,
	tabs_horizontal:    bool,
	header_height:      f32,
}

window_settings_fields :: proc(app: ^App, scale: f32, linked: bool) -> Window_Settings_Fields {
	return {
		metrics = window_metrics(app, scale),
		rail_default_width = f32(app.settings.tabs.rail_width),
		// A linked window has no tabs to place, and the rail is the only placement that takes pane space.
		tabs_horizontal = linked || app.settings.tabs.orientation == .Horizontal,
		header_height = pane_header_row_height(app, scale),
	}
}

window_apply_settings :: proc(app: ^App, w: ^Window) {
	w.ui_text = app.ui_text
	ui.text_set_size(&w.ui_text, points_pixels(f32(app.settings.interface.font_size), w.scale))
	fields := window_settings_fields(app, w.scale, window_linked(w))
	w.metrics = fields.metrics
	w.rail_default_width = fields.rail_default_width
	colors := app.settings.active_theme.colors
	if platform.window_set_frame_color(&app.platform, w.id, colors[.Tab_Bar].rgb, colors[.Text].rgb) !=
	   .None {
		log.error("setting the window frame color failed")
	}
	horizontal := fields.tabs_horizontal
	placement_changed := horizontal != w.tabs_horizontal
	w.tabs_horizontal = horizontal
	if placement_changed {
		rail_resize_cancel(w)
		tab_chrome_forget_hover(w)
	}
	if placement_changed && !horizontal {
		// Returning from the strip restores the rail's automatic state; a manual hide or overlay
		// does not survive the mode switch.
		rail_auto_reset(w)
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
	window_dock_reserve(app, w)
	workspace_picker_layout_changed(w)
	if palette_visible(app, w) {
		ui.palette_fit(&app.palette, f32(w.width), f32(w.height), w.scale)
	}
	if w.phase == .Preparing || window_minimized(w) {return}
	bar_height := window_title_height(w)
	tab_presentation_fit(w)
	platform.window_title_bar(
		&app.platform,
		w.id,
		i32(bar_height),
		i32(window_title_controls_end(app, w)),
	)
	// The rail owner stores its scroll clamp for the new size.
	_, _ = rail_current_layout(w)
	pane_header_relayout_reset(w)
	w.header_height = pane_header_row_height(app, w.scale)
	layout.place_shown(window_tree(w), window_geometry(app, w, w.pane_fill), pane_view_solo(w), &w.panes)
	window_panes_placed(app, w, 0)
	rail_reveal_active(w)
}

// Lays out only the floating panes, after one opened, moved, resized, rose or was minimized. The tiled
// panes keep their rectangles, grids and cached drawing.
window_floats_layout :: proc(app: ^App, w: ^Window) {
	tree := window_tree(w)
	if w.phase == .Preparing || window_minimized(w) || tree == nil {return}
	tiled := len(window_tiled_rects(w))
	resize(&w.panes, tiled)
	g := window_geometry(app, w, w.pane_fill)
	layout.floats_place(tree, g.floating, g.gap, g.header, &w.panes)
	window_panes_placed(app, w, tiled)
}

// What follows placing w.panes[first:], for the full and the floats-only relayout alike: the dividers,
// the views of panes no longer shown, each placed pane's grid and cached drawing, and the capsules.
@(private)
window_panes_placed :: proc(app: ^App, w: ^Window, first: int) {
	window_dividers(app, w)
	window_views_prune(w)
	for pane in w.panes[first:] {
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
		pane_view_destroy(&w.views[i])
		ordered_remove(&w.views, i)
	}
}

// Sizes a pane's terminal to its rectangle and makes sure the window keeps a view for it.
@(private)
pane_fit :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	entry := workspace_session_for_content(app, pane.content)
	if entry == nil {
		if pane_view(w, pane.content) == nil {
			cached, _ := pane_view_create(pane.content, false)
			if _, err := append(&w.views, cached); err != nil {
				log.error("storing a pane's header state failed")
			}
		}
		return
	}
	box := pane_box(
		w.metrics,
		pane.rect,
		pane_insets(app, w, entry, pane),
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
		cached, created := pane_view_create(pane.content, true)
		if !created {
			log.error("creating a terminal view failed")
			return
		}
		if _, err := append(&w.views, cached); err != nil {
			pane_view_destroy(&cached)
			log.error("storing a terminal view failed")
		}
	}
}

// The one lookup of the state a window keeps for the pane showing `content`; nil when it has none.
@(private)
pane_view :: proc(w: ^Window, content: layout.Content) -> ^Pane_View {
	for &pane in w.views {
		if pane.content == content {
			return &pane
		}
	}
	return nil
}

// A terminal's view, cache and link index are made together; any other pane keeps only its header
// state. A failure leaves nothing to release.
@(require_results)
pane_view_create :: proc(content: layout.Content, terminal: bool) -> (pane: Pane_View, ok: bool) {
	pane.content = content
	if !terminal {return pane, true}
	if !term_view.create(&pane.view) {return {}, false}
	if !term.link_map_create(&pane.links) {
		term_view.destroy(&pane.view)
		return {}, false
	}
	pane.cache = render.draw_list_init()
	return pane, true
}

pane_view_destroy :: proc(pane: ^Pane_View) {
	if !pane_owns_session(pane.content.kind) {return}
	term_view.destroy(&pane.view)
	render.draw_list_destroy(&pane.cache)
	term.link_map_destroy(&pane.links)
}

// The session shown in the focused pane, which receives keyboard input.
focused_session :: proc(app: ^App, w: ^Window) -> ^Session_Entry {
	content, is_pane := window_focused_content(w)
	return is_pane ? workspace_session_for_content(app, content) : nil
}

window_render :: proc(app: ^App, w: ^Window) {
	if window_minimized(w) {return}
	if !window_surface_ready(app, w) {return}
	surface := window_surface(w)
	if err := render.frame_wait(surface, FRAME_WAIT_MS); err == .Wait_Failed {
		log.error("waiting for the swap chain failed")
	}
	background := app.theme.window
	when FRAME_STATS {build_start := time.tick_now()}
	if !window_build_frame(app, w) {return}
	when FRAME_STATS {
		perf.mark_built(&app.perf)
		build_ms := perf.since_ms(build_start)
	}
	w.gloss_hovered = ui.hover_rim_present(&w.list)
	when FRAME_STATS {render_start := time.tick_now()}
	err := window_surface_present(app, w, background)
	when FRAME_STATS {render_ms := perf.since_ms(render_start)}
	// The surface module recovered a lost device; the next frame draws on the new one.
	if err == .Device_Lost {return}
	if err != .None {
		log.errorf("rendering a frame failed: %v", err)
	}
	// A failed render still built a draw list, but only a presented frame can carry an input
	// latency sample; counting successes alone keeps frames.presented meaningful. The render
	// start tick is the idle predicate's clock, so a frame reads the clock only twice.
	when FRAME_STATS {
		if err == .None {
			perf.record_frame(&app.perf, build_ms, render_ms, perf.idle_at(&app.perf, render_start))
		}
	}
	w.dirty = false
}

// Only a completed draw list may be submitted or counted as built. Failed construction keeps
// the window dirty, so a later healthy attempt can recover without waiting for new terminal output.
@(require_results)
window_build_frame :: proc(app: ^App, w: ^Window) -> bool {
	build := render.frame_build_begin(&w.list, app.device)
	for {
		build_frame(app, w)
		switch render.frame_build_finish(&build) {
		case .Ready: return true
		case .Retry:
		case .Failed: return false
		}
	}
}

// Builds the window's draw list. An atlas reset stops the build at once; window_build_frame then reads
// the draw list to decide whether to build again.
@(private)
build_frame :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	blinking := false
	w.frame_wakes = {}
	// Floating panes draw after the chrome, whose shared pane borders would otherwise cross them.
	for pane in w.panes {
		if pane.floating {continue}
		if result := pane_draw(app, w, pane, &blinking); result != .Ok {return result}
	}
	if w.pane_fill != .Screen {
		if result := window_chrome_draw(app, w); result != .Ok {return result}
	}
	if result := rail_draw(app, w); result != .Ok {return result}
	if result := status_panel_draw(app, w); result != .Ok {return result}
	group := layout.INVALID_NODE
	tree := window_tree(w)
	for pane in w.panes {
		if !pane.floating {continue}
		// Each float's frame and header draw with it, so a higher float covers a lower one's.
		if root := layout.float_root(tree, pane.node); root != group {
			group = root
			floating_header_draw(app, w, root)
		}
		if result := pane_draw(app, w, pane, &blinking); result != .Ok {return result}
	}
	if result := floating_capsules_draw(app, w); result != .Ok {return result}
	cursor_blink_observe(w, blinking)
	if result := pane_drag_draw(app, w); result != .Ok {return result}
	if result := tab_drag_draw(app, w); result != .Ok {return result}
	if result := window_leader_draw(app, w); result != .Ok {return result}
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
			return result
		}
	}
	if palette_visible(app, w) {
		result := ui.palette_draw(
			&app.palette, &w.list, &w.ui_text, app.theme, size.x, size.y, w.scale,
			ui.presence_fade(app.palette.presence, ui.RISE_DIALOG * w.scale), w.pointer,
		)
		if result != .Ok { return result }
	}
	if result := overlay_draw(app, w); result != .Ok {return result}
	if result := status_inbox_draw(app, w); result != .Ok {return result}
	if result := tooltip_draw(app, w); result != .Ok {return result}
	if app.notice_window != w.id {return .Ok}
	return ui.notices_draw(
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
pane_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect, blinking: ^bool) -> render.Build_Status {
	card := len(w.list.rects)
	window_card_draw(app, w, pane)
	switch pane.content.kind {
	case .Terminal:
	case .Settings:
		return settings_pane_draw(app, w, pane, card)
	case .Markdown:
		return markdown_pane_draw(app, w, pane, card)
	}
	entry := workspace_session_for_content(app, pane.content)
	state := pane_view(w, pane.content)
	if entry == nil || state == nil {return .Ok}
	view := &state.view
	c := app.settings.colors
	selection_foreground: Maybe(render.Color)
	if fg, ok := c.selection_foreground.?; ok {selection_foreground = colour.rgba(fg)}
	content_focused := pane_has_keyboard(app, w, pane)
	hover := link_hover_range(w, pane.content)
	minimum_contrast := f32(1)
	if app.settings.active_theme.terminal_light {
		minimum_contrast = f32(app.settings.terminal.minimum_contrast)
	}
	style := term_view.Style {
		family = app.family,
		selection_background = colour.rgba(c.selection_background),
		selection_foreground = selection_foreground,
		search_foreground = colour.rgba(c.search_foreground),
		search_background = colour.rgba(c.search_background),
		search_selected_background = colour.rgba(c.search_selected_background),
		cursor_text = colour.rgba(c.cursor_text),
		minimum_contrast = minimum_contrast,
		focused = content_focused,
		cursor_phase_visible = !content_focused || cursor_visible(w),
		hover = hover,
	}
	box := pane_box(
		w.metrics,
		pane.rect,
		pane_insets(app, w, entry, pane),
	)
	frame, result := build_pane(app, w, pane, entry, view, box.origin, style)
	if result != .Ok {return result}
	if held, ok := frame.capture.(term.Capture_Held); ok {capture_hold_note(w, held.until)}
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
		); message_result != .Ok {return message_result}
	}
	if header_result := pane_header_draw(app, w, pane, entry);
	   header_result != .Ok {return header_result}
	pane_scrollbar_draw(app, w, pane)
	window_card_dim(app, w, pane, frame.background)
	window_card_outline(app, w, pane)
	return .Ok
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
	render.Build_Status,
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
		atlas := render.atlas_generation(app.device)
		if !cached.valid ||
		   cached.generation != term.generation(entry.session) ||
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
				cached.atlas_generation = render.atlas_generation(app.device)
				cached.image_epoch = render.image_epoch(app.device)
				// Only a read screen is cached, under the generation it was read at. A held or
				// failed capture drew the previous screen; rebuild on the next frame.
				if updated, ok := frame.capture.(term.Capture_Updated); ok {
					cached.generation, cached.valid = updated.generation, true
				}
				cached.builds += 1
			}
		}
		_ = render.append_list(&w.list, &cached.cache)
		return cached.frame, .Ok
	}
	return {}, .Ok
}

@(private)
capture_hold_note :: proc(w: ^Window, until: time.Tick) {
	if at, held := w.capture_hold.?; held && time.tick_diff(at, until) >= 0 {return}
	w.capture_hold = until
}

capture_hold_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	until, held := w.capture_hold.?
	return until, held
}

// A hold that outlived its limit no longer stops capture, so the next frame reads the screen.
capture_hold_tick :: proc(w: ^Window, now: time.Tick) {
	until, held := w.capture_hold.?
	if !held || time.tick_diff(until, now) < 0 {return}
	w.capture_hold = nil
	w.dirty = true
}
