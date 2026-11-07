package main

import "aio:platform"
import "aio:render"
import "core:math"
import "aio:ui"

Workspace_Picker_Mode :: enum { Closed, List, Menu, Rename, Icons, Tint }

// Which part of the picker is open; nil is closed. workspace_picker_transition and workspace_picker_list_set
// are its only writers, so a move target, a drag hold or a row press ends with the list it belongs to.
Workspace_Picker_State :: union {
	Workspace_Picker_List,
	Workspace_Picker_Menu,
	Workspace_Picker_Rename,
	Workspace_Picker_Icons,
	Workspace_Picker_Tint,
}

Workspace_Picker_List :: struct {
	sub: Workspace_List_State,
}

// What the list does besides browsing, which is nil.
Workspace_List_State :: union {
	Workspace_Chip_Pressed,
	Workspace_Move_Target,
	Workspace_Order_Pressed,
	Workspace_Order_Lifted,
}

// The chip press that opened the list. A second press on the chip within the double-click time names the
// workspace; it lands on the list because the first press opened it.
Workspace_Chip_Pressed :: struct {
	time_ns: i64,
}

// The rows are destinations for content rather than workspaces to switch to. A pane or tab drag holds
// the list open from its chip, offering a new window as well; that drag's Drop_Workspace_Dropdown
// destination carries the pointer.
Workspace_Move_Target :: struct {
	request: Workspace_Move_Request,
	drag:    bool,
}

Workspace_Picker_Menu :: struct {
	id: u32,
}

Workspace_Picker_Rename :: struct {
	id:    u32,
	error: bool,
}

Workspace_Picker_Icons :: struct {
	id: u32,
}

Workspace_Picker_Tint :: struct {
	id: u32,
}

Workspace_Picker :: struct {
	state: Workspace_Picker_State,
	query: ui.Text_Field,
	rows: [dynamic]Workspace_Row,
	selected, scroll: int,
	menu_selected: int,
	menu_hover: u32,
	menu_motion: ui.Control_Motion,
	rename_motion: ui.Motion,
	// The list's query while Icons or Tint edits the field, restored on return. The buffer is kept for reuse.
	saved_query: ui.Text_Field,
	order_positions: [dynamic]Workspace_Order_Position,
	order_settle: Maybe(Workspace_Order_Settle),
}

workspace_picker_active :: proc(p: ^Workspace_Picker) -> bool {
	return p.state != nil
}

workspace_picker_mode :: proc(p: ^Workspace_Picker) -> Workspace_Picker_Mode {
	switch _ in p.state {
	case Workspace_Picker_List: return .List
	case Workspace_Picker_Menu: return .Menu
	case Workspace_Picker_Rename: return .Rename
	case Workspace_Picker_Icons: return .Icons
	case Workspace_Picker_Tint: return .Tint
	}
	return .Closed
}

workspace_picker_icons :: proc(p: ^Workspace_Picker) -> bool {
	mode := workspace_picker_mode(p)
	return mode == .Icons || mode == .Tint
}

// The workspace a row menu, rename or icon grid acts on, or 0 when the picker is not in that mode. Icons
// includes Tint, which edits the same workspace's icon.
workspace_picker_target :: proc(p: ^Workspace_Picker, mode: Workspace_Picker_Mode) -> u32 {
	switch s in p.state {
	case Workspace_Picker_List:
	case Workspace_Picker_Menu: if mode == .Menu {return s.id}
	case Workspace_Picker_Rename: if mode == .Rename {return s.id}
	case Workspace_Picker_Icons: if mode == .Icons {return s.id}
	case Workspace_Picker_Tint: if mode == .Icons || mode == .Tint {return s.id}
	}
	return 0
}

workspace_picker_move :: proc(p: ^Workspace_Picker) -> (move: Workspace_Move_Target, moving: bool) {
	list := p.state.(Workspace_Picker_List) or_return
	return list.sub.(Workspace_Move_Target)
}

