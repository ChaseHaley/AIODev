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
	for entry in settings.SCHEMA {
		row := ui.Editor_Row{entry.key, entry.key, entry.description,
			settings.value_text(&s, entry), entry.default_value}
		if ui.editor_add(p, row) != nil {
			ui.editor_destroy(p)
			notify(app, .Error, "Could not allocate settings editor.")
			return
		}
	}
	for command in app.registry.items {
		value := shortcuts_text(command.shortcuts)
		for binding in s.keys { if binding.name == command.name { value = binding.value; break } }
		row := ui.Editor_Row{
			fmt.tprintf("keys.%s", command.name), command.title,
			"Shortcuts separated by commas. Physical+ names a key position. Leader+ requires input.leader. Empty disables.",
			value, shortcuts_text(command.defaults),
		}
		if ui.editor_add(p, row) != nil {
			ui.editor_destroy(p)
			notify(app, .Error, "Could not allocate settings editor.")
			return
		}
	}
	p.open = true
	ui.editor_filter(p)
	ui.palette_close(&app.palette)
	find_close(w, focused_session(app, w))
	leader_cancel(app, w)
	w.selecting, w.autoscrolling = false, false
	w.dragging = nil
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
	value := string(p.value.bytes[:])
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
	reload_settings(app)
	text := "Saved and applied."
	if warning != "" { text = fmt.tprintf("Saved. %s", warning) }
	if row.key == "shell.command" || row.key == "shell.directory" { text = "Saved. Applies to new or restarted shells." }
	if row.key == "window.columns" || row.key == "window.rows" {
		text = "Saved. Initial size applies to new sessions."
	}
	ui.editor_message(p, text, false)
}
