package main

import "core:fmt"
import "core:log"
import "aio:commands"
import "aio:input"
import "aio:platform"
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
	shortcut: Maybe(commands.Shortcut),
}

@(private)
ACTIONS :: [Action]Action_Info{
	.Command_Palette = {"app.command_palette", "Show Command Palette", commands.Shortcut{.P, {.Control, .Shift}}},
	.Copy = {"edit.copy", "Copy", commands.Shortcut{.C, {.Control, .Shift}}},
	.Paste = {"edit.paste", "Paste", commands.Shortcut{.V, {.Control, .Shift}}},
	.Select_All = {"edit.select_all", "Select All", commands.Shortcut{.A, {.Control, .Shift}}},
	.Clear_Scrollback = {"terminal.clear_scrollback", "Clear Scrollback", commands.Shortcut{.K, {.Control, .Shift}}},
	.Scroll_Page_Up = {"terminal.scroll_page_up", "Scroll Up One Page", commands.Shortcut{.Page_Up, {.Shift}}},
	.Scroll_Page_Down = {"terminal.scroll_page_down", "Scroll Down One Page", commands.Shortcut{.Page_Down, {.Shift}}},
	.Font_Size_Increase = {"view.font_size_increase", "Increase Font Size", commands.Shortcut{.Equal, {.Control}}},
	.Font_Size_Decrease = {"view.font_size_decrease", "Decrease Font Size", commands.Shortcut{.Minus, {.Control}}},
	.Font_Size_Reset = {"view.font_size_reset", "Reset Font Size", commands.Shortcut{.Digit_0, {.Control}}},
	.Open_Settings = {"settings.open_file", "Open Settings File", commands.Shortcut{.Comma, {.Control}}},
	.Reload_Settings = {"settings.reload", "Reload Settings", nil},
	.Restart_Shell = {"terminal.restart_shell", "Restart Shell", nil},
	.Hide_To_Tray = {"app.hide_to_tray", "Hide to Tray", nil},
	.Quit = {"app.quit", "Quit AIODev", nil},
}

// Second bindings that WezTerm users expect alongside the primary shortcuts.
@(private)
ALTERNATE_SHORTCUTS :: [?]struct {
	shortcut: commands.Shortcut,
	action: Action,
}{
	{{.Insert, {.Control}}, .Copy},
	{{.Insert, {.Shift}}, .Paste},
	{{.Equal, {.Control, .Shift}}, .Font_Size_Increase},
	{{.Numpad_Add, {.Control}}, .Font_Size_Increase},
	{{.Numpad_Subtract, {.Control}}, .Font_Size_Decrease},
	{{.Numpad_0, {.Control}}, .Font_Size_Reset},
}

register_actions :: proc(app: ^App) {
	@(static, rodata) actions := ACTIONS
	for info, action in actions {
		command := commands.Command{
			id = commands.Command_Id(action),
			name = info.name,
			title = info.title,
			shortcut = info.shortcut,
		}
		if err := commands.register(&app.registry, command); err != .None {
			log.errorf("registering %s failed: %v", info.name, err)
		}
	}
}

shortcut_action :: proc(app: ^App, e: platform.Key_Event) -> (Action, bool) {
	shortcut := commands.Shortcut{e.key, e.modifiers}
	if command := commands.find_by_shortcut(&app.registry, shortcut); command != nil {
		return Action(command.id), true
	}
	ignored := input.Modifiers{.Caps_Lock, .Num_Lock, .Right_Shift, .Right_Control, .Right_Alt, .Right_Super}
	for alternate in ALTERNATE_SHORTCUTS {
		if alternate.shortcut.key == e.key && alternate.shortcut.modifiers == e.modifiers - ignored {
			return alternate.action, true
		}
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
	} else if explicit {
		term.clear_selection(entry.session)
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
