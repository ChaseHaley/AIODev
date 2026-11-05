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
import "core:unicode/utf8"

// Icons of the programs running in panes (WORK-272, WORK-279). A program is named by its
// executable stem, the script a launcher runs, or the app a WSL or SSH session reports. Its icon
// is the user's PNG for that name, then bundled artwork, then the executable's own icon, then the
// shell badge. The process worker reads and draws each one at the drawn pixel size, cached by
// source and size; a source that yields nothing is cached as missing so the next one is used.

@(private)
PROGRAM_ICON_LIMIT :: 32
// A remembered command longer than this is cut; it only reminds the user what ran.
@(private)
PROGRAM_COMMAND_LIMIT :: 240

// Launchers run the program named by their arguments rather than being one.
@(private, rodata)
program_launchers := [?]string{"node", "bun", "deno", "npx", "pnpx", "bunx", "cmd", "uv", "uvx"}

// Bridges run programs out of Windows' sight, which can only be named by what they report.
@(private, rodata)
program_bridges := [?]string{"wsl", "ssh", "mosh", "mosh-client", "docker", "podman"}

// Artwork with a brand colour fainter than this against the tab background uses the tab text
// colour instead.
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
	paint:  program_art.Paint,
	size:   int,
	pixels: []u8,
	state:  Program_Icon_State,
	slot:   render.Atlas_Slot,
	used:   u64,
}

