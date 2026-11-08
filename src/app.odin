package main

import "aio:commands"
import "aio:font"
import "aio:glyphs"
import "aio:input"
import "aio:instance"
import platform_api "aio:platform"
import "aio:perf"
import "aio:program_art"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"

@(private)
FALLBACK_FONT_FAMILIES :: [?]string{"Cascadia Mono", "Consolas"}
@(private)
NOTICE_DURATION :: 6 * time.Second
// Errors, and notices meant to be read at leisure.
@(private)
ERROR_NOTICE_DURATION :: 12 * time.Second

// Every notice that replaces its own earlier copy has a key here, so no two features share one.
@(private)
Notice_Key :: enum u32 {
	Transient = 1,
	Settings,
	Font,
	Copy,
	Paste,
	Build_Info,
}

// What every window shares. Each feature's own state is a struct declared beside that feature's procs
// and embedded here, so the app composes it without knowing its fields. main defers app_destroy before
// anything starts, so every feature's destroy must accept its zero value.
App :: struct {
	verify:                Verify,
	perf:                  perf.Stats,
	options:               instance.Options,
	paths:                 instance.Paths,
	app_id:                string,
	platform:              platform_api.Platform,
	platform_ready:        bool,
	using settings_notices: Settings_Notice_State,
	// Theme files and machine shells the running revision was read with; saves and pages reuse them.
	settings_inputs:       settings.Inputs,
	settings:              settings.Settings,
	using markdown_state:  Markdown_App,
	dialogs:               File_Dialogs,
	// The settings file this app reads and saves; app_init takes it from paths.
	settings_path:         string,
	log_path:              string,
	fonts:                 ^font.System,
	family:                font.Family,
	font_points:           f32,
	device:                ^render.Device,
	cache:                 glyphs.Cache,
	shell_icons:           [dynamic]Shell_Icon,
	processes:             Process_Worker,
	program_icons:         Program_Icon_Cache,
	program_art:           program_art.Catalogue,
	ui_text:               ui.Text,
	animations:            bool,
	theme:                 ui.Theme,
	registry:              commands.Registry,
	leader:                Maybe(commands.Shortcut),
	palette:               ui.Palette,
	find_history:          ui.Find_History,
	focus_jumps:           Focus_Jumps,
	// The window the palette is open or closing in; see palette_owner.odin.
	palette_owner:         Maybe(input.Window_Id),
	notices:               ui.Notices,
	notice_window:         input.Window_Id,
	// Counts window activations; see window_focus_note.
	window_focus_order:    u64,
	sessions:              [dynamic]Session_Entry,
	workspaces:            [dynamic]^Workspace,
	next_workspace_id:     u32,
	// The last session id session_open allocated; callers use the id it returns instead.
	next_session_id:       u32,
	windows:               [dynamic]^Window,
	run:                   App_Run,
	tray_hint_shown:       bool,
	// See update_processes.
	process_deadline:      time.Tick,
	// Only the real launch enables saving, which also turns restoring on.
	using layout_store:    Layout_Store,
	// Hands web and file targets to the system; see target_open.odin.
	opener:                Target_Opener,
	using cli_state:       Cli_State,
	// How the most recently closed sessions ended; see session.odin.
	closed_sessions:       Closed_Sessions,
	// Panes and tabs closed explicitly, newest last, for Reopen Closed.
	closed:                [dynamic]Closed_Item,
}

