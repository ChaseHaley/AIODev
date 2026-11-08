package main

import "aio:commands"
import "aio:colour"
import "aio:font"
import "aio:input"
import "aio:platform"
import "aio:pty"
import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// The row keys of the page's own action rows, which reveals select after a change.
@(private)
PROFILE_ADD_KEY :: "profiles.add"
@(private)
THEME_KEY :: "theme.name"
@(private)
THEME_NAME_KEY :: "theme.display_name"
@(private)
THEME_RENAME_KEY :: "theme.rename"

@(private)
settings_profile_row_key :: proc(id: string) -> string {
	return fmt.tprintf("%s%s", settings.PROFILE_PREFIX, id)
}

// Whether a profile's command line names an executable that exists. Explicit paths must exist;
// a bare name is resolved through the same trusted directories the terminal uses. A lookup that
// cannot run fails open so an unrelated OS problem never blocks saving; spawning still fails then.
@(private)
profile_command_exists :: proc(command: string) -> bool {
	executable, err := pty.resolve_command(command, context.temp_allocator)
	if err.kind == .Out_Of_Memory {return true}
	switch found in executable {
	case pty.Explicit_Executable:
		return os.exists(found.token)
	case pty.Searched_Executable:
		return true
	}
	return false
}

// Fills the page from the settings file, keeping its expansion and settling reorders. A failure
// leaves the page as it was.
settings_load :: proc(app: ^App, p: ^ui.Editor) -> bool {
	data, err := os.read_entire_file(app.settings_path, context.temp_allocator)
	if err != nil {
		notify(app, .Error, "Could not read settings. Check the settings path and permissions.")
		return false
	}
	view, view_error := ui.editor_view_take(p)
	defer ui.editor_view_destroy(&view)
	if view_error != nil {
		notify(app, .Error, "Could not allocate settings editor.")
		return false
	}
	page, built := settings_page_build(app, string(data), &view)
	if !built {return false}
	ui.editor_destroy(p)
	p^ = page
	return true
}

// A settings page for `source`, parsed with the running revision's inputs, with `view` (when given)
// restored once its rows exist. The page owns its copy of `source`.
@(private, require_results)
settings_page_build :: proc(app: ^App, source: string, view: ^ui.Editor_View) -> (page: ui.Editor, ok: bool) {
	p := &page
	defer if !ok {ui.editor_destroy(p)}
	owned_source, source_error := strings.clone(source)
	if source_error != nil {
		notify(app, .Error, "Could not allocate settings editor.")
		return
	}
	defer delete(owned_source)
	s, diagnostics, parse_error := settings.parse(owned_source, inputs = &app.settings_inputs)
	defer settings.diagnostics_destroy(&diagnostics)
	if parse_error != nil {
		notify(app, .Error, "Could not open settings.")
		return
	}
	defer settings.destroy(&s)
	font_items, font_error := font.installed_families(app.fonts)
	if font_error != .None && app.fonts != nil {
		notify(app, .Error, "Could not discover installed fonts. Current families remain available.")
	}
	if !settings_page_setting_rows(p, &s, font_items) {
		notify(app, .Error, "Could not allocate settings editor.")
		return
	}
	if ui.editor_process_load(p, s.process.padding_groups, s.window.padding) != nil {
		notify(app, .Error, "Could not build the program groups.")
		return
	}
	// Profiles are one dense table. The model rows come from the resolved profile list; each becomes
	// a table row plus its inline editor rows, which stay hidden until the row expands.
	table, table_error := ui.profile_table_build(&s.profiles, profile_command_exists)
	if table_error != nil {
		notify(app, .Error, "Could not build the profile table.")
		return
	}
	defer ui.profile_table_destroy(&table)
	if !settings_page_profile_rows(p, table.rows[:]) {
		notify(app, .Error, "Could not allocate the profile table.")
		return
	}
	if !settings_add_theme_rows(p, &s) || !settings_page_shortcut_rows(app, p, &s) {
		notify(app, .Error, "Could not allocate settings editor.")
		return
	}
	p.capture.leader = app.leader
	if view != nil {ui.editor_view_restore(p, view)}
	ui.editor_hover_clear(p)
	ui.editor_filter(p)
	if len(diagnostics) > 0 {
		ui.editor_message(
			p,
			"File has diagnostics; invalid settings show defaults. Only the selected key is changed.",
			true,
		)
	}
	ui.editor_revision_open(p, owned_source)
	owned_source = ""
	return page, true
}

