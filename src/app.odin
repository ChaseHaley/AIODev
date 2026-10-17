package main

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"
import "aio:commands"
import "aio:font"
import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"

@(private) FALLBACK_FONT_FAMILIES :: [?]string{"Cascadia Mono", "Consolas"}
@(private) UI_FONT_POINTS :: 10.5
@(private) MIN_FONT_POINTS :: 6
@(private) MAX_FONT_POINTS :: 72
@(private) NOTICE_DURATION :: 6 * time.Second
@(private) ERROR_NOTICE_DURATION :: 12 * time.Second

@(private)
Notice_Key :: enum u32 {
	Transient,
	Session,
	Settings,
	Font,
}

Init_Result :: enum {
	Ready,
	Already_Running,
	Failed,
}

Session_Entry :: struct {
	id: u32,
	session: ^term.Session,
	status: term.Status_Kind,
}

App :: struct {
	platform: platform.Platform,
	platform_ready: bool,
	settings: settings.Settings,
	settings_path: string,
	fonts: ^font.System,
	family: font.Family,
	font_points: f32,
	device: ^render.Device,
	cache: glyphs.Cache,
	ui_text: ui.Text,
	ui_ready: bool,
	theme: ui.Theme,
	registry: commands.Registry,
	palette: ui.Palette,
	notices: ui.Notices,
	sessions: [dynamic]Session_Entry,
	next_session_id: u32,
	windows: [dynamic]^Window,
	running: bool,
	tray_hint_shown: bool,
}

app_init :: proc(app: ^App) -> Init_Result {
	switch platform.init(&app.platform, APP_ID) {
	case .Secondary:
		return .Already_Running
	case .Failed:
		log.error("platform initialization failed")
		return .Failed
	case .Primary:
		app.platform_ready = true
	}
	ui.notices_init(&app.notices)
	app.registry = commands.create()
	register_actions(app)
	if ui.palette_init(&app.palette) != nil {
		return .Failed
	}
	load_settings(app)
	font_error: font.Error
	app.fonts, font_error = font.system_create()
	if font_error != .None {
		log.errorf("font system creation failed: %v", font_error)
		return .Failed
	}
	render_error: render.Error
	app.device, render_error = render.device_create()
	if render_error != .None {
		log.errorf("graphics device creation failed: %v", render_error)
		return .Failed
	}
	apply_text_gamma(app)
	glyphs.init(&app.cache, app.fonts, app.device)
	ui_size_px := UI_FONT_POINTS * f32(platform.primary_dpi(&app.platform)) / 72
	if !ui.text_init(&app.ui_text, app.fonts, &app.cache, ui_size_px) {
		log.error("no interface font is available")
		return .Failed
	}
	app.ui_ready = true
	apply_fonts(app)
	apply_theme(app)
	if !session_open(app) {
		return .Failed
	}
	if platform.tray_create(&app.platform, APP_ID) != .None {
		log.error("creating the tray icon failed")
	}
	tray_menu := [?]platform.Tray_Menu_Item{
		{id = TRAY_OPEN, title = "Open AIODev"},
		{id = TRAY_QUIT, title = "Quit"},
	}
	if platform.tray_set_menu(&app.platform, tray_menu[:]) != .None {
		log.error("setting the tray menu failed")
	}
	platform.set_modal_loop_callback(&app.platform, proc(user: rawptr) { tick((^App)(user)) }, app)
	if !window_open(app) {
		return .Failed
	}
	app.running = true
	return .Ready
}

