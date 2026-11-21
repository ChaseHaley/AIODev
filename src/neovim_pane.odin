package main

import "aio:commands"
import "aio:colour"
import "aio:input"
import "aio:layout"
import "aio:neovim"
import platform_api "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:spawn"
import "aio:term_view"
import "aio:ui"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

// Neovim panes (WORK-542, D-107). Each pane starts its own `nvim --embed` the first time it is laid out,
// at the size it is shown, and AIODev is that Neovim's UI: it draws the grid itself and sends keys and
// the mouse through Neovim's API, with no terminal or shell between them.

NEOVIM_PROGRAM :: "nvim"

// How often panes no layout shows any more are let go, ending their Neovim.
@(private)
NEOVIM_SWEEP :: 500 * time.Millisecond

// App-wide registry of Neovim panes. Embedded in App.
Neovim_App :: struct {
	neovim_panes:    [dynamic]^Neovim_Pane,
	next_neovim_id:  u32,
	// Set by the process threads when any Neovim has news; neovim_tick polls every pane once it is.
	neovim_woken:    bool,
	neovim_deadline: time.Tick,
	// The mouse button pressed on a Neovim pane, which its drags and release follow.
	neovim_drag:     Neovim_Drag,
	// Wheel lines not yet sent, as Neovim scrolls by whole wheel events.
	neovim_wheel:    [2]f32,
}

@(private)
Neovim_Drag :: struct {
	window: input.Window_Id,
	pane:   u32,
	button: neovim.Mouse_Button,
	cell:   [2]int,
	active: bool,
}

Neovim_Pane :: struct {
	id:        u32,
	client:    neovim.Client,
	view:      term_view.Neovim_View,
	// What the pane started with, so a restored layout or a reopened pane starts it the same way.
	file:      string,
	directory: string,
	line:      int,
	started:   bool,
	exited:    bool,
	// Why Neovim is not running, shown in the pane: it could not start, or it exited.
	message:   string,
	// The terminal session of the shell the pane opened over, running out of sight until Neovim quits and
	// the pane shows it again; 0 for none. The pane owns it: closing the pane ends it.
	shell:     u32,
	// A close waits on Neovim's question about unsaved buffers; when Neovim then quits, the pane closes
	// instead of showing a shell.
	closing:   bool,
	// Opened over a shell and started at the size of the shell's pane, but not shown yet: Neovim takes
	// the pane at its first screen, so the pane never shows an empty grid in between (NEOVIM_TAKE_WAIT).
	pending:   bool,
	opened:    time.Tick,
}

@(require_results)
neovim_find :: proc(app: ^App, id: u32) -> ^Neovim_Pane {
	for pane in app.neovim_panes {if pane.id == id {return pane}}
	return nil
}

@(private = "file")
neovim_pane_destroy :: proc(pane: ^Neovim_Pane) {
	neovim.destroy(&pane.client)
	term_view.neovim_view_destroy(&pane.view)
	delete(pane.file)
	delete(pane.directory)
	free(pane)
}

// Ends the pane's Neovim and the shell it opened over.
@(private = "file")
neovim_pane_release :: proc(app: ^App, pane: ^Neovim_Pane) {
	if pane.shell != 0 {session_close(app, pane.shell)}
	neovim_pane_destroy(pane)
}

// Sessions are already gone when the app ends, so the panes' shells are not closed again.
neovim_app_destroy :: proc(state: ^Neovim_App) {
	for pane in state.neovim_panes {neovim_pane_destroy(pane)}
	delete(state.neovim_panes)
	state^ = {}
}

// A pane that opens `file` (none for an empty buffer) at 1-based `line` (0 for Neovim's choice), in
// `directory`. Neovim starts once the pane is laid out.
@(require_results)
neovim_pane_create :: proc(app: ^App, file, directory: string, line := 0) -> ^Neovim_Pane {
	pane, err := new(Neovim_Pane)
	if err != nil {return nil}
	pane.line = line
	file_error, directory_error: runtime.Allocator_Error
	pane.file, file_error = strings.clone(file)
	pane.directory, directory_error = strings.clone(directory)
	if file_error != nil || directory_error != nil {
		neovim_pane_destroy(pane)
		return nil
	}
	if _, append_error := append(&app.neovim_panes, pane); append_error != nil {
		neovim_pane_destroy(pane)
		return nil
	}
	app.next_neovim_id += 1
	pane.id = app.next_neovim_id
	if app.neovim_deadline == {} {app.neovim_deadline = time.tick_add(clock_now(&app.clock), NEOVIM_SWEEP)}
	return pane
}

