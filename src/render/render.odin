package render

import "core:math"

Color :: [4]f32

Rect :: struct {
	x, y, width, height: f32,
}

Rect_Instance :: struct {
	rect:             Rect,
	color:            Color,
	radius, softness: f32,
	stroke:           f32,
	fill:             u32,
	// RECT_FILL_RIM only: local centre of the light, its reach, and the rim width, in pixels.
	sheen:            [4]f32,
}

// RECT_FILL_HUE_WHEEL shades a circle by hue around the center and saturation outward, with color.r as
// the HSV value. RECT_FILL_VALUE_RAMP darkens color.rgb to black at the left edge.
// RECT_FILL_RIM keeps color.rgb as a rim light: alpha follows a pointer-shaped reach at the rounded edge.
RECT_FILL_HUE_WHEEL :: u32(1)
RECT_FILL_VALUE_RAMP :: u32(2)
RECT_FILL_RIM :: u32(3)

// A glyph quad. Coverage glyphs are tinted with color; with GLYPH_COLOR set, the glyph samples the
// RGBA atlas and color.a only fades it.
Glyph_Instance :: struct {
	rect, atlas:          Rect,
	color:                Color,
	flags:                u32,
	fade_start, fade_end: f32,
	_:                    u32,
}

GLYPH_COLOR :: u32(1)
GLYPH_FADE :: u32(2)

Layer :: struct {
	clip:                                             Rect,
	radius:                                           f32,
	rect_start, rect_count, glyph_start, glyph_count: int,
}

Draw_List :: struct {
	layers: [dynamic]Layer,
	rects:  [dynamic]Rect_Instance,
	glyphs: [dynamic]Glyph_Instance,
	// The first failed write invalidates the whole list until the next build.
	error: Error,
	// Completed frames belong to this atlas; zero leaves standalone lists unbound.
	atlas_generation: u64,
	// Resetting an attempt preserves diagnostics; only healthy completion rearms them.
	failure_reported: bool,
}

Atlas_Slot :: struct {
	x, y, width, height: i32,
	generation:          u64,
	color:               bool,
}

Text_Gamma :: struct {
	gamma, enhanced_contrast: f32,
}

DEFAULT_TEXT_GAMMA :: Text_Gamma {
	gamma             = 1.8,
	enhanced_contrast = 1.0,
}

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
	Atlas_Invalidated,
	Construction_Failed,
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
	list.error = .None
	list.atlas_generation = 0
}

draw_list_destroy :: proc(list: ^Draw_List) {
	delete(list.layers)
	delete(list.rects)
	delete(list.glyphs)
	list^ = {}
}

@(require_results)
append_list :: proc(list: ^Draw_List, source: ^Draw_List) -> Error {
	if list.error != .None {return list.error}
	if source.error != .None {list.error = source.error; return list.error}
	if reserve(&list.layers, len(list.layers) + len(source.layers)) != nil ||
	   reserve(&list.rects, len(list.rects) + len(source.rects)) != nil ||
	   reserve(&list.glyphs, len(list.glyphs) + len(source.glyphs)) != nil {
		list.error = .Out_Of_Memory
		return list.error
	}
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
push_layer :: proc(list: ^Draw_List, clip: Rect, radius: f32 = 0) -> Error {
	if list.error != .None {return list.error}
	layer := Layer {
		clip        = clip,
		radius      = radius,
		rect_start  = len(list.rects),
		glyph_start = len(list.glyphs),
	}
	if _, err := append(&list.layers, layer); err != nil {
		list.error = .Out_Of_Memory
	}
	return list.error
}

@(require_results)
push_rect :: proc(list: ^Draw_List, instance: Rect_Instance) -> Error {
	if list.error != .None {return list.error}
	assert(len(list.layers) > 0, "push_layer must precede push_rect")
	if _, err := append(&list.rects, instance); err != nil {
		list.error = .Out_Of_Memory
		return list.error
	}
	list.layers[len(list.layers) - 1].rect_count += 1
	return .None
}

@(require_results)
push_glyph :: proc(list: ^Draw_List, instance: Glyph_Instance) -> Error {
	if list.error != .None {return list.error}
	assert(len(list.layers) > 0, "push_layer must precede push_glyph")
	if _, err := append(&list.glyphs, instance); err != nil {
		list.error = .Out_Of_Memory
		return list.error
	}
	list.layers[len(list.layers) - 1].glyph_count += 1
	return .None
}

@(private)
GAMMA_INCORRECT_TARGET_RATIOS :: [13][4]f32 {
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
	@(static, rodata)
	table := GAMMA_INCORRECT_TARGET_RATIOS
	index := int(math.round((clamp(gamma, 1, 2.2) - 1) * 10))
	r := table[index]
	return {NORM13 * r[0], NORM24 * r[1], NORM13 * r[2], NORM24 * r[3]}
}