// Whether a pane or tab drag holds the list open as its drop target.
workspace_picker_held :: proc(p: ^Workspace_Picker) -> bool {
	move, moving := workspace_picker_move(p)
	return moving && move.drag
}

// The list shows workspaces to switch to: rows offer their menu and a press may reorder them.
workspace_picker_browsing :: proc(p: ^Workspace_Picker) -> bool {
	list, listing := p.state.(Workspace_Picker_List)
	_, moving := list.sub.(Workspace_Move_Target)
	return listing && !moving
}

workspace_picker_rename_error :: proc(p: ^Workspace_Picker) -> bool {
	rename, renaming := p.state.(Workspace_Picker_Rename)
	return renaming && rename.error
}

// Enters mode, leaving any list state behind. target_id is the workspace a Menu, Rename, Icons or Tint
// acts on. Row motion carries on settling under the rows of List, Menu and Rename; the icon grids hide
// the rows.
@(private)
workspace_picker_transition :: proc(w: ^Window, mode: Workspace_Picker_Mode, target_id: u32 = 0) {
	p := &w.workspace_picker
	next: Workspace_Picker_State
	switch mode {
	case .Closed:
	case .List: next = Workspace_Picker_List{}
	case .Menu: next = Workspace_Picker_Menu{target_id}
	case .Rename: next = Workspace_Picker_Rename{id = target_id}
	case .Icons: next = Workspace_Picker_Icons{target_id}
	case .Tint: next = Workspace_Picker_Tint{target_id}
	}
	workspace_picker_state_set(w, next)
	if mode == .Closed || mode == .Icons || mode == .Tint {workspace_order_stop(p)}
	p.menu_hover, p.menu_selected, p.rename_motion = 0, 0, {}
	ui.field_release(&p.query)
	ui.field_release(&w.rename)
}

// Moves an open list between browsing (nil), a chip press, a move target and a row reorder. Outside the
// list it does nothing.
@(private)
workspace_picker_list_set :: proc(w: ^Window, sub: Workspace_List_State) {
	if _, listing := w.workspace_picker.state.(Workspace_Picker_List); !listing {return}
	workspace_picker_state_set(w, Workspace_Picker_List{sub})
}

// The one write of the picker's state. A lifted row that the new state lets go starts its settle.
@(private = "file")
workspace_picker_state_set :: proc(w: ^Window, next: Workspace_Picker_State) {
	p := &w.workspace_picker
	lifted: u32
	if lift := workspace_order_lift(p); lift != nil {lifted = lift.id}
	p.state = next
	if lifted != 0 && workspace_order_lift(p) == nil {p.order_settle = Workspace_Order_Settle{lifted}}
	w.dirty = true
}

workspace_picker_cancel :: proc(w: ^Window, focus_lost := false) {
	p := &w.workspace_picker
	ui.field_release(&p.query)
	ui.field_release(&w.rename)
	// Windows' emoji picker can take focus before delivering text to the icon field.
	if focus_lost && workspace_picker_icons(p) {return}
	workspace_picker_transition(w, .Closed)
}

workspace_picker_destroy :: proc(w: ^Window) {
	delete(w.workspace_picker.query.bytes)
	delete(w.workspace_picker.saved_query.bytes)
	delete(w.workspace_picker.rows)
	delete(w.workspace_picker.order_positions)
	w.workspace_picker = {}
}

workspace_picker_layout_changed :: proc(w: ^Window) {
	p := &w.workspace_picker
	if !workspace_picker_active(p) {return}
	p.selected = clamp(p.selected, 0, workspace_picker_count(w) - 1)
	if workspace_picker_icons(p) {
		workspace_icon_picker_reveal(w, workspace_icon_picker_layout(w))
		return
	}
	if mode := workspace_picker_mode(p); mode == .Rename || mode == .Menu {
		if index := workspace_row_index(w, workspace_picker_target(p, mode)); index >= 0 {p.selected = index}
	}
	_, rows := workspace_picker_rect(w)
	p.scroll = clamp(p.scroll, max(0, p.selected - rows + 1), p.selected)
	p.scroll = clamp(p.scroll, 0, max(0, workspace_picker_count(w) - rows))
}

