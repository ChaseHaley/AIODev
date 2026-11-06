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

// An icon's slot is free, then pending while its job reads it, then ready or missing until it is
// reused or reloaded. A pending icon's path and pixels are borrowed by its job, so it is never freed.
Program_Icon_State :: enum u8 {
	Free,
	Pending,
	Ready,
	Missing,
}

@(private, rodata)
PROGRAM_ICON_MOVES := [Program_Icon_State]bit_set[Program_Icon_State] {
	.Free    = {.Pending},
	.Pending = {.Ready, .Missing},
	.Ready   = {.Free},
	.Missing = {.Free},
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

// The only writer of an icon's state. Freeing releases the icon's memory, and the icon must already
// hold its source, path, paint, size and pixels when it becomes pending.
@(private)
program_icon_move :: proc(icon: ^Program_Icon, to: Program_Icon_State) {
	assert(to in PROGRAM_ICON_MOVES[icon.state])
	if to == .Free {
		delete(icon.path)
		delete(icon.pixels)
		icon^ = {}
		return
	}
	icon.state = to
}

// Reuses a free icon or the least recently drawn finished one. The worker is started first, so an
// icon is only made pending when a job will settle it.
@(private)
program_icon_request :: proc(
	app: ^App,
	source: Program_Icon_Source,
	path: string,
	paint: program_art.Paint,
	size: int,
) {
	pw := &app.processes
	if !process_worker_start(pw, app.platform_ready ? &app.platform : nil) {return}
	index := -1
	for icon, i in pw.icons {
		if icon.state == .Pending {continue}
		if index < 0 || icon.state == .Free || icon.used < pw.icons[index].used {index = i}
		if icon.state == .Free {break}
	}
	if index < 0 {return}
	icon := &pw.icons[index]
	if icon.state != .Free {program_icon_move(icon, .Free)}
	path_copy, path_error := strings.clone(path)
	pixels, pixel_error := make([]u8, size * size * 4)
	if path_error != nil || pixel_error != nil {
		delete(path_copy)
		delete(pixels)
		log.error("allocating a program icon failed")
		return
	}
	icon.source, icon.path, icon.paint, icon.size, icon.pixels = source, path_copy, paint, size, pixels
	icon.used = pw.clock
	program_icon_move(icon, .Pending)
	process_icon_request(pw, index)
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
	program := program_adopted(entry)
	if app.settings.tabs.program_icons && program != nil && program.name != "" {
		source, path, paint, found := program_icon_source(app, program, int(math.round(size)))
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

// The icon for a status report: what the reporting program's name draws, so a child reporter shows
// its own agent, then the pane's icon. Pending while the named icon is read, so nothing lesser flashes.
report_icon :: proc(
	app: ^App,
	entry: ^Session_Entry,
	name: string,
	size: f32,
) -> (
	atlas: render.Rect,
	pending: bool,
	result: glyphs.Result,
) {
	if app.settings.tabs.program_icons && name != "" {
		pixels := int(math.round(size))
		art, has_art := program_art.find(name)
		source, path, paint, found := program_named_source(app, name, art, has_art, pixels)
		if found {
			state: Program_Icon_State
			atlas, state, result = program_icon_atlas(app, source, path, paint, pixels)
			if result != .Ok || state == .Ready {return}
			if state == .Pending {return {}, true, .Ok}
		}
	}
	_, atlas, result = pane_icon(app, entry, size)
	return
}

// The first source in precedence order that has not turned out to be missing at this size.
@(private)
program_icon_source :: proc(
	app: ^App,
	program: ^Program_Adopted,
	size: int,
) -> (
	source: Program_Icon_Source,
	path: string,
	paint: program_art.Paint,
	found: bool,
) {
	source, path, paint, found = program_named_source(app, program.name, program.art, program.has_art, size)
	if found {return}
	if program.path != "" && !program_icon_missing(app, .Executable, program.path, {}, size) {
		return .Executable, program.path, {}, true
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

// The pane's program as polling sees it; nil while its shell is at the prompt. A program is adopted
// only when a second poll still sees it, so a prompt helper or a short command does not flash its
// icon, while returning to the shell shows at once. Only program_update and program_forget write it.
Program :: union {
	Program_Seen,
	Program_Adopted,
	Program_Changing,
}

// Seen by one poll, with nothing adopted yet.
Program_Seen :: struct {
	id: u32,
}

// The process adopted and its image path; the name icons are looked up by and its bundled artwork;
// whether it is a WSL or SSH bridge, named by what its programs report; and how it was started, as
// a reopened pane shows it.
Program_Adopted :: struct {
	id:      u32,
	path:    string,
	name:    string,
	art:     program_art.Art,
	has_art: bool,
	bridge:  bool,
	command: string,
}

// The adopted program stands while the last poll saw another, `id`, for the first time.
Program_Changing :: struct {
	adopted: Program_Adopted,
	id:      u32,
}

// The last poll's choice, adopted or not, so that a split right after a program starts already
// opens in its directory.
program_polled :: proc(entry: ^Session_Entry) -> u32 {
	switch program in entry.program {
	case Program_Seen:
		return program.id
	case Program_Adopted:
		return program.id
	case Program_Changing:
		return program.id
	}
	return 0
}

// The program the pane's icon and remembered command name; nil until one is adopted.
program_adopted :: proc(entry: ^Session_Entry) -> ^Program_Adopted {
	#partial switch &program in entry.program {
	case Program_Adopted:
		return &program
	case Program_Changing:
		return &program.adopted
	}
	return nil
}

// Follows the pane's program to this poll's snapshot; reports whether its icon may change.
program_update :: proc(app: ^App, entry: ^Session_Entry, processes: []pty.Process_Info, root: u32) -> bool {
	apps := program_reporters(entry)
	index := pty.process_program(processes, root, apps, program_polled(entry))
	if index < 0 {
		if !program_forget(entry) {return false}
		layout_state_touch(app)
		return true
	}
	id := processes[index].id
	stem := settings.executable_stem(processes[index].executable)
	adopted := false
	switch &program in entry.program {
	case nil:
		entry.program = Program_Seen{id}
		return false
	case Program_Seen:
		if program.id != id {program.id = id; return false}
		entry.program = program_adopt(app, id, root, stem)
		adopted = true
	case Program_Adopted:
		if program.id != id {entry.program = Program_Changing{program, id}; return false}
	case Program_Changing:
		if program.id != id {
			standing := program.adopted
			if standing.id == id {entry.program = standing} else {program.id = id}
			return false
		}
		program_release(&program.adopted)
		entry.program = program_adopt(app, id, root, stem)
		adopted = true
	}
	if adopted {layout_state_touch(app)}
	program := program_adopted(entry)
	if !program.bridge {return adopted}
	// A bridge is named by the first reported app that has an icon, and by itself otherwise.
	name := stem
	for key in apps {
		if program_known(app, key) {name = key; break}
	}
	if strings.equal_fold(name, program.name) {return adopted}
	program_name_set(program, name)
	return true
}

// What a program confirmed by a second poll shows: its image, name and command.
@(private)
program_adopt :: proc(app: ^App, id, root: u32, stem: string) -> (program: Program_Adopted) {
	path, ok := pty.process_image(id, root)
	name := stem
	arguments, _ := pty.process_arguments(id, root, context.temp_allocator)
	if program_listed(program_launchers[:], stem) {
		if script := pty.process_script(arguments); program_known(app, script) {
			name = script
			// The launcher's own icon would show Node or cmd rather than the program.
			delete(path)
			path, ok = "", false
		}
	}
	program.id, program.path = id, ok ? path : ""
	program_name_set(&program, name)
	program.command = program_command(arguments, stem)
	program.bridge = program_listed(program_bridges[:], stem)
	return
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
program_name_set :: proc(program: ^Program_Adopted, name: string) {
	lower := strings.to_lower(name)
	delete(program.name)
	program.name = lower
	program.art, program.has_art = program_art.find(lower)
}

@(private)
program_release :: proc(program: ^Program_Adopted) {
	delete(program.path)
	delete(program.name)
	delete(program.command)
}

// Drops the pane's program; reports whether it had one.
program_forget :: proc(entry: ^Session_Entry) -> bool {
	if entry.program == nil {return false}
	if program := program_adopted(entry); program != nil {program_release(program)}
	entry.program = nil
	return true
}

// Drops PNG icons so edited files and settings are read again; ones being read are left alone.
program_icons_reload :: proc(app: ^App) {
	for &icon in app.processes.icons {
		if icon.source != .File || icon.state == .Pending || icon.state == .Free {continue}
		program_icon_move(&icon, .Free)
	}
}
