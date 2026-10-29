package main

import "aio:commands"
import "aio:layout"
import "aio:platform"
import "aio:pty"
import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:strings"

@(private)
shortcut_group :: proc(name: string) -> string {
	switch ui.command_category(name) {
	case "Application":
		return "Application Shortcuts"
	case "Terminal":
		return "Terminal Shortcuts"
	case "Panes":
		return "Pane Shortcuts"
	case "Tabs":
		return "Tab Shortcuts"
	case "Workspaces":
		return "Workspace Shortcuts"
	case "Windows":
		return "Window Shortcuts"
	case "Settings":
		return "Settings Shortcuts"
	case "Edit":
		return "Edit Shortcuts"
	case "View":
		return "View Shortcuts"
	}
	return "Other Shortcuts"
}

@(private)
settings_add_profile_row :: proc(p: ^ui.Editor, row: ui.Editor_Row, group: string) -> bool {
	return ui.editor_add(p, row, group) == nil
}

// Whether a profile's command line names an executable that exists. Explicit paths must exist;
// a bare name is resolved through the same trusted directories the terminal uses. A resolver
// error fails open so an unrelated OS problem never blocks saving.
@(private)
profile_command_exists :: proc(command: string) -> bool {
	token := pty.executable_token(command)
	if token == "" {return false}
	if pty.is_explicit_path(token) {return os.exists(token)}
	directories, directory_error := pty.search_directories(context.temp_allocator)
	if directory_error != nil {return true}
	_, resolve_error := pty.resolve_executable(command, directories, context.temp_allocator)
	return resolve_error.kind == .None
}

// Fills the editor from the settings file; the settings tab shows it.
@(private)
settings_load :: proc(app: ^App, p: ^ui.Editor) -> bool {
	data, err := os.read_entire_file(app.settings_path, context.temp_allocator)
	if err != nil {
		notify(app, .Error, "Could not read settings. Check the settings path and permissions.")
		return false
	}
	return settings_load_source(app, p, string(data))
}

