package main

import "aio:glyphs"
import platform_api "aio:platform"
import "aio:program_art"
import "aio:pty"
import "aio:render"
import "aio:settings"
import "aio:term_view"
import "core:log"
import "core:math"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Icons of the programs running in panes (WORK-272, WORK-279). A program is named by its
// executable stem, the script a launcher runs, or the app a WSL or SSH session reports. Its icon
// is the user's PNG for that name, then bundled artwork, then the executable's own icon, then the
// shell badge. The process worker reads and draws each one at the drawn pixel size, cached by
// source and size; a source that yields nothing is cached as missing so the next one is used.

@(private)
PROGRAM_ICON_LIMIT :: 32

// Launchers run the program named by their arguments rather than being one.
@(private, rodata)
program_launchers := [?]string{"node", "bun", "deno", "npx", "pnpx", "bunx", "cmd", "uv", "uvx"}

// Bridges run programs out of Windows' sight, which can only be named by what they report.
@(private, rodata)
program_bridges := [?]string{"wsl", "ssh", "mosh", "mosh-client", "docker", "podman"}

// Brand colours fainter than this against the tab background use the tab text colour instead.
@(private)
PROGRAM_ART_CONTRAST :: 3

@(private)
Program_Icon_State :: enum u8 {
	Free,
	Pending,
	Ready,
	Missing,
}

@(private)
Program_Icon_Source :: enum u8 {
	Executable,
	Artwork,
	File,
}

// `path` is an executable or PNG path, or the artwork's canonical name.
@(private)
Program_Icon :: struct {
	source: Program_Icon_Source,
	path:   string,
	colour: [3]u8,
	size:   int,
	pixels: []u8,
	state:  Program_Icon_State,
	slot:   render.Atlas_Slot,
	used:   u64,
}

// Reuses a free icon or the least recently drawn finished one.
@(private)
program_icon_request :: proc(app: ^App, source: Program_Icon_Source, path: string, colour: [3]u8, size: int) {
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
	icon^ = {
		source = source,
		path   = path_copy,
		colour = colour,
		size   = size,
		pixels = pixels,
		state  = .Pending,
		used   = pw.clock,
	}
	process_icon_request(pw, index, app.platform_ready ? &app.platform : nil)
}

// The atlas rectangle of one source's icon once it is ready; `state` is Pending while it is read.
@(private)
program_icon_atlas :: proc(
	app: ^App,
	source: Program_Icon_Source,
	path: string,
	colour: [3]u8,
	size: int,
) -> (
	rect: render.Rect,
	state: Program_Icon_State,
	result: glyphs.Result,
) {
	pw := &app.processes
	if path == "" || size < 1 || size > platform_api.EXECUTABLE_ICON_MAX {return {}, .Missing, .Ok}
	pw.clock += 1
	for &icon in pw.icons {
		if icon.state == .Free || icon.source != source || icon.size != size || icon.colour != colour {
			continue
		}
		if icon.path != path {continue}
		icon.used = pw.clock
		if icon.state != .Ready {return {}, icon.state, .Ok}
		if icon.slot.generation != render.atlas_generation(app.device) {
			slot, ok := render.atlas_reserve(app.device, i32(size), i32(size), true)
			if !ok {render.atlas_reset(app.device); return {}, .Pending, .Atlas_Reset}
			render.atlas_upload(app.device, slot, icon.pixels, size)
			icon.slot = slot
		}
		r := icon.slot
		return {f32(r.x), f32(r.y), f32(r.width), f32(r.height)}, .Ready, .Ok
	}
	program_icon_request(app, source, path, colour, size)
	return {}, .Pending, .Ok
}

// The badge for a pane drawn `size` pixels square: its program's icon once one is ready,
// otherwise the shell's text badge and configured shell image. While a preferred source is still
// being read the shell badge stands in, so a lesser icon never flashes first.
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
	if app.settings.tabs.program_icons && entry.program_name != "" {
		source, path, colour, found := program_icon_source(app, entry, int(math.round(size)))
		if found {
			state: Program_Icon_State
			atlas, state, result = program_icon_atlas(app, source, path, colour, int(math.round(size)))
			if result != .Ok || state == .Ready {return}
			atlas = {}
		}
	}
	badge = entry.header.icon
	atlas, result = shell_icon_atlas(app)
	return
}

// The first source in precedence order that has not turned out to be missing at this size.
@(private)
program_icon_source :: proc(
	app: ^App,
	entry: ^Session_Entry,
	size: int,
) -> (
	source: Program_Icon_Source,
	path: string,
	colour: [3]u8,
	found: bool,
) {
	if file, ok := program_icon_file(app, entry); ok && !program_icon_missing(app, .File, file, {}, size) {
		return .File, file, {}, true
	}
	if entry.program_has_art {
		name := program_art.canonical(entry.program_art)
		art_colour := program_art_colour(app, entry.program_art)
		if !program_icon_missing(app, .Artwork, name, art_colour, size) {return .Artwork, name, art_colour, true}
	}
	if entry.program_path != "" && !program_icon_missing(app, .Executable, entry.program_path, {}, size) {
		return .Executable, entry.program_path, {}, true
	}
	return
}

