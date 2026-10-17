package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Grid_Ref :: struct {
	size: uint,
	node: rawptr,
	x: u16,
	y: u16,
}

@(default_calling_convention="c", link_prefix="ghostty_")
foreign lib {
	@(require_results)
	grid_ref_cell :: proc(ref: ^Grid_Ref, out_cell: ^Cell) -> Result ---
	@(require_results)
	grid_ref_row :: proc(ref: ^Grid_Ref, out_row: ^Row) -> Result ---
	@(require_results)
	grid_ref_graphemes :: proc(ref: ^Grid_Ref, buf: [^]u32, buf_len: uint, out_len: ^uint) -> Result ---
	@(require_results)
	grid_ref_hyperlink_uri :: proc(ref: ^Grid_Ref, buf: [^]u8, buf_len: uint, out_len: ^uint) -> Result ---
	@(require_results)
	grid_ref_style :: proc(ref: ^Grid_Ref, out_style: ^Style) -> Result ---
}