// Builds a replacement before releasing the old page, so a failed refresh keeps its draft.
@(private)
settings_load_source :: proc(app: ^App, editor: ^ui.Editor, source: string) -> bool {
	view, view_error := ui.editor_view_take(editor)
	defer ui.editor_view_destroy(&view)
	if view_error != nil {
		notify(app, .Error, "Could not allocate settings editor.")
		return false
	}
	replacement: ui.Editor
	p := &replacement
	defer ui.editor_destroy(&replacement)
	owned_source, source_error := strings.clone(source)
	if source_error != nil {
		notify(app, .Error, "Could not allocate settings editor.")
		return false
	}
	p.source = owned_source
	s, diagnostics, parse_error := settings.parse(p.source)
	defer settings.diagnostics_destroy(&diagnostics)
	if parse_error != nil {
		ui.editor_destroy(p)
		notify(app, .Error, "Could not open settings.")
		return false
	}
	defer settings.destroy(&s)
	// The page parses its own copy of the file; detection results live on the running settings.
	// Reusing the cached results adds the detected section without touching the file or the disk.
	settings.profiles_begin_detection(&s.profiles)
	for &detected in app.settings.profiles.items {
		if !detected.detected {continue}
		_ = settings.profile_detect(
			&s,
			{detected.id, detected.name, detected.command, detected.directory},
		)
	}
	_ = settings.profiles_finalize(&s)
	@(static, rodata)
	schema := settings.SCHEMA
	for &entry in schema {
		row := ui.Editor_Row {
			key           = entry.key,
			title         = entry.title,
			description   = entry.description,
			value         = settings.value_text(&s, entry),
			default_value = entry.default_value,
			minimum       = entry.minimum,
			maximum       = entry.maximum,
		}
		if entry.key == "font.size" {row.minimum, row.maximum = 6, 32}
		if entry.key == "font.line_height" {row.minimum, row.maximum = 0.8, 2}
		if entry.key == "theme.mode" &&
		   (s.color_overrides.foreground != nil || s.color_overrides.background != nil) {
			row.description = "Shell colors are pinned. Search Follow Theme to reset foreground and background."
		}
		switch entry.kind {
		case .String:
			row.kind = entry.key == "input.leader" ? .Shortcut : .Text
		case .Int:
			row.kind = .Integer
		case .Float:
			row.kind = .Number
		case .Bool:
			row.kind = .Toggle
		case .Enum:
			row.kind, row.choices = .Choice, entry.enum_names
		case .Color:
			row.kind = .Color
		case .Optional_Color:
			row.kind = .Optional_Color
			if c, ok := settings.theme_color(&s, entry.key);
			   ok {row.fallback = settings.color_hex(c)}
		}
		if ui.editor_add(p, row, settings.group_title(entry.key)) != nil {
			ui.editor_destroy(p)
			notify(app, .Error, "Could not allocate settings editor.")
			return false
		}
	}
	// Profiles are one dense table. The model rows come from the resolved profile list; each becomes
	// a table row plus its inline editor rows, which stay hidden until the row expands.
	table, table_error := ui.profile_table_build(&s.profiles, profile_command_exists)
	if table_error != nil {
		ui.editor_destroy(p)
		notify(app, .Error, "Could not build the profile table.")
		return false
	}
	defer ui.profile_table_destroy(&table)
	profile_group := "Profiles"
	for row in table.rows {
		flags: bit_set[ui.Editor_Row_Flag]
		if row.is_default {flags += {.Default}}
		if row.hidden {flags += {.Hidden}}
		if row.listed {flags += {.Listed}}
		detail := fmt.tprintf(
			"%s %s %s name command line starting directory icon hidden duplicate remove",
			row.command,
			row.directory,
			row.icon,
		)
		if !settings_add_profile_row(
			p,
			{
				key = fmt.tprintf("profile.%s", row.id),
				title = row.name,
				description = row.command,
				value = row.directory,
				detail = detail,
				profile = row.id,
				badge = row.badge,
				note = row.note,
				kind = .Profile,
				flags = flags,
			},
			profile_group,
		) {
			ui.editor_destroy(p)
			notify(app, .Error, "Could not allocate the profile table.")
			return false
		}
		prefix := fmt.tprintf("profile.%s", row.id)
		rows := [?]ui.Editor_Row {
			{
				key = fmt.tprintf("%s.name", prefix),
				title = "Name",
				description = "Shown in menus, tabs and the palette.",
				value = row.name,
				default_value = row.name,
				profile = row.id,
				kind = .Text,
			},
			{
				key = fmt.tprintf("%s.command", prefix),
				title = "Command line",
				description = "Executable and arguments.",
				value = row.command,
				default_value = settings.DEFAULT_PROFILE_COMMAND,
				profile = row.id,
				kind = .Text,
			},
			{
				key = fmt.tprintf("%s.directory", prefix),
				title = "Starting directory",
				description = "Empty inherits the default starting directory.",
				value = row.directory,
				default_value = settings.DEFAULT_PROFILE_DIRECTORY,
				profile = row.id,
				kind = .Text,
			},
			{
				key = fmt.tprintf("%s.icon", prefix),
				title = "Icon",
				description = "PNG path; empty uses the executable's text badge.",
				value = row.icon,
				profile = row.id,
				badge = row.badge,
				kind = .Profile_Icon,
			},
			{
				key = fmt.tprintf("%s.hidden", prefix),
				title = "Hide from menus",
				description = "Hidden profiles stay available to open panes and shortcuts.",
				value = row.hidden ? "true" : "false",
				default_value = row.hidden ? "true" : "false",
				profile = row.id,
				kind = .Toggle,
			},
			{
				key = fmt.tprintf("%s.duplicate", prefix),
				title = "Duplicate Profile",
				description = "Add a copy with its own command line and starting directory.",
				value = "Duplicate",
				profile = row.id,
				kind = .Action,
			},
			{
				key = fmt.tprintf("%s.remove", prefix),
				title = "Remove Profile",
				description = "Panes keep running; a restarted pane uses its recorded command.",
				value = "Remove…",
				profile = row.id,
				kind = .Action,
			},
			{
				key = fmt.tprintf("%s.remove.cancel", prefix),
				title = "Cancel Removal",
				description = "Keep this profile and leave the table as it is.",
				value = "Cancel",
				profile = row.id,
				kind = .Action,
			},
			{
				key = fmt.tprintf("%s.remove.confirm", prefix),
				title = "Confirm Remove Profile",
				description = "Remove every line this profile owns; running panes keep their shells.",
				value = "Remove Profile",
				profile = row.id,
				kind = .Action,
			},
		}
		remove_prefix := fmt.tprintf("%s.remove", prefix)
		for field in rows {
			if row.id == settings.PROFILE_DEFAULT_ID &&
			   strings.has_prefix(field.key, remove_prefix) {continue}
			if !settings_add_profile_row(p, field, profile_group) {
				ui.editor_destroy(p)
				notify(app, .Error, "Could not allocate the profile table.")
				return false
			}
		}
	}
	if !settings_add_profile_row(
		   p,
		   {
			   key = "profiles.add",
			   title = "Add Profile",
			   description = "Add a shell with its own command line and starting directory.",
			   value = "Add Profile",
			   kind = .Profile_Add,
		   },
		   profile_group,
	   ) {
		ui.editor_destroy(p)
		notify(app, .Error, "Could not allocate the profile table.")
		return false
	}
	if len(table.detected) > 0 {
		names := make([dynamic]string, 0, len(table.detected), context.temp_allocator)
		for row in table.detected {append(&names, fmt.tprintf("%s %s", row.name, row.command))}
		if !settings_add_profile_row(
			   p,
			   {
				   key = "profiles.detected",
				   title = "Detected on this PC",
				   description = "Shells found on this machine that the settings file has not enabled.",
				   value = fmt.tprintf("%d", len(table.detected)),
				   detail = strings.join(names[:], " ", context.temp_allocator),
				   kind = .Detected_Header,
			   },
			   profile_group,
		   ) {
			ui.editor_destroy(p)
			notify(app, .Error, "Could not allocate the profile table.")
			return false
		}
		for row in table.detected {
			flags: bit_set[ui.Editor_Row_Flag]
			if row.is_default {flags += {.Default}}
			if row.listed {flags += {.Listed}}
			if !settings_add_profile_row(
				p,
				{
					key = fmt.tprintf("profile.%s", row.id),
					title = row.name,
					description = row.command,
					value = row.directory,
					detail = fmt.tprintf("%s %s", row.command, row.directory),
					profile = row.id,
					badge = row.badge,
					kind = .Detected,
					flags = flags,
				},
				profile_group,
			) {
				ui.editor_destroy(p)
				notify(app, .Error, "Could not allocate the profile table.")
				return false
			}
		}
	}
	ui.editor_group_table(p, profile_group)
	if ui.editor_add(
		   p,
		   {
			   key = "colors.follow_theme",
			   title = "Follow Theme for Shell Colors",
			   description = "Reset shell foreground and background together; preserve other color overrides.",
			   value = "Use theme colors",
			   kind = .Action,
		   },
		   "Colors",
	   ) !=
	   nil {
		ui.editor_destroy(p)
		notify(app, .Error, "Could not allocate settings editor.")
		return false
	}
	for command in app.registry.items {
		value := commands.shortcut_set_text(command.shortcuts, context.temp_allocator)
		for binding in s.keys {if binding.name == command.name {value = binding.value; break}}
		row := ui.Editor_Row {
			key           = fmt.tprintf("keys.%s", command.name),
			title         = command.title,
			description   = "",
			value         = value,
			default_value = commands.shortcut_set_text(command.defaults, context.temp_allocator),
			kind          = .Shortcut,
		}
		if ui.editor_add(p, row, shortcut_group(command.name)) != nil {
			ui.editor_destroy(p)
			notify(app, .Error, "Could not allocate settings editor.")
			return false
		}
	}
	p.leader = app.leader
	p.open = true
	ui.editor_view_restore(p, &view)
	// A configured default that is still only detected has no radio in the main table, so its
	// section must be open for the default to remain visible.
	for row in table.detected {
		if row.is_default {p.detected_open = true}
	}
	ui.editor_hover_clear(p)
	ui.editor_filter(p)
	if len(diagnostics) > 0 {
		ui.editor_message(
			p,
			"File has diagnostics; invalid settings show defaults. Only the selected key is changed.",
			true,
		)
	}
	ui.editor_destroy(editor)
	editor^, replacement = replacement, {}
	return true
}

