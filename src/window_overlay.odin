package main

import "aio:layout"
import "aio:ui"

// The surface a window shows over its content and takes input with, holding what only that surface
// needs. overlay_open and overlay_close are its only writers; each surface's own file changes the
// payload of its variant while it shows.
//
// The palette, the workspace picker and confirmations also take a window's input, but they keep their
// own state: the palette is one app-wide surface (palette_owner.odin), and the picker's modes and the
// confirmation subjects belong to their own files. Holding them here as well would repeat that state,
// so overlay_kind folds them in, and overlay_open and window_overlays_cancel close them, which is what
// keeps every surface exclusive.
Window_Overlay :: union {
	Overlay_Rename,
	Overlay_Chip_Name,
	Overlay_Tab_Menu,
	Overlay_Divider_Menu,
	Overlay_Profile_Menu,
	Overlay_Document_Menu,
}

// A tab or pane renames in a dialog; the text is w.rename.
Overlay_Rename :: struct {
	target: Rename_Target,
}

// The window's workspace names in place, in its chip; the text is w.rename.
Overlay_Chip_Name :: struct {
	workspace: u32,
	// The last save found the name in use. Editing the field clears it.
	error:     bool,
}

// The right-clicked tab. The menu acts on it, or on its marked group, without activating it.
Overlay_Tab_Menu :: struct {
	tab: u32,
}

// A dock edge's menu, which offers to keep the edge's current size. Its rows are w.divider_menu.
Overlay_Divider_Menu :: struct {
	node: layout.Node_Id,
}

Overlay_Profile_Menu :: struct {
	mode: Profile_Menu_Mode,
}

Overlay_Document_Menu :: struct {
	// The pane whose documents the menu shows and adds to.
	content: layout.Content,
	mode:    Document_Menu_Mode,
}

// Which surface has the window's input. When more than one claims it, which only commands driven from
// outside can arrange, the order here decides, as the order of on_key's checks did.
Overlay_Kind :: enum u8 {
	None,
	Workspace_Picker,
	Rename,
	Chip_Name,
	Tab_Menu,
	Divider_Menu,
	Profile_Menu,
	Document_Menu,
	Confirmation,
	Palette,
}

overlay_kind :: proc(app: ^App, w: ^Window) -> Overlay_Kind {
	if workspace_picker_active(&w.workspace_picker) {return .Workspace_Picker}
	switch _ in w.overlay {
	case Overlay_Rename: return .Rename
	case Overlay_Chip_Name: return .Chip_Name
	case Overlay_Tab_Menu: return .Tab_Menu
	case Overlay_Divider_Menu: return .Divider_Menu
	case Overlay_Profile_Menu: return .Profile_Menu
	case Overlay_Document_Menu: return .Document_Menu
	}
	if confirmation_current(w) != nil {return .Confirmation}
	if palette_active(app, w) {return .Palette}
	return .None
}

// How the window's surface ends when something other than its own controls closes it.
Overlay_Exit :: enum u8 {
	Cancel,
	// The window lost focus or a press landed elsewhere. The chip's name field is not modal, so it keeps
	// the typed name when no other workspace uses it; everything else cancels.
	Leave,
}

// Shows `next` in place of whatever had the window's input. The previous window surface ends with its
// cancel exit, a palette owned here fades out, and the picker and an open confirmation close, so no two
// surfaces take the window's input together. Callers that cancel the pointer gesture do so first.
// `reopening` is a confirmation its caller rewrites in place: cancelling it would undo what the caller
// prepared for the new question, such as the tabs a close subset just marked.
overlay_open :: proc(app: ^App, w: ^Window, next: Window_Overlay, reopening: ^ui.Confirm = nil) {
	overlay_close(app, w)
	palette_close(app, w)
	if workspace_picker_active(&w.workspace_picker) {workspace_picker_cancel(w)}
	if current := confirmation_current(w); current != nil && current != reopening {confirmation_cancel(app, w)}
	w.overlay, w.dirty = next, true
}

// Ends the window's surface, releasing what its variant holds. A rename's saving exit is
// rename_finish, which calls this once the name is stored.
overlay_close :: proc(app: ^App, w: ^Window, exit := Overlay_Exit.Cancel) {
	switch current in w.overlay {
	case nil:
		return
	case Overlay_Chip_Name:
		if exit == .Leave {_ = chip_name_save(app, w, current.workspace)}
		ui.field_release(&w.rename)
	case Overlay_Rename:
		ui.field_release(&w.rename)
	case Overlay_Document_Menu:
		document_menu_mode_release(current.mode)
		ui.field_release(&w.document_menu.url)
		w.document_menu.menu.hover_part = .Row
	case Overlay_Tab_Menu, Overlay_Divider_Menu, Overlay_Profile_Menu:
	}
	w.overlay, w.dirty = nil, true
}

// Ends everything that takes the window's input: the window's surface, the palette, the picker and any
// confirmation, plus the transient rail overlay and Activity inbox. Losing focus keeps a chip name that
// can be kept and an icon picker the emoji panel took focus from.
window_overlays_cancel :: proc(app: ^App, w: ^Window, focus_lost := false) {
	palette_release(app, w)
	workspace_picker_cancel(w, focus_lost)
	overlay_close(app, w, focus_lost ? .Leave : .Cancel)
	confirmation_cancel(app, w)
	rail_overlay_dismiss(app, w)
	status_overview_cancel(w)
	w.dirty = true
}
