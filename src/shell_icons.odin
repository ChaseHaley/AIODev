package main

import "aio:localpath"
import "aio:render"
import "aio:settings"
import "core:fmt"
import "core:image/png"
import "core:strings"

Shell_Icon :: struct {
	pixels:        [32 * 32 * 4]u8,
	width, height: int,
	slot:          render.Atlas_Slot,
	// The Shell Icon setting as written when these pixels loaded from it; owned, empty without an image.
	path:          string,
}

shell_icon_destroy :: proc(icon: ^Shell_Icon) {
	delete(icon.path)
	icon^ = {}
}

shell_icon_load :: proc(app: ^App) {
	shell_icon_destroy(&app.shell_icon)
	icon_path := settings.profile_base(&app.settings.profiles).icon
	if icon_path == "" {return}
	path, path_error := localpath.settings_relative(icon_path, app.settings_path, context.temp_allocator)
	switch path_error {
	case .None:
	case .Expand:
		notify(app, .Error, "Could not allocate the shell icon path.")
		return
	case .Join:
		notify(app, .Error, "Could not resolve the shell icon path.")
		return
	}
	image, load_error := icon_png_load(path)
	defer png.destroy(image)
	switch load_error {
	case .None:
	case .Refused:
		notify(app, .Error, fmt.tprintf(
			"Shell Icon needs a readable PNG no larger than %d × %d. Using the shell default.",
			ICON_PNG_MAX_SIDE, ICON_PNG_MAX_SIDE,
		))
		return
	case .Undecodable:
		notify(
			app,
			.Error,
			"Could not decode Shell Icon as an 8-bit PNG. Using the shell default.",
		)
		return
	}
	icon := &app.shell_icon
	icon.width = max(1, min(32, image.width * 32 / max(image.width, image.height)))
	icon.height = max(1, min(32, image.height * 32 / max(image.width, image.height)))
	for y in 0 ..< icon.height {
		for x in 0 ..< icon.width {
			from :=
				(y * image.height / icon.height * image.width + x * image.width / icon.width) * 4
			to := (y * icon.width + x) * 4
			copy(icon.pixels[to:to + 4], image.pixels.buf[from:from + 4])
		}
	}
	icon.path = strings.clone(icon_path)
	mark_all_dirty(app)
}

shell_icon_atlas :: proc(app: ^App) -> (render.Rect, render.Build_Status) {
	icon := &app.shell_icon
	if icon.width == 0 {return {}, .Ok}
	return render.atlas_ensure(
		app.device,
		&icon.slot,
		i32(icon.width),
		i32(icon.height),
		icon.pixels[:icon.width * icon.height * 4],
		icon.width,
		true,
	)
}
