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

Pane_Header_Metadata :: struct {
	executable, title, directory: string,
	command, launch_directory:    string,
	// The started process's image path, whose own icon stands for the shell; empty when nothing
	// started.
	executable_path:              string,
	icon:                         string, // Borrowed static shell badge.
}

pane_header_destroy :: proc(header: ^Pane_Header_Metadata) {
	delete(header.executable)
	delete(header.title)
	delete(header.directory)
	delete(header.command)
	delete(header.launch_directory)
	delete(header.executable_path)
	header^ = {}
}

@(private)
header_clone :: proc(text: string) -> string {
	copy, err := strings.clone(text)
	if err != nil {log.error("caching pane header text failed")}
	return copy
}

pane_header_launch :: proc(header: ^Pane_Header_Metadata, config: term.Config, session: ^term.Session) {
	pane_header_destroy(header)
	header.executable = header_clone(settings.shell_executable(config.command_line))
	header.command, header.launch_directory =
		header_clone(config.command_line), header_clone(config.working_directory)
	header.icon = settings.shell_badge(config.command_line)
	header.executable_path = term.process_image(session)
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
	return printable_text(raw, 1024, allocator)
}

pane_header_title :: proc(header: ^Pane_Header_Metadata) -> string {
	return header.title != "" ? header.title : header.executable
}

// The pane header's buttons, left to right, in groups by what they do: Documents; the splits; the views that
// make the pane bigger; the moves that take it out of the tiling; Close. A pane in a float keeps its split
// controls; minimizing, docking and moving belong to the float header. Tiled panes add their view controls,
// Float and Linked window.
Pane_Header_Button :: enum u8 {
	Documents,
	Split_Right,
	Split_Down,
	Zoom,
	Fill_Window,
	Dock,
	Linked_Window,
	Close,
}

// What a point on a pane header does: a button, the shell badge's menu, or nil for the title, which
// focuses and drags the pane.
Pane_Header_Target :: ui.Header_Target(Pane_Header_Button)

Pane_Header_Layout :: ui.Header_Layout(Pane_Header_Button)

@(private = "file")
PANE_HEADER_TILED :: bit_set[Pane_Header_Button] {
	.Documents, .Split_Right, .Split_Down, .Zoom, .Fill_Window, .Linked_Window, .Dock, .Close,
}
@(private = "file")
PANE_HEADER_FLOATING :: bit_set[Pane_Header_Button]{.Documents, .Split_Right, .Split_Down, .Close}
@(private = "file")
PANE_HEADER_OVERLAY :: bit_set[Pane_Header_Button]{.Documents, .Split_Right, .Split_Down}
// The last button of each group, which a divider sets apart from the next group.
@(private = "file")
PANE_HEADER_GROUP_ENDS :: bit_set[Pane_Header_Button]{.Documents, .Split_Down, .Fill_Window, .Linked_Window}

// The order buttons give way in a narrow header: the Documents button first, then the tiled view
// controls, so splitting, floating and closing stay longest.
@(private = "file", rodata)
PANE_HEADER_DROP_ORDER := [?]Pane_Header_Button {
	.Documents, .Fill_Window, .Linked_Window, .Zoom, .Split_Down, .Split_Right, .Dock, .Close,
}

// Whether a pane shows a header row. A tiled pane without one carries its split controls in the split
// overlay, which shows while the pointer is near its top or its document menu is open.
pane_header_row :: proc(w: ^Window, pane: layout.Pane_Rect) -> bool {
	return pane.floating || w.header_height > 0
}

// The header row or split overlay of a pane, which drawing and hit testing share. Every pane can split
// and close; the view controls and Float apply only to the tiled layout, and a pane that takes no pins
// has no Documents button.
pane_header_layout :: proc(w: ^Window, pane: layout.Pane_Rect) -> Pane_Header_Layout {
	r := pane.rect
	area := render.Rect{r.x, r.y, r.width, r.height}
	row := pane_header_row(w, pane)
	shown := PANE_HEADER_TILED
	if !row {
		shown = PANE_HEADER_OVERLAY
	} else if pane.floating {
		shown = PANE_HEADER_FLOATING
	}
	if !CONTENT_POLICY[pane.content.kind].documents {shown -= {.Documents}}
	if !row {return ui.split_overlay_layout(area, w.scale, shown, PANE_HEADER_GROUP_ENDS)}
	return ui.header_layout(area, w.scale, shown, PANE_HEADER_GROUP_ENDS, PANE_HEADER_DROP_ORDER[:])
}

