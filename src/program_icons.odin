package main

import "aio:colour"
import "aio:localpath"
import platform_api "aio:platform"
import "aio:program_art"
import "aio:render"
import "aio:settings"
import "core:image/png"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"

// Icons of the programs running in panes (WORK-272, WORK-279). A program's icon is the user's PNG
// for its name, then bundled artwork, then the executable's own icon, then the shell badge. The
// shell's own executable icon is read through the same cache (WORK-345). The process worker reads
// and draws each one at the drawn pixel size, cached by source and size; a source that yields
// nothing is cached as missing so the next one is used.

@(private)
PROGRAM_ICON_LIMIT :: 32

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

// Where an icon comes from. `path` is an executable or PNG path, or the artwork's canonical name;
// `art` is set for artwork and borrows from App.program_art.
@(private)
Program_Icon_Want :: struct {
	source: Program_Icon_Source,
	path:   string,
	art:    program_art.Art,
	paint:  program_art.Paint,
}

@(private)
Program_Icon :: struct {
	using want: Program_Icon_Want,
	size:       int,
	pixels:     []u8,
	state:      Program_Icon_State,
	slot:       render.Atlas_Slot,
	used:       u64,
}

// Every slot, its eviction clock and its state transitions. At most PROGRAM_ICON_LIMIT icons are
// pending, which is the capacity Process_Worker reserves for icon jobs.
Program_Icon_Cache :: struct {
	icons: [PROGRAM_ICON_LIMIT]Program_Icon,
	clock: u64,
}

// One pending icon's read, run on the process worker. Its path and pixels are borrowed from the
// pending icon, which is never evicted while pending.
@(private)
Program_Icon_Job :: struct {
	index:  int,
	want:   Program_Icon_Want,
	size:   int,
	pixels: []u8,
	found:  bool,
}

