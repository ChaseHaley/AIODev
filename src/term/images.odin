package term

import "aio:ghostty"
import "base:runtime"
import "core:image/png"
import "core:log"
import "core:mem"
import "core:slice"
import "core:sync"

// Kitty graphics. libghostty parses the protocol and owns image storage; this file installs what it
// needs from an embedder and reads placements out for drawing. Transmission stays direct-only, the
// libghostty default: output arriving over SSH must not make the local terminal open local files.

// Per screen, so one terminal can hold twice this. A program cannot exceed it: libghostty evicts.
IMAGE_STORAGE_LIMIT :: u64(320 << 20)

Image_Layer :: enum u8 {
	Below_Background,
	Below_Text,
	Above_Text,
}

// One visible placement in viewport cells and image pixels. `generation` identifies the pixels and
// is unique across every terminal in the process, so a texture cache can key on it alone.
Image_Placement :: struct {
	image_id:                  u32,
	generation:                u64,
	image_width, image_height: u32,
	layer:                     Image_Layer,
	z:                         i32,
	// May be negative for an image partly scrolled off the top; the layer's clip trims it.
	column, row:               i32,
	offset_x, offset_y:        u32,
	width, height:             u32,
	source_x, source_y:        u32,
	source_width:              u32,
	source_height:             u32,
}

// What one view reads each frame. The iterator stays with the view because it is reused.
Image_Capture :: struct {
	iterator:   ghostty.Kitty_Graphics_Placement_Iterator,
	placements: [dynamic]Image_Placement,
}

@(require_results)
image_capture_create :: proc(c: ^Image_Capture, allocator := context.allocator) -> bool {
	c.placements = make([dynamic]Image_Placement, allocator)
	return ghostty.kitty_graphics_placement_iterator_new(nil, &c.iterator) == .Success
}

image_capture_destroy :: proc(c: ^Image_Capture) {
	ghostty.kitty_graphics_placement_iterator_free(c.iterator)
	delete(c.placements)
	c^ = {}
}

// image_layer applies the protocol's z convention: far below zero is under cell backgrounds,
// negative is above backgrounds and under text, and the rest is above text.
@(require_results)
image_layer :: proc(z: i32) -> Image_Layer {
	if z < min(i32) / 2 {return .Below_Background}
	return z < 0 ? .Below_Text : .Above_Text
}

// Called with the session mutex held, in the same critical section as the render-state update, so
// images and text agree on the viewport. A terminal that never stored an image stops at the check.
@(private)
collect_images :: proc(s: ^Session, c: ^Image_Capture) {
	clear(&c.placements)
	graphics: ghostty.Kitty_Graphics
	if ghostty.terminal_get(s.terminal, .Kitty_Graphics, &graphics) != .Success {return}
	generation: u64
	if ghostty.kitty_graphics_get(graphics, .Generation, &generation) != .Success || generation == 0 {
		return
	}
	if ghostty.kitty_graphics_get(graphics, .Placement_Iterator, &c.iterator) != .Success {return}
	for ghostty.kitty_graphics_placement_next(c.iterator) {
		p: Image_Placement
		placement_keys := [?]ghostty.Kitty_Graphics_Placement_Data {
			.Image_Id,
			.X_Offset,
			.Y_Offset,
			.Z,
		}
		placement_values := [?]rawptr{&p.image_id, &p.offset_x, &p.offset_y, &p.z}
		if ghostty.kitty_graphics_placement_get_multi(
			   c.iterator,
			   len(placement_keys),
			   &placement_keys[0],
			   &placement_values[0],
			   nil,
		   ) !=
		   .Success {continue}
		image := ghostty.kitty_graphics_image(graphics, p.image_id)
		if image == nil {continue}
		info := ghostty.sized(ghostty.Kitty_Graphics_Placement_Render_Info)
		if ghostty.kitty_graphics_placement_render_info(c.iterator, image, s.terminal, &info) !=
		   .Success {continue}
		if !info.viewport_visible || info.pixel_width == 0 || info.pixel_height == 0 {continue}
		image_keys := [?]ghostty.Kitty_Graphics_Image_Data{.Generation, .Width, .Height}
		image_values := [?]rawptr{&p.generation, &p.image_width, &p.image_height}
		if ghostty.kitty_graphics_image_get_multi(
			   image,
			   len(image_keys),
			   &image_keys[0],
			   &image_values[0],
			   nil,
		   ) !=
		   .Success {continue}
		if p.image_width == 0 || p.image_height == 0 {continue}
		p.layer = image_layer(p.z)
		p.column, p.row = info.viewport_col, info.viewport_row
		p.width, p.height = info.pixel_width, info.pixel_height
		p.source_x, p.source_y = info.source_x, info.source_y
		p.source_width, p.source_height = info.source_width, info.source_height
		if _, err := append(&c.placements, p); err != nil {
			log.error("term: out of memory reading image placements")
			return
		}
	}
	// Equal z keeps the protocol's order, so an image stays where its siblings expect it.
	slice.stable_sort_by(c.placements[:], proc(a, b: Image_Placement) -> bool {return a.z < b.z})
}