@(private)
neovim_pane_remove :: proc(app: ^App, id: u32) {
	for pane, i in app.neovim_panes {
		if pane.id != id {continue}
		neovim_pane_release(app, pane)
		ordered_remove(&app.neovim_panes, i)
		return
	}
}

// Process threads call this; it only flags the host and wakes the loop.
@(private = "file")
neovim_wake :: proc "contextless" (data: rawptr) {
	app := (^App)(data)
	sync.atomic_store(&app.neovim_woken, true)
	context = runtime.default_context()
	_ = platform_api.wake(&app.platform)
}

// What Neovim inherits beyond AIODev's own environment, as a shell in a pane does: the `aio` beside this
// AIODev first on PATH and named by AIODEV_CLI, the instance name, and the theme record D-105 reads.
@(private = "file")
neovim_environment :: proc(app: ^App) -> []string {
	environment := make([dynamic]string, 0, 4, context.temp_allocator)
	if app.options.name != "" {append(&environment, fmt.tprintf("%s=%s", INSTANCE_VARIABLE, app.options.name))}
	if app.cli_directory != "" {
		append(&environment, fmt.tprintf(`%s=%s\%s`, CLI_VARIABLE, app.cli_directory, CLI_EXECUTABLE))
		path, _ := os.lookup_env("PATH", context.temp_allocator)
		append(&environment, fmt.tprintf("PATH=%s;%s", app.cli_directory, path))
	}
	if record := theme_record_path(app); record != "" {
		append(&environment, fmt.tprintf("%s=%s", settings.NEOVIM_RECORD_VARIABLE, record))
	}
	return environment[:]
}

@(private)
neovim_pane_start :: proc(app: ^App, pane: ^Neovim_Pane, columns, rows: int) {
	pane.started = true
	argv := make([dynamic]string, 0, 5, context.temp_allocator)
	append(&argv, NEOVIM_PROGRAM, "--embed")
	if pane.line > 0 {append(&argv, fmt.tprintf("+%d", pane.line))}
	if pane.file != "" {append(&argv, "--", pane.file)}
	directory := pane.directory
	if directory == "" || !os.is_dir(directory) {directory = home_directory()}
	options := neovim.Start {
		argv = argv[:], cwd = directory, env = neovim_environment(app), columns = columns, rows = rows,
	}
	switch neovim.start(&pane.client, options, spawn.Wake{app, neovim_wake}) {
	case .None:
		return
	case .Not_Found:
		pane.message = "nvim is not on PATH, so Neovim cannot start here."
	case .Start_Failed, .Closed, .Protocol:
		pane.message = "Neovim could not start."
	case .Out_Of_Memory:
		pane.message = "Neovim could not start: out of memory."
	}
	pane.exited = true
	log.errorf("starting Neovim for a pane failed: %s", pane.message)
}

// The padding a pane gives Neovim's grid: the one a padding group gives nvim, as in a terminal pane.
@(private)
neovim_insets :: proc(app: ^App, w: ^Window) -> Pane_Insets {
	padding, _ := settings.process_padding(&app.settings, NEOVIM_PROGRAM)
	return {padding = math.round(f32(padding) * w.scale), header = pane_header_height(w.scale)}
}

// Sizes the pane's Neovim to its rectangle, starting it at that size the first time.
@(private)
neovim_pane_fit :: proc(app: ^App, w: ^Window, rect: layout.Pane_Rect) {
	pane := neovim_find(app, rect.content.id)
	if pane == nil || pane.exited {return}
	box := pane_box(w.metrics, rect.rect, neovim_insets(app, w))
	columns, rows := int(box.columns), int(box.rows)
	if !pane.started {
		neovim_pane_start(app, pane, columns, rows)
		return
	}
	if neovim.resize(&pane.client, columns, rows) != .None {neovim_lost(app)}
}

