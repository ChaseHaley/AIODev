package main

import "aio:commands"
import app_events "aio:events"
import "cosmos:font"
import "cosmos:glyphs"
import "cosmos:input"
import "aio:instance"
import platform_api "cosmos:platform"
import "cosmos:perf"
import "aio:program_art"
import "cosmos:render"
import "aio:settings"
import "aio:term"
import "aio:views"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"
// Only the headless build reads the bundled test fonts; other builds compile none of them in.
@(require) import "cosmos:test_fonts"
import "cosmos:ui"
import "cosmos:host"

@(private)
FALLBACK_FONT_FAMILIES :: [?]string{"Cascadia Mono", "Consolas"}
@(private)
NOTICE_DURATION :: 6 * time.Second
// Errors, and notices meant to be read at leisure.
@(private)
ERROR_NOTICE_DURATION :: 12 * time.Second

// Every notice source has a key here, so no two features share one. A notice that tracks a state still
// changing (settings problems, the font, a paste or Undo waiting, an update) replaces its own earlier
// copy, so it never shows a stale state; the others stack, and their key only names them for the harness.
@(private)
Notice_Key :: enum u32 {
	Transient = 1,
	Settings,
	Font,
	Copy,
	Paste,
	Build_Info,
	Shortcut_Undo,
	Update,
	Lua,
}

// What every window shares. Each feature's own state is a struct declared beside that feature's procs
// and embedded here, so the app composes it without knowing its fields. main defers app_destroy before
// anything starts, so every feature's destroy must accept its zero value.
App :: struct {
	verify:                Verify,
	perf:                  perf.Stats,
	options:               instance.Options,
	paths:                 instance.Paths,
	clock:                 host.Clock,
	app_id:                string,
	platform:              platform_api.Platform,
	platform_ready:        bool,
	using settings_notices: Settings_Notice_State,
	// Theme files and machine shells the running revision was read with; saves and pages reuse them.
	settings_inputs:       settings.Inputs,
	settings:              settings.Settings,
	theme_record:          Theme_Record,
	using markdown_state:  Markdown_App,
	using changes_state:   Changes_App,
	using web_state:       Web_App,
	using neovim_state:    Neovim_App,
	dialogs:               File_Dialogs,
	// The settings file this app reads and saves; app_init takes it from paths.
	settings_path:         string,
	log_path:              string,
	fonts:                 ^font.System,
	family:                font.Family,
	font_points:           f32,
	device:                ^render.Device,
	// Auto in the app; tests that read the app's pixels back set Warp before app_init.
	render_driver:         render.Driver,
	cache:                 glyphs.Cache,
	shell_icons:           [dynamic]Shell_Icon,
	// What each link program's command line runs, found when settings apply (WORK-395).
	link_programs:         [dynamic]Link_Program_Target,
	processes:             Process_Worker,
	program_icons:         Program_Icon_Cache,
	program_art:           program_art.Catalogue,
	ui_text:               ui.Text,
	animations:            bool,
	theme:                 views.Theme,
	registry:              commands.Registry,
	runtime_runner:        Runtime_Runner,
	keymap:                commands.Keymap,
	leader:                Maybe(input.Shortcut),
	palette:               views.Palette,
	// Where the palette's usage is saved; see palette_usage.odin.
	palette_store:         Palette_Usage_Store,
	find_history:          ui.Find_History,
	focus_jumps:           Focus_Jumps,
	// The window the palette is open or closing in; see palette_owner.odin.
	palette_owner:         Maybe(input.Window_Id),
	notices:               ui.Notices,
	notice_window:         input.Window_Id,
	// The last conflict chain save, which its notice's Undo or Ctrl+Z puts back.
	shortcut_undo:         Shortcut_Undo,
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
	// What happened this tick, for scripts and `aio events`; see app_events.odin.
	events:                app_events.Queue,
	// Some session has not been announced by pane.created because no tree held it yet.
	events_unattached:     bool,
	// A window's focus may have moved; app_events_settle reports where it came to rest.
	events_focus:          bool,
	// A digest of every listed workspace's arrangement, compared each tick for layout.changed.
	events_layout:         u64,
	// Panes and tabs closed explicitly, newest last, for Reopen Closed.
	closed:                [dynamic]Closed_Item,
	// Update AIODev's updater while it runs; see app_update.odin.
	update:                App_Update,
	next_prompt_id:         u64,
	// init.lua's state, actions and timers; see lua_host.odin.
	lua:                   Lua_Host,
	// What agent turns changed, recorded or being recorded; see turn_recorder.odin.
	turn_recorder:         Turn_Recorder,
}

