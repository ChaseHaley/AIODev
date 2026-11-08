package render

import "core:math"

Color :: [4]f32

Rect :: struct {
	x, y, width, height: f32,
}

// Half-open containment: the left and top edges are inside, the right and bottom edges are not, so
// adjacent rectangles never both claim a point and an empty rectangle contains nothing.
rect_contains :: proc(r: Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

// What drawing into a frame under construction reports. Atlas_Reset means the atlas was emptied
// to make room: every glyph and icon already placed in the frame is stale, so the caller stops
// drawing and lets Frame_Build start the next attempt.
Build_Status :: enum {
	Ok,
	Atlas_Reset,
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

// Rect_Instance and Glyph_Instance are read by draw.hlsl as StructuredBuffer elements, which pack
// four-byte scalars without padding. The shader's RectInstance and GlyphInstance list these fields
// in the same order.
#assert(size_of(Rect_Instance) == 64 && offset_of(Rect_Instance, fill) == 44)
#assert(offset_of(Rect_Instance, sheen) == 48)

// The fill and glyph flag values below reach draw.hlsl as same-named macros (see shader_macros), so
// the shader cannot drift from them.
//
// RECT_FILL_HUE_WHEEL shades a circle by hue around the center and saturation outward, with color.r as
// the HSV value. RECT_FILL_VALUE_RAMP darkens color.rgb to black at the left edge.
// RECT_FILL_RIM keeps color.rgb as a rim light: alpha follows a pointer-shaped reach at the rounded edge.
RECT_FILL_HUE_WHEEL :: u32(1)
RECT_FILL_VALUE_RAMP :: u32(2)
RECT_FILL_RIM :: u32(3)
// Round-capped strokes of width `stroke`. SEGMENT runs from sheen.xy to sheen.zw; ARC is centred on
// sheen.xy with `radius`, starting at angle sheen.z and sweeping sheen.w radians clockwise on screen.
// Both are in pixels local to `rect`, which must contain the stroke.
RECT_FILL_SEGMENT :: u32(4)
RECT_FILL_ARC :: u32(5)

// A glyph quad. Coverage glyphs are tinted with color; with GLYPH_COLOR set, the glyph samples the
// RGBA atlas and color.a only fades it.
Glyph_Instance :: struct {
	rect, atlas:          Rect,
	color:                Color,
	flags:                u32,
	fade_start, fade_end: f32,
	_:                    u32,
}

#assert(size_of(Glyph_Instance) == 64 && offset_of(Glyph_Instance, flags) == 48)

GLYPH_COLOR :: u32(1)
GLYPH_FADE :: u32(2)

// A textured quad. `key` names a texture from image_upload; `uv` is the part of it to show, in 0..1.
Image_Instance :: struct {
	rect, uv: Rect,
	key:      u64,
}

// A layer draws its rects, then its images, then its glyphs.
Layer :: struct {
	clip:                                             Rect,
	radius:                                           f32,
	rect_start, rect_count, glyph_start, glyph_count: int,
	image_start, image_count:                         int,
}

Draw_List :: struct {
	layers: [dynamic]Layer,
	rects:  [dynamic]Rect_Instance,
	glyphs: [dynamic]Glyph_Instance,
	images: [dynamic]Image_Instance,
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

// Text_Gamma carries DirectWrite's grayscale text rendering parameters from font to the renderer.
Text_Gamma :: struct {
	gamma, enhanced_contrast: f32,
}

DEFAULT_TEXT_GAMMA :: Text_Gamma {
	gamma             = 1.8,
	enhanced_contrast = 1.0,
}

// The gamma range GAMMA_INCORRECT_TARGET_RATIOS covers, one row per tenth.
@(private)
MIN_TEXT_GAMMA :: 1
@(private)
MAX_TEXT_GAMMA :: 2.2

Error :: enum {
	None,
	Invalid_Argument,
	Out_Of_Memory,
	Device_Failed,
	Device_Lost,
	Shader_Failed,
	Surface_Failed,
	Wait_Failed,
	Atlas_Invalidated,
	Construction_Failed,
}

draw_list_init :: proc(allocator := context.allocator) -> Draw_List {
	return {
		layers = make([dynamic]Layer, allocator),
		rects = make([dynamic]Rect_Instance, allocator),
		glyphs = make([dynamic]Glyph_Instance, allocator),
		images = make([dynamic]Image_Instance, allocator),
	}
}

draw_list_reset :: proc(list: ^Draw_List) {
	clear(&list.layers)
	clear(&list.rects)
	clear(&list.glyphs)
	clear(&list.images)
	list.error = .None
	list.atlas_generation = 0
}

draw_list_destroy :: proc(list: ^Draw_List) {
	delete(list.layers)
	delete(list.rects)
	delete(list.glyphs)
	delete(list.images)
	list^ = {}
}

@(require_results)
append_list :: proc(list: ^Draw_List, source: ^Draw_List) -> Error {
	if list.error != .None {return list.error}
	if source.error != .None {list.error = source.error; return list.error}
	if reserve(&list.layers, len(list.layers) + len(source.layers)) != nil ||
	   reserve(&list.rects, len(list.rects) + len(source.rects)) != nil ||
	   reserve(&list.glyphs, len(list.glyphs) + len(source.glyphs)) != nil ||
	   reserve(&list.images, len(list.images) + len(source.images)) != nil {
		list.error = .Out_Of_Memory
		return list.error
	}
	rect_offset, glyph_offset := len(list.rects), len(list.glyphs)
	image_offset := len(list.images)
	append(&list.rects, ..source.rects[:])
	append(&list.glyphs, ..source.glyphs[:])
	append(&list.images, ..source.images[:])
	for layer in source.layers {
		adjusted := layer
		adjusted.rect_start += rect_offset
		adjusted.glyph_start += glyph_offset
		adjusted.image_start += image_offset
		append(&list.layers, adjusted)
	}
	return .None
}

// Where drawing into a list stood, so a later pass can move or fade only what was drawn after it.
Draw_Mark :: struct {
	layers, rects, glyphs, images: int,
}

draw_mark :: proc(list: ^Draw_List) -> Draw_Mark {
	return {len(list.layers), len(list.rects), len(list.glyphs), len(list.images)}
}

// Moves everything drawn since `mark` by `offset` and keeps it inside `clip`.
draw_translate :: proc(list: ^Draw_List, mark: Draw_Mark, offset: [2]f32, clip: Rect) {
	for &layer in list.layers[mark.layers:] {
		c := layer.clip
		left, top := max(c.x + offset.x, clip.x), max(c.y + offset.y, clip.y)
		right := min(c.x + offset.x + c.width, clip.x + clip.width)
		bottom := min(c.y + offset.y + c.height, clip.y + clip.height)
		layer.clip = {left, top, max(0, right - left), max(0, bottom - top)}
	}
	for &rect in list.rects[mark.rects:] {rect.rect.x += offset.x; rect.rect.y += offset.y}
	for &glyph in list.glyphs[mark.glyphs:] {
		glyph.rect.x += offset.x
		glyph.rect.y += offset.y
		glyph.fade_start += offset.x
		glyph.fade_end += offset.x
	}
	for &image in list.images[mark.images:] {image.rect.x += offset.x; image.rect.y += offset.y}
}

// Appends what `source` drew between `from` and `to` to `list`, as a copy that outlives `source`'s next
// build. The range must start with a layer, so every instance in it belongs to one of its layers.
@(require_results)
draw_list_copy :: proc(list: ^Draw_List, source: ^Draw_List, from, to: Draw_Mark) -> Error {
	if list.error != .None {return list.error}
	base := draw_mark(list)
	if _, err := append(&list.rects, ..source.rects[from.rects:to.rects]); err != nil {
		list.error = .Out_Of_Memory
	}
	if _, err := append(&list.glyphs, ..source.glyphs[from.glyphs:to.glyphs]); err != nil {
		list.error = .Out_Of_Memory
	}
	if _, err := append(&list.images, ..source.images[from.images:to.images]); err != nil {
		list.error = .Out_Of_Memory
	}
	for layer in source.layers[from.layers:to.layers] {
		copied := layer
		// Drawing after the range may have gone on into its last layer; the copy keeps only the range.
		copied.rect_count = clamp(to.rects - layer.rect_start, 0, layer.rect_count)
		copied.glyph_count = clamp(to.glyphs - layer.glyph_start, 0, layer.glyph_count)
		copied.image_count = clamp(to.images - layer.image_start, 0, layer.image_count)
		copied.rect_start += base.rects - from.rects
		copied.glyph_start += base.glyphs - from.glyphs
		copied.image_start += base.images - from.images
		if _, err := append(&list.layers, copied); err != nil {list.error = .Out_Of_Memory}
	}
	return list.error
}

@(require_results)
push_layer :: proc(list: ^Draw_List, clip: Rect, radius: f32 = 0) -> Error {
	if list.error != .None {return list.error}
	layer := Layer {
		clip        = clip,
		radius      = radius,
		rect_start  = len(list.rects),
		glyph_start = len(list.glyphs),
		image_start = len(list.images),
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
push_segment :: proc(list: ^Draw_List, a, b: [2]f32, width: f32, color: Color) -> Error {
	half := width / 2
	lo := [2]f32{min(a.x, b.x), min(a.y, b.y)} - half
	hi := [2]f32{max(a.x, b.x), max(a.y, b.y)} + half
	return push_rect(
		list,
		{
			rect = {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y},
			color = color,
			stroke = width,
			fill = RECT_FILL_SEGMENT,
			sheen = {a.x - lo.x, a.y - lo.y, b.x - lo.x, b.y - lo.y},
		},
	)
}

@(require_results)
push_arc :: proc(list: ^Draw_List, center: [2]f32, radius, start, sweep, width: f32, color: Color) -> Error {
	extent := radius + width / 2
	return push_rect(
		list,
		{
			rect = {center.x - extent, center.y - extent, 2 * extent, 2 * extent},
			color = color,
			radius = radius,
			stroke = width,
			fill = RECT_FILL_ARC,
			sheen = {extent, extent, start, sweep},
		},
	)
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

@(require_results)
push_image :: proc(list: ^Draw_List, instance: Image_Instance) -> Error {
	if list.error != .None {return list.error}
	assert(len(list.layers) > 0, "push_layer must precede push_image")
	if _, err := append(&list.images, instance); err != nil {
		list.error = .Out_Of_Memory
		return list.error
	}
	list.layers[len(list.layers) - 1].image_count += 1
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
	index := int(math.round((clamp(gamma, MIN_TEXT_GAMMA, MAX_TEXT_GAMMA) - MIN_TEXT_GAMMA) * 10))
	r := table[index]
	return {NORM13 * r[0], NORM24 * r[1], NORM13 * r[2], NORM24 * r[3]}
}