// A write to Neovim failed: it is gone, which the next poll reports as its exit.
@(private = "file")
neovim_lost :: proc(app: ^App) {
	sync.atomic_store(&app.neovim_woken, true)
}

neovim_deadline :: proc(app: ^App) -> (next: time.Tick, pending: bool) {
	if app.neovim_deadline == {} {return}
	return app.neovim_deadline, true
}

neovim_tick :: proc(app: ^App) {
	if sync.atomic_exchange(&app.neovim_woken, false) {
		for i := 0; i < len(app.neovim_panes); i += 1 {neovim_pane_poll(app, app.neovim_panes[i])}
	}
	if app.neovim_deadline == {} {return}
	now := clock_now(&app.clock)
	if time.tick_diff(now, app.neovim_deadline) > 0 {return}
	for i := len(app.neovim_panes) - 1; i >= 0; i -= 1 {
		pane := app.neovim_panes[i]
		if pane.pending && time.tick_diff(pane.opened, now) >= NEOVIM_TAKE_WAIT {neovim_take_pane(app, pane)}
		if pane.pending || neovim_shown_anywhere(app, pane.id) {continue}
		neovim_pane_release(app, app.neovim_panes[i])
		ordered_remove(&app.neovim_panes, i)
	}
	app.neovim_deadline = len(app.neovim_panes) > 0 ? time.tick_add(now, NEOVIM_SWEEP) : {}
}

@(private = "file")
neovim_shown_anywhere :: proc(app: ^App, id: u32) -> bool {
	target := layout.Content{.Neovim, id}
	for workspace in app.workspaces {
		for &tab in workspace.tabs {
			if layout.find_content(&tab.tree, target) != layout.INVALID_NODE {return true}
		}
	}
	return false
}

@(private = "file")
neovim_pane_poll :: proc(app: ^App, pane: ^Neovim_Pane) {
	if !pane.started || pane.exited {return}
	polled := neovim.poll(&pane.client)
	if pane.pending {
		neovim_pending_poll(app, pane, polled)
		return
	}
	content := layout.Content{.Neovim, pane.id}
	if polled.flushed {
		for w in app.windows {
			for shown in w.panes {if shown.content == content {w.dirty = true}}
		}
	}
	if polled.title_changed || polled.directory_changed || polled.buffer_changed {
		layout_state_touch(app)
		neovim_titles_changed(app, content)
	}
	if polled.bell {
		for w in app.windows {
			if !w.focused && w.phase == .Shown && platform_api.window_flash(&app.platform, w.id) != .None {
				log.error("flashing the window failed")
			}
		}
	}
	if polled.quit_cancelled {pane.closing = false}
	if polled.exited {
		pane.exited = true
		pane.message = "Neovim exited."
		mark_all_dirty(app)
		neovim_exited(app, pane)
	}
}

@(private = "file")
neovim_titles_changed :: proc(app: ^App, content: layout.Content) {
	for workspace in app.workspaces {neovim_workspace_titles_changed(app, workspace, content)}
	for w in app.windows {
		// Linked views own private workspaces, outside app.workspaces.
		if window_linked(w) {neovim_workspace_titles_changed(app, w.workspace, content)}
		w.dirty = true
		if focused, ok := window_focused_content(w); ok && focused == content {window_update_title(app, w)}
	}
}

@(private = "file")
neovim_workspace_titles_changed :: proc(app: ^App, workspace: ^Workspace, content: layout.Content) {
	for tab in workspace.tabs {
		focused, is_pane := layout.focused_content(&tab.tree)
		if is_pane && focused == content {tab_update_title(app, tab)}
	}
}

// The name of the file Neovim is editing, or the one the pane opens before Neovim starts; else Neovim's
// own title when 'title' is on, else "Neovim".
@(require_results)
neovim_title :: proc(pane: ^Neovim_Pane) -> string {
	if file := neovim_file(pane); file != "" {return filepath.base(file)}
	if pane.client.title != "" {return pane.client.title}
	return CONTENT_POLICY[.Neovim].display_name
}

// The file Neovim is editing once it runs ("" for an unnamed buffer), else the one the pane will open:
// what a restored layout or a reopened pane opens.
@(require_results)
neovim_file :: proc(pane: ^Neovim_Pane) -> string {
	return pane.started ? pane.client.buffer : pane.file
}