@(require_results)
app_init :: proc(app: ^App) -> bool {
	app_events.init(&app.events)
	when FRAME_STATS {perf.start(&app.perf)}
	when platform_api.HEADLESS {
		// The same pixels on every machine: WARP (WORK-350).
		app.render_driver = .Warp
	}
	starting: host.Device_Start
	host.device_start(&starting, app.render_driver)
	defer host.device_abandon(&starting)
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
	commands.keymap_init(&app.keymap)
	if err := register_actions(&app.registry); err != .None {
		log.errorf("registering commands failed: %v", err)
		return false
	}
	if !palette_settings_init(app) {return false}
	palette_usage_load(app)
	palette_set_sources(app)
	control_cli_init(app)
	// Before settings load, which runs init.lua and registers its actions.
	app.runtime_runner = lua_host_run
	if !load_settings(app) {return false}
	font_error: font.Error
	when platform_api.HEADLESS {
		// The same pixels on every machine: bundled fonts (WORK-351).
		app.fonts, font_error = font.system_create_private(test_fonts.files())
	} else {
		app.fonts, font_error = font.system_create()
	}
	if font_error != .None {
		log.errorf("font system creation failed: %v", font_error)
		return false
	}
	apply_fonts(app)
	markdown_style_apply(app)
	apply_theme(app)
	// Each shell takes 30 to 40 ms to start, so the panes start theirs while the graphics device is
	// still being created; the windows showing them open once it exists.
	restoring, restored := layout_state_restore_workspaces(app)
	fresh: ^Workspace
	if !restored {
		fresh = workspace_create_empty(app)
		if fresh == nil {return false}
		if _, created := tab_create(app, fresh); !created {return false}
	}
	render_error: render.Error
	app.device, render_error = host.device_finish(&starting)
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
	link_programs_load(app)
	tray_init(app)
	platform_api.set_modal_loop_callback(
		&app.platform,
		proc(user: rawptr) {tick((^App)(user), wait_frames = true)},
		app,
	)
	if restored && !layout_state_restore_windows(app, restoring) {
		fresh = workspace_create_empty(app)
		if fresh == nil {return false}
		if _, created := tab_create(app, fresh); !created {return false}
	}
	if fresh != nil && !window_open(app, fresh) {return false}
	turns_apply_settings(app)
	agent_records_prune(app)
	when AIO_CONTROL {verify_start(app)}
	control_cli_sync(app)
	return true
}

// Also runs for an App that never started, so each feature's destroy accepts its zero value.
app_destroy :: proc(app: ^App) {
	when AIO_CONTROL {verify_destroy(app)}
	control_cli_destroy(app)
	// Lua handlers may still hold windows and panes by id, but never past this point.
	lua_host_destroy(app)
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
	turn_recorder_destroy(app)
	program_icon_cache_destroy(&app.program_icons)
	program_art.catalogue_destroy(&app.program_art)
	shell_icons_destroy(&app.shell_icons)
	link_programs_destroy(&app.link_programs)
	web_app_destroy(&app.web_state)
	neovim_app_destroy(&app.neovim_state)
	glyphs.destroy(&app.cache)
	if app.device != nil {
		render.device_destroy(app.device)
	}
	if app.fonts != nil {
		font.system_destroy(app.fonts)
	}
	views.palette_destroy(&app.palette)
	ui.query_history_destroy(&app.find_history)
	focus_jumps_destroy(&app.focus_jumps)
	file_dialogs_destroy(app)
	markdown_app_destroy(&app.markdown_state)
	changes_app_destroy(&app.changes_state)
	ui.notices_destroy(&app.notices)
	shortcut_undo_destroy(&app.shortcut_undo)
	commands.destroy(&app.registry)
	commands.keymap_destroy(&app.keymap)
	settings.destroy(&app.settings)
	settings.inputs_destroy(&app.settings_inputs)
	settings_notice_state_destroy(&app.settings_notices)
	delete(app.settings_path)
	theme_record_remove(app)
	instance.paths_destroy(&app.paths)
	delete(app.log_path)
	layout_state_destroy(app)
	palette_usage_store_destroy(&app.palette_store)
	closed_destroy(app)
	app_update_destroy(app)
	app_events.destroy(&app.events)
	delete(app.app_id)
	if app.platform_ready {
		if platform_api.destroy(&app.platform) != .None {
			log.error("platform shutdown reported an error")
		}
	}
}

