package main

import "core:image/png"
import "core:path/filepath"
import "aio:glyphs"
import "aio:render"
import "aio:settings"

Shell_Icon :: struct {
	pixels: [32*32*4]u8,
	width, height: int,
	slot: render.Atlas_Slot,
}

shell_icon_load :: proc(app: ^App) {
	app.shell_icon = {}
	if app.settings.shell.icon == "" { return }
	path, err := settings.expand_home(app.settings.shell.icon, context.temp_allocator)
	if err != nil { notify(app, .Error, "Could not allocate the shell icon path."); return }
	if !filepath.is_abs(path) {
		path, err = filepath.join({filepath.dir(app.settings_path), path}, context.temp_allocator)
		if err != nil { notify(app, .Error, "Could not resolve the shell icon path."); return }
	}
	header, header_error := png.load(path, {.return_header})
	defer png.destroy(header)
	if header_error != nil || header == nil || header.width < 1 || header.height < 1 ||
	   header.width > 1024 || header.height > 1024 {
		notify(app, .Error, "Shell Icon needs a readable PNG no larger than 1024 × 1024. Using the shell default.")
		return
	}
	image, image_error := png.load(path, {.alpha_add_if_missing, .alpha_premultiply})
	defer png.destroy(image)
	if image_error != nil || image == nil || image.depth != 8 || image.channels != 4 {
		notify(app, .Error, "Could not decode Shell Icon as an 8-bit PNG. Using the shell default.")
		return
	}
	icon := &app.shell_icon
	icon.width = max(1, min(32, image.width*32/max(image.width, image.height)))
	icon.height = max(1, min(32, image.height*32/max(image.width, image.height)))
	for y in 0..<icon.height {
		for x in 0..<icon.width {
			from := (y*image.height/icon.height*image.width+x*image.width/icon.width)*4
			to := (y*icon.width+x)*4
			copy(icon.pixels[to:to+4], image.pixels.buf[from:from+4])
		}
	}
	mark_all_dirty(app)
}

shell_icon_atlas :: proc(app: ^App) -> (render.Rect, glyphs.Result) {
	icon := &app.shell_icon
	if icon.width == 0 { return {}, .Ok }
	if icon.slot.generation != render.atlas_generation(app.device) {
		slot, ok := render.atlas_reserve(app.device, i32(icon.width), i32(icon.height), true)
		if !ok { render.atlas_reset(app.device); return {}, .Atlas_Reset }
		render.atlas_upload(app.device, slot, icon.pixels[:icon.width*icon.height*4], icon.width)
		icon.slot = slot
	}
	r := icon.slot
	return {f32(r.x), f32(r.y), f32(r.width), f32(r.height)}, .Ok
}
