package main

import "aio:localpath"
import "aio:render"
import "aio:settings"
import "core:fmt"
import "core:image/png"
import "core:log"
import "core:strings"

// One profile's Icon setting, read when settings are published. A pane draws the image of the
// profile it was launched with.
Shell_Icon :: struct {
	pixels:        [32 * 32 * 4]u8,
	width, height: int,
	slot:          render.Atlas_Slot,
	// The profile, and its Icon setting as written, these pixels loaded from; owned.
	profile, path: string,
}

shell_icons_destroy :: proc(icons: ^[dynamic]Shell_Icon) {
	for &icon in icons {
		delete(icon.profile)
		delete(icon.path)
	}
	delete(icons^)
	icons^ = nil
}

// Reads every profile's Icon again, so edited files and settings take effect. A profile without
// one, or whose image cannot be read, has no entry and draws its executable's own icon instead.
shell_icons_load :: proc(app: ^App) {
	shell_icons_destroy(&app.shell_icons)
	for &profile in app.settings.profiles.items {
		if profile.icon != "" {shell_icon_load(app, &profile)}
	}
	mark_all_dirty(app)
}

@(private)
shell_icon_load :: proc(app: ^App, profile: ^settings.Profile) {
	path, path_error := localpath.settings_relative(
		profile.icon,
		app.settings_path,
		context.temp_allocator,
	)
	switch path_error {
	case .None:
	case .Expand:
		notify(app, .Error, fmt.tprintf("Could not allocate the %s profile's icon path.", profile.name))
		return
	case .Join:
		notify(app, .Error, fmt.tprintf("Could not resolve the %s profile's icon path.", profile.name))
		return
	}
	image, load_error := icon_png_load(path)
	defer png.destroy(image)
	switch load_error {
	case .None:
	case .Refused:
		notify(app, .Error, fmt.tprintf(
			"The %s profile's Icon needs a readable PNG no larger than %d × %d. " +
			"Using the shell default.",
			profile.name, ICON_PNG_MAX_SIDE, ICON_PNG_MAX_SIDE,
		))
		return
	case .Undecodable:
		notify(app, .Error, fmt.tprintf(
			"Could not decode the %s profile's Icon as an 8-bit PNG. Using the shell default.",
			profile.name,
		))
		return
	}
	icon := Shell_Icon{}
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
	id, id_error := strings.clone(profile.id)
	written, copy_error := strings.clone(profile.icon)
	icon.profile, icon.path = id, written
	if id_error == nil && copy_error == nil {
		if _, append_error := append(&app.shell_icons, icon); append_error == nil {return}
	}
	delete(id)
	delete(written)
	log.error("keeping a profile icon failed")
}

// The loaded Icon of the profile `id`, or nil.
shell_icon_find :: proc(app: ^App, id: string) -> ^Shell_Icon {
	for &icon in app.shell_icons {
		if icon.profile == id {return &icon}
	}
	return nil
}

shell_icon_atlas :: proc(app: ^App, icon: ^Shell_Icon) -> (render.Rect, render.Build_Status) {
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