settings_tab_index :: proc(workspace: ^Workspace) -> int {
	tab, _, found := settings_pane_location(workspace)
	return found ? tab : -1
}

// The layout node of the settings pane, wherever it sits in its tab.
settings_pane_node :: proc(workspace: ^Workspace) -> (layout.Node_Id, bool) {
	_, node, found := settings_pane_location(workspace)
	return node, found
}

@(private)
settings_pane_location :: proc(
	workspace: ^Workspace,
) -> (
	tab: int,
	node: layout.Node_Id,
	found: bool,
) {
	if workspace == nil {return -1, layout.INVALID_NODE, false}
	for candidate, tab_index in workspace.tabs {
		walk := tab_other_panes(nil, &candidate.tree, tab_index)
		for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
			if pane.content.kind == .Settings {return tab_index, pane.node, true}
		}
	}
	return -1, layout.INVALID_NODE, false
}

// Whether the window shows a focused settings pane, which then takes keyboard input.
settings_active :: proc(w: ^Window) -> bool {
	if w.tree == nil || w.tree.focus == layout.INVALID_NODE {return false}
	pane, ok := w.tree.nodes[w.tree.focus].(layout.Pane)
	return ok && pane.content.kind == .Settings
}

// The rectangle of the settings pane the window should address, preferring the focused one.
@(private)
settings_pane_rect :: proc(w: ^Window) -> layout.Rect {
	if w.tree != nil && w.tree.focus != layout.INVALID_NODE {
		for pane in w.panes {
			if pane.node == w.tree.focus && pane.content.kind == .Settings {return pane.rect}
		}
	}
	for pane in w.panes {
		if pane.content.kind == .Settings {return pane.rect}
	}
	return {}
}

