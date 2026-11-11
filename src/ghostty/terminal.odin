package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Terminal_Scroll_Viewport_Tag :: enum i32 {
	Top          = 0,
	Bottom       = 1,
	Delta        = 2,
	Row          = 3,
	Delta_Prompt = 4,
}

Terminal_Scroll_Viewport_Value :: struct #raw_union {
	delta:        int,
	row:          uint,
	delta_prompt: int,
	_padding:     [2]u64,
}

Terminal_Scroll_Viewport :: struct {
	tag:   Terminal_Scroll_Viewport_Tag,
	value: Terminal_Scroll_Viewport_Value,
}

Terminal_Screen :: enum i32 {
	Primary   = 0,
	Alternate = 1,
}

Terminal_Boundary :: enum u32 {
	Ground,
	Apc_Start,
	Apc_End,
	Dcs_Start,
	Dcs_End,
	Osc_Start,
	Osc_End,
}

Terminal_Boundaries :: bit_set[Terminal_Boundary;u32]

Terminal_String_Kind :: enum i32 {
	Apc = 0,
	Dcs = 1,
	Osc = 2,
}

Terminal_String_Introducer :: enum i32 {
	Esc = 0,
	C1  = 1,
}

Terminal_String_End :: enum i32 {
	St_Esc    = 0,
	St_C1     = 1,
	Cancelled = 2,
	Aborted   = 3,
	Bel       = 4,
}

Terminal_Write_Stop :: struct {
	size:       uint,
	consumed:   uint,
	reached:    Terminal_Boundaries,
	kind:       Terminal_String_Kind,
	introducer: Terminal_String_Introducer,
	end:        Terminal_String_End,
	byte:       u8,
}

Terminal_Scrollbar :: struct {
	total:  u64,
	offset: u64,
	len:    u64,
}

Terminal_Memory_Usage :: struct {
	size:                       uint,
	compression_supported:      bool,
	primary_pages:              u64,
	primary_virtual_bytes:      u64,
	primary_resident_bytes:     u64,
	primary_compressed_pages:   u64,
	primary_compressed_bytes:   u64,
	primary_image_bytes:        u64,
	alternate_pages:            u64,
	alternate_virtual_bytes:    u64,
	alternate_resident_bytes:   u64,
	alternate_compressed_pages: u64,
	alternate_compressed_bytes: u64,
	alternate_image_bytes:      u64,
}

Terminal_Bell_Fn :: proc "c" (terminal: Terminal, userdata: rawptr)

Clipboard_Location :: enum i32 {
	Standard  = 0,
	Selection = 1,
	Primary   = 2,
}

Terminal_Device_Attributes_Fn :: proc "c" (
	terminal: Terminal,
	userdata: rawptr,
	out_attrs: ^Device_Attributes,
) -> bool

Terminal_Title_Changed_Fn :: proc "c" (terminal: Terminal, userdata: rawptr)

Terminal_Render_Hold_Fn :: proc "c" (terminal: Terminal, userdata: rawptr, held: bool)

Terminal_Write_Pty_Fn :: proc "c" (terminal: Terminal, userdata: rawptr, data: [^]u8, len: uint)

Size_Report_Size :: struct {
	rows:        u16,
	columns:     u16,
	cell_width:  u32,
	cell_height: u32,
}

Terminal_Size_Fn :: proc "c" (terminal: Terminal, userdata: rawptr, out_size: ^Size_Report_Size) -> bool

Terminal_Mode_Config :: struct {
	mode:  Mode,
	value: bool,
}