// Neovim's working directory once it reports one, else the folder the pane started in.
@(require_results)
neovim_directory :: proc(pane: ^Neovim_Pane) -> string {
	return pane.client.directory != "" ? pane.client.directory : pane.directory
}

// The Neovim logo where a pane's badge shows, when program icons are on and it is ready.
@(require_results)
neovim_badge_atlas :: proc(app: ^App, size: f32) -> (atlas: render.Rect, result: render.Build_Status) {
	if !app.settings.tabs.program_icons {return}
	pixels := int(math.round(size))
	art, has_art := program_art_find(app, NEOVIM_PROGRAM)
	want, found := program_named_source(app, NEOVIM_PROGRAM, art, has_art, pixels, .Draw)
	if !found {return}
	state: Program_Icon_State
	atlas, state, result = program_icon_atlas(app, want, pixels)
	if state != .Ready {atlas = {}}
	return
}

// --- Drawing ---

// Draws the pane's screen, or why there is none, laid out at the pane's layout rectangle.
@(private)
neovim_pane_draw :: proc(
	app: ^App,
	w: ^Window,
	rect: layout.Pane_Rect,
	shown: layout.Rect,
) -> (
	frame: term_view.Neovim_Frame,
	result: render.Build_Status,
) {
	frame.background = app.theme.pane
	pane := neovim_find(app, rect.content.id)
	if pane == nil {return}
	if pane.exited || pane.client.screen.columns == 0 {
		if pane.message == "" {return}
		radius := window_pane_radius(app, w)
		area := render.Rect{shown.x, shown.y, shown.width, shown.height}
		result = ui.pane_message_draw(&w.list, &w.ui_text, app.theme, area, pane.message, w.scale, radius)
		return
	}
	focused := pane_has_keyboard(app, w, rect)
	owner := terminal_caret_owner(rect.content)
	minimum_contrast := f32(1)
	if app.settings.active_theme.terminal_light {
		minimum_contrast = f32(app.settings.terminal.minimum_contrast)
	}
	style := term_view.Neovim_Style {
		family           = app.family,
		focused          = focused,
		cursor_visible   = cursor_visible(w),
		cursor_hidden    = focused ? ui.caret_holds(&w.carets, owner) : pane_cursor_held_elsewhere(app, w, rect),
		cursor_color     = colour.rgba(app.settings.colors.cursor),
		cursor_text      = colour.rgba(app.settings.colors.cursor_text),
		minimum_contrast = minimum_contrast,
		cursor_effects   = cursor_effects(app),
		smooth_scroll    = app.animations && app.settings.neovim.smooth_scroll,
		overlay_opacity  = f32(app.settings.neovim.overlay_opacity) / 100,
		float_blur       = f32(app.settings.neovim.float_blur) * w.scale,
	}
	if app.settings.neovim.float_shadow {
		// The shadow AIODev's own popovers cast.
		popover := ui.popover_panel({}, w.scale)
		style.float_shadow = {
			color    = app.theme.shadow,
			offset   = {popover.shadow_x * w.scale, popover.shadow_y * w.scale},
			softness = popover.softness * w.scale,
		}
	}
	box := pane_box(w.metrics, rect.rect, neovim_insets(app, w))
	clip := render.Rect{rect.rect.x, rect.rect.y, rect.rect.width, rect.rect.height}
	if render.push_layer(&w.list, clip, window_pane_radius(app, w)) != .None {return}
	frame, result = term_view.neovim_build(&pane.view, &pane.client, app.fonts, &app.cache, &w.list,
		box.origin, w.metrics, style, w.frame)
	moving := term_view.neovim_cursor_animating(&pane.view) || term_view.neovim_scroll_animating(&pane.view)
	if moving && !w.frame.resuming {w.frame_moved = true}
	return
}

// --- Opening ---

// The folder of the focused pane, for a Neovim opened beside it.
@(private)
neovim_focused_directory :: proc(app: ^App, w: ^Window) -> string {
	if entry := focused_session(app, w); entry != nil {
		if directory, refused := pane_directory(app, entry); !refused && directory != "" {return directory}
	}
	if content, ok := window_focused_content(w); ok {
		if directory := content_directory(app, content); directory != "" && os.is_dir(directory) {
			return directory
		}
	}
	return home_directory()
}

