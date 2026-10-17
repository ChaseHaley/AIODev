package render

import "core:math"

Color :: [4]f32

Rect :: struct {
	x, y, width, height: f32,
}

Rect_Instance :: struct {
	rect: Rect,
	color: Color,
	radius, softness: f32,
}

// A glyph quad. Coverage glyphs are tinted with color; with GLYPH_COLOR set, the glyph samples the
// RGBA atlas and color.a only fades it.
Glyph_Instance :: struct {
	rect, atlas: Rect,
	color: Color,
	flags: u32,
	_: [3]u32,
}

GLYPH_COLOR :: u32(1)

Layer :: struct {
	clip: Rect,
	rect_start, rect_count, glyph_start, glyph_count: int,
}

Draw_List :: struct {
	layers: [dynamic]Layer,
	rects: [dynamic]Rect_Instance,
	glyphs: [dynamic]Glyph_Instance,
}

Atlas_Slot :: struct {
	x, y, width, height: i32,
	generation: u64,
	color: bool,
}

Text_Gamma :: struct {
	gamma, enhanced_contrast: f32,
}

DEFAULT_TEXT_GAMMA :: Text_Gamma{gamma = 1.8, enhanced_contrast = 1.0}

Error :: enum {
	None,
	Invalid_Argument,
	Out_Of_Memory,
	Device_Failed,
	Device_Lost,
	Shader_Failed,
	Surface_Failed,
	Wait_Failed,
	Timeout,
}

draw_list_init :: proc(allocator := context.allocator) -> Draw_List {
	return {
		layers = make([dynamic]Layer, allocator),
		rects = make([dynamic]Rect_Instance, allocator),
		glyphs = make([dynamic]Glyph_Instance, allocator),
	}
}

draw_list_reset :: proc(list: ^Draw_List) {
	clear(&list.layers)
	clear(&list.rects)
	clear(&list.glyphs)
}

draw_list_destroy :: proc(list: ^Draw_List) {
	delete(list.layers)
	delete(list.rects)
	delete(list.glyphs)
	list^ = {}
}

@(require_results)
append_list :: proc(list: ^Draw_List, source: ^Draw_List) -> Error {
	if reserve(&list.layers, len(list.layers)+len(source.layers)) != nil ||
	   reserve(&list.rects, len(list.rects)+len(source.rects)) != nil ||
	   reserve(&list.glyphs, len(list.glyphs)+len(source.glyphs)) != nil { return .Out_Of_Memory }
	rect_offset, glyph_offset := len(list.rects), len(list.glyphs)
	append(&list.rects, ..source.rects[:])
	append(&list.glyphs, ..source.glyphs[:])
	for layer in source.layers {
		adjusted := layer
		adjusted.rect_start += rect_offset
		adjusted.glyph_start += glyph_offset
		append(&list.layers, adjusted)
	}
	return .None
}

@(require_results)
push_layer :: proc(list: ^Draw_List, clip: Rect) -> Error {
	layer := Layer{clip = clip, rect_start = len(list.rects), glyph_start = len(list.glyphs)}
	if _, err := append(&list.layers, layer); err != nil {
		return .Out_Of_Memory
	}
	return .None
}

@(require_results)
push_rect :: proc(list: ^Draw_List, instance: Rect_Instance) -> Error {
	assert(len(list.layers) > 0, "push_layer must precede push_rect")
	if _, err := append(&list.rects, instance); err != nil {
		return .Out_Of_Memory
	}
	list.layers[len(list.layers)-1].rect_count += 1
	return .None
}

@(require_results)
push_glyph :: proc(list: ^Draw_List, instance: Glyph_Instance) -> Error {
	assert(len(list.layers) > 0, "push_layer must precede push_glyph")
	if _, err := append(&list.glyphs, instance); err != nil {
		return .Out_Of_Memory
	}
	list.layers[len(list.layers)-1].glyph_count += 1
	return .None
}

@(private)
GAMMA_INCORRECT_TARGET_RATIOS :: [13][4]f32{
	{0.0000 / 4, 0.0000 / 4, 0.0000 / 4, 0.0000 / 4},
	{0.0166 / 4, -0.0807 / 4, 0.2227 / 4, -0.0751 / 4},
	{0.0350 / 4, -0.1760 / 4, 0.4325 / 4, -0.1370 / 4},
	{0.0543 / 4, -0.2821 / 4, 0.6302 / 4, -0.1876 / 4},
	{0.0739 / 4, -0.3963 / 4, 0.8167 / 4, -0.2287 / 4},
	{0.0933 / 4, -0.5161 / 4, 0.9926 / 4, -0.2616 / 4},
	{0.1121 / 4, -0.6395 / 4, 1.1588 / 4, -0.2877 / 4},
	{0.1300 / 4, -0.7649 / 4, 1.3159 / 4, -0.3080 / 4},
	{0.1469 / 4, -0.8911 / 4, 1.4644 / 4, -0.3234 / 4},
	{0.1627 / 4, -1.0170 / 4, 1.6051 / 4, -0.3347 / 4},
	{0.1773 / 4, -1.1420 / 4, 1.7385 / 4, -0.3426 / 4},
	{0.1908 / 4, -1.2652 / 4, 1.8650 / 4, -0.3476 / 4},
	{0.2031 / 4, -1.3864 / 4, 1.9851 / 4, -0.3501 / 4},
}

// DirectWrite's fitted gamma correction, after microsoft/terminal src/renderer/atlas/dwrite.cpp (MIT).
gamma_ratios :: proc(gamma: f32) -> [4]f32 {
	NORM13 :: f32(f64(0x10000) / (255 * 255) * 4)
	NORM24 :: f32(f64(0x100) / 255 * 4)
	@(static, rodata) table := GAMMA_INCORRECT_TARGET_RATIOS
	index := int(math.round((clamp(gamma, 1, 2.2) - 1) * 10))
	r := table[index]
	return {NORM13 * r[0], NORM24 * r[1], NORM13 * r[2], NORM24 * r[3]}
}
