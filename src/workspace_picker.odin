package main

import "aio:input"
import "aio:platform"
import "aio:render"
import "core:math"
import "aio:ui"

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
	// The row editor's text while Workspace_Picker_Rename shows. The buffer is kept for reuse.
	rename: ui.Text_Field,
	rows: [dynamic]Workspace_Row,
	// A navigation cursor over the current targets; workspace_picker_target_at says what it is on.
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

// What a picker position chooses. Each part of the picker lays its targets out in one order:
//
// - browsing, a row menu or a rename: each workspace row, then each of WORKSPACE_ACTIONS;
// - a keyboard move: each workspace row, then a new workspace;
// - a drag move: each workspace row, then a new workspace and a new window;
// - icons: each preset icon, then the emoji field, its Apply button and the icon colour button;
// - tint: each preset colour, then Back to icons.
Workspace_Picker_Target :: union {
	Picker_Workspace,
	Picker_Action,
	Picker_New_Workspace,
	Picker_New_Window,
	Picker_Icon,
	Picker_Emoji_Field,
	Picker_Emoji_Apply,
	Picker_Tint_Open,
	Picker_Tint,
	Picker_Tint_Back,
}

// A workspace row: switch to it, or move content into it.
Picker_Workspace :: struct {
	id: u32,
}

// A browse list's command row, one of WORKSPACE_ACTIONS.
Picker_Action :: struct {
	action: Action,
}

// A move's destination row that creates a workspace for the content.
Picker_New_Workspace :: struct {}

// A drag's destination row that tears the content off into a new window.
Picker_New_Window :: struct {}

// A preset icon cell, by its index in WORKSPACE_ICONS.
Picker_Icon :: struct {
	preset: int,
}

Picker_Emoji_Field :: struct {}

Picker_Emoji_Apply :: struct {}

// The icon grid's colour button, which opens the tint grid.
Picker_Tint_Open :: struct {}

// A preset colour cell, by its index in WORKSPACE_ICON_COLORS.
Picker_Tint :: struct {
	tint: int,
}

Picker_Tint_Back :: struct {}

// The emoji field, its Apply button and the colour button follow the preset icons.
WORKSPACE_ICON_CONTROLS :: 3

workspace_picker_active :: proc(p: ^Workspace_Picker) -> bool {
	return p.state != nil
}

// The icon grid or the tint grid it opens shows.
workspace_picker_icons :: proc(p: ^Workspace_Picker) -> bool {
	#partial switch _ in p.state {
	case Workspace_Picker_Icons, Workspace_Picker_Tint: return true
	}
	return false
}

workspace_picker_tint :: proc(p: ^Workspace_Picker) -> bool {
	_, tint := p.state.(Workspace_Picker_Tint)
	return tint
}

// The workspace whose row menu shows, or 0.
workspace_picker_menu_id :: proc(p: ^Workspace_Picker) -> u32 {
	menu, _ := p.state.(Workspace_Picker_Menu)
	return menu.id
}

// The workspace the row editor renames, or 0.
workspace_picker_rename_id :: proc(p: ^Workspace_Picker) -> u32 {
	rename, _ := p.state.(Workspace_Picker_Rename)
	return rename.id
}

// The workspace whose icon the icon or tint grid edits, or 0.
workspace_picker_icon_id :: proc(p: ^Workspace_Picker) -> u32 {
	#partial switch s in p.state {
	case Workspace_Picker_Icons: return s.id
	case Workspace_Picker_Tint: return s.id
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

// How many targets the current part of the picker lays out.
workspace_picker_count :: proc(w: ^Window) -> int {
	p := &w.workspace_picker
	#partial switch _ in p.state {
	case Workspace_Picker_Icons: return len(WORKSPACE_ICONS) + WORKSPACE_ICON_CONTROLS
	case Workspace_Picker_Tint: return len(WORKSPACE_ICON_COLORS) + 1
	}
	if move, moving := workspace_picker_move(p); moving {
		return len(p.rows) + (move.drag ? 2 : 1)
	}
	return len(p.rows) + len(WORKSPACE_ACTIONS)
}

// The target at a cursor position, or nil outside the current targets.
workspace_picker_target_at :: proc(w: ^Window, index: int) -> Workspace_Picker_Target {
	p := &w.workspace_picker
	if index < 0 || index >= workspace_picker_count(w) {return nil}
	#partial switch _ in p.state {
	case Workspace_Picker_Icons:
		switch index - len(WORKSPACE_ICONS) {
		case 0: return Picker_Emoji_Field{}
		case 1: return Picker_Emoji_Apply{}
		case 2: return Picker_Tint_Open{}
		}
		return Picker_Icon{index}
	case Workspace_Picker_Tint:
		if index == len(WORKSPACE_ICON_COLORS) {return Picker_Tint_Back{}}
		return Picker_Tint{index}
	}
	if index < len(p.rows) {return Picker_Workspace{p.rows[index].id}}
	tail := index - len(p.rows)
	if _, moving := workspace_picker_move(p); moving {
		if tail == 0 {return Picker_New_Workspace{}}
		return Picker_New_Window{}
	}
	@(static, rodata) actions := WORKSPACE_ACTIONS
	return Picker_Action{actions[tail]}
}

