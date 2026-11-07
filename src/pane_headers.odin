package main

import "aio:input"
import "aio:layout"
import "aio:localpath"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

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
	header.icon = settings.shell_badge(config.command_line)
}

pane_header_refresh :: proc(entry: ^Session_Entry) {
	header := &entry.header
	title := term.title(entry.session)
	defer delete(title)
	directory := term.working_directory(entry.session)
	defer delete(directory)
	label, err := localpath.directory_label(directory)
	if err != nil {log.error("caching the reported pane directory failed")}
	delete(header.title)
	delete(header.directory)
	header.title, header.directory = display_title(title), label
}

// A program-supplied or user-typed title as shown: control characters dropped, capped at 1024
// bytes on a complete UTF-8 rune.
display_title :: proc(raw: string, allocator := context.allocator) -> string {
	bytes := make([dynamic]u8, 0, min(1024, len(raw)), allocator)
	for r in raw {
		if r < ' ' || r >= 0x7f && r <= 0x9f {continue}
		encoded, count := utf8.encode_rune(r)
		if len(bytes) + count > 1024 {break}
		if _, err := append(&bytes, ..encoded[:count]); err != nil {break}
	}
	return string(bytes[:])
}

pane_header_title :: proc(header: ^Pane_Header_Metadata) -> string {
	return header.title != "" ? header.title : header.executable
}

pane_header_draw :: proc(
	app: ^App,
	w: ^Window,
	pane: layout.Pane_Rect,
	entry: ^Session_Entry,
) -> render.Build_Status {
	controls: [ui.HEADER_BUTTONS]ui.Control_Motion
	if view := pane_view(w, pane.content); view != nil {controls = view.header_controls}
	r := pane.rect
	documents := pane_header_documents(w, pane)
	if w.header_height == 0 && !pane.floating {
		if !w.split_overlay && !documents.open {return .Ok}
		return ui.split_overlay_draw(
			&w.list,
			&w.ui_text,
			app.theme,
			ui.split_overlay_layout({r.x, r.y, r.width, r.height}, w.scale, documents.shown),
			controls,
			w.scale,
			w.pointer,
			documents,
		)
	}
	icon_atlas: render.Rect
	title, directory := content_title(app, pane.content), content_directory(app, pane.content)
	icon := content_icon(pane.content.kind)
	if entry != nil {
		// Only a directory the shell reported (OSC 7) is shown; the launch directory may be stale.
		title = session_display_title(entry)
		directory = entry.header.directory
		result: render.Build_Status
		icon, icon_atlas, result = pane_icon(app, entry, ui.ICON_BUTTON * w.scale)
		if result != .Ok {return result}
	}
	badge_hovered := false
	if entry != nil {
		layout := ui.header_layout({r.x, r.y, r.width, r.height}, w.scale, documents.shown, pane.floating)
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
			status = status_presentation(summary.top).mark
			buffer: [8]u8
			headline := status_headline(status, buffer[:])
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
		window_pane_radius(app, w),
		w.scale,
		title,
		directory,
		icon,
		pane_shows_focus(w, pane),
		controls,
		pane_view_current(w) == .Zoom,
		w.pane_fill == .Content,
		window_linked(w),
		icon_atlas,
		badge_hovered,
		w.pointer,
		status,
		status_text,
		status_phase(app, w, status),
		content_icon = pane.content.kind == .Markdown ? .Markdown : .None,
		documents = documents,
		floating = pane.floating,
	)
}

@(private)
pane_header_documents :: proc(w: ^Window, pane: layout.Pane_Rect) -> ui.Header_Documents {
	if !CONTENT_POLICY[pane.content.kind].documents {return {}}
	return {shown = true, open = document_menu_shown_for(w, pane.content)}
}

// The header under the point, on the topmost pane there: a floating pane covers the headers below it.
pane_header_hit :: proc(w: ^Window, x, y: f32) -> (layout.Pane_Rect, ui.Header_Action, bool) {
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found || (!pane.floating && w.header_height == 0 && !w.split_overlay) {return {}, .None, false}
	l := pane_header_layout(w, pane)
	if ui.header_contains(l, x, y) {return pane, ui.header_hit_test(l, x, y), true}
	return {}, .None, false
}

pane_header_layout :: proc(w: ^Window, pane: layout.Pane_Rect) -> ui.Header_Layout {
	r := pane.rect
	area := render.Rect{r.x, r.y, r.width, r.height}
	documents := CONTENT_POLICY[pane.content.kind].documents
	if w.header_height == 0 && !pane.floating {return ui.split_overlay_layout(area, w.scale, documents)}
	return ui.header_layout(area, w.scale, documents, pane.floating)
}

// Where a pane's document menu hangs from: under its Documents button, or inside its corner without one.
// A split pane with headers off shows no controls, so its menu sits in the corner the header would use.
pane_header_document_anchor :: proc(w: ^Window, pane: layout.Pane_Rect) -> [2]f32 {
	r := pane.rect
	s := w.scale
	width := ui.MENU_WIDTH * s
	if w.header_height == 0 && !pane.floating && !pane_single_tiled(w) {
		return {r.x + r.width - width - ui.SPACE_2 * s, r.y + ui.SPACE_2 * s}
	}
	button := pane_header_layout(w, pane).buttons[int(ui.Header_Action.Documents) - 1]
	if button.width == 0 {
		return {r.x + r.width - width - ui.SPACE_2 * s, r.y + ui.HEADER_HEIGHT * s + ui.SPACE_1 * s}
	}
	return {button.x + button.width - width, button.y + button.height + ui.SPACE_1 * s}
}