run :: proc(app: ^App) {
	for app_running(app) {
		waits := frame_waits(app)
		signaled, err := platform_api.wait_events(
			&app.platform,
			wait_timeout(app, waits),
			waits.handles[:waits.count],
		)
		if err != .None {
			log.error("waiting for events failed")
		}
		if signaled >= 0 {render.frame_signaled(window_surface(waits.windows[signaled]))}
		tick(app, wait_frames = false)
	}
	// Consumers hear of the quit while everything they may ask about still exists.
	app_events.push(&app.events, .App_Quitting, Event_Empty{})
	app_events_deliver(app)
}

// The windows that want a frame and how the loop learns it may draw them: a window with a swap chain
// draws when the swap chain signals room for its next frame, so frames follow the display's refresh
// and each window keeps its own display's pace.
@(private = "file")
Frame_Waits :: struct {
	handles: [32]rawptr,
	windows: [32]^Window,
	count:   int,
	// A window can draw at once: it has no surface yet, which its next frame makes.
	ready:   bool,
	// A window wants frames that its swap chain cannot wake the loop for: it cannot present but still
	// has motion to finish, it holds a frame it failed to draw, or no wait slot is left. The loop
	// retries on the assumed refresh.
	unpaced: bool,
}

@(private = "file")
frame_waits :: proc(app: ^App) -> (waits: Frame_Waits) {
	waits.unpaced = notices_unshown(app) && ui.notices_animating(&app.notices)
	for w in app.windows {
		animating := window_animating(app, w)
		if !window_drawable(w) {
			waits.unpaced ||= animating
			continue
		}
		if !w.dirty && !animating && !status_spin_active(w) {continue}
		switch surface in w.surface {
		case ^render.Surface:
			handle := render.frame_waitable(surface)
			if handle == nil || waits.count == len(waits.handles) {
				waits.unpaced = true
				continue
			}
			waits.handles[waits.count], waits.windows[waits.count] = handle, w
			waits.count += 1
		case Surface_Failed:
			waits.unpaced ||= animating
		case nil:
			waits.ready = true
		}
	}
	return
}

// One iteration of the main loop; also driven by the platform during modal resize loops and by tests.
// Those wait for each window's swap chain and draw it, as the size-move timer expects; the main loop
// passes false because its own wait already took the swap chains that signaled.
tick :: proc(app: ^App, wait_frames := true) {
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
	// Each window samples its next frame's instant, picking up motion events retargeted without drawing.
	update_motion(app)
	app_timers_advance(app, .Before_Draw)
	pane_links_sync(app)
	window_notices_sync(app)
	for window in app.windows {
		now := host.clock_now(&app.clock)
		for timer in Window_Timer {window_timer_advance(app, window, timer, now)}
		status_spin_tick(window)
		status_taskbar_follow(app, window)
		if !window_drawable(window) {
			if window.phase == .Preparing {window.dirty = false}
			continue
		}
		window_surface_settle(app, window)
		if window.dirty || window_animating(app, window) {
			window_render(app, window, wait_frames)
			// The harness counts this window's present now; its After_Draw timer reads every window's.
			when AIO_CONTROL {verify_presented(app, window)}
		}
	}
	app_timers_advance(app, .After_Draw)
	control_cli_tick(app)
	focus_jumps_track(app)
	// Lua and pipe consumers are added in app_events_deliver.
	app_events_deliver(app)
	free_all(context.temp_allocator)
}

