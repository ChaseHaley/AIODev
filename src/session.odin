package main

import "aio:layout"
import "aio:localpath"
import "aio:platform"
import "aio:pty"
import "aio:settings"
import "aio:term"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

// The terminal session registry: opening, finding, restarting and closing the sessions panes show,
// and the record of how closed sessions ended. app.next_session_id is this file's allocation state;
// everything else learns a session's id from the procedure that opened it.

Session_Entry :: struct {
	id:                  u32,
	session:             ^term.Session,
	status:              term.Status_Kind,
	keep_open:           bool,
	process_padding:     Maybe(int),
	process_name:        [780]u8,
	process_name_length: int,
	header:              Pane_Header_Metadata,
	name:                string,
	profile_id:          string,
	// The program status records last copied from the session, and the last notice they raised.
	statuses:            []term.Program_Status,
	status_notified:     time.Tick,
	// The program its icon names and a reopened pane remembers, as process polling sees it.
	program:             Program,
	documents:           Document_List,
}

// Release only the entry's owned memory; callers own removal from app.sessions.
session_entry_destroy :: proc(entry: ^Session_Entry) {
	documents_destroy(&entry.documents)
	pane_header_destroy(&entry.header)
	delete(entry.name)
	delete(entry.profile_id)
	status_release(entry)
	program_forget(entry)
	term.destroy(entry.session)
}

Closed_Session :: struct {
	id:        u32,
	status:    term.Status_Kind,
	exit_code: u32,
}

// How the most recently closed sessions ended, oldest overwritten first. A pane closes as its
// program exits, so a CLI wait that polls afterwards still learns the exit code.
Closed_Sessions :: struct {
	entries: [32]Closed_Session,
	next:    int,
}

@(private)
closed_sessions_record :: proc(history: ^Closed_Sessions, closed: Closed_Session) {
	history.entries[history.next] = closed
	history.next = (history.next + 1) % len(history.entries)
}

// The newest record of how session `id` ended. Id 0 names no session; unused records hold it.
@(private, require_results)
closed_session_find :: proc(history: ^Closed_Sessions, id: u32) -> (Closed_Session, bool) {
	if id == 0 {return {}, false}
	for offset in 1 ..= len(history.entries) {
		index := (history.next - offset + len(history.entries)) % len(history.entries)
		if history.entries[index].id == id {return history.entries[index], true}
	}
	return {}, false
}

@(private)
PANE_VARIABLE :: "AIODEV_PANE"
@(private)
INSTANCE_VARIABLE :: "AIODEV_INSTANCE"

// `pane` is the session id the launch serves. The shell learns it from AIODEV_PANE, so the aio command
// line acts on "here" by default, and finds aio itself on PATH.
@(private)
session_config :: proc(
	app: ^App,
	pane: u32,
	geometry: term.Geometry,
	profile: ^settings.Profile,
	command_override: string = "",
) -> term.Config {
	base := settings.profile_base(&app.settings.profiles)
	directory_text, command, title := base.directory, base.command, ""
	if profile != nil {
		directory_text, command, title = profile.directory, profile.command, profile.name
	}
	if command_override != "" {command, title = command_override, ""}
	directory, err := localpath.expand_home(directory_text, context.temp_allocator)
	if err != nil {
		log.errorf("expanding the shell directory failed: %v", err)
		directory = directory_text
	}
	environment := make([dynamic]pty.Env_Var, 0, 2, context.temp_allocator)
	append(&environment, pty.Env_Var{PANE_VARIABLE, fmt.tprintf("%d", pane)})
	if app.options.name != "" {append(&environment, pty.Env_Var{INSTANCE_VARIABLE, app.options.name})}
	return {
		command_line = settings.shell_command_line(command, app.settings.shell.integration),
		title = title,
		environment = environment[:],
		path_append = app.cli_directory,
		refresh_environment = app.settings.shell.refresh_environment,
		working_directory = directory,
		geometry = geometry,
		options = session_options(app),
		colors = terminal_colors(app.settings.colors),
	}
}