@(require_results)
app_init :: proc(app: ^App) -> bool {
	when FRAME_STATS {perf.start(&app.perf)}
	paths, paths_error := instance.paths(app.options)
	if paths_error != nil {
		log.errorf("locating the instance files failed: %v", paths_error)
		return false
	}
	app.paths = paths
	if app.paths.settings == "" {
		log.error("locating the settings file failed: no settings directory")
	} else if path, err := strings.clone(app.paths.settings); err != nil {
		log.errorf("constructing the settings path failed: %v", err)
		return false
	} else {
		app.settings_path = path
	}
	if app.options.data_dir != "" {
		if directory_error := os.mkdir_all(app.options.data_dir); directory_error != nil {
			log.errorf("creating the data directory failed: %v", directory_error)
			return false
		}
	}
	app.animations = platform_api.client_animations_enabled()
	ui.notices_init(&app.notices)
	if catalogue, err := program_art.catalogue_make(); err == nil {
		app.program_art = catalogue
	} else {
		log.errorf("parsing the bundled program artwork failed: %v", err)
	}
	app.registry = commands.create()
	if err := register_actions(&app.registry); err != .None {
		log.errorf("registering commands failed: %v", err)
		return false
	}
	if !palette_settings_init(app) {return false}
	palette_set_sources(app)
	control_cli_init(app)
	if !load_settings(app) {return false}
	font_error: font.Error
	app.fonts, font_error = font.system_create()
	if font_error != .None {
		log.errorf("font system creation failed: %v", font_error)
		return false
	}
	render_error: render.Error
	app.device, render_error = render.device_create()
	if render_error != .None {
		log.errorf("graphics device creation failed: %v", render_error)
		return false
	}
	apply_text_gamma(app)
	glyphs.init(&app.cache, app.fonts, app.device)
	ui_size_px := points_pixels(
		f32(app.settings.interface.font_size),
		dpi_scale(platform_api.primary_dpi(&app.platform)),
	)
	if !ui.text_init(&app.ui_text, app.fonts, &app.cache, ui_size_px, app.settings.interface.font_family) {
		log.error("no interface font is available")
		return false
	}
	shell_icons_load(app)
	apply_fonts(app)
	apply_theme(app)
	tray_init(app)
	platform_api.set_modal_loop_callback(
		&app.platform,
		proc(user: rawptr) {tick((^App)(user))},
		app,
	)
	if !layout_state_restore(app) {
		workspace := workspace_create_empty(app)
		if workspace == nil {return false}
		if _, created := tab_create(app, workspace); !created {return false}
		if !window_open(app, workspace) {return false}
	}
	when AIO_CONTROL {verify_start(app)}
	control_cli_sync(app)
	return true
}

// Also runs for an App that never started, so each feature's destroy accepts its zero value.
app_destroy :: proc(app: ^App) {
	when AIO_CONTROL {verify_destroy(app)}
	control_cli_destroy(app)
	for len(app.windows) > 0 {
		window_close(app, app.windows[len(app.windows) - 1])
	}
	delete(app.windows)
	for &entry in app.sessions {
		session_entry_destroy(&entry)
	}
	delete(app.sessions)
	for workspace in app.workspaces {workspace_destroy(workspace)}
	delete(app.workspaces)
	if app.platform_ready {
		tray_destroy(app)
	}
	process_worker_destroy(&app.processes)
	program_icon_cache_destroy(&app.program_icons)
	program_art.catalogue_destroy(&app.program_art)
	shell_icons_destroy(&app.shell_icons)
	glyphs.destroy(&app.cache)
	if app.device != nil {
		render.device_destroy(app.device)
	}
	if app.fonts != nil {
		font.system_destroy(app.fonts)
	}
	ui.palette_destroy(&app.palette)
	ui.find_history_destroy(&app.find_history)
	focus_jumps_destroy(&app.focus_jumps)
	file_dialogs_destroy(app)
	markdown_app_destroy(&app.markdown_state)
	ui.notices_destroy(&app.notices)
	commands.destroy(&app.registry)
	settings.destroy(&app.settings)
	settings.inputs_destroy(&app.settings_inputs)
	settings_notice_state_destroy(&app.settings_notices)
	delete(app.settings_path)
	instance.paths_destroy(&app.paths)
	delete(app.log_path)
	layout_state_destroy(app)
	closed_destroy(app)
	delete(app.app_id)
	if app.platform_ready {
		if platform_api.destroy(&app.platform) != .None {
			log.error("platform shutdown reported an error")
		}
	}
}

run :: proc(app: ^App) {
	for app_running(app) {
		if platform_api.wait_events(&app.platform, wait_timeout(app)) != .None {
			log.error("waiting for events failed")
		}
		tick(app)
	}
}

// One iteration of the main loop; also driven by the platform during modal resize loops.
tick :: proc(app: ^App) {
	events, err := platform_api.poll_events(&app.platform)
	if err != .None {
		log.errorf("polling events failed: %v", err)
	}
	for event in events {
		handle_event(app, event)
	}
	if len(events) > 0 {layout_state_touch(app)}
	update_sessions(app)
	find_tick(app)
	if ready, unreadable := program_icons_adopt(app); ready || unreadable != "" {
		if unreadable != "" {
			notify(app, .Error, fmt.tprintf("Could not read %s as a PNG program icon.", unreadable))
		}
		mark_all_dirty(app)
	}
	update_motion(app)
	app_timers_advance(app, .Before_Draw)
	pane_links_sync(app)
	window_notices_sync(app)
	for window in app.windows {
		now := time.tick_now()
		for timer in Window_Timer {window_timer_advance(app, window, timer, now)}
		status_spin_tick(window)
		status_taskbar_follow(app, window)
		switch window.phase {
		case .Preparing:
			window.dirty = false
			continue
		case .Hidden, .Closing:
			continue
		case .Shown:
		}
		if window.dirty {
			window_render(app, window)
			// The harness counts this window's present now; its After_Draw timer reads every window's.
			when AIO_CONTROL {verify_presented(app, window)}
		}
	}
	app_timers_advance(app, .After_Draw)
	control_cli_tick(app)
	focus_jumps_track(app)
	free_all(context.temp_allocator)
}