// Every timed feature that is not a window's, once. Each advances itself and names its next deadline:
// tick advances them and wait_timeout sleeps until the earliest. A value added here must be named by
// every switch below, so no feature can be advanced without waking the loop, or the reverse. Find
// progress stays outside, as a pair: find_tick runs before the timers and the windows' motion, where no
// phase here runs, and find_pending wakes the loop at once rather than at a deadline.
@(private = "file")
App_Timer :: enum u8 {
	Processes,
	Notices,
	// A pane drag resting on another tab switches to it; this can create or discard a preview window.
	Drag_Hover,
	Verify,
	Layout_Save,
	Palette_Usage_Save,
	File_Dialogs,
	Markdown,
	Changes,
	Web,
	Neovim,
	Turns,
	Update,
	// init.lua's timers, process polls and the step after any Lua code ran.
	Lua,
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
	case .Processes, .Notices, .Drag_Hover, .Turns, .Lua, .Neovim:
		return .Before_Draw
	case .Verify, .Layout_Save, .Palette_Usage_Save, .File_Dialogs, .Markdown, .Changes, .Web, .Update:
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
			now := host.clock_now(&app.clock)
			if ui.notices_expire(&app.notices, app.animations, now) {mark_all_dirty(app)}
			// The front card's countdown line redraws only once it has lost a whole pixel: about every
			// frame for a short notice, about 37 times a second for a 12 s one at 100%, and never paused.
			if ui.notices_line_due(&app.notices, now) {
				if w := window_find(app, app.notice_window); w != nil {w.dirty = true}
			}
		case .Drag_Hover:
			for i := 0; i < len(app.windows); i += 1 {
				now := host.clock_now(&app.clock)
				pane_drag_tick(app, app.windows[i], now)
				files_drag_tick(app, app.windows[i], now)
			}
		case .Verify:
			when AIO_CONTROL {verify_tick(app)}
		case .Layout_Save:
			layout_state_tick(app)
		case .Palette_Usage_Save:
			palette_usage_tick(app)
		case .File_Dialogs:
			file_dialogs_tick(app)
		case .Markdown:
			markdown_tick(app)
		case .Changes:
			changes_tick(app)
		case .Web:
			web_tick(app)
		case .Neovim:
			neovim_tick(app)
		case .Update:
			app_update_tick(app)
		case .Turns:
			turns_tick(app)
		case .Lua:
			lua_host_tick(app)
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
			if at, armed := drag_hover_deadline(w); armed {next, pending = host.earliest(next, pending, at)}
			if at, armed := files_drag_deadline(w); armed {next, pending = host.earliest(next, pending, at)}
		}
	case .Verify:
		when AIO_CONTROL {return verify_deadline(app)}
	case .Layout_Save:
		return layout_state_deadline(app)
	case .Palette_Usage_Save:
		return palette_usage_deadline(app)
	case .File_Dialogs:
		// A finished dialog wakes the loop itself.
	case .Markdown:
		return markdown_poll_deadline(app)
	case .Changes:
		return changes_poll_deadline(app)
	case .Web:
		return web_poll_deadline(app)
	case .Neovim:
		return neovim_deadline(app)
	case .Turns:
		return turns_deadline(app)
	case .Update:
		// A finished updater wakes the loop itself.
	case .Lua:
		return lua_host_deadline(app)
	}
	return
}

// Every timed feature of a window, once, advanced before the window draws.
@(private = "file")
Window_Timer :: enum u8 {
	Leader,
	Key_Sequence,
	Cursor_Blink,
	Capture_Hold,
	Selection_Autoscroll,
	Markdown_Autoscroll,
	Scroll_Hold,
	Tooltip,
	Hidden_Panes,
	Link_Submenu,
	Command_Submenu,
	Tab_Submenu,
}