// Opens a session and returns the id it was registered under. The session may hold a shell that
// failed to start; only a session that could not be created or registered fails.
@(private, require_results)
session_open :: proc(
	app: ^App,
	command: string = "",
	directory: string = "",
	profile_id: string = "",
	last_command: string = "",
) -> (
	id: u32,
	ok: bool,
) {
	profile, _ := settings.profile_resolve(&app.settings, profile_id)
	geometry := initial_geometry(app)
	config := session_config(app, app.next_session_id + 1, geometry, profile, command)
	// A reopened pane notes what it was running above the fresh shell's first prompt.
	if shown := printable_command(last_command, context.temp_allocator); shown != "" {
		config.preface = fmt.tprintf("\x1b[2mLast running: %s\x1b[0m\r\n", shown)
	}
	// Defense in depth: every caller filters its directory, but an untrusted one must never reach
	// CreateProcess. Falling back here keeps the pane usable instead of failing the whole open.
	launch_directory, refused := local_launch_directory(directory)
	if refused {
		notify(
			app,
			.Warning,
			"The requested directory is remote or unavailable; using the profile's default.",
		)
	}
	if launch_directory != "" {config.working_directory = launch_directory}
	session, err := term.create(config, {wake_platform, &app.platform})
	if err != .None {
		log.errorf("creating the terminal session failed: %v", err)
		return 0, false
	}
	resolved_id := profile_id
	if resolved_id == "" && profile != nil {resolved_id = profile.id}
	owned_id, id_error := strings.clone(resolved_id)
	if id_error != nil {
		term.destroy(session)
		return 0, false
	}
	app.next_session_id += 1
	id = app.next_session_id
	if _, allocation_error := append(
		&app.sessions,
		Session_Entry {
			id = id,
			session = session,
			profile_id = owned_id,
		},
	); allocation_error != nil {
		delete(owned_id)
		term.destroy(session)
		return 0, false
	}
	pane_header_launch(&app.sessions[len(app.sessions) - 1].header, config)
	session_status_sync(&app.sessions[len(app.sessions) - 1])
	return id, true
}

// The settings a running session follows; create, restart and configure all take the whole set.
@(private)
session_options :: proc(app: ^App) -> term.Options {
	cursor: term.Cursor_Style
	switch app.settings.cursor.style {
	case .Block:
		cursor = .Block
	case .Bar:
		cursor = .Bar
	case .Underline:
		cursor = .Underline
	}
	return {
		scrollback_lines = app.settings.scrollback.lines,
		cursor = cursor,
		cursor_blink = app.settings.cursor.blink,
		program_status_enabled = app.settings.status.enabled,
	}
}

session_find :: proc(app: ^App, id: u32) -> ^Session_Entry {
	for &entry in app.sessions {
		if entry.id == id {
			return &entry
		}
	}
	return nil
}

// What a session's pane is called: the name the user gave it, else the title its program reports.
session_display_title :: proc(entry: ^Session_Entry) -> string {
	return entry.name != "" ? entry.name : pane_header_title(&entry.header)
}

// Session_Entry.status is the frame's copy of the session's process phase, so drawing never takes
// the session mutex. This is its only writer; it reports whether the copy changed.
@(private)
session_status_sync :: proc(entry: ^Session_Entry) -> (status: term.Status, changed: bool) {
	status = term.status(entry.session)
	changed = status.kind != entry.status
	entry.status = status.kind
	return
}

session_restart :: proc(app: ^App, entry: ^Session_Entry) {
	geometry := term.geometry(entry.session)
	profile, requested := settings.profile_resolve(&app.settings, entry.profile_id)
	config := session_config(app, entry.id, geometry, profile)
	// A removed or unusable profile restarts from the exact line it last launched, without
	// applying the directory-reporting wrapper a second time.
	if !requested && entry.profile_id != "" && entry.header.command != "" {
		config.command_line = entry.header.command
		if entry.header.launch_directory != "" {
			config.working_directory = entry.header.launch_directory
		}
	}
	session_relaunch(app, entry, config)
}

// Runs `config` in the session's place, as a restart and a shell switch do; the header shows the new
// launch and the status what the new process reports.
session_relaunch :: proc(app: ^App, entry: ^Session_Entry, config: term.Config) {
	term.restart(entry.session, config)
	pane_header_launch(&entry.header, config)
	pane_header_refresh(entry)
	session_status_sync(entry)
	mark_all_dirty(app)
}

