package main

import "aio:commands"
import "aio:layout"
import "aio:platform"
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

// Fills the editor from the settings file; the settings tab shows it.
@(private)
settings_load :: proc(app: ^App, p: ^ui.Editor) -> bool {
	ui.editor_destroy(p)
	data, err := os.read_entire_file(app.settings_path, context.allocator)
	if err != nil {
		notify(app, .Error, "Could not read settings. Check the settings path and permissions.")
		return false
	}
	p.source = string(data)
	s, diagnostics, parse_error := settings.parse(p.source)
	defer settings.diagnostics_destroy(&diagnostics)
	if parse_error != nil {
		ui.editor_destroy(p)
		notify(app, .Error, "Could not open settings.")
		return false
	}
	defer settings.destroy(&s)
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
	// The default profile's rows keep the shell command, directory and icon editable while the
	// full Profiles group is built. They were previously schema rows; the file now uses
	// profile.default.* and migrates the legacy keys on load.
	if builtin := settings.profile_default(&s.profiles); builtin != nil {
		rows := [?]ui.Editor_Row {
			{
				key = "profile.default.name",
				title = "Profile Name",
				description = "Shown in menus, tabs and the palette.",
				value = builtin.name,
				kind = .Text,
			},
			{
				key = "profile.default.command",
				title = "Profile Command Line",
				description = "Executable and arguments for the default shell.",
				value = builtin.command,
				default_value = settings.DEFAULT_PROFILE_COMMAND,
				kind = .Text,
			},
			{
				key = "profile.default.directory",
				title = "Profile Starting Directory",
				description = "Initial directory for the default shell; the home prefix is expanded.",
				value = builtin.directory,
				default_value = settings.DEFAULT_PROFILE_DIRECTORY,
				kind = .Text,
			},
			{
				key = "profile.default.icon",
				title = "Profile Icon",
				description = "PNG path; empty uses the executable's text badge.",
				value = builtin.icon,
				kind = .Text,
			},
		}
		for row in rows {
			if ui.editor_add(p, row, "Profile: Default") != nil {
				ui.editor_destroy(p)
				notify(app, .Error, "Could not allocate settings editor.")
				return false
			}
		}
	}
	if ui.editor_add(
		   p,
		   {
			   key = "profiles.add",
			   title = "Add Profile",
			   description = "Add a shell with its own command line and starting directory.",
			   value = "Add Profile",
			   kind = .Action,
		   },
		   "Profiles",
	   ) !=
	   nil {
		ui.editor_destroy(p)
		notify(app, .Error, "Could not allocate settings editor.")
		return false
	}
	for &profile in s.profiles.items {
		if profile.id == settings.PROFILE_DEFAULT_ID {continue}
		group := fmt.tprintf("Profile: %s", profile.name)
		if profile.detected {group = fmt.tprintf("Profile: %s (detected)", profile.name)}
		rows := [?]ui.Editor_Row {
			{
				key = fmt.tprintf("profile.%s.name", profile.id),
				title = "Profile Name",
				description = "Shown in menus, tabs and the palette.",
				value = profile.name,
				kind = .Text,
			},
			{
				key = fmt.tprintf("profile.%s.command", profile.id),
				title = "Profile Command Line",
				description = "Executable and arguments.",
				value = profile.command,
				default_value = settings.DEFAULT_PROFILE_COMMAND,
				kind = .Text,
			},
			{
				key = fmt.tprintf("profile.%s.directory", profile.id),
				title = "Profile Starting Directory",
				description = "Empty inherits the default starting directory.",
				value = profile.directory,
				default_value = settings.DEFAULT_PROFILE_DIRECTORY,
				kind = .Text,
			},
			{
				key = fmt.tprintf("profile.%s.icon", profile.id),
				title = "Profile Icon",
				description = "PNG path; empty uses the executable's text badge.",
				value = profile.icon,
				kind = .Text,
			},
			{
				key = fmt.tprintf("profile.%s.hidden", profile.id),
				title = "Hide from Menus",
				description = "Hidden profiles stay available to open panes and shortcuts.",
				value = profile.hidden ? "true" : "false",
				kind = .Toggle,
			},
			{
				key = fmt.tprintf("profile.%s.remove", profile.id),
				title = "Remove Profile",
				description = "Panes keep running; a restarted pane uses its recorded command.",
				value = "Remove…",
				kind = .Action,
			},
		}
		for row in rows {
			if ui.editor_add(p, row, group) != nil {
				ui.editor_destroy(p)
				notify(app, .Error, "Could not allocate settings editor.")
				return false
			}
		}
	}
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
	ui.editor_hover_clear(p)
	ui.editor_filter(p)
	if len(diagnostics) > 0 {
		ui.editor_message(
			p,
			"File has diagnostics; invalid settings show defaults. Only the selected key is changed.",
			true,
		)
	}
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
	if outcome != .Save && outcome != .Reset {return}
	row := ui.editor_row(p)
	if row == nil {return}
	if row.key == "profiles.add" {
		editor_add_profile(app, w)
		return
	}
	if strings.has_prefix(row.key, settings.PROFILE_PREFIX) &&
	   strings.has_suffix(row.key, ".remove") {
		editor_remove_profile(app, w, row.key)
		return
	}
	if row.key == "colors.follow_theme" {editor_follow_theme(app, w); return}
	if outcome == .Reset {ui.field_set(&p.value, row.default_value)}
	value := ui.field_string(&p.value)
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
	if result := settings.save(app.settings_path, p.source, updated); result != .None {
		delete(updated)
		text := "Could not save settings. Check the settings path and permissions."
		if result == .Conflict {
			text = "File changed outside this editor. Close and reopen Settings to reload it."
		}
		ui.editor_message(p, text, true)
		return
	}
	delete(p.source)
	p.source = updated
	delete(row.value)
	row.value = strings.clone(value)
	ui.field_set(&p.value, value)
	if row.kind == .Shortcut {p.focus, p.capturing = .Search, false}
	reload_settings(app, false)
	p.leader = app.leader
	text := "Saved and applied."
	if alpha {text = "Saved and applied; the color's alpha is ignored."}
	if warning != "" {text = fmt.tprintf("Saved. %s", warning)}
	if row.key == "shell.command" ||
	   row.key == "shell.directory" ||
	   strings.has_prefix(row.key, settings.PROFILE_PREFIX) &&
		   (strings.has_suffix(row.key, ".command") || strings.has_suffix(row.key, ".directory")) {
		text = "Saved. Applies to new or restarted shells."
	}
	if row.key == "window.columns" || row.key == "window.rows" {
		text = "Saved. Initial size applies to new sessions."
	}
	ui.editor_message(p, text, false)
}

