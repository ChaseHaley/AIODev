package main

import "aio:input"
import "aio:markdown"
import "aio:render"
import "aio:ui"
import "core:log"

// The menu a right click on an editor's text opens: Undo, Redo, Cut, Copy, Paste and Select all, with the
// keys that do the same. Its rows are w.edit_menu; the Markdown pane whose text they act on is the
// overlay's. Rows that would do nothing show disabled.

@(private = "file", rodata)
EDIT_MENU_LABELS := [Text_Edit_Command]string {
	.Undo       = "Undo",
	.Redo       = "Redo",
	.Cut        = "Cut",
	.Copy       = "Copy",
	.Paste      = "Paste",
	.Select_All = "Select all",
}

@(private = "file", rodata)
EDIT_MENU_SHORTCUTS := [Text_Edit_Command]string {
	.Undo       = "Ctrl+Z",
	.Redo       = "Ctrl+Y",
	.Cut        = "Ctrl+X",
	.Copy       = "Ctrl+C",
	.Paste      = "Ctrl+V",
	.Select_All = "Ctrl+A",
}

// Where a group of rows starts, so a separator goes before it.
@(private = "file", rodata)
EDIT_MENU_GROUP_STARTS := bit_set[Text_Edit_Command]{.Cut, .Select_All}

@(private = "file")
EDIT_MENU_WIDTH :: f32(220)

edit_menu_shown :: proc(w: ^Window) -> bool {
	_, shown := w.overlay.(Overlay_Edit_Menu)
	return shown
}

// Opens the menu at a point for the Markdown pane `pane`, whose text is `b`.
edit_menu_open :: proc(app: ^App, w: ^Window, pane: u32, b: ^markdown.Edit_Buffer, x, y: f32) {
	if !gesture_cancel(app, w) {return}
	overlay_open(app, w, Overlay_Edit_Menu{pane = pane})
	menu := &w.edit_menu
	ui.menu_clear(menu)
	ui.menu_anchor(menu, x, y)
	menu.width = EDIT_MENU_WIDTH
	for command in Text_Edit_Command {
		if command in EDIT_MENU_GROUP_STARTS {
			if added, err := ui.menu_add(menu, {separator = true}); !added {
				log.errorf("adding an edit menu separator failed: %v", err)
				overlay_close(app, w)
				return
			}
		}
		row := ui.Menu_Item {
			label    = EDIT_MENU_LABELS[command],
			shortcut = EDIT_MENU_SHORTCUTS[command],
			enabled  = text_edit_enabled(app, b, command),
			payload  = u32(command),
		}
		if added, err := ui.menu_add(menu, row); !added {
			log.errorf("adding an edit menu row failed: %v", err)
			overlay_close(app, w)
			return
		}
	}
	ui.menu_select_edge(menu, false)
}

edit_menu_choose :: proc(app: ^App, w: ^Window) {
	shown, ok := w.overlay.(Overlay_Edit_Menu)
	index := ui.menu_selected(&w.edit_menu)
	if !ok || index < 0 {return}
	item := w.edit_menu.items[index]
	if !item.enabled || item.separator {return}
	overlay_close(app, w)
	markdown_edit_command(app, w, shown.pane, Text_Edit_Command(item.payload))
}

edit_menu_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	if !e.pressed {return}
	w.dirty = true
	switch ui.menu_key(&w.edit_menu, e) {
	case .None, .Submenu:
	case .Changed: ui.menu_reveal(&w.edit_menu, f32(w.width), f32(w.height), w.scale)
	case .Chosen: edit_menu_choose(app, w)
	case .Closed: overlay_close(app, w)
	}
}

edit_menu_wheel :: proc(w: ^Window, rows: int) {
	ui.menu_wheel(&w.edit_menu, rows)
	ui.menu_reveal(&w.edit_menu, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

@(private = "file")
edit_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	return ui.menu_hit(&w.edit_menu, x, y, f32(w.width), f32(w.height), w.scale)
}

edit_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	width, height := f32(w.width), f32(w.height)
	return ui.menu_draw(&w.edit_menu, &w.list, &w.ui_text, app.theme, width, height, w.scale, w.pointer)
}

// Edit menu pointer surface

@(private)
edit_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return edit_menu_shown(w)}

@(private)
edit_menu_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Edit_Menu {return}
	hit := edit_menu_hit(w, f32(e.x), f32(e.y))
	enabled := hit >= 0 && w.edit_menu.items[hit].enabled
	if enabled && hit != ui.menu_selected(&w.edit_menu) {
		ui.menu_select(&w.edit_menu, hit)
		w.dirty = true
	}
	pointer_set(app, w, enabled ? .Hand : .Arrow)
}

@(private)
edit_menu_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if !e.pressed {return}
	gesture_swallow(w, e.button, .Edit_Menu)
	if hit := edit_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 && e.button == .Left {
		if w.edit_menu.items[hit].enabled {
			ui.menu_select(&w.edit_menu, hit)
			edit_menu_choose(app, w)
		}
	} else {overlay_close(app, w)}
}