// One row per schema setting that has its own row; group settings have their own editor and
// embedded ones live inside another setting's control.
@(private, require_results)
settings_page_setting_rows :: proc(p: ^ui.Editor, s: ^settings.Settings, fonts: []font.Family_Info) -> bool {
	@(static, rodata)
	schema := settings.SCHEMA
	for &entry in schema {
		if entry.control == .Group || entry.embedded {continue}
		row := ui.schema_row(entry)
		row.value = settings.value_text(s, entry)
		if row.multiple {row.choice_mask, _, _ = settings.set_parse(entry.names, row.value)}
		if choices, labels, live := setting_live_choices(s, fonts, entry.live_choices); live {
			row.choices, row.choice_labels = choices, labels
		}
		if filter := settings.schema_find(entry.choice_filter); filter != nil {
			row.show_all_fonts = settings.value_text(s, filter^) == "true"
		}
		if entry.page_description != "" {row.description = entry.page_description}
		if ui.editor_add(p, row, settings.group_title(entry.key)) != nil {return false}
	}
	return true
}

@(private, require_results)
settings_page_profile_rows :: proc(p: ^ui.Editor, profiles: []ui.Profile_Row) -> bool {
	group := SETTINGS_SECTIONS[.Profiles].title
	for row in profiles {
		flags: bit_set[ui.Editor_Row_Flag]
		if row.is_default {flags += {.Default}}
		if row.hidden {flags += {.Hidden}}
		if row.listed {flags += {.Listed}}
		if row.detected {flags += {.Builtin}}
		if !row.removable {flags += {.Protected}}
		detail := fmt.tprintf(
			"%s %s %s name command line starting directory icon hidden duplicate remove",
			row.command,
			row.directory,
			row.icon,
		)
		table_row := ui.Editor_Row {
			key         = settings_profile_row_key(row.id),
			title       = row.name,
			description = row.command,
			value       = row.directory,
			detail      = detail,
			profile     = row.id,
			badge       = row.badge,
			note        = row.note,
			kind        = .Profile,
			flags       = flags,
		}
		if ui.editor_add(p, table_row, group) != nil {return false}
		fields := [settings.Profile_Field]ui.Editor_Row {
			.Name = {
				title = "Name",
				description = "Shown in menus, tabs and the palette.",
				value = row.name,
				default_value = row.name,
				kind = .Text,
			},
			.Command = {
				title = "Command line",
				description = "Executable and arguments.",
				value = row.command,
				default_value = settings.DEFAULT_PROFILE_COMMAND,
				kind = .Text,
			},
			.Directory = {
				title = "Starting directory",
				description = "Empty inherits the default starting directory.",
				value = row.directory,
				default_value = settings.DEFAULT_PROFILE_DIRECTORY,
				kind = .Text,
			},
			.Icon = {
				title = "Icon",
				description = "PNG path; empty uses the executable's text badge.",
				value = row.icon,
				badge = row.badge,
				kind = .Profile_Icon,
			},
			.Hidden = {
				title = "Show in menus",
				description = "Include this profile in shell menus.",
				value = row.hidden ? "false" : "true",
				default_value = "true",
				kind = .Toggle,
			},
		}
		for &field_row, field in fields {
			field_row.key = settings.profile_field_key(row.id, field)
			field_row.profile, field_row.profile_field = row.id, field
			if ui.editor_add(p, field_row, group) != nil {return false}
		}
	}
	add := ui.Editor_Row {
		key         = PROFILE_ADD_KEY,
		title       = "Add Profile",
		description = "Add a shell with its own command line and starting directory.",
		value       = "Add Profile",
		kind        = .Profile_Add,
	}
	if ui.editor_add(p, add, group) != nil {return false}
	ui.editor_group_table(p, group)
	return true
}

