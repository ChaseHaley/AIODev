package main

import "aio:program_art"
import "aio:pty"
import "aio:settings"
import "aio:term"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// Which program each pane runs (WORK-272, WORK-279): named by its executable stem, the script a
// launcher runs, or the app a WSL or SSH session reports. Split directories, remembered commands
// and program icons read it.

// A remembered command longer than this is cut; it only reminds the user what ran.
@(private)
PROGRAM_COMMAND_LIMIT :: 240

// Launchers run the program named by their arguments rather than being one.
@(private, rodata)
program_launchers := [?]string{"node", "bun", "deno", "npx", "pnpx", "bunx", "cmd", "uv", "uvx"}

// Bridges run programs out of Windows' sight, which can only be named by what they report.
@(private, rodata)
program_bridges := [?]string{"wsl", "ssh", "mosh", "mosh-client", "docker", "podman"}

// Programs are polled only while program icons are shown; otherwise each lookup samples a
// snapshot taken at that moment. Retained policy: polling costs a snapshot every interval.
program_polling :: proc(app: ^App) -> bool {
	return app.settings.tabs.program_icons
}

// The bundled artwork for an executable stem or reported app key.
program_art_find :: proc(app: ^App, name: string) -> (program_art.Art, bool) {
	return program_art.find(&app.program_art, settings.executable_stem(name))
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
		// A program seen once never showed, so its end changes nothing drawn or saved.
		if _, seen := entry.program.(Program_Seen); seen {entry.program = nil; return false}
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
	program_name_set(app, program, name)
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
	program_name_set(app, &program, name)
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
	if _, found := program_art_find(app, name); found {return true}
	_, found := settings.program_icon_file(&app.settings, name)
	return found
}

@(private)
program_listed :: proc(names: []string, stem: string) -> bool {
	for name in names {if strings.equal_fold(name, stem) {return true}}
	return false
}

@(private)
program_name_set :: proc(app: ^App, program: ^Program_Adopted, name: string) {
	lower := strings.to_lower(name)
	delete(program.name)
	program.name = lower
	program.art, program.has_art = program_art_find(app, lower)
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

// The pane's running program. Polling already tracks it, including one seen once but not yet
// adopted; without polling it is chosen the same way from a snapshot taken now (about 10 ms).
@(private)
pane_program :: proc(app: ^App, entry: ^Session_Entry) -> u32 {
	if program_polling(app) {
		return program_polled(entry)
	}
	processes, err := pty.process_snapshot(context.temp_allocator)
	if err != .None {return 0}
	program, _ := pane_running(app, entry, processes)
	return program
}

// The processes to read running programs from when a pane is remembered: nil while polling
// tracks them, otherwise one snapshot taken now, in temporary memory.
pane_processes :: proc(app: ^App) -> []pty.Process_Info {
	if program_polling(app) || len(app.sessions) == 0 {return nil}
	processes, err := pty.process_snapshot(context.temp_allocator)
	return err == .None ? processes : nil
}

// The pane's running program and how it was started, in temporary memory: polling's choice, or the
// one `processes` names; none without either.
pane_running :: proc(
	app: ^App,
	entry: ^Session_Entry,
	processes: []pty.Process_Info,
) -> (
	program: u32,
	command: string,
) {
	if program_polling(app) {
		if adopted := program_adopted(entry); adopted != nil {command = adopted.command}
		return program_polled(entry), command
	}
	root := term.process_id(entry.session)
	index := pty.process_program(processes, root, program_reporters(entry), 0)
	if index < 0 {return}
	program = processes[index].id
	arguments, _ := pty.process_arguments(program, root, context.temp_allocator)
	stem := settings.executable_stem(processes[index].executable)
	return program, program_command(arguments, stem, context.temp_allocator)
}
