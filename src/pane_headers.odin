package main

import "aio:commands"
import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:strings"

Pane_Header_Metadata :: struct {
	executable, title, directory: string,
	command, launch_directory:    string,
	icon:                         string, // Borrowed static shell badge.
}

pane_header_destroy :: proc(header: ^Pane_Header_Metadata) {
	delete(header.executable)
	delete(header.title)
	delete(header.directory)
	delete(header.command)
	delete(header.launch_directory)
	header^ = {}
}

@(private)
header_clone :: proc(text: string) -> string {
	copy, err := strings.clone(text)
	if err != nil {log.error("caching pane header text failed")}
	return copy
}

pane_header_launch :: proc(header: ^Pane_Header_Metadata, config: term.Config) {
	pane_header_destroy(header)
	header.executable = header_clone(settings.shell_executable(config.command_line))
	header.command, header.launch_directory =
		header_clone(config.command_line), header_clone(config.working_directory)
	header.icon = settings.shell_icon(header.executable, "")
}

pane_header_refresh :: proc(entry: ^Session_Entry) {
	header := &entry.header
	title := term.title(entry.session)
	defer delete(title)
	directory := term.working_directory(entry.session)
	defer delete(directory)
	label, err := settings.directory_label(directory)
	if err != nil {log.error("caching the reported pane directory failed")}
	delete(header.title)
	delete(header.directory)
	header.title, header.directory = settings.display_title(title), label
}

pane_header_title :: proc(header: ^Pane_Header_Metadata) -> string {
	return header.title != "" ? header.title : header.executable
}

@(private)
SETTINGS_HEADER_TITLE :: "Settings"
@(private)
SETTINGS_HEADER_ICON :: "⚙"

pane_header_draw :: proc(
	app: ^App,
	w: ^Window,
	pane: layout.Pane_Rect,
	entry: ^Session_Entry,
) -> glyphs.Result {
	controls: [4]ui.Control_Motion
	for view in w.views {if view.content == pane.content {controls = view.header_controls; break}}
	r := pane.rect
	if w.header_height == 0 {
		if !w.split_overlay {return .Ok}
		return ui.split_overlay_draw(
			&w.list,
			&w.ui_text,
			app.theme,
			ui.split_overlay_layout({r.x, r.y, r.width, r.height}, w.scale),
			controls,
			w.scale,
			w.pointer,
		)
	}
	icon_atlas: render.Rect
	if entry != nil {
		value, result := shell_icon_atlas(app)
		if result != .Ok {return result}
		icon_atlas = value
	}
	title, directory, icon := SETTINGS_HEADER_TITLE, "", SETTINGS_HEADER_ICON
	if entry != nil {
		// Only a directory the shell reported (OSC 7) is shown; the launch directory may be stale.
		title = entry.name != "" ? entry.name : pane_header_title(&entry.header)
		directory, icon = entry.header.directory, entry.header.icon
	}
	badge_hovered := false
	if entry != nil {
		layout := ui.header_layout({r.x, r.y, r.width, r.height}, w.scale, pane.node == w.tree.focus)
		badge_hovered =
			w.pointer.x >= layout.badge.x - 3 * w.scale &&
			w.pointer.x < layout.badge.x + layout.badge.width + 9 * w.scale &&
			w.pointer.y >= layout.badge.y - 3 * w.scale &&
			w.pointer.y < layout.badge.y + layout.badge.height + 3 * w.scale
	}
	status: ui.Status_Mark
	status_text: string
	if entry != nil && app.settings.status.pane_headers {
		summary: Status_Summary
		status_summary_add(app, &summary, entry)
		if summary.found {
			status = status_mark(summary.top)
			buffer: [8]u8
			headline := ui.status_headline(status, buffer[:])
			status_text = strings.clone(headline, context.temp_allocator)
			if summary.top.message != "" {
				status_text = fmt.tprintf("%s · %s", headline, summary.top.message)
				if status.glyph == .Working && status.progress < 0 {status_text = summary.top.message}
			}
		}
	}
	return ui.header_draw(
		&w.list,
		&w.ui_text,
		app.theme,
		{r.x, r.y, r.width, r.height},
		app.theme.pane,
		f32(app.settings.pane.corner_radius) * w.scale,
		w.scale,
		title,
		directory,
		icon,
		pane.node == w.tree.focus,
		controls,
		w.tree.zoomed,
		icon_atlas,
		badge_hovered,
		w.pointer,
		status,
		status_text,
		status_phase(app, w, status),
	)
}

