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
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// These imports are used only when AIO_CONTROL is set.
_ :: fmt
_ :: log
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
_ :: settings

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
		pending: ^control.Message,
		started, changed: time.Tick,
		generation, frames, request_frame: u64,
		pointer_updates: u64,
		session_id: u32,
		phase: Verify_Phase,
		needs_frame, presented: bool,
		quit_id: u64,
		quit_started: time.Tick,
		before: term.Snapshot,
		before_state: []control.State_Entry,
		presents: [dynamic]Verify_Present,
		mouse_window: platform.Window_Id,
		target_window: platform.Window_Id,
		buttons: input.Mouse_Buttons,
	}

	Verify_Present :: struct {
		id: platform.Window_Id,
		surface: ^render.Surface,
		count: u32,
	}

	Verify_Phase :: enum {
		Read,
		Wait,
		Start_Drive,
		Finish_Drive,
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

	verify_clear :: proc(v: ^Verify) {
		control.message_destroy(v.pending)
		v.pending = nil
		term.snapshot_destroy(&v.before)
		for entry in v.before_state {
			delete(entry.key)
			delete(entry.value)
		}
		delete(v.before_state)
		v.before_state = nil
		v.phase, v.needs_frame = .Read, false
	}

	verify_destroy :: proc(app: ^App) {
		v := &app.verify
		control.destroy(v.server)
		verify_clear(v)
		delete(v.presents)
		v^ = {}
	}

	verify_window :: proc(app: ^App) -> ^Window {
		if app.verify.target_window != 0 {
			if w := window_find(app, app.verify.target_window); w != nil {return w}
			app.verify.target_window = 0
			app.verify.mouse_window, app.verify.buttons = 0, {}
		}
		for w in app.windows {
			if w.focused {return w}
		}
		return len(app.windows) > 0 ? app.windows[0] : nil
	}

	verify_presented :: proc(app: ^App, w: ^Window) {
		if w.surface == nil {return}
		count, err := render.surface_present_count(w.surface)
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
			previous := p.surface == w.surface ? p.count : 0
			if count == previous {w.dirty = true}
			if verify_window(app) == w {
				v.presented ||= count != previous
				v.frames += u64(count >= previous ? count - previous : count)
			}
			p.surface, p.count = w.surface, count
			return
		}
		if _, err := append(&v.presents, Verify_Present{w.id, w.surface, count}); err != nil {
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
		if v.quit_id != 0 {
			return time.tick_add(now, 10 * time.Millisecond), true
		}
		if v.pending == nil {return {}, false}
		for w in app.windows {
			if w.dirty && w.width > 0 && w.height > 0 {return now, true}
		}
		deadline := time.tick_add(
			v.started,
			time.Duration(verify_timeout(v.pending.request)) * time.Millisecond,
		)
		idle_ms := -1
		#partial switch r in v.pending.request {
		case control.Wait:
			if r.kind == .Idle {idle_ms = r.idle_ms}
		case control.Run:
			if v.phase == .Finish_Drive {idle_ms = r.idle_ms}
		case:
			if v.phase == .Finish_Drive {
				idle_ms = 50
				if _, resize := v.pending.request.(control.Resize); !resize {
					deadline = time.tick_add(v.started, time.Second)
				}
			}
		}
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
		control.Error,
	) {
		w := verify_window(app)
		if w == nil {return {}, .Invalid_Argument}
		entry := focused_session(app, w)
		if entry == nil {return {}, .Invalid_Argument}
		for pane in w.views {
			if pane.content.id != entry.id {continue}
			allocator := persistent ? context.allocator : context.temp_allocator
			snapshot, err := term.snapshot(pane.view.state, allocator)
			if err != .None {
				return {}, err == .Out_Of_Memory ? .Out_Of_Memory : .System
			}
			return snapshot, .None
		}
		return {}, .Invalid_Argument
	}

	verify_value :: proc(entries: []control.State_Entry, key: string) -> string {
		for entry in entries {
			if entry.key == key {return entry.value}
		}
		return ""
	}

	verify_timeout :: proc(request: control.Request) -> int {
		#partial switch r in request {
		case control.Wait:
			return r.timeout_ms
		case control.Run:
			return r.timeout_ms
		}
		return 5000
	}

	verify_needs_window :: proc(request: control.Request) -> bool {
		#partial switch r in request {
		case control.Ping, control.Help, control.State, control.Perf:
			return false
		case control.Tray:
			return r.action == .Hide
		case control.Expect:
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
	verify_state :: proc(app: ^App) -> ([]control.State_Entry, control.Error) {
		w := verify_window(app)
		owns_palette := w != nil && app.palette_window == w.id
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
		entries := make([dynamic]control.State_Entry, context.temp_allocator)
		base := [?]control.State_Entry {
			{"app.pid", fmt.tprintf("%d", os.get_pid())},
			{"app.app", app.app_id},
			{"app.build", AIO_BUILD_ID},
			{"app.build_kind", AIO_BUILD_KIND},
			{"app.data", app.options.data_dir == "" ? "default" : app.options.data_dir},
			{"app.settings", app.settings_path},
			{"app.log", app.log_path},
			{"window.visible", fmt.tprintf("%t", len(app.windows) > 0)},
			{"windows.count", fmt.tprintf("%d", len(app.windows))},
			{"palette.window", fmt.tprintf("%d", app.palette_window)},
			{"palette.open", fmt.tprintf("%t", palette_active(app, w))},
			{"palette.query", owns_palette ? ui.palette_query(p) : ""},
			{"palette.mode", owns_palette ? ui.palette_mode_word(p.mode) : "all"},
			{"palette.chip", owns_palette ? ui.palette_mode_prefix(p.mode) : ""},
			{"palette.selected", fmt.tprintf("%d", owns_palette ? p.selected : 0)},
			{"palette.items", fmt.tprintf("%d", owns_palette ? len(p.results) : 0)}, {"palette.item", item},
			{"palette.scroll", fmt.tprintf("%d", owns_palette ? p.scroll : 0)},
			{"palette.rows", fmt.tprintf("%d", palette_layout.rows)},
			{"palette.row_height", fmt.tprintf("%g", palette_layout.row_height)},
			{"palette.panel", fmt.tprintf("%g,%g,%g,%g", palette_layout.panel.x, palette_layout.panel.y,
				palette_layout.panel.width, palette_layout.panel.height)},
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
			{"shell.icon.loaded", fmt.tprintf("%t", app.shell_icon.width > 0)},
			{"ui.animating", fmt.tprintf("%t", motion_active(app))},
			{"leader.enabled", fmt.tprintf("%t", app.leader != nil)},
			{"workspaces.count", fmt.tprintf("%d", len(app.workspaces))},
		}
		if _, err := append(&entries, ..base[:]); err != nil {return nil, .Out_Of_Memory}
		origin: [2]i32
		for window, i in app.windows {
			x, y, err := platform.window_to_screen(&app.platform, window.id, 0, 0)
			if err != .None {return nil, .System}
			if window == w {origin = {x, y}}
			prefix := fmt.tprintf("window.%d", i + 1)
			inventory := [?]control.State_Entry {
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
				{fmt.tprintf("%s.preparing", prefix), fmt.tprintf("%t", window.preparing)},
				{
					fmt.tprintf("%s.preview_visible", prefix),
					fmt.tprintf("%t", window.preview_visible),
				},
			}
			if _, err := append(&entries, ..inventory[:]); err != nil {return nil, .Out_Of_Memory}
		}
		entry: ^Session_Entry
		if w != nil {
			entry = focused_session(app, w)
			editor_key := ""
			editor_title := ""
			if row := ui.editor_row(&w.editor);
			   row != nil {editor_key, editor_title = row.key, row.title}
			confirm := pending_close_text(app, &w.pending_close, w.workspace)
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
			window := [?]control.State_Entry {
				{"window.id", fmt.tprintf("%d", w.id)},
				{"window.origin", fmt.tprintf("%d,%d", origin.x, origin.y)},
				{"window.pointer", fmt.tprintf("%g,%g", w.pointer.x, w.pointer.y)},
				{"theme.hover_lift", fmt.tprintf("%g", app.theme.hover_lift)},
				{"theme.hover_gloss", fmt.tprintf("%g", app.theme.hover_gloss)},
				{"window.workspace_index", fmt.tprintf("%d", verify_workspace_index(app, w))},
				{"settings.open", fmt.tprintf("%t", w.editor.open)},
				{"rename.open", fmt.tprintf("%t", w.rename_open)},
				{"rename.value", ui.field_string(&w.rename)},
				{"tab_menu.open", fmt.tprintf("%t", w.tab_menu.open)},
				{"tab_menu.count", fmt.tprintf("%d", w.tab_menu.count)},
				{"tab_menu.action", fmt.tprintf("%v", w.tab_menu.actions[w.tab_menu.selected])},
				{"settings.filter", string(w.editor.filter.bytes[:])},
				{"settings.scroll", fmt.tprintf("%d", w.editor.scroll)},
				{"settings.group", fmt.tprintf("%d", ui.editor_active_group(&w.editor))},
				{"settings.key", editor_key},
				{"settings.value", string(w.editor.value.bytes[:])},
				{"settings.editing", fmt.tprintf("%t", ui.editor_editing(&w.editor))},
				{"settings.active", fmt.tprintf("%t", settings_active(w))},
				{"settings.popup", fmt.tprintf("%v", w.editor.popup)},
				{"settings.capturing", fmt.tprintf("%t", w.editor.capturing)},
				{"settings.title", editor_title},
				{"settings.message", w.editor.message},
				{"settings.error", fmt.tprintf("%t", w.editor.error)},
				{"settings.profile.expanded", w.editor.expanded},
				{"settings.profile.default", app.settings.profiles.default_id},
				{"settings.profile.detected_open", fmt.tprintf("%t", w.editor.detected_open)},
				{"settings.profile.removing", w.editor.remove_confirm},
				{"settings.profile.action", fmt.tprintf("%v", w.editor.action)},
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
				{"settings.profile.dragging", fmt.tprintf("%t", w.editor.drag == .Profile_Order)},
				{"settings.profile.drag_target", fmt.tprintf("%d", w.editor.drag_target)},
				{"settings.profile.drag_id", w.editor.drag_id},
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
				{"leader.pending", fmt.tprintf("%t", w.leader_until != {})},
				{"confirm.open", fmt.tprintf("%t", w.pending_close.confirm.open)},
				{"confirm.opacity", fmt.tprintf("%g", w.pending_close.confirm.motion.value)},
				{"confirm.title", w.pending_close.confirm.open ? confirm.title : ""},
				{"confirm.body", w.pending_close.confirm.open ? confirm.body : ""},
				{"confirm.workspace", fmt.tprintf("%d", w.pending_close.workspace)},
				{"swap.open", fmt.tprintf("%t", w.pending_swap.confirm.open)},
				{"swap.opacity", fmt.tprintf("%g", w.pending_swap.confirm.motion.value)},
				{"swap.profile", w.pending_swap.profile_id},
				{"leader.indicator", w.leader_until != {} ? "pane-status-line" : "none"},
				{"window.size", fmt.tprintf("%dx%d", w.width, w.height)},
				{"window.dpi", fmt.tprintf("%d", u32(w.scale * 96))},
				{"window.scale", fmt.tprintf("%g", w.scale)},
				{"window.focused", fmt.tprintf("%t", w.focused)},
				{"window.maximized", fmt.tprintf("%t", w.maximized)},
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
				{"rail.resizing", fmt.tprintf("%t", w.rail_resizing)},
				{"rail.overlay", fmt.tprintf("%t", rail_overlay(w))},
				{"rail.scroll", fmt.tprintf("%g", w.rail_scroll)},
				{"rail.slide", fmt.tprintf("%g", w.rail_slide.value)},
				{"rail.rows", fmt.tprintf("%d", len(w.rail_rows))},
				{"rail.row.height", fmt.tprintf("%g", ui.RAIL_ROW_HEIGHT * w.scale)},
				{"rail.toggle", verify_workspace_rect(tab_orientation_button_rect(w))},
				{"tabs.orientation_button", verify_workspace_rect(tab_orientation_button_rect(w))},
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
				{"workspace.picker.colors", fmt.tprintf("%t", (w.workspace_picker.mode == .Tint))},
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
				{"workspace.picker.rename_error", fmt.tprintf("%t", w.workspace_picker.rename_error)},
				{"workspace.picker.icon_target", fmt.tprintf("%d", workspace_picker_target(&w.workspace_picker, .Icons))},
				{"window.preparing", fmt.tprintf("%t", w.preparing)},
				{"window.preview_visible", fmt.tprintf("%t", w.preview_visible)},
				{"pointer.shape", strings.to_lower(fmt.tprintf("%v", w.pointer_shape), context.temp_allocator)},
				{"pointer.updates", fmt.tprintf("%d", app.verify.pointer_updates)},
				{"link.hover", link_hover},
				{"link.uri", link_uri},
				{"link.spans", fmt.tprintf("%d", link_spans)},
				{"rail.new_tab", verify_workspace_rect(rail_new_tab_rect(w))},
				{"rail.profile", verify_workspace_rect(rail_profile_rect(w))},
				{"profile_menu.open", fmt.tprintf("%t", w.profile_menu.open)},
				{"profile_menu.count", fmt.tprintf("%d", w.profile_menu.count)},
				{"grid.cell", fmt.tprintf("%gx%g", w.metrics.cell_width, w.metrics.cell_height)},
				{"grid.padding", fmt.tprintf("%g", pane_padding(app, w.scale, entry))},
				{
					"session.process",
					entry != nil ? string(entry.process_name[:entry.process_name_length]) : "",
				},
				{"find.open", fmt.tprintf("%t", w.find.open)},
				{"find.query", ui.field_string(&w.find.query)},
				{"find.matches", find_status(w, entry)},
				{"find.count", verify_find_count(w, entry)},
				{"find.older", verify_find_rect(w, entry, true)},
				{"find.newer", verify_find_rect(w, entry, false)},
			}
			if _, err := append(&entries, ..window[:]); err != nil { return nil, .Out_Of_Memory }
			for i in 0..<w.tab_menu.count {
				row := [?]control.State_Entry{
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
					row_state := [?]control.State_Entry{
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
			hidden := [?]control.State_Entry {
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
					entry = session_find(app, pane.content.id)
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
		workspace_state := [?]control.State_Entry {
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
			tab_state := [?]control.State_Entry {
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
					if session := session_find(app, pane.content.id); session != nil {
						g := term.geometry(session.session)
						if _, err := append(
							&entries,
							control.State_Entry {
								fmt.tprintf("%s.pane.%d.grid", prefix, n),
								fmt.tprintf("%dx%d", g.columns, g.rows),
							},
						); err != nil {return nil, .Out_Of_Memory}
						if _, err := append(
							&entries,
							control.State_Entry {
								fmt.tprintf("%s.pane.%d.keep_open", prefix, n),
								fmt.tprintf("%t", session.keep_open),
							},
						); err != nil {return nil, .Out_Of_Memory}
					}
					if _, err := append(
						&entries,
						control.State_Entry {
							fmt.tprintf("%s.pane.%d.session", prefix, n),
							fmt.tprintf("%d", pane.content.id),
						},
					); err != nil {return nil, .Out_Of_Memory}
				}
			}
			if _, err := append(
				&entries,
				control.State_Entry{fmt.tprintf("%s.panes", prefix), fmt.tprintf("%d", count)},
			); err != nil {return nil, .Out_Of_Memory}
		}
		if w != nil {
			pane_state := [?]control.State_Entry {
				{"panes.count", fmt.tprintf("%d", len(w.panes))},
				{"panes.focused", fmt.tprintf("%d", w.tree.focus)},
				{"panes.gap", fmt.tprintf("%g", window_gap(app, w))},
				{"panes.header_height", fmt.tprintf("%g", w.header_height)},
				{"panes.split_overlay", fmt.tprintf("%t", w.split_overlay)},
				{"panes.dragging", fmt.tprintf("%t", w.pane_drag.active)},
				{"tabs.dragging", fmt.tprintf("%t", w.tab_drag.active)},
				{"panes.drop.shown", fmt.tprintf("%t", w.pane_drag.shown)},
				{"panes.drop.root", fmt.tprintf("%t", w.pane_drag.root)},
				{"panes.drop.new_tab", fmt.tprintf("%t", w.pane_drag.new_tab)},
				{"panes.drop.new_window", fmt.tprintf("%t", w.pane_drag.new_window)},
				{"panes.drop.window", fmt.tprintf("%d", w.pane_drag.destination_window)},
				{"panes.drop.preview_window", fmt.tprintf("%d", w.pane_drag.preview_window)},
				{
					"panes.drop.rect",
					fmt.tprintf(
						"%g,%g,%g,%g",
						w.pane_drag.ghost[0].target,
						w.pane_drag.ghost[1].target,
						w.pane_drag.ghost[2].target,
						w.pane_drag.ghost[3].target,
					),
				},
			}
			if _, err := append(&entries, ..pane_state[:]); err != nil {return nil, .Out_Of_Memory}
			for view in w.views {
				if _, err := append(
					&entries,
					control.State_Entry {
						fmt.tprintf("session.%d.builds", view.content.id),
						fmt.tprintf("%d", view.builds),
					},
				); err != nil {return nil, .Out_Of_Memory}
			}
			for pane in w.panes {
				r := pane.rect
				if _, err := append(
					&entries,
					control.State_Entry {
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
			session := [?]control.State_Entry {
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
				{"session.header.directory", entry.header.directory},
				{
					"session.header.icon",
					app.shell_icon.width > 0 ? app.settings.shell.icon : entry.header.icon,
				},
				{"grid.origin", fmt.tprintf("%d,%d", g.padding_left, g.padding_top)},
				{"session.viewport", up == 0 ? "bottom" : fmt.tprintf("up:%d", up)},
				{"session.selection", selection},
				{"session.mouse", fmt.tprintf("%t", term.mouse_tracking(s))},
				{"session.generation", fmt.tprintf("%d", term.generation(s))},
			}
			if _, err := append(&entries, ..session[:]); err != nil {return nil, .Out_Of_Memory}
			if w == nil {
				grid := [?]control.State_Entry {
					{"grid.cell", fmt.tprintf("%dx%d", g.cell_width, g.cell_height)},
					{"grid.padding", fmt.tprintf("%d", g.padding_left)},
				}
				if _, err := append(&entries, ..grid[:]); err != nil {return nil, .Out_Of_Memory}
			}
		}
		for n in app.notices.items {
			remaining := max(
				i64(0),
				i64(time.tick_diff(time.tick_now(), n.expires) / time.Millisecond),
			)
			left := n.sticky ? "sticky" : fmt.tprintf("%dms", remaining)
			key := fmt.tprintf("notice.%s", verify_notice_key(n.key))
			kind := strings.to_lower(fmt.tprintf("%v", n.kind), context.temp_allocator)
			value := fmt.tprintf("%s: %s (%s)", kind, n.text, left)
			if _, err := append(&entries, control.State_Entry{key, value}); err != nil {
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
		for &view, i in w.views {
			spans += len(view.view.links.spans)
			range, ok := view.hover.?
			if !ok || hover != "none" {
				continue
			}
			hover = fmt.tprintf(
				"%d,%d-%d,%d",
				range.first_row,
				range.first_column,
				range.last_row,
				range.last_column,
			)
			if _, target, found := term.link_at(
				&w.views[i].view.links,
				range.first_column,
				range.first_row,
			); found {
				uri = target
			}
		}
		return
	}

	verify_find_count :: proc(w: ^Window, entry: ^Session_Entry) -> string {
		label, _ := find_presentation(w, entry)
		return label
	}

	// Retain the original matches field for existing control journeys.
	find_status :: proc(w: ^Window, entry: ^Session_Entry) -> string {
		if entry == nil || len(w.find.query.bytes) == 0 { return "" }
		s := term.search_summary(entry.session)
		switch {
		case s.selected >= 0: return fmt.tprintf("%d of %d", s.selected + 1, s.total)
		case s.total == 1: return "1 match"
		case s.total > 0: return fmt.tprintf("%d matches", s.total)
		case !s.complete: return "Searching…"
		}
		return "No matches"
	}

	verify_find_rect :: proc(w: ^Window, entry: ^Session_Entry, older: bool) -> string {
		if !w.find.open { return "" }
		l, _ := find_controls(w, entry)
		return verify_workspace_rect(older ? l.older : l.newer)
	}

	verify_workspace_rect :: proc(r: render.Rect) -> string {
		return fmt.tprintf("%g,%g,%g,%g", r.x, r.y, r.width, r.height)
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

	verify_reply :: proc(app: ^App, ok: bool, text: string) {
		v := &app.verify
		if err := control.respond(v.server, v.pending.id, {ok, text}); err != .None {
			log.errorf("answering control request failed: %v", err)
		}
		verify_clear(v)
	}

	verify_error :: proc(app: ^App, err: control.Error) {
		log.errorf("control request failed: %v", err)
		verify_reply(
			app,
			false,
			fmt.tprintf("error: %v; check arguments with help and retry", err),
		)
	}

	@(require_results)
	verify_before :: proc(app: ^App, entries: []control.State_Entry) -> control.Error {
		v := &app.verify
		if w := verify_window(app); w != nil && focused_session(app, w) != nil {
			err: control.Error
			v.before, err = verify_snapshot(app, true)
			if err != .None {return err}
		}
		owned, allocation_error := make([]control.State_Entry, len(entries))
		if allocation_error != nil {return .Out_Of_Memory}
		v.before_state = owned
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

	@(require_results)
	verify_key_event :: proc(
		app: ^App,
		id: platform.Window_Id,
		key: input.Key,
		mods: input.Modifiers,
		pressed: bool,
	) -> control.Error {
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
		id: platform.Window_Id,
		chord: commands.Shortcut,
	) -> control.Error {
		keys := [?]input.Key{.Control_Left, .Shift_Left, .Alt_Left, .Meta_Left}
		flags := [?]input.Modifier{.Control, .Shift, .Alt, .Super}
		mods: input.Modifiers
		err: control.Error
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
		p: control.Position,
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
	verify_mouse :: proc(app: ^App, w: ^Window, m: control.Mouse) -> control.Error {
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
				platform.Mouse_Wheel_Event {
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
				platform.Mouse_Move_Event{w.id, pos.x, pos.y, v.buttons, m.modifiers, now},
			)
			return .None
		}
		if m.kind != .Up {
			v.buttons += {m.button}
			handle_event(
				app,
				platform.Mouse_Button_Event{w.id, m.button, true, pos.x, pos.y, m.modifiers, now},
			)
		}
		if m.kind == .Drag {
			for step in 1 ..= 4 {
				x := pos.x + i32((i64(end.x) - i64(pos.x)) * i64(step) / 4)
				y := pos.y + i32((i64(end.y) - i64(pos.y)) * i64(step) / 4)
				handle_event(
					app,
					platform.Mouse_Move_Event{w.id, x, y, v.buttons, m.modifiers, now + i64(step)},
				)
			}
		}
		if m.kind != .Down {
			v.buttons -= {m.button}
			handle_event(
				app,
				platform.Mouse_Button_Event {
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
	verify_drive :: proc(app: ^App, request: control.Request) -> control.Error {
		if selection, ok := request.(control.Window_Select); ok {
			id := platform.Window_Id(selection.id)
			if window_find(app, id) == nil {return .Invalid_Argument}
			app.verify.target_window = id
			return .None
		}
		w := verify_window(app)
		if tray, ok := request.(control.Tray); ok {
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
		case control.Type:
			handle_event(app, platform.Text_Event{w.id, r.text})
		case control.Key:
			for chord in r.chords {
				if err := verify_chord(app, id, chord); err != .None {return err}
			}
		case control.Run:
			handle_event(app, platform.Text_Event{w.id, r.line})
			return verify_chord(app, w.id, {.Enter, {}})
		case control.Mouse:
			return verify_mouse(app, w, r)
		case control.Window_Move:
			if platform.window_set_position(
				   &app.platform,
				   w.id,
				   i32(r.position.x),
				   i32(r.position.y),
			   ) !=
			   .None {return .System}
		case control.Focus:
			handle_event(app, platform.Focus_Event{w.id, r.focused})
		case control.Dpi:
			handle_event(app, platform.Dpi_Event{w.id, u32(r.value)})
		case control.Resize:
			_, width, height := pane_box_for_grid(
				app,
				w.scale,
				w.metrics,
				u16(r.columns),
				u16(r.rows),
				pane_insets(app, w.scale, focused_session(app, w)),
				w.rail_width > 0 ? w.rail_width : ui.RAIL_WIDTH,
			)
			if platform.window_set_client_size(&app.platform, w.id, width, height) !=
			   .None {return .System}
		case control.Command:
			command := commands.find(&app.registry, r.name)
			if command == nil || command.disabled {return .Invalid_Argument}
			palette_close(app, w)
			run_action(app, w, Action(command.id), r.direction, r.ratio, r.focus)
		case:
			return .Invalid_Argument
		}
		return .None
	}

	@(require_results)
	verify_rows :: proc(s: ^term.Snapshot, count: int = 3) -> (string, control.Error) {
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
		s: ^term.Snapshot,
		entries: []control.State_Entry,
	) -> (
		string,
		control.Error,
	) {
		v := &app.verify
		parts := make([dynamic]string, context.temp_allocator)
		ranges := make([dynamic]string, context.temp_allocator)
		changed_rows := 0
		first := -1
		rows := v.before.rows > 0 && s.rows > 0 ? max(int(v.before.rows), int(s.rows)) : 0
		for row in 0 ..= rows {
			changed := false
			if row < rows {
				a, ae := term.row_text(&v.before, row, context.temp_allocator)
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
			a, b := verify_value(v.before_state, key), verify_value(entries, key)
			if a == b {continue}
			value := strings.builder_make(context.temp_allocator)
			if err := control.format_value(&value, b); err != .None {return "", err}
			change := fmt.tprintf("%s=%s", key, strings.to_string(value))
			if key == "window.visible" {change = b == "true" ? "window shown" : "window hidden"}
			if key == "palette.open" {change = b == "true" ? "palette opened" : "palette closed"}
			if key == "find.open" {change = b == "true" ? "find opened" : "find closed"}
			if _, err := append(&parts, change); err != nil {return "", .Out_Of_Memory}
		}
		for n in app.notices.items {
			key := fmt.tprintf("notice.%s", verify_notice_key(n.key))
			old := verify_value(v.before_state, key)
			// Expiry countdown changes are not a new notice.
			kind := strings.to_lower(fmt.tprintf("%v", n.kind), context.temp_allocator)
			prefix := fmt.tprintf("%s: %s (", kind, n.text)
			if strings.has_prefix(old, prefix) {continue}
			value := strings.builder_make(context.temp_allocator)
			if err := control.format_value(&value, n.text); err != .None {return "", err}
			label := fmt.tprintf(
				"notice %s %s",
				verify_notice_key(n.key),
				strings.to_string(value),
			)
			if _, err := append(&parts, label); err != nil {return "", .Out_Of_Memory}
		}
		for old in v.before_state {
			if strings.has_prefix(old.key, "notice.") && verify_value(entries, old.key) == "" {
				if _, err := append(&parts, fmt.tprintf("%s removed", old.key)); err != nil {
					return "", .Out_Of_Memory
				}
			}
		}
		if len(parts) == 0 {return "ok; no visible change", .None}
		return fmt.tprintf("ok; %s", strings.join(parts[:], "; ", context.temp_allocator)), .None
	}

	verify_read :: proc(app: ^App) {
		entries, state_error := verify_state(app)
		if state_error != .None {verify_error(app, state_error); return}
		out := strings.builder_make(context.temp_allocator)
		err: control.Error
		passed := true
		#partial switch r in app.verify.pending.request {
		case control.Ping:
			for key, i in ([]string{"pid", "app", "build", "data", "settings", "log"}) {
				fmt.sbprintf(&out, "%s%s=", i == 0 ? "" : " ", key)
				err = control.format_value(&out, verify_value(entries, fmt.tprintf("app.%s", key)))
				if err != .None {break}
			}
		case control.Help:
			err = control.help(&out, r.command)
		case control.State:
			err = control.format_state(&out, entries)
		case control.Screen, control.Cells, control.Expect:
			s: term.Snapshot
			expect, is_expect := app.verify.pending.request.(control.Expect)
			if !is_expect || expect.kind != .State {
				s, err = verify_snapshot(app)
				if err != .None {verify_error(app, err); return}
			}
			#partial switch r in app.verify.pending.request {
			case control.Screen:
				err = control.format_screen(&out, &s, r.rows)
			case control.Cells:
				err = control.format_cells(&out, &s, r)
			case control.Expect:
				passed, err = control.evaluate(&out, r, &s, entries)
			}
		case control.Capture:
			err = capture_read(app, &out, r)
		case control.Pixels:
			err = pixels_read(app, &out, r)
		case control.Diff:
			err = pixels_diff(app, &out, r)
		case control.Draws:
			err = draws_read(app, &out, r)
		case control.Perf:
			err = perf_read(app, &out, r)
		case control.Vt:
			err = vt_record(app, &out, r)
		case:
			err = .Invalid_Argument
		}
		if err != .None {
			// Evidence commands explain bad input, files, or devices in their own words.
			text := strings.to_string(out)
			if strings.has_prefix(text, "error:") {
				verify_reply(app, false, text)
				return
			}
			verify_error(app, err)
			return
		}
		verify_reply(app, passed, strings.to_string(out))
	}

	verify_wait :: proc(app: ^App, w: ^Window, now: time.Tick, presented: bool) {
		v := &app.verify
		r := v.pending.request.(control.Wait)
		elapsed := int(time.tick_diff(v.started, now) / time.Millisecond)
		timed_out := elapsed >= r.timeout_ms
		idle := time.tick_diff(v.changed, now) >= time.Duration(r.idle_ms) * time.Millisecond
		if !timed_out {
			if r.kind == .Idle && !idle {return}
			if !presented {
				if r.kind == .Idle || v.frames == v.request_frame {w.dirty = true}
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
			passed = v.frames > v.request_frame
		case .Text, .Gone:
			e := control.Expect {
				kind = r.kind == .Text ? .Text : .No_Text,
				text = r.text,
			}
			passed, err = control.evaluate(&out, e, &s)
			label = fmt.tprintf("%s %q", r.kind == .Text ? "text" : "gone", r.text)
			if passed && r.kind == .Text {
				label = strings.trim_prefix(strings.trim_space(strings.to_string(out)), "PASS ")
			}
		}
		if err != .None {verify_error(app, err); return}
		if passed && presented && v.frames > v.request_frame && !w.dirty {
			verify_reply(app, true, fmt.tprintf("PASS wait %s after %dms", label, elapsed))
			return
		}
		if timed_out {
			rows, rows_error := verify_rows(&s)
			if rows_error != .None {verify_error(app, rows_error); return}
			verify_reply(
				app,
				false,
				fmt.tprintf(
					"FAIL wait %s: timeout after %dms; last rows: %s",
					label,
					elapsed,
					rows,
				),
			)
			return
		}
		if passed || v.frames == v.request_frame {w.dirty = true}
	}

	verify_begin_quit :: proc(app: ^App, now: time.Tick) {
		v := &app.verify
		v.quit_id, v.quit_started = v.pending.id, now
		verify_reply(app, true, "ok; quitting")
	}

	verify_start_drive :: proc(app: ^App, now: time.Tick) {
		v := &app.verify
		entries, state_error := verify_state(app)
		if state_error != .None {verify_error(app, state_error); return}
		if err := verify_before(app, entries); err != .None {verify_error(app, err); return}
		perf.mark_input(&app.perf)
		if err := verify_drive(app, v.pending.request);
		   err != .None {verify_error(app, err); return}
		if !app.running {
			app.running = true
			verify_begin_quit(app, now)
			return
		}
		v.phase, v.started, v.changed = .Finish_Drive, now, now
		v.request_frame = v.frames
	}

	verify_finish_drive :: proc(app: ^App, w: ^Window, now: time.Tick) {
		v := &app.verify
		elapsed := int(time.tick_diff(v.started, now) / time.Millisecond)
		idle_ms, timeout_ms := 50, 1000
		run, is_run := v.pending.request.(control.Run)
		if is_run {idle_ms, timeout_ms = run.idle_ms, run.timeout_ms}
		quiet := time.tick_diff(v.changed, now) >= time.Duration(idle_ms) * time.Millisecond
		frame := w == nil || v.frames > v.request_frame && !w.dirty
		if elapsed < timeout_ms && (!quiet || !frame) {
			if w != nil && quiet {w.dirty = true}
			return
		}
		s: term.Snapshot
		err: control.Error
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
		if r, resize := v.pending.request.(control.Resize); resize {
			if verify_value(entries, "grid.size") != fmt.tprintf("%dx%d", r.columns, r.rows) {
				if elapsed < 5000 {return}
				verify_reply(app, false, "error: resize timed out; use state to inspect grid.size")
				return
			}
		}
		text, change_error := verify_changes(app, &s, entries)
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
		if v.quit_id != 0 {
			if control.delivery_finished(v.server, v.quit_id) ||
			   time.tick_diff(v.quit_started, now) >= time.Second {
				handle_event(app, platform.Tray_Menu_Event{TRAY_QUIT})
			}
			return
		}
		w := verify_window(app)
		verify_update_generation(v, app, w, now)
		if v.pending == nil {
			v.pending = control.poll(v.server)
			if v.pending == nil {return}
			v.started, v.request_frame = now, v.frames
			v.phase = .Start_Drive
			#partial switch _ in v.pending.request {
			case control.Ping,
			     control.Screen,
			     control.Cells,
			     control.State,
			     control.Expect,
			     control.Help,
			     control.Capture,
			     control.Pixels,
			     control.Diff,
			     control.Draws,
			     control.Perf,
			     control.Vt:
				v.phase = .Read
			case control.Wait:
				v.phase = .Wait
			}
			if w != nil {
				current: u64
				current = window_generation(app, w)
				v.needs_frame = w.dirty || current != w.generation
			}
		}
		if tray, ok := v.pending.request.(control.Tray); ok && tray.action == .Quit {
			verify_begin_quit(app, now)
			return
		}
		if w == nil && v.phase != .Finish_Drive && verify_needs_window(v.pending.request) {
			verify_reply(app, false, "error: window hidden; run tray open")
			return
		}
		if w != nil &&
		   (v.phase == .Read || v.phase == .Start_Drive) &&
		   (w.dirty || v.needs_frame && v.frames == v.request_frame) {
			timeout := time.Duration(verify_timeout(v.pending.request)) * time.Millisecond
			if time.tick_diff(v.started, now) < timeout {w.dirty = true; return}
			verify_reply(
				app,
				false,
				"error: no frame presented before timeout; restore the window and retry",
			)
			return
		}
		switch v.phase {
		case .Read:
			verify_read(app)
		case .Wait:
			verify_wait(app, w, now, presented)
		case .Start_Drive:
			verify_start_drive(app, now)
		case .Finish_Drive:
			verify_finish_drive(app, w, now)
		}
	}
} else {
	Verify :: struct {}
	verify_start :: proc(_: ^App) {}
	verify_destroy :: proc(_: ^App) {}
	verify_presented :: proc(_: ^App, _: ^Window) {}
	verify_tick :: proc(_: ^App) {}
	verify_deadline :: proc(_: ^App) -> (time.Tick, bool) {return {}, false}
}