// One row per command a key can run, showing the file's shortcuts or the defaults.
@(private, require_results)
settings_page_shortcut_rows :: proc(app: ^App, p: ^ui.Editor, s: ^settings.Settings) -> bool {
	for command in app.registry.items {
		if command.hidden {continue}
		value := commands.shortcut_set_text(command.shortcuts, context.temp_allocator)
		for binding in s.keys {if binding.name == command.name {value = binding.value; break}}
		row := ui.Editor_Row {
			key           = settings.binding_key(command.name),
			title         = command.title,
			value         = value,
			default_value = commands.shortcut_set_text(command.defaults, context.temp_allocator),
			kind          = .Shortcut,
		}
		if ui.editor_add(p, row, commands.category(command.name).group) != nil {return false}
	}
	return true
}

// Saves the font list's other filter, the setting the font descriptor names. Publication rebuilds
// the page with that filter's fonts, so the page changes only once the file has.
@(private)
editor_font_filter :: proc(app: ^App, w: ^Window) {
	p := &w.editor
	row := ui.editor_row(p)
	if row == nil || !row.font_filter {return}
	entry := settings.schema_find(row.key)
	if entry == nil || entry.choice_filter == "" {return}
	query := strings.clone(ui.field_string(&p.choice_search), context.temp_allocator)
	focused := ui.editor_choice_toggle_focused(p)
	value := row.show_all_fonts ? "false" : "true"
	result := settings_change(app, Setting_Value{entry.choice_filter, value}, Settings_Page{p})
	_ = settings_page_report(p, result, .Font_Filter)
	ui.editor_font_search_restore(p, query, focused)
}

editor_outcome :: proc(app: ^App, w: ^Window, outcome: ui.Editor_Outcome) {
	p := &w.editor
	// The outcome that names a request is the only one that may act on it.
	request := ui.editor_request_take(p)
	defer ui.editor_request_destroy(&request)
	if outcome == .None {return}
	w.dirty = true
	ui.editor_outcome_begin(p, outcome)
	switch outcome {
	case .None, .Changed:
		return
	case .Reset_All:
		settings_reset_ask(app, w)
		return
	case .Font_Filter:
		editor_font_filter(app, w)
		return
	case .Process_Remove:
		if remove, ok := request.(ui.Process_Remove_Request); ok {
			editor_process_remove_ask(app, w, remove.group)
		}
		return
	case .Process_Save:
		editor_process_save(app, w)
		return
	case .Profile_Action:
		editor_profile_action(app, w, request)
		return
	case .Save, .Reset:
	}
	row := ui.editor_row(p)
	if row == nil {return}
	if row.process_field != .None {
		if row.process_field == .Add_Group || row.process_field == .Add_Program {
			_ = ui.editor_process_activate(p, row)
		} else {editor_process_save(app, w)}
		return
	}
	if row.kind == .Profile_Add {
		editor_profile_mutate(app, w, {kind = .Add})
		return
	}
	// A color's reset returns it to its base theme instead of writing the shown default.
	if outcome == .Reset && row.action != .Theme_Color {ui.field_set(&p.value, row.default_value)}
	if field, is_field := row.profile_field.?; is_field {
		editor_profile_field(app, w, row.profile, field)
		return
	}
	switch row.action {
	case .None:
		editor_setting_save(app, w, row, outcome == .Reset)
	case .Theme_Color:
		editor_theme_color(app, w, row, outcome == .Reset)
	case .Theme_Name:
		if _, applied := editor_theme_change(app, w, Theme_Name{ui.field_string(&p.value)}); applied {
			editor_theme_reveal(w, THEME_NAME_KEY, "Theme name saved.")
		}
	case .Theme_Rename:
		new_id := strings.clone(strings.trim_space(ui.field_string(&p.value)), context.temp_allocator)
		if _, applied := editor_theme_change(app, w, Theme_Rename{new_id}); applied {
			editor_theme_reveal(w, THEME_RENAME_KEY, fmt.tprintf("Theme renamed to %s.", new_id))
		}
	case .Theme_Duplicate:
		if result, applied := editor_theme_change(app, w, Theme_Duplicate{}); applied {
			editor_theme_reveal(w, THEME_RENAME_KEY, fmt.tprintf("Saved as new theme %s.", result.id))
		}
	case .Theme_Delete:
		// Deleting discards colors that exist nowhere else, so it takes a second press.
		if !ui.editor_theme_delete_press(p) {return}
		if result, applied := editor_theme_change(app, w, Theme_Remove{}); applied {
			editor_theme_reveal(w, THEME_KEY, fmt.tprintf("Theme deleted. Using %s.", result.id))
		}
	case .Theme_Export:
		path, error := settings.theme_export(&app.settings, app.settings_inputs.themes_directory)
		if error != nil {
			ui.editor_message(p, "Could not export theme. Check the themes folder permissions.", true)
		} else {
			ui.editor_message(p, fmt.tprintf("Theme saved to %s", path), false)
		}
	}
}