workspace_picker_select :: proc(w: ^Window, index: int) {
	w.workspace_picker.selected, w.dirty = index, true
	workspace_picker_layout_changed(w)
}

// Opens the list from a press on the chip, keeping the press for a double-click.
workspace_picker_chip_press :: proc(app: ^App, w: ^Window, time_ns: i64) {
	workspace_picker_open(app, w)
	workspace_picker_list_set(w, Workspace_Chip_Pressed{time_ns})
}

workspace_picker_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	p := &w.workspace_picker
	if !e.pressed {
		ui.field_release(&p.query)
		ui.field_release(&w.rename)
		if e.button == .Left {workspace_order_release(app, w, e)}
		return
	}
	gesture_swallow(w, e.button, .Workspace_Picker)
	x, y := f32(e.x), f32(e.y)
	r, _ := workspace_picker_rect(w)
	if list, listing := p.state.(Workspace_Picker_List); listing && e.button == .Left {
		if chip, pressed := list.sub.(Workspace_Chip_Pressed); pressed &&
		   render.rect_contains(workspace_button_rect(w), x, y) &&
		   e.time_ns - chip.time_ns <= DOUBLE_CLICK_NS {
			workspace_name_begin(app, w)
			return
		}
	}
	if workspace_picker_mode(p) == .Menu && e.button == .Left {
		workspace_picker_click(app, w, x, y, .Shift in e.modifiers)
	} else if !render.rect_contains(r, x, y) {
		workspace_picker_cancel(w)
	} else if e.button == .Left {
		if workspace_picker_browsing(p) {
			if hit := workspace_picker_hit(w, x, y); hit >= 0 && hit < len(p.rows) &&
			   !render.rect_contains(workspace_picker_menu_button_rect(w, hit), x, y) {
				row := workspace_picker_row_rect(w, hit)
				workspace_picker_list_set(w, Workspace_Order_Pressed{id = p.rows[hit].id, start_x = x,
					start_y = y, grab = (y - row.y) / row.height})
				workspace_picker_select(w, hit)
				return
			}
		}
		workspace_picker_click(app, w, x, y, .Shift in e.modifiers)
	}
}

workspace_picker_hover :: proc(app: ^App, w: ^Window, e: platform.Mouse_Move_Event) {
	if workspace_order_hover(app, w, e) {return}
	if workspace_row_hover(app, w, e) {return}
	p := &w.workspace_picker
	x, y := f32(e.x), f32(e.y)
	hover := u32(0)
	shape := platform.Cursor_Shape.Arrow
	if p.query.dragging && .Left in e.buttons {
		workspace_picker_pointer(app, w, x, false, true)
		shape = .Text
	} else if hit := workspace_picker_hit(w, x, y); hit >= 0 {
		shape = .Hand
		workspace_picker_select(w, hit)
		if workspace_picker_browsing(p) && hit < len(p.rows) &&
		   render.rect_contains(workspace_picker_menu_button_rect(w, hit), x, y) {
			hover = p.rows[hit].id
		}
	} else if render.rect_contains(workspace_picker_field_rect(w), x, y) {
		shape = .Text
	}
	if hover != p.menu_hover {
		p.menu_hover, w.dirty = hover, true
	}
	pointer_set(app, w, shape)
}

workspace_picker_wheel :: proc(w: ^Window, delta: f32) {
	p := &w.workspace_picker
	if mode := workspace_picker_mode(p); mode == .Menu || mode == .Rename {return}
	if lift := workspace_order_lift(p); lift != nil {
		_, rows := workspace_picker_rect(w)
		p.scroll = clamp(p.scroll - int(math.sign(delta)), 0, max(0, len(p.rows) - rows))
		workspace_order_move(w, lift.pointer_x, lift.pointer_y)
		w.dirty = true
		return
	}
	workspace_picker_select(w, p.selected - int(math.sign(delta)))
}
