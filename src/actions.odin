package main

import "core:fmt"
import "core:log"
import "core:strings"
import "aio:commands"
import "aio:platform"
import "aio:settings"
import "aio:term"
import "aio:ui"

Action :: enum u32 {
	Command_Palette,
	Copy,
	Paste,
	Select_All,
	Clear_Scrollback,
	Scroll_Page_Up,
	Scroll_Page_Down,
	Font_Size_Increase,
	Font_Size_Decrease,
	Font_Size_Reset,
	Open_Settings,
	Reload_Settings,
	Restart_Shell,
	Hide_To_Tray,
	Quit,
}

@(private)
Action_Info :: struct {
	name, title: string,
	shortcuts: []commands.Shortcut,
}

@(private)
ACTIONS :: [Action]Action_Info{
	.Command_Palette = {"app.command_palette", "Show Command Palette", {{.P, {.Control, .Shift}}}},
	.Copy = {"edit.copy", "Copy", {{.C, {.Control, .Shift}}, {.Insert, {.Control}}}},
	.Paste = {"edit.paste", "Paste", {{.V, {.Control, .Shift}}, {.Insert, {.Shift}}}},
	.Select_All = {"edit.select_all", "Select All", {{.A, {.Control, .Shift}}}},
	.Clear_Scrollback = {"terminal.clear_scrollback", "Clear Scrollback", {{.K, {.Control, .Shift}}}},
	.Scroll_Page_Up = {"terminal.scroll_page_up", "Scroll Up One Page", {{.Page_Up, {.Shift}}}},
	.Scroll_Page_Down = {"terminal.scroll_page_down", "Scroll Down One Page", {{.Page_Down, {.Shift}}}},
	.Font_Size_Increase = {
		"view.font_size_increase", "Increase Font Size", {{.Equal, {.Control}}, {.Numpad_Add, {.Control}}},
	},
	.Font_Size_Decrease = {
		"view.font_size_decrease", "Decrease Font Size", {{.Minus, {.Control}}, {.Numpad_Subtract, {.Control}}},
	},
	.Font_Size_Reset = {
		"view.font_size_reset", "Reset Font Size", {{.Digit_0, {.Control}}, {.Numpad_0, {.Control}}},
	},
	.Open_Settings = {"settings.open_file", "Open Settings File", {{.Comma, {.Control}}}},
	.Reload_Settings = {"settings.reload", "Reload Settings", nil},
	.Restart_Shell = {"terminal.restart_shell", "Restart Shell", nil},
	.Hide_To_Tray = {"app.hide_to_tray", "Hide to Tray", nil},
	.Quit = {"app.quit", "Quit AIODev", nil},
}

@(require_results)
register_actions :: proc(registry: ^commands.Registry) -> commands.Error {
	@(static, rodata) actions := ACTIONS
	for info, action in actions {
		command := commands.Command{
			id = commands.Command_Id(action),
			name = info.name,
			title = info.title,
			shortcuts = {count = len(info.shortcuts)},
		}
		copy(command.shortcuts.items[:], info.shortcuts)
		if err := commands.register(registry, command); err != .None { return err }
	}
	return .None
}

shortcut_action :: proc(app: ^App, e: platform.Key_Event) -> (Action, bool) {
	shortcut := commands.Shortcut{e.key, e.modifiers}
	if command := commands.find_by_shortcut(&app.registry, shortcut); command != nil {
		return Action(command.id), true
	}
	return {}, false
}

run_action :: proc(app: ^App, w: ^Window, action: Action) {
	entry := focused_session(app, w)
	w.dirty = true
	switch action {
	case .Command_Palette:
		if app.palette.open {
			ui.palette_close(&app.palette)
			return
		}
		has_selection := entry != nil && term.has_selection(entry.session)
		registered := commands.set_enabled(&app.registry, commands.Command_Id(Action.Copy), has_selection)
		assert(registered)
		ui.palette_open(&app.palette, &app.registry)
	case .Copy:
		if entry != nil {
			copy_selection(app, entry, true)
		}
	case .Paste:
		if entry != nil {
			paste_clipboard(app, entry)
		}
	case .Select_All:
		if entry != nil {
			term.select_all(entry.session)
		}
	case .Clear_Scrollback:
		if entry != nil {
			term.clear_scrollback(entry.session)
		}
	case .Scroll_Page_Up, .Scroll_Page_Down:
		if entry != nil {
			page := max(1, int(term.geometry(entry.session).rows) - 1)
			term.scroll_viewport(entry.session, action == .Scroll_Page_Up ? -page : page)
		}
	case .Font_Size_Increase:
		set_font_points(app, app.font_points + 1)
	case .Font_Size_Decrease:
		set_font_points(app, app.font_points - 1)
	case .Font_Size_Reset:
		set_font_points(app, f32(app.settings.font.size))
	case .Open_Settings:
		if !platform.open_path(app.settings_path) {
			notify(app, .Error, fmt.tprintf("Could not open %s.", app.settings_path))
		}
	case .Reload_Settings:
		reload_settings(app)
	case .Restart_Shell:
		if entry != nil {
			session_restart(app, entry)
		}
	case .Hide_To_Tray:
		hide_to_tray(app, w)
	case .Quit:
		app.running = false
	}
}

