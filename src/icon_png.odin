package main

import platform_api "aio:platform"
import "core:image/png"

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
	header, header_error := png.load(path, {.return_header})
	defer png.destroy(header)
	if header_error != nil ||
	   header == nil ||
	   header.width < 1 ||
	   header.height < 1 ||
	   header.width > ICON_PNG_MAX_SIDE ||
	   header.height > ICON_PNG_MAX_SIDE {return nil, .Refused}
	image, image_error := png.load(path, {.alpha_add_if_missing, .alpha_premultiply})
	if image_error != nil || image == nil || image.depth != 8 || image.channels != 4 {
		png.destroy(image)
		return nil, .Undecodable
	}
	return image, .None
}
