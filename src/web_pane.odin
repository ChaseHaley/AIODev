package main

import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:links"
import "aio:platform"
import "aio:render"
import "aio:search"
import "aio:ui"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Embedded web panes, hosted with WebView2 DirectComposition visual hosting (WORK-315, D-106). No
// DirectComposition or WebView2 object exists until a web pane is opened.

@(private)
WEB_POLL :: 500 * time.Millisecond
@(private)
WEB_NAV_HEIGHT :: f32(32)
@(private)
WEB_NAV_BUTTON_SIZE :: f32(24)
@(private)
WEB_NAV_PAD :: f32(6)
@(private)
WEB_NAV_GAP :: f32(4)
// The loading line along the bottom of the URL bar, or of the header when the bar is hidden: a segment
// that sweeps across in the notices' sweep timing while the page loads.
@(private)
WEB_LOAD_LINE :: f32(2)
@(private)
WEB_LOAD_SWEEP :: 1200 * time.Millisecond
@(private)
WEB_LOAD_SHARE :: f32(0.3)
@(private)
WEB_RELOAD_BUTTON :: [2]f32{96, 28}
// DirectComposition levels a window stacks: tiled web views, then one per floating group with a web
// view. Further groups share the top level.
@(private)
WEB_LEVELS_MAX :: 8

Web_Nav_Button :: enum u8 {
	None,
	Back,
	Forward,
	Reload,
	Url,
	Zoom,
	Copy_Link,
	Open_External,
	// The Reload button a crashed page shows in its body.
	Recover,
}

Web_Accel_Pending :: struct {
	window: input.Window_Id,
	event:  input.Key_Event,
}

// Per-window DirectComposition host and the draw-list splits around its web views. Embedded in Window.
Web_Window_State :: struct {
	host:        platform.Webview_Host,
	host_failed: bool,
	// The frame shows a web pane, so its draw list splits into overlays around the web views.
	shown:       bool,
	// Draw-list layers where each overlay starts: the first after the tiled panes and chrome, then one
	// after each floating group that shows a web pane. Overlay i covers web level i.
	splits:      [WEB_LEVELS_MAX]int,
	split_count: int,
	// The floating group being drawn shows a web pane.
	group_web:   bool,
}

// App-wide WebView2 environment and pane registry. Embedded in App.
Web_App :: struct {
	web_panes:       [dynamic]^Web_Pane,
	next_web_id:     u32,
	web_env:         platform.Webview_Env,
	web_env_failed:  bool,
	web_deadline:    time.Tick,
	web_accel_queue: [dynamic]Web_Accel_Pending,
	web_accel_ctx:   runtime.Context,
}

Web_Pane :: struct {
	id:              u32,
	url:             string,
	title:           string,
	host_label:      string,
	documents:       Document_List,
	view:            platform.Webview,
	host_window:     input.Window_Id,
	nav_bar:         bool,
	url_field:       ui.Text_Field,
	url_editing:     bool,
	can_back:        bool,
	can_forward:     bool,
	loading:         bool,
	ready:           bool,
	failed:          bool,
	crashed:         platform.Webview_Crash,
	webview_focused: bool,
	cursor:          platform.Cursor_Shape,
	// The page zoom, 1 at 100%; kept with the layout.
	zoom:            f64,
	// The find session's matches and its 1-based selected match (-1 for none); find_failed when the
	// WebView2 runtime has no find API.
	find_count:      i32,
	find_index:      i32,
	find_failed:     bool,
	favicon_serial:  u32,
	// The DirectComposition level the last frame drew the pane at; 0 while tiled.
	level:           i32,
	// Permissions already reported as blocked, so a page that keeps asking raises one notice each.
	denied:          bit_set[platform.Webview_Permission],
	nav_hover:       Web_Nav_Button,
	nav_armed:       Web_Nav_Button,
	last_click_ns:   i64,
	last_click_pos:  [2]i32,
	favicon:         Web_Favicon,
}

@(require_results)
web_find :: proc(app: ^App, id: u32) -> ^Web_Pane {
	for pane in app.web_panes {if pane.id == id {return pane}}
	return nil
}

@(private = "file")
web_pane_destroy :: proc(pane: ^Web_Pane) {
	if pane.view != nil {platform.webview_destroy(pane.view)}
	documents_destroy(&pane.documents)
	delete(pane.url)
	delete(pane.title)
	delete(pane.host_label)
	delete(pane.url_field.bytes)
	web_favicon_destroy(&pane.favicon)
	free(pane)
}

web_app_destroy :: proc(state: ^Web_App) {
	for pane in state.web_panes {web_pane_destroy(pane)}
	delete(state.web_panes)
	delete(state.web_accel_queue)
	if state.web_env != nil {platform.webview_env_destroy(state.web_env)}
	state^ = {}
}

web_window_destroy :: proc(app: ^App, w: ^Window) {
	for pane in app.web_panes {
		if pane.host_window == w.id {
			if pane.view != nil {platform.webview_detach_host(&app.platform, pane.view)}
			pane.host_window = 0
		}
	}
	if w.web.host == nil {return}
	platform.webview_host_destroy(w.web.host)
	w.web.host = nil
	w.web.host_failed = false
}

// Rebuilds every window's DirectComposition host after a D3D11 device reset.
web_device_lost :: proc(app: ^App) {
	for w in app.windows {web_window_destroy(app, w)}
}

web_poll_deadline :: proc(app: ^App) -> (next: time.Tick, pending: bool) {
	if app.web_deadline == {} {return}
	return app.web_deadline, true
}

// The host of an http(s) address: "github.com" for "https://github.com/odin-lang".
@(require_results)
web_host_from_url :: proc(url: string) -> string {
	rest := url
	if strings.has_prefix(rest, "https://") {
		rest = rest[8:]
	} else if strings.has_prefix(rest, "http://") {
		rest = rest[7:]
	}
	if slash := strings.index_byte(rest, '/'); slash >= 0 {rest = rest[:slash]}
	if q := strings.index_byte(rest, '?'); q >= 0 {rest = rest[:q]}
	if hash := strings.index_byte(rest, '#'); hash >= 0 {rest = rest[:hash]}
	return rest
}

@(private = "file")
web_pane_set_url_text :: proc(pane: ^Web_Pane, url: string) {
	if pane.url == url {return}
	owned, err := strings.clone(url)
	if err != nil {return}
	host, host_err := strings.clone(web_host_from_url(url))
	if host_err != nil {host = ""}
	delete(pane.url)
	delete(pane.host_label)
	pane.url, pane.host_label = owned, host
	if !pane.url_editing {
		ui.field_set(&pane.url_field, url)
	}
}

@(private = "file")
web_pane_set_title_text :: proc(pane: ^Web_Pane, raw_title: string) {
	clean := display_title(raw_title, context.temp_allocator)
	if pane.title == clean {return}
	owned, err := strings.clone(clean)
	if err != nil {return}
	delete(pane.title)
	pane.title = owned
}

// Pages are asked for the look that matches the window: light on a light theme, dark on a dark one.
@(private = "file")
web_color_scheme :: proc(app: ^App) -> platform.Webview_Color_Scheme {
	return app.settings.active_theme.light ? .Light : .Dark
}

@(private = "file")
web_accel_queue :: proc(app: ^App, window: input.Window_Id, e: input.Key_Event) -> bool {
	append(&app.web_accel_queue, Web_Accel_Pending{window, e})
	_ = platform.wake(&app.platform)
	return true
}