// Saves the selected schema setting or shortcut.
@(private)
editor_setting_save :: proc(app: ^App, w: ^Window, row: ^ui.Editor_Row, reset: bool) {
	p := &w.editor
	key := strings.clone(row.key, context.temp_allocator)
	kind := row.kind
	value := ui.field_string(&p.value)
	// A combination of choices is edited as option bits; the file stores their names.
	if row.multiple && !reset {value = settings.set_text(row.choices, ui.editor_choice_set(p))}
	value = strings.clone(value, context.temp_allocator)
	result := settings_change(app, Setting_Value{key, value}, Settings_Page{p})
	if !settings_page_report(p, result, .Setting) {return}
	if kind == .Shortcut {ui.editor_browse(p)}
	text := "Saved and applied."
	if result.message != "" {text = fmt.tprintf("Saved. %s", result.message)}
	if entry := settings.schema_find(key); entry != nil && entry.apply_timing == .New_Sessions {
		text = "Saved. Initial size applies to new sessions."
	}
	ui.editor_message(p, text, false)
}

// Reports a profile change: one that did not apply on the page, one that did by showing
// `select_key` with `message`, scrolled where the page was.
@(private)
editor_profile_saved :: proc(
	w: ^Window,
	result: Settings_Result,
	workflow: Settings_Workflow,
	select_key, message: string,
	focus := Reveal_Focus.None,
) {
	if !settings_page_report(&w.editor, result, workflow) {return}
	ui.editor_browse(&w.editor)
	settings_reveal_page(
		&w.editor,
		{key = select_key, search = .Preserve, message = message, focus = focus, keep_scroll = true},
	)
}

// Validates and writes one inline profile field. Empty names and commands, duplicate names and a
// command line whose executable cannot be found stay inline: the row is ringed, the field carries
// the message, and no modal appears.
@(private)
editor_profile_field :: proc(app: ^App, w: ^Window, profile: string, field: settings.Profile_Field) {
	id := strings.clone(profile, context.temp_allocator)
	value := strings.clone(ui.field_string(&w.editor.value), context.temp_allocator)
	key := settings.profile_field_key(id, field)
	message := "Saved."
	focus := Reveal_Focus.Control
	switch field {
	case .Command, .Directory:
		message = "Saved. Applies to new or restarted shells."
	case .Hidden:
		// The toggle shows "Show in menus"; the file stores the opposite.
		value = value == "true" ? "false" : "true"
		focus = .None
	case .Name, .Icon:
	}
	result := settings_change(app, Profile_Field_Value{id, field, value}, Settings_Page{&w.editor})
	if result.status == .Refused {
		ui.editor_error_set(&w.editor, id, key, result.message)
		ui.editor_message(&w.editor, result.message, true)
		return
	}
	editor_profile_saved(w, result, .Profile_Field, key, message, focus)
}

@(private)
editor_profile_mutate :: proc(app: ^App, w: ^Window, change: settings.Profile_Mutation) {
	result := settings_change(app, change, Settings_Page{&w.editor})
	if result.status == .Unchanged {return}
	if result.status != .Applied {
		_ = settings_page_report(&w.editor, result, .Profile)
		return
	}
	key := settings_profile_row_key(result.id)
	message: string
	switch change.kind {
	case .Add:
		message = "Profile added. Change its command line or name."
	case .Duplicate:
		message = "Profile duplicated. Change its name or command line."
	case .Remove:
		message, key = "Profile removed.", PROFILE_ADD_KEY
	case .Move:
		message = "Profile order saved. Menus and Ctrl+Shift+1 to 9 follow it."
	}
	// The reveal rebuilds the published page, which then opens the new profile's inline editor.
	if change.kind == .Add || change.kind == .Duplicate {
		ui.editor_profile_set_expanded(&w.editor, result.id)
	} else if change.kind == .Remove && w.editor.expanded == result.id {
		ui.editor_profile_set_expanded(&w.editor, "")
	}
	editor_profile_saved(w, result, .Profile, key, message)
}

