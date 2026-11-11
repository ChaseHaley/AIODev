package main

import "aio:localpath"
import "aio:procinfo"
import "aio:pty"
import "aio:render"
import "aio:settings"
import "core:log"
import "core:math"
import "core:path/filepath"
import "core:strings"

// Link program icons (WORK-395). A program shows its own Icon PNG, then what a pane running it would
// show by name (a tabs.program_icon_files PNG, then bundled artwork such as Neovim's), then its
// executable's icon. Each comes from the program icon cache, read at the drawn size on the process
// worker; while the preferred source is read, or when none has an icon, the row keeps its glyph.

// What one link program's command line runs, found when settings apply rather than on every draw.
// Owned.
Link_Program_Target :: struct {
	// The program and the command line this was found for.
	id, command: string,
	// The executable stem, lowercase, as program artwork is named: `nvim` for `nvim %1`.
	name:        string,
	// The executable found for it; empty for a batch script, whose icon would be cmd's, or a program
	// that is not installed.
	path:        string,
}

link_programs_destroy :: proc(targets: ^[dynamic]Link_Program_Target) {
	for &target in targets {link_program_target_destroy(&target)}
	delete(targets^)
	targets^ = nil
}

// Finds what each link program runs. A program whose command line is unchanged keeps what was found, so
// a settings save that touches no command line searches nothing; the search directories are read once.
link_programs_load :: proc(app: ^App) {
	previous := app.link_programs
	app.link_programs = nil
	defer link_programs_destroy(&previous)
	directories: []string
	defer {
		for directory in directories {delete(directory)}
		delete(directories)
	}
	searched := false
	next: for &opener in app.settings.openers.items {
		for &old in previous {
			if old.id != opener.id || old.command != opener.command {continue}
			if _, append_error := append(&app.link_programs, old); append_error != nil {
				log.error("keeping a link program's executable failed")
				continue next
			}
			old = {}
			continue next
		}
		if !searched {
			searched = true
			if found, err := pty.search_directories(); err == nil {directories = found}
		}
		target := link_program_target_find(&opener, directories)
		if target.id == "" {
			link_program_target_destroy(&target)
			log.error("keeping a link program's executable failed")
			continue
		}
		if _, append_error := append(&app.link_programs, target); append_error != nil {
			link_program_target_destroy(&target)
			log.error("keeping a link program's executable failed")
		}
	}
	mark_all_dirty(app)
}

// Finds what `opener` runs among `directories`. An empty id means a copy could not be made.
@(private = "file")
link_program_target_find :: proc(
	opener: ^settings.Opener,
	directories: []string,
) -> (
	target: Link_Program_Target,
) {
	token := pty.executable_token(opener.command)
	id, id_error := strings.clone(opener.id)
	command, command_error := strings.clone(opener.command)
	name, name_error := strings.to_lower(procinfo.executable_stem(filepath.base(token)))
	target = {id = id, command = command, name = name}
	if program, err := pty.resolve_program_in(opener.command, directories); err.kind == .None {
		if program.batch {
			pty.program_destroy(&program)
		} else {
			target.path = program.path
		}
	}
	if id_error != nil || command_error != nil || name_error != nil {
		delete(target.id)
		target.id = ""
	}
	return
}

@(private = "file")
link_program_target_destroy :: proc(target: ^Link_Program_Target) {
	delete(target.id)
	delete(target.command)
	delete(target.name)
	delete(target.path)
	target^ = {}
}

@(private = "file")
link_program_target :: proc(app: ^App, id: string) -> ^Link_Program_Target {
	for &target in app.link_programs {
		if target.id == id {return &target}
	}
	return nil
}

// The image for link program `opener` drawn `size` pixels square, once its icon is ready; empty while
// it is read or when no source has one.
link_program_icon :: proc(
	app: ^App,
	opener: ^settings.Opener,
	size: f32,
) -> (
	render.Rect,
	render.Build_Status,
) {
	pixels := int(math.round(size))
	want, found := link_program_icon_source(app, opener, pixels)
	if !found {return {}, .Ok}
	atlas, state, result := program_icon_atlas(app, want, pixels)
	if state != .Ready {return {}, result}
	return atlas, result
}

// The first source in precedence order that has not turned out to be missing at this size.
@(private = "file")
link_program_icon_source :: proc(
	app: ^App,
	opener: ^settings.Opener,
	size: int,
) -> (
	want: Program_Icon_Want,
	found: bool,
) {
	if opener.icon != "" {
		path, err := localpath.settings_relative(opener.icon, app.settings_path, context.temp_allocator)
		if err == .None {
			want = {source = .File, path = path}
			if !program_icon_missing(app, want, size, .Draw) {return want, true}
		}
	}
	target := link_program_target(app, opener.id)
	if target == nil {return {}, false}
	if target.name != "" {
		art, has_art := program_art_find(app, target.name)
		if want, found = program_named_source(app, target.name, art, has_art, size, .Draw); found {return}
	}
	executable := Program_Icon_Want{source = .Executable, path = target.path}
	if target.path != "" && !program_icon_missing(app, executable, size, .Draw) {return executable, true}
	return {}, false
}
