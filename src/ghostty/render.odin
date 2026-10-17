package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Render_State_Dirty :: enum i32 {
	False = 0,
	Partial = 1,
	Full = 2,
}

Render_State_Cursor_Visual_Style :: enum i32 {
	Bar = 0,
	Block = 1,
	Underline = 2,
	Block_Hollow = 3,
}

Render_State_Overscan :: struct {
	above: u16,
	below: u16,
}

Render_State_Row_Id :: struct {
	bits: [2]u64,
}

Render_State_Data :: enum i32 {
	Invalid = 0,
	Cols = 1,
	Rows = 2,
	Dirty = 3,
	Row_Iterator = 4,
	Color_Background = 5,
	Color_Foreground = 6,
	Color_Cursor = 7,
	Color_Cursor_Has_Value = 8,
	Color_Palette = 9,
	Cursor_Visual_Style = 10,
	Cursor_Visible = 11,
	Cursor_Blinking = 12,
	Cursor_Password_Input = 13,
	Cursor_Viewport_Has_Value = 14,
	Cursor_Viewport_X = 15,
	Cursor_Viewport_Y = 16,
	Cursor_Viewport_Wide_Tail = 17,
	Cursor = 18,
	Colors = 19,
	Overscan = 20,
	Overscan_Request = 21,
}

Render_State_Option :: enum i32 {
	Dirty = 0,
	Overscan = 1,
}

Render_State_Row_Data :: enum i32 {
	Invalid = 0,
	Dirty = 1,
	Raw = 2,
	Cells = 3,
	Selection = 4,
	Cells_Raw = 5,
	Viewport_Y = 6,
	Id = 7,
}

Render_State_Row_Option :: enum i32 {
	Dirty = 0,
}

Render_State_Row_Selection :: struct {
	size: uint,
	start_x: u16,
	end_x: u16,
}

Render_State_Cursor :: struct {
	size: uint,
	viewport_has_value: bool,
	viewport_x: u16,
	viewport_y: u16,
	wide_tail: bool,
	visible: bool,
	blinking: bool,
	password_input: bool,
	visual_style: Render_State_Cursor_Visual_Style,
}

Render_State_Colors :: struct {
	size: uint,
	background: Color_Rgb,
	foreground: Color_Rgb,
	cursor: Color_Rgb,
	cursor_has_value: bool,
	palette: [256]Color_Rgb,
}

Render_State_Row_Cells_Data :: enum i32 {
	Invalid = 0,
	Raw = 1,
	Style = 2,
	Graphemes_Len = 3,
	Graphemes_Buf = 4,
	Bg_Color = 5,
	Fg_Color = 6,
	Selected = 7,
	Has_Styling = 8,
	Graphemes_Utf8 = 9,
}

@(default_calling_convention="c", link_prefix="ghostty_")
foreign lib {
	@(require_results)
	render_state_new :: proc(allocator: ^Allocator, state: ^Render_State) -> Result ---
	render_state_free :: proc(state: Render_State) ---
	@(require_results)
	render_state_update :: proc(state: Render_State, terminal: Terminal) -> Result ---
	@(require_results)
	render_state_begin_update :: proc(state: Render_State, terminal: Terminal) -> Result ---
	@(require_results)
	render_state_end_update :: proc(state: Render_State) -> Result ---
	@(require_results)
	render_state_clean :: proc(state: Render_State) -> Result ---
	@(require_results)
	render_state_get :: proc(state: Render_State, data: Render_State_Data, out: rawptr) -> Result ---
	@(require_results)
	render_state_get_multi :: proc(
		state: Render_State,
		count: uint,
		keys: [^]Render_State_Data,
		values: [^]rawptr,
		out_written: ^uint,
	) -> Result ---
	@(require_results)
	render_state_set :: proc(state: Render_State, option: Render_State_Option, value: rawptr) -> Result ---
	@(require_results)
	render_state_row_iterator_new :: proc(
		allocator: ^Allocator,
		out_iterator: ^Render_State_Row_Iterator,
	) -> Result ---
	render_state_row_iterator_free :: proc(iterator: Render_State_Row_Iterator) ---
	@(require_results)
	render_state_row_iterator_next :: proc(iterator: Render_State_Row_Iterator) -> bool ---
	@(require_results)
	render_state_row_iterator_next_dirty :: proc(iterator: Render_State_Row_Iterator, out_y: ^u16) -> bool ---
	@(require_results)
	render_state_row_get :: proc(
		iterator: Render_State_Row_Iterator,
		data: Render_State_Row_Data,
		out: rawptr,
	) -> Result ---
	@(require_results)
	render_state_row_get_multi :: proc(
		iterator: Render_State_Row_Iterator,
		count: uint,
		keys: [^]Render_State_Row_Data,
		values: [^]rawptr,
		out_written: ^uint,
	) -> Result ---
	@(require_results)
	render_state_row_set :: proc(
		iterator: Render_State_Row_Iterator,
		option: Render_State_Row_Option,
		value: rawptr,
	) -> Result ---
	@(require_results)
	render_state_row_cells_new :: proc(allocator: ^Allocator, out_cells: ^Render_State_Row_Cells) -> Result ---
	@(require_results)
	render_state_row_cells_next :: proc(cells: Render_State_Row_Cells) -> bool ---
	@(require_results)
	render_state_row_cells_select :: proc(cells: Render_State_Row_Cells, x: u16) -> Result ---
	@(require_results)
	render_state_row_cells_get :: proc(
		cells: Render_State_Row_Cells,
		data: Render_State_Row_Cells_Data,
		out: rawptr,
	) -> Result ---
	@(require_results)
	render_state_row_cells_get_multi :: proc(
		cells: Render_State_Row_Cells,
		count: uint,
		keys: [^]Render_State_Row_Cells_Data,
		values: [^]rawptr,
		out_written: ^uint,
	) -> Result ---
	render_state_row_cells_free :: proc(cells: Render_State_Row_Cells) ---
}