@(private = "file")
window_timer_advance :: proc(app: ^App, w: ^Window, timer: Window_Timer, now: time.Tick) {
	switch timer {
	case .Leader:
		leader_expire(w, now)
	case .Key_Sequence:
		key_sequence_expire(w, now)
	case .Cursor_Blink:
		cursor_blink_tick(w, now)
	case .Capture_Hold:
		capture_hold_tick(w, now)
	case .Selection_Autoscroll:
		selection_autoscroll_tick(app, w, now)
	case .Markdown_Autoscroll:
		markdown_autoscroll_tick(app, w, now)
	case .Scroll_Hold:
		scroll_hold_tick(app, w, now)
	case .Tooltip:
		tooltip_tick(w, now)
	case .Hidden_Panes:
		hidden_panes_tick(w, now)
	case .Link_Submenu:
		document_submenu_tick(app, w, now)
	case .Command_Submenu:
		command_submenu_tick(app, w, now)
	case .Tab_Submenu:
		tab_submenu_tick(app, w, now)
	}
}

@(private = "file")
window_timer_deadline :: proc(w: ^Window, timer: Window_Timer) -> (time.Tick, bool) {
	switch timer {
	case .Leader:
		return leader_deadline(w)
	case .Key_Sequence:
		return key_sequence_deadline(w)
	case .Cursor_Blink:
		return cursor_blink_deadline(w)
	case .Capture_Hold:
		return capture_hold_deadline(w)
	case .Selection_Autoscroll:
		return selection_autoscroll_deadline(w)
	case .Markdown_Autoscroll:
		return markdown_autoscroll_deadline(w)
	case .Scroll_Hold:
		return scroll_hold_deadline(w)
	case .Tooltip:
		return tooltip_deadline(w)
	case .Hidden_Panes:
		return hidden_panes_deadline(w)
	case .Link_Submenu:
		return document_submenu_deadline(w)
	case .Command_Submenu:
		return command_submenu_deadline(w)
	case .Tab_Submenu:
		return tab_submenu_deadline(w)
	}
	return {}, false
}

// How long the loop may sleep when nothing signals. Windows paced by their swap chain are not timed
// here: their waitables wake the loop.
@(private = "file")
wait_timeout :: proc(app: ^App, waits: Frame_Waits) -> u32 {
	if waits.ready {return 0}
	if waits.unpaced {return u32(time.duration_milliseconds(render.FRAME_PERIOD_DEFAULT))}
	deadline: time.Tick
	found := false
	for timer in App_Timer {
		if next, pending := app_timer_deadline(app, timer); pending {
			deadline, found = host.earliest(deadline, found, next)
		}
	}
	for window in app.windows {
		for timer in Window_Timer {
			if next, pending := window_timer_deadline(window, timer); pending {
				deadline, found = host.earliest(deadline, found, next)
			}
		}
	}
	if find_pending(app) {return 0}
	return host.wait_ms(deadline, found, host.clock_now(&app.clock))
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
	}
	box, width, height, _ := pane_box_for_grid(
		app,
		template,
		u16(app.settings.window.columns),
		u16(app.settings.window.rows),
		pane_insets(app, &template, nil),
	)
	return pane_box_geometry(box, fields.metrics, width, height)
}

notify :: proc(app: ^App, kind: ui.Notice_Kind, text: string) {
	duration := kind == .Error || kind == .Warning ? ERROR_NOTICE_DURATION : NOTICE_DURATION
	key := u32(Notice_Key.Transient)
	ui.notices_put(&app.notices, key, kind, text, duration, app.animations,
		host.clock_now(&app.clock), stack = true)
	mark_all_dirty(app)
}

// Resolves the configured terminal font, falling back to fonts every Windows install has.
apply_fonts :: proc(app: ^App) {
	family, err := font.family_load(app.fonts, app.settings.font.family)
	if err == .None {
		app.family = family
		ui.notices_clear(&app.notices, u32(Notice_Key.Font), app.animations)
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
				host.clock_now(&app.clock),
			)
			return
		}
	}
	log.errorf("no terminal font could be loaded: %v", err)
}

apply_theme :: proc(app: ^App) {
	app.theme = views.theme_from(app.settings.active_theme, app.settings.interface)
	theme_record_publish(app)
	web_theme_apply(app)
}

@(private)
terminal_colors :: proc(c: settings.Color_Settings) -> term.Colors {
	colors := term.Colors {
		foreground = c.foreground,
		background = c.background,
		cursor     = c.cursor,
		light      = c.light,
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