// Called synchronously by WebView2 AcceleratorKeyPressed. Never mutates UI directly; only decides
// whether AIODev should claim the chord and queues it for the next tick.
@(private = "file")
web_accel_callback :: proc "c" (user: rawptr, pane_id: u32, vk: u32, kind: u32, lparam: i32) -> bool {
	if user == nil {return false}
	app := (^App)(user)
	context = app.web_accel_ctx
	// Only intercept key-down / sys-key-down; let releases pass.
	if kind != 0 && kind != 2 {return false}
	pane := web_find(app, pane_id)
	if pane == nil || pane.host_window == 0 {return false}
	w := window_find(app, pane.host_window)
	if w == nil {return false}
	e, ok := platform.webview_accel_key_event(&app.platform, pane.host_window, vk, kind, lparam)
	if !ok || input.is_modifier_key(e.key) {return false}
	// An armed leader chord or a key sequence in progress takes every key until it resolves, as it does
	// in a terminal.
	if leader_armed(w) || w.bindings.count > 0 {return web_accel_queue(app, w.id, e)}
	if leader, enabled := app.leader.?;
	   enabled && commands.shortcut_matches(leader, e.key, e.modifiers, e.unshifted) {
		return web_accel_queue(app, w.id, e)
	}
	if commands.keymap_claims(&app.keymap, &w.bindings, &app.registry, e.key, e.modifiers, e.unshifted) {
		return web_accel_queue(app, w.id, e)
	}
	logical := commands.logical_key(e.key, e.unshifted)
	// Ctrl+L focuses the URL bar and Ctrl+F opens the app's find bar in place of Edge's.
	if e.modifiers == {.Control} && (logical == .L || logical == .F) {return web_accel_queue(app, w.id, e)}
	// Never steal plain typing, Enter, Escape, Tab or navigation keys from web page inputs.
	has_chord := .Control in e.modifiers || .Alt in e.modifiers || .Super in e.modifiers
	if !has_chord && e.key != .F11 {return false}
	// Let standard web editing, reload and zoom chords stay inside the page.
	if e.modifiers == {.Control} {
		#partial switch logical {
		case .C, .V, .X, .A, .Z, .Y, .R, .Equal, .Minus, .Digit_0:
			return false
		}
	}
	if e.modifiers == {.Alt} {
		#partial switch e.key {
		case .Arrow_Left, .Arrow_Right:
			return false
		}
	}
	// Steal bound AIODev shortcuts (palette, splits, focus moves, fullscreen, close pane, tabs).
	if command := commands.find_by_key(&app.registry, e.key, e.modifiers, e.unshifted); command != nil {
		if action, builtin := action_builtin(command.id); builtin && !action_available(app, w, action) {
			return false
		}
		return web_accel_queue(app, w.id, e)
	}
	return false
}

@(private = "file")
web_env_ensure :: proc(app: ^App) -> bool {
	if !platform.webview_supported() {return false}
	if app.web_env != nil {return true}
	if app.web_env_failed {return false}
	app.web_accel_ctx = context
	user_data_dir := ""
	if app.paths.local != "" {
		if joined, join_err := filepath.join({app.paths.local, "webview2"}, context.temp_allocator);
		   join_err == nil {
			user_data_dir = joined
		}
	}
	env, ok := platform.webview_env_create(&app.platform, user_data_dir, web_accel_callback, app)
	if !ok {
		app.web_env_failed = true
		return false
	}
	app.web_env = env
	return true
}

@(private = "file")
web_host_ensure :: proc(app: ^App, w: ^Window) -> platform.Webview_Host {
	if w.web.host != nil {return w.web.host}
	if w.web.host_failed || !platform.webview_supported() {return nil}
	d3d_dev, dxgi_factory := render.device_native_handles(app.device)
	if d3d_dev == nil || dxgi_factory == nil {return nil}
	host, ok := platform.webview_host_create(&app.platform, w.id, d3d_dev, dxgi_factory)
	if !ok {
		w.web.host_failed = true
		return nil
	}
	w.web.host = host
	return host
}

@(require_results)
web_pane_create :: proc(app: ^App, url: string, zoom := f64(1)) -> ^Web_Pane {
	pane, err := new(Web_Pane)
	if err != nil {return nil}
	pane.nav_bar = app.settings.pane.web_navigator
	pane.cursor = .Arrow
	pane.zoom = zoom > 0 ? zoom : 1
	pane.find_index = -1
	if url != "" {web_pane_set_url_text(pane, url)}
	if _, append_err := append(&app.web_panes, pane); append_err != nil {
		web_pane_destroy(pane)
		return nil
	}
	app.next_web_id += 1
	pane.id = app.next_web_id
	if app.web_deadline == {} {
		app.web_deadline = time.tick_add(clock_now(&app.clock), WEB_POLL)
	}
	return pane
}

// Opens `url` in a new web pane beside the focused pane: in a float when pane.web_floating is on, or
// inside the focused pane's float. Returns false only if the pane could not be placed.
@(require_results)
web_open_focused :: proc(app: ^App, w: ^Window, url: string) -> bool {
	if w == nil {return false}
	tree := window_tree(w)
	if tree == nil {return false}
	floating := app.settings.pane.web_floating && !layout.is_floating(tree, tree.focus)
	return web_open_placed(app, w, tree.focus, url, floating ? .Float : .Split_Right)
}

@(require_results)
web_open_placed :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	url: string,
	placement: Pane_Placement,
	edit_url := false,
) -> bool {
	acting, beside, found := pane_placement_window(app, w, node, placement)
	if !found {return false}
	pane := web_pane_create(app, url)
	if pane == nil {return false}
	if edit_url {
		pane.nav_bar = true
		pane.url_editing = true
		ui.field_select_all(&pane.url_field)
	}
	tab := acting.workspace.selected
	if !pane_place(app, acting, acting.workspace, tab, beside, {.Web, pane.id}, placement, true) {
		web_pane_remove(app, pane.id)
		return false
	}
	if edit_url {
		platform.window_reclaim_focus(&app.platform, acting.id)
	}
	acting.dirty = true
	return true
}

// Opens a new empty web pane with its URL bar focused so the user can type an address immediately.
web_open_blank :: proc(app: ^App, w: ^Window) {
	if w == nil {return}
	tree := window_tree(w)
	if tree == nil {return}
	if !web_open_placed(app, w, tree.focus, "", .Split_Right, edit_url = true) {
		notify(app, .Error, "Could not open a web pane.")
	}
}

web_toggle_navigator :: proc(app: ^App, w: ^Window) {
	pane := web_focused_pane(app, w)
	if pane == nil {return}
	pane.nav_bar = !pane.nav_bar
	if !pane.nav_bar {pane.url_editing = false}
	w.dirty = true
}

@(private)
web_pane_remove :: proc(app: ^App, id: u32) {
	for pane, i in app.web_panes {
		if pane.id != id {continue}
		web_pane_destroy(pane)
		ordered_remove(&app.web_panes, i)
		return
	}
}

@(private = "file")
web_content_used :: proc(app: ^App, id: u32) -> bool {
	target := layout.Content{.Web, id}
	for workspace in app.workspaces {
		for &tab in workspace.tabs {
			if layout.find_content(&tab.tree, target) != layout.INVALID_NODE {return true}
		}
	}
	return false
}

// The browser process exited, taking every view and the environment with it. Each pane shows its crash
// state until its Reload makes a new view, and a new environment with it.
@(private = "file")
web_browser_lost :: proc(app: ^App) {
	for pane in app.web_panes {
		if pane.view == nil {continue}
		platform.webview_destroy(pane.view)
		pane.view = nil
		pane.ready, pane.loading, pane.webview_focused = false, false, false
		pane.crashed = .Browser
		pane.find_count, pane.find_index = 0, -1
	}
	if app.web_env != nil {
		platform.webview_env_destroy(app.web_env)
		app.web_env = nil
	}
	mark_all_dirty(app)
}