@(private)
program_icon_missing :: proc(
	app: ^App,
	source: Program_Icon_Source,
	path: string,
	colour: [3]u8,
	size: int,
) -> bool {
	for &icon in app.processes.icons {
		if icon.state == .Missing && icon.source == source && icon.size == size && icon.colour == colour &&
		   icon.path == path {
			icon.used = app.processes.clock
			return true
		}
	}
	return false
}

// The user's PNG for the pane's program, resolved like Shell Icon: home expanded, and relative to
// the settings folder. Its artwork's canonical name is tried after the program's own name.
@(private)
program_icon_file :: proc(app: ^App, entry: ^Session_Entry) -> (string, bool) {
	file, ok := settings.program_icon_file(&app.settings, entry.program_name)
	if !ok && entry.program_has_art {
		file, ok = settings.program_icon_file(&app.settings, program_art.canonical(entry.program_art))
	}
	if !ok {return "", false}
	path, err := settings.expand_home(file, context.temp_allocator)
	if err != nil {return "", false}
	if !filepath.is_abs(path) {
		path, err = filepath.join({filepath.dir(app.settings_path), path}, context.temp_allocator)
		if err != nil {return "", false}
	}
	return path, true
}

// Artwork is drawn in its brand colour when that stands out from the tab background, otherwise in
// the tab text colour, so dark logos stay visible on dark themes and light ones on light themes.
@(private)
program_art_colour :: proc(app: ^App, art: program_art.Art) -> [3]u8 {
	if brand, ok := program_art.brand(art); ok {
		colour := render.Color{f32(brand.r) / 255, f32(brand.g) / 255, f32(brand.b) / 255, 1}
		if term_view.contrast_ratio(colour, app.theme.tab_bar) >= PROGRAM_ART_CONTRAST {return brand}
	}
	text := app.theme.tab_text
	return {u8(math.round(text.r * 255)), u8(math.round(text.g * 255)), u8(math.round(text.b * 255))}
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
	if candidate != previous {return false}
	stem := settings.executable_stem(processes[index].executable)
	adopted := false
	if candidate != entry.program_id {
		path, ok := pty.process_image(candidate, root)
		name := stem
		if program_listed(program_launchers[:], stem) {
			if script := program_script(app, candidate, root); script != "" {
				name = script
				// The launcher's own icon would show Node or cmd rather than the program.
				delete(path)
				path, ok = "", false
			}
		}
		delete(entry.program_path)
		entry.program_id, entry.program_path = candidate, ok ? path : ""
		program_name_set(entry, name)
		entry.program_bridge = program_listed(program_bridges[:], stem)
		adopted = true
	}
	if !entry.program_bridge {return adopted}
	// A bridge is named by the first reported app that has an icon, and by itself otherwise.
	name := stem
	for key in apps {
		if program_known(app, key) {name = key; break}
	}
	if strings.equal_fold(name, entry.program_name) {return adopted}
	program_name_set(entry, name)
	return true
}

// The program a launcher runs, when it has an icon to show; otherwise empty.
@(private)
program_script :: proc(app: ^App, id, root: u32) -> string {
	arguments, ok := pty.process_arguments(id, root, context.temp_allocator)
	if !ok {return ""}
	script := pty.process_script(arguments)
	return program_known(app, script) ? script : ""
}

@(private)
program_known :: proc(app: ^App, name: string) -> bool {
	if name == "" {return false}
	if _, found := program_art.find(name); found {return true}
	_, found := settings.program_icon_file(&app.settings, name)
	return found
}

@(private)
program_listed :: proc(names: []string, stem: string) -> bool {
	for name in names {if strings.equal_fold(name, stem) {return true}}
	return false
}

@(private)
program_name_set :: proc(entry: ^Session_Entry, name: string) {
	lower := strings.to_lower(name)
	delete(entry.program_name)
	entry.program_name = lower
	entry.program_art, entry.program_has_art = program_art.find(lower)
}

program_forget :: proc(entry: ^Session_Entry) -> bool {
	if entry.program_id == 0 && entry.program_candidate == 0 {return false}
	delete(entry.program_path)
	delete(entry.program_name)
	entry.program_id, entry.program_candidate, entry.program_path = 0, 0, ""
	entry.program_name, entry.program_art = "", {}
	entry.program_has_art, entry.program_bridge = false, false
	return true
}

// Drops PNG icons so edited files and settings are read again; ones being read are left alone.
program_icons_reload :: proc(app: ^App) {
	for &icon in app.processes.icons {
		if icon.source != .File || icon.state == .Pending || icon.state == .Free {continue}
		delete(icon.path)
		delete(icon.pixels)
		icon = {}
	}
}
