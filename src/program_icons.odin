package main

import "aio:glyphs"
import platform_api "aio:platform"
import "aio:pty"
import "aio:render"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"

// Icons of the programs running in panes (WORK-272), read from each executable by the process
// worker and cached by path and pixel size. Executables without an icon resource are cached as
// missing so they fall back to the shell badge without being read again.

@(private)
PROGRAM_ICON_LIMIT :: 32

@(private)
Program_Icon_State :: enum u8 {
	Free,
	Pending,
	Ready,
	Missing,
}

@(private)
Program_Icon :: struct {
	path:   string,
	size:   int,
	pixels: []u8,
	state:  Program_Icon_State,
	slot:   render.Atlas_Slot,
	used:   u64,
}

// Reuses a free icon or the least recently drawn finished one.
@(private)
program_icon_request :: proc(app: ^App, path: string, size: int) {
	pw := &app.processes
	index := -1
	for icon, i in pw.icons {
		if icon.state == .Pending {continue}
		if index < 0 || icon.state == .Free || icon.used < pw.icons[index].used {index = i}
		if icon.state == .Free {break}
	}
	if index < 0 {return}
	icon := &pw.icons[index]
	delete(icon.path)
	delete(icon.pixels)
	icon^ = {}
	path_copy, path_error := strings.clone(path)
	pixels, pixel_error := make([]u8, size * size * 4)
	if path_error != nil || pixel_error != nil {
		delete(path_copy)
		delete(pixels)
		log.error("allocating a program icon failed")
		return
	}
	icon^ = {path = path_copy, size = size, pixels = pixels, state = .Pending, used = pw.clock}
	process_icon_request(pw, index, app.platform_ready ? &app.platform : nil)
}

@(private)
program_icon_atlas :: proc(app: ^App, path: string, size: int) -> (render.Rect, glyphs.Result) {
	pw := &app.processes
	if path == "" || size < 1 || size > platform_api.EXECUTABLE_ICON_MAX {return {}, .Ok}
	pw.clock += 1
	for &icon in pw.icons {
		if icon.state == .Free || icon.size != size || icon.path != path {continue}
		icon.used = pw.clock
		if icon.state != .Ready {return {}, .Ok}
		if icon.slot.generation != render.atlas_generation(app.device) {
			slot, ok := render.atlas_reserve(app.device, i32(size), i32(size), true)
			if !ok {render.atlas_reset(app.device); return {}, .Atlas_Reset}
			render.atlas_upload(app.device, slot, icon.pixels, size)
			icon.slot = slot
		}
		r := icon.slot
		return {f32(r.x), f32(r.y), f32(r.width), f32(r.height)}, .Ok
	}
	program_icon_request(app, path, size)
	return {}, .Ok
}

// The badge for a pane drawn `size` pixels square: its program's own icon once one is ready,
// otherwise the shell's text badge and configured shell image.
pane_icon :: proc(
	app: ^App,
	entry: ^Session_Entry,
	size: f32,
) -> (
	badge: string,
	atlas: render.Rect,
	result: glyphs.Result,
) {
	if entry == nil {return}
	if app.settings.tabs.program_icons && entry.program_path != "" {
		atlas, result = program_icon_atlas(app, entry.program_path, int(math.round(size)))
		if result != .Ok || atlas.width > 0 {return}
	}
	badge = entry.header.icon
	atlas, result = shell_icon_atlas(app)
	return
}

// Chooses the pane's program from this poll's snapshot; reports whether its icon may change. A
// new candidate is adopted only when a second poll still sees it, so a prompt helper or a short
// command does not flash its icon, while returning to the shell shows at once.
program_update :: proc(app: ^App, entry: ^Session_Entry, processes: []pty.Process_Info, root: u32) -> bool {
	records := slice.clone(entry.statuses, context.temp_allocator)
	slice.sort_by(records, status_before)
	apps := make([dynamic]string, 0, len(records), context.temp_allocator)
	for record in records {if record.app != "" {append(&apps, record.app)}}
	index := pty.process_program(processes, root, apps[:], entry.program_candidate)
	candidate := index >= 0 ? processes[index].id : 0
	previous := entry.program_candidate
	entry.program_candidate = candidate
	if candidate == 0 {return program_forget(entry)}
	if candidate != previous || candidate == entry.program_id {return false}
	path, ok := pty.process_image(candidate, root)
	delete(entry.program_path)
	entry.program_id, entry.program_path = candidate, ok ? path : ""
	return true
}

program_forget :: proc(entry: ^Session_Entry) -> bool {
	if entry.program_id == 0 && entry.program_candidate == 0 {return false}
	delete(entry.program_path)
	entry.program_id, entry.program_candidate, entry.program_path = 0, 0, ""
	return true
}