// Run after the process worker has stopped, since pending icons are borrowed by its jobs.
program_icon_cache_destroy :: proc(cache: ^Program_Icon_Cache) {
	for &icon in cache.icons {
		delete(icon.path)
		delete(icon.pixels)
	}
	cache^ = {}
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
// icon is only made pending when a job will settle it. When no slot or memory is available nothing
// is queued and the caller still reports Pending (retained: the next draw asks again).
@(private)
program_icon_request :: proc(app: ^App, want: Program_Icon_Want, size: int) {
	cache := &app.program_icons
	if !process_worker_start(&app.processes, process_worker_platform(app)) {return}
	index := -1
	for icon, i in cache.icons {
		if icon.state == .Pending {continue}
		if index < 0 || icon.state == .Free || icon.used < cache.icons[index].used {index = i}
		if icon.state == .Free {break}
	}
	if index < 0 {return}
	icon := &cache.icons[index]
	if icon.state != .Free {program_icon_move(icon, .Free)}
	path_copy, path_error := strings.clone(want.path)
	pixels, pixel_error := make([]u8, size * size * 4)
	if path_error != nil || pixel_error != nil {
		delete(path_copy)
		delete(pixels)
		log.error("allocating a program icon failed")
		return
	}
	icon.want, icon.size, icon.pixels = want, size, pixels
	icon.path = path_copy
	icon.used = cache.clock
	program_icon_move(icon, .Pending)
	process_icon_request(&app.processes, {index = index, want = icon.want, size = size, pixels = pixels})
}

// Source identity belongs to the cache. A zero size is an observer's ready-at-any-size query,
// which deliberately ignores paint too: session.program.icon has always reported any ready icon.
@(private)
program_icon_find :: proc(
	cache: ^Program_Icon_Cache,
	want: Program_Icon_Want,
	size: int,
	states: bit_set[Program_Icon_State],
) -> ^Program_Icon {
	for &icon in cache.icons {
		if icon.state not_in states || icon.source != want.source || icon.path != want.path {continue}
		if size != 0 && (icon.size != size || icon.paint != want.paint) {continue}
		return &icon
	}
	return nil
}

// The atlas rectangle of one source's icon once it is ready; `state` is Pending while it is read.
// An empty path or a size the decoders refuse reports Missing, so the next source is used.
@(private)
program_icon_atlas :: proc(
	app: ^App,
	want: Program_Icon_Want,
	size: int,
) -> (
	rect: render.Rect,
	state: Program_Icon_State,
	result: render.Build_Status,
) {
	cache := &app.program_icons
	if want.path == "" || size < 1 || size > platform_api.EXECUTABLE_ICON_MAX {return {}, .Missing, .Ok}
	cache.clock += 1
	if icon := program_icon_find(cache, want, size, {.Pending, .Ready, .Missing}); icon != nil {
		icon.used = cache.clock
		if icon.state != .Ready {return {}, icon.state, .Ok}
		side := i32(size)
		atlas, status := render.atlas_ensure(app.device, &icon.slot, side, side, icon.pixels, size, true)
		if status != .Ok {return {}, .Pending, status}
		return atlas, .Ready, .Ok
	}
	program_icon_request(app, want, size)
	return {}, .Pending, .Ok
}

// Settles the icon reads the worker finished; reports whether one produced an icon to draw, and
// the path of a user's PNG that could not be read, valid until the icon is reused.
program_icons_adopt :: proc(app: ^App) -> (ready: bool, unreadable: string) {
	done: [PROGRAM_ICON_LIMIT]Program_Icon_Job
	for job in done[:process_icon_results(&app.processes, done[:])] {
		icon := &app.program_icons.icons[job.index]
		program_icon_move(icon, job.found ? .Ready : .Missing)
		ready ||= job.found
		if !job.found && job.want.source == .File {unreadable = icon.path}
	}
	return
}

// The badge for a pane drawn `size` pixels square: its program's icon once one is ready, otherwise
// its shell's (pane_badge_source). While a preferred source is still being read the next one stands
// in, so a lesser icon never flashes first; the text badge stands in for them all.
pane_icon :: proc(
	app: ^App,
	entry: ^Session_Entry,
	size: f32,
) -> (
	badge: string,
	atlas: render.Rect,
	result: render.Build_Status,
) {
	if entry == nil {return}
	pixels := int(math.round(size))
	program := program_adopted(entry)
	if app.settings.tabs.program_icons && program != nil && program.name != "" {
		want, found := program_icon_source(app, program, pixels, .Draw)
		if found {
			state: Program_Icon_State
			atlas, state, result = program_icon_atlas(app, want, pixels)
			if result != .Ok || state == .Ready {return}
			atlas = {}
		}
	}
	badge = entry.header.icon
	image, executable := pane_badge_source(app, entry)
	if image != nil {
		atlas, result = shell_icon_atlas(app, image)
	} else {
		atlas, _, result = program_icon_atlas(app, {source = .Executable, path = executable}, pixels)
	}
	return
}

// What stands for a pane's shell when no program icon does: the Icon of the profile it was launched
// with once loaded, otherwise the launched executable's own icon, read at the drawn size. The
// session's text badge stands in while that is read, and for good when there is none.
pane_badge_source :: proc(app: ^App, entry: ^Session_Entry) -> (image: ^Shell_Icon, executable: string) {
	if image = shell_icon_find(app, entry.profile_id); image != nil {return}
	return nil, entry.header.executable_path
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
	result: render.Build_Status,
) {
	if app.settings.tabs.program_icons && name != "" {
		pixels := int(math.round(size))
		art, has_art := program_art_find(app, name)
		want, found := program_named_source(app, name, art, has_art, pixels, .Draw)
		if found {
			state: Program_Icon_State
			atlas, state, result = program_icon_atlas(app, want, pixels)
			if result != .Ok || state == .Ready {return}
			if state == .Pending {return {}, true, .Ok}
		}
	}
	_, atlas, result = pane_icon(app, entry, size)
	return
}

// Whether a source lookup marks the missing entries it consults as recently used. Drawing does, so
// they outlive idle entries; an observer leaves the cache as it is.
Program_Icon_Lookup :: enum {
	Draw,
	Observe,
}

// The first source in precedence order that has not turned out to be missing at this size.
@(private)
program_icon_source :: proc(
	app: ^App,
	program: ^Program_Adopted,
	size: int,
	lookup: Program_Icon_Lookup,
) -> (
	want: Program_Icon_Want,
	found: bool,
) {
	want, found = program_named_source(app, program.name, program.art, program.has_art, size, lookup)
	if found {return}
	executable := Program_Icon_Want{source = .Executable, path = program.path}
	if program.path != "" && !program_icon_missing(app, executable, size, lookup) {return executable, true}
	return {}, false
}

// The user's PNG for a program's name, then its bundled artwork.
// Size zero is the state report's observer query: the first named source ready at any size/paint,
// rather than the first source not known missing at a particular draw size.
@(private)
program_named_source :: proc(
	app: ^App,
	name: string,
	art: program_art.Art,
	has_art: bool,
	size: int,
	lookup: Program_Icon_Lookup,
) -> (
	want: Program_Icon_Want,
	found: bool,
) {
	if file, ok := program_named_file(app, name, art, has_art); ok {
		want = {source = .File, path = file}
		if size == 0 {
			if program_icon_find(&app.program_icons, want, 0, {.Ready}) != nil {return want, true}
		} else if !program_icon_missing(app, want, size, lookup) {return want, true}
	}
	if has_art {
		paint := program_art_paint(app, art)
		want = {source = .Artwork, path = program_art.canonical(art), art = art, paint = paint}
		if size == 0 {
			if program_icon_find(&app.program_icons, want, 0, {.Ready}) != nil {return want, true}
		} else if !program_icon_missing(app, want, size, lookup) {return want, true}
	}
	return {}, false
}

@(private)
program_icon_missing :: proc(
	app: ^App,
	want: Program_Icon_Want,
	size: int,
	lookup: Program_Icon_Lookup,
) -> bool {
	cache := &app.program_icons
	if icon := program_icon_find(cache, want, size, {.Missing}); icon != nil {
		if lookup == .Draw {icon.used = cache.clock}
		return true
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
	path, err := localpath.settings_relative(file, app.settings_path, context.temp_allocator)
	return path, err == .None
}

// Artwork is drawn in its brand colours when every one stands out from the tab background,
// otherwise wholly in the tab text colour, so dark logos stay visible on dark themes and light ones
// on light themes, and a multi-colour logo is never partly recoloured.
@(private)
program_art_paint :: proc(app: ^App, art: program_art.Art) -> (paint: program_art.Paint) {
	paint.text = app.settings.active_theme.colors[.Tab_Text].rgb
	for layer in art.layers {
		if !layer.branded {continue}
		if colour.contrast_ratio(colour.rgba(layer.colour), app.theme.tab_bar) < PROGRAM_ART_CONTRAST {
			paint.mono = true
			return
		}
	}
	return
}

when AIO_CONTROL {
	// session.program.source has always been looked up at 16 pixels, a rail tab's icon at 100% scale;
	// a source missing only at another drawn size does not change it.
	PROGRAM_ICON_REPORT_SIZE :: 16

	// The pane's program icon: the source it would draw from, and whether an icon is ready at any
	// size from any source. Reading them leaves the cache's use order alone.
	program_icon_state_report :: proc(r: ^State_Report, app: ^App, entry: ^Session_Entry) {
		want: Program_Icon_Want
		found, ready := false, false
		if program := program_adopted(entry); program != nil && program.name != "" {
			want, found = program_icon_source(app, program, PROGRAM_ICON_REPORT_SIZE, .Observe)
			_, ready = program_named_source(app, program.name, program.art, program.has_art, 0, .Observe)
			if !ready && program.path != "" {
				executable := Program_Icon_Want{source = .Executable, path = program.path}
				ready = program_icon_find(&app.program_icons, executable, 0, {.Ready}) != nil
			}
		}
		if found {
			state_word(r, "session.program.source", want.source)
		} else {
			state_text(r, "session.program.source", "")
		}
		state_value(r, "session.program.icon", ready)
	}
}

// Drops PNG icons so edited files and settings are read again; ones being read are left alone.
program_icons_reload :: proc(app: ^App) {
	for &icon in app.program_icons.icons {
		if icon.source != .File || icon.state == .Pending || icon.state == .Free {continue}
		program_icon_move(&icon, .Free)
	}
}

// Runs on the process worker: reads or draws one icon into its job's pixels.
@(private)
program_icon_read :: proc(job: Program_Icon_Job) -> bool {
	switch job.want.source {
	case .Executable:
		return platform_api.executable_icon(job.want.path, job.size, job.pixels)
	case .Artwork:
		return program_art.draw(job.want.art, job.size, job.want.paint, job.pixels)
	case .File:
		return program_icon_png(job.want.path, job.size, job.pixels)
	}
	return false
}

// A user's PNG fitted into size x size, centred, each pixel averaging the source pixels it covers
// (the shell icon samples nearest-neighbour instead).
@(private)
program_icon_png :: proc(path: string, size: int, pixels: []u8) -> bool {
	image, load_error := icon_png_load(path)
	defer png.destroy(image)
	if load_error != .None {return false}
	source := image.pixels.buf[:]
	longest := max(image.width, image.height)
	width, height := max(1, image.width * size / longest), max(1, image.height * size / longest)
	left, top := (size - width) / 2, (size - height) / 2
	slice.fill(pixels[:size * size * 4], 0)
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
			to := ((top + y) * size + left + x) * 4
			for c in 0 ..< 4 {pixels[to + c] = u8((sum[c] + count / 2) / count)}
		}
	}
	return true
}