@(require_results)
settings_layout_for :: proc(w: ^Window, rect: layout.Rect) -> ui.Editor_Layout {
	return ui.editor_layout(
		{rect.x, rect.y + w.header_height, rect.width, max(0, rect.height - w.header_height)},
		w.scale,
	)
}

settings_layout :: proc(w: ^Window) -> ui.Editor_Layout {
	return settings_layout_for(w, settings_pane_rect(w))
}

// The settings pane under a point, so pointer routing follows the pane rather than the focus.
settings_pane_under_pointer :: proc(
	w: ^Window,
	x, y: f32,
) -> (
	layout.Pane_Rect,
	bool,
) {
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found || pane.content.kind != .Settings {return {}, false}
	return pane, true
}

// Keeps the window's settings page matching its workspace: load one when a settings pane arrives
// from another workspace, and release it when the last settings pane leaves.
workspace_settings_sync :: proc(app: ^App, workspace: ^Workspace) {
	if workspace == nil {return}
	present := workspace_has_content(workspace, {.Settings, 0})
	for w in app.windows {
		if w.workspace != workspace {continue}
		if present {
			if !w.editor.open && app.settings_path != "" {_ = settings_load(app, &w.editor)}
		} else if w.editor.open {
			ui.editor_destroy(&w.editor)
		}
	}
}

// Selects the settings pane, creating it and loading the settings file when the workspace has none.
editor_open :: proc(app: ^App, w: ^Window) {
	if !gesture_cancel(app, w) {return}
	palette_close(app, w)
	find_close(w, focused_session(app, w))
	if index := settings_tab_index(w.workspace); index >= 0 {
		tab_select(app, w, index)
		if node, found := settings_pane_node(w.workspace); found {pane_focus(app, w, node)}
		return
	}
	if !settings_load(app, &w.editor) {return}
	tab, record_error := tab_record_reserve(w.workspace)
	if record_error != .None {
		ui.editor_destroy(&w.editor)
		notify(app, .Error, "Could not open the settings tab.")
		return
	}
	if layout.init(&tab.tree, {.Settings, 0}) != nil {
		tab_record_free(tab)
		ui.editor_destroy(&w.editor)
		notify(app, .Error, "Could not open the settings tab.")
		return
	}
	tab_record_commit(app, w.workspace, tab)
	tab_select(app, w, len(w.workspace.tabs) - 1)
}

@(private)
editor_validate_bindings :: proc(text, path: string) -> (problem, warning: string) {
	s, diagnostics, err := settings.parse(text)
	if err != nil {return "Could not validate settings.", ""}
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	registry := commands.create()
	defer commands.destroy(&registry)
	if register_actions(&registry) != .None {return "Could not validate shortcuts.", ""}
	report, report_error := binding_report(&registry, &s)
	for issue in report.issues {
		message := binding_issue_text(issue, path)
		if issue.severity == .Shortcut_Warning {
			// Parsed settings are freed on return; clone the location-free identity for the caller.
			if warning ==
			   "" {warning = strings.clone(diagnostic_identity_text(issue.severity, message), context.temp_allocator)}
		} else if issue.kind == .Duplicate_Shortcut {
			return fmt.tprintf(
				"Assigned to %s. Choose another shortcut.",
				issue.conflict.winner.title,
			), ""
		} else {
			return fmt.tprintf("%s: %s", issue.key, message), ""
		}
	}
	if report_error != nil {return "Could not validate shortcuts.", ""}
	return "", warning
}

