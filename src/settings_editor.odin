package main

import "core:fmt"
import "core:os"
import "core:strings"
import "aio:commands"
import "aio:settings"
import "aio:ui"

@(private)
shortcuts_text :: proc(shortcuts: commands.Shortcut_Set) -> string {
	labels: [commands.MAX_SHORTCUTS]string
	set := shortcuts
	for shortcut, i in set.items[:set.count] {
		buffer: [128]u8
		label, err := commands.shortcut_label(shortcut, buffer[:])
		if err != .None { return "" }
		labels[i] = fmt.tprintf("%s", label)
	}
	return strings.join(labels[:shortcuts.count], ", ", context.temp_allocator)
}

@(private)
shortcut_group :: proc(name: string) -> string {
	switch ui.command_category(name) {
	case "Application": return "Application Shortcuts"
	case "Terminal": return "Terminal Shortcuts"
	case "Panes": return "Pane Shortcuts"
	case "Tabs": return "Tab Shortcuts"
	case "Settings": return "Settings Shortcuts"
	case "Edit": return "Edit Shortcuts"
	case "View": return "View Shortcuts"
	}
	return "Other Shortcuts"
}

editor_open :: proc(app: ^App, w: ^Window) {
	pane_header_cancel(w)
	p := &w.editor
	ui.editor_destroy(p)
	data, err := os.read_entire_file(app.settings_path, context.allocator)
	if err != nil {
		notify(app, .Error, "Could not read settings. Check the settings path and permissions.")
		return
	}
	p.source = string(data)
	s, diagnostics, parse_error := settings.parse(p.source)
	defer settings.diagnostics_destroy(&diagnostics)
	if parse_error != nil {
		ui.editor_destroy(p)
		notify(app, .Error, "Could not open settings.")
		return
	}
	defer settings.destroy(&s)
	@(static, rodata) schema := settings.SCHEMA
	for &entry in schema {
		row := ui.Editor_Row{key = entry.key, title = entry.title, description = entry.description,
			value = settings.value_text(&s, entry), default_value = entry.default_value,
			minimum = entry.minimum, maximum = entry.maximum}
		switch entry.kind {
		case .String: row.kind = entry.key == "input.leader" ? .Shortcut : .Text
		case .Int: row.kind = .Integer
		case .Float: row.kind = .Number
		case .Bool: row.kind = .Toggle
		case .Enum: row.kind, row.choices = .Choice, entry.enum_names
		case .Color: row.kind = .Color
		case .Optional_Color:
			row.kind = .Optional_Color
			if c, ok := settings.theme_color(&s, entry.key); ok { row.fallback = settings.color_hex(c) }
		}
		if ui.editor_add(p, row, settings.group_title(entry.key)) != nil {
			ui.editor_destroy(p)
			notify(app, .Error, "Could not allocate settings editor.")
			return
		}
	}
	for command in app.registry.items {
		value := shortcuts_text(command.shortcuts)
		for binding in s.keys { if binding.name == command.name { value = binding.value; break } }
		row := ui.Editor_Row{
			key = fmt.tprintf("keys.%s", command.name), title = command.title,
			description = "Up to four shortcuts. Press Enter to record keys; Leader+ chords need a leader key.",
			value = value, default_value = shortcuts_text(command.defaults), kind = .Shortcut,
		}
		group := shortcut_group(command.name)
		if ui.editor_add(p, row, group) != nil {
			ui.editor_destroy(p)
			notify(app, .Error, "Could not allocate settings editor.")
			return
		}
		ui.editor_collapse(p, group, true)
	}
	p.leader = app.leader
	p.open = true
	ui.editor_filter(p)
	ui.palette_close(&app.palette)
	find_close(w, focused_session(app, w))
	leader_cancel(w)
	w.selecting, w.autoscrolling = false, false
	w.dragging = {}
	w.dirty = true
	if len(diagnostics) > 0 {
		ui.editor_message(p,
			"File has diagnostics; invalid settings show defaults. Only the selected key is changed.", true)
	}
}

@(private)
editor_validate_bindings :: proc(text, path: string) -> (problem, warning: string) {
	s, diagnostics, err := settings.parse(text)
	if err != nil { return "Could not validate settings.", "" }
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	probe := App{settings = s, settings_path = path, registry = commands.create()}
	defer commands.destroy(&probe.registry)
	defer ui.notices_destroy(&probe.notices)
	if register_actions(&probe.registry) != .None { return "Could not validate shortcuts.", "" }
	before := len(diagnostics)
	apply_bindings(&probe, &diagnostics)
	for d in diagnostics[before:] {
		message := fmt.tprintf("%s: %s", d.key, d.message)
		if d.kind == .Shortcut_Warning {
			if warning == "" {
				warning = d.message
				if source := strings.index_byte(warning, '['); source > 0 {
					warning = strings.trim_space(warning[:source])
				}
			}
		} else { return message, "" }
	}
	return "", warning
}

editor_outcome :: proc(app: ^App, w: ^Window, outcome: ui.Editor_Outcome) {
	p := &w.editor
	if outcome == .None { return }
	w.dirty = true
	if outcome == .Closed { ui.editor_destroy(p); return }
	if outcome != .Save && outcome != .Reset { return }
	row := ui.editor_row(p)
	if row == nil { return }
	if outcome == .Reset { ui.field_set(&p.value, row.default_value) }
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
		text := result == .Conflict ? "File changed outside this editor. Close and reopen Settings to reload it." :
			"Could not save settings. Check the settings path and permissions."
		ui.editor_message(p, text, true)
		return
	}
	delete(p.source)
	p.source = updated
	delete(row.value)
	row.value = strings.clone(value)
	ui.field_set(&p.value, value)
	if row.kind == .Shortcut { p.editing, p.capturing = false, false }
	reload_settings(app)
	p.leader = app.leader
	text := "Saved and applied."
	if alpha { text = "Saved and applied; the color's alpha is ignored." }
	if warning != "" { text = fmt.tprintf("Saved. %s", warning) }
	if row.key == "shell.command" || row.key == "shell.directory" { text = "Saved. Applies to new or restarted shells." }
	if row.key == "window.columns" || row.key == "window.rows" {
		text = "Saved. Initial size applies to new sessions."
	}
	ui.editor_message(p, text, false)
}