// The icon a header button shows, which can follow the window's state.
@(private = "file")
pane_header_icon :: proc(w: ^Window, button: Pane_Header_Button) -> ui.Icon {
	switch button {
	case .Documents:
		return .Document
	case .Split_Right:
		return .Split_Right
	case .Split_Down:
		return .Split_Down
	case .Zoom:
		return pane_view_current(w) == .Zoom ? .Collapse : .Expand
	case .Fill_Window:
		return w.pane_fill == .Content ? .Restore : .Zoom
	case .Linked_Window:
		return window_linked(w) ? .Window_In : .Window_Out
	case .Dock:
		return .Float_Pane
	case .Close:
		return .Close
	}
	return .None
}

// The command a header button runs. Documents opens its menu on press instead.
@(private)
pane_header_command :: proc(button: Pane_Header_Button) -> (Action, bool) {
	switch button {
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
	case .Documents:
	}
	return {}, false
}

// What a header button's tooltip says it does, which can depend on the window's current state. The badge
// and title have none.
pane_header_tooltip :: proc(w: ^Window, target: Pane_Header_Target) -> string {
	button, ok := target.(Pane_Header_Button)
	if !ok {return ""}
	switch button {
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
	}
	return ""
}

pane_header_draw :: proc(
	app: ^App,
	w: ^Window,
	pane: layout.Pane_Rect,
	entry: ^Session_Entry,
) -> render.Build_Status {
	l := pane_header_layout(w, pane)
	open := CONTENT_POLICY[pane.content.kind].documents && document_menu_shown_for(w, pane.content)
	buttons: [Pane_Header_Button]ui.Header_Button
	view := pane_view(w, pane.content)
	for &face, button in buttons {
		face.icon = pane_header_icon(w, button)
		if view == nil {continue}
		face.motion = view.header_controls[button]
		face.disabled = view.header_refused[button] != .None
	}
	buttons[.Documents].selected = open
	buttons[.Close].danger = true
	if !pane_header_row(w, pane) {
		if !w.split_overlay && !open {return .Ok}
		return ui.split_overlay_draw(&w.list, app.theme, l, buttons, w.scale, w.pointer)
	}
	if !pane_header_buttons_shown(w, pane, open) {l.buttons, l.dividers = {}, {}}
	// Only a directory the shell reported (OSC 7) is shown; the launch directory may be stale.
	title := content_pane_title(app, entry, pane.content)
	directory := entry != nil ? entry.header.directory : content_directory(app, pane.content)
	badge, result := content_badge(app, entry, pane.content.kind, ui.ICON_BUTTON * w.scale)
	if result != .Ok {return result}
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
	r := pane.rect
	return ui.header_draw(
		&w.list,
		&w.ui_text,
		app.theme,
		{r.x, r.y, r.width, r.height},
		l,
		buttons,
		app.theme.pane,
		window_pane_radius(app, w),
		w.scale,
		title,
		directory,
		badge.glyph,
		pane_shows_focus(w, pane),
		badge.atlas,
		entry != nil && render.rect_contains(l.badge_target, w.pointer.x, w.pointer.y),
		w.pointer,
		status,
		status_text,
		status_phase(app, w, status),
		badge.icon,
	)
}

// A header row shows its buttons on the focused pane, the pane under the pointer and a pane whose document
// menu is open. The others keep the buttons' space, so their titles stay put when the buttons appear.
@(private = "file")
pane_header_buttons_shown :: proc(w: ^Window, pane: layout.Pane_Rect, menu_open: bool) -> bool {
	hovered, found := w.header_pane.?
	return menu_open || pane_shows_focus(w, pane) || (found && hovered == pane.content)
}

// The surfaces that lie on a pane's card, so the pointer over one is over that pane.
@(private = "file")
PANE_HOVER_SURFACES :: bit_set[Pointer_Target] {
	.Find, .Pane_Header, .Scrollbar, .Settings_Page, .Markdown_Page, .Content,
}