// Reloads a crashed page; a page whose browser process exited gets a new view.
@(private = "file")
web_recover :: proc(app: ^App, w: ^Window, pane: ^Web_Pane) {
	switch pane.crashed {
	case .None:
		return
	case .Browser:
		if pane.view != nil {
			platform.webview_destroy(pane.view)
			pane.view = nil
		}
		pane.ready, pane.failed = false, false
	case .Renderer, .Unresponsive:
		platform.webview_reload(pane.view)
	}
	pane.crashed = .None
	w.dirty = true
}

@(private = "file")
WEB_PERMISSION_NAMES := [platform.Webview_Permission]string {
	.Unknown                        = "a permission",
	.Microphone                     = "the microphone",
	.Camera                         = "the camera",
	.Geolocation                    = "your location",
	.Notifications                  = "notifications",
	.Other_Sensors                  = "motion sensors",
	.Clipboard_Read                 = "clipboard reading",
	.Multiple_Automatic_Downloads   = "repeated downloads",
	.File_Read_Write                = "file access",
	.Autoplay                       = "autoplay",
	.Local_Fonts                    = "local fonts",
	.Midi_System_Exclusive_Messages = "MIDI devices",
	.Window_Management              = "window management",
	.Persistent_Storage             = "persistent storage",
}

// Reports a download or a blocked permission as a notice.
@(private = "file")
web_note_show :: proc(app: ^App, pane: ^Web_Pane, note: platform.Webview_Note) {
	name := filepath.base(note.text)
	#partial switch note.kind {
	case .Download_Started:
		notify(app, .Info, fmt.tprintf("Downloading %s…", name))
	case .Download_Done:
		notify(app, .Success, fmt.tprintf("Saved %s to %s.", name, filepath.dir(note.text)))
	case .Download_Failed:
		notify(app, .Warning, fmt.tprintf("Could not download %s.", name))
	case .Permission_Denied:
		permission := platform.Webview_Permission(note.detail)
		if note.detail < 0 || note.detail > i32(max(platform.Webview_Permission)) {permission = .Unknown}
		if permission in pane.denied {return}
		pane.denied += {permission}
		host := web_host_from_url(note.text)
		if host == "" {host = "this page"}
		notify(app, .Info, fmt.tprintf("Blocked %s for %s.", WEB_PERMISSION_NAMES[permission], host))
	}
}

// Polls WebView2 state updates and dispatches any queued accelerator shortcuts.
web_events_process :: proc(app: ^App) {
	browser_lost := false
	// Opening a user-triggered popup can append to the pane list and move its storage.
	for i in 0 ..< len(app.web_panes) {
		pane := app.web_panes[i]
		if pane.view == nil {continue}
		snap := platform.webview_poll(pane.view)
		changed := snap.dirty
		if snap.ready != pane.ready {pane.ready = snap.ready; changed = true}
		if snap.failed != pane.failed {pane.failed = snap.failed; changed = true}
		if snap.loading != pane.loading {pane.loading = snap.loading; changed = true}
		if snap.can_back != pane.can_back {pane.can_back = snap.can_back; changed = true}
		if snap.can_forward != pane.can_forward {pane.can_forward = snap.can_forward; changed = true}
		if snap.focused != pane.webview_focused {pane.webview_focused = snap.focused; changed = true}
		if snap.cursor != pane.cursor {pane.cursor = snap.cursor}
		if snap.zoom > 0 && snap.zoom != pane.zoom {pane.zoom = snap.zoom; changed = true}
		if snap.find_count != pane.find_count || snap.find_index != pane.find_index {
			pane.find_count, pane.find_index = snap.find_count, snap.find_index
			changed = true
		}
		if snap.crashed != pane.crashed {
			pane.crashed = snap.crashed
			browser_lost ||= snap.crashed == .Browser
			changed = true
		}
		if snap.url != "" && snap.url != pane.url {
			web_pane_set_url_text(pane, snap.url)
			changed = true
		}
		if snap.dirty && snap.title != pane.title {
			web_pane_set_title_text(pane, snap.title)
		}
		if snap.favicon_serial != pane.favicon_serial {
			pane.favicon_serial = snap.favicon_serial
			_ = web_favicon_set(app, &pane.favicon, snap.favicon)
			changed = true
		}
		if snap.note.kind != .None {
			web_note_show(app, pane, snap.note)
			platform.webview_pop_note(pane.view)
		}
		if snap.new_window_url != "" {
			new_url := strings.clone(snap.new_window_url, context.temp_allocator)
			platform.webview_clear_new_window(pane.view)
			if w := window_find(app, pane.host_window); w != nil {
				_ = web_open_focused(app, w, new_url)
			}
			changed = true
		}
		if changed {
			if w := window_find(app, pane.host_window); w != nil {
				w.dirty = true
				window_update_title(app, w)
			}
		}
	}
	if browser_lost {web_browser_lost(app)}
	if len(app.web_accel_queue) > 0 {
		// Copy out so dispatching a command cannot alias a growing queue.
		pending := make([]Web_Accel_Pending, len(app.web_accel_queue), context.temp_allocator)
		copy(pending, app.web_accel_queue[:])
		clear(&app.web_accel_queue)
		for item in pending {
			w := window_find(app, item.window)
			if w == nil {continue}
			logical := commands.logical_key(item.event.key, item.event.unshifted)
			if item.event.modifiers == {.Control} && logical == .L {
				web_focus_url_bar(app, w)
				continue
			}
			platform.window_reclaim_focus(&app.platform, w.id)
			on_key(app, w, item.event)
			web_page_refocus(app, w)
		}
	}
}

web_tick :: proc(app: ^App) {
	web_events_process(app)
	if len(app.web_panes) == 0 {
		app.web_deadline = {}
		return
	}
	// Overlay dismissal and native reactivation can leave the app HWND holding the keyboard.
	for w in app.windows {if w.focused {web_page_refocus(app, w)}}
	now := clock_now(&app.clock)
	if app.web_deadline != {} && time.tick_diff(now, app.web_deadline) <= 0 {
		for i := len(app.web_panes) - 1; i >= 0; i -= 1 {
			if !web_content_used(app, app.web_panes[i].id) {
				web_pane_destroy(app.web_panes[i])
				ordered_remove(&app.web_panes, i)
			}
		}
		app.web_deadline = len(app.web_panes) > 0 ? time.tick_add(now, WEB_POLL) : {}
	}
}

web_window_moved :: proc(app: ^App, w: ^Window) {
	for pane in app.web_panes {
		if pane.host_window == w.id && pane.view != nil {
			platform.webview_parent_moved(pane.view)
		}
	}
}

web_theme_apply :: proc(app: ^App) {
	scheme := web_color_scheme(app)
	for pane in app.web_panes {
		if pane.view == nil {continue}
		platform.webview_set_color_scheme(pane.view, scheme)
	}
}

// --- Find, through the window's find bar ---

web_find_set :: proc(pane: ^Web_Pane, needle: string, options: search.Options) {
	if needle == "" {pane.find_count, pane.find_index = 0, -1}
	if pane.view == nil || !pane.ready {return}
	// WebView2 matches plain text, so a regular expression is searched for as written.
	pane.find_failed = !platform.webview_find_start(pane.view, needle, options.case_sensitive, false)
}

web_find_select :: proc(pane: ^Web_Pane, up: bool) {
	if pane.view != nil {platform.webview_find_step(pane.view, up)}
}