// The cursor position of a target, and whether the current part of the picker shows it.
workspace_picker_target_index :: proc(w: ^Window, target: Workspace_Picker_Target) -> (int, bool) {
	p := &w.workspace_picker
	_, icons := p.state.(Workspace_Picker_Icons)
	tint := workspace_picker_tint(p)
	move, moving := workspace_picker_move(p)
	rows := !icons && !tint
	switch t in target {
	case nil:
	case Picker_Workspace:
		if index := workspace_row_index(w, t.id); rows && index >= 0 {return index, true}
	case Picker_Action:
		if !rows || moving {break}
		@(static, rodata) actions := WORKSPACE_ACTIONS
		for action, i in actions {if action == t.action {return len(p.rows) + i, true}}
	case Picker_New_Workspace:
		if moving {return len(p.rows), true}
	case Picker_New_Window:
		if moving && move.drag {return len(p.rows) + 1, true}
	case Picker_Icon:
		if icons && t.preset >= 0 && t.preset < len(WORKSPACE_ICONS) {return t.preset, true}
	case Picker_Emoji_Field:
		if icons {return len(WORKSPACE_ICONS), true}
	case Picker_Emoji_Apply:
		if icons {return len(WORKSPACE_ICONS) + 1, true}
	case Picker_Tint_Open:
		if icons {return len(WORKSPACE_ICONS) + 2, true}
	case Picker_Tint:
		if tint && t.tint >= 0 && t.tint < len(WORKSPACE_ICON_COLORS) {return t.tint, true}
	case Picker_Tint_Back:
		if tint {return len(WORKSPACE_ICON_COLORS), true}
	}
	return -1, false
}

// The target under the cursor.
workspace_picker_selection :: proc(w: ^Window) -> Workspace_Picker_Target {
	return workspace_picker_target_at(w, w.workspace_picker.selected)
}

// Moves the cursor onto a target the current part of the picker shows; any other target leaves it.
workspace_picker_select_target :: proc(w: ^Window, target: Workspace_Picker_Target) {
	if index, shown := workspace_picker_target_index(w, target); shown {
		w.workspace_picker.selected, w.dirty = index, true
	}
}

// Enters `next`, leaving any list state behind; nil closes the picker. Row motion carries on settling under
// the rows of List, Menu and Rename; the icon grids hide the rows.
@(private)
workspace_picker_transition :: proc(w: ^Window, next: Workspace_Picker_State) {
	p := &w.workspace_picker
	workspace_picker_state_set(w, next)
	switch _ in next {
	case nil, Workspace_Picker_Icons, Workspace_Picker_Tint: workspace_order_stop(p)
	case Workspace_Picker_List, Workspace_Picker_Menu, Workspace_Picker_Rename:
	}
	p.menu_hover, p.menu_selected, p.rename_motion = 0, 0, {}
	ui.field_release(&p.query)
	ui.field_release(&p.rename)
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
	ui.field_release(&p.rename)
	// Windows' emoji picker can take focus before delivering text to the icon field.
	if focus_lost && workspace_picker_icons(p) {return}
	workspace_picker_transition(w, nil)
}

workspace_picker_destroy :: proc(w: ^Window) {
	delete(w.workspace_picker.query.bytes)
	delete(w.workspace_picker.rename.bytes)
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
	id := workspace_picker_menu_id(p)
	if id == 0 {id = workspace_picker_rename_id(p)}
	if index := workspace_row_index(w, id); index >= 0 {p.selected = index}
	_, rows := workspace_picker_rect(w)
	p.scroll = clamp(p.scroll, max(0, p.selected - rows + 1), p.selected)
	workspace_picker_scroll(w, 0)
}

// Scrolls the list by `rows` within its current targets. A lifted row reorders among the workspace rows,
// so it scrolls them alone; otherwise every target, including a move's or drag's destinations, counts.
workspace_picker_scroll :: proc(w: ^Window, rows: int) {
	p := &w.workspace_picker
	_, visible := workspace_picker_rect(w)
	count := workspace_order_lift(p) != nil ? len(p.rows) : workspace_picker_count(w)
	p.scroll = clamp(p.scroll + rows, 0, max(0, count - visible))
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

workspace_picker_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	p := &w.workspace_picker
	if !e.pressed {
		ui.field_release(&p.query)
		ui.field_release(&p.rename)
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
	if _, menu := p.state.(Workspace_Picker_Menu); menu && e.button == .Left {
		workspace_picker_click(app, w, x, y, .Shift in e.modifiers)
	} else if !render.rect_contains(r, x, y) {
		workspace_picker_cancel(w)
	} else if e.button == .Left {
		if workspace_picker_browsing(p) {
			hit := workspace_picker_hit(w, x, y)
			if _, on_row := workspace_picker_target_at(w, hit).(Picker_Workspace); on_row &&
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

workspace_picker_hover :: proc(app: ^App, w: ^Window, e: input.Mouse_Move_Event) {
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
		row, on_row := workspace_picker_target_at(w, hit).(Picker_Workspace)
		if workspace_picker_browsing(p) && on_row &&
		   render.rect_contains(workspace_picker_menu_button_rect(w, hit), x, y) {
			hover = row.id
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
	#partial switch _ in p.state {
	case Workspace_Picker_Menu, Workspace_Picker_Rename: return
	}
	if lift := workspace_order_lift(p); lift != nil {
		workspace_picker_scroll(w, -int(math.sign(delta)))
		workspace_order_move(w, lift.pointer_x, lift.pointer_y)
		w.dirty = true
		return
	}
	workspace_picker_select(w, p.selected - int(math.sign(delta)))
}
