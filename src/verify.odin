package main

import "aio:commands"
import "aio:control"
import "aio:input"
import "aio:layout"
import "aio:perf"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "aio:verify_protocol"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// These imports are used only when AIO_CONTROL is set.
_ :: fmt
_ :: log
_ :: math
_ :: os
_ :: strings
_ :: utf8
_ :: commands
_ :: control
_ :: layout
_ :: input
_ :: perf
_ :: platform
_ :: render
_ :: term
_ :: ui
_ :: verify_protocol
_ :: settings

AIO_CONTROL :: #config(AIO_CONTROL, false)

when AIO_CONTROL {
	// The state keys a drive's reply names when they change, in reply order. A key with words reports
	// a change to true or false in them; any other key reports key=value.
	Changed_Key :: struct {
		key:                       string,
		became_true, became_false: string,
	}

	CHANGED_KEYS :: [?]Changed_Key {
		{key = "window.visible", became_true = "window shown", became_false = "window hidden"},
		{key = "windows.count"},
		{key = "window.id"},
		{key = "window.origin"},
		{key = "window.size"},
		{key = "window.dpi"},
		{key = "window.focused"},
		{key = "grid.size"},
		{key = "palette.open", became_true = "palette opened", became_false = "palette closed"},
		{key = "palette.query"},
		{key = "palette.item"},
		{key = "palette.selected"},
		{key = "find.open", became_true = "find opened", became_false = "find closed"},
		{key = "find.query"},
		{key = "find.matches"},
		{key = "session.viewport"},
		{key = "session.selection"},
	}

	// Server-side timings. A read or drive waits this long for the window to present before it starts.
	GATE_TIMEOUT_MS :: 5000
	// A drive answers once the focused content has been quiet DRIVE_IDLE_MS, or at DRIVE_TIMEOUT_MS.
	DRIVE_IDLE_MS :: 50
	DRIVE_TIMEOUT_MS :: 1000
	// A resize may report only once the grid follows, which takes longer than the frame.
	RESIZE_TIMEOUT_MS :: 5000
	// The slowest fixed-budget drive, a gated resize, answers before a client stops waiting.
	#assert(GATE_TIMEOUT_MS + RESIZE_TIMEOUT_MS < verify_protocol.CLIENT_TIMEOUT_MS)
	// A quit's answer has this long to reach the client, checked every QUIT_POLL, before the app exits.
	QUIT_DRAIN :: time.Second
	QUIT_POLL :: 10 * time.Millisecond
	// A mouse drag moves in this many even steps, one nanosecond apart, and releases a nanosecond later.
	MOUSE_DRAG_STEPS :: 4

	Verify :: struct {
		server: ^control.Server,
		request: Verify_Request,
		// When the focused pane's content last changed, or the last drive began.
		changed: time.Tick,
		// state's frames.presented: swap-chain presents of the verified window, from DXGI statistics.
		// perf's frames.presented is perf.Stats.presented, successful frame_render calls of every
		// window; both keys keep their published meaning, and this is the one place stating it.
		generation, frames: u64,
		pointer_updates: u64,
		session_id: u32,
		presented: bool,
		presents: [dynamic]Verify_Present,
		mouse_window: input.Window_Id,
		target_window: input.Window_Id,
		buttons: input.Mouse_Buttons,
	}

	Verify_Present :: struct {
		id: input.Window_Id,
		surface: ^render.Surface,
		count: u32,
	}

	// The control request in flight; nil is idle. Only the procs from verify_accept to verify_end
	// write it. A read or the start of a drive finishes in the tick it begins, so neither is a state.
	Verify_Request :: union {
		Verify_Gate,
		Verify_Wait,
		Verify_Drive,
		Verify_Quitting,
	}

	// A polled control message and the request parsed from its arguments, which the request
	// borrows. The state holding it destroys both.
	Verify_Message :: struct {
		transport: ^control.Message,
		request: verify_protocol.Request,
	}

	// A read or drive held until the window has presented what it last drew, so it never sees a
	// stale frame.
	Verify_Gate :: struct {
		message: Verify_Message,
		then: Verify_Gated,
		started: time.Tick,
		request_frame: u64,
		// The window had a frame to draw when the request arrived.
		needs_frame: bool,
	}

	Verify_Gated :: enum {
		Read,
		Drive,
	}

	Verify_Wait :: struct {
		message: Verify_Message,
		started: time.Tick,
		request_frame: u64,
	}

	// A drive has happened; its reply waits for the window to settle, then reports what changed.
	Verify_Drive :: struct {
		message: Verify_Message,
		started: time.Tick,
		request_frame: u64,
		before: term.Snapshot,
		before_state: []verify_protocol.State_Entry,
	}

	// The reply to the request that quit has been sent; the app's quit is held until it is delivered.
	Verify_Quitting :: struct {
		id: u64,
		started: time.Tick,
	}

	Verify_Action :: enum {
		Read,
		Wait,
		Drive,
		Quit,
	}

	// Every request type names its action, so a new one cannot silently become a drive.
	verify_action :: proc(request: verify_protocol.Request) -> (action: Verify_Action) {
		switch r in request {
		case nil:
			action = .Read
		case verify_protocol.Ping,
		     verify_protocol.Screen,
		     verify_protocol.Cells,
		     verify_protocol.State,
		     verify_protocol.Expect,
		     verify_protocol.Help,
		     verify_protocol.Capture,
		     verify_protocol.Pixels,
		     verify_protocol.Diff,
		     verify_protocol.Draws,
		     verify_protocol.Perf,
		     verify_protocol.Vt:
			action = .Read
		case verify_protocol.Wait:
			action = .Wait
		case verify_protocol.Tray:
			action = r.action == .Quit ? .Quit : .Drive
		case verify_protocol.Type,
		     verify_protocol.Key,
		     verify_protocol.Run,
		     verify_protocol.Mouse,
		     verify_protocol.Focus,
		     verify_protocol.Resize,
		     verify_protocol.Dpi,
		     verify_protocol.Command,
		     verify_protocol.Window_Select,
		     verify_protocol.Window_Move:
			action = .Drive
		}
		return
	}

	verify_start :: proc(app: ^App) {
		name, err := control.pipe_name(app.app_id, context.temp_allocator)
		if err == .None {
			app.verify.server, err = control.create(name, {wake_platform, &app.platform})
		}
		if err != .None {
			log.errorf("starting the control channel failed: %v", err)
			notify(
				app,
				.Error,
				"Could not start the control channel; check the log and restart this instance.",
			)
		}
		app.verify.changed = time.tick_now()
	}

	verify_destroy :: proc(app: ^App) {
		v := &app.verify
		control.destroy(v.server)
		verify_end(v)
		delete(v.presents)
		v^ = {}
	}

	verify_window :: proc(app: ^App) -> ^Window {
		if app.verify.target_window != 0 {
			if w := window_find(app, app.verify.target_window); w != nil {
				// A hidden linked window presents no frames, so it cannot answer; the selection waits.
				if w.phase != .Hidden {return w}
			} else {
				app.verify.target_window = 0
				app.verify.mouse_window, app.verify.buttons = 0, {}
			}
		}
		for w in app.windows {
			if w.focused {return w}
		}
		return window_primary(app)
	}

	// Counts the swap-chain presents of a window just rendered. A window whose count has not advanced
	// is drawn again, so a gated reply can prove a presented frame once DXGI statistics catch up; this
	// redraw is harness-build cadence only.
	verify_presented :: proc(app: ^App, w: ^Window) {
		surface := window_surface(w)
		if surface == nil {return}
		count, err := render.surface_present_count(surface)
		if err != .None {
			log.errorf("reading the present count failed: %v", err)
			return
		}
		v := &app.verify
		for i := len(v.presents) - 1; i >= 0; i -= 1 {
			if window_find(app, v.presents[i].id) == nil {ordered_remove(&v.presents, i)}
		}
		for &p in v.presents {
			if p.id != w.id {continue}
			previous := p.surface == surface ? p.count : 0
			if count == previous {w.dirty = true}
			if verify_window(app) == w {
				v.presented ||= count != previous
				v.frames += u64(count >= previous ? count - previous : count)
			}
			p.surface, p.count = surface, count
			return
		}
		if _, err := append(&v.presents, Verify_Present{w.id, surface, count}); err != nil {
			log.error("recording the presented frame failed: out of memory")
			return
		}
		if verify_window(app) == w {
			v.frames += u64(count)
			v.presented ||= count > 0
		}
		if count == 0 {w.dirty = true}
	}

	verify_deadline :: proc(app: ^App) -> (time.Tick, bool) {
		v := &app.verify
		now := time.tick_now()
		started: time.Tick
		timeout_ms, idle_ms := 0, -1
		switch s in v.request {
		case nil:
			return {}, false
		case Verify_Quitting:
			return time.tick_add(now, QUIT_POLL), true
		case Verify_Gate:
			started, timeout_ms = s.started, verify_timeout(s.message.request)
		case Verify_Wait:
			r := s.message.request.(verify_protocol.Wait)
			started, timeout_ms = s.started, r.timeout_ms
			if r.kind == .Idle {idle_ms = r.idle_ms}
		case Verify_Drive:
			started = s.started
			idle_ms, timeout_ms = verify_drive_limits(s.message.request)
			if _, resize := s.message.request.(verify_protocol.Resize); resize {timeout_ms = RESIZE_TIMEOUT_MS}
		}
		for w in app.windows {
			if w.dirty && window_drawable(w) {return now, true}
		}
		deadline := time.tick_add(started, time.Duration(timeout_ms) * time.Millisecond)
		if idle_ms >= 0 {
			idle := time.tick_add(v.changed, time.Duration(idle_ms) * time.Millisecond)
			if time.tick_diff(now, idle) > 0 &&
			   time.tick_diff(idle, deadline) > 0 {deadline = idle}
		}
		return deadline, true
	}

	@(require_results)
	verify_snapshot :: proc(
		app: ^App,
		persistent: bool = false,
	) -> (
		term.Snapshot,
		verify_protocol.Error,
	) {
		w := verify_window(app)
		if w == nil {return {}, .Invalid_Argument}
		entry := focused_session(app, w)
		if entry == nil {return {}, .Invalid_Argument}
		if pane := pane_view(w, {.Terminal, entry.id}); pane != nil {
			allocator := persistent ? context.allocator : context.temp_allocator
			snapshot, err := term.snapshot(pane.view.state, allocator)
			if err != .None {
				return {}, err == .Out_Of_Memory ? .Out_Of_Memory : .System
			}
			return snapshot, .None
		}
		return {}, .Invalid_Argument
	}

	verify_value :: proc(entries: []verify_protocol.State_Entry, key: string) -> string {
		for entry in entries {
			if entry.key == key {return entry.value}
		}
		return ""
	}

	// How long a read or drive waits for the window to present a frame before it starts.
	verify_timeout :: proc(request: verify_protocol.Request) -> int {
		if r, run := request.(verify_protocol.Run); run {return r.timeout_ms}
		return GATE_TIMEOUT_MS
	}

	// How long after a drive the content must be quiet, and the longest a drive waits for it.
	verify_drive_limits :: proc(request: verify_protocol.Request) -> (idle_ms, timeout_ms: int) {
		if r, run := request.(verify_protocol.Run); run {return r.idle_ms, r.timeout_ms}
		return DRIVE_IDLE_MS, DRIVE_TIMEOUT_MS
	}

	verify_needs_window :: proc(request: verify_protocol.Request) -> bool {
		#partial switch r in request {
		case verify_protocol.Ping, verify_protocol.Help, verify_protocol.State, verify_protocol.Perf:
			return false
		case verify_protocol.Tray:
			return r.action == .Hide
		case verify_protocol.Expect:
			return r.kind != .State
		}
		return true
	}

	verify_notice_key :: proc(key: u32) -> string {
		if key <= u32(max(Notice_Key)) {
			return strings.to_lower(fmt.tprintf("%v", Notice_Key(key)), context.temp_allocator)
		}
		return fmt.tprintf("%d", key)
	}

	// Where every report writes the verification state: key=value entries in the order written. Each
	// feature's report sits beside its state; the first failure is kept and later writes are dropped.
	State_Report :: struct {
		entries: [dynamic]verify_protocol.State_Entry,
		error:   verify_protocol.Error,
	}

	state_text :: proc(r: ^State_Report, key, value: string) {
		if r.error != .None {return}
		if _, err := append(&r.entries, verify_protocol.State_Entry{key, value}); err != nil {
			r.error = .Out_Of_Memory
		}
	}

	// A boolean, integer or enum name as fmt's %v writes it.
	state_value :: proc(r: ^State_Report, key: string, value: any) {
		state_text(r, key, fmt.tprintf("%v", value))
	}

	state_valuef :: proc(r: ^State_Report, key, format: string, args: ..any) {
		state_text(r, key, fmt.tprintf(format, ..args))
	}

	// An enum or other name, in lower case.
	state_word :: proc(r: ^State_Report, key: string, value: any) {
		state_text(r, key, strings.to_lower(fmt.tprintf("%v", value), context.temp_allocator))
	}

	state_rect :: proc(r: ^State_Report, key: string, rect: render.Rect) {
		state_valuef(r, key, "%g,%g,%g,%g", rect.x, rect.y, rect.width, rect.height)
	}

	// A key carrying an index or name, such as rail.row.2.title.
	state_key :: proc(format: string, args: ..any) -> string {
		return fmt.tprintf(format, ..args)
	}

	state_fail :: proc(r: ^State_Report, err: verify_protocol.Error) {
		if r.error == .None {r.error = err}
	}

	// The state every reply reads, one group per owner. Reading it changes nothing.
	@(require_results)
	verify_state :: proc(app: ^App) -> ([]verify_protocol.State_Entry, verify_protocol.Error) {
		r := State_Report {
			entries = make([dynamic]verify_protocol.State_Entry, context.temp_allocator),
		}
		w := verify_window(app)
		verify_app_report(&r, app)
		palette_state_report(&r, app, w)
		entry: ^Session_Entry
		if w != nil {
			entry = focused_session(app, w)
			verify_window_report(&r, app, w, entry)
			markdown_state_report(&r, app, w)
			settings_page_state_report(&r, app, w)
			rename_state_report(&r, w)
			tab_menu_state_report(&r, w)
			confirmation_state_report(&r, app, w)
			tab_strip_state_report(&r, app, w)
			rail_state_report(&r, w)
			status_panel_state_report(&r, app, w)
			divider_state_report(&r, w)
			title_state_report(&r, app, w)
			workspace_picker_state_report(&r, app, w)
			link_state_report(&r, w)
			profile_menu_state_report(&r, w)
			document_menu_state_report(&r, w)
			find_bar_state_report(&r, app, w)
		} else {
			state_text(&r, "window.id", "0")
			state_text(&r, "window.origin", "0,0")
			state_text(&r, "window.workspace_index", "0")
			state_text(&r, "window.size", "0x0")
			state_text(&r, "window.dpi", "0")
			state_text(&r, "window.scale", "0")
			state_text(&r, "window.focused", "false")
			if len(app.workspaces) > 0 {
				if tab := selected_tab(app.workspaces[0]); tab != nil {
					pane := tab.tree.nodes[tab.tree.focus].(layout.Pane)
					entry = workspace_session_for_content(app, pane.content)
				}
			}
		}
		verify_tabs_report(&r, app, w)
		if w != nil {
			verify_panes_report(&r, app, w)
			floating_state_report(&r, w)
			drag_state_report(&r, w)
		}
		if entry != nil {verify_session_report(&r, app, w, entry)}
		verify_notices_report(&r, app)
		return r.entries[:], r.error
	}

	// The application's identity, the settings it shows and its window inventory. App and Window
	// compose the features, so these keys belong to no feature.
	verify_app_report :: proc(r: ^State_Report, app: ^App) {
		state_value(r, "app.pid", os.get_pid())
		state_text(r, "app.app", app.app_id)
		state_text(r, "app.build", AIO_BUILD_ID)
		state_text(r, "app.build_kind", AIO_BUILD_KIND)
		state_text(r, "app.data", app.options.data_dir == "" ? "default" : app.options.data_dir)
		state_text(r, "app.settings", app.settings_path)
		state_text(r, "app.log", app.log_path)
		state_value(r, "window.visible", !app_tray_only(app))
		state_value(r, "windows.count", len(app.windows))
		state_value(r, "frames.presented", app.verify.frames)
		state_text(r, "theme.name", settings.value_text(&app.settings, settings.schema_find("theme.name")^))
		state_text(r, "terminal.foreground", settings.color_hex(app.settings.colors.foreground))
		state_text(r, "terminal.background", settings.color_hex(app.settings.colors.background))
		state_value(r, "ui.animations", app.animations)
		state_valuef(r, "ui.font_points", "%g", app.settings.interface.font_size)
		state_text(r, "ui.font_family", app.settings.interface.font_family)
		state_text(r, "terminal.font_family", app.settings.font.family)
		state_value(r, "shell.icon.loaded", app.shell_icon.width > 0)
		state_value(r, "ui.animating", motion_active(app))
		state_value(r, "leader.enabled", app.leader != nil)
		state_value(r, "workspaces.count", len(app.workspaces))
		for window, i in app.windows {
			n := i + 1
			x, y, err := platform.window_to_screen(&app.platform, window.id, 0, 0)
			if err != .None {state_fail(r, .System); return}
			state_value(r, state_key("window.%d.id", n), window.id)
			state_valuef(r, state_key("window.%d.origin", n), "%d,%d", x, y)
			state_valuef(r, state_key("window.%d.size", n), "%dx%d", window.width, window.height)
			state_value(r, state_key("window.%d.workspace_index", n), verify_workspace_index(app, window))
			state_value(r, state_key("window.%d.preparing", n), window.phase == .Preparing)
			state_value(r, state_key("window.%d.linked", n), window_linked(window))
			state_value(r, state_key("window.%d.link_shown", n), window_linked(window) && window.phase == .Shown)
		}
	}

	// The verified window's own keys: placement, scale, focus, pointer and grid metrics.
	verify_window_report :: proc(r: ^State_Report, app: ^App, w: ^Window, entry: ^Session_Entry) {
		x, y, err := platform.window_to_screen(&app.platform, w.id, 0, 0)
		if err != .None {state_fail(r, .System); return}
		state_value(r, "window.id", w.id)
		state_valuef(r, "window.origin", "%d,%d", x, y)
		state_valuef(r, "window.pointer", "%g,%g", w.pointer.x, w.pointer.y)
		state_valuef(r, "theme.hover_lift", "%g", app.theme.hover_lift)
		state_valuef(r, "theme.hover_gloss", "%g", app.theme.hover_gloss)
		state_value(r, "window.workspace_index", verify_workspace_index(app, w))
		state_word(r, "overlay", overlay_kind(app, w))
		state_value(r, "leader.pending", leader_armed(w))
		state_text(r, "leader.indicator", leader_armed(w) ? "pane-status-line" : "none")
		state_valuef(r, "window.size", "%dx%d", w.width, w.height)
		state_value(r, "window.dpi", u32(w.scale * 96))
		state_valuef(r, "window.scale", "%g", w.scale)
		state_value(r, "window.focused", w.focused)
		state_value(r, "window.maximized", w.maximized)
		state_value(r, "window.pane_view", pane_view_current(w))
		state_value(r, "window.preparing", w.phase == .Preparing)
		state_word(r, "pointer.shape", w.pointer_shape)
		state_value(r, "pointer.updates", app.verify.pointer_updates)
		state_valuef(r, "grid.cell", "%gx%g", w.metrics.cell_width, w.metrics.cell_height)
		state_valuef(r, "grid.padding", "%g", pane_padding(app, w.scale, entry))
		process := entry != nil ? string(entry.process_name[:entry.process_name_length]) : ""
		state_text(r, "session.process", process)
	}

	// The shown workspace's tabs, or the first workspace's while every window is hidden.
	verify_tabs_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		empty: Workspace
		workspace := &empty
		if w != nil {
			workspace = w.workspace
		} else if len(app.workspaces) > 0 {
			workspace = app.workspaces[0]
		}
		state_value(r, "tabs.count", len(workspace.tabs))
		state_value(r, "tabs.selected", len(workspace.tabs) == 0 ? 0 : workspace.selected + 1)
		state_value(r, "sessions.count", len(app.sessions))
		for tab, i in workspace.tabs {
			n := i + 1
			row_index := -1
			row_rect, close_rect, strip_rect, strip_close: render.Rect
			position := f32(i)
			if w != nil {
				row_index, row_rect, close_rect = rail_tab_report_rects(w, i)
				position = tab_position(w, i)
				strip_rect = window_tab_rect(app, w, i)
				strip_close = window_tab_close_rect(app, w, i)
			}
			state_value(r, state_key("tab.%d.id", n), tab.id)
			state_value(r, state_key("tab.%d.marked", n), tab.marked)
			state_valuef(r, state_key("tab.%d.position", n), "%g", position)
			state_value(r, state_key("tab.%d.rail_row", n), row_index)
			state_rect(r, state_key("tab.%d.rect", n), row_rect)
			state_rect(r, state_key("tab.%d.close", n), close_rect)
			state_rect(r, state_key("tab.%d.strip_rect", n), strip_rect)
			state_rect(r, state_key("tab.%d.strip_close", n), strip_close)
			state_value(r, state_key("tab.%d.focus", n), tab.tree.focus)
			state_text(r, state_key("tab.%d.title", n), tab.title)
			state_value(r, state_key("tab.%d.zoomed", n), tab.tree.zoomed)
			count := 0
			for node, id in tab.tree.nodes {
				pane, ok := node.(layout.Pane)
				if !ok {continue}
				count += 1
				if session := workspace_session_for_content(app, pane.content); session != nil {
					g := term.geometry(session.session)
					state_valuef(r, state_key("tab.%d.pane.%d.grid", n, id), "%dx%d", g.columns, g.rows)
					state_value(r, state_key("tab.%d.pane.%d.keep_open", n, id), session.keep_open)
				}
				state_value(r, state_key("tab.%d.pane.%d.session", n, id), pane.content.id)
				if floating, floated := layout.float_of(&tab.tree, layout.Node_Id(id)); floated {
					b := floating.bounds
					float_key := state_key("tab.%d.pane.%d.float", n, id)
					state_valuef(r, float_key, "%g,%g,%g,%g", b.x, b.y, b.width, b.height)
					state_value(r, state_key("tab.%d.pane.%d.minimized", n, id), floating.minimized)
				}
			}
			shown_floats, minimized_floats := layout.float_counts(&tab.tree)
			state_value(r, state_key("tab.%d.panes", n), count)
			state_value(r, state_key("tab.%d.floating", n), shown_floats)
			state_value(r, state_key("tab.%d.minimized", n), minimized_floats)
		}
	}

	// The verified window's tiled panes and the views it keeps.
	verify_panes_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		state_value(r, "panes.count", len(window_tiled_rects(w)))
		state_value(r, "panes.focused", window_tree(w).focus)
		state_valuef(r, "panes.gap", "%g", window_gap(app, w))
		state_valuef(r, "panes.header_height", "%g", w.header_height)
		state_value(r, "panes.split_overlay", w.split_overlay)
		for view in w.views {
			if !pane_owns_session(view.content.kind) {continue}
			state_value(r, state_key("session.%d.builds", view.content.id), view.builds)
		}
		for pane in w.panes {
			p := pane.rect
			state_valuef(r, state_key("pane.%d.rect", pane.node), "%g,%g,%g,%g", p.x, p.y, p.width, p.height)
		}
	}

	// The focused session, or the first workspace's while every window is hidden.
	verify_session_report :: proc(r: ^State_Report, app: ^App, w: ^Window, entry: ^Session_Entry) {
		s := entry.session
		g := term.geometry(s)
		status := term.status(s)
		bar, bar_ok := term.scrollbar(s)
		if !bar_ok {state_fail(r, .System); return}
		up := bar.total - min(bar.total, bar.offset + bar.len)
		selection := "none"
		if term.has_selection(s) {
			text, ok := term.selection_text(s, context.temp_allocator)
			if !ok {state_fail(r, .System); return}
			end, count := 0, 0
			for _, offset in text {
				if count == 80 {break}
				_, width := utf8.decode_rune_in_string(text[offset:])
				end, count = offset + width, count + 1
			}
			selection = text[:end]
		}
		program: Program_Adopted
		if adopted := program_adopted(entry); adopted != nil {program = adopted^}
		state_value(r, "session.id", entry.id)
		state_text(r, "session.message", session_message(status))
		state_valuef(r, "grid.size", "%dx%d", g.columns, g.rows)
		state_word(r, "session.status", status.kind)
		state_valuef(r, "session.exit", "%d", status.exit_code)
		state_text(r, "session.title", term.title(s, context.temp_allocator))
		state_text(r, "session.header.title", pane_header_title(&entry.header))
		state_text(r, "session.profile", entry.profile_id)
		state_text(r, "session.name", entry.name)
		state_text(r, "session.command", program.command)
		state_text(r, "session.program", program.path)
		state_text(r, "session.program.name", program.name)
		program_icon_state_report(r, app, entry)
		state_text(r, "session.header.directory", entry.header.directory)
		icon := entry.header.icon
		if app.shell_icon.width > 0 {icon = settings.profile_base(&app.settings.profiles).icon}
		state_text(r, "session.header.icon", icon)
		state_valuef(r, "grid.origin", "%d,%d", g.padding_left, g.padding_top)
		state_text(r, "session.viewport", up == 0 ? "bottom" : fmt.tprintf("up:%d", up))
		state_text(r, "session.selection", selection)
		state_value(r, "session.mouse", term.mouse_tracking(s))
		state_value(r, "session.generation", term.generation(s))
		if w == nil {
			state_valuef(r, "grid.cell", "%dx%d", g.cell_width, g.cell_height)
			state_valuef(r, "grid.padding", "%d", g.padding_left)
		}
	}

	verify_notices_report :: proc(r: ^State_Report, app: ^App) {
		state_value(r, "notices.window", app.notice_window)
		for n in ui.notices_live(&app.notices) {
			left := "sticky"
			if expires, timed := ui.notice_expiry(n).?; timed {
				remaining := max(i64(0), i64(time.tick_diff(time.tick_now(), expires) / time.Millisecond))
				left = fmt.tprintf("%dms", remaining)
			}
			kind := strings.to_lower(fmt.tprintf("%v", n.kind), context.temp_allocator)
			state_valuef(r, state_key("notice.%s", verify_notice_key(n.key)), "%s: %s (%s)", kind, n.text, left)
		}

	}

	verify_workspace_index :: proc(app: ^App, w: ^Window) -> int {
		for workspace, i in app.workspaces {
			if workspace == w.workspace {return i + 1}
		}
		return 0
	}

	verify_error :: proc(app: ^App, err: verify_protocol.Error) {
		log.errorf("control request failed: %v", err)
		verify_reply(
			app,
			false,
			fmt.tprintf("error: %v; check arguments with help and retry", err),
		)
	}

	// Records what a drive's reply compares against. On failure the caller frees what was recorded.
	@(require_results)
	verify_before :: proc(
		app: ^App,
		d: ^Verify_Drive,
		entries: []verify_protocol.State_Entry,
	) -> verify_protocol.Error {
		if w := verify_window(app); w != nil && focused_session(app, w) != nil {
			err: verify_protocol.Error
			d.before, err = verify_snapshot(app, true)
			if err != .None {return err}
		}
		owned, allocation_error := make([]verify_protocol.State_Entry, len(entries))
		if allocation_error != nil {return .Out_Of_Memory}
		d.before_state = owned
		for entry, i in entries {
			key, key_error := strings.clone(entry.key)
			if key_error != nil {return .Out_Of_Memory}
			owned[i].key = key
			value, value_error := strings.clone(entry.value)
			if value_error != nil {return .Out_Of_Memory}
			owned[i].value = value
		}
		return .None
	}

	verify_before_destroy :: proc(d: ^Verify_Drive) {
		term.snapshot_destroy(&d.before)
		for entry in d.before_state {
			delete(entry.key)
			delete(entry.value)
		}
		delete(d.before_state)
	}

	@(require_results)
	verify_key_event :: proc(
		app: ^App,
		id: input.Window_Id,
		key: input.Key,
		mods: input.Modifiers,
		pressed: bool,
	) -> verify_protocol.Error {
		if window_find(app, id) == nil {return .Invalid_Argument}
		buffer: [32]u8
		event, err := platform.synthesize_key(id, key, mods, pressed, buffer[:])
		if err != .None {return .System}
		handle_event(app, event)
		return .None
	}

	@(require_results)
	verify_chord :: proc(
		app: ^App,
		id: input.Window_Id,
		chord: commands.Shortcut,
	) -> verify_protocol.Error {
		keys := [?]input.Key{.Control_Left, .Shift_Left, .Alt_Left, .Meta_Left}
		flags := [?]input.Modifier{.Control, .Shift, .Alt, .Super}
		mods: input.Modifiers
		err: verify_protocol.Error
		for key, i in keys {
			if flags[i] not_in chord.modifiers {continue}
			mods += {flags[i]}
			if err = verify_key_event(app, id, key, mods, true); err != .None {break}
		}
		if err == .None {err = verify_key_event(app, id, chord.key, mods, true)}
		if window_find(app, id) == nil {return err}
		up_error := verify_key_event(app, id, chord.key, mods, false)
		if err == .None {err = up_error}
		for i := len(keys) - 1; i >= 0; i -= 1 {
			if flags[i] not_in mods {continue}
			mods -= {flags[i]}
			if release_error := verify_key_event(app, id, keys[i], mods, false); err == .None {
				err = release_error
			}
		}
		return err
	}

	@(require_results)
	verify_position :: proc(
		app: ^App,
		w: ^Window,
		p: verify_protocol.Position,
		pixels: bool,
		screen: bool = false,
	) -> (
		[2]i32,
		bool,
	) {
		if screen {
			if p.x < int(min(i32)) ||
			   p.y < int(min(i32)) ||
			   p.x > int(max(i32)) ||
			   p.y > int(max(i32)) {return {}, false}
			x, y, err := platform.window_from_screen(&app.platform, w.id, i32(p.x), i32(p.y))
			return {x, y}, err == .None
		}
		if p.x < 0 || p.y < 0 {return {}, false}
		if pixels {
			if p.x > int(max(i32)) || p.y > int(max(i32)) {return {}, false}
			return {i32(p.x), i32(p.y)}, true
		}
		box, complaint := verify_grid(app, w)
		if complaint != "" || p.x >= int(box.columns) || p.y >= int(box.rows) {return {}, false}
		first, last := verify_cell_corner(w, box, p.x, p.y), verify_cell_corner(w, box, p.x + 1, p.y + 1)
		return {i32(first.x + (last.x - first.x) / 2), i32(first.y + (last.y - first.y) / 2)}, true
	}

	// The focused pane's grid as `w` draws it: the one cell-to-pixel mapping that mouse cells and
	// cell evidence share. The complaint says why there is none.
	@(require_results)
	verify_grid :: proc(app: ^App, w: ^Window) -> (box: Pane_Box, complaint: string) {
		entry := focused_session(app, w)
		if entry == nil {return {}, "the selected window has no focused pane; address the region in pixels"}
		for pane in w.panes {
			if pane.content != {.Terminal, entry.id} {continue}
			return pane_box(w.metrics, pane.rect, pane_insets(app, w.scale, entry, pane.floating)), ""
		}
		return {}, "the focused pane is not visible; select its tab or use --region"
	}

	// The client pixel at the top-left corner of cell (column, row). Edges round rather than the
	// cell size, so adjacent cells meet exactly.
	@(require_results)
	verify_cell_corner :: proc(w: ^Window, box: Pane_Box, column, row: int) -> [2]int {
		return {
			int(math.round(box.origin.x + f32(column) * w.metrics.cell_width)),
			int(math.round(box.origin.y + f32(row) * w.metrics.cell_height)),
		}
	}

	@(require_results)
	verify_mouse :: proc(app: ^App, w: ^Window, m: verify_protocol.Mouse) -> verify_protocol.Error {
		v := &app.verify
		if v.mouse_window != w.id {
			v.mouse_window, v.buttons = w.id, {}
		}
		pos, ok := verify_position(app, w, m.position, m.pixels, m.screen)
		if !ok {return .Invalid_Argument}
		end := pos
		if m.kind == .Drag {
			end, ok = verify_position(app, w, m.end, m.pixels, m.screen)
			if !ok {return .Invalid_Argument}
		}
		now := i64(time.tick_diff({}, time.tick_now()))
		if m.kind == .Wheel {
			handle_event(
				app,
				input.Mouse_Wheel_Event {
					window = w.id,
					x = pos.x,
					y = pos.y,
					delta_y = wheel_delta_for_lines(m.lines),
					modifiers = m.modifiers,
					time_ns = now,
				},
			)
			return .None
		}
		if m.kind == .Move {
			handle_event(
				app,
				input.Mouse_Move_Event{w.id, pos.x, pos.y, v.buttons, m.modifiers, now},
			)
			return .None
		}
		if m.kind != .Up {
			v.buttons += {m.button}
			handle_event(
				app,
				input.Mouse_Button_Event{w.id, m.button, true, pos.x, pos.y, m.modifiers, now},
			)
		}
		if m.kind == .Drag {
			for step in 1 ..= MOUSE_DRAG_STEPS {
				x := pos.x + i32((i64(end.x) - i64(pos.x)) * i64(step) / MOUSE_DRAG_STEPS)
				y := pos.y + i32((i64(end.y) - i64(pos.y)) * i64(step) / MOUSE_DRAG_STEPS)
				handle_event(
					app,
					input.Mouse_Move_Event{w.id, x, y, v.buttons, m.modifiers, now + i64(step)},
				)
			}
		}
		if m.kind != .Down {
			v.buttons -= {m.button}
			handle_event(
				app,
				input.Mouse_Button_Event {
					w.id,
					m.button,
					false,
					end.x,
					end.y,
					m.modifiers,
					now + MOUSE_DRAG_STEPS + 1,
				},
			)
		}
		return .None
	}

	@(require_results)
	verify_drive :: proc(app: ^App, request: verify_protocol.Request) -> verify_protocol.Error {
		if selection, ok := request.(verify_protocol.Window_Select); ok {
			id := input.Window_Id(selection.id)
			if window_find(app, id) == nil {return .Invalid_Argument}
			app.verify.target_window = id
			return .None
		}
		w := verify_window(app)
		if tray, ok := request.(verify_protocol.Tray); ok {
			switch tray.action {
			case .Open:
				handle_event(app, platform.Tray_Event{})
			case .Hide:
				if w != nil {handle_event(app, platform.Close_Request_Event{w.id})}
			case .Quit:
				handle_event(app, platform.Tray_Menu_Event{TRAY_QUIT})
			}
			return .None
		}
		if w == nil {return .Invalid_Argument}
		id := w.id
		#partial switch r in request {
		case verify_protocol.Type:
			handle_event(app, input.Text_Event{w.id, r.text})
		case verify_protocol.Key:
			for chord in r.chords {
				if err := verify_chord(app, id, chord); err != .None {return err}
			}
		case verify_protocol.Run:
			handle_event(app, input.Text_Event{w.id, r.line})
			return verify_chord(app, w.id, {.Enter, {}})
		case verify_protocol.Mouse:
			return verify_mouse(app, w, r)
		case verify_protocol.Window_Move:
			if platform.window_set_position(
				   &app.platform,
				   w.id,
				   i32(r.position.x),
				   i32(r.position.y),
			   ) !=
			   .None {return .System}
		case verify_protocol.Focus:
			handle_event(app, platform.Focus_Event{w.id, r.focused})
		case verify_protocol.Dpi:
			handle_event(app, platform.Dpi_Event{w.id, u32(r.value)})
		case verify_protocol.Resize:
			insets := pane_insets(app, w.scale, focused_session(app, w))
			desired, width, height, _ := pane_box_for_grid(app, w^, u16(r.columns), u16(r.rows), insets)
			// Activity can move between a standalone dock and the rail as the width changes.
			for _ in 0..<32 {
				candidate := w^
				candidate.width, candidate.height = width, height
				rail_adaptive_update(&candidate)
				area := window_content_area(app, &candidate)
				box := pane_box(w.metrics, area, insets)
				if box.columns == u16(r.columns) && box.rows == u16(r.rows) {
					if platform.window_set_client_size(&app.platform, w.id,
						candidate.width, candidate.height) != .None {return .System}
					return .None
				}
				width += i32(math.ceil(desired.rect.width - area.width))
				height += i32(math.ceil(desired.rect.height - area.height))
			}
			return .Invalid_Argument
		case verify_protocol.Command:
			command := commands.find(&app.registry, r.name)
			if command == nil {return .Invalid_Argument}
			// Copy runs only on a selection, judged in this window now, as the palette judges it.
			is_copy := Action(command.id) == .Copy
			if is_copy && !copy_selection_available(app, w) {return .Invalid_Argument}
			palette_close(app, w)
			// Verification stands in for a person at the keyboard, acting on this window's focus, which
			// reports failures as notices rather than an outcome.
			invocation := commands.invocation(command.id, focus = r.focus)
			invocation.direction, invocation.ratio = r.direction, r.ratio
			_ = command_execute(app, Window_Context{window = w}, invocation)
		case:
			return .Invalid_Argument
		}
		return .None
	}

	@(require_results)
	verify_rows :: proc(s: ^term.Snapshot, count: int = 3) -> (string, verify_protocol.Error) {
		rows: [3]string
		n := 0
		for row := int(s.rows) - 1; row >= 0 && n < min(count, len(rows)); row -= 1 {
			text, err := term.row_text(s, row, context.temp_allocator)
			if err != .None {return "", .Out_Of_Memory}
			if text == "" {continue}
			rows[n] = fmt.tprintf("%d|%s", row, text)
			n += 1
		}
		for i in 0 ..< n / 2 {rows[i], rows[n - i - 1] = rows[n - i - 1], rows[i]}
		return strings.join(rows[:n], " ", context.temp_allocator), .None
	}

	@(require_results)
	verify_changes :: proc(
		app: ^App,
		d: ^Verify_Drive,
		s: ^term.Snapshot,
		entries: []verify_protocol.State_Entry,
	) -> (
		string,
		verify_protocol.Error,
	) {
		parts := make([dynamic]string, context.temp_allocator)
		ranges := make([dynamic]string, context.temp_allocator)
		changed_rows := 0
		first := -1
		rows := d.before.rows > 0 && s.rows > 0 ? max(int(d.before.rows), int(s.rows)) : 0
		for row in 0 ..= rows {
			changed := false
			if row < rows {
				a, ae := term.row_text(&d.before, row, context.temp_allocator)
				b, be := term.row_text(s, row, context.temp_allocator)
				if ae != .None || be != .None {return "", .Out_Of_Memory}
				changed = a != b
			}
			if changed && first < 0 {first = row}
			if changed {changed_rows += 1}
			if !changed && first >= 0 {
				label :=
					first == row - 1 ? fmt.tprintf("%d", first) : fmt.tprintf("%d-%d", first, row - 1)
				if _, err := append(&ranges, label); err != nil {return "", .Out_Of_Memory}
				first = -1
			}
		}
		if len(ranges) > 0 {
			label := fmt.tprintf(
				"%s %s changed",
				changed_rows == 1 ? "row" : "rows",
				strings.join(ranges[:], ", ", context.temp_allocator),
			)
			if _, err := append(&parts, label); err != nil {return "", .Out_Of_Memory}
		}
		for changed in CHANGED_KEYS {
			a, b := verify_value(d.before_state, changed.key), verify_value(entries, changed.key)
			if a == b {continue}
			change: string
			if changed.became_true != "" {
				change = b == "true" ? changed.became_true : changed.became_false
			} else {
				value := strings.builder_make(context.temp_allocator)
				if err := verify_protocol.format_value(&value, b); err != .None {return "", err}
				change = fmt.tprintf("%s=%s", changed.key, strings.to_string(value))
			}
			if _, err := append(&parts, change); err != nil {return "", .Out_Of_Memory}
		}
		for n in ui.notices_live(&app.notices) {
			key := fmt.tprintf("notice.%s", verify_notice_key(n.key))
			old := verify_value(d.before_state, key)
			// Expiry countdown changes are not a new notice.
			kind := strings.to_lower(fmt.tprintf("%v", n.kind), context.temp_allocator)
			prefix := fmt.tprintf("%s: %s (", kind, n.text)
			if strings.has_prefix(old, prefix) {continue}
			value := strings.builder_make(context.temp_allocator)
			if err := verify_protocol.format_value(&value, n.text); err != .None {return "", err}
			label := fmt.tprintf(
				"notice %s %s",
				verify_notice_key(n.key),
				strings.to_string(value),
			)
			if _, err := append(&parts, label); err != nil {return "", .Out_Of_Memory}
		}
		for old in d.before_state {
			if strings.has_prefix(old.key, "notice.") && verify_value(entries, old.key) == "" {
				if _, err := append(&parts, fmt.tprintf("%s removed", old.key)); err != nil {
					return "", .Out_Of_Memory
				}
			}
		}
		if len(parts) == 0 {return "ok; no visible change", .None}
		return fmt.tprintf("ok; %s", strings.join(parts[:], "; ", context.temp_allocator)), .None
	}

	verify_read :: proc(app: ^App, request: verify_protocol.Request) {
		entries, state_error := verify_state(app)
		if state_error != .None {verify_error(app, state_error); return}
		out := strings.builder_make(context.temp_allocator)
		err: verify_protocol.Error
		passed := true
		#partial switch r in request {
		case verify_protocol.Ping:
			values: [verify_protocol.Ping_Field]string
			for name, field in verify_protocol.PING_FIELDS {
				values[field] = verify_value(entries, fmt.tprintf("app.%s", name))
			}
			err = verify_protocol.format_ping(&out, values)
		case verify_protocol.Help:
			err = verify_protocol.help(&out, r.command)
		case verify_protocol.State:
			err = verify_protocol.format_state(&out, entries)
		case verify_protocol.Screen, verify_protocol.Cells, verify_protocol.Expect:
			s: term.Snapshot
			expect, is_expect := request.(verify_protocol.Expect)
			if !is_expect || expect.kind != .State {
				s, err = verify_snapshot(app)
				if err != .None {verify_error(app, err); return}
			}
			#partial switch r in request {
			case verify_protocol.Screen:
				err = verify_protocol.format_screen(&out, &s, r.rows)
			case verify_protocol.Cells:
				err = verify_protocol.format_cells(&out, &s, r)
			case verify_protocol.Expect:
				passed, err = verify_protocol.evaluate(&out, r, &s, entries)
			}
		case verify_protocol.Capture:
			err = capture_read(app, &out, r)
		case verify_protocol.Pixels:
			err = pixels_read(app, &out, r)
		case verify_protocol.Diff:
			err = pixels_diff(app, &out, r)
		case verify_protocol.Draws:
			err = draws_read(app, &out, r)
		case verify_protocol.Perf:
			err = perf_read(app, &out, r)
		case verify_protocol.Vt:
			err = vt_record(app, &out, r)
		case:
			err = .Invalid_Argument
		}
		if err != .None {
			// Evidence commands explain bad input, files, or devices in their own words.
			text := strings.to_string(out)
			if verify_protocol.reply_explained(text) {
				verify_reply(app, false, text)
				return
			}
			verify_error(app, err)
			return
		}
		verify_reply(app, passed, strings.to_string(out))
	}

	verify_wait :: proc(app: ^App, wait: Verify_Wait, w: ^Window, now: time.Tick, presented: bool) {
		v := &app.verify
		r := wait.message.request.(verify_protocol.Wait)
		elapsed := int(time.tick_diff(wait.started, now) / time.Millisecond)
		timed_out := elapsed >= r.timeout_ms
		idle := time.tick_diff(v.changed, now) >= time.Duration(r.idle_ms) * time.Millisecond
		if !timed_out {
			if r.kind == .Idle && !idle {return}
			if !presented {
				if r.kind == .Idle || v.frames == wait.request_frame {w.dirty = true}
				return
			}
		}
		s, err := verify_snapshot(app)
		if err != .None {verify_error(app, err); return}
		out := strings.builder_make(context.temp_allocator)
		passed := false
		label := "frame"
		switch r.kind {
		case .Idle:
			label, passed = fmt.tprintf("idle %dms", r.idle_ms), idle
		case .Frame:
			passed = v.frames > wait.request_frame
		case .Text, .Gone:
			e := verify_protocol.Expect {
				kind = r.kind == .Text ? .Text : .No_Text,
				text = r.text,
			}
			passed, err = verify_protocol.evaluate(&out, e, &s)
			label = fmt.tprintf("%s %q", r.kind == .Text ? "text" : "gone", r.text)
			if passed && r.kind == .Text {
				text := strings.trim_space(strings.to_string(out))
				label = strings.trim_prefix(text, verify_protocol.PASS_PREFIX)
			}
		}
		if err != .None {verify_error(app, err); return}
		if passed && presented && v.frames > wait.request_frame && !w.dirty {
			text := fmt.tprintf("%swait %s after %dms", verify_protocol.PASS_PREFIX, label, elapsed)
			verify_reply(app, true, text)
			return
		}
		if timed_out {
			rows, rows_error := verify_rows(&s)
			if rows_error != .None {verify_error(app, rows_error); return}
			verify_reply(
				app,
				false,
				fmt.tprintf(
					"%swait %s: timeout after %dms; last rows: %s",
					verify_protocol.FAIL_PREFIX,
					label,
					elapsed,
					rows,
				),
			)
			return
		}
		if passed || v.frames == wait.request_frame {w.dirty = true}
	}

	verify_finish_drive :: proc(app: ^App, d: ^Verify_Drive, w: ^Window, now: time.Tick) {
		v := &app.verify
		elapsed := int(time.tick_diff(d.started, now) / time.Millisecond)
		idle_ms, timeout_ms := verify_drive_limits(d.message.request)
		_, is_run := d.message.request.(verify_protocol.Run)
		quiet := time.tick_diff(v.changed, now) >= time.Duration(idle_ms) * time.Millisecond
		frame := w == nil || v.frames > d.request_frame && !w.dirty
		if elapsed < timeout_ms && (!quiet || !frame) {
			if w != nil && quiet {w.dirty = true}
			return
		}
		s: term.Snapshot
		err: verify_protocol.Error
		if w != nil && focused_session(app, w) != nil {
			s, err = verify_snapshot(app)
			if err != .None {verify_error(app, err); return}
		}
		if is_run && !quiet {
			rows, rows_error := verify_rows(&s)
			if rows_error != .None {verify_error(app, rows_error); return}
			verify_reply(
				app,
				false,
				fmt.tprintf("error: run timed out after %dms; use screen\n%s", elapsed, rows),
			)
			return
		}
		if !frame {
			verify_reply(
				app,
				false,
				"error: no frame presented before timeout; restore the window and retry",
			)
			return
		}
		entries, state_error := verify_state(app)
		if state_error != .None {verify_error(app, state_error); return}
		if r, resize := d.message.request.(verify_protocol.Resize); resize {
			if verify_value(entries, "grid.size") != fmt.tprintf("%dx%d", r.columns, r.rows) {
				if elapsed < RESIZE_TIMEOUT_MS {return}
				verify_reply(app, false, "error: resize timed out; use state to inspect grid.size")
				return
			}
		}
		text, change_error := verify_changes(app, d, &s, entries)
		if change_error != .None {verify_error(app, change_error); return}
		if is_run {
			rows, rows_error := verify_rows(&s)
			if rows_error != .None {verify_error(app, rows_error); return}
			text = fmt.tprintf("%s\n%s", text, rows)
		}
		verify_reply(app, true, text)
	}

	verify_update_generation :: proc(v: ^Verify, app: ^App, w: ^Window, now: time.Tick) {
		generation: u64
		session_id: u32
		if w != nil {
			if entry := focused_session(app, w); entry != nil {
				generation, session_id = term.generation(entry.session), entry.id
			}
		}
		if generation != v.generation || session_id != v.session_id {
			v.generation, v.changed, v.session_id = generation, now, session_id
		}
	}

	verify_tick :: proc(app: ^App) {
		v := &app.verify
		if v.server == nil {return}
		presented := v.presented
		v.presented = false
		now := time.tick_now()
		if quitting, ok := v.request.(Verify_Quitting); ok {
			if control.delivery_finished(v.server, quitting.id) ||
			   time.tick_diff(quitting.started, now) >= QUIT_DRAIN {
				app_quit_release(app)
			}
			return
		}
		w := verify_window(app)
		verify_update_generation(v, app, w, now)
		if v.request == nil {
			transport := control.poll(v.server)
			if transport == nil {return}
			request, parse_error := verify_protocol.parse(transport.args)
			if parse_error.advice != "" {
				verify_reject(v, transport, parse_error)
				return
			}
			verify_accept(app, {transport, request}, w, now)
		}
		message, active := verify_message(v)
		if !active {return}
		_, driving := v.request.(Verify_Drive)
		if !driving && w == nil && verify_needs_window(message.request) {
			verify_reply(app, false, "error: window hidden; run tray open")
			return
		}
		switch &s in v.request {
		case nil, Verify_Quitting:
		case Verify_Gate:
			if w != nil && (w.dirty || s.needs_frame && v.frames == s.request_frame) {
				timeout := time.Duration(verify_timeout(message.request)) * time.Millisecond
				if time.tick_diff(s.started, now) < timeout {w.dirty = true; return}
				verify_reply(
					app,
					false,
					"error: no frame presented before timeout; restore the window and retry",
				)
				return
			}
			switch s.then {
			case .Read:
				verify_read(app, message.request)
			case .Drive:
				verify_start_drive(app, s, now)
			}
		case Verify_Wait:
			verify_wait(app, s, w, now, presented)
		case Verify_Drive:
			verify_finish_drive(app, &s, w, now)
		}
	}

	// Answers a request whose arguments do not parse, without entering a state.
	verify_reject :: proc(v: ^Verify, transport: ^control.Message, e: verify_protocol.Parse_Error) {
		defer control.message_destroy(transport)
		out := strings.builder_make(context.temp_allocator)
		text: string
		if err := verify_protocol.format_parse_error(&out, e); err == .None {
			text = strings.to_string(out)
		} else {
			text = fmt.tprintf("error: %v; check arguments with help and retry", err)
		}
		if err := control.respond(v.server, transport.id, {ok = false, text = text}); err != .None {
			log.errorf("answering control request failed: %v", err)
		}
	}

	// The procs from here to verify_end are the only writers of Verify.request.

	// The message's request decides its first state; a quit is answered at once.
	verify_accept :: proc(app: ^App, message: Verify_Message, w: ^Window, now: time.Tick) {
		v := &app.verify
		switch verify_action(message.request) {
		case .Read:
			verify_gate(app, message, .Read, w, now)
		case .Drive:
			verify_gate(app, message, .Drive, w, now)
		case .Wait:
			v.request = Verify_Wait{message, now, v.frames}
		case .Quit:
			id := message.transport.id
			verify_message_destroy(message)
			app_quit(app)
			verify_quit(app, id, now)
		}
	}

	verify_gate :: proc(app: ^App, message: Verify_Message, then: Verify_Gated, w: ^Window, now: time.Tick) {
		v := &app.verify
		gate := Verify_Gate{message = message, then = then, started = now, request_frame = v.frames}
		if w != nil {gate.needs_frame = w.dirty || window_generation(app, w) != w.generation}
		v.request = gate
	}

	// Records the state the reply compares against, drives, and waits for the result. A drive that
	// quit the app is answered now, while the quit is held open.
	verify_start_drive :: proc(app: ^App, gate: Verify_Gate, now: time.Tick) {
		v := &app.verify
		entries, state_error := verify_state(app)
		if state_error != .None {verify_error(app, state_error); return}
		drive := Verify_Drive{message = gate.message}
		started := false
		defer if !started {verify_before_destroy(&drive)}
		if err := verify_before(app, &drive, entries); err != .None {verify_error(app, err); return}
		perf.mark_input(&app.perf)
		if err := verify_drive(app, gate.message.request);
		   err != .None {verify_error(app, err); return}
		if app.run != .Running {
			id := gate.message.transport.id
			verify_end(v)
			verify_quit(app, id, now)
			return
		}
		drive.started, drive.request_frame = now, v.frames
		v.changed = now
		v.request = drive
		started = true
	}

	// Answers the request that quit and holds the app's quit until the answer is delivered. A failed
	// graphics device ends the app regardless, so its answer says so and nothing is held.
	verify_quit :: proc(app: ^App, id: u64, now: time.Tick) {
		v := &app.verify
		held := app_quit_hold(app)
		response := control.Response{ok = held, text = "ok; quitting"}
		if !held {response.text = "error: the graphics device was lost; AIODev is exiting"}
		if err := control.respond(v.server, id, response); err != .None {
			log.errorf("answering control request failed: %v", err)
		}
		if held {v.request = Verify_Quitting{id, now}}
	}

	verify_reply :: proc(app: ^App, ok: bool, text: string) {
		v := &app.verify
		if m, active := verify_message(v); active {
			if err := control.respond(v.server, m.transport.id, {ok = ok, text = text}); err != .None {
				log.errorf("answering control request failed: %v", err)
			}
		}
		verify_end(v)
	}

	// Ends whatever request is in flight, freeing what its state owns.
	verify_end :: proc(v: ^Verify) {
		switch &s in v.request {
		case nil, Verify_Quitting:
		case Verify_Gate:
			verify_message_destroy(s.message)
		case Verify_Wait:
			verify_message_destroy(s.message)
		case Verify_Drive:
			verify_message_destroy(s.message)
			verify_before_destroy(&s)
		}
		v.request = nil
	}

	verify_message :: proc(v: ^Verify) -> (Verify_Message, bool) {
		switch s in v.request {
		case Verify_Gate:
			return s.message, true
		case Verify_Wait:
			return s.message, true
		case Verify_Drive:
			return s.message, true
		case Verify_Quitting:
		}
		return {}, false
	}

	verify_message_destroy :: proc(message: Verify_Message) {
		request := message.request
		verify_protocol.request_destroy(&request)
		control.message_destroy(message.transport)
	}
} else {
	Verify :: struct {}
	verify_start :: proc(_: ^App) {}
	verify_destroy :: proc(_: ^App) {}
	verify_presented :: proc(_: ^App, _: ^Window) {}
	verify_tick :: proc(_: ^App) {}
	verify_deadline :: proc(_: ^App) -> (time.Tick, bool) {return {}, false}
}