@(require_results)
web_find_summary :: proc(pane: ^Web_Pane) -> search.Summary {
	if pane.find_failed {return {progress = .Failed, selected = -1, order = .Document_Order}}
	selected := pane.find_index > 0 ? int(pane.find_index) - 1 : -1
	return {progress = .Complete, total = int(pane.find_count), selected = selected, order = .Document_Order}
}

// --- Zoom ---

// Chrome's zoom steps, so the buttons, Ctrl+wheel and Ctrl+= agree on where 100% is.
@(private = "file", rodata)
WEB_ZOOM_STEPS := [?]f64{0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5}

// The zoom one step in from `zoom` (`direction` 1 larger, -1 smaller, 0 back to 100%).
@(require_results)
web_zoom_step :: proc(zoom: f64, direction: int) -> f64 {
	if direction == 0 {return 1}
	if direction > 0 {
		for step in WEB_ZOOM_STEPS {if step > zoom + 0.001 {return step}}
		return WEB_ZOOM_STEPS[len(WEB_ZOOM_STEPS) - 1]
	}
	#reverse for step in WEB_ZOOM_STEPS {if step < zoom - 0.001 {return step}}
	return WEB_ZOOM_STEPS[0]
}

// The font size commands zoom the focused web pane's page instead, as a browser's would.
@(require_results)
web_zoom_focused :: proc(app: ^App, w: ^Window, direction: int) -> bool {
	pane := web_focused_pane(app, w)
	if pane == nil {return false}
	pane.zoom = web_zoom_step(pane.zoom, direction)
	platform.webview_set_zoom(pane.view, pane.zoom)
	w.dirty = true
	return true
}

@(private = "file")
web_zoom_label :: proc(pane: ^Web_Pane) -> string {
	if abs(pane.zoom - 1) < 0.001 {return ""}
	return fmt.tprintf("%d%%", int(math.round(pane.zoom * 100)))
}

// --- Geometry for header, URL navigator bar, and WebView2 body ---

Web_Nav_Layout :: struct {
	bar:           render.Rect,
	back:          render.Rect,
	forward:       render.Rect,
	reload:        render.Rect,
	url_box:       render.Rect,
	zoom:          render.Rect,
	copy_link:     render.Rect,
	open_external: render.Rect,
	shown:         bool,
}

@(private = "file")
web_nav_layout :: proc(w: ^Window, pane: ^Web_Pane, card: layout.Rect) -> Web_Nav_Layout {
	if pane == nil || !pane.nav_bar {return {}}
	header := pane_header_height(w.scale)
	bar_h := math.round(WEB_NAV_HEIGHT * w.scale)
	if card.height < header + bar_h {return {}}
	bar := render.Rect{card.x, card.y + header, card.width, bar_h}
	pad := math.round(WEB_NAV_PAD * w.scale)
	gap := math.round(WEB_NAV_GAP * w.scale)
	btn := math.round(WEB_NAV_BUTTON_SIZE * w.scale)
	by := bar.y + math.round((bar_h - btn) * 0.5)
	x := bar.x + pad
	back := render.Rect{x, by, btn, btn}
	x += btn + gap
	forward := render.Rect{x, by, btn, btn}
	x += btn + gap
	reload := render.Rect{x, by, btn, btn}
	x += btn + gap
	right := bar.x + bar.width - pad - btn
	open_ext := render.Rect{right, by, btn, btn}
	right -= gap + btn
	copy_link := render.Rect{right, by, btn, btn}
	zoom: render.Rect
	if label := web_zoom_label(pane); label != "" {
		width := math.round(ui.text_width(&w.ui_text, label) + 2 * WEB_NAV_PAD * w.scale)
		right -= gap + width
		zoom = {right, by, width, btn}
	}
	url_box := render.Rect{x, by, max(0, right - gap - x), btn}
	return {
		bar = bar,
		back = back,
		forward = forward,
		reload = reload,
		url_box = url_box,
		zoom = zoom,
		copy_link = copy_link,
		open_external = open_ext,
		shown = true,
	}
}

@(private = "file")
web_body_inset :: proc(app: ^App, w: ^Window) -> f32 {
	return max(f32(1), math.round(f32(app.settings.pane.focus_border) * w.scale))
}

@(private = "file")
web_body_rect :: proc(app: ^App, w: ^Window, pane: ^Web_Pane, card: layout.Rect) -> render.Rect {
	top := pane_header_height(w.scale)
	if pane != nil && pane.nav_bar {
		top += math.round(WEB_NAV_HEIGHT * w.scale)
	}
	inset := web_body_inset(app, w)
	return {
		card.x + inset,
		card.y + top,
		max(0, card.width - 2 * inset),
		max(0, card.height - top - inset),
	}
}

// What the body shows while no page is drawn over it, and whether it offers Reload.
@(private = "file")
web_body_message :: proc(app: ^App, pane: ^Web_Pane) -> (message: string, recover: bool) {
	switch {
	case !platform.webview_supported():
		when platform.AIO_HEADLESS {
			return "Web panes are unavailable in headless mode.", false
		} else {
			return "Web panes are off while AIODev runs as administrator. Use Open in default browser above.", false
		}
	case pane.crashed == .Renderer:
		return "This page crashed.", true
	case pane.crashed == .Unresponsive:
		return "This page is not responding.", true
	case pane.crashed == .Browser:
		return "The web view stopped.", true
	case pane.failed || app.web_env_failed:
		return "The WebView2 runtime could not start. Use Open in default browser above.", false
	case pane.url == "":
		return "Type a URL above and press Enter.", false
	case !pane.ready:
		return "Loading web view…", false
	}
	return "", false
}

@(private = "file")
web_recover_rect :: proc(w: ^Window, body: render.Rect) -> render.Rect {
	size := WEB_RELOAD_BUTTON * w.scale
	gap := 12 * w.scale
	return {
		math.round(body.x + (body.width - size.x) * 0.5),
		math.round(body.y + body.height * 0.5 + gap),
		size.x,
		size.y,
	}
}

// --- Drawing (nav bar + status fallback when initializing / unsupported) ---

web_pane_draw :: proc(app: ^App, w: ^Window, pane_rect: layout.Pane_Rect) -> render.Build_Status {
	pane := web_find(app, pane_rect.content.id)
	if pane == nil {return .Ok}
	f := pane_frame(w, pane_rect)
	nav := web_nav_layout(w, pane, pane_rect.rect)
	clip := render.Rect{pane_rect.rect.x, pane_rect.rect.y, pane_rect.rect.width, pane_rect.rect.height}
	if render.push_layer(&w.list, clip, window_pane_radius(app, w)) != .None {return .Ok}
	if nav.shown {
		if result := web_nav_draw(app, w, pane, nav, f.offset); result != .Ok {return result}
	}
	web_loading_draw(app, w, pane, pane_rect.rect, nav)
	body := web_body_rect(app, w, pane, pane_rect.rect)
	message, recover := web_body_message(app, pane)
	if body.width > 0 && body.height > 0 && message != "" {
		text_w := ui.text_width(&w.ui_text, message)
		tx := body.x + max(12 * w.scale, (body.width - text_w) * 0.5)
		ty := body.y + body.height * 0.5 - (recover ? w.ui_text.line_height : 0) + w.ui_text.ascent * 0.5
		if result := ui.draw_text(
			&w.ui_text,
			&w.list,
			message,
			tx,
			ty,
			app.theme.muted,
			max(0, body.width - 24 * w.scale),
		); result != .Ok {return result}
		if recover {
			button := web_recover_rect(w, body)
			if result := ui.text_button_draw(
				&w.list, &w.ui_text, app.theme, button, "Reload", false, w.scale, w.pointer,
			); result != .Ok {return result}
		}
	}
	return .Ok
}