editor_outcome :: proc(app: ^App, w: ^Window, outcome: ui.Editor_Outcome) {
	p := &w.editor
	if outcome == .None {return}
	w.dirty = true
	if outcome == .Profile_Action {
		editor_profile_action(app, w)
		return
	}
	if outcome != .Save && outcome != .Reset {return}
	row := ui.editor_row(p)
	if row == nil {return}
	if row.key == "profiles.add" {
		editor_profile_mutate(app, w, {kind = .Add})
		return
	}
	if row.profile != "" && row.kind == .Action {
		if strings.has_suffix(row.key, ".remove.cancel") {
			ui.editor_profile_remove_cancel(p)
			return
		}
		if strings.has_suffix(row.key, ".remove.confirm") {
			editor_profile_mutate(app, w, {kind = .Remove, id = row.profile})
			return
		}
		if strings.has_suffix(row.key, ".duplicate") {
			editor_profile_mutate(app, w, {kind = .Duplicate, id = row.profile})
			return
		}
		if strings.has_suffix(row.key, ".remove") {
			ui.editor_profile_remove_ask(p, row.profile)
			return
		}
	}
	if row.profile != "" {
		if outcome == .Reset {ui.field_set(&p.value, row.default_value)}
		editor_profile_field(app, w, row)
		return
	}
	if row.key == "colors.follow_theme" {editor_follow_theme(app, w); return}
	if outcome == .Reset {ui.field_set(&p.value, row.default_value)}
	key := strings.clone(row.key, context.temp_allocator)
	kind := row.kind
	value := strings.clone(ui.field_string(&p.value), context.temp_allocator)
	alpha := false
	if (row.kind == .Color || row.kind == .Optional_Color) && value != "" {
		if c, ok, has_alpha := settings.parse_color(value); ok {
			value, alpha = settings.color_hex(c), has_alpha
		}
	}
	updated, message, err := settings.edit_text(p.source, row.key, value)
	defer delete(message)
	if err != nil || message != "" {
		ui.editor_message(p, err != nil ? "Could not allocate settings change." : message, true)
		delete(updated)
		return
	}
	warning: string
	if strings.has_prefix(row.key, settings.KEY_BINDING_PREFIX) || row.key == "input.leader" {
		problem: string
		problem, warning = editor_validate_bindings(updated, app.settings_path)
		if problem != "" {
			ui.editor_message(p, problem, true)
			delete(updated)
			return
		}
	}
	defer delete(updated)
	if result := settings_commit(app, p.source, updated, p); result != .None {
		text := "Could not save settings. Check the settings path and permissions."
		if result == .Conflict {
			text = "File changed outside this editor. Close and reopen Settings to reload it."
		}
		ui.editor_message(p, text, true)
		return
	}
	if kind == .Shortcut {p.focus, p.capturing = .Search, false}
	text := "Saved and applied."
	if alpha {text = "Saved and applied; the color's alpha is ignored."}
	if warning != "" {text = fmt.tprintf("Saved. %s", warning)}
	if key == "window.columns" || key == "window.rows" {
		text = "Saved. Initial size applies to new sessions."
	}
	ui.editor_message(p, text, false)
}

@(private)
editor_profile_fail :: proc(w: ^Window, profile, key, text: string) {
	ui.editor_error_set(&w.editor, profile, key, text)
	ui.editor_message(&w.editor, text, true)
	w.dirty = true
}

// Writes one settings key, saves the file and reloads the page on the named row. Refusing leaves
// the editor untouched so the field keeps the value the user typed.
@(private)
editor_profile_write :: proc(
	app: ^App,
	w: ^Window,
	key, value, select_key, message: string,
	focus := Reveal_Focus.None,
) -> bool {
	updated, edit_message, err := settings.edit_text(w.editor.source, key, value)
	defer delete(edit_message)
	if err != nil || edit_message != "" {
		ui.editor_message(
			&w.editor,
			err != nil ? "Could not allocate settings change." : edit_message,
			true,
		)
		delete(updated)
		return false
	}
	result := settings_commit(app, w.editor.source, updated, &w.editor)
	delete(updated)
	if result != .None {
		text := "Could not save the profile. Check the settings path and permissions."
		if result == .Conflict {
			text = "File changed outside this editor. Close and reopen Settings to reload it."
		}
		ui.editor_message(&w.editor, text, true)
		return false
	}
	w.editor.focus = .Search
	settings_reveal_page(
		app,
		&w.editor,
		{key = select_key, search = .Preserve, message = message, focus = focus},
	)
	return true
}