app_destroy :: proc(app: ^App) {
	for len(app.windows) > 0 {
		window_close(app, app.windows[len(app.windows) - 1])
	}
	delete(app.windows)
	for entry in app.sessions {
		term.destroy(entry.session)
	}
	delete(app.sessions)
	if app.platform_ready {
		if platform.tray_destroy(&app.platform) != .None {
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
	if app.platform_ready {
		if platform.destroy(&app.platform) != .None {
			log.error("platform shutdown reported an error")
		}
	}
}

run :: proc(app: ^App) {
	for app.running {
		if platform.wait_events(&app.platform, wait_timeout(app)) != .None {
			log.error("waiting for events failed")
		}
		tick(app)
	}
}

// One iteration of the main loop; also driven by the platform during modal resize loops.
tick :: proc(app: ^App) {
	events, err := platform.poll_events(&app.platform)
	if err != .None {
		log.errorf("polling events failed: %v", err)
	}
	for event in events {
		handle_event(app, event)
	}
	update_sessions(app)
	if ui.notices_expire(&app.notices, time.tick_now()) {
		mark_all_dirty(app)
	}
	for window in app.windows {
		update_blink(window)
		if window.dirty {
			window_render(app, window)
		}
	}
	free_all(context.temp_allocator)
}

@(private)
wait_timeout :: proc(app: ^App) -> u32 {
	INFINITE :: max(u32)
	deadline, found := ui.notices_deadline(&app.notices)
	for window in app.windows {
		if window.blinking && (!found || time.tick_diff(window.blink_deadline, deadline) > 0) {
			deadline, found = window.blink_deadline, true
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
	if platform.wake((^platform.Platform)(user)) != .None {
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
		command_line = app.settings.shell.command,
		working_directory = directory,
		geometry = geometry,
		scrollback_lines = app.settings.scrollback.lines,
		colors = terminal_colors(app.settings.colors),
	}
}

@(private)
session_open :: proc(app: ^App) -> bool {
	scale := f32(platform.primary_dpi(&app.platform)) / 96
	metrics := window_metrics(app, scale)
	padding := f32(app.settings.window.padding) * scale
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
	session, err := term.create(session_config(app, geometry), {wake_platform, &app.platform})
	if err != .None {
		log.errorf("creating the terminal session failed: %v", err)
		return false
	}
	app.next_session_id += 1
	append(&app.sessions, Session_Entry{id = app.next_session_id, session = session, status = .Running})
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
	term.restart(entry.session, session_config(app, geometry))
	ui.notices_clear(&app.notices, u32(Notice_Key.Session))
	mark_all_dirty(app)
}

@(private)
update_sessions :: proc(app: ^App) {
	for &entry in app.sessions {
		s := entry.session
		status := term.status(s)
		if status.kind != entry.status {
			entry.status = status.kind
			show_session_status(app, status)
			mark_all_dirty(app)
		}
		if term.take_title_change(s) {
			title := term.title(s, context.temp_allocator)
			for window in app.windows {
				if platform.window_set_title(&app.platform, window.id, len(title) > 0 ? title : APP_ID) != .None {
					log.error("setting the window title failed")
				}
			}
		}
		if term.take_bell(s) {
			for window in app.windows {
				if !window.focused && platform.window_flash(&app.platform, window.id) != .None {
					log.error("flashing the window failed")
				}
			}
		}
	}
	for window in app.windows {
		generation: u64
		for entry in app.sessions {
			generation += term.generation(entry.session)
		}
		if generation != window.generation {
			window.generation = generation
			window.dirty = true
		}
	}
}

@(private)
show_session_status :: proc(app: ^App, status: term.Status) {
	key := u32(Notice_Key.Session)
	switch status.kind {
	case .Running:
		ui.notices_clear(&app.notices, key)
	case .Exited:
		text := fmt.tprintf("The shell exited with code %d. Press Enter to restart it.", status.exit_code)
		ui.notices_put(&app.notices, key, .Info, text, 0)
	case .Failed:
		reason := len(status.message) > 0 ? status.message : "Could not start the shell."
		text := fmt.tprintf("%s Check shell.command in the settings file, then press Enter to try again.", reason)
		ui.notices_put(&app.notices, key, .Error, text, 0)
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
	loaded, diagnostics, created, err := settings.load(app.settings_path)
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
	for d, i in diagnostics {
		if i == 3 {
			fmt.sbprintf(&b, " (%d more)", len(diagnostics) - 3)
			break
		}
		fmt.sbprintf(&b, "%sLine %d, %s: %s.", i > 0 ? " " : "", d.line, d.key, d.message)
	}
	text := fmt.tprintf("Settings: %s", strings.to_string(b))
	ui.notices_put(&app.notices, u32(Notice_Key.Settings), .Error, text, ERROR_NOTICE_DURATION)
}

reload_settings :: proc(app: ^App) {
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
	c := app.settings.colors
	app.theme = ui.theme_from(color(c.background), color(c.foreground), color(c.palette[4]), color(c.palette[1]))
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
