package main

import "aio:glyphs"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:settings"
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
	style: term_view.Style,
	frame: term_view.Frame,
	header_controls: [4]ui.Control_Motion,
	header_hover, header_pressed: ui.Header_Action,
}

Window :: struct {
	id: platform.Window_Id,
	surface: ^render.Surface,
	ui_text: ui.Text,
	using resources: Workspace_View_Resources,
	gesture: Gesture_State,
	dragging: Divider_Drag,
	divider_click_node: layout.Node_Id,
	divider_click_ns: i64,
	pane_drag: Pane_Drag,
	tab_drag: Tab_Drag,
	// A single pane has no header row, so its split controls appear while the pointer is near its top.
	split_overlay: bool,
	list: render.Draw_List,
	width, height: i32,
	header_height: f32,
	header_buttons: input.Mouse_Buttons,
	scale: f32,
	metrics: term_view.Metrics,
	focused, dirty: bool,
	preparing, preview_visible: bool,
	generation: u64,
	selecting: bool,
	// While a selection drag is past the top or bottom edge, history scrolls a row per AUTOSCROLL_INTERVAL.
	autoscrolling: bool,
	autoscroll_deadline: time.Tick,
	pointer: [2]f32,
	pointer_shape: platform.Cursor_Shape,
	find: ui.Find_Bar,
	leader_until: time.Tick,
	tab_underline: ui.Motion,
	tab_hover: int,
	tab_pressed: bool,
	tab_close_pressed: int,
	// Asks before a destructive close and holds its subject, live counts and presentation state.
	pending_close: Pending_Close,
	close_restore: [dynamic]u32,
	tab_menu: Tab_Menu,
	rename: ui.Text_Field,
	rename_open: bool,
	rename_target: Rename_Target,
	workspace_picker: Workspace_Picker,
	caption_hover, caption_pressed: int,
	maximized: bool,
	paste_confirm_until: time.Tick,
	suppressed_key: Maybe(platform.Key_Event),
	wheel_remainder: f32,
	blinking, cursor_phase_visible: bool,
	blink_deadline: time.Tick,
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
	w.list = render.draw_list_init()
	ui.find_init(&w.find)
	w.tab_hover = -1
	w.tab_close_pressed = -1
	w.caption_hover, w.caption_pressed = -1, -1
	w.divider_click_node = layout.INVALID_NODE
	w.pointer_shape = .Text
	w.cursor_phase_visible = true
	w.dirty = true
	if !workspace_view_init(app, &w.resources, workspace) {window_free(w); return nil}
	if w.workspace.selection_anchor == 0 {tab_select_one(w.workspace, w.workspace.selected)}
	g := initial_geometry(app)
	if entry := focused_session(app, w); entry != nil {g = term.geometry(entry.session)}
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
	w.preview_visible, w.dirty = true, true
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
}

@(private)
window_free :: proc(w: ^Window) {
	workspace_view_destroy(&w.resources)
	delete(w.tab_drag.order)
	ui.find_destroy(&w.find)
	delete(w.rename.bytes)
	workspace_picker_destroy(w)
	delete(w.close_restore)
	pending_close_clear(&w.pending_close)
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
	window_apply_settings(app, w)
}

window_apply_settings :: proc(app: ^App, w: ^Window) {
	ui.text_set_size(&w.ui_text, f32(app.settings.interface.font_size) * w.scale * 96 / 72)
	w.metrics = window_metrics(app, w.scale)
	theme := settings.theme_resolve(app.settings.theme)
	if platform.window_set_frame_color(&app.platform, w.id, theme.chrome, theme.text) != .None {
		log.error("setting the window frame color failed")
	}
	window_relayout(app, w)
}