// Validates and writes one inline profile field. Empty names and commands, duplicate names and a
// command line whose executable cannot be found stay inline: the row is ringed, the field carries
// the message, and no modal appears.
@(private)
editor_profile_field :: proc(app: ^App, w: ^Window, row: ^ui.Editor_Row) {
	key := strings.clone(row.key, context.temp_allocator)
	profile := strings.clone(row.profile, context.temp_allocator)
	value := strings.clone(ui.field_string(&w.editor.value), context.temp_allocator)
	problem: string
	switch {
	case strings.has_suffix(key, ".name"):
		if strings.trim_space(value) == "" {
			problem = "A profile needs a name."
		} else if settings.profile_name_taken(&app.settings.profiles, profile, value) {
			problem = "Another profile uses this name."
		}
	case strings.has_suffix(key, ".command"):
		if strings.trim_space(value) == "" {
			problem = "A profile needs a command line."
		} else if !profile_command_exists(value) {
			problem = fmt.tprintf(
				"Command not found: %s. Check the path, or leave the executable on PATH.",
				settings.shell_executable(value),
			)
		}
	}
	if problem != "" {
		editor_profile_fail(w, profile, key, problem)
		return
	}
	message := "Saved."
	focus := Reveal_Focus.Control
	if strings.has_suffix(key, ".command") || strings.has_suffix(key, ".directory") {
		message = "Saved. Applies to new or restarted shells."
	}
	if strings.has_suffix(key, ".hidden") {focus = .None}
	_ = editor_profile_write(app, w, key, value, key, message, focus)
}

@(private)
editor_profile_set_expanded :: proc(p: ^ui.Editor, id: string) {
	if p.remove_confirm != "" && p.remove_confirm != id {
		delete(p.remove_confirm)
		p.remove_confirm = ""
	}
	delete(p.expanded)
	p.expanded = strings.clone(id)
}

@(private)
editor_profile_saved :: proc(
	app: ^App,
	w: ^Window,
	updated, key, message: string,
) -> bool {
	result := settings_commit(app, w.editor.source, updated, &w.editor)
	if result != .None {
		text := "Could not save the profile. Check the settings path and permissions."
		if result == .Conflict {
			text = "File changed outside this editor. Close and reopen Settings to reload it."
		}
		ui.editor_message(&w.editor, text, true)
		return false
	}
	w.editor.focus = .Search
	settings_reveal_page(
		app,
		&w.editor,
		{key = key, search = .Preserve, message = message},
	)
	return true
}

@(private)
editor_profile_mutate :: proc(app: ^App, w: ^Window, change: settings.Profile_Mutation) {
	updated, id, issue, error := settings.profile_mutate(w.editor.source, &app.settings.profiles, change)
	defer delete(updated)
	defer delete(id)
	defer delete(issue)
	if error == .Unavailable {return}
	if error != .None {
		message := "Could not prepare the profile change."
		if error == .Edit {message = issue}
		if error == .Limit {
			message = "Profile limit reached. Remove one before duplicating."
			if change.kind == .Add {
				message = "Profile limit reached. Remove one before adding another."
			}
		}
		ui.editor_message(&w.editor, message, true)
		return
	}
	key := fmt.tprintf("profile.%s", id)
	message: string
	switch change.kind {
	case .Add:
		message = "Profile added. Change its command line or name."
	case .Duplicate:
		message = "Profile duplicated. Change its name or command line."
	case .Enable:
		message = "Detected profile enabled. It now has explicit profile lines in the settings file."
	case .Remove:
		message, key = "Profile removed.", "profiles.add"
	case .Move:
		message = "Profile order saved. Menus and Ctrl+Shift+1 to 9 follow it."
	}
	if change.kind == .Add || change.kind == .Duplicate || change.kind == .Enable {
		editor_profile_set_expanded(&w.editor, id)
	} else if change.kind == .Remove && w.editor.expanded == id {
		editor_profile_set_expanded(&w.editor, "")
	}
	_ = editor_profile_saved(app, w, updated, key, message)
}