// The per-tick poll of every session: search progress, status, title, program status and bell, then
// the windows whose shown screens changed.
@(private)
update_sessions :: proc(app: ^App) {
	workspace_status_changed := false
	// Exit cleanup removes only the current entry; earlier entries remain valid.
	for i := len(app.sessions) - 1; i >= 0; i -= 1 {
		entry := &app.sessions[i]
		s := entry.session
		if term.take_status_change(s) {
			workspace_status_changed = true
			layout_state_touch(app)
			status, changed := session_status_sync(entry)
			if changed {mark_all_dirty(app)}
			if status.kind == .Exited && close_exited_session(app, entry.id) {continue}
		}
		if term.take_title_change(s) {
			layout_state_touch(app)
			pane_header_refresh(entry)
			session_titles_changed(app, entry.id)
		}
		if term.take_program_status_change(s) {
			workspace_status_changed = true
			status_refresh(app, entry)
			if status_watched(app, entry) {term.program_status_acknowledge(s)}
			mark_all_dirty(app)
		}
		if term.take_bell(s) {
			for window in app.windows {
				if !window.focused && window.phase == .Shown &&
				   platform.window_flash(&app.platform, window.id) != .None {
					log.error("flashing the window failed")
				}
			}
		}
	}
	if workspace_status_changed {
		workspace_picker_status_changed(app)
		for window in app.windows {status_taskbar_update(app, window)}
	}
	for window in app.windows {
		generation := window_generation(app, window)
		if generation != window.generation {
			window.generation = generation
			link_hover_refresh(app, window)
			window.dirty = true
		}
	}
}

// A sum of the generations of the sessions w shows, which changes whenever one of their screens does.
window_generation :: proc(app: ^App, w: ^Window) -> u64 {
	generation: u64
	for pane in w.panes {
		if entry := workspace_session_for_content(app, pane.content); entry != nil {
			generation += term.generation(entry.session)
		}
	}
	return generation
}

session_close :: proc(app: ^App, id: u32) {
	for &entry, i in app.sessions {
		if entry.id == id {
			status := term.status(entry.session)
			closed_sessions_record(&app.closed_sessions, {id, status.kind, status.exit_code})
			session_entry_destroy(&entry)
			ordered_remove(&app.sessions, i)
			return
		}
	}
}

@(require_results)
close_exited_session :: #force_no_inline proc(app: ^App, id: u32) -> bool {
	if entry := session_find(app, id); entry != nil && entry.keep_open {return false}
	workspace, pane, found := session_pane_find(app, id)
	if !found {return false}
	if len(workspace.tabs) == 1 && workspace.tabs[pane.tab].tree.root == pane.node {return false}
	pane_close_at(app, workspace, pane.tab, pane.node)
	return true
}

session_titles_changed :: #force_no_inline proc(app: ^App, id: u32) {
	for workspace in app.workspaces {
		session_workspace_titles_changed(app, workspace, id)
	}
	for window in app.windows {
		// Linked views own private workspaces, outside app.workspaces.
		if window_linked(window) {session_workspace_titles_changed(app, window.workspace, id)}
		window.dirty = true
		if tree := window_tree(window); tree != nil {
			node := layout.find_content(tree, {.Terminal, id})
			if floating, ok := layout.float_of(tree, node); ok && floating.minimized {
				floating_capsules_refresh(app, window)
			}
		}
		if focused := focused_session(app, window); focused != nil && focused.id == id {
			window_update_title(app, window)
		}
	}
}

@(private = "file")
session_workspace_titles_changed :: proc(app: ^App, workspace: ^Workspace, id: u32) {
	for tab in workspace.tabs {
		content, is_pane := layout.focused_content(&tab.tree)
		if is_pane && content == {.Terminal, id} {tab_update_title(app, tab)}
	}
}

session_message :: proc(status: term.Status) -> string {
	switch status.kind {
	case .Running:
		return ""
	case .Exited:
		return fmt.tprintf(
			"The shell exited with code %d. Press Enter to restart it.",
			status.exit_code,
		)
	case .Failed:
		reason := status.message != "" ? status.message : "Could not start the shell."
		return fmt.tprintf(
			"%s Check shell.command and shell.directory in settings, " +
			"then press Enter to try again.",
			reason,
		)
	}
	return ""
}