// Follows the pane under the pointer, whose header shows its buttons.
@(private = "file")
header_pane_update :: proc(w: ^Window, owner: Pointer_Target, x, y: f32) {
	hovered: Maybe(layout.Content)
	if owner in PANE_HOVER_SURFACES {
		if pane, found := layout.hit_test(w.panes[:], x, y); found {hovered = pane.content}
	}
	if hovered == w.header_pane {return}
	w.header_pane = hovered
	w.dirty = true
}

// The header under the point, on the topmost pane there: a floating pane covers the headers below it.
pane_header_hit :: proc(w: ^Window, x, y: f32) -> (layout.Pane_Rect, Pane_Header_Target, bool) {
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found || (!pane_header_row(w, pane) && !w.split_overlay) {return {}, nil, false}
	l := pane_header_layout(w, pane)
	if ui.header_contains(l, x, y) {return pane, ui.header_hit_test(l, x, y), true}
	return {}, nil, false
}

// Where a pane's document menu hangs from: under its Documents button, or inside its corner without one.
// A split pane with headers off shows no controls, so its menu sits in the corner the header would use.
pane_header_document_anchor :: proc(w: ^Window, pane: layout.Pane_Rect) -> [2]f32 {
	r := pane.rect
	s := w.scale
	width := ui.MENU_WIDTH * s
	if !pane_header_row(w, pane) && !pane_single_tiled(w) {
		return {r.x + r.width - width - ui.SPACE_2 * s, r.y + ui.SPACE_2 * s}
	}
	button := pane_header_layout(w, pane).buttons[.Documents]
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
		view.header_hover = nil
		ui.armed_cancel(&view.header_armed)
	}
}

// A relayout moves every header, so each drops its hover and press and its buttons restart at rest.
pane_header_relayout_reset :: proc(w: ^Window) {
	pane_header_cancel(w)
	for &view in w.views {view.header_controls = {}}
}

// Header buttons animate only while some header shows: a header row, a single pane's split controls or
// a float's panes.
@(private = "file")
pane_header_controls_shown :: proc(w: ^Window) -> bool {
	return w.header_height > 0 || w.split_overlay || window_floats_shown(w)
}

// Advances every header button's hover and press; true when the window must draw again.
pane_header_controls_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	if !pane_header_controls_shown(w) {return false}
	changed := false
	for &pane in w.views {
		for &control, button in pane.header_controls {
			hovered, armed := pane.header_hover == button, ui.armed_is(pane.header_armed, button)
			changed = ui.control_update(&control, hovered, armed, app.animations, frame) || changed
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
	pane, target, hit := pane_header_hit(w, f32(e.x), f32(e.y))
	if !hit || selection_active(w) {return}
	gesture_swallow(w, e.button, .Pane_Header)
	if e.button != .Left {return}
	pane_focus(app, w, pane.node)
	if _, badge := target.(ui.Header_Badge); badge {
		if workspace_session_for_content(app, pane.content) == nil {return}
		profile_menu_open_pane(app, w, pane)
		return
	}
	if target == Pane_Header_Button.Documents {
		document_menu_open_pane(app, w, pane)
		return
	}
	// A refused button takes the press and does nothing; its tooltip says why.
	if button, is_button := target.(Pane_Header_Button);
	   is_button && pane_header_refused(w, pane, button) != .None {return}
	if view := pane_view(w, pane.content); view != nil {ui.armed_press(&view.header_armed, target)}
	// Every pane header rearranges panes; a float moves by its own float header.
	if target == nil {pane_drag_press(app, w, pane.node, f32(e.x), f32(e.y))}
}

pane_header_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	pane, target, hit := pane_header_hit(w, f32(e.x), f32(e.y))
	if e.button == .Left && pane_drag_active(w) {
		pane_drag_move(app, w, f32(e.x), f32(e.y), .Shift in e.modifiers)
		pane_header_cancel(w)
		_ = pane_drag_release(app, w)
		return
	}
	if e.button == .Left {
		_ = pane_drag_release(app, w)
	}
	chosen: Pane_Header_Target
	for &view in w.views {
		if e.button == .Left {
			released: Pane_Header_Target
			if hit && view.content == pane.content {released = target}
			fired, ok := ui.armed_release(&view.header_armed, released)
			// A view armed with no target must not clear another view's choice.
			if ok && fired != nil {chosen = fired}
		}
	}
	button, chose := chosen.(Pane_Header_Button)
	if !chose {return}
	if action, runs := pane_header_command(button); runs {run_action(app, w, action)}
}