window_resize :: proc(app: ^App, w: ^Window, width, height: i32) {
	w.maximized = platform.window_maximized(&app.platform, w.id)
	w.width, w.height = width, height
	if width <= 0 || height <= 0 {
		return
	}
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
	w.dirty = true
	workspace_picker_layout_changed(w)
	if palette_visible(app, w) {
		ui.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
	}
	if w.preparing { return }
	if w.width <= 0 || w.height <= 0 {
		return
	}
	if !tab_presentation_resize(&w.presentation, len(w.workspace.tabs)) {
		log.error("resizing tab presentation values failed")
	}
	bar := window_tab_bar(app, w)
	platform.window_title_bar(
		&app.platform,
		w.id,
		i32(bar.height),
		i32(bar.x + f32(bar.count) * bar.tab_width + 2 * bar.button_width),
	)
	pane_header_cancel(w)
	for &view in w.views {view.header_controls = {}}
	kind: layout.Content_Kind = .Terminal
	if settings_active(w) {kind = .Settings}
	w.header_height = pane_header_height(w.scale, app.settings.pane.show_headers, kind)
	area := window_content_area(app, w)
	layout.compute(w.tree, area, window_gap(app, w), &w.panes)
	layout.dividers(w.tree, area, window_gap(app, w), &w.dividers)
	for i := len(w.views) - 1; i >= 0; i -= 1 {
		visible := false
		for pane in w.panes {visible ||= pane.content == w.views[i].content}
		if !visible {
			term_view.destroy(&w.views[i].view)
			render.draw_list_destroy(&w.views[i].cache)
			ordered_remove(&w.views, i)
		} else {w.views[i].valid = false}
	}
	for pane in w.panes {
		entry := session_find(app, pane.content.id)
		if entry == nil {
			continue
		}
		box := pane_box(
			w.metrics,
			pane.rect,
			pane_insets(app, w.scale, entry, pane.content.kind),
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
		if g != term.geometry(entry.session) {
			term.resize(entry.session, g)
		}
		if pane_view(w, pane.content) == nil {
			view: term_view.View
			if !term_view.create(&view) {
				log.error("creating a terminal view failed")
				continue
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
	return session_find(app, pane.content.id)
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
	if w.preparing {pane_window_preview_render(app, w); return}
	if err := render.frame_wait(w.surface, FRAME_WAIT_MS); err == .Wait_Failed {
		log.error("waiting for the swap chain failed")
	}
	background := app.theme.window
	for _ in 0 ..< 2 {
		_, result := build_frame(app, w)
		if result == .Ok {
			break
		}
	}
	err := render.frame_render(app.device, w.surface, &w.list, background)
	if err == .Device_Lost {
		recover_device(app)
		return
	}
	if err != .None {
		log.errorf("rendering a frame failed: %v", err)
	}
	w.dirty = false
}

@(private)
build_frame :: proc(app: ^App, w: ^Window) -> (term_view.Frame, glyphs.Result) {
	render.draw_list_reset(&w.list)
	frame: term_view.Frame
	blinking := false
	c := app.settings.colors
	selection_foreground: Maybe(render.Color)
	if fg, ok := c.selection_foreground.?; ok {
		selection_foreground = color(fg)
	}
	for pane in w.panes {
		card := len(w.list.rects)
		window_card_draw(app, w, pane)
		if pane.content.kind == .Settings {
			if card < len(w.list.rects) {w.list.rects[card].color = app.theme.pane}
			result := ui.editor_draw(
				&w.editor,
				settings_layout(w),
				&w.list,
				&w.ui_text,
				app.theme,
				w.focused && !palette_active(app, w),
			)
			if result != .Ok {return frame, result}
			window_card_outline(app, w, pane)
			continue
		}
		entry := session_find(app, pane.content.id)
		view := pane_view(w, pane.content)
		if entry == nil || view == nil {
			continue
		}
		content_focused :=
			w.focused && pane.node == w.tree.focus && !palette_active(app, w) && !w.find.open
		style := term_view.Style {
			family = app.family,
			selection_background = color(c.selection_background),
			selection_foreground = selection_foreground,
			search_foreground = color(c.search_foreground),
			search_background = color(c.search_background),
			search_selected_background = color(c.search_selected_background),
			cursor_text = color(c.cursor_text),
			minimum_contrast = app.settings.theme.mode == .Light ? f32(app.settings.terminal.minimum_contrast) : 1,
			focused = content_focused,
			cursor_phase_visible = !content_focused || w.cursor_phase_visible,
		}
		box := pane_box(
			w.metrics,
			pane.rect,
			pane_insets(app, w.scale, entry, pane.content.kind),
		)
		result: glyphs.Result
		frame, result = build_pane(app, w, pane, entry, view, box.origin, style)
		if result != .Ok {
			return frame, result
		}
		if card < len(w.list.rects) {w.list.rects[card].color = frame.background}
		blinking ||= frame.cursor_blinking && content_focused
		if entry.status != .Running {
			message := session_message(term.status(entry.session))
			if message_result := ui.pane_message_draw(
				&w.list,
				&w.ui_text,
				app.theme,
				{pane.rect.x, pane.rect.y, pane.rect.width, pane.rect.height},
				message,
				w.scale,
				f32(app.settings.pane.corner_radius) * w.scale,
			); message_result != .Ok {return frame, message_result}
		}
		if header_result := pane_header_draw(app, w, pane, entry);
		   header_result != .Ok {return frame, header_result}
		window_card_outline(app, w, pane)
	}
	if blinking != w.blinking {
		w.blinking = blinking
		reset_blink(w)
	}
	if result := window_chrome_draw(app, w); result != .Ok {return frame, result}
	if result := pane_drag_draw(app, w); result != .Ok {return frame, result}
	if result := window_leader_draw(app, w); result != .Ok {return frame, result}
	size := [2]f32{f32(w.width), f32(w.height)}
	if w.find.open {
		status, enabled := find_presentation(w, focused_session(app, w))
		result := ui.find_draw(&w.find, &w.list, &w.ui_text, app.theme, status, enabled, size.x, size.y, w.scale)
		if result != .Ok {
			return frame, result
		}
	}
	if palette_visible(app, w) {
		opacity, rise := ui.presence_fade(app.palette.presence, 4 * w.scale)
		result := ui.palette_draw(
			&app.palette, &w.list, &w.ui_text, app.theme, size.x, size.y, w.scale,
			opacity, rise,
		)
		if result != .Ok { return frame, result }
	}
	if pc := &w.pending_close; ui.presence_visible(pc.confirm.presence) {
		layers, rects, glyph_count := len(w.list.layers), len(w.list.rects), len(w.list.glyphs)
		content := pending_close_text(app, pc, w.workspace)
		result := ui.confirm_draw(
			&pc.confirm,
			&w.list,
			&w.ui_text,
			app.theme,
			size.x,
			size.y,
			w.scale,
			content.title,
			content.body,
			content.label,
			content.note,
		)
		opacity, rise := ui.presence_fade(pc.confirm.presence, 4 * w.scale)
		ui.fade_draw(&w.list, layers, rects, glyph_count, opacity, rise)
		if result != .Ok {return frame, result}
	}
	if w.rename_open {
		if result := rename_draw(app, w); result != .Ok {return frame, result}
	}
	if w.tab_menu.open {
		if result := tab_menu_draw(app, w); result != .Ok {return frame, result}
	}
	if workspace_picker_active(&w.workspace_picker) {
		if result := workspace_picker_draw(app, w); result != .Ok {return frame, result}
	}
	return frame, ui.notices_draw(
		&app.notices,
		&w.list,
		&w.ui_text,
		app.theme,
		size.x,
		size.y,
		w.scale,
	)
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
	radius := f32(app.settings.pane.corner_radius) * w.scale
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
		   cached.style != style {
			cached.valid = false
			render.draw_list_reset(&cached.cache)
			if render.push_layer(&cached.cache, clip, radius) != .None {return {}, .Ok}
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
			cached.frame, cached.style = frame, style
			cached.generation, cached.atlas_generation =
				generation, render.atlas_generation(app.device)
			cached.valid = true
			cached.builds += 1
		}
		if render.append_list(&w.list, &cached.cache) !=
		   .None {log.error("copying a pane frame failed")}
		return cached.frame, .Ok
	}
	return {}, .Ok
}