// The loading line: a segment sweeping along the bottom of the URL bar (or the header) while the page
// loads. It asks for frames as the working spinner does, and holds still without system animations.
@(private = "file")
web_loading_draw :: proc(app: ^App, w: ^Window, pane: ^Web_Pane, card: layout.Rect, nav: Web_Nav_Layout) {
	if !pane.loading || pane.crashed != .None {return}
	thickness := math.round(WEB_LOAD_LINE * w.scale)
	track := render.Rect{card.x, card.y + pane_header_height(w.scale) - thickness, card.width, thickness}
	if nav.shown {track.y = nav.bar.y + nav.bar.height - thickness}
	phase := f32(0.5)
	if app.animations {
		w.status_spinning = true
		period := i64(WEB_LOAD_SWEEP)
		phase = f32(f64(w.frame.display._nsec % period) / f64(period))
	}
	segment := track.width * WEB_LOAD_SHARE
	start := track.x - segment + (track.width + segment) * phase
	left, right := max(start, track.x), min(start + segment, track.x + track.width)
	if right > left {
		_ = render.push_rect(&w.list, {rect = {left, track.y, right - left, thickness}, color = app.theme.accent})
	}
}

@(private = "file")
web_alpha :: proc(c: render.Color, a: f32) -> render.Color {
	return {c.r, c.g, c.b, c.a * a}
}

@(private = "file")
web_nav_button_draw :: proc(
	app: ^App,
	w: ^Window,
	rect: render.Rect,
	icon: ui.Icon,
	enabled, hovered, pressed: bool,
) -> render.Build_Status {
	if rect.width < 1 || rect.height < 1 {return .Ok}
	radius := ui.RADIUS_CONTROL * w.scale
	if enabled && (hovered || pressed) {
		fill := pressed ? web_alpha(app.theme.accent, 0.22) : app.theme.hover
		_ = render.push_rect(&w.list, {rect = rect, color = fill, radius = radius})
	}
	ink := enabled ? (hovered ? app.theme.text : app.theme.muted) : web_alpha(app.theme.muted, 0.4)
	ui.icon_draw(&w.list, icon, rect, ink, ui.ICON_BUTTON, w.scale)
	return .Ok
}

@(private = "file")
web_nav_draw :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Web_Pane,
	nav: Web_Nav_Layout,
	offset: [2]f32,
) -> render.Build_Status {
	_ = offset
	// Subtle bar fill and bottom hairline.
	_ = render.push_rect(&w.list, {rect = nav.bar, color = app.theme.pane})
	_ = render.push_rect(
		&w.list,
		{
			rect = {nav.bar.x, nav.bar.y + nav.bar.height - 1, nav.bar.width, 1},
			color = web_alpha(app.theme.border, 0.5),
		},
	)
	_ = web_nav_button_draw(
		app, w, nav.back, .Chevron_Left, pane.can_back,
		pane.nav_hover == .Back, pane.nav_armed == .Back,
	)
	_ = web_nav_button_draw(
		app, w, nav.forward, .Chevron_Right, pane.can_forward,
		pane.nav_hover == .Forward, pane.nav_armed == .Forward,
	)
	reload_icon: ui.Icon = pane.loading ? .Close : .Undo
	_ = web_nav_button_draw(
		app, w, nav.reload, reload_icon, pane.url != "",
		pane.nav_hover == .Reload, pane.nav_armed == .Reload,
	)
	_ = web_nav_button_draw(
		app, w, nav.copy_link, .Link, pane.url != "",
		pane.nav_hover == .Copy_Link, pane.nav_armed == .Copy_Link,
	)
	_ = web_nav_button_draw(
		app, w, nav.open_external, .Launch, pane.url != "",
		pane.nav_hover == .Open_External, pane.nav_armed == .Open_External,
	)
	if label := web_zoom_label(pane); label != "" && nav.zoom.width > 0 {
		hovered, pressed := pane.nav_hover == .Zoom, pane.nav_armed == .Zoom
		radius := ui.RADIUS_CONTROL * w.scale
		if hovered || pressed {
			fill := pressed ? web_alpha(app.theme.accent, 0.22) : app.theme.hover
			_ = render.push_rect(&w.list, {rect = nav.zoom, color = fill, radius = radius})
		}
		width := ui.text_width(&w.ui_text, label)
		baseline := nav.zoom.y + math.round((nav.zoom.height - w.ui_text.line_height) * 0.5) + w.ui_text.ascent
		if result := ui.draw_text(
			&w.ui_text,
			&w.list,
			label,
			nav.zoom.x + (nav.zoom.width - width) * 0.5,
			baseline,
			hovered ? app.theme.text : app.theme.muted,
			nav.zoom.width,
		); result != .Ok {return result}
	}
	if nav.url_box.width > 16 * w.scale {
		focused := pane.url_editing && web_is_focused_pane(w, pane.id) && overlay_kind(app, w) == .None
		radius := ui.RADIUS_CONTROL * w.scale
		box_fill := focused ? app.theme.surface : web_alpha(app.theme.surface, 0.7)
		border := focused ? app.theme.accent : web_alpha(app.theme.border, 0.7)
		_ = render.push_rect(&w.list, {rect = nav.url_box, color = box_fill, radius = radius})
		_ = render.push_rect(&w.list, {rect = nav.url_box, color = border, radius = radius, stroke = 1})
		pad_x := math.round(8 * w.scale)
		avail := max(0, nav.url_box.width - 2 * pad_x)
		half := math.round((nav.url_box.height - w.ui_text.line_height) * 0.5)
		baseline := nav.url_box.y + half + w.ui_text.ascent
		if result := ui.field_draw(
			&pane.url_field,
			&w.list,
			&w.ui_text,
			app.theme,
			nav.url_box.x + pad_x,
			baseline,
			avail,
			focused,
			"Enter URL (Ctrl+L)…",
			focused ? app.theme.text : app.theme.muted,
		); result != .Ok {return result}
	}
	return .Ok
}

// --- DirectComposition levels and split-layer presentation ---

// Starts a frame: whether this window shows any web pane, so build_frame splits its draw list around
// the web views.
web_window_prepare_frame :: proc(w: ^Window) {
	w.web.shown = false
	w.web.split_count = 0
	w.web.group_web = false
	if !platform.webview_supported() {return}
	for pane in w.panes {
		if pane.content.kind == .Web {
			w.web.shown = true
			return
		}
	}
}

web_window_has_visible :: proc(w: ^Window) -> bool {
	return w.web.shown
}

// Starts the next overlay at the end of the draw list. build_frame calls it once the tiled panes and
// chrome are drawn, and web_float_group_end after each floating group that shows a web pane.
web_overlay_split :: proc(w: ^Window) {
	if !w.web.shown || w.web.split_count == WEB_LEVELS_MAX {return}
	w.web.splits[w.web.split_count] = len(w.list.layers)
	w.web.split_count += 1
	_ = render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)})
}

// Notes a floating pane about to draw: a web pane takes the level above the overlay its group's frame
// draws in, so the frame sits under the page and every later float over it.
web_float_pane :: proc(app: ^App, w: ^Window, rect: layout.Pane_Rect) {
	if !w.web.shown || rect.content.kind != .Web {return}
	if pane := web_find(app, rect.content.id); pane != nil {pane.level = i32(w.web.split_count)}
	w.web.group_web = true
}

// Ends a floating group: one that showed a web pane starts a new overlay above it.
web_float_group_end :: proc(w: ^Window) {
	if !w.web.group_web {return}
	w.web.group_web = false
	web_overlay_split(w)
}