// Reuses a free icon or the least recently drawn finished one.
@(private)
program_icon_request :: proc(
	app: ^App,
	source: Program_Icon_Source,
	path: string,
	paint: program_art.Paint,
	size: int,
) {
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
		paint  = paint,
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
	paint: program_art.Paint,
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
		if icon.state == .Free || icon.source != source || icon.size != size || icon.paint != paint {
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
	program_icon_request(app, source, path, paint, size)
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
		source, path, paint, found := program_icon_source(app, entry, int(math.round(size)))
		if found {
			state: Program_Icon_State
			atlas, state, result = program_icon_atlas(app, source, path, paint, int(math.round(size)))
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
	paint: program_art.Paint,
	found: bool,
) {
	source, path, paint, found = program_named_source(app, entry.program_name, entry.program_art,
		entry.program_has_art, size)
	if found {return}
	if entry.program_path != "" && !program_icon_missing(app, .Executable, entry.program_path, {}, size) {
		return .Executable, entry.program_path, {}, true
	}
	return
}

// The user's PNG for a program's name, then its bundled artwork.
@(private)
program_named_source :: proc(
	app: ^App,
	name: string,
	art: program_art.Art,
	has_art: bool,
	size: int,
) -> (
	source: Program_Icon_Source,
	path: string,
	paint: program_art.Paint,
	found: bool,
) {
	if file, ok := program_named_file(app, name, art, has_art);
	   ok && !program_icon_missing(app, .File, file, {}, size) {
		return .File, file, {}, true
	}
	if has_art {
		canonical := program_art.canonical(art)
		art_paint := program_art_paint(app, art)
		if !program_icon_missing(app, .Artwork, canonical, art_paint, size) {
			return .Artwork, canonical, art_paint, true
		}
	}
	return
}

@(private)
program_icon_missing :: proc(
	app: ^App,
	source: Program_Icon_Source,
	path: string,
	paint: program_art.Paint,
	size: int,
) -> bool {
	for &icon in app.processes.icons {
		if icon.state == .Missing && icon.source == source && icon.size == size && icon.paint == paint &&
		   icon.path == path {
			icon.used = app.processes.clock
			return true
		}
	}
	return false
}

// The user's PNG for a program, resolved like Shell Icon: home expanded, and relative to
// the settings folder. Its artwork's canonical name is tried after the program's own name.
@(private)
program_named_file :: proc(app: ^App, name: string, art: program_art.Art, has_art: bool) -> (string, bool) {
	file, ok := settings.program_icon_file(&app.settings, name)
	if !ok && has_art {
		file, ok = settings.program_icon_file(&app.settings, program_art.canonical(art))
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

// Artwork is drawn in its brand colours when every one stands out from the tab background,
// otherwise wholly in the tab text colour, so dark logos stay visible on dark themes and light ones
// on light themes, and a multi-colour logo is never partly recoloured.
@(private)
program_art_paint :: proc(app: ^App, art: program_art.Art) -> (paint: program_art.Paint) {
	text := app.theme.tab_text
	paint.text = {u8(math.round(text.r * 255)), u8(math.round(text.g * 255)), u8(math.round(text.b * 255))}
	layers := art.layers
	for layer in program_art.next_layer(&layers) {
		brand := program_art.brand(layer) or_continue
		colour := render.Color{f32(brand.r) / 255, f32(brand.g) / 255, f32(brand.b) / 255, 1}
		if term_view.contrast_ratio(colour, app.theme.tab_bar) < PROGRAM_ART_CONTRAST {
			paint.mono = true
			return
		}
	}
	return
}

// Chooses the pane's program from this poll's snapshot; reports whether its icon may change. A
// new candidate is adopted only when a second poll still sees it, so a prompt helper or a short
// command does not flash its icon, while returning to the shell shows at once.
program_update :: proc(app: ^App, entry: ^Session_Entry, processes: []pty.Process_Info, root: u32) -> bool {
	apps := program_reporters(entry)
	index := pty.process_program(processes, root, apps, entry.program_candidate)
	candidate := index >= 0 ? processes[index].id : 0
	previous := entry.program_candidate
	entry.program_candidate = candidate
	if candidate == 0 {
		if !program_forget(entry) {return false}
		layout_state_touch(app)
		return true
	}
	if candidate != previous {return false}
	stem := settings.executable_stem(processes[index].executable)
	adopted := false
	if candidate != entry.program_id {
		path, ok := pty.process_image(candidate, root)
		name := stem
		arguments, _ := pty.process_arguments(candidate, root, context.temp_allocator)
		if program_listed(program_launchers[:], stem) {
			if script := pty.process_script(arguments); program_known(app, script) {
				name = script
				// The launcher's own icon would show Node or cmd rather than the program.
				delete(path)
				path, ok = "", false
			}
		}
		delete(entry.program_path)
		entry.program_id, entry.program_path = candidate, ok ? path : ""
		program_name_set(entry, name)
		delete(entry.program_command)
		entry.program_command = program_command(arguments, stem)
		layout_state_touch(app)
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

// The apps the pane's program status names, most important first, in temporary memory.
program_reporters :: proc(entry: ^Session_Entry) -> []string {
	records := slice.clone(entry.statuses, context.temp_allocator)
	slice.sort_by(records, status_before)
	apps := make([dynamic]string, 0, len(records), context.temp_allocator)
	for record in records {if record.app != "" {append(&apps, record.app)}}
	return apps[:]
}

// How the program was started, as someone would type it: the executable's stem, or the script a
// launcher runs, then the remaining arguments. Control characters are dropped so the text is safe
// to write to a terminal. Empty when the arguments are unreadable.
program_command :: proc(arguments: []string, stem: string, allocator := context.allocator) -> string {
	if len(arguments) == 0 || stem == "" {return ""}
	b := strings.builder_make(context.temp_allocator)
	first := 1
	if program_listed(program_launchers[:], stem) {
		if script := pty.process_script(arguments); script != "" {
			// The argument naming the script; anything after the script in it (cmd's quoted
			// command) is kept.
			for argument, i in arguments[1:] {
				text := strings.trim(argument, "\" ")
				lower := strings.to_lower(text, context.temp_allocator)
				at := strings.index(lower, strings.to_lower(script, context.temp_allocator))
				if at < 0 || argument == "" || argument[0] == '-' {continue}
				strings.write_string(&b, script)
				rest := text[at + len(script):]
				if space := strings.index_byte(rest, ' '); space >= 0 {
					rest = strings.trim_left(rest[space:], "\" ")
					if rest != "" {strings.write_byte(&b, ' '); strings.write_string(&b, rest)}
				}
				first = i + 2
				break
			}
		}
	}
	if strings.builder_len(b) == 0 {strings.write_string(&b, stem)}
	for argument in arguments[min(first, len(arguments)):] {
		strings.write_byte(&b, ' ')
		quoted := argument == "" || strings.index_any(argument, " \t") >= 0
		if quoted {strings.write_byte(&b, '"')}
		strings.write_string(&b, argument)
		if quoted {strings.write_byte(&b, '"')}
	}
	return printable_command(strings.to_string(b), allocator)
}

// The text without control characters, cut to PROGRAM_COMMAND_LIMIT bytes, so it can be written
// to a terminal as plain text.
printable_command :: proc(text: string, allocator := context.allocator) -> string {
	out := strings.builder_make(allocator)
	for r in text {
		if r < 0x20 || r == 0x7f || r >= 0x80 && r < 0xa0 || r == utf8.RUNE_ERROR {continue}
		if strings.builder_len(out) + utf8.rune_size(r) > PROGRAM_COMMAND_LIMIT {break}
		strings.write_rune(&out, r)
	}
	return strings.to_string(out)
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
	delete(entry.program_command)
	entry.program_command = ""
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
