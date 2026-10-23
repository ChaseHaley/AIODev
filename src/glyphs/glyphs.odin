package glyphs

import "aio:font"
import "aio:render"
import "base:runtime"
import "core:log"
import "core:math"

Sprite :: enum u8 {
	Curly_Underline,
	Dotted_Underline,
	Dashed_Underline,
}

// Where a glyph or sprite sits in the atlas and how to place it relative to the pen position on the baseline.
Entry :: struct {
	atlas:  render.Rect,
	offset: [2]f32,
	size:   [2]f32,
	// The atlas rect is in the RGBA atlas and the glyph draws in its own colors.
	color:  bool,
}

Result :: enum {
	Ok,
	Atlas_Reset,
}

Cache :: struct {
	allocator:  runtime.Allocator,
	fonts:      ^font.System,
	device:     ^render.Device,
	glyphs:     map[Glyph_Key]Entry,
	sprites:    map[Sprite_Key]Entry,
	generation: u64,
	hits:       u64,
	misses:     u64,
}

@(private)
Glyph_Key :: struct {
	face:   font.Face_Id,
	index:  u16,
	size_q: u32,
	color:  bool,
}

@(private)
Sprite_Key :: struct {
	sprite:                   Sprite,
	width, height, thickness: u16,
}

init :: proc(
	c: ^Cache,
	fonts: ^font.System,
	device: ^render.Device,
	allocator := context.allocator,
) {
	c^ = {
		allocator  = allocator,
		fonts      = fonts,
		device     = device,
		glyphs     = make(map[Glyph_Key]Entry, allocator),
		sprites    = make(map[Sprite_Key]Entry, allocator),
		generation = render.atlas_generation(device),
	}
}

destroy :: proc(c: ^Cache) {
	delete(c.glyphs)
	delete(c.sprites)
	c^ = {}
}

// Points the cache at a new device after device loss; every entry belongs to the old atlas.
reset_device :: proc(c: ^Cache, device: ^render.Device) {
	c.device = device
	forget(c)
}

@(private)
forget :: proc(c: ^Cache) {
	clear(&c.glyphs)
	clear(&c.sprites)
	c.generation = render.atlas_generation(c.device)
}

@(private)
validate :: proc(c: ^Cache) {
	if c.generation != render.atlas_generation(c.device) {
		forget(c)
	}
}

// Reserves atlas space and uploads pixels. When the atlas is full it is reset, every entry is
// forgotten, and the caller must rebuild the frame because entries it already used are stale.
@(private)
upload :: proc(
	c: ^Cache,
	width, height: i32,
	pixels: []u8,
	color := false,
) -> (
	render.Rect,
	Result,
) {
	slot, ok := render.atlas_reserve(c.device, width, height, color)
	if !ok {
		render.atlas_reset(c.device)
		forget(c)
		return {}, .Atlas_Reset
	}
	render.atlas_upload(c.device, slot, pixels, int(width))
	return {f32(slot.x), f32(slot.y), f32(width), f32(height)}, .Ok
}

// With color set, a glyph the font draws in color is cached as RGBA and its entry reports color.
glyph :: proc(c: ^Cache, g: font.Glyph, size_px: f32, color := false) -> (Entry, Result) {
	validate(c)
	key := Glyph_Key{g.face, g.index, u32(math.round(size_px * g.scale * 64)), color}
	if entry, found := c.glyphs[key]; found {
		c.hits += 1
		return entry, .Ok
	}
	c.misses += 1
	bitmap, err := font.glyph_rasterize(c.fonts, g, size_px, c.allocator, color)
	if err != .None {
		log.errorf("glyphs: rasterizing glyph %v of face %v failed: %v", g.index, g.face, err)
		c.glyphs[key] = {}
		return {}, .Ok
	}
	defer font.bitmap_destroy(&bitmap, c.allocator)
	entry: Entry
	if bitmap.width > 0 && bitmap.height > 0 {
		rect, result := upload(c, bitmap.width, bitmap.height, bitmap.pixels, bitmap.color)
		if result != .Ok {
			return {}, result
		}
		entry = {
			atlas  = rect,
			offset = {f32(bitmap.left), -f32(bitmap.top)},
			size   = {f32(bitmap.width), f32(bitmap.height)},
			color  = bitmap.color,
		}
	}
	c.glyphs[key] = entry
	return entry, .Ok
}

// glyph_counts reports glyph() atlas lookups since the cache was created: hits reused an entry,
// misses rasterized and uploaded one. Sprites (underline decorations) are not counted. Rendering
// owns both counters, so a diagnostics read needs no lock.
@(require_results)
glyph_counts :: proc(c: ^Cache) -> (hits, misses: u64) {
	return c.hits, c.misses
}

// reset_counts clears the lookup totals for a diagnostics reset.
reset_counts :: proc(c: ^Cache) {
	c.hits, c.misses = 0, 0
}

// Returns a cell-wide decoration; its offset centers it vertically on the pen position.
sprite :: proc(c: ^Cache, kind: Sprite, cell_width, thickness: f32) -> (Entry, Result) {
	validate(c)
	t := max(1, u16(math.round(thickness)))
	w := max(1, u16(cell_width))
	h := t * 4
	key := Sprite_Key{kind, w, h, t}
	if entry, found := c.sprites[key]; found {
		return entry, .Ok
	}
	pixels := make([]u8, int(w) * int(h), context.temp_allocator)
	draw_sprite(kind, int(w), int(h), f32(t), pixels)
	rect, result := upload(c, i32(w), i32(h), pixels)
	if result != .Ok {
		return {}, result
	}
	entry := Entry {
		atlas  = rect,
		offset = {0, -f32(h) / 2},
		size   = {f32(w), f32(h)},
	}
	c.sprites[key] = entry
	return entry, .Ok
}

@(private)
draw_sprite :: proc(kind: Sprite, width, height: int, thickness: f32, pixels: []u8) {
	center := f32(height) / 2
	switch kind {
	case .Curly_Underline:
		amplitude := center - thickness / 2 - 0.5
		for y in 0 ..< height {
			for x in 0 ..< width {
				phase := (f32(x) + 0.5) / f32(width) * 2 * math.PI
				curve := center + amplitude * math.sin(phase)
				distance :=
					abs(f32(y) + 0.5 - curve) *
					math.cos(math.atan(amplitude * 2 * math.PI / f32(width)))
				coverage := clamp(thickness / 2 + 0.5 - distance, 0, 1)
				pixels[y * width + x] = u8(coverage * 255)
			}
		}
	case .Dotted_Underline, .Dashed_Underline:
		top := int(center - thickness / 2)
		segment := kind == .Dotted_Underline ? max(1, int(thickness)) : max(2, width / 3)
		for y in top ..< min(height, top + int(thickness)) {
			for x in 0 ..< width {
				on := (x / segment) % 2 == 0
				pixels[y * width + x] = on ? 255 : 0
			}
		}
	}
}