// Opens Neovim on `file` beside the pane at `node` of w. Returns false only when it could not be placed.
@(require_results)
neovim_open_placed :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	file, directory: string,
	line: int,
	placement: Pane_Placement,
) -> bool {
	acting, beside, found := pane_placement_window(app, w, node, placement)
	if !found {return false}
	pane := neovim_pane_create(app, file, directory, line)
	if pane == nil {return false}
	tab := acting.workspace.selected
	if !pane_place(app, acting, acting.workspace, tab, beside, {.Neovim, pane.id}, placement, true) {
		neovim_pane_remove(app, pane.id)
		return false
	}
	acting.dirty = true
	return true
}

// The palette's and keys' Open Neovim: an empty buffer beside the focused pane, in its folder.
neovim_open_focused :: proc(app: ^App, w: ^Window) {
	tree := window_tree(w)
	if tree == nil {return}
	if !neovim_open_placed(app, w, tree.focus, "", neovim_focused_directory(app, w), 0, .Split_Right) {
		notify(app, .Error, "Could not open Neovim.")
	}
}

// Edits `path` at `line` in Neovim beside the pane at `node`: in the tab's Neovim pane when it has one,
// else in a new one split beside it.
neovim_edit_beside :: proc(app: ^App, w: ^Window, node: layout.Node_Id, path: string, line: int) {
	tree := window_tree(w)
	if tree == nil {return}
	for i in 0 ..< len(tree.nodes) {
		content, is_pane := layout.pane_content(tree, layout.Node_Id(i))
		if !is_pane || content.kind != .Neovim {continue}
		pane := neovim_find(app, content.id)
		if pane == nil || pane.exited {continue}
		if !pane.started {
			delete(pane.file)
			pane.file, _ = strings.clone(path)
			pane.line = line
		} else if neovim.edit(&pane.client, path, line) != .None {
			continue
		}
		pane_focus(app, w, layout.Node_Id(i))
		return
	}
	if !neovim_open_placed(app, w, node, path, filepath.dir(path), line, .Split_Right) {
		notify(app, .Error, "Could not open the file in Neovim.")
	}
}

// `aio pane.open_neovim [path]`: run in a shell pane, Neovim in that pane over its shell; otherwise, or
// with --direction, --ratio or --float, a split beside the target pane or a float. `caller` is the pane
// aio ran in, 0 outside AIODev. Neovim works in a folder it is given, as `nvim .` does in that folder,
// else in the file's folder, else in the pane's.
@(require_results)
control_neovim_open :: proc(
	app: ^App,
	w: ^Window,
	target: Pane_Target,
	invocation: commands.Invocation,
	caller: u32,
) -> Outcome {
	file := .File in invocation.given ? invocation.file : ""
	directory := os.is_dir(file) ? file : filepath.dir(file)
	if file == "" {
		directory = home_directory()
		if entry := target.pane.session; entry != nil {
			if folder, refused := pane_directory(app, entry); !refused && folder != "" {directory = folder}
		} else if folder := content_directory(app, target.pane.content); folder != "" {
			directory = folder
		}
	}
	// As `nvim` run in that shell would, unless a split or float is asked for.
	entry := target.pane.session
	if entry != nil && entry.id == caller && invocation.given & {.Direction, .Ratio, .Float} == {} {
		node := target.pane.node
		if !neovim_open_over(app, target.workspace, target.pane.tab, node, entry.id, file, directory) {
			return outcome_failure(.Failed, "could not open Neovim")
		}
		if invocation.focus && w != nil {pane_focus(app, w, target.pane.node)}
		return {}
	}
	placement: Pane_Placement = .Float in invocation.given ? .Float : .Split_Right
	pane := neovim_pane_create(app, file, directory)
	if pane == nil {return outcome_failure(.Failed, "could not open Neovim")}
	content := layout.Content{.Neovim, pane.id}
	if !pane_place(app, w, target.workspace, target.pane.tab, target.pane.node, content, placement,
		invocation.focus, invocation.ratio, invocation.direction) {
		neovim_pane_remove(app, pane.id)
		return outcome_failure(.Failed, "could not open Neovim")
	}
	if w != nil {w.dirty = true}
	return {}
}

