package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Cell :: u64

Row :: u64

Cells_View :: struct {
	ptr: ^Cell,
	len: uint,
}

Cell_Content_Tag :: enum i32 {
	Codepoint          = 0,
	Codepoint_Grapheme = 1,
	Bg_Color_Palette   = 2,
	Bg_Color_Rgb       = 3,
}

Cell_Wide :: enum i32 {
	Narrow      = 0,
	Wide        = 1,
	Spacer_Tail = 2,
	Spacer_Head = 3,
}

Cell_Semantic_Content :: enum i32 {
	Output = 0,
	Input  = 1,
	Prompt = 2,
}

Cell_Data :: enum i32 {
	Invalid          = 0,
	Codepoint        = 1,
	Content_Tag      = 2,
	Wide             = 3,
	Has_Text         = 4,
	Has_Styling      = 5,
	Style_Id         = 6,
	Has_Hyperlink    = 7,
	Protected        = 8,
	Semantic_Content = 9,
	Color_Palette    = 10,
	Color_Rgb        = 11,
}

Row_Semantic_Prompt :: enum i32 {
	None                = 0,
	Prompt              = 1,
	Prompt_Continuation = 2,
}

Row_Data :: enum i32 {
	Invalid                   = 0,
	Wrap                      = 1,
	Wrap_Continuation         = 2,
	Grapheme                  = 3,
	Styled                    = 4,
	Hyperlink                 = 5,
	Semantic_Prompt           = 6,
	Kitty_Virtual_Placeholder = 7,
	Dirty                     = 8,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	cell_get :: proc(cell: Cell, data: Cell_Data, out: rawptr) -> Result ---
	@(require_results)
	cell_get_multi :: proc(cell: Cell, count: uint, keys: [^]Cell_Data, values: [^]rawptr, out_written: ^uint) -> Result ---
	@(require_results)
	row_get :: proc(row: Row, data: Row_Data, out: rawptr) -> Result ---
	@(require_results)
	row_get_multi :: proc(row: Row, count: uint, keys: [^]Row_Data, values: [^]rawptr, out_written: ^uint) -> Result ---
}