copy_selection :: proc(app: ^App, entry: ^Session_Entry, explicit: bool) {
	text, selected := term.selection_text(entry.session, context.temp_allocator)
	if !selected {
		return
	}
	if !platform.clipboard_set_text(&app.platform, text) {
		notify(app, .Error, "Could not copy to the clipboard.")
	} else {
		ui.notices_put(&app.notices, u32(Notice_Key.Copy), .Info, "Copied to clipboard", COPY_NOTICE_DURATION)
		mark_all_dirty(app)
		if explicit { term.clear_selection(entry.session) }
	}
}

paste_clipboard :: proc(app: ^App, entry: ^Session_Entry) {
	text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator)
	if !ok || len(text) == 0 {
		return
	}
	if entry.status != .Running || !term.paste(entry.session, text) {
		notify(app, .Error, "Could not paste: the shell is not accepting input.")
	}
}

@(private)
binding_comment :: proc(info: Action_Info) -> string {
	labels: [commands.MAX_SHORTCUTS]string
	for shortcut, i in info.shortcuts {
		buffer: [128]u8
		label, err := commands.shortcut_label(shortcut, buffer[:])
		assert(err == .None)
		labels[i] = fmt.tprintf("%s", label)
	}
	if len(info.shortcuts) == 0 { return fmt.tprintf("keys.%s =", info.name) }
	joined := strings.join(labels[:len(info.shortcuts)], ", ", context.temp_allocator)
	return fmt.tprintf("keys.%s = %s", info.name, joined)
}

@(private)
binding_comments :: proc() -> [len(Action)+1]string {
	lines: [len(Action)+1]string
	lines[0] = "Shortcuts: uncomment a line to change it. Separate several with commas; " +
		"leave the value empty to remove them."
	@(static, rodata) actions := ACTIONS
	for info, action in actions {
		lines[int(action)+1] = binding_comment(info)
	}
	return lines
}

@(private)
binding_diagnostic :: proc(app: ^App, diagnostics: ^[dynamic]settings.Diagnostic,
	binding: settings.Key_Binding, message: string) {
	key := fmt.tprintf("%s%s", settings.KEY_BINDING_PREFIX, binding.name)
	if err := settings.diagnostic_append(diagnostics, binding.line, key, message); err != nil {
		log.errorf("recording shortcut diagnostic failed: %v", err)
		notify(app, .Error, message)
	}
}

@(private)
apply_bindings :: proc(app: ^App, diagnostics: ^[dynamic]settings.Diagnostic) {
	storage: [len(Action)][commands.MAX_SHORTCUTS]commands.Shortcut
	overrides: [len(Action)]commands.Override
	lines: [len(Action)]int
	count := 0
	for binding, i in app.settings.keys {
		command := commands.find(&app.registry, binding.name)
		if command == nil {
			binding_diagnostic(app, diagnostics, binding, fmt.tprintf("unknown command \"%s\"", binding.name))
			continue
		}
		n, err := commands.parse_shortcuts(binding.value, storage[count][:])
		if err != .None {
			message := fmt.tprintf("cannot parse shortcut \"%s\"", binding.value)
			if err == .Output_Too_Small { message = "at most 4 shortcuts are allowed" }
			binding_diagnostic(app, diagnostics, binding, message)
			continue
		}
		overrides[count] = {command.id, storage[count][:n]}
		lines[count] = i
		count += 1
	}
	errors: [len(Action)]commands.Error
	commands.rebind(&app.registry, overrides[:count], errors[:count])
	for error, i in errors[:count] {
		if error == .None { continue }
		binding := app.settings.keys[lines[i]]
		message := fmt.tprintf("cannot apply shortcuts for \"%s\": %v", binding.name, error)
		if error == .Duplicate_Shortcut {
			for shortcut in overrides[i].shortcuts {
				other := commands.find_by_shortcut(&app.registry, shortcut)
				if other != nil && other.id != overrides[i].id {
					buffer: [128]u8
					label, label_error := commands.shortcut_label(shortcut, buffer[:])
					assert(label_error == .None)
					message = fmt.tprintf("shortcut \"%s\" already used by %s", label, other.name)
					break
				}
			}
		}
		binding_diagnostic(app, diagnostics, binding, message)
	}
}