// --- Focus ---

neovim_focus_changed :: proc(app: ^App, content: layout.Content, focused: bool) {
	if content.kind != .Neovim {return}
	pane := neovim_find(app, content.id)
	if pane == nil || !pane.started || pane.exited {return}
	if neovim.set_focus(&pane.client, focused) != .None {neovim_lost(app)}
}

neovim_active :: proc(w: ^Window) -> bool {
	content, ok := window_focused_content(w)
	return ok && content.kind == .Neovim
}

@(require_results)
neovim_focused :: proc(app: ^App, w: ^Window) -> ^Neovim_Pane {
	content, ok := window_focused_content(w)
	if !ok || content.kind != .Neovim {return nil}
	pane := neovim_find(app, content.id)
	if pane == nil || !pane.started || pane.exited {return nil}
	return pane
}

// --- Keyboard ---

// Keys for the focused Neovim pane. As in a terminal, the app's shortcuts come first and the leader
// pressed twice passes a key past them.
neovim_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	key, consumed := content_key_prelude(app, w, e, true)
	if consumed {return}
	if key.found && (key.runtime || action_available(app, w, key.action)) {
		key_suppress(w, e)
		run_window_command(app, w, key.command, .Key)
		return
	}
	status_inbox_typed(w, e)
	if ui.find_has_keyboard(&w.find) {
		find_bar_key(app, w, e, key.logical)
		return
	}
	pane := neovim_focused(app, w)
	if pane == nil {return}
	buffer: [NEOVIM_KEY_MAX]u8
	notation := neovim_key_notation(e, buffer[:])
	if notation == "" {return}
	if neovim.input(&pane.client, notation) != .None {neovim_lost(app)}
	cursor_blink_reset(w, clock_now(&app.clock))
	neovim_pointer_hide(app, w, pane)
}

// Text typed without a key of its own, such as an input method's.
neovim_text :: proc(app: ^App, w: ^Window, text: string) {
	pane := neovim_focused(app, w)
	if pane == nil {return}
	escaped, _ := strings.replace_all(text, "<", "<lt>", context.temp_allocator)
	if neovim.input(&pane.client, escaped) != .None {neovim_lost(app)}
	cursor_blink_reset(w, clock_now(&app.clock))
	neovim_pointer_hide(app, w, pane)
}

// Pastes the clipboard into the focused Neovim as Neovim's own paste does, so it lands as one undo step
// and is not run through mappings.
neovim_paste :: proc(app: ^App, w: ^Window) {
	pane := neovim_focused(app, w)
	if pane == nil {return}
	text, ok := platform_api.clipboard_get_text(&app.platform, context.temp_allocator)
	if !ok || len(text) == 0 {return}
	if neovim.paste(&pane.client, text) != .None {neovim_lost(app)}
}

// --- Pointer ---

// The Neovim pane under (x, y) and the grid cell there, clamped to the grid; ok is false off a Neovim
// pane's body.
@(private = "file")
neovim_cell_at :: proc(app: ^App, w: ^Window, x, y: f32) -> (pane: ^Neovim_Pane, cell: [2]int, ok: bool) {
	hit, found := layout.hit_test(w.panes[:], x, y)
	if !found || hit.content.kind != .Neovim || y < pane_body_rect(w, hit).y {return}
	pane = neovim_find(app, hit.content.id)
	if pane == nil {return}
	return pane, neovim_cell_of(app, w, pane, hit, x, y), true
}

@(private = "file")
neovim_cell_of :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Neovim_Pane,
	shown: layout.Pane_Rect,
	x, y: f32,
) -> [2]int {
	box := pane_box(w.metrics, shown.rect, neovim_insets(app, w))
	s := &pane.client.screen
	column := int(math.floor((x - box.origin.x) / w.metrics.cell_width))
	row := int(math.floor((y - box.origin.y) / w.metrics.cell_height))
	return {clamp(column, 0, max(s.columns - 1, 0)), clamp(row, 0, max(s.rows - 1, 0))}
}

@(private = "file")
neovim_modifiers :: proc(modifiers: input.Modifiers) -> (result: bit_set[neovim.Modifier; u8]) {
	if .Shift in modifiers {result += {.Shift}}
	if .Control in modifiers {result += {.Ctrl}}
	if .Alt in modifiers {result += {.Alt}}
	if .Super in modifiers {result += {.Super}}
	return
}

