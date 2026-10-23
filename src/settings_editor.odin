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
shortcuts_text :: proc(shortcuts: commands.Shortcut_Set) -> string {
	labels := make([]string, shortcuts.count, context.temp_allocator)
	set := shortcuts
	for shortcut, i in set.items[:set.count] {
		buffer: [128]u8
		label, err := commands.shortcut_label(shortcut, buffer[:])
		if err != .None {return ""}
		labels[i] = fmt.tprintf("%s", label)
	}
	return strings.join(labels[:shortcuts.count], ", ", context.temp_allocator)
}

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
		value := shortcuts_text(command.shortcuts)
		for binding in s.keys {if binding.name == command.name {value = binding.value; break}}
		row := ui.Editor_Row {
			key           = fmt.tprintf("keys.%s", command.name),
			title         = command.title,
			description   = "",
			value         = value,
			default_value = shortcuts_text(command.defaults),
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
	for tab, i in workspace.tabs {
		if root, ok := tab.tree.nodes[tab.tree.root].(layout.Pane);
		   ok && root.content.kind == .Settings {return i}
	}
	return -1
}

// Whether the window shows its settings tab, which then takes keyboard and pointer input.
settings_active :: proc(w: ^Window) -> bool {
	if w.tree == nil || w.tree.root == layout.INVALID_NODE {return false}
	pane, ok := w.tree.nodes[w.tree.root].(layout.Pane)
	return ok && pane.content.kind == .Settings
}

settings_layout :: proc(w: ^Window) -> ui.Editor_Layout {
	r := len(w.panes) > 0 ? w.panes[0].rect : {}
	return ui.editor_layout({r.x, r.y, r.width, r.height}, w.scale)
}

// Selects the settings tab, creating it and loading the settings file when the workspace has none.
editor_open :: proc(app: ^App, w: ^Window) {
	if !gesture_cancel(app, w) {return}
	palette_close(app, w)
	find_close(w, focused_session(app, w))
	if index := settings_tab_index(w.workspace); index >= 0 {
		tab_select(app, w, index)
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
		text :=
			result == .Conflict ? "File changed outside this editor. Close and reopen Settings to reload it." : "Could not save settings. Check the settings path and permissions."
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
	   row.key == "shell.directory" {text = "Saved. Applies to new or restarted shells."}
	if row.key == "window.columns" || row.key == "window.rows" {
		text = "Saved. Initial size applies to new sessions."
	}
	ui.editor_message(p, text, false)
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
		text :=
			result == .Conflict ? "Settings changed outside the editor. Reopen Settings before resetting colors." : "Could not save theme colors. Check the settings path and permissions."
		if w.editor.open {ui.editor_message(&w.editor, text, true)} else {notify(app, .Error, text)}
		return
	}
	reload_settings(app, false)
	if w.editor.open {
		filter := strings.clone(ui.field_string(&w.editor.filter), context.temp_allocator)
		if !settings_load(app, &w.editor) {return}
		ui.field_set(&w.editor.filter, filter)
		ui.editor_filter(&w.editor)
		ui.editor_select_key(&w.editor, "colors.follow_theme")
		ui.editor_message(
			&w.editor,
			"Shell foreground and background now follow the theme.",
			false,
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