@(private)
editor_profile_action :: proc(app: ^App, w: ^Window) {
	p := &w.editor
	action := p.action
	id := strings.clone(p.action_id, context.temp_allocator)
	value := strings.clone(p.action_value, context.temp_allocator)
	slot := p.action_slot
	ui.editor_action_clear(p)
	select_key := fmt.tprintf("profile.%s", id)
	switch action {
	case .None:
	case .Default:
		_ = editor_profile_write(
			app,
			w,
			"shell.default_profile",
			id,
			select_key,
			"Default profile saved. New tabs, splits and the plus button use it.",
		)
	case .Hidden:
		hidden := value == "true"
		_ = editor_profile_write(
			app,
			w,
			fmt.tprintf("profile.%s.hidden", id),
			value,
			select_key,
			hidden ? "Profile hidden from menus." : "Profile shown in menus.",
		)
	case .Order:
		editor_profile_mutate(app, w, {kind = .Move, id = id, slot = slot})
	case .Enable:
		editor_profile_mutate(app, w, {kind = .Enable, id = id})
	case .Duplicate:
		editor_profile_mutate(app, w, {kind = .Duplicate, id = id})
	case .Remove:
		editor_profile_mutate(app, w, {kind = .Remove, id = id})
	}
}

editor_follow_theme :: proc(app: ^App, w: ^Window) {
	data, err := os.read_entire_file(app.settings_path, context.temp_allocator)
	if err != nil {notify(app, .Error, "Could not read settings."); return}
	source := w.editor.open ? w.editor.source : string(data)
	updated, edit_error := settings.follow_theme_text(source)
	if edit_error != nil {notify(app, .Error, "Could not prepare theme colors."); return}
	defer delete(updated)
	result := settings_commit(app, source, updated, w.editor.open ? &w.editor : nil)
	if result != .None {
		text := "Could not save theme colors. Check the settings path and permissions."
		if result == .Conflict {
			text = "Settings changed outside the editor. Reopen Settings before resetting colors."
		}
		if w.editor.open {ui.editor_message(&w.editor, text, true)} else {notify(app, .Error, text)}
		return
	}
	if w.editor.open {
		w.editor.focus = .Search
		settings_reveal_page(
			app,
			&w.editor,
			{
				key = "colors.follow_theme",
				search = .Preserve,
				message = "Shell foreground and background now follow the theme.",
			},
		)
	} else {notify(app, .Info, "Shell foreground and background now follow the theme.")}
}

// Plain and shifted keys type or navigate, and these Ctrl chords edit text or move through the list.
@(private)
editor_owns :: proc(e: platform.Key_Event) -> bool {
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	if modifiers & {.Control, .Alt, .Super} == {} {return true}
	#partial switch e.key {
	case .Arrow_Left, .Arrow_Right, .Home, .End:
		return modifiers - {.Shift} == {.Control}
	case .A, .N, .P, .R, .Backspace, .Delete:
		return modifiers == {.Control}
	}
	return false
}

// Keys on the settings tab. Recording a shortcut keeps every key; otherwise text fields keep their
// clipboard and editing chords and other app shortcuts still run, so tabs can be switched or closed.
settings_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	pane_header_cancel(w)
	p := &w.editor
	w.dirty = true
	if e.pressed {w.suppressed_key = e}
	if ui.editor_capturing(p) {
		editor_outcome(app, w, ui.editor_key(p, e))
		return
	}
	literal := false
	switch leader_key(app, w, e) {
	case .Consumed:
		return
	case .Literal:
		literal = true
	case .None:
	}
	logical := e
	logical.key = commands.logical_key(e.key, e.unshifted)
	switch clipboard_chord(logical) {
	case .Copy:
		clipboard_copy(app, ui.editor_selection(p))
		return
	case .Cut:
		if clipboard_copy(app, ui.editor_selection(p)) {ui.editor_cut(p)}
		return
	case .Paste:
		if text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator);
		   ok {ui.editor_paste(p, text)}
		return
	case .None:
	}
	if e.pressed && !literal && !editor_owns(logical) {
		if action, found := shortcut_action(app, e); found {
			run_action(app, w, action)
			return
		}
	}
	editor_outcome(app, w, ui.editor_key(p, e))
}