Terminal_Option :: enum i32 {
	Invalid                       = 0,
	Userdata                      = 1,
	Write_Pty                     = 2,
	Bell                          = 3,
	Enquiry                       = 4,
	Xtversion                     = 5,
	Title_Changed                 = 6,
	Size                          = 7,
	Color_Scheme                  = 8,
	Device_Attributes             = 9,
	Title                         = 10,
	Pwd                           = 11,
	Color_Foreground              = 12,
	Color_Background              = 13,
	Color_Cursor                  = 14,
	Color_Palette                 = 15,
	Kitty_Image_Storage_Limit     = 16,
	Kitty_Image_Medium_File       = 17,
	Kitty_Image_Medium_Temp_File  = 18,
	Kitty_Image_Medium_Shared_Mem = 19,
	Apc_Max_Bytes                 = 20,
	Apc_Max_Bytes_Kitty           = 21,
	Selection                     = 22,
	Default_Cursor_Style          = 23,
	Default_Cursor_Blink          = 24,
	Glyph_Protocol                = 25,
	Pwd_Changed                   = 26,
	Clipboard_Write               = 27,
	Scrollback_Max_Bytes          = 28,
	Scrollback_Max_Lines          = 29,
	Desktop_Notification          = 30,
	Progress_Report               = 31,
	Continuation_Max_Bytes        = 32,
	Title_Report                  = 33,
	Mode_Default                  = 34,
	Mode                          = 35,
	Unknown_Sequence              = 36,
	Unknown_Max_Bytes             = 37,
	Terminfo_Name                 = 38,
	Clipboard_Read                = 39,
	Clipboard_Write_Max_Bytes     = 40,
	Resize_Pull_Scrollback        = 41,
	Render_Hold                   = 42,
	Semantic_Prompt               = 43,
	Reset                         = 44,
	Xt_Checksum_Report            = 45,
	Xt_Checksum_Extension         = 46,
	Program_Status                = 47,
	Resize_Window                 = 48,
}

Terminal_Data :: enum i32 {
	Invalid                       = 0,
	Cols                          = 1,
	Rows                          = 2,
	Cursor_X                      = 3,
	Cursor_Y                      = 4,
	Cursor_Pending_Wrap           = 5,
	Active_Screen                 = 6,
	Cursor_Visible                = 7,
	Kitty_Keyboard_Flags          = 8,
	Scrollbar                     = 9,
	Cursor_Sgr_Style              = 10,
	Mouse_Tracking                = 11,
	Title                         = 12,
	Pwd                           = 13,
	Total_Rows                    = 14,
	Scrollback_Rows               = 15,
	Width_Px                      = 16,
	Height_Px                     = 17,
	Color_Foreground              = 18,
	Color_Background              = 19,
	Color_Cursor                  = 20,
	Color_Palette                 = 21,
	Color_Foreground_Default      = 22,
	Color_Background_Default      = 23,
	Color_Cursor_Default          = 24,
	Color_Palette_Default         = 25,
	Kitty_Image_Storage_Limit     = 26,
	Kitty_Image_Medium_File       = 27,
	Kitty_Image_Medium_Temp_File  = 28,
	Kitty_Image_Medium_Shared_Mem = 29,
	Kitty_Graphics                = 30,
	Selection                     = 31,
	Viewport_Active               = 32,
	Vt_Processing_Error           = 33,
	Scrollback_Max_Bytes          = 34,
	Scrollback_Max_Lines          = 35,
	Continuation_Max_Bytes        = 36,
	Mode                          = 37,
	Vt_Ground                     = 38,
	Cursor_At_Prompt              = 39,
	Clipboard_Write_Max_Bytes     = 40,
	Mouse_Shape                   = 41,
	Memory_Usage                  = 42,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	terminal_new :: proc(allocator: ^Allocator, terminal: ^Terminal, cols: u16, rows: u16) -> Result ---
	terminal_free :: proc(terminal: Terminal) ---
	terminal_reset :: proc(terminal: Terminal) ---
	@(require_results)
	terminal_resize :: proc(terminal: Terminal, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) -> Result ---
	@(require_results)
	terminal_set :: proc(terminal: Terminal, option: Terminal_Option, value: rawptr) -> Result ---
	terminal_vt_write :: proc(terminal: Terminal, data: [^]u8, len: uint) ---
	@(require_results)
	terminal_vt_write_until :: proc(
		terminal: Terminal,
		data: [^]u8,
		len: uint,
		boundaries: Terminal_Boundaries,
		out: ^Terminal_Write_Stop,
	) -> Result ---
	@(require_results)
	terminal_scroll_viewport :: proc(terminal: Terminal, behavior: Terminal_Scroll_Viewport) -> Result ---
	@(require_results)
	terminal_get :: proc(terminal: Terminal, data: Terminal_Data, out: rawptr) -> Result ---
	@(require_results)
	terminal_get_multi :: proc(terminal: Terminal, count: uint, keys: [^]Terminal_Data, values: [^]rawptr, out_written: ^uint) -> Result ---
	@(require_results)
	terminal_grid_ref :: proc(terminal: Terminal, point: Point, out_ref: ^Grid_Ref) -> Result ---
	@(require_results)
	terminal_point_from_grid_ref :: proc(terminal: Terminal, ref: ^Grid_Ref, tag: Point_Tag, out: ^Point_Coordinate) -> Result ---
}