// Follows the hovered header button; a refused button takes no hover, so it stays flat under the arrow.
pane_header_pointer :: proc(w: ^Window, x, y: f32, enabled: bool) -> (bool, Pane_Header_Target) {
	pane, target, hit := pane_header_hit(w, x, y)
	if button, is_button := target.(Pane_Header_Button);
	   is_button && hit && pane_header_refused(w, pane, button) != .None {target = nil}
	for &view in w.views {
		hover: Pane_Header_Target
		if enabled && hit && view.content == pane.content {hover = target}
		if hover != view.header_hover {view.header_hover = hover; w.dirty = true}
	}
	if !enabled || !hit {return false, nil}
	return true, target
}

// Shows a single pane's split controls while the pointer is within the top band of its card.
split_overlay_update :: proc(w: ^Window, x, y: f32, enabled: bool) {
	shown := false
	single := pane_single_tiled(w)
	if enabled && single && !pane_header_row(w, w.panes[0]) {
		r := w.panes[0].rect
		top, found := layout.hit_test(w.panes[:], x, y)
		shown = found && !top.floating && x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + 40 * w.scale
	}
	if shown == w.split_overlay {return}
	w.split_overlay = shown
	pane_header_cancel(w)
	w.dirty = true
}

// Pane header pointer surface: pane headers, and a single pane's split controls, which show while the
// pointer is in the pane's top band and no surface above the pane covers it.

@(private)
header_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	_, _, hit := pane_header_hit(w, x, y)
	return hit
}

@(private)
header_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	header_pane_update(w, owner, x, y)
	in_pane := pointer_surfaces[owner].in_pane
	split_overlay_update(w, x, y, in_pane && !selection_active(w))
	over, target := pane_header_pointer(w, x, y, owner == .Pane_Header && !selection_active(w))
	if owner != .Pane_Header {return}
	pointer_set(app, w, over && target != nil && !gesture_swallowing(w) ? .Hand : .Arrow)
}

@(private)
header_tooltip :: proc(_: ^App, w: ^Window, x, y: f32) -> string {
	_, target, _ := pane_header_hit(w, x, y)
	return pane_header_tooltip(w, target)
}

@(private)
header_tooltip_card :: proc(app: ^App, w: ^Window, x, y: f32) -> Tooltip_Card {
	pane, target, hit := pane_header_hit(w, x, y)
	button, is_button := target.(Pane_Header_Button)
	if !hit || !is_button {return {}}
	return pane_header_card(app, w, pane, button)
}

// The header swallows its presses, so it also finishes a release that lands anywhere.
@(private)
header_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if palette_active(app, w) {pane_header_cancel(w)}
	pane_header_release(app, w, e)
	return true
}

@(private)
header_cancel :: proc(_: ^App, w: ^Window) {
	pane_header_cancel(w)
	w.split_overlay = false
}

// The pointer left the window, so no pane is under it. Capture loss keeps the hovered pane, which stays
// under the pointer.
@(private)
header_leave :: proc(app: ^App, w: ^Window) {
	header_cancel(app, w)
	w.header_pane = nil
}

// A pane drag follows the pointer once it has started, or while no modal surface is under it.
@(private)
pane_drag_held :: proc(
	app: ^App,
	w: ^Window,
	under: Pointer_Target,
	e: input.Mouse_Move_Event,
) -> Pointer_Held {
	if _, pane := pane_drag_grab(w); !pane {return .Free}
	if drag_active(w) == nil && pointer_modal(under) {return .Free}
	if .Left not_in e.buttons {pane_drag_cancel(app, w); return .Ended}
	if !pane_drag_move(app, w, f32(e.x), f32(e.y), .Shift in e.modifiers) {return .Free}
	pointer_set(app, w, .Resize_All)
	return .Taken
}