@(private = "file")
web_layers_have_content :: proc(list: ^render.Draw_List, from, to: int) -> bool {
	start := clamp(from, 0, len(list.layers))
	stop := clamp(to, start, len(list.layers))
	for layer in list.layers[start:stop] {
		if layer.rect_count > 0 || layer.glyph_count > 0 || layer.image_count > 0 {return true}
	}
	return false
}

// Places every web view, then presents the base swap chain and each overlay: layers before the first
// split go to the window's swap chain under every web view, and overlay i (to the next split) sits
// above web level i.
web_window_present :: proc(app: ^App, w: ^Window, background: render.Color) -> render.Error {
	surface := window_surface(w)
	if !web_window_has_visible(w) {
		if w.web.host != nil {
			web_window_hide_all_visuals(app, w)
			platform.webview_host_overlay_hide(w.web.host, 0)
			platform.webview_host_trim(w.web.host, 1)
			platform.webview_host_commit(w.web.host)
		}
		return render.frame_render(app.device, surface, &w.list, background)
	}
	host := web_host_ensure(app, w)
	if host == nil || w.web.split_count == 0 {
		return render.frame_render(app.device, surface, &w.list, background)
	}
	web_window_sync_visuals(app, w, host)

	total := len(w.list.layers)
	count := w.web.split_count
	base := clamp(w.web.splits[0], 0, total)
	if err := render.frame_render_base(app.device, surface, &w.list, base, background); err != .None {
		return err
	}
	for i in 0 ..< count {
		from := clamp(w.web.splits[i], 0, total)
		to := i + 1 < count ? clamp(w.web.splits[i + 1], from, total) : total
		if !web_layers_have_content(&w.list, from, to) {
			platform.webview_host_overlay_hide(host, i32(i))
			continue
		}
		rtv := platform.webview_host_overlay_begin(host, i32(i), w.width, w.height)
		if rtv == nil {continue}
		if err := render.frame_render_overlay(app.device, rtv, w.width, w.height, &w.list, from, to);
		   err != .None {return err}
		platform.webview_host_overlay_present(host, i32(i))
	}
	platform.webview_host_trim(host, i32(count))
	platform.webview_host_commit(host)
	return render.frame_present(app.device, surface)
}

@(private = "file")
web_window_hide_all_visuals :: proc(app: ^App, w: ^Window) {
	for pane in app.web_panes {
		if pane.host_window == w.id && pane.view != nil {
			platform.webview_set_placement(
				pane.view, w.web.host, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, w.scale,
			)
		}
	}
}

@(private = "file")
web_window_sync_visuals :: proc(app: ^App, w: ^Window, host: platform.Webview_Host) {
	hide_for_overview := workspace_overview_animating(w)
	env_ready := web_env_ensure(app)
	radius := window_pane_radius(app, w)
	animating := pane_motion_animating(w)
	stage, sliding := w.pane_motion.slide.?
	over_chrome := pane_motion_over_chrome(w)
	content_area := window_content_area_in(app, w, w.pane_fill)

	for pane in app.web_panes {
		shown_rect: layout.Pane_Rect
		found := false
		for pr in w.panes {
			if pr.content.kind == .Web && pr.content.id == pane.id {
				shown_rect = pr
				found = true
				break
			}
		}
		if !found {
			if pane.host_window == w.id && pane.view != nil {
				platform.webview_set_placement(
					pane.view, host, false, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, w.scale,
				)
			}
			continue
		}
		pane.host_window = w.id
		if pane.view == nil && env_ready && !pane.failed && pane.crashed == .None {
			pane.view = platform.webview_create(
				app.web_env, host, pane.id, pane.url, web_color_scheme(app), pane.zoom,
			)
		}
		if pane.view == nil {continue}

		f := pane_frame(w, shown_rect)
		vis_body := web_body_rect(app, w, pane, f.shown)
		logical_body := web_body_rect(app, w, pane, shown_rect.rect)
		inset := web_body_inset(app, w)
		// Clip the visual to its own body AND to the slide stage / content area so sliding panes never
		// paint over the Activity panel, tab rail or title bar.
		clip_l, clip_t := f32(0), f32(0)
		clip_r, clip_b := vis_body.width, vis_body.height
		apply_clip :: proc(vis: render.Rect, bound: render.Rect, cl, ct, cr, cb: ^f32) {
			cl^ = max(cl^, bound.x - vis.x)
			ct^ = max(ct^, bound.y - vis.y)
			cr^ = min(cr^, bound.x + bound.width - vis.x)
			cb^ = min(cb^, bound.y + bound.height - vis.y)
		}
		if sliding && animating {
			apply_clip(vis_body, stage, &clip_l, &clip_t, &clip_r, &clip_b)
		} else if !shown_rect.floating && !over_chrome {
			bound := render.Rect{content_area.x, content_area.y, content_area.width, content_area.height}
			apply_clip(vis_body, bound, &clip_l, &clip_t, &clip_r, &clip_b)
		}
		// During 160 ms animated pane motion, keep Chromium's viewport at its settled target size while
		// DirectComposition smoothly clips and positions the visual at full display refresh rate.
		bounds := animating ? logical_body : vis_body
		covered := false
		if raised_key, has_raised := w.pane_motion.raised.?;
		   has_raised && animating && !shown_rect.floating {
			covered = raised_key != pane_motion_key(shown_rect.content)
		}
		visible := !hide_for_overview && !covered && pane.crashed == .None &&
			(clip_r - clip_l) >= 2 && (clip_b - clip_t) >= 2 && pane.url != ""
		inner_radius := max(f32(0), radius - inset)
		rad_bl := clip_l <= 0.5 && clip_b >= vis_body.height - 0.5 ? inner_radius : 0
		rad_br := clip_r >= vis_body.width - 0.5 && clip_b >= vis_body.height - 0.5 ? inner_radius : 0
		platform.webview_set_placement(
			pane.view,
			host,
			visible,
			shown_rect.floating ? pane.level : 0,
			i32(math.round(vis_body.x)),
			i32(math.round(vis_body.y)),
			i32(math.round(vis_body.width)),
			i32(math.round(vis_body.height)),
			clip_l,
			clip_t,
			clip_r,
			clip_b,
			max(1, i32(math.round(bounds.width))),
			max(1, i32(math.round(bounds.height))),
			rad_bl,
			rad_br,
			w.scale,
		)
	}
}

// --- Focus, Pointer, Wheel, and Keyboard Routing ---

@(private = "file")
web_is_focused_pane :: proc(w: ^Window, id: u32) -> bool {
	content, ok := window_focused_content(w)
	return ok && content.kind == .Web && content.id == id
}

web_active :: proc(w: ^Window) -> bool {
	content, ok := window_focused_content(w)
	return ok && content.kind == .Web
}

web_focused_pane :: proc(app: ^App, w: ^Window) -> ^Web_Pane {
	content, ok := window_focused_content(w)
	if !ok || content.kind != .Web {return nil}
	return web_find(app, content.id)
}

web_focus_url_bar :: proc(app: ^App, w: ^Window) {
	pane := web_focused_pane(app, w)
	if pane == nil {return}
	pane.nav_bar = true
	pane.url_editing = true
	ui.field_set(&pane.url_field, pane.url)
	ui.field_select_all(&pane.url_field)
	platform.window_reclaim_focus(&app.platform, w.id)
	w.dirty = true
}

