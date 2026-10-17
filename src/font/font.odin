package font

import "base:runtime"

Style :: enum u8 {
	Regular,
	Bold,
	Italic,
	Bold_Italic,
}

Face_Id :: distinct u32

Family :: struct {
	faces: [Style]Face_Id,
}

Glyph :: struct {
	face: Face_Id,
	index: u16,
	scale, advance_em: f32,
}

Face_Metrics :: struct {
	ascent, descent, line_gap: f32,
	underline_position, underline_thickness: f32,
	strikethrough_position, strikethrough_thickness: f32,
	cap_height: f32,
}

Bitmap :: struct {
	pixels: []u8,
	width, height: i32,
	left, top: i32,
}

Text_Gamma :: struct {
	gamma, enhanced_contrast: f32,
}

Error :: enum {
	None,
	Out_Of_Memory,
	Invalid_Argument,
	Family_Not_Found,
	DirectWrite,
}

bitmap_destroy :: proc(bitmap: ^Bitmap, allocator: runtime.Allocator) {
	if bitmap != nil {
		delete(bitmap.pixels, allocator)
		bitmap^ = {}
	}
}
