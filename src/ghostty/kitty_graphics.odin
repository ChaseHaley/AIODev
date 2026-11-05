package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Kitty_Graphics :: distinct rawptr

Kitty_Graphics_Image :: distinct rawptr

Kitty_Graphics_Placement_Iterator :: distinct rawptr

Kitty_Graphics_Data :: enum i32 {
	Invalid            = 0,
	Placement_Iterator = 1,
	Generation         = 2,
}

Kitty_Graphics_Placement_Data :: enum i32 {
	Invalid       = 0,
	Image_Id      = 1,
	Placement_Id  = 2,
	Is_Virtual    = 3,
	X_Offset      = 4,
	Y_Offset      = 5,
	Source_X      = 6,
	Source_Y      = 7,
	Source_Width  = 8,
	Source_Height = 9,
	Columns       = 10,
	Rows          = 11,
	Z             = 12,
}

Kitty_Image_Format :: enum i32 {
	Rgb        = 0,
	Rgba       = 1,
	Png        = 2,
	Gray_Alpha = 3,
	Gray       = 4,
}

Kitty_Graphics_Image_Data :: enum i32 {
	Invalid     = 0,
	Id          = 1,
	Number      = 2,
	Width       = 3,
	Height      = 4,
	Format      = 5,
	Compression = 6,
	Data_Ptr    = 7,
	Data_Len    = 8,
	Generation  = 9,
}

Kitty_Graphics_Placement_Render_Info :: struct {
	size:             uint,
	pixel_width:      u32,
	pixel_height:     u32,
	grid_cols:        u32,
	grid_rows:        u32,
	viewport_col:     i32,
	viewport_row:     i32,
	viewport_visible: bool,
	source_x:         u32,
	source_y:         u32,
	source_width:     u32,
	source_height:    u32,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	kitty_graphics_get :: proc(graphics: Kitty_Graphics, data: Kitty_Graphics_Data, out: rawptr) -> Result ---
	@(require_results)
	kitty_graphics_image :: proc(graphics: Kitty_Graphics, image_id: u32) -> Kitty_Graphics_Image ---
	@(require_results)
	kitty_graphics_image_get_multi :: proc(image: Kitty_Graphics_Image, count: uint, keys: [^]Kitty_Graphics_Image_Data, values: [^]rawptr, out_written: ^uint) -> Result ---
	@(require_results)
	kitty_graphics_placement_iterator_new :: proc(allocator: ^Allocator, out_iterator: ^Kitty_Graphics_Placement_Iterator) -> Result ---
	kitty_graphics_placement_iterator_free :: proc(iterator: Kitty_Graphics_Placement_Iterator) ---
	@(require_results)
	kitty_graphics_placement_next :: proc(iterator: Kitty_Graphics_Placement_Iterator) -> bool ---
	@(require_results)
	kitty_graphics_placement_get_multi :: proc(iterator: Kitty_Graphics_Placement_Iterator, count: uint, keys: [^]Kitty_Graphics_Placement_Data, values: [^]rawptr, out_written: ^uint) -> Result ---
	@(require_results)
	kitty_graphics_placement_render_info :: proc(iterator: Kitty_Graphics_Placement_Iterator, image: Kitty_Graphics_Image, terminal: Terminal, out_info: ^Kitty_Graphics_Placement_Render_Info) -> Result ---
}