@(private)
editor_profile_saved :: proc(
	app: ^App,
	w: ^Window,
	updated, key, message: string,
) -> bool {
	result := settings.save(app.settings_path, w.editor.source, updated)
	if result != .None {
		text := "Could not save the profile. Check the settings path and permissions."
		if result == .Conflict {
			text = "File changed outside this editor. Close and reopen Settings to reload it."
		}
		ui.editor_message(&w.editor, text, true)
		return false
	}
	reload_settings(app, false)
	settings_reveal_page(
		app,
		&w.editor,
		{key = key, search = .Preserve, reload = true, message = message},
	)
	return true
}

@(private)
editor_add_profile :: proc(app: ^App, w: ^Window) {
	id := ""
	for number := 1; ; number += 1 {
		candidate := fmt.tprintf("profile-%d", number)
		if settings.profile_find(&app.settings.profiles, candidate) == nil {
			id = candidate
			break
		}
	}
	text, clone_error := strings.clone(w.editor.source)
	if clone_error != nil {
		ui.editor_message(&w.editor, "Could not add the profile.", true)
		return
	}
	for pair in ([?][2]string{
		{"name", "New Profile"},
		{"command", settings.DEFAULT_PROFILE_COMMAND},
		{"directory", settings.DEFAULT_PROFILE_DIRECTORY},
	}) {
		key := fmt.tprintf("profile.%s.%s", id, pair[0])
		updated, message, edit_error := settings.edit_text(text, key, pair[1])
		delete(message)
		if edit_error != nil || updated == "" {
			delete(updated)
			delete(text)
			ui.editor_message(&w.editor, "Could not add the profile.", true)
			return
		}
		delete(text)
		text = updated
	}
	defer delete(text)
	key := fmt.tprintf("profile.%s.name", id)
	if editor_profile_saved(app, w, text, key, "Profile added. Change its command line or name.") {
		return
	}
}

@(private)
editor_remove_profile :: proc(app: ^App, w: ^Window, row_key: string) {
	key := strings.trim_suffix(row_key, ".remove")
	id := strings.trim_prefix(key, settings.PROFILE_PREFIX)
	profile := settings.profile_find(&app.settings.profiles, id)
	if profile == nil {return}
	if profile.detected {
		hidden_key := fmt.tprintf("profile.%s.hidden", id)
		updated, message, edit_error := settings.edit_text(w.editor.source, hidden_key, "true")
		delete(message)
		if edit_error != nil || updated == "" {
			delete(updated)
			ui.editor_message(&w.editor, "Could not hide the detected profile.", true)
			return
		}
		defer delete(updated)
		_ = editor_profile_saved(
			app,
			w,
			updated,
			"profiles.add",
			"Detected profile hidden. Its profile.hidden line overrides detection.",
		)
		return
	}
	updated, remove_error := settings.remove_profile_text(w.editor.source, id)
	if remove_error != nil {
		ui.editor_message(&w.editor, "Could not remove the profile.", true)
		return
	}
	defer delete(updated)
	_ = editor_profile_saved(app, w, updated, "profiles.add", "Profile removed.")
}

editor_follow_theme :: proc(app: ^App, w: ^Window) {
	data, err := os.read_entire_file(app.settings_path, context.temp_allocator)
	if err != nil {notify(app, .Error, "Could not read settings."); return}
	source := w.editor.open ? w.editor.source : string(data)
	updated, edit_error := settings.follow_theme_text(source)
	if edit_error != nil {notify(app, .Error, "Could not prepare theme colors."); return}
	defer delete(updated)
	result := settings.save(app.settings_path, source, updated)
	if result != .None {
		text := "Could not save theme colors. Check the settings path and permissions."
		if result == .Conflict {
			text = "Settings changed outside the editor. Reopen Settings before resetting colors."
		}
		if w.editor.open {ui.editor_message(&w.editor, text, true)} else {notify(app, .Error, text)}
		return
	}
	reload_settings(app, false)
	if w.editor.open {
		settings_reveal_page(
			app,
			&w.editor,
			{
				key = "colors.follow_theme",
				search = .Preserve,
				reload = true,
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