@(private = "file")
neovim_mouse :: proc(
	app: ^App,
	pane: ^Neovim_Pane,
	button: neovim.Mouse_Button,
	action: neovim.Mouse_Action,
	modifiers: input.Modifiers,
	cell: [2]int,
) {
	if !pane.started || pane.exited || !pane.client.mouse {return}
	if neovim.input_mouse(&pane.client, button, action, neovim_modifiers(modifiers), cell.y, cell.x) != .None {
		neovim_lost(app)
	}
}

neovim_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	shown, found := layout.hit_test(w.panes[:], x, y)
	return found && shown.content.kind == .Neovim
}

neovim_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	drag := &app.neovim_drag
	if drag.active && drag.window == w.id {
		pane := neovim_find(app, drag.pane)
		if pane == nil {
			drag^ = {}
			return
		}
		for shown in w.panes {
			if shown.content != {.Neovim, drag.pane} {continue}
			cell := neovim_cell_of(app, w, pane, shown, f32(e.x), f32(e.y))
			if cell != drag.cell {
				drag.cell = cell
				neovim_mouse(app, pane, drag.button, .Drag, e.modifiers, cell)
			}
		}
		return
	}
	if owner != .Neovim_Page {return}
	pointer_set(app, w, .Text)
}

neovim_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	x, y := f32(e.x), f32(e.y)
	shown, found := layout.hit_test(w.panes[:], x, y)
	if !found || shown.content.kind != .Neovim {return}
	pane_focus(app, w, shown.node)
	pane, cell, ok := neovim_cell_at(app, w, x, y)
	if !ok {return}
	button: neovim.Mouse_Button
	#partial switch e.button {
	case .Left:
		button = .Left
	case .Right:
		button = .Right
	case .Middle:
		button = .Middle
	case:
		return
	}
	app.neovim_drag = {window = w.id, pane = pane.id, button = button, cell = cell, active = true}
	neovim_mouse(app, pane, button, .Press, e.modifiers, cell)
}

neovim_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	drag := app.neovim_drag
	if !drag.active || drag.window != w.id {return false}
	app.neovim_drag = {}
	if pane := neovim_find(app, drag.pane); pane != nil {
		neovim_mouse(app, pane, drag.button, .Release, e.modifiers, drag.cell)
	}
	return true
}

// Capture loss ends a drag where it last was, so Neovim does not keep extending a selection.
neovim_cancel :: proc(app: ^App, w: ^Window) {
	drag := app.neovim_drag
	if !drag.active || drag.window != w.id {return}
	app.neovim_drag = {}
	if pane := neovim_find(app, drag.pane); pane != nil {
		neovim_mouse(app, pane, drag.button, .Release, {}, drag.cell)
	}
}

// The wheel over a Neovim pane's body sends a wheel event per line a terminal pane would scroll, so
// Neovim scrolls as much as it does in a terminal.
@(require_results)
neovim_wheel :: proc(app: ^App, w: ^Window, e: input.Mouse_Wheel_Event) -> bool {
	pane, cell, ok := neovim_cell_at(app, w, f32(e.x), f32(e.y))
	if !ok {return false}
	app.neovim_wheel += [2]f32{e.delta_x, e.delta_y} * WHEEL_LINES
	vertical := int(app.neovim_wheel.y)
	horizontal := int(app.neovim_wheel.x)
	app.neovim_wheel -= {f32(horizontal), f32(vertical)}
	for _ in 0 ..< abs(vertical) {
		neovim_mouse(app, pane, .Wheel, vertical > 0 ? .Up : .Down, e.modifiers, cell)
	}
	for _ in 0 ..< abs(horizontal) {
		neovim_mouse(app, pane, .Wheel, horizontal > 0 ? .Right : .Left, e.modifiers, cell)
	}
	return true
}

