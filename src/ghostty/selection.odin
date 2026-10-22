package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Selection_Gesture :: distinct rawptr

Selection_Gesture_Event :: distinct rawptr

Selection :: struct {
	size:      uint,
	start:     Grid_Ref,
	end:       Grid_Ref,
	rectangle: bool,
}

Selection_Buffer :: struct {
	ptr: ^Selection,
	cap: uint,
	len: uint,
}

Terminal_Select_Word_Options :: struct {
	size:                    uint,
	ref:                     Grid_Ref,
	boundary_codepoints:     [^]u32,
	boundary_codepoints_len: uint,
}

Terminal_Select_Word_Between_Options :: struct {
	size:                    uint,
	start:                   Grid_Ref,
	end:                     Grid_Ref,
	boundary_codepoints:     [^]u32,
	boundary_codepoints_len: uint,
}

Terminal_Select_Line_Options :: struct {
	size:                     uint,
	ref:                      Grid_Ref,
	whitespace:               [^]u32,
	whitespace_len:           uint,
	semantic_prompt_boundary: bool,
}

Terminal_Selection_Format_Options :: struct {
	size:      uint,
	emit:      Formatter_Format,
	unwrap:    bool,
	trim:      bool,
	selection: ^Selection,
}

Selection_Order :: enum i32 {
	Forward          = 0,
	Reverse          = 1,
	Mirrored_Forward = 2,
	Mirrored_Reverse = 3,
}

Selection_Adjust :: enum i32 {
	Left              = 0,
	Right             = 1,
	Up                = 2,
	Down              = 3,
	Home              = 4,
	End               = 5,
	Page_Up           = 6,
	Page_Down         = 7,
	Beginning_Of_Line = 8,
	End_Of_Line       = 9,
}

Selection_Gesture_Behavior :: enum i32 {
	Cell   = 0,
	Word   = 1,
	Line   = 2,
	Output = 3,
}

Selection_Gesture_Behaviors :: struct {
	single_click: Selection_Gesture_Behavior,
	double_click: Selection_Gesture_Behavior,
	triple_click: Selection_Gesture_Behavior,
}

Selection_Gesture_Geometry :: struct {
	columns:       u32,
	cell_width:    u32,
	padding_left:  u32,
	screen_height: u32,
}

Selection_Gesture_Autoscroll :: enum i32 {
	None = 0,
	Up   = 1,
	Down = 2,
}

Selection_Gesture_Data :: enum i32 {
	Click_Count = 0,
	Dragged     = 1,
	Autoscroll  = 2,
	Behavior    = 3,
	Anchor      = 4,
}

Selection_Gesture_Event_Type :: enum i32 {
	Press           = 0,
	Release         = 1,
	Drag            = 2,
	Autoscroll_Tick = 3,
	Deep_Press      = 4,
}

Selection_Gesture_Event_Option :: enum i32 {
	Ref                      = 0,
	Position                 = 1,
	Repeat_Distance          = 2,
	Time_Ns                  = 3,
	Repeat_Interval_Ns       = 4,
	Word_Boundary_Codepoints = 5,
	Behaviors                = 6,
	Rectangle                = 7,
	Geometry                 = 8,
	Viewport                 = 9,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	selection_gesture_event_new :: proc(allocator: ^Allocator, out_event: ^Selection_Gesture_Event, type: Selection_Gesture_Event_Type) -> Result ---
	selection_gesture_event_free :: proc(event: Selection_Gesture_Event) ---
	@(require_results)
	selection_gesture_event_set :: proc(event: Selection_Gesture_Event, option: Selection_Gesture_Event_Option, value: rawptr) -> Result ---
	@(require_results)
	selection_gesture_event :: proc(gesture: Selection_Gesture, terminal: Terminal, event: Selection_Gesture_Event, out_selection: ^Selection) -> Result ---
	@(require_results)
	selection_gesture_new :: proc(allocator: ^Allocator, out_gesture: ^Selection_Gesture) -> Result ---
	selection_gesture_free :: proc(gesture: Selection_Gesture, terminal: Terminal) ---
	selection_gesture_reset :: proc(gesture: Selection_Gesture, terminal: Terminal) ---
	@(require_results)
	selection_gesture_get :: proc(gesture: Selection_Gesture, terminal: Terminal, data: Selection_Gesture_Data, value: rawptr) -> Result ---
	@(require_results)
	selection_gesture_get_multi :: proc(gesture: Selection_Gesture, terminal: Terminal, count: uint, keys: [^]Selection_Gesture_Data, values: [^]rawptr, out_written: ^uint) -> Result ---
	@(require_results)
	terminal_select_word :: proc(terminal: Terminal, options: ^Terminal_Select_Word_Options, out_selection: ^Selection) -> Result ---
	@(require_results)
	terminal_select_word_between :: proc(terminal: Terminal, options: ^Terminal_Select_Word_Between_Options, out_selection: ^Selection) -> Result ---
	@(require_results)
	terminal_select_line :: proc(terminal: Terminal, options: ^Terminal_Select_Line_Options, out_selection: ^Selection) -> Result ---
	@(require_results)
	terminal_select_all :: proc(terminal: Terminal, out_selection: ^Selection) -> Result ---
	@(require_results)
	terminal_select_output :: proc(terminal: Terminal, ref: Grid_Ref, out_selection: ^Selection) -> Result ---
	@(require_results)
	terminal_selection_format_buf :: proc(terminal: Terminal, options: Terminal_Selection_Format_Options, buf: [^]u8, buf_len: uint, out_written: ^uint) -> Result ---
	@(require_results)
	terminal_selection_format_alloc :: proc(terminal: Terminal, allocator: ^Allocator, options: Terminal_Selection_Format_Options, out_ptr: ^[^]u8, out_len: ^uint) -> Result ---
	@(require_results)
	terminal_selection_adjust :: proc(terminal: Terminal, selection: ^Selection, adjustment: Selection_Adjust) -> Result ---
	@(require_results)
	terminal_selection_order :: proc(terminal: Terminal, selection: ^Selection, out_order: ^Selection_Order) -> Result ---
	@(require_results)
	terminal_selection_ordered :: proc(terminal: Terminal, selection: ^Selection, desired: Selection_Order, out_selection: ^Selection) -> Result ---
	@(require_results)
	terminal_selection_contains :: proc(terminal: Terminal, selection: ^Selection, point: Point, out_contains: ^bool) -> Result ---
	@(require_results)
	terminal_selection_equal :: proc(terminal: Terminal, a: ^Selection, b: ^Selection, out_equal: ^bool) -> Result ---
}