// Gives the keyboard back to the focused page once nothing of the app's still wants keys: a leader
// chord, key sequence or mode, the URL bar, the find bar or an overlay.
@(private = "file")
web_page_refocus :: proc(app: ^App, w: ^Window) {
	pane := web_focused_pane(app, w)
	if pane == nil || pane.url_editing || pane.url == "" || pane.view == nil ||
	   !pane.ready || pane.crashed != .None {return}
	if !w.focused {return}
	if w.bindings.count > 0 || len(w.bindings.modes) > 0 || leader_armed(w) {
		if pane.webview_focused {platform.window_reclaim_focus(&app.platform, w.id)}
		return
	}
	if overlay_kind(app, w) != .None {return}
	if ui.find_has_keyboard(&w.find) || arrange_active(w) {return}
	if pane.webview_focused {return}
	platform.webview_focus(pane.view)
}

web_focus_leave :: proc(app: ^App, w: ^Window, content: layout.Content) {
	if content.kind != .Web {return}
	if pane := web_find(app, content.id); pane != nil {
		if pane.url_editing {
			pane.url_editing = false
			ui.field_set(&pane.url_field, pane.url)
		}
	}
	platform.window_reclaim_focus(&app.platform, w.id)
}

web_focus_enter :: proc(app: ^App, w: ^Window, content: layout.Content) {
	if content.kind != .Web {return}
	pane := web_find(app, content.id)
	if pane == nil {return}
	if pane.url_editing || !w.focused || overlay_kind(app, w) != .None {
		platform.window_reclaim_focus(&app.platform, w.id)
		return
	}
	web_page_refocus(app, w)
}

@(private = "file")
web_pane_at :: proc(app: ^App, w: ^Window, x, y: f32) -> (pane: ^Web_Pane, rect: layout.Pane_Rect, ok: bool) {
	hit, found := layout.hit_test(w.panes[:], x, y)
	if !found || hit.content.kind != .Web {return nil, {}, false}
	if y < pane_body_rect(w, hit).y {return nil, {}, false}
	p := web_find(app, hit.content.id)
	return p, hit, p != nil
}

@(private = "file")
web_nav_hit :: proc(nav: Web_Nav_Layout, x, y: f32) -> Web_Nav_Button {
	if !nav.shown || !render.rect_contains(nav.bar, x, y) {return .None}
	if render.rect_contains(nav.back, x, y) {return .Back}
	if render.rect_contains(nav.forward, x, y) {return .Forward}
	if render.rect_contains(nav.reload, x, y) {return .Reload}
	if render.rect_contains(nav.zoom, x, y) {return .Zoom}
	if render.rect_contains(nav.copy_link, x, y) {return .Copy_Link}
	if render.rect_contains(nav.open_external, x, y) {return .Open_External}
	if render.rect_contains(nav.url_box, x, y) {return .Url}
	return .None
}

// The nav bar button, or the body's Reload on a crashed page, under (x, y).
@(private = "file")
web_button_at :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Web_Pane,
	card: layout.Rect,
	x, y: f32,
) -> Web_Nav_Button {
	if hit := web_nav_hit(web_nav_layout(w, pane, card), x, y); hit != .None {return hit}
	if _, recover := web_body_message(app, pane); recover {
		body := web_body_rect(app, w, pane, card)
		if render.rect_contains(web_recover_rect(w, body), x, y) {return .Recover}
	}
	return .None
}

@(private = "file")
web_button_enabled :: proc(pane: ^Web_Pane, button: Web_Nav_Button) -> bool {
	switch button {
	case .None, .Url:
		return false
	case .Back:
		return pane.can_back
	case .Forward:
		return pane.can_forward
	case .Reload, .Copy_Link, .Open_External:
		return pane.url != ""
	case .Zoom, .Recover:
		return true
	}
	return false
}

web_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	_, _, ok := web_pane_at(app, w, x, y)
	return ok
}

web_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	if owner != .Web_Page {
		web_clear_hover(app, w)
		return
	}
	pane, pr, ok := web_pane_at(app, w, x, y)
	if !ok {
		web_clear_hover(app, w)
		return
	}
	for other in app.web_panes {
		if other != pane && other.nav_hover != .None {
			other.nav_hover = .None
			w.dirty = true
		}
	}
	nav := web_nav_layout(w, pane, pr.rect)
	if pane.url_field.dragging && .Left in e.buttons {
		pad_x := math.round(8 * w.scale)
		avail := max(0, nav.url_box.width - 2 * pad_x)
		start := ui.field_view_start(&pane.url_field, &w.ui_text, avail)
		at := ui.field_offset_at(&pane.url_field, &w.ui_text, start, nav.url_box.x + pad_x, x)
		if ui.field_pointer(&pane.url_field, at, false, true) != .None {w.dirty = true}
		pointer_set(app, w, .Text)
		return
	}
	hit := web_button_at(app, w, pane, pr.rect, x, y)
	if pane.nav_hover != hit {
		pane.nav_hover = hit
		w.dirty = true
	}
	if hit != .None || (nav.shown && render.rect_contains(nav.bar, x, y)) {
		shape: platform.Cursor_Shape = .Arrow
		if hit == .Url {
			shape = .Text
		} else if web_button_enabled(pane, hit) {
			shape = .Hand
		}
		pointer_set(app, w, shape)
		return
	}
	body := web_body_rect(app, w, pane, pr.rect)
	if pane.view != nil && pane.ready && pane.crashed == .None && render.rect_contains(body, x, y) {
		lx := i32(math.round(x - body.x))
		ly := i32(math.round(y - body.y))
		platform.webview_mouse(pane.view, .Move, e.buttons, e.modifiers, 0, lx, ly)
		pointer_set(app, w, pane.cursor)
	} else {
		pointer_set(app, w, .Arrow)
	}
}

web_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	x, y := f32(e.x), f32(e.y)
	pane, pr, ok := web_pane_at(app, w, x, y)
	if !ok {return}
	pane_focus(app, w, pr.node)
	nav := web_nav_layout(w, pane, pr.rect)
	hit := web_button_at(app, w, pane, pr.rect, x, y)
	if hit != .None || (nav.shown && render.rect_contains(nav.bar, x, y)) {
		if e.button == .Right {
			if hit == .Url {edit_menu_open_web_url(app, w, pane.id, x, y)}
			return
		}
		if e.button != .Left {return}
		pane.nav_armed = hit
		if hit == .Url {
			was_editing := pane.url_editing
			pane.url_editing = true
			platform.window_reclaim_focus(&app.platform, w.id)
			if !was_editing {
				// The first click selects the address; it still counts, so a double click selects a word.
				_ = click_mark_press(&pane.url_field.clicks, x, e.time_ns, false)
				ui.field_select_all(&pane.url_field)
			} else {
				pad_x := math.round(8 * w.scale)
				avail := max(0, nav.url_box.width - 2 * pad_x)
				start := ui.field_view_start(&pane.url_field, &w.ui_text, avail)
				at := ui.field_offset_at(&pane.url_field, &w.ui_text, start, nav.url_box.x + pad_x, x)
				_ = field_press(&pane.url_field, at, x, .Shift in e.modifiers, e.time_ns)
			}
		} else {
			pane.url_editing = false
			platform.window_reclaim_focus(&app.platform, w.id)
		}
		w.dirty = true
		return
	}
	if pane.url_editing {
		pane.url_editing = false
		ui.field_set(&pane.url_field, pane.url)
		w.dirty = true
	}
	body := web_body_rect(app, w, pane, pr.rect)
	if pane.view == nil || !pane.ready || pane.crashed != .None || !render.rect_contains(body, x, y) {return}
	web_page_refocus(app, w)
	lx := i32(math.round(x - body.x))
	ly := i32(math.round(y - body.y))
	kind: platform.Webview_Mouse_Kind
	switch e.button {
	case .Left:
		double := e.time_ns > pane.last_click_ns &&
			e.time_ns - pane.last_click_ns <= DOUBLE_CLICK_NS &&
			abs(lx - pane.last_click_pos.x) <= 4 &&
			abs(ly - pane.last_click_pos.y) <= 4
		kind = double ? .Left_Button_Double : .Left_Button_Down
		pane.last_click_ns = double ? 0 : e.time_ns
		pane.last_click_pos = {lx, ly}
	case .Right:
		kind = .Right_Button_Down
	case .Middle:
		kind = .Middle_Button_Down
	case .Back:
		platform.webview_go_back(pane.view)
		return
	case .Forward:
		platform.webview_go_forward(pane.view)
		return
	}
	platform.webview_mouse(pane.view, kind, {e.button}, e.modifiers, 0, lx, ly)
}