pane_header_hit :: proc(w: ^Window, x, y: f32) -> (layout.Pane_Rect, ui.Header_Action, bool) {
	if w.header_height == 0 && !w.split_overlay {return {}, .None, false}
	for pane in w.panes {
		r := pane.rect
		area := render.Rect{r.x, r.y, r.width, r.height}
		l := ui.header_layout(area, w.scale, pane.node == w.tree.focus)
		if w.header_height == 0 {l = ui.split_overlay_layout(area, w.scale)}
		if ui.header_contains(l, x, y) {return pane, ui.header_hit_test(l, x, y), true}
	}
	return {}, .None, false
}

pane_header_cancel :: proc(w: ^Window) {
	for &view in w.views {
		view.header_hover = .None
		ui.armed_cancel(&view.header_armed)
	}
}

// The terminal must not receive either half of a header click, including a release outside it.
pane_header_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	pane, action, hit := pane_header_hit(w, f32(e.x), f32(e.y))
	if !e.pressed && e.button in w.header_buttons {
		w.header_buttons -= {e.button}
		if e.button == .Left && w.pane_drag.active {
			pane_drag_move(app, w, f32(e.x), f32(e.y), .Shift in e.modifiers)
			pane_header_cancel(w)
			_ = pane_drag_release(app, w)
			return true
		}
		if e.button == .Left {_ = pane_drag_release(app, w)}
		chosen: ui.Header_Action
		for &view in w.views {
			if e.button == .Left {
				fired, ok := ui.armed_release(
					&view.header_armed,
					hit && view.content == pane.content ? action : ui.Header_Action.None,
				)
				// A view armed with no action must not clear another view's choice.
				if ok && fired != .None {chosen = fired}
			}
		}
		if chosen != .None {
			names := [ui.Header_Action]string {
				.None        = "",
				.Split_Right = "pane.split_right",
				.Split_Down  = "pane.split_down",
				.Zoom        = "pane.zoom",
				.Close       = "pane.close",
				.Badge       = "",
			}
			if command := commands.find(&app.registry, names[chosen]);
			   command != nil {run_action(app, w, Action(command.id))}
		}
		return true
	}
	if !hit || w.selecting {return false}
	if e.pressed {
		w.header_buttons += {e.button}
		if e.button == .Left {
			pane_focus(app, w, pane.node)
			if action == .Badge {
				if workspace_session_for_content(app, pane.content) == nil {return true}
				profile_menu_open_pane(
					app,
					w,
					pane.node,
					pane.rect.x + 8 * w.scale,
					pane.rect.y + ui.HEADER_HEIGHT * w.scale,
				)
				return true
			}
			for &view in w.views {
				if view.content == pane.content {ui.armed_press(&view.header_armed, action)}
			}
			if action == .None {pane_drag_press(app, w, pane.node, f32(e.x), f32(e.y))}
		}
	}
	return true
}

pane_header_pointer :: proc(w: ^Window, x, y: f32, enabled: bool) -> bool {
	pane, action, hit := pane_header_hit(w, x, y)
	for &view in w.views {
		hover := enabled && hit && view.content == pane.content ? action : ui.Header_Action.None
		if hover != view.header_hover {view.header_hover = hover; w.dirty = true}
	}
	return enabled && hit
}

// Shows a single pane's split controls while the pointer is within the top band of its card.
split_overlay_update :: proc(w: ^Window, x, y: f32, enabled: bool) {
	shown := false
	if enabled && w.header_height == 0 && len(w.panes) == 1 {
		r := w.panes[0].rect
		shown = x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + 40 * w.scale
	}
	if shown == w.split_overlay {return}
	w.split_overlay = shown
	pane_header_cancel(w)
	w.dirty = true
}