// Every timed feature that is not a window's, once. Each advances itself and names its next deadline:
// tick advances them and wait_timeout sleeps until the earliest. A value added here must be named by
// every switch below, so no feature can be advanced without waking the loop, or the reverse. Find
// progress stays outside, as a pair: find_tick runs before update_motion, where no phase here runs, and
// find_pending wakes the loop at once rather than at a deadline.
@(private = "file")
App_Timer :: enum u8 {
	Processes,
	Notices,
	// A pane drag resting on another tab switches to it; this can create or discard a preview window.
	Drag_Hover,
	Verify,
	Layout_Save,
	File_Dialogs,
	Markdown,
}

// Before the windows draw, a timer's change shows in this tick's frame; after, verify counts the
// frames this tick presented.
@(private = "file")
Timer_Phase :: enum u8 {
	Before_Draw,
	After_Draw,
}

@(private = "file")
app_timer_phase :: proc(timer: App_Timer) -> Timer_Phase {
	switch timer {
	case .Processes, .Notices, .Drag_Hover:
		return .Before_Draw
	case .Verify, .Layout_Save, .File_Dialogs, .Markdown:
		return .After_Draw
	}
	return .Before_Draw
}

@(private = "file")
app_timers_advance :: proc(app: ^App, phase: Timer_Phase) {
	for timer in App_Timer {
		if app_timer_phase(timer) != phase {continue}
		switch timer {
		case .Processes:
			update_processes(app)
		case .Notices:
			if ui.notices_expire(&app.notices, app.animations, time.tick_now()) {mark_all_dirty(app)}
		case .Drag_Hover:
			for i := 0; i < len(app.windows); i += 1 {pane_drag_tick(app, app.windows[i], time.tick_now())}
		case .Verify:
			when AIO_CONTROL {verify_tick(app)}
		case .Layout_Save:
			layout_state_tick(app)
		case .File_Dialogs:
			file_dialogs_tick(app)
		case .Markdown:
			markdown_tick(app)
		}
	}
}

@(private = "file")
app_timer_deadline :: proc(app: ^App, timer: App_Timer) -> (next: time.Tick, pending: bool) {
	switch timer {
	case .Processes:
		return process_poll_deadline(app)
	case .Notices:
		return ui.notices_deadline(&app.notices)
	case .Drag_Hover:
		for w in app.windows {
			if at, armed := drag_hover_deadline(w); armed {next, pending = earliest(next, pending, at)}
		}
	case .Verify:
		when AIO_CONTROL {return verify_deadline(app)}
	case .Layout_Save:
		return layout_state_deadline(app)
	case .File_Dialogs:
		// A finished dialog wakes the loop itself.
	case .Markdown:
		return markdown_poll_deadline(app)
	}
	return
}

// Every timed feature of a window, once, advanced before the window draws.
@(private = "file")
Window_Timer :: enum u8 {
	Leader,
	Paste_Confirm,
	Cursor_Blink,
	Capture_Hold,
	Selection_Autoscroll,
	Tooltip,
}

@(private = "file")
window_timer_advance :: proc(app: ^App, w: ^Window, timer: Window_Timer, now: time.Tick) {
	switch timer {
	case .Leader:
		leader_expire(w, now)
	case .Paste_Confirm:
		paste_confirm_expire(w, now)
	case .Cursor_Blink:
		cursor_blink_tick(w, now)
	case .Capture_Hold:
		capture_hold_tick(w, now)
	case .Selection_Autoscroll:
		selection_autoscroll_tick(app, w, now)
	case .Tooltip:
		tooltip_tick(w, now)
	}
}

@(private = "file")
window_timer_deadline :: proc(w: ^Window, timer: Window_Timer) -> (time.Tick, bool) {
	switch timer {
	case .Leader:
		return leader_deadline(w)
	case .Paste_Confirm:
		return paste_confirm_deadline(w)
	case .Cursor_Blink:
		return cursor_blink_deadline(w)
	case .Capture_Hold:
		return capture_hold_deadline(w)
	case .Selection_Autoscroll:
		return selection_autoscroll_deadline(w)
	case .Tooltip:
		return tooltip_deadline(w)
	}
	return {}, false
}