// Performs the profile write a table control asked for.
@(private)
editor_profile_action :: proc(app: ^App, w: ^Window, request: ui.Editor_Request) {
	#partial switch r in request {
	case ui.Profile_Request:
		switch r.action {
		case .Default:
			result := settings_change(
				app, Setting_Value{"shell.default_profile", r.id}, Settings_Page{&w.editor},
			)
			editor_profile_saved(
				w,
				result,
				.Profile_Field,
				settings_profile_row_key(r.id),
				"Default profile saved. New tabs, splits and the plus button use it.",
			)
		case .Duplicate:
			editor_profile_mutate(app, w, {kind = .Duplicate, id = r.id})
		case .Remove:
			editor_profile_remove_ask(app, w, r.id)
		}
	case ui.Profile_Hidden_Request:
		value := Profile_Field_Value{r.id, .Hidden, r.hidden ? "true" : "false"}
		editor_profile_saved(
			w,
			settings_change(app, value, Settings_Page{&w.editor}),
			.Profile_Field,
			settings_profile_row_key(r.id),
			r.hidden ? "Profile hidden from menus." : "Profile shown in menus.",
		)
	case ui.Profile_Order_Request:
		editor_profile_mutate(app, w, {kind = .Move, id = r.id, slot = r.slot})
	}
}

// The choices of a setting whose list depends on installed themes or fonts; `live` is false for the
// rest. A font list always includes the current family, even when it is not installed.
setting_live_choices :: proc(
	s: ^settings.Settings,
	fonts: []font.Family_Info,
	source: settings.Live_Choices,
) -> (
	choices, labels: []string,
	live: bool,
) {
	switch source {
	case .None:
	case .Themes:
		choices, labels = settings_theme_choices(s)
		return choices, labels, true
	case .Shell_Fonts:
		return font.family_choices(fonts, s.font.show_all, s.font.family), nil, true
	case .Interface_Fonts:
		return font.family_choices(fonts, true, s.interface.font_family), nil, true
	}
	return nil, nil, false
}

// The theme selector lists theme files by display name, then custom themes in settings file order.
// Choices are IDs and labels are display names. The editor owns its copies, so both slices may
// borrow the parsed settings.
@(private)
settings_theme_choices :: proc(s: ^settings.Settings) -> (choices, labels: []string) {
	files := make([dynamic]^settings.Custom_Theme, 0, len(s.themes), context.temp_allocator)
	for &theme in s.themes {
		if theme.external {append(&files, &theme)}
	}
	slice.sort_by(files[:], proc(a, b: ^settings.Custom_Theme) -> bool {
		a_name, b_name := a.name != "" ? a.name : a.id, b.name != "" ? b.name : b.id
		return a_name != b_name ? a_name < b_name : a.id < b.id
	})
	ids := make([dynamic]string, 0, len(s.themes), context.temp_allocator)
	names := make([dynamic]string, 0, len(s.themes), context.temp_allocator)
	for theme in files {
		append(&ids, theme.id)
		append(&names, settings.theme_display_name(s, theme.id))
	}
	for theme in s.themes {
		if theme.external {continue}
		append(&ids, theme.id)
		append(&names, settings.theme_display_name(s, theme.id))
	}
	return ids[:], names[:]
}

