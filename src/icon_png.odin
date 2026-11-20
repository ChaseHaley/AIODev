package main

import platform_api "aio:platform"
import "core:image/png"
import "core:os"

// Shell and program icons are small, and the PNG loader reads a whole file before checking its
// header, so a settings value naming a huge file must be refused before it is read into memory.
@(private)
ICON_PNG_MAX_BYTES :: 32 << 20
@(private)
ICON_PNG_MAX_SIDE :: 1024

@(private)
Icon_Png_Error :: enum u8 {
	None,
	// Not a local file within the byte limit, or a header outside 1..ICON_PNG_MAX_SIDE.
	Refused,
	// Not decodable as 8-bit RGBA.
	Undecodable,
}

// A user's PNG icon decoded as premultiplied 8-bit RGBA; the caller destroys it with png.destroy
// and samples it to its own size. The settings file is trusted, but a device path, remote share,
// directory, or oversized file would stall or allocate without bound before the decoder's checks.
@(private)
icon_png_load :: proc(path: string) -> (^png.Image, Icon_Png_Error) {
	if !platform_api.local_file_within_limit(path, ICON_PNG_MAX_BYTES) {return nil, .Refused}
	data, read_error := os.read_entire_file(path, context.allocator)
	defer delete(data)
	if read_error != nil {return nil, .Refused}
	return icon_png_decode(data)
}

// PNG bytes decoded as icon_png_load decodes a file: its header is checked before the pixels are.
@(private)
icon_png_decode :: proc(data: []u8) -> (^png.Image, Icon_Png_Error) {
	header, header_error := png.load(data, {.return_header})
	defer png.destroy(header)
	if header_error != nil ||
	   header == nil ||
	   header.width < 1 ||
	   header.height < 1 ||
	   header.width > ICON_PNG_MAX_SIDE ||
	   header.height > ICON_PNG_MAX_SIDE {return nil, .Refused}
	image, image_error := png.load(data, {.alpha_add_if_missing, .alpha_premultiply})
	if image_error != nil || image == nil || image.depth != 8 || image.channels != 4 {
		png.destroy(image)
		return nil, .Undecodable
	}
	return image, .None
}

// `image` fitted into the width x height block at (left, top) of `pixels`, whose rows are `stride`
// pixels long, each pixel averaging the source pixels it covers.
@(private)
icon_png_sample :: proc(image: ^png.Image, width, height: int, pixels: []u8, stride, left, top: int) {
	source := image.pixels.buf[:]
	for y in 0 ..< height {
		y0 := y * image.height / height
		y1 := max(y0 + 1, (y + 1) * image.height / height)
		for x in 0 ..< width {
			x0 := x * image.width / width
			x1 := max(x0 + 1, (x + 1) * image.width / width)
			sum: [4]u32
			for sy in y0 ..< y1 {
				for sx in x0 ..< x1 {
					from := (sy * image.width + sx) * 4
					for c in 0 ..< 4 {sum[c] += u32(source[from + c])}
				}
			}
			count := u32((x1 - x0) * (y1 - y0))
			to := ((top + y) * stride + left + x) * 4
			for c in 0 ..< 4 {pixels[to + c] = u8((sum[c] + count / 2) / count)}
		}
	}
}
