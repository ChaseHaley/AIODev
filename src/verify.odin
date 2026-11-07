package main

import "aio:commands"
import "aio:control"
import "aio:input"
import "aio:layout"
import "aio:perf"
import "aio:platform"
import "aio:program_art"
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
_ :: program_art

AIO_CONTROL :: #config(AIO_CONTROL, false)

// State keys whose change is reported by name rather than as a full value dump.
@(private)
CHANGED_KEYS :: [?]string {
	"window.visible", "windows.count", "window.id", "window.origin", "window.size", "window.dpi",
	"window.focused", "grid.size", "palette.open", "palette.query", "palette.item", "palette.selected",
	"find.open", "find.query", "find.matches", "session.viewport", "session.selection",
}

when AIO_CONTROL {
	Verify :: struct {
		server: ^control.Server,
		request: Verify_Request,
		// When the focused pane's content last changed, or the last drive began.
		changed: time.Tick,
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
			return time.tick_add(now, 10 * time.Millisecond), true
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
		return 5000
	}

	// A resize may report only once the grid follows, which takes longer than the frame.
	RESIZE_TIMEOUT_MS :: 5000

	// How long after a drive the content must be quiet, and the longest a drive waits for it.
	verify_drive_limits :: proc(request: verify_protocol.Request) -> (idle_ms, timeout_ms: int) {
		if r, run := request.(verify_protocol.Run); run {return r.idle_ms, r.timeout_ms}
		return 50, 1000
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

	@(require_results)
	verify_state :: proc(app: ^App) -> ([]verify_protocol.State_Entry, verify_protocol.Error) {
		w := verify_window(app)
		palette_owner := palette_owner_id(app)
		owns_palette := w != nil && palette_owner == w.id
		item := ""
		p := &app.palette
		palette_layout: ui.Palette_Layout
		if owns_palette {
			// Observing geometry must not repair selection or scroll before the assertion reads them.
			measured := p^
			palette_layout = ui.palette_layout(&measured, f32(w.width), f32(w.height), w.scale)
		}
		if owns_palette && p.selected >= 0 && p.selected < len(p.results) {
			item = ui.palette_result_name(p, p.results[p.selected])
		}
		// The saved value of the selected setting row, read the way its palette control reads it.
		selected_value := ""
		edit := ui.Palette_Edit_Kind.None
		if owns_palette {
			edit = ui.palette_editing(p)
			if p.selected >= 0 && p.selected < len(p.results) && p.results[p.selected].kind == .Setting {
				selected_value, _ = palette_setting_value(app, item)
			}
			if p.selected >= 0 && p.selected < len(p.results) && p.results[p.selected].command != nil {
				selected_value = commands.shortcut_set_text(p.results[p.selected].command.shortcuts,
				                                           context.temp_allocator)
			}
		}
		entries := make([dynamic]verify_protocol.State_Entry, context.temp_allocator)
		base := [?]verify_protocol.State_Entry {
			{"app.pid", fmt.tprintf("%d", os.get_pid())},
			{"app.app", app.app_id},
			{"app.build", AIO_BUILD_ID},
			{"app.build_kind", AIO_BUILD_KIND},
			{"app.data", app.options.data_dir == "" ? "default" : app.options.data_dir},
			{"app.settings", app.settings_path},
			{"app.log", app.log_path},
			{"window.visible", fmt.tprintf("%t", !app_tray_only(app))},
			{"windows.count", fmt.tprintf("%d", len(app.windows))},
			{"palette.window", fmt.tprintf("%d", palette_owner)},
			{"palette.open", fmt.tprintf("%t", palette_active(app, w))},
			{"palette.query", owns_palette ? ui.palette_query(p) : ""},
			{"palette.mode", owns_palette ? ui.palette_mode_word(p.mode) : "all"},
			{"palette.prefix", owns_palette ? ui.palette_mode_prefix(p.mode) : ""},
			{"palette.selected", fmt.tprintf("%d", owns_palette ? p.selected : 0)},
			{"palette.items", fmt.tprintf("%d", owns_palette ? len(p.results) : 0)}, {"palette.item", item},
			{"palette.scroll", fmt.tprintf("%d", owns_palette ? p.scroll : 0)},
			{"palette.edit", fmt.tprintf("%v", edit)},
			{"palette.value", selected_value},
			{"palette.rows", fmt.tprintf("%d", palette_layout.rows)},
			{"palette.row_height", fmt.tprintf("%g", palette_layout.row_height)},
			{"palette.panel", fmt.tprintf("%g,%g,%g,%g", palette_layout.panel.x, palette_layout.panel.y,
				palette_layout.panel.width, palette_layout.panel.height)},
			{"palette.input", fmt.tprintf("%g,%g,%g,%g", palette_layout.input.x, palette_layout.input.y,
				palette_layout.input.width, palette_layout.input.height)},
			{"palette.list", fmt.tprintf("%g,%g,%g,%g", palette_layout.list.x, palette_layout.list.y,
				palette_layout.list.width, palette_layout.list.height)},
			{"frames.presented", fmt.tprintf("%d", app.verify.frames)},
			{
				"theme.name",
				settings.value_text(&app.settings, settings.schema_find("theme.name")^),
			},
			{"terminal.foreground", settings.color_hex(app.settings.colors.foreground)},
			{"terminal.background", settings.color_hex(app.settings.colors.background)},
			{"ui.animations", fmt.tprintf("%t", app.animations)},
			{"ui.font_points", fmt.tprintf("%g", app.settings.interface.font_size)},
			{"ui.font_family", app.settings.interface.font_family},
			{"terminal.font_family", app.settings.font.family},
			{"shell.icon.loaded", fmt.tprintf("%t", app.shell_icon.width > 0)},
			{"ui.animating", fmt.tprintf("%t", motion_active(app))},
			{"leader.enabled", fmt.tprintf("%t", app.leader != nil)},
			{"workspaces.count", fmt.tprintf("%d", len(app.workspaces))},
		}
		if _, err := append(&entries, ..base[:]); err != nil {return nil, .Out_Of_Memory}
		for mode in ui.Palette_Mode {
			r := palette_layout.modes[mode]
			entry := verify_protocol.State_Entry{fmt.tprintf("palette.mode.%s", ui.palette_mode_word(mode)),
				fmt.tprintf("%g,%g,%g,%g", r.x, r.y, r.width, r.height)}
			if _, err := append(&entries, entry); err != nil {return nil, .Out_Of_Memory}
		}
		origin: [2]i32
		for window, i in app.windows {
			x, y, err := platform.window_to_screen(&app.platform, window.id, 0, 0)
			if err != .None {return nil, .System}
			if window == w {origin = {x, y}}
			prefix := fmt.tprintf("window.%d", i + 1)
			inventory := [?]verify_protocol.State_Entry {
				{fmt.tprintf("%s.id", prefix), fmt.tprintf("%d", window.id)},
				{fmt.tprintf("%s.origin", prefix), fmt.tprintf("%d,%d", x, y)},
				{
					fmt.tprintf("%s.size", prefix),
					fmt.tprintf("%dx%d", window.width, window.height),
				},
				{
					fmt.tprintf("%s.workspace_index", prefix),
					fmt.tprintf("%d", verify_workspace_index(app, window)),
				},
				{fmt.tprintf("%s.preparing", prefix), fmt.tprintf("%t", window.phase == .Preparing)},
				{fmt.tprintf("%s.linked", prefix), fmt.tprintf("%t", window_linked(window))},
				{
					fmt.tprintf("%s.link_shown", prefix),
					fmt.tprintf("%t", window_linked(window) && window.phase == .Shown),
				},
			}
			if _, err := append(&entries, ..inventory[:]); err != nil {return nil, .Out_Of_Memory}
		}
		entry: ^Session_Entry
		if w != nil {
			entry = focused_session(app, w)
			editor_key := ""
			editor_title := ""
			choice_count := 0
			if row := ui.editor_row(&w.editor);
			   row != nil {
				editor_key, editor_title = row.key, row.title
				choice_count = len(row.choices)
			}
			// Each confirmation key reads the question only while it is about that key's subject.
			question := confirmation_shown(w)
			opacity := question != nil ? question.dialog.motion.value : 0
			closing := confirmation_subject(w, Pending_Close)
			close_open := confirmation_asking(w, Pending_Close) != nil
			confirm: Confirmation_Text
			close_workspace: u32
			if closing != nil {
				confirm = pending_close_text(app, closing, close_open, w.workspace)
				if target, ok := closing.target.(Close_Workspace); ok {close_workspace = target.workspace}
			}
			file := confirmation_subject(w, Pending_File)
			swap := confirmation_subject(w, Pane_Swap)
			removing := confirmation_subject(w, Profile_Remove)
			process_remove := confirmation_asking(w, Process_Remove) != nil
			picker_rect, _ := workspace_picker_rect(w)
			link_hover, link_uri, link_spans := verify_link_hover(w)
			slider := render.Rect{}
			page: ui.Editor_Layout
			if settings_active(w) {
				page = settings_layout(w)
				if len(w.editor.items) > 0 {
					slider = ui.editor_row_parts(&w.editor, page, w.editor.selected).slider
				}
			}
			markdown_scroll, markdown_total := 0, 0
			markdown_path, markdown_selected := "", ""
			markdown_state := "Missing"
			if pane := markdown_focused(app, w); pane != nil {
				markdown_scroll, markdown_total = pane.view.scroll, ui.markdown_total(&pane.view)
				markdown_path = pane.path
				switch _ in pane.load {
				case nil:
					markdown_state = "Unverified"
				case Markdown_Missing:
				case Markdown_Loaded:
					markdown_state = "Loaded"
				case Markdown_Too_Large:
					markdown_state = "Too_Large"
				case Markdown_Failed:
					markdown_state = "Failed"
				}
				if document := markdown_document(pane); document != nil {
					markdown_selected = ui.markdown_selected_text(&pane.view, document)
				}
			}
			window := [?]verify_protocol.State_Entry {
				{"window.id", fmt.tprintf("%d", w.id)},
				{"markdown.count", fmt.tprintf("%d", len(app.markdown_panes))},
				{"markdown.active", fmt.tprintf("%t", markdown_active(w))},
				{"markdown.path", markdown_path},
				{"markdown.state", markdown_state},
				{"markdown.scroll", fmt.tprintf("%d", markdown_scroll)},
				{"markdown.total", fmt.tprintf("%d", markdown_total)},
				{"markdown.selection", markdown_selected},
				{"window.origin", fmt.tprintf("%d,%d", origin.x, origin.y)},
				{"window.pointer", fmt.tprintf("%g,%g", w.pointer.x, w.pointer.y)},
				{"theme.hover_lift", fmt.tprintf("%g", app.theme.hover_lift)},
				{"theme.hover_gloss", fmt.tprintf("%g", app.theme.hover_gloss)},
				{"window.workspace_index", fmt.tprintf("%d", verify_workspace_index(app, w))},
				{"settings.open", fmt.tprintf("%t", ui.editor_loaded(&w.editor))},
				{"settings.revision", verify_settings_revision(&w.editor)},
				{"settings.theme_delete_armed", fmt.tprintf("%t", w.theme_delete != nil)},
				{"overlay", strings.to_lower(fmt.tprintf("%v", overlay_kind(app, w)), context.temp_allocator)},
				{"rename.open", fmt.tprintf("%t", rename_shown(w))},
				{"rename.error", fmt.tprintf("%t", verify_chip_name_error(w))},
				{"rename.value", ui.field_string(&w.rename)},
				{"tab_menu.open", fmt.tprintf("%t", tab_menu_shown(w))},
				{"tab_menu.count", fmt.tprintf("%d", w.tab_menu.count)},
				{"tab_menu.action", fmt.tprintf("%v", w.tab_menu.actions[w.tab_menu.selected])},
				{"settings.filter", string(w.editor.filter.bytes[:])},
				{"settings.scroll", fmt.tprintf("%d", w.editor.scroll)},
				{"settings.group", fmt.tprintf("%d", ui.editor_active_group(&w.editor))},
				{"settings.key", editor_key},
				{"settings.value", string(w.editor.value.bytes[:])},
				{"settings.editing", fmt.tprintf("%t", ui.editor_editing(&w.editor))},
				{"settings.active", fmt.tprintf("%t", settings_active(w))},
				{"settings.popup", fmt.tprintf("%v", ui.editor_popup(&w.editor))},
				{"settings.choice_count", fmt.tprintf("%d", choice_count)},
				{"settings.choice_query", ui.field_string(&w.editor.choice_search)},
				{"settings.choice_matches", fmt.tprintf("%d", len(w.editor.choice_matches))},
				{"settings.capturing", fmt.tprintf("%t", ui.editor_capturing(&w.editor))},
				{"settings.title", editor_title},
				{"settings.message", w.editor.message},
				{"settings.error", fmt.tprintf("%t", w.editor.error)},
				{"settings.process.rows", verify_process_rows(w, page)},
				{"settings.process.expanded", fmt.tprintf("%d", w.editor.process_expanded)},
				{
					"settings.process.dragging",
					fmt.tprintf("%t", ui.editor_order_dragging(&w.editor, .Process_Groups)),
				},
				{"settings.process.drag_target", fmt.tprintf("%d", ui.editor_order_target(&w.editor))},
				{"settings.process.value", app.settings.process.padding_groups},
				{"settings.process.confirming", fmt.tprintf("%t", process_remove)},
				{
					"settings.process.confirm_option",
					fmt.tprintf("%t", process_remove && question.dialog.show_option),
				},
				{"settings.profile.expanded", w.editor.expanded},
				{"settings.profile.default", app.settings.profiles.default_id},
				{"settings.profile.detected_open", fmt.tprintf("%t", w.editor.detected_open)},
				{
					"settings.profile.removing",
					confirmation_asking(w, Profile_Remove) != nil ? removing.id : "",
				},
				{
					"settings.profile.remove_title",
					editor_profile_remove_text(app, removing != nil ? removing.id : "").title,
				},
				{"settings.profile.menu_open", fmt.tprintf("%t", verify_editor_profile_menu_open(w))},
				{"settings.profile.menu_count", fmt.tprintf("%d", len(w.editor.profile_menu.items))},
				{"settings.profile.action", fmt.tprintf("%v", w.editor.request)},
				{"settings.profile.error_key", w.editor.error_key},
				{"settings.profile.error", w.editor.error_text},
				{"settings.profile.control", fmt.tprintf("%v", w.editor.profile_control)},
				{
					"settings.profile.directory_shown",
					fmt.tprintf("%t", ui.profile_columns(page.list, page.scale).directory_shown),
				},
				{"settings.profile.rows", verify_profile_rows(w, page, .Profile)},
				{"settings.profile.detected_rows", verify_profile_rows(w, page, .Detected)},
				{
					"settings.profile.detected_header",
					verify_profile_rows(w, page, .Detected_Header),
				},
				{"settings.profile.app_count", fmt.tprintf("%d", len(app.settings.profiles.items))},
				{"settings.profile.app_detected", verify_detected_count(app)},
				{"settings.profile.group", fmt.tprintf("%d", verify_profile_group(&w.editor))},
				{
					"settings.profile.dragging",
					fmt.tprintf("%t", ui.editor_order_dragging(&w.editor, .Profiles)),
				},
				{"settings.profile.drag_target", fmt.tprintf("%d", ui.editor_order_target(&w.editor))},
				{"settings.profile.drag_id", ui.editor_order_profile(&w.editor)},
				{
					"settings.slider",
					fmt.tprintf("%g,%g,%g,%g", slider.x, slider.y, slider.width, slider.height),
				},
				{
					"settings.search_rect",
					fmt.tprintf(
						"%g,%g,%g,%g",
						page.filter.x,
						page.filter.y,
						page.filter.width,
						page.filter.height,
					),
				},
				{
					"settings.outline_rect",
					fmt.tprintf(
						"%g,%g,%g,%g",
						page.outline.x,
						page.outline.y,
						page.outline.width,
						page.outline.height,
					),
				},
				{
					"settings.list_rect",
					fmt.tprintf(
						"%g,%g,%g,%g",
						page.list.x,
						page.list.y,
						page.list.width,
						page.list.height,
					),
				},
				{"leader.pending", fmt.tprintf("%t", leader_armed(w))},
				{"confirm.open", fmt.tprintf("%t", close_open)},
				{"confirm.opacity", fmt.tprintf("%g", closing != nil ? opacity : 0)},
				{"confirm.title", close_open ? confirm.title : ""},
				{"confirm.body", close_open ? confirm.body : ""},
				{"confirm.workspace", fmt.tprintf("%d", close_workspace)},
				{"file.open", fmt.tprintf("%t", confirmation_asking(w, Pending_File) != nil)},
				{"file.path", file != nil ? file.file.path : ""},
				{"file.target", file != nil ? file.file.target : ""},
				{"swap.open", fmt.tprintf("%t", confirmation_asking(w, Pane_Swap) != nil)},
				{"swap.opacity", fmt.tprintf("%g", swap != nil ? opacity : 0)},
				{"swap.profile", swap != nil ? swap.profile_id : ""},
				{"leader.indicator", leader_armed(w) ? "pane-status-line" : "none"},
				{"window.size", fmt.tprintf("%dx%d", w.width, w.height)},
				{"window.dpi", fmt.tprintf("%d", u32(w.scale * 96))},
				{"window.scale", fmt.tprintf("%g", w.scale)},
				{"window.focused", fmt.tprintf("%t", w.focused)},
				{"window.maximized", fmt.tprintf("%t", w.maximized)},
				{"window.pane_view", fmt.tprintf("%v", pane_view_current(w))},
				{"tabs.orientation", w.tabs_horizontal ? "horizontal" : "vertical"},
				{"tabs.width", fmt.tprintf("%g", window_tab_bar(app, w).tab_width)},
				{"tabs.x", fmt.tprintf("%g", window_tab_bar(app, w).x)},
				{"tabs.height", fmt.tprintf("%g", window_tab_bar(app, w).height)},
				{"tabs.new_tab", verify_workspace_rect(window_tab_new_rect(app, w))},
				{"tabs.chevron", verify_workspace_rect(tab_chevron_rect(app, w))},
				{"rail.visible", fmt.tprintf("%t", rail_visible(w))},
				{"rail.docked", fmt.tprintf("%t", rail_docked(w))},
				{"rail.rect", verify_workspace_rect(rail_area(w))},
				{"rail.resize", verify_workspace_rect(rail_resize_rect(w))},
				{"rail.resizing", fmt.tprintf("%t", rail_resizing(w))},
				{"activity.rect", verify_workspace_rect(status_panel_rect(app, w))},
				{"activity.side_button", verify_workspace_rect(status_panel_side_rect(app, w))},
				{"activity.side", app.settings.status.panel_side == .Left ? "left" : "right"},
				{"activity.view_button", verify_workspace_rect(status_panel_view_rect(app, w))},
				{"activity.view", app.settings.status.panel_view == .Comfy ? "comfy" : "dense"},
				{"dividers.dragging", fmt.tprintf("%d", divider_drag_count(w))},
				{"rail.overlay", fmt.tprintf("%t", rail_overlay(w))},
				{"rail.scroll", fmt.tprintf("%g", w.rail_scroll)},
				{"rail.slide", fmt.tprintf("%g", rail_slide_value(w))},
				{"rail.rows", fmt.tprintf("%d", len(w.rail_rows))},
				{"rail.row.height", fmt.tprintf("%g", ui.RAIL_ROW_HEIGHT * w.scale)},
				{"rail.toggle", verify_workspace_rect(tab_orientation_button_rect(w))},
				{"tabs.orientation_button", verify_workspace_rect(tab_orientation_button_rect(w))},
				{"title.settings", verify_workspace_rect(title_action_rect(w, .Settings))},
				{"title.palette", verify_workspace_rect(title_action_rect(w, .Palette))},
				{"title.height", fmt.tprintf("%g", ui.TITLE_BAR_HEIGHT * w.scale)},
				{
					"title.controls_end",
					fmt.tprintf("%d", i32(window_title_controls_end(app, w))),
				},
				{"title.caption_start", fmt.tprintf("%g", f32(w.width) - 138 * w.scale)},
				{"workspace.id", fmt.tprintf("%d", w.workspace.id)},
				{"workspace.name", w.workspace.name},
				{"workspace.button", verify_workspace_rect(workspace_button_rect(w))},
				{"workspace.button.hover", fmt.tprintf("%t", w.workspace_hovered)},
				{"workspace.picker", fmt.tprintf("%t", workspace_picker_active(&w.workspace_picker))},
				{"workspace.icon.preset", fmt.tprintf("%d", w.workspace.icon.preset)},
				{"workspace.icon.emoji", w.workspace.icon.emoji},
				{"workspace.icon.tint", fmt.tprintf("%d", w.workspace.icon.tint)},
				{"workspace.picker.colors", fmt.tprintf("%t", workspace_picker_mode(&w.workspace_picker) == .Tint)},
				{"workspace.picker.color_button", verify_workspace_rect(workspace_icon_color_button(w))},
				{"workspace.picker.icons", fmt.tprintf("%t", workspace_picker_icons(&w.workspace_picker))},
				{"workspace.picker.selected", fmt.tprintf("%d", w.workspace_picker.selected)},
				{"workspace.picker.count", fmt.tprintf("%d", workspace_picker_count(w))},
				{"workspace.picker.query", ui.field_string(&w.workspace_picker.query)},
				{"workspace.picker.rect", verify_workspace_rect(picker_rect)},
				{"workspace.picker.field", verify_workspace_rect(workspace_picker_field_rect(w))},
				{"workspace.picker.row", verify_workspace_rect(
					workspace_picker_row_rect(w, w.workspace_picker.selected))},
				{"workspace.picker.menu_target", fmt.tprintf("%d", workspace_picker_target(&w.workspace_picker, .Menu))},
				{"workspace.picker.menu_hover", fmt.tprintf("%d", w.workspace_picker.menu_hover)},
				{"workspace.picker.menu_selected", fmt.tprintf("%d", w.workspace_picker.menu_selected)},
				{"workspace.picker.window_enabled", fmt.tprintf("%t", workspace_row_window_enabled(app, w,
					workspace_picker_target(&w.workspace_picker, .Menu)))},
				{"workspace.picker.window_title", workspace_row_window_title(app,
					workspace_picker_target(&w.workspace_picker, .Menu))},
				{"workspace.picker.menu_button", verify_workspace_rect(workspace_picker_menu_button_rect(w,
					w.workspace_picker.selected))},
				{"workspace.picker.menu_item", verify_workspace_rect(workspace_row_menu_item_rect(w,
					w.workspace_picker.menu_selected))},
				{"workspace.picker.rename_target", fmt.tprintf("%d",
					workspace_picker_target(&w.workspace_picker, .Rename))},
				{"workspace.picker.rename_value", ui.field_string(&w.rename)},
				{"workspace.picker.rename_field", verify_workspace_rect(workspace_row_rename_field_rect(w))},
				{"workspace.picker.rename_error", fmt.tprintf("%t", workspace_picker_rename_error(&w.workspace_picker))},
				{"workspace.picker.icon_target", fmt.tprintf("%d", workspace_picker_target(&w.workspace_picker, .Icons))},
				{"window.preparing", fmt.tprintf("%t", w.phase == .Preparing)},
				{"pointer.shape", strings.to_lower(fmt.tprintf("%v", w.pointer_shape), context.temp_allocator)},
				{"pointer.updates", fmt.tprintf("%d", app.verify.pointer_updates)},
				{"link.hover", link_hover},
				{"link.uri", link_uri},
				{"link.spans", fmt.tprintf("%d", link_spans)},
				{"rail.new_tab", verify_workspace_rect(rail_new_tab_rect(w))},
				{"rail.profile", verify_workspace_rect(rail_profile_rect(w))},
				{"profile_menu.open", fmt.tprintf("%t", profile_menu_shown(w))},
				{"profile_menu.count", fmt.tprintf("%d", w.profile_menu.count)},
				{"documents.open", fmt.tprintf("%t", document_menu_shown(w))},
				{"documents.mode", verify_document_mode(w)},
				{"documents.count", fmt.tprintf("%d", w.document_menu.count)},
				{"documents.popout", fmt.tprintf("%t", verify_document_popout(w))},
				{"documents.url_open", fmt.tprintf("%t", verify_document_url_entry(w))},
				{"grid.cell", fmt.tprintf("%gx%g", w.metrics.cell_width, w.metrics.cell_height)},
				{"grid.padding", fmt.tprintf("%g", pane_padding(app, w.scale, entry))},
				{
					"session.process",
					entry != nil ? string(entry.process_name[:entry.process_name_length]) : "",
				},
				{"find.open", fmt.tprintf("%t", ui.find_is_open(&w.find))},
				{"find.focused", fmt.tprintf("%t", ui.find_has_keyboard(&w.find))},
				{"find.case_sensitive", fmt.tprintf("%t", w.find.case_sensitive)},
				{"find.regex", fmt.tprintf("%t", w.find.regex)},
				{"find.query", ui.field_string(&w.find.query)},
				{"find.matches", find_status(w, find_target(app, w))},
				{"find.count", verify_find_count(w, find_target(app, w))},
				{"find.older", verify_find_rect(w, find_target(app, w), .Up)},
				{"find.newer", verify_find_rect(w, find_target(app, w), .Down)},
				{"find.close", verify_find_rect(w, find_target(app, w), .Close)},
			}
			if _, err := append(&entries, ..window[:]); err != nil { return nil, .Out_Of_Memory }
			activity_rows, _ := status_panel_rows(app, w)
			activity_list := status_panel_list(app, w, status_panel_rect(app, w))
			for row, i in activity_rows {
				rect := verify_workspace_rect(status_panel_row_rect(w, activity_list, row))
				text := row.report ? status_item_name(app, row.item) : row.label
				row_state := [?]verify_protocol.State_Entry {
					{fmt.tprintf("activity.row.%d.rect", i), rect},
					{fmt.tprintf("activity.row.%d.report", i), fmt.tprintf("%t", row.report)},
					{fmt.tprintf("activity.row.%d.text", i), text},
					{fmt.tprintf("activity.row.%d.depth", i), fmt.tprintf("%d", row.depth)},
				}
				if _, err := append(&entries, ..row_state[:]); err != nil { return nil, .Out_Of_Memory }
			}
			for i in 0..<w.tab_menu.count {
				row := [?]verify_protocol.State_Entry{
					{fmt.tprintf("tab_menu.row.%d.label", i + 1), tab_menu_label(w, i)},
					{fmt.tprintf("tab_menu.row.%d.separator", i + 1), fmt.tprintf("%t", w.tab_menu.separators[i])},
					{fmt.tprintf("tab_menu.row.%d.enabled", i + 1), fmt.tprintf("%t", tab_menu_enabled(w, i))},
					{fmt.tprintf("tab_menu.row.%d.rect", i + 1), verify_workspace_rect(tab_menu_row_rect(w, i))},
				}
				if _, err := append(&entries, ..row[:]); err != nil { return nil, .Out_Of_Memory }
			}
			layout, layout_ok := rail_current_layout(w)
			if layout_ok {
				for row, i in w.rail_rows {
					rect := ui.rail_row_rect(layout, i)
					title := row.workspace.tabs[row.tab].title
					selected := row.tab == w.workspace.selected
					marked := row.workspace.tabs[row.tab].marked
					row_state := [?]verify_protocol.State_Entry{
						{fmt.tprintf("rail.row.%d.kind", i + 1), "tab"},
						{fmt.tprintf("rail.row.%d.title", i + 1), title},
						{fmt.tprintf("rail.row.%d.rect", i + 1), verify_workspace_rect(rect)},
						{fmt.tprintf("rail.row.%d.selected", i + 1), fmt.tprintf("%t", selected)},
						{fmt.tprintf("rail.row.%d.marked", i + 1), fmt.tprintf("%t", marked)},
						{fmt.tprintf("rail.row.%d.workspace", i + 1), fmt.tprintf("%d", row.workspace.id)},
						{fmt.tprintf("rail.row.%d.tab", i + 1), fmt.tprintf("%d", row.tab + 1)},
					}
					if _, err := append(&entries, ..row_state[:]); err != nil { return nil, .Out_Of_Memory }
				}
			}
		} else {
			hidden := [?]verify_protocol.State_Entry {
				{"window.id", "0"},
				{"window.origin", "0,0"},
				{"window.workspace_index", "0"},
				{"window.size", "0x0"},
				{"window.dpi", "0"},
				{"window.scale", "0"},
				{"window.focused", "false"},
			}
			if _, err := append(&entries, ..hidden[:]); err != nil {return nil, .Out_Of_Memory}
			if len(app.workspaces) > 0 {
				if tab := selected_tab(app.workspaces[0]); tab != nil {
					pane := tab.tree.nodes[tab.tree.focus].(layout.Pane)
					entry = workspace_session_for_content(app, pane.content)
				}
			}
		}
		empty: Workspace
		workspace := &empty
		if w != nil {
			workspace = w.workspace
			_, _ = rail_current_layout(w)
		} else if len(app.workspaces) > 0 {
			workspace = app.workspaces[0]
		}
		workspace_state := [?]verify_protocol.State_Entry {
			{"tabs.count", fmt.tprintf("%d", len(workspace.tabs))},
			{
				"tabs.selected",
				fmt.tprintf("%d", len(workspace.tabs) == 0 ? 0 : workspace.selected + 1),
			},
			{"sessions.count", fmt.tprintf("%d", len(app.sessions))},
		}
		if _, err := append(&entries, ..workspace_state[:]);
		   err != nil {return nil, .Out_Of_Memory}
		for tab, i in workspace.tabs {
			prefix := fmt.tprintf("tab.%d", i + 1)
			row_index := -1
			row_rect := render.Rect{}
			close_rect := render.Rect{}
			position := f32(i)
			strip_rect := render.Rect{}
			strip_close := render.Rect{}
			if w != nil {
				row_index = rail_row_index_for_tab(w.rail_rows[:], workspace, i)
				row_rect = rail_row_rect_for_tab(w, i)
				layout, _ := rail_current_layout(w)
				close_rect = ui.rail_close_rect(layout, row_index, w.scale)
				position = tab_position(w, i)
				strip_rect = window_tab_rect(app, w, i)
				strip_close = window_tab_close_rect(app, w, i)
			}
			tab_state := [?]verify_protocol.State_Entry {
				{fmt.tprintf("%s.id", prefix), fmt.tprintf("%d", tab.id)},
				{fmt.tprintf("%s.marked", prefix), fmt.tprintf("%t", tab.marked)},
				{fmt.tprintf("%s.position", prefix), fmt.tprintf("%g", position)},
				{fmt.tprintf("%s.rail_row", prefix), fmt.tprintf("%d", row_index)},
				{fmt.tprintf("%s.rect", prefix), verify_workspace_rect(row_rect)},
				{fmt.tprintf("%s.close", prefix), verify_workspace_rect(close_rect)},
				{fmt.tprintf("%s.strip_rect", prefix), verify_workspace_rect(strip_rect)},
				{fmt.tprintf("%s.strip_close", prefix), verify_workspace_rect(strip_close)},
				{fmt.tprintf("%s.focus", prefix), fmt.tprintf("%d", tab.tree.focus)},
				{fmt.tprintf("%s.title", prefix), tab.title},
				{fmt.tprintf("%s.zoomed", prefix), fmt.tprintf("%t", tab.tree.zoomed)},
			}
			if _, err := append(&entries, ..tab_state[:]); err != nil {return nil, .Out_Of_Memory}
			count := 0
			for node, n in tab.tree.nodes {
				if pane, ok := node.(layout.Pane); ok {
					count += 1
					if session := workspace_session_for_content(app, pane.content); session != nil {
						g := term.geometry(session.session)
						if _, err := append(
							&entries,
							verify_protocol.State_Entry {
								fmt.tprintf("%s.pane.%d.grid", prefix, n),
								fmt.tprintf("%dx%d", g.columns, g.rows),
							},
						); err != nil {return nil, .Out_Of_Memory}
						if _, err := append(
							&entries,
							verify_protocol.State_Entry {
								fmt.tprintf("%s.pane.%d.keep_open", prefix, n),
								fmt.tprintf("%t", session.keep_open),
							},
						); err != nil {return nil, .Out_Of_Memory}
					}
					if _, err := append(
						&entries,
						verify_protocol.State_Entry {
							fmt.tprintf("%s.pane.%d.session", prefix, n),
							fmt.tprintf("%d", pane.content.id),
						},
					); err != nil {return nil, .Out_Of_Memory}
					if floating, floated := layout.float_of(&tab.tree, layout.Node_Id(n)); floated {
						b := floating.bounds
						floating_state := [?]verify_protocol.State_Entry {
							{
								fmt.tprintf("%s.pane.%d.float", prefix, n),
								fmt.tprintf("%g,%g,%g,%g", b.x, b.y, b.width, b.height),
							},
							{
								fmt.tprintf("%s.pane.%d.minimized", prefix, n),
								fmt.tprintf("%t", floating.minimized),
							},
						}
						if _, err := append(&entries, ..floating_state[:]); err != nil {
							return nil, .Out_Of_Memory
						}
					}
				}
			}
			shown_floats, minimized_floats := layout.float_counts(&tab.tree)
			tab_floats := [?]verify_protocol.State_Entry {
				{fmt.tprintf("%s.panes", prefix), fmt.tprintf("%d", count)},
				{fmt.tprintf("%s.floating", prefix), fmt.tprintf("%d", shown_floats)},
				{fmt.tprintf("%s.minimized", prefix), fmt.tprintf("%d", minimized_floats)},
			}
			if _, err := append(&entries, ..tab_floats[:]); err != nil {return nil, .Out_Of_Memory}
		}
		if w != nil {
			drag := drag_report(w)
			tab_thumbnail, pane_thumbnail: Drag_Thumbnail
			if drag.tab {tab_thumbnail = drag.thumbnail}
			if drag.pane {pane_thumbnail = drag.thumbnail}
			pane_state := [?]verify_protocol.State_Entry {
				{"panes.count", fmt.tprintf("%d", len(window_tiled_rects(w)))},
				{"panes.floating", fmt.tprintf("%d", len(floating_rects(w)))},
				{"panes.capsules", fmt.tprintf("%d", len(floating_capsules(w)))},
				{
					"panes.capsule_group",
					fmt.tprintf(
						"%g,%g,%g,%g",
						w.float_capsule_group.x,
						w.float_capsule_group.y,
						w.float_capsule_group.width,
						w.float_capsule_group.height,
					),
				},
				{"panes.focused", fmt.tprintf("%d", w.tree.focus)},
				{"panes.gap", fmt.tprintf("%g", window_gap(app, w))},
				{"panes.header_height", fmt.tprintf("%g", w.header_height)},
				{"panes.split_overlay", fmt.tprintf("%t", w.split_overlay)},
				{"panes.dragging", fmt.tprintf("%t", drag.pane)},
				{"panes.float_dragging", fmt.tprintf("%t", floating_dragging(w))},
				{
					"panes.float_header_hover",
					fmt.tprintf("%v", (w.float_header_hover.? or_else Float_Header_Spot{}).action),
				},
				{"panes.float_header_hover_value", fmt.tprintf("%g", w.float_header_motion.hover.value)},
				{"panes.float_header_press_value", fmt.tprintf("%g", w.float_header_motion.press.value)},
				{"tabs.dragging", fmt.tprintf("%t", drag.tab)},
				{"tabs.drop.new_window", fmt.tprintf("%t", drag.tab && drag.tear_off)},
				{"tabs.drop.preview_window", fmt.tprintf("%d", drag.tab ? drag.preview : 0)},
				{"tabs.drop.window", fmt.tprintf("%d", drag.tab ? drag.window : 0)},
				{"tabs.incoming.count", fmt.tprintf("%d", w.tab_incoming.count)},
				{"tabs.incoming.slot", fmt.tprintf("%d", w.tab_incoming.slot)},
				{"tabs.drop.thumbnail", fmt.tprintf("%t", drag.tab && drag.thumbnail.shown)},
				{
					"tabs.drop.thumbnail_size",
					fmt.tprintf("%dx%d", tab_thumbnail.width, tab_thumbnail.height),
				},
				{"panes.drop.shown", fmt.tprintf("%t", drag.shown)},
				{"panes.drop.root", fmt.tprintf("%t", drag.root)},
				{"panes.drop.new_tab", fmt.tprintf("%t", drag.new_tab)},
				{"panes.drop.new_window", fmt.tprintf("%t", drag.pane && drag.tear_off)},
				{"panes.drop.window", fmt.tprintf("%d", drag.tab ? 0 : drag.window)},
				{"panes.drop.preview_window", fmt.tprintf("%d", drag.pane ? drag.preview : 0)},
				{"panes.drop.thumbnail", fmt.tprintf("%t", drag.pane && drag.thumbnail.shown)},
				{
					"panes.drop.thumbnail_size",
					fmt.tprintf("%dx%d", pane_thumbnail.width, pane_thumbnail.height),
				},
				{
					"panes.drop.rect",
					fmt.tprintf("%g,%g,%g,%g", drag.ghost[0], drag.ghost[1], drag.ghost[2], drag.ghost[3]),
				},
			}
			if _, err := append(&entries, ..pane_state[:]); err != nil {return nil, .Out_Of_Memory}
			for view in w.views {
				if !pane_owns_session(view.content.kind) {continue}
				if _, err := append(
					&entries,
					verify_protocol.State_Entry {
						fmt.tprintf("session.%d.builds", view.content.id),
						fmt.tprintf("%d", view.builds),
					},
				); err != nil {return nil, .Out_Of_Memory}
			}
			for pane in w.panes {
				r := pane.rect
				if _, err := append(
					&entries,
					verify_protocol.State_Entry {
						fmt.tprintf("pane.%d.rect", pane.node),
						fmt.tprintf("%g,%g,%g,%g", r.x, r.y, r.width, r.height),
					},
				); err != nil {return nil, .Out_Of_Memory}
			}
		}
		if entry != nil {
			s := entry.session
			g := term.geometry(s)
			status := term.status(s)
			bar, bar_ok := term.scrollbar(s)
			if !bar_ok {return nil, .System}
			up := bar.total - min(bar.total, bar.offset + bar.len)
			selection := "none"
			if term.has_selection(s) {
				text, ok := term.selection_text(s, context.temp_allocator)
				if !ok {return nil, .System}
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
			session := [?]verify_protocol.State_Entry {
				{"session.id", fmt.tprintf("%d", entry.id)},
				{"session.message", session_message(status)},
				{"grid.size", fmt.tprintf("%dx%d", g.columns, g.rows)},
				{
					"session.status",
					strings.to_lower(fmt.tprintf("%v", status.kind), context.temp_allocator),
				},
				{"session.exit", fmt.tprintf("%d", status.exit_code)},
				{"session.title", term.title(s, context.temp_allocator)},
				{"session.header.title", pane_header_title(&entry.header)},
				{"session.profile", entry.profile_id},
				{"session.name", entry.name},
				{"session.command", program.command},
				{"session.program", program.path},
				{"session.program.name", program.name},
				{"session.program.source", verify_program_source(app, entry)},
				{"session.program.icon", fmt.tprintf("%t", verify_program_icon(app, entry))},
				{"session.header.directory", entry.header.directory},
				{
					"session.header.icon",
					app.shell_icon.width > 0 ? settings.profile_base(&app.settings.profiles).icon : entry.header.icon,
				},
				{"grid.origin", fmt.tprintf("%d,%d", g.padding_left, g.padding_top)},
				{"session.viewport", up == 0 ? "bottom" : fmt.tprintf("up:%d", up)},
				{"session.selection", selection},
				{"session.mouse", fmt.tprintf("%t", term.mouse_tracking(s))},
				{"session.generation", fmt.tprintf("%d", term.generation(s))},
			}
			if _, err := append(&entries, ..session[:]); err != nil {return nil, .Out_Of_Memory}
			if w == nil {
				grid := [?]verify_protocol.State_Entry {
					{"grid.cell", fmt.tprintf("%dx%d", g.cell_width, g.cell_height)},
					{"grid.padding", fmt.tprintf("%d", g.padding_left)},
				}
				if _, err := append(&entries, ..grid[:]); err != nil {return nil, .Out_Of_Memory}
			}
		}
		if _, err := append(&entries, verify_protocol.State_Entry{
			"notices.window", fmt.tprintf("%d", app.notice_window),
		}); err != nil {return nil, .Out_Of_Memory}
		for n in ui.notices_live(&app.notices) {
			left := "sticky"
			if expires, timed := ui.notice_expiry(n).?; timed {
				remaining := max(i64(0), i64(time.tick_diff(time.tick_now(), expires) / time.Millisecond))
				left = fmt.tprintf("%dms", remaining)
			}
			key := fmt.tprintf("notice.%s", verify_notice_key(n.key))
			kind := strings.to_lower(fmt.tprintf("%v", n.kind), context.temp_allocator)
			value := fmt.tprintf("%s: %s (%s)", kind, n.text, left)
			if _, err := append(&entries, verify_protocol.State_Entry{key, value}); err != nil {
				return nil, .Out_Of_Memory
			}
		}
		return entries[:], .None
	}

	// Hover state and the link count are enough to prove the interaction from a control journey
	// without reading pixels: the range and target name the cells under the pointer, and the
	// cursor shape is what the OS was asked to show.
	verify_link_hover :: proc(w: ^Window) -> (hover, uri: string, spans: int) {
		hover = "none"
		for &view in w.views {spans += term.link_span_count(&view.links)}
		link, ok := w.link_hover.?
		if !ok {return}
		view := pane_view(w, link.content)
		if view == nil {return}
		range := link.range
		hover = fmt.tprintf(
			"%d,%d-%d,%d",
			range.first_row,
			range.first_column,
			range.last_row,
			range.last_column,
		)
		if _, target, found := term.link_at(&view.links, range.first_column, range.first_row); found {
			uri = target
		}
		return
	}

	verify_find_count :: proc(w: ^Window, target: Find_Target) -> string {
		label, _ := find_presentation(w, target)
		return label
	}

	// Retain the original matches field for existing control journeys.
	find_status :: proc(w: ^Window, target: Find_Target) -> string {
		s, ok := find_target_summary(target)
		if !ok || len(w.find.query.bytes) == 0 { return "" }
		switch {
		case s.selected >= 0: return fmt.tprintf("%d of %d", s.selected + 1, s.total)
		case s.total == 1: return "1 match"
		case s.total > 0: return fmt.tprintf("%d matches", s.total)
		case s.progress == .Searching: return "Searching…"
		}
		return "No matches"
	}

	verify_find_rect :: proc(w: ^Window, searched: Find_Target, target: ui.Find_Outcome) -> string {
		if !ui.find_is_open(&w.find) { return "" }
		l, _ := find_controls(w, searched)
		#partial switch target {
		case .Up: return verify_workspace_rect(l.up)
		case .Down: return verify_workspace_rect(l.down)
		}
		return verify_workspace_rect(l.close)
	}

	verify_workspace_rect :: proc(r: render.Rect) -> string {
		return fmt.tprintf("%g,%g,%g,%g", r.x, r.y, r.width, r.height)
	}

	verify_chip_name_error :: proc(w: ^Window) -> bool {
		chip, _ := w.overlay.(Overlay_Chip_Name)
		return chip.error
	}

	verify_editor_profile_menu_open :: proc(w: ^Window) -> bool {
		_, open := w.editor.mode.(ui.Editor_Profile_Menu)
		return open
	}

	verify_document_popout :: proc(w: ^Window) -> bool {
		_, shown := document_menu_popout(w)
		return shown
	}

	verify_document_url_entry :: proc(w: ^Window) -> bool {
		_, shown := document_menu_url_entry(w)
		return shown
	}

	// list, pin or link; empty while the menu is closed.
	verify_document_mode :: proc(w: ^Window) -> string {
		state, shown := w.overlay.(Overlay_Document_Menu)
		if !shown {return ""}
		switch _ in state.mode {
		case Document_Menu_List: return "list"
		case Document_Menu_Pin: return "pin"
		case Document_Menu_Link: return "link"
		}
		return ""
	}

	verify_process_rows :: proc(w: ^Window, page: ui.Editor_Layout) -> string {
		builder := strings.builder_make(context.temp_allocator)
		first := true
		for item, index in w.editor.items {
			if item.row < 0 {continue}
			row := &w.editor.rows[item.row]
			if row.process_field == .None {continue}
			r := ui.editor_row_parts(&w.editor, page, index).row
			if !first {strings.write_byte(&builder, ';')}
			first = false
			strings.write_string(&builder,
				fmt.tprintf("%s@%g,%g,%g,%g", row.key, r.x, r.y, r.width, r.height))
		}
		return strings.to_string(builder)
	}

	// One table row per item as id@x,y,w,h, so a live journey can aim a drag at the grip.
	verify_profile_rows :: proc(
		w: ^Window,
		page: ui.Editor_Layout,
		kind: ui.Row_Kind,
	) -> string {
		builder := strings.builder_make(context.temp_allocator)
		first := true
		for item, index in w.editor.items {
			if item.row < 0 {continue}
			row := &w.editor.rows[item.row]
			if row.kind != kind {continue}
			if !first {strings.write_byte(&builder, ';')}
			first = false
			rect := ui.editor_row_parts(&w.editor, page, index).row
			strings.write_string(
				&builder,
				fmt.tprintf(
					"%s@%g,%g,%g,%g",
					row.profile,
					rect.x,
					rect.y,
					rect.width,
					rect.height,
				),
			)
		}
		return strings.to_string(builder)
	}

	verify_detected_count :: proc(app: ^App) -> string {
		count := 0
		for &profile in app.settings.profiles.items {
			if profile.detected {count += 1}
		}
		return fmt.tprintf("%d", count)
	}

	verify_profile_group :: proc(p: ^ui.Editor) -> int {
		for group, index in p.groups {
			if group.title == "Profiles" {return index}
		}
		return -1
	}

	verify_workspace_index :: proc(app: ^App, w: ^Window) -> int {
		for workspace, i in app.workspaces {
			if workspace == w.workspace {return i + 1}
		}
		return 0
	}

	// Current pages report draft when they hold pending work, derived rather than stored.
	verify_settings_revision :: proc(p: ^ui.Editor) -> string {
		switch r in p.revision {
		case ui.Editor_Current:
			return ui.editor_draft(p) ? "draft" : "fresh"
		case ui.Editor_Stale:
			switch r.reason {
			case .Changed_Outside:
				return "stale.changed_outside"
			case .Draft_Conflict:
				return "stale.draft_conflict"
			case .Refresh_Failed:
				return "stale.refresh_failed"
			}
		}
		return "closed"
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
		entry := focused_session(app, w)
		if entry == nil {return {}, false}
		g := term.geometry(entry.session)
		point, ok := term.cell_center(g, p.x, p.y)
		return point, ok
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
					delta_y = f32(m.lines) / WHEEL_LINES,
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
			for step in 1 ..= 4 {
				x := pos.x + i32((i64(end.x) - i64(pos.x)) * i64(step) / 4)
				y := pos.y + i32((i64(end.y) - i64(pos.y)) * i64(step) / 4)
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
					now + 5,
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
			desired, width, height := pane_box_for_grid(
				app,
				w.scale,
				w.metrics,
				u16(r.columns),
				u16(r.rows),
				insets,
				w.rail_width > 0 ? w.rail_width : f32(app.settings.tabs.rail_width),
			)
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
		for key in CHANGED_KEYS {
			a, b := verify_value(d.before_state, key), verify_value(entries, key)
			if a == b {continue}
			value := strings.builder_make(context.temp_allocator)
			if err := verify_protocol.format_value(&value, b); err != .None {return "", err}
			change := fmt.tprintf("%s=%s", key, strings.to_string(value))
			if key == "window.visible" {change = b == "true" ? "window shown" : "window hidden"}
			if key == "palette.open" {change = b == "true" ? "palette opened" : "palette closed"}
			if key == "find.open" {change = b == "true" ? "find opened" : "find closed"}
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
			   time.tick_diff(quitting.started, now) >= time.Second {
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
	// Whether the pane's program has an icon ready to draw at any size, from whichever source.
	verify_program_icon :: proc(app: ^App, entry: ^Session_Entry) -> bool {
		program := program_adopted(entry)
		if program == nil || program.name == "" {return false}
		file, has_file := program_named_file(app, program.name, program.art, program.has_art)
		art := program.has_art ? program_art.canonical(program.art) : ""
		for icon in app.processes.icons {
			if icon.state != .Ready {continue}
			switch icon.source {
			case .File:
				if has_file && icon.path == file {return true}
			case .Artwork:
				if art != "" && icon.path == art {return true}
			case .Executable:
				if program.path != "" && icon.path == program.path {return true}
			}
		}
		return false
	}
	verify_program_source :: proc(app: ^App, entry: ^Session_Entry) -> string {
		program := program_adopted(entry)
		if program == nil || program.name == "" {return ""}
		source, _, _, found := program_icon_source(app, program, 16)
		return found ? strings.to_lower(fmt.tprintf("%v", source), context.temp_allocator) : ""
	}
} else {
	Verify :: struct {}
	verify_start :: proc(_: ^App) {}
	verify_destroy :: proc(_: ^App) {}
	verify_presented :: proc(_: ^App, _: ^Window) {}
	verify_tick :: proc(_: ^App) {}
	verify_deadline :: proc(_: ^App) -> (time.Tick, bool) {return {}, false}
}