// The active theme's management rows and one row per theme color. Every color shows the value in
// effect; a custom theme's Reset returns a color to its base theme.
@(private)
settings_add_theme_rows :: proc(p: ^ui.Editor, s: ^settings.Settings) -> bool {
	if ui.editor_theme_set(p, s.theme.name) != nil {return false}
	duplicate := ui.Editor_Row {
		key         = "theme.duplicate",
		title       = "Save as New Theme",
		description = fmt.tprintf(
			"Copy %s into a custom theme you can edit.",
			settings.theme_display_name(s, s.theme.name),
		),
		value       = "Save Copy",
		kind        = .Action,
		action      = .Theme_Duplicate,
	}
	if settings.theme_custom(s) {
		custom := settings.custom_theme_find(s, s.theme.name)
		duplicate.description = "Copy this theme with all its colors and switch to the copy."
		rows := [?]ui.Editor_Row {
			{
				key = THEME_NAME_KEY,
				title = "Theme Name",
				description = "Shown in the theme selector. Any text; empty shows the theme ID.",
				value = custom.name,
				kind = .Text,
				action = .Theme_Name,
			},
			{
				key = THEME_RENAME_KEY,
				title = "Theme ID",
				description = "Renames this custom theme. Use lowercase letters, digits, - and _.",
				value = custom.id,
				default_value = custom.id,
				kind = .Text,
				action = .Theme_Rename,
			},
			duplicate,
			{
				key = "theme.delete",
				title = "Delete Theme",
				description = fmt.tprintf(
					"Remove this custom theme and switch to %s.",
					settings.theme_display_name(s, settings.theme_delete_target(s, custom)),
				),
				value = "Delete…",
				kind = .Action,
				action = .Theme_Delete,
			},
		}
		for row in rows {
			if ui.editor_add(p, row, settings.group_title("theme.name")) != nil {return false}
		}
	} else if ui.editor_add(p, duplicate, settings.group_title("theme.name")) != nil {return false}
	if ui.editor_add(p, {
		key = "theme.export",
		title = "Export Theme File",
		description = "Save a portable JSON file in the themes folder. Share it with its schema file.",
		kind = .Action,
		value = "Export",
		action = .Theme_Export,
	}, settings.group_title("theme.name")) != nil {return false}
	base := settings.theme_base(s)
	tokens := settings.THEME_TOKENS
	for token in settings.Theme_Token {
		info := tokens[token]
		row := ui.Editor_Row {
			key           = fmt.tprintf("%s%s", SETTINGS_COLOR_PREFIX, info.key),
			title         = info.title,
			description   = info.description,
			value         = settings.theme_color_text(token, s.active_theme.colors[token]),
			default_value = settings.theme_color_text(token, base.colors[token]),
			kind          = info.kind == .Optional ? .Optional_Color : .Color,
			action        = .Theme_Color,
		}
		group := settings.token_terminal(token) ? "Terminal Colors" : "Interface Colors"
		if ui.editor_add(p, row, group) != nil {return false}
	}
	return true
}

// Applies a theme change made on the page; a change that does not apply is reported there.
@(private)
editor_theme_change :: proc(app: ^App, w: ^Window, change: Theme_Change) -> (Settings_Result, bool) {
	result := settings_change(app, change, Settings_Page{&w.editor})
	return result, settings_page_report(&w.editor, result, .Theme)
}

// An action that replaces its own row selects `select_key` on the published page.
@(private)
editor_theme_reveal :: proc(w: ^Window, select_key, message: string) {
	settings_reveal_page(&w.editor, {key = select_key, search = .Preserve, message = message})
}

// Sets or resets one color; the published page keeps the edited row selected.
@(private)
editor_theme_color :: proc(app: ^App, w: ^Window, row: ^ui.Editor_Row, reset: bool) {
	token_key := strings.clone(row.key[len(SETTINGS_COLOR_PREFIX):], context.temp_allocator)
	value := reset ? "" : strings.clone(ui.field_string(&w.editor.value), context.temp_allocator)
	alpha_dropped := false
	if token, found := settings.token_find(token_key); found && value != "" {
		tokens := settings.THEME_TOKENS
		_, _, alpha := colour.parse(value, .Permissive)
		alpha_dropped = alpha && tokens[token].kind != .Translucent
	}
	result, applied := editor_theme_change(app, w, Theme_Color{token_key, value})
	if result.status == .Unchanged {
		ui.editor_message(&w.editor, "Theme files keep their colors; changing one saves a custom theme.", false)
	}
	if !applied {return}
	message := "Saved and applied."
	if result.id != "" {message = fmt.tprintf("Saved as new theme %s.", result.id)}
	if alpha_dropped {message = fmt.tprintf("%s This color is opaque, so its alpha is ignored.", message)}
	if reset {message = "Color returned to the base theme."}
	ui.editor_message(&w.editor, message, false)
}