// The earlier of a deadline found so far, if any, and `next`.
@(private = "file")
earliest :: proc(current: time.Tick, found: bool, next: time.Tick) -> (time.Tick, bool) {
	if found && time.tick_diff(next, current) <= 0 {return current, true}
	return next, true
}

@(private)
wait_timeout :: proc(app: ^App) -> u32 {
	// Spinner frames are already paced by the swap chain, including on high-refresh displays.
	for window in app.windows {
		if status_spin_active(window) {return 0}
	}
	if motion_active(app) {return 16}
	INFINITE :: max(u32)
	deadline: time.Tick
	found := false
	for timer in App_Timer {
		if next, pending := app_timer_deadline(app, timer); pending {
			deadline, found = earliest(deadline, found, next)
		}
	}
	for window in app.windows {
		for timer in Window_Timer {
			if next, pending := window_timer_deadline(window, timer); pending {
				deadline, found = earliest(deadline, found, next)
			}
		}
	}
	if find_pending(app) {return 0}
	if !found {
		return INFINITE
	}
	remaining := time.tick_diff(time.tick_now(), deadline)
	return u32(clamp(time.duration_milliseconds(remaining) + 1, 0, 60_000))
}

mark_all_dirty :: proc(app: ^App) {
	for window in app.windows {
		window.dirty = true
	}
}

@(private)
wake_platform :: proc(user: rawptr) {
	if platform_api.wake((^platform_api.Platform)(user)) != .None {
		log.error("waking the main loop failed")
	}
}

initial_geometry :: proc(app: ^App) -> term.Geometry {
	scale := dpi_scale(platform_api.primary_dpi(&app.platform))
	fields := window_settings_fields(app, scale, linked = false)
	// A new window as it shows once opened and its settings apply, before it has a size.
	template := Window {
		scale              = scale,
		metrics            = fields.metrics,
		rail_default_width = fields.rail_default_width,
		tabs_horizontal    = fields.tabs_horizontal,
		header_height      = fields.header_height,
	}
	// window.columns and window.rows size the window without a docked Activity panel, which then takes
	// its width from the pane. This is the shipped policy, kept pending the owner's decision on whether
	// the window should widen for the panel instead.
	box, width, height, _ := pane_box_for_grid(
		app,
		template,
		u16(app.settings.window.columns),
		u16(app.settings.window.rows),
		pane_insets(app, &template, nil),
		activity_dock = false,
	)
	return pane_box_geometry(box, fields.metrics, width, height)
}

notify :: proc(app: ^App, kind: ui.Notice_Kind, text: string) {
	duration := kind == .Error || kind == .Warning ? ERROR_NOTICE_DURATION : NOTICE_DURATION
	key := u32(Notice_Key.Transient)
	ui.notices_put(&app.notices, key, kind, text, duration, app.animations, time.tick_now())
	mark_all_dirty(app)
}

// Resolves the configured terminal font, falling back to fonts every Windows install has.
apply_fonts :: proc(app: ^App) {
	family, err := font.family_load(app.fonts, app.settings.font.family)
	if err == .None {
		app.family = family
		ui.notices_clear(&app.notices, u32(Notice_Key.Font), app.animations, time.tick_now())
		return
	}
	for name in FALLBACK_FONT_FAMILIES {
		if fallback, fallback_error := font.family_load(app.fonts, name); fallback_error == .None {
			app.family = fallback
			text := fmt.tprintf(
				"Font \"%s\" is not installed. Using %s.",
				app.settings.font.family,
				name,
			)
			ui.notices_put(
				&app.notices, u32(Notice_Key.Font), .Error, text, ERROR_NOTICE_DURATION, app.animations,
				time.tick_now(),
			)
			return
		}
	}
	log.errorf("no terminal font could be loaded: %v", err)
}

apply_theme :: proc(app: ^App) {
	app.theme = ui.theme_from(app.settings.active_theme, app.settings.interface)
}

@(private)
terminal_colors :: proc(c: settings.Color_Settings) -> term.Colors {
	colors := term.Colors {
		foreground = c.foreground,
		background = c.background,
		cursor     = c.cursor,
	}
	for value, i in c.palette {
		colors.palette[i] = value
	}
	return colors
}

set_font_points :: proc(app: ^App, points: f32) {
	zoom := settings.FONT_SIZE_ZOOM
	app.font_points = clamp(points, f32(zoom.minimum), f32(zoom.maximum))
	for window in app.windows {
		window_apply_settings(app, window)
	}
}

apply_text_gamma :: proc(app: ^App) {
	render.set_text_gamma(app.device, font.text_gamma(app.fonts))
}