// Runs a nav bar or body button released over the button it was pressed on.
@(private = "file")
web_button_run :: proc(app: ^App, w: ^Window, pane: ^Web_Pane, button: Web_Nav_Button) {
	if !web_button_enabled(pane, button) {return}
	switch button {
	case .None, .Url:
	case .Back:
		platform.webview_go_back(pane.view)
	case .Forward:
		platform.webview_go_forward(pane.view)
	case .Reload:
		if pane.loading {platform.webview_stop(pane.view)} else {platform.webview_reload(pane.view)}
	case .Zoom:
		pane.zoom = 1
		platform.webview_set_zoom(pane.view, 1)
	case .Copy_Link:
		_ = clipboard_copy(app, pane.url)
	case .Open_External:
		if !target_open_url(app, pane.url) {
			notify(app, .Error, "Could not open the link in the default browser.")
		}
	case .Recover:
		web_recover(app, w, pane)
	}
}

web_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	x, y := f32(e.x), f32(e.y)
	pane := web_focused_pane(app, w)
	if pane == nil {return true}
	pr: layout.Pane_Rect
	found := false
	for item in w.panes {
		if item.content.kind == .Web && item.content.id == pane.id {
			pr, found = item, true
			break
		}
	}
	if !found {pane.nav_armed = .None; return true}
	if pane.url_field.dragging {
		_ = ui.field_release(&pane.url_field)
		pane.nav_armed = .None
		return true
	}
	if pane.nav_armed != .None {
		armed := pane.nav_armed
		pane.nav_armed = .None
		if e.button == .Left && web_button_at(app, w, pane, pr.rect, x, y) == armed {
			web_button_run(app, w, pane, armed)
		}
		w.dirty = true
		return true
	}
	body := web_body_rect(app, w, pane, pr.rect)
	if pane.view != nil && pane.ready && pane.crashed == .None {
		lx := i32(math.round(x - body.x))
		ly := i32(math.round(y - body.y))
		kind: platform.Webview_Mouse_Kind
		#partial switch e.button {
		case .Left: kind = .Left_Button_Up
		case .Right: kind = .Right_Button_Up
		case .Middle: kind = .Middle_Button_Up
		case: return true
		}
		platform.webview_mouse(pane.view, kind, {}, e.modifiers, 0, lx, ly)
	}
	return true
}

web_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	pane, pr, ok := web_pane_at(app, w, x, y)
	if !ok {return ""}
	switch web_button_at(app, w, pane, pr.rect, x, y) {
	case .Back: return "Back"
	case .Forward: return "Forward"
	case .Reload: return pane.loading ? "Stop loading" : "Reload"
	case .Zoom: return "Reset zoom"
	case .Copy_Link: return "Copy link"
	case .Open_External: return "Open in default browser"
	case .None, .Url, .Recover:
	}
	return ""
}

web_cancel :: proc(app: ^App, w: ^Window) {
	for pane in app.web_panes {
		pane.nav_armed = .None
		pane.nav_hover = .None
	}
	w.dirty = true
}

web_leave :: proc(app: ^App, w: ^Window) {
	web_clear_hover(app, w)
}

@(private = "file")
web_clear_hover :: proc(app: ^App, w: ^Window) {
	for pane in app.web_panes {
		if pane.nav_hover != .None {
			pane.nav_hover = .None
			w.dirty = true
		}
		if pane.host_window == w.id && pane.view != nil && pane.ready {
			platform.webview_mouse(pane.view, .Leave, {}, {}, 0, 0, 0)
		}
	}
}

web_wheel :: proc(app: ^App, w: ^Window, e: input.Mouse_Wheel_Event) -> bool {
	x, y := f32(e.x), f32(e.y)
	pane, pr, ok := web_pane_at(app, w, x, y)
	if !ok {return false}
	body := web_body_rect(app, w, pane, pr.rect)
	if !render.rect_contains(body, x, y) {return true}
	if pane.view == nil || !pane.ready || pane.crashed != .None {return true}
	lx := i32(math.round(x - body.x))
	ly := i32(math.round(y - body.y))
	if e.delta_y != 0 {
		delta := u32(i32(math.round(e.delta_y * 120)))
		platform.webview_mouse(pane.view, .Wheel, {}, e.modifiers, delta, lx, ly)
	}
	if e.delta_x != 0 {
		delta := u32(i32(math.round(e.delta_x * 120)))
		platform.webview_mouse(pane.view, .Horizontal_Wheel, {}, e.modifiers, delta, lx, ly)
	}
	return true
}

// Keys reach here while the app's window, not the page, has the keyboard: the URL bar or find bar is
// focused, or a key the page passed up (a shortcut, the leader) is being resolved.
web_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	pane := web_focused_pane(app, w)
	if pane == nil {return}
	key, consumed := content_key_prelude(app, w, e, true)
	if consumed {
		web_page_refocus(app, w)
		return
	}
	if !e.pressed {return}
	has_find := ui.find_has_keyboard(&w.find)
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	if modifiers == {.Control} && key.logical.key == .L {
		key_suppress(w, e)
		web_focus_url_bar(app, w)
		return
	}
	if !has_find && modifiers == {.Control} && key.logical.key == .F {
		key_suppress(w, e)
		pane_header_cancel(w)
		find_toggle(app, w, pane)
		return
	}
	if pane.url_editing && !has_find {
		if e.key == .Escape {
			key_suppress(w, e)
			pane.url_editing = false
			ui.field_set(&pane.url_field, pane.url)
			web_page_refocus(app, w)
			w.dirty = true
			return
		}
		if e.key == .Enter || e.key == .Numpad_Enter {
			key_suppress(w, e)
			raw := ui.field_string(&pane.url_field)
			if normalized, valid := links.normalize_web_input(raw); valid {
				pane.url_editing = false
				web_pane_set_url_text(pane, normalized)
				if pane.view != nil {
					platform.webview_navigate(pane.view, normalized)
					web_page_refocus(app, w)
				}
			} else {
				notify(app, .Warning, "Enter an HTTP, HTTPS, or local file:/// address.")
			}
			w.dirty = true
			return
		}
		edit := field_edit_key(app, &pane.url_field, e)
		if edit.change != .None || edit.pasted {
			key_suppress(w, e)
			w.dirty = true
			return
		}
	}
	if key.found && (key.runtime || action_available(app, w, key.action)) {
		key_suppress(w, e)
		run_window_command(app, w, key.command, .Key)
		web_page_refocus(app, w)
		return
	}
	if has_find {
		find_bar_key(app, w, e, key.logical)
		return
	}
	web_page_refocus(app, w)
}

web_text :: proc(app: ^App, w: ^Window, text: string) {
	pane := web_focused_pane(app, w)
	if pane == nil || !pane.url_editing {return}
	ui.field_text(&pane.url_field, text)
	w.dirty = true
}
