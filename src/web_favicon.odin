package main

import "aio:render"
import "core:image/png"
import "core:log"

// A web page's favicon (WORK-315), the image its pane's header, tab, rail row and float capsule draw
// in place of the globe. The native view hands over PNG bytes whenever the site's favicon changes.
// It is a full-colour image: it is drawn as it is, never tinted to the theme.

// The longest side kept, in pixels. Favicons are 16 to 32 pixels square; a larger one is averaged
// down, and a smaller one is kept as it is and scaled by the badge's draw.
@(private)
WEB_FAVICON_MAX_SIDE :: 32
// The most PNG bytes accepted, since a page chooses its favicon.
WEB_FAVICON_MAX_BYTES :: 1 << 20

// The favicon of one web pane: premultiplied 8-bit RGBA, owned, with none when width is zero.
Web_Favicon :: struct {
	pixels:        []u8,
	width, height: int,
	slot:          render.Atlas_Slot,
}

// Replaces the favicon with the image in `data`, a PNG. Empty `data` clears it. False when the bytes
// are not a PNG icon, are too large, or cannot be kept; the pane then has no favicon and its badge is
// the globe, rather than the previous page's icon.
@(require)
web_favicon_set :: proc(app: ^App, favicon: ^Web_Favicon, data: []u8) -> bool {
	web_favicon_destroy(favicon)
	mark_all_dirty(app)
	if len(data) == 0 {return true}
	if len(data) > WEB_FAVICON_MAX_BYTES {return false}
	image, decode_error := icon_png_decode(data)
	defer png.destroy(image)
	if decode_error != .None {return false}
	longest := max(image.width, image.height)
	fit := min(longest, WEB_FAVICON_MAX_SIDE)
	width, height := max(1, image.width * fit / longest), max(1, image.height * fit / longest)
	pixels, allocation_error := make([]u8, width * height * 4)
	if allocation_error != nil {
		log.error("keeping a web favicon failed")
		return false
	}
	icon_png_sample(image, width, height, pixels, width, 0, 0)
	favicon^ = {
		pixels = pixels,
		width  = width,
		height = height,
	}
	return true
}

// Releases the favicon's pixels. The atlas keeps no memory per slot, so nothing else is held.
web_favicon_destroy :: proc(favicon: ^Web_Favicon) {
	delete(favicon.pixels)
	favicon^ = {}
}

// The atlas rectangle of the favicon, uploading it when it is not resident; empty when there is none.
@(require_results)
web_favicon_atlas :: proc(app: ^App, favicon: ^Web_Favicon) -> (render.Rect, render.Build_Status) {
	if favicon.width < 1 {return {}, .Ok}
	return render.atlas_ensure(
		app.device,
		&favicon.slot,
		i32(favicon.width),
		i32(favicon.height),
		favicon.pixels,
		favicon.width,
		true,
	)
}
