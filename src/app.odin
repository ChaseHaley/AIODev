package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "aio:commands"
import "aio:font"
import "aio:glyphs"
import "aio:instance"
import platform_api "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"

@(private) FALLBACK_FONT_FAMILIES :: [?]string{"Cascadia Mono", "Consolas"}
@(private) MIN_FONT_POINTS :: 6
@(private) MAX_FONT_POINTS :: 72
@(private) NOTICE_DURATION :: 6 * time.Second
@(private) COPY_NOTICE_DURATION :: 2 * time.Second
@(private) ERROR_NOTICE_DURATION :: 12 * time.Second
@(private) PASTE_CONFIRM_DURATION :: 10 * time.Second
@(private) PASTE_CONFIRM_TEXT ::
	"The clipboard text has line breaks, so the shell will run each line as a command. " +
	"Paste again within 10 seconds to confirm."

@(private)
Notice_Key :: enum u32 {
	Transient = 1,
	Settings,
	Font,
	Copy,
	Paste,
}

Session_Entry :: struct {
	id: u32,
	session: ^term.Session,
	status: term.Status_Kind,
	keep_open: bool,
	process_padding: Maybe(int),
	process_name: [780]u8,
	process_name_length: int,
	header: Pane_Header_Metadata,
	name: string,
}

App :: struct {
	verify: Verify,
	options: instance.Options,
	app_id: string,
	platform: platform_api.Platform,
	platform_ready: bool,
	settings: settings.Settings,
	settings_path: string,
	log_path: string,
	fonts: ^font.System,
	family: font.Family,
	font_points: f32,
	device: ^render.Device,
	cache: glyphs.Cache,
	shell_icon: Shell_Icon,
	ui_text: ui.Text,
	ui_ready: bool,
	animations: bool,
	theme: ui.Theme,
	registry: commands.Registry,
	leader: Maybe(commands.Shortcut),
	palette: ui.Palette,
	palette_window: platform_api.Window_Id,
	notices: ui.Notices,
	sessions: [dynamic]Session_Entry,
	workspaces: [dynamic]^Workspace,
	next_workspace_id: u32,
	next_session_id: u32,
	windows: [dynamic]^Window,
	running: bool,
	tray_hint_shown: bool,
	process_deadline: time.Tick,
}

@(require_results)
app_init :: proc(app: ^App) -> bool {
	if app.options.data_dir != "" {
		path, err := filepath.join({app.options.data_dir, "settings.ini"})
		if err != nil {
			log.errorf("constructing the settings path failed: %v", err)
			return false
		}
		app.settings_path = path
		if directory_error := os.mkdir_all(app.options.data_dir); directory_error != nil {
			log.errorf("creating the data directory failed: %v", directory_error)
			return false
		}
	}
	app.animations = platform_api.client_animations_enabled()
	ui.notices_init(&app.notices)
	app.notices.animations = app.animations
	app.registry = commands.create()
	if err := register_actions(&app.registry); err != .None {
		log.errorf("registering commands failed: %v", err)
		return false
	}
	@(static) palette_settings: [len(settings.SCHEMA)]ui.Palette_Setting
	@(static, rodata) schema := settings.SCHEMA
	for entry, i in schema {
		palette_settings[i] = {entry.key, entry.title, settings.group_title(entry.key)}
	}
	if ui.palette_init(&app.palette, palette_settings[:]) != nil {
		return false
	}
	load_settings(app)
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
	ui_size_px := f32(app.settings.interface.font_size) * f32(platform_api.primary_dpi(&app.platform)) / 72
	if !ui.text_init(&app.ui_text, app.fonts, &app.cache, ui_size_px) {
		log.error("no interface font is available")
		return false
	}
	app.ui_ready = true
	shell_icon_load(app)
	apply_fonts(app)
	apply_theme(app)
	workspace := workspace_create_empty(app)
	if workspace == nil { return false }
	if !tab_create(app, workspace) { return false }
	if platform_api.tray_create(&app.platform, app.app_id) != .None {
		log.error("creating the tray icon failed")
	}
	tray_menu := [?]platform_api.Tray_Menu_Item{
		{id = TRAY_OPEN, title = "Open AIODev"},
		{id = TRAY_QUIT, title = "Quit"},
	}
	if platform_api.tray_set_menu(&app.platform, tray_menu[:]) != .None {
		log.error("setting the tray menu failed")
	}
	platform_api.set_modal_loop_callback(&app.platform, proc(user: rawptr) { tick((^App)(user)) }, app)
	if !window_open(app, workspace) {
		return false
	}
	verify_start(app)
	app.running = true
	return true
}