// image_pixels copies one image out as premultiplied RGBA, the format textures hold. It returns
// false when the image was replaced since the placement was read or its payload has not arrived;
// either way a later frame sees the new state.
@(require_results)
image_pixels :: proc(
	s: ^Session,
	image_id: u32,
	generation: u64,
	allocator := context.allocator,
) -> (
	[]u8,
	bool,
) {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	graphics: ghostty.Kitty_Graphics
	if ghostty.terminal_get(s.terminal, .Kitty_Graphics, &graphics) != .Success {return nil, false}
	image := ghostty.kitty_graphics_image(graphics, image_id)
	if image == nil {return nil, false}
	current: u64
	width, height: u32
	format: ghostty.Kitty_Image_Format
	data: [^]u8
	length: uint
	keys := [?]ghostty.Kitty_Graphics_Image_Data{.Generation, .Width, .Height, .Format, .Data_Len, .Data_Ptr}
	values := [?]rawptr{&current, &width, &height, &format, &length, &data}
	if ghostty.kitty_graphics_image_get_multi(image, len(keys), &keys[0], &values[0], nil) != .Success {
		return nil, false
	}
	if current != generation || data == nil {return nil, false}
	count := int(width) * int(height)
	out, allocation_error := make([]u8, count * 4, allocator)
	if allocation_error != nil {
		log.errorf("term: out of memory copying a %dx%d image", width, height)
		return nil, false
	}
	if !premultiplied_rgba(format, data[:length], out) {
		log.errorf("term: image payload of %d bytes does not match %dx%d %v", length, width, height, format)
		delete(out, allocator)
		return nil, false
	}
	return out, true
}

// premultiplied_rgba expands any stored format to four channels. The destination's size decides the
// pixel count; a source of the wrong length is refused rather than read past its end.
@(require_results)
premultiplied_rgba :: proc(format: ghostty.Kitty_Image_Format, source, out: []u8) -> bool {
	count := len(out) / 4
	scale :: proc(channel, alpha: u8) -> u8 {
		return u8((u32(channel) * u32(alpha) + 127) / 255)
	}
	#partial switch format {
	case .Rgb:
		if len(source) != count * 3 {return false}
		for i in 0 ..< count {
			out[i * 4 + 0], out[i * 4 + 1] = source[i * 3 + 0], source[i * 3 + 1]
			out[i * 4 + 2], out[i * 4 + 3] = source[i * 3 + 2], 255
		}
	case .Rgba:
		if len(source) != count * 4 {return false}
		for i in 0 ..< count {
			alpha := source[i * 4 + 3]
			out[i * 4 + 0] = scale(source[i * 4 + 0], alpha)
			out[i * 4 + 1] = scale(source[i * 4 + 1], alpha)
			out[i * 4 + 2] = scale(source[i * 4 + 2], alpha)
			out[i * 4 + 3] = alpha
		}
	case .Gray:
		if len(source) != count {return false}
		for i in 0 ..< count {
			g := source[i]
			out[i * 4 + 0], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = g, g, g, 255
		}
	case .Gray_Alpha:
		if len(source) != count * 2 {return false}
		for i in 0 ..< count {
			alpha := source[i * 2 + 1]
			g := scale(source[i * 2], alpha)
			out[i * 4 + 0], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = g, g, g, alpha
		}
	case:
		return false
	}
	return true
}

@(private)
png_decoder_once: sync.Once

// The decoder is process-global in libghostty, so the first terminal installs it for all of them.
@(private)
png_decoder_install :: proc() {
	sync.once_do(&png_decoder_once, proc() {
		decode: ghostty.Sys_Decode_Png_Fn = on_decode_png
		if ghostty.sys_set(.Decode_Png, rawptr(decode)) != .Success {
			log.error("term: installing the PNG decoder failed; PNG images will be refused")
		}
	})
}

// Runs on a session's reader thread with that session's mutex held.
@(private)
on_decode_png :: proc "c" (
	userdata: rawptr,
	allocator: ^ghostty.Allocator,
	data: [^]u8,
	data_len: uint,
	out: ^ghostty.Sys_Image,
) -> bool {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	return png_decode(data[:data_len], allocator, out)
}

// The dimensions are checked before decoding: a tiny file can claim a size far beyond the storage
// limit, and the decoder would allocate for it first.
@(private, require_results)
png_decode :: proc(data: []u8, allocator: ^ghostty.Allocator, out: ^ghostty.Sys_Image) -> bool {
	header, header_error := png.load_from_bytes(data, {.return_header})
	defer png.destroy(header)
	if header_error != nil || header == nil {return false}
	bytes := u64(header.width) * u64(header.height) * 4
	if bytes == 0 || bytes > IMAGE_STORAGE_LIMIT {return false}
	decoded, decode_error := png.load_from_bytes(data, {.alpha_add_if_missing})
	defer png.destroy(decoded)
	if decode_error != nil || decoded == nil || decoded.channels != 4 {return false}
	if decoded.width != header.width || decoded.height != header.height {return false}
	pixels := ghostty.alloc(allocator, uint(bytes))
	if pixels == nil {return false}
	target := pixels[:bytes]
	switch decoded.depth {
	case 8:
		copy(target, decoded.pixels.buf[:])
	case 16:
		wide := mem.slice_data_cast([]u16, decoded.pixels.buf[:])
		for value, i in wide {target[i] = u8(value >> 8)}
	case:
		ghostty.free(allocator, pixels, uint(bytes))
		return false
	}
	out^ = {u32(decoded.width), u32(decoded.height), pixels, uint(bytes)}
	return true
}

// Programs learn the cell size this way on Windows, where ConPTY has no pixel-size ioctl. Called
// during a VT write, under the session mutex that also guards the geometry.
@(private)
on_size :: proc "c" (
	terminal: ghostty.Terminal,
	userdata: rawptr,
	out_size: ^ghostty.Size_Report_Size,
) -> bool {
	g := (^Session)(userdata).geometry
	out_size^ = {g.rows, g.columns, g.cell_width, g.cell_height}
	return true
}
