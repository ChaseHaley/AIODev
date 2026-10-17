package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Style_Id :: u16

Style_Color_Tag :: enum i32 {
	None = 0,
	Palette = 1,
	Rgb = 2,
}

Style_Color_Value :: struct #raw_union {
	palette: Color_Palette_Index,
	rgb: Color_Rgb,
	_padding: u64,
}

Style_Color :: struct {
	tag: Style_Color_Tag,
	value: Style_Color_Value,
}

Style :: struct {
	size: uint,
	fg_color: Style_Color,
	bg_color: Style_Color,
	underline_color: Style_Color,
	bold: bool,
	italic: bool,
	faint: bool,
	blink: bool,
	inverse: bool,
	invisible: bool,
	strikethrough: bool,
	overline: bool,
	underline: i32,
}

@(default_calling_convention="c", link_prefix="ghostty_")
foreign lib {
	style_default :: proc(style: ^Style) ---
	@(require_results)
	style_is_default :: proc(style: ^Style) -> bool ---
}