app_destroy :: proc(app: ^App) {
	verify_destroy(app)
	for len(app.windows) > 0 {
		window_close(app, app.windows[len(app.windows) - 1])
	}
	delete(app.windows)
	for &entry in app.sessions {
		pane_header_destroy(&entry.header)
		delete(entry.name)
		term.destroy(entry.session)
	}
	delete(app.sessions)
	for workspace in app.workspaces { workspace_destroy(workspace) }
	delete(app.workspaces)
	if app.platform_ready {
		if platform_api.tray_destroy(&app.platform) != .None {
			log.error("removing the tray icon failed")
		}
	}
	glyphs.destroy(&app.cache)
	if app.device != nil {
		render.device_destroy(app.device)
	}
	if app.fonts != nil {
		font.system_destroy(app.fonts)
	}
	ui.palette_destroy(&app.palette)
	ui.notices_destroy(&app.notices)
	commands.destroy(&app.registry)
	settings.destroy(&app.settings)
	delete(app.settings_path)
	delete(app.log_path)
	delete(app.app_id)
	if app.platform_ready {
		if platform_api.destroy(&app.platform) != .None {
			log.error("platform shutdown reported an error")
		}
	}
}

run :: proc(app: ^App) {
	for app.running {
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
	update_sessions(app)
	update_process_padding(app)
	update_motion(app)
	if ui.notices_expire(&app.notices, time.tick_now()) {
		mark_all_dirty(app)
	}
	// A dwell can create or discard the trailing preview window.
	for i := 0; i < len(app.windows); i += 1 { pane_drag_tick(app, app.windows[i], time.tick_now()) }
	for window in app.windows {
		if window.leader_until != {} && time.tick_diff(time.tick_now(), window.leader_until) <= 0 {
			leader_cancel(window)
		}
		update_blink(window)
		update_autoscroll(app, window)
		if window.dirty {
			window_render(app, window)
			verify_presented(app, window)
		}
	}
	verify_tick(app)
	free_all(context.temp_allocator)
}

@(private)
wait_timeout :: proc(app: ^App) -> u32 {
	if motion_active(app) { return 16 }
	INFINITE :: max(u32)
	deadline, found := ui.notices_deadline(&app.notices)
	if app.process_deadline != {} && (!found || time.tick_diff(app.process_deadline, deadline) > 0) {
		deadline, found = app.process_deadline, true
	}
	if next, pending := verify_deadline(app); pending && (!found || time.tick_diff(next, deadline) > 0) {
		deadline, found = next, true
	}
	for window in app.windows {
		if next := window.pane_drag.hover_until; next != {} && (!found || time.tick_diff(next, deadline) > 0) {
			deadline, found = next, true
		}
		if window.leader_until != {} && (!found || time.tick_diff(window.leader_until, deadline) > 0) {
			deadline, found = window.leader_until, true
		}
		if window.blinking && (!found || time.tick_diff(window.blink_deadline, deadline) > 0) {
			deadline, found = window.blink_deadline, true
		}
		if window.autoscrolling && (!found || time.tick_diff(window.autoscroll_deadline, deadline) > 0) {
			deadline, found = window.autoscroll_deadline, true
		}
	}
	for entry in app.sessions {
		if term.search_pending(entry.session) {
			return 0
		}
	}
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

@(private)
session_config :: proc(app: ^App, geometry: term.Geometry) -> term.Config {
	directory, err := settings.expand_home(app.settings.shell.directory, context.temp_allocator)
	if err != nil {
		log.errorf("expanding the shell directory failed: %v", err)
		directory = app.settings.shell.directory
	}
	return {
		command_line = settings.shell_command_line(app.settings.shell.command, app.settings.shell.report_directory),
		refresh_environment = app.settings.shell.refresh_environment,
		working_directory = directory,
		geometry = geometry,
		scrollback_lines = app.settings.scrollback.lines,
		colors = terminal_colors(app.settings.colors),
	}
}

initial_geometry :: proc(app: ^App) -> term.Geometry {
	scale := f32(platform_api.primary_dpi(&app.platform)) / 96
	metrics := window_metrics(app, scale)
	padding := math.round(f32(app.settings.window.padding)*scale)+
		math.round(f32(app.settings.pane.gap)*scale)
	geometry := term.Geometry{
		columns = u16(app.settings.window.columns),
		rows = u16(app.settings.window.rows),
		cell_width = u32(metrics.cell_width),
		cell_height = u32(metrics.cell_height),
		padding_left = u32(padding),
		padding_top = u32(padding),
	}
	geometry.surface_width = u32(geometry.columns) * geometry.cell_width + 2 * geometry.padding_left
	geometry.surface_height = u32(geometry.rows) * geometry.cell_height + 2 * geometry.padding_top
	geometry.padding_top += u32(ui.TAB_HEIGHT*scale)
	geometry.surface_height += u32(ui.TAB_HEIGHT*scale)
	if app.settings.pane.show_headers {
		header := u32(math.round(ui.HEADER_HEIGHT*scale))
		geometry.padding_top += header
		geometry.surface_height += header
	}
	return geometry
}

@(private)
session_open :: proc(app: ^App, command: string = "", directory: string = "") -> bool {
	geometry := initial_geometry(app)
	config := session_config(app, geometry)
	if command != "" { config.command_line = command }
	if directory != "" { config.working_directory = directory }
	session, err := term.create(config, {wake_platform, &app.platform})
	if err != .None {
		log.errorf("creating the terminal session failed: %v", err)
		return false
	}
	app.next_session_id += 1
	if _, allocation_error := append(&app.sessions,
		Session_Entry{id = app.next_session_id, session = session, status = term.status(session).kind});
		allocation_error != nil {
		term.destroy(session)
		return false
	}
	pane_header_launch(&app.sessions[len(app.sessions)-1].header, config)
	configure_session(app, session)
	return true
}

@(private)
configure_session :: proc(app: ^App, session: ^term.Session) {
	cursor: term.Cursor_Style
	switch app.settings.cursor.style {
	case .Block: cursor = .Block
	case .Bar: cursor = .Bar
	case .Underline: cursor = .Underline
	}
	term.configure(session, app.settings.scrollback.lines, cursor, app.settings.cursor.blink)
}

session_find :: proc(app: ^App, id: u32) -> ^Session_Entry {
	for &entry in app.sessions {
		if entry.id == id {
			return &entry
		}
	}
	return nil
}

session_restart :: proc(app: ^App, entry: ^Session_Entry) {
	geometry := term.geometry(entry.session)
	config := session_config(app, geometry)
	term.restart(entry.session, config)
	pane_header_launch(&entry.header, config)
	pane_header_refresh(entry)
	status := term.status(entry.session)
	entry.status = status.kind
	mark_all_dirty(app)
}

@(private)
update_sessions :: proc(app: ^App) {
	workspace_status_changed := false
	// Exit cleanup removes only the current entry; earlier entries remain valid.
	for i := len(app.sessions)-1; i >= 0; i -= 1 {
		entry := &app.sessions[i]
		s := entry.session
		if term.search_pending(s) {
			before := term.search_summary(s)
			term.search_update(s)
			if term.search_summary(s) != before {
				mark_all_dirty(app)
			}
		}
		if term.take_status_change(s) {
			workspace_status_changed = true
			status := term.status(s)
			if status.kind != entry.status {
				entry.status = status.kind
				mark_all_dirty(app)
			}
			if status.kind == .Exited && close_exited_session(app, entry.id) { continue }
		}
		if term.take_title_change(s) {
			pane_header_refresh(entry)
			session_titles_changed(app, entry.id)
		}
		workspace_status_changed = term.take_program_status_change(s) || workspace_status_changed
		if term.take_bell(s) {
			for window in app.windows {
				if !window.focused && platform_api.window_flash(&app.platform, window.id) != .None {
					log.error("flashing the window failed")
				}
			}
		}
	}
	if workspace_status_changed { workspace_picker_status_changed(app) }
	for window in app.windows {
		generation := window_generation(app, window)
		if generation != window.generation {
			window.generation = generation
			window.dirty = true
		}
	}
}

notify :: proc(app: ^App, kind: ui.Notice_Kind, text: string) {
	duration := kind == .Error ? ERROR_NOTICE_DURATION : NOTICE_DURATION
	ui.notices_put(&app.notices, u32(Notice_Key.Transient), kind, text, duration)
	mark_all_dirty(app)
}

load_settings :: proc(app: ^App) {
	if app.settings_path == "" {
		path, err := settings.default_path()
		if err != nil {
			log.errorf("locating the settings file failed: %v", err)
		}
		app.settings_path = path
	}
	comments := binding_comments()
	loaded, diagnostics, created, err := settings.load(app.settings_path, extra_comments = comments[:])
	defer settings.diagnostics_destroy(&diagnostics)
	if err != nil {
		log.errorf("reading %s failed: %v", app.settings_path, err)
		text := fmt.tprintf("Could not read %s. Using default settings.", app.settings_path)
		ui.notices_put(&app.notices, u32(Notice_Key.Settings), .Error, text, ERROR_NOTICE_DURATION)
		defaults, default_error := settings.defaults()
		if default_error != nil {
			return
		}
		loaded = defaults
	}
	settings.destroy(&app.settings)
	app.settings = loaded
	app.process_deadline = {}
	for &entry in app.sessions { entry.process_padding = nil }
	apply_bindings(app, &diagnostics)
	app.font_points = f32(loaded.font.size)
	if created {
		log.infof("created %s", app.settings_path)
	}
	if len(diagnostics) == 0 {
		if err == nil {
			ui.notices_clear(&app.notices, u32(Notice_Key.Settings))
		}
		return
	}
	b := strings.builder_make(context.temp_allocator)
	warnings_only := true
	for d in diagnostics { if d.kind != .Shortcut_Warning { warnings_only = false } }
	for d, i in diagnostics {
		if i == 3 {
			fmt.sbprintf(&b, " (%d more)", len(diagnostics) - 3)
			break
		}
		fmt.sbprintf(&b, "%sLine %d, %s: %s.", i > 0 ? " " : "", d.line, d.key, d.message)
	}
	text := fmt.tprintf("Settings: %s", strings.to_string(b))
	ui.notices_put(&app.notices, u32(Notice_Key.Settings), warnings_only ? .Info : .Error, text, ERROR_NOTICE_DURATION)
}

reload_settings :: proc(app: ^App) {
	refresh_animations(app)
	for i := len(app.windows)-1; i >= 0; i -= 1 {
		if i >= len(app.windows) { continue }
		window := app.windows[i]
		leader_cancel(window)
		arrange_cancel(app, window)
	}
	previous_shell := strings.clone(app.settings.shell.command, context.temp_allocator)
	previous_directory := strings.clone(app.settings.shell.directory, context.temp_allocator)
	load_settings(app)
	apply_fonts(app)
	apply_theme(app)
	for entry in app.sessions {
		term.set_colors(entry.session, terminal_colors(app.settings.colors))
		configure_session(app, entry.session)
	}
	if previous_shell != app.settings.shell.command || previous_directory != app.settings.shell.directory {
		notify(app, .Info, "Shell settings apply the next time the shell restarts.")
	} else {
		notify(app, .Info, "Settings reloaded.")
	}
	for window in app.windows {
		window_apply_settings(app, window)
	}
	shell_icon_load(app)
}

// Resolves the configured terminal font, falling back to fonts every Windows install has.
apply_fonts :: proc(app: ^App) {
	family, err := font.family_load(app.fonts, app.settings.font.family)
	if err == .None {
		app.family = family
		ui.notices_clear(&app.notices, u32(Notice_Key.Font))
		return
	}
	for name in FALLBACK_FONT_FAMILIES {
		if fallback, fallback_error := font.family_load(app.fonts, name); fallback_error == .None {
			app.family = fallback
			text := fmt.tprintf("Font \"%s\" is not installed. Using %s.", app.settings.font.family, name)
			ui.notices_put(&app.notices, u32(Notice_Key.Font), .Error, text, ERROR_NOTICE_DURATION)
			return
		}
	}
	log.errorf("no terminal font could be loaded: %v", err)
}

apply_theme :: proc(app: ^App) {
	app.theme = ui.theme_from(settings.theme_resolve(app.settings.theme))
}

color :: proc(c: settings.Color, alpha: f32 = 1) -> render.Color {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, alpha}
}

@(private)
terminal_colors :: proc(c: settings.Color_Settings) -> term.Colors {
	colors := term.Colors{foreground = c.foreground, background = c.background, cursor = c.cursor}
	for value, i in c.palette {
		colors.palette[i] = value
	}
	return colors
}

set_font_points :: proc(app: ^App, points: f32) {
	app.font_points = clamp(points, MIN_FONT_POINTS, MAX_FONT_POINTS)
	for window in app.windows {
		window_apply_settings(app, window)
	}
}

apply_text_gamma :: proc(app: ^App) {
	gamma := font.text_gamma(app.fonts)
	render.set_text_gamma(app.device, {gamma = gamma.gamma, enhanced_contrast = gamma.enhanced_contrast})
}