// Plain and shifted keys type or navigate, and these Ctrl chords edit text or move through the list.
@(private)
editor_owns :: proc(e: input.Key_Event) -> bool {
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
settings_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	pane_header_cancel(w)
	p := &w.editor
	_ = settings_layout(w)
	w.dirty = true
	key_suppress(w, e)
	// Escape backs out of a delete prompt even when the page has nothing else to leave.
	if e.pressed && e.key == .Escape {ui.editor_theme_delete_disarm(p)}
	if ui.editor_capturing(p) {
		editor_outcome(app, w, ui.editor_key(p, e))
		return
	}
	key, consumed := content_key_prelude(app, w, e, false)
	if consumed {return}
	switch key.clipboard {
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
	if key.found && !editor_owns(key.logical) {
		run_action(app, w, key.action)
		return
	}
	editor_outcome(app, w, ui.editor_key(p, e))
}

// The custom profile a confirmation asks before deleting, and its name as the page showed it.
Profile_Remove :: struct {
	id, name: string,
}

editor_profile_remove_text :: proc(remove: Profile_Remove) -> Confirmation_Text {
	text := Confirmation_Text{title = "Delete profile?", label = "Delete"}
	if remove.name != "" {text.title = fmt.tprintf("Delete %s?", remove.name)}
	return text
}

// Asks before deleting a profile the page lists and may delete.
editor_profile_remove_ask :: proc(app: ^App, w: ^Window, id: string) {
	for row in w.editor.rows {
		if row.kind != .Profile || row.profile != id {continue}
		if .Protected in row.flags {return}
		owned, err := strings.clone(id)
		name, name_error := strings.clone(row.title)
		if err != nil || name_error != nil {
			delete(owned)
			delete(name)
			notify(app, .Error, "Could not prepare profile deletion.")
			return
		}
		overlay_close_all(app, w)
		confirmation_open(w, Profile_Remove{owned, name}, focus = .Cancel)
		return
	}
}

@(private)
editor_profile_remove_finish :: proc(app: ^App, w: ^Window, remove: Profile_Remove, accepted: bool) {
	if accepted {editor_profile_mutate(app, w, {kind = .Remove, id = remove.id})}
}

editor_profile_remove_destroy :: proc(remove: ^Profile_Remove) {
	delete(remove.id)
	delete(remove.name)
}

when AIO_CONTROL {
	// The settings page's verification keys, with the page's row geometry as the drawer lays it out.
	settings_page_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		p := &w.editor
		key, title := "", ""
		choice_count := 0
		if row := ui.editor_row(p); row != nil {
			key, title = row.key, row.title
			choice_count = len(row.choices)
		}
		selected: ui.Row_Parts
		page: ui.Editor_Layout
		if settings_active(w) {
			page = settings_layout(w)
			if len(p.items) > 0 {selected = ui.editor_row_parts(p, page, p.selected)}
		}
		question := confirmation_shown(w)
		process_remove := confirmation_asking(w, Process_Remove) != nil
		removing := confirmation_subject(w, Profile_Remove)
		_, menu_open := p.mode.(ui.Editor_Profile_Menu)
		detected := 0
		for &profile in app.settings.profiles.items {
			if profile.detected {detected += 1}
		}
		profile_group := -1
		for group, index in p.groups {
			if group.title == SETTINGS_SECTIONS[.Profiles].title {profile_group = index; break}
		}
		state_value(r, "settings.open", ui.editor_loaded(p))
		state_text(r, "settings.revision", settings_page_revision_word(p))
		state_value(r, "settings.theme_delete_armed", p.delete_armed)
		state_text(r, "settings.filter", string(p.filter.bytes[:]))
		state_value(r, "settings.scroll", p.scroll)
		state_value(r, "settings.group", ui.editor_active_group(p))
		state_text(r, "settings.key", key)
		state_text(r, "settings.value", string(p.value.bytes[:]))
		state_value(r, "settings.editing", ui.editor_editing(p))
		state_value(r, "settings.active", settings_active(w))
		state_value(r, "settings.popup", ui.editor_popup(p))
		state_value(r, "settings.choice_count", choice_count)
		state_text(r, "settings.choice_query", ui.field_string(&p.choice_search))
		state_value(r, "settings.choice_matches", len(p.choice_matches))
		state_value(r, "settings.capturing", ui.editor_capturing(p))
		state_text(r, "settings.title", title)
		state_text(r, "settings.message", p.message)
		state_value(r, "settings.error", p.error)
		state_text(r, "settings.process.rows", settings_page_row_rects(p, page, .Process))
		state_value(r, "settings.process.expanded", p.process_expanded)
		state_value(r, "settings.process.dragging", ui.editor_order_dragging(p, .Process_Groups))
		state_value(r, "settings.process.drag_target", ui.editor_order_target(p))
		state_text(r, "settings.process.value", app.settings.process.padding_groups)
		state_value(r, "settings.process.confirming", process_remove)
		state_value(r, "settings.process.confirm_option", process_remove && question.dialog.show_option)
		state_text(r, "settings.profile.expanded", p.expanded)
		state_text(r, "settings.profile.default", app.settings.profiles.default_id)
		// The page no longer has a detected-profile section; its keys keep their empty values.
		state_text(r, "settings.profile.detected_open", "false")
		state_text(r, "settings.profile.removing", confirmation_asking(w, Profile_Remove) != nil ? removing.id : "")
		remove_title := removing != nil ? editor_profile_remove_text(removing^).title : "Delete profile?"
		state_text(r, "settings.profile.remove_title", remove_title)
		state_value(r, "settings.profile.menu_open", menu_open)
		state_value(r, "settings.profile.menu_count", len(p.profile_menu.items))
		state_value(r, "settings.profile.action", p.request)
		state_text(r, "settings.profile.error_key", p.error_key)
		state_text(r, "settings.profile.error", p.error_text)
		state_value(r, "settings.profile.control", p.profile_control)
		columns := ui.profile_columns(page.list, page.scale)
		state_value(r, "settings.profile.directory_shown", columns.directory_shown)
		state_text(r, "settings.profile.rows", settings_page_row_rects(p, page, .Profile))
		state_text(r, "settings.profile.detected_rows", "")
		state_text(r, "settings.profile.detected_header", "")
		state_value(r, "settings.profile.app_count", len(app.settings.profiles.items))
		state_value(r, "settings.profile.app_detected", detected)
		state_value(r, "settings.profile.group", profile_group)
		state_value(r, "settings.profile.dragging", ui.editor_order_dragging(p, .Profiles))
		state_value(r, "settings.profile.drag_target", ui.editor_order_target(p))
		state_text(r, "settings.profile.drag_id", ui.editor_order_profile(p))
		state_rect(r, "settings.slider", selected.slider)
		state_rect(r, "settings.search_rect", page.filter)
		state_rect(r, "settings.outline_rect", page.outline)
		state_rect(r, "settings.list_rect", page.list)
	}

	// Current pages report draft while they hold pending work, derived rather than stored.
	@(private = "file")
	settings_page_revision_word :: proc(p: ^ui.Editor) -> string {
		switch revision in p.revision {
		case ui.Editor_Current:
			return ui.editor_draft(p) ? "draft" : "fresh"
		case ui.Editor_Stale:
			switch revision.reason {
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

	@(private = "file")
	Settings_Page_Table :: enum {
		Process,
		Profile,
	}

	// A table's rows as key@x,y,w,h (process) or id@x,y,w,h (profile), joined by ';', so a live
	// journey can aim a drag at a row's grip.
	@(private = "file")
	settings_page_row_rects :: proc(
		p: ^ui.Editor,
		page: ui.Editor_Layout,
		table: Settings_Page_Table,
	) -> string {
		builder := strings.builder_make(context.temp_allocator)
		first := true
		for item, index in p.items {
			if item.row < 0 {continue}
			row := &p.rows[item.row]
			name: string
			switch table {
			case .Process:
				if row.process_field == .None {continue}
				name = row.key
			case .Profile:
				if row.kind != .Profile {continue}
				name = row.profile
			}
			rect := ui.editor_row_parts(p, page, index).row
			if !first {strings.write_byte(&builder, ';')}
			first = false
			fmt.sbprintf(&builder, "%s@%g,%g,%g,%g", name, rect.x, rect.y, rect.width, rect.height)
		}
		return strings.to_string(builder)
	}
}
