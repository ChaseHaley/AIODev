package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Terminal_Scroll_Viewport_Tag :: enum i32 {
	Top,
	Bottom,
	Delta,
	Row,
	Delta_Prompt,
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

Terminal_Cursor_Style :: enum i32 {
	Bar          = 0,
	Block        = 1,
	Underline    = 2,
	Block_Hollow = 3,
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

Terminal_Mode_Config :: struct {
	mode:  Mode,
	value: bool,
}

Terminal_Option :: enum i32 {
	Userdata                      = 0,
	Write_Pty                     = 1,
	Bell                          = 2,
	Enquiry                       = 3,
	Xtversion                     = 4,
	Title_Changed                 = 5,
	Size                          = 6,
	Color_Scheme                  = 7,
	Device_Attributes             = 8,
	Title                         = 9,
	Pwd                           = 10,
	Color_Foreground              = 11,
	Color_Background              = 12,
	Color_Cursor                  = 13,
	Color_Palette                 = 14,
	Kitty_Image_Storage_Limit     = 15,
	Kitty_Image_Medium_File       = 16,
	Kitty_Image_Medium_Temp_File  = 17,
	Kitty_Image_Medium_Shared_Mem = 18,
	Apc_Max_Bytes                 = 19,
	Apc_Max_Bytes_Kitty           = 20,
	Selection                     = 21,
	Default_Cursor_Style          = 22,
	Default_Cursor_Blink          = 23,
	Glyph_Protocol                = 24,
	Pwd_Changed                   = 25,
	Clipboard_Write               = 26,
	Scrollback_Max_Bytes          = 27,
	Scrollback_Max_Lines          = 28,
	Desktop_Notification          = 29,
	Progress_Report               = 30,
	Continuation_Max_Bytes        = 31,
	Title_Report                  = 32,
	Mode_Default                  = 33,
	Mode                          = 34,
	Unknown_Sequence              = 35,
	Unknown_Max_Bytes             = 36,
	Terminfo_Name                 = 37,
	Clipboard_Read                = 38,
	Clipboard_Write_Max_Bytes     = 39,
	Resize_Pull_Scrollback        = 40,
	Render_Hold                   = 41,
	Semantic_Prompt               = 42,
	Reset                         = 43,
	Xt_Checksum_Report            = 44,
	Xt_Checksum_Extension         = 45,
	Program_Status                = 46,
	Resize_Window                 = 47,
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
	Cursor_Style                  = 10,
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
	terminal_vt_write_until_ground :: proc(terminal: Terminal, data: [^]u8, len: uint, out_consumed: ^uint) -> Result ---
	terminal_scroll_viewport :: proc(terminal: Terminal, behavior: Terminal_Scroll_Viewport) ---
	@(require_results)
	terminal_get :: proc(terminal: Terminal, data: Terminal_Data, out: rawptr) -> Result ---
	@(require_results)
	terminal_get_multi :: proc(terminal: Terminal, count: uint, keys: [^]Terminal_Data, values: [^]rawptr, out_written: ^uint) -> Result ---
	@(require_results)
	terminal_grid_ref :: proc(terminal: Terminal, point: Point, out_ref: ^Grid_Ref) -> Result ---
	@(require_results)
	terminal_point_from_grid_ref :: proc(terminal: Terminal, ref: ^Grid_Ref, tag: Point_Tag, out: ^Point_Coordinate) -> Result ---
}