// Advances the smooth scroll of every Neovim pane w shows; true while text still travels.
neovim_scroll_motion :: proc(app: ^App, w: ^Window, frame: render.Frame_Time) -> bool {
	duration := time.Duration(app.settings.neovim.scroll_duration) * time.Millisecond
	enabled := app.animations && app.settings.neovim.smooth_scroll && window_drawable(w)
	moved := false
	for pane in w.panes {
		if pane.content.kind != .Neovim {continue}
		if np := neovim_find(app, pane.content.id); np != nil {
			moved ||= term_view.neovim_scroll_animate(&np.view, frame, duration, enabled)
		}
	}
	return moved
}

neovim_scrolls_animating :: proc(app: ^App, w: ^Window) -> bool {
	if !window_drawable(w) {return false}
	for pane in w.panes {
		if pane.content.kind != .Neovim {continue}
		if np := neovim_find(app, pane.content.id); np != nil && term_view.neovim_scroll_animating(&np.view) {
			return true
		}
	}
	return false
}

when AIO_CONTROL {
	// The verification keys of the Neovim panes: the focused one under neovim.*, with the text of each grid
	// row, and every pane under neovim.pane.<id>.*.
	neovim_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		state_value(r, "neovim.count", len(app.neovim_panes))
		state_value(r, "neovim.active", neovim_active(w))
		focused: ^Neovim_Pane
		if content, ok := window_focused_content(w); ok && content.kind == .Neovim {
			focused = neovim_find(app, content.id)
		}
		neovim_pane_state(r, "neovim", focused)
		if focused != nil {
			s := &focused.client.screen
			for y in 0 ..< s.rows {
				state_text(r, state_key("neovim.row.%d", y), neovim_row_text(&focused.client, y))
			}
		}
		for pane in app.neovim_panes {neovim_pane_state(r, state_key("neovim.pane.%d", pane.id), pane)}
	}

	// One pane's keys under `prefix`; a nil pane reports a blank one.
	@(private = "file")
	neovim_pane_state :: proc(r: ^State_Report, prefix: string, pane: ^Neovim_Pane) {
		blank: Neovim_Pane
		p := pane != nil ? pane : &blank
		s := &p.client.screen
		floats := 0
		for grid in s.grids {if grid.kind == .Float {floats += 1}}
		state_value(r, state_key("%s.id", prefix), p.id)
		state_value(r, state_key("%s.started", prefix), p.started)
		state_value(r, state_key("%s.exited", prefix), p.exited)
		state_text(r, state_key("%s.message", prefix), p.message)
		state_text(r, state_key("%s.file", prefix), p.file)
		state_text(r, state_key("%s.buffer", prefix), p.client.buffer)
		state_text(r, state_key("%s.title", prefix), p.client.title)
		state_text(r, state_key("%s.directory", prefix), p.client.directory)
		state_value(r, state_key("%s.mouse", prefix), p.client.mouse)
		state_value(r, state_key("%s.columns", prefix), s.columns)
		state_value(r, state_key("%s.rows", prefix), s.rows)
		state_value(r, state_key("%s.grids", prefix), len(s.grids))
		state_value(r, state_key("%s.floats", prefix), floats)
		state_value(r, state_key("%s.shell", prefix), p.shell)
		state_value(r, state_key("%s.unsaved", prefix), p.client.unsaved)
		state_value(r, state_key("%s.closing", prefix), p.closing)
		state_value(r, state_key("%s.cursor_row", prefix), s.cursor_screen_row)
		state_value(r, state_key("%s.cursor_column", prefix), s.cursor_screen_column)
		state_word(r, state_key("%s.cursor_shape", prefix), s.mode.shape)
		state_value(r, state_key("%s.scrolling", prefix), term_view.neovim_scroll_animating(&p.view))
		state_value(r, state_key("%s.generation", prefix), s.generation)
	}

	// Screen row y as the grids compose it, trailing spaces trimmed.
	@(private = "file")
	neovim_row_text :: proc(client: ^neovim.Client, y: int) -> string {
		s := &client.screen
		out := strings.builder_make(context.temp_allocator)
		for x in 0 ..< s.columns {
			cell, _ := neovim.screen_cell(s, y, x)
			switch {
			case cell.glyph == 0:
			case cell.glyph & neovim.GLYPH_CLUSTER != 0:
				strings.write_string(&out, neovim.cluster(client, cell.glyph))
			case:
				strings.write_rune(&out, rune(cell.glyph))
			}
		}
		return strings.trim_right(strings.to_string(out), " ")
	}
}