// One tiled pane alone, which shows split controls while headers are off. Floating panes follow
// the tiled ones.
@(private)
pane_single_tiled :: proc(w: ^Window) -> bool {
	return len(w.panes) > 0 && !w.panes[0].floating && (len(w.panes) == 1 || w.panes[1].floating)
}

pane_header_cancel :: proc(w: ^Window) {
	for &view in w.views {
		view.header_hover = .None
		ui.armed_cancel(&view.header_armed)
	}
}

// Header buttons animate only while some header shows: a header row, a single pane's split controls or
// a float's panes.
@(private = "file")
pane_header_controls_shown :: proc(w: ^Window) -> bool {
	return w.header_height > 0 || w.split_overlay || window_floats_shown(w)
}

// Advances every header button's hover and press; true when the window must draw again.
pane_header_controls_animate :: proc(app: ^App, w: ^Window, now: time.Tick) -> bool {
	if !pane_header_controls_shown(w) {return false}
	changed := false
	for &pane in w.views {
		for &control, i in pane.header_controls {
			action := ui.Header_Action(i + 1)
			hovered, armed := pane.header_hover == action, ui.armed_is(pane.header_armed, action)
			changed = ui.control_update(&control, hovered, armed, app.animations, now) || changed
		}
	}
	return changed
}

pane_header_controls_animating :: proc(w: ^Window) -> bool {
	if !pane_header_controls_shown(w) {return false}
	for pane in w.views {for control in pane.header_controls {if ui.control_active(control) {return true}}}
	return false
}

// The terminal must not receive either half of a header click: the header swallows the press, and
// pane_header_release finishes it wherever it is released.
pane_header_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	pane, action, hit := pane_header_hit(w, f32(e.x), f32(e.y))
	if !hit || selection_active(w) {return}
	gesture_swallow(w, e.button, .Pane_Header)
	if e.button != .Left {return}
	pane_focus(app, w, pane.node)
	if action == .Badge {
		if workspace_session_for_content(app, pane.content) == nil {return}
		x, y := pane.rect.x + 8 * w.scale, pane.rect.y + ui.HEADER_HEIGHT * w.scale
		profile_menu_open_pane(app, w, pane.node, x, y)
		return
	}
	if action == .Documents {
		document_menu_open_pane(app, w, pane)
		return
	}
	if view := pane_view(w, pane.content); view != nil {ui.armed_press(&view.header_armed, action)}
	// Every pane header rearranges panes; a float moves by its own float header.
	if action == .None {pane_drag_press(app, w, pane.node, f32(e.x), f32(e.y))}
}

pane_header_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	pane, action, hit := pane_header_hit(w, f32(e.x), f32(e.y))
	if e.button == .Left && pane_drag_active(w) {
		pane_drag_move(app, w, f32(e.x), f32(e.y), .Shift in e.modifiers)
		pane_header_cancel(w)
		_ = pane_drag_release(app, w)
		return
	}
	if e.button == .Left {
		_ = pane_drag_release(app, w)
	}
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
	if chosen == .None {return}
	if action, runs := pane_header_command(chosen); runs {run_action(app, w, action)}
}

// The command a header button runs. Documents opens its menu on press, and the badge runs none.
@(private)
pane_header_command :: proc(action: ui.Header_Action) -> (Action, bool) {
	switch action {
	case .Split_Right:
		return .Split_Right, true
	case .Split_Down:
		return .Split_Down, true
	case .Zoom:
		return .Zoom_Pane, true
	case .Fill_Window:
		return .Fill_Window_Pane, true
	case .Linked_Window:
		return .Linked_Window, true
	case .Dock:
		return .Float_Pane, true
	case .Close:
		return .Close_Pane, true
	case .None, .Documents, .Badge:
	}
	return {}, false
}

// What a header button's tooltip says it does, which can depend on the window's current state.
pane_header_tooltip :: proc(w: ^Window, action: ui.Header_Action) -> string {
	switch action {
	case .Documents:
		return "Documents"
	case .Split_Right:
		return "Split right"
	case .Split_Down:
		return "Split down"
	case .Zoom:
		return "Zoom"
	case .Fill_Window:
		return w.pane_fill == .Content ? "Exit fill window" : "Fill window"
	case .Linked_Window:
		return window_linked(w) ? "Return pane to tab" : "Move pane to linked window"
	case .Dock:
		return "Move to a float"
	case .Close:
		return "Close pane"
	case .None, .Badge:
	}
	return ""
}

pane_header_pointer :: proc(w: ^Window, x, y: f32, enabled: bool) -> (bool, ui.Header_Action) {
	pane, action, hit := pane_header_hit(w, x, y)
	for &view in w.views {
		hover := enabled && hit && view.content == pane.content ? action : ui.Header_Action.None
		if hover != view.header_hover {view.header_hover = hover; w.dirty = true}
	}
	return enabled && hit, enabled && hit ? action : .None
}

// Shows a single pane's split controls while the pointer is within the top band of its card.
split_overlay_update :: proc(w: ^Window, x, y: f32, enabled: bool) {
	shown := false
	single := pane_single_tiled(w)
	if enabled && w.header_height == 0 && single {
		r := w.panes[0].rect
		top, found := layout.hit_test(w.panes[:], x, y)
		shown = found && !top.floating && x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + 40 * w.scale
	}
	if shown == w.split_overlay {return}
	w.split_overlay = shown
	pane_header_cancel(w)
	w.dirty = true
}
