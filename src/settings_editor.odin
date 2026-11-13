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
OPENER_ADD_KEY :: "openers.add"
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

@(private)
settings_opener_row_key :: proc(id: string) -> string {
	return fmt.tprintf("%s%s", settings.OPENER_PREFIX, id)
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

// Fills the page from the settings file, keeping its expansion and settling reorders, or restoring
// `kept` instead when given. A failure leaves the page as it was.
settings_load :: proc(app: ^App, p: ^ui.Editor, kept: ^ui.Editor_View = nil) -> bool {
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
	page, built := settings_page_build(app, string(data), kept != nil ? kept : &view)
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
	if ui.editor_motion_load(p, &s) != nil {
		notify(app, .Error, "Could not build the motion settings.")
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
	// Link programs follow the profile table's shape: a line per program, its fields under it.
	if !settings_page_opener_rows(p, &s.openers) {
		notify(app, .Error, "Could not allocate the link program table.")
		return
	}
	if !settings_add_theme_rows(p, &s) ||
	   !settings_theme_strip_load(p, &s) ||
	   !settings_page_shortcut_rows(app, p, &s) {
		notify(app, .Error, "Could not allocate settings editor.")
		return
	}
	p.capture.leader = app.leader
	settings_page_sections(p)
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

// The page's top sections: the tabs above its list. The left outline lists the shown section's groups.
Settings_Area :: enum {
	General,
	Advanced,
	Shortcuts,
	Colors,
}

// Indexed by Settings_Area. A global, so the page's slice of it outlives the call that sets it.
@(rodata)
SETTINGS_AREA_TITLES := [len(Settings_Area)]string{"General", "Advanced", "Shortcuts", "Colors"}

// Each named group's section, in page order. Command shortcut groups are not listed: they follow
// these in Shortcuts, in the order the registry adds them.
@(private, rodata)
SETTINGS_GROUP_AREAS := [?]struct {
	title: string,
	area:  Settings_Area,
} {
	{"Theme", .General},
	{"Font", .General},
	{"Interface", .General},
	{"Window", .General},
	{"Tabs", .General},
	{"Panes", .General},
	{"Terminal", .General},
	{"Cursor", .General},
	{"Scrollback", .General},
	{"Shell", .General},
	{"Program Status", .General},
	{"Motion", .Advanced},
	{"Profiles", .Advanced},
	{"Link Programs", .Advanced},
	{"Processes", .Advanced},
	{"Command Line", .Advanced},
	{"Input", .Shortcuts},
	{THEME_MANAGE_GROUP, .Colors},
}

// The section a group's title belongs to and its place there; theme color groups follow Manage Theme.
settings_group_area :: proc(title: string) -> (area: Settings_Area, rank: int) {
	for entry, i in SETTINGS_GROUP_AREAS {
		if entry.title == title {return entry.area, i}
	}
	if color_rank, color := settings_color_group_area(title); color {return .Colors, color_rank}
	return .Shortcuts, len(SETTINGS_GROUP_AREAS)
}

@(private)
settings_page_sections :: proc(p: ^ui.Editor) {
	p.sections = SETTINGS_AREA_TITLES[:]
	for &group in p.groups {
		area, rank := settings_group_area(group.title)
		group.section, group.rank = int(area), rank
	}
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
				description = "PNG path; empty uses the shell's own icon, else its text badge.",
				value = row.icon,
				badge = row.badge,
				kind = .Icon_File,
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

// One table line per link program in opener.order order, each followed by its field rows, which
// stay hidden until the line expands, then the Add row.
@(private, require_results)
settings_page_opener_rows :: proc(p: ^ui.Editor, openers: ^settings.Openers) -> bool {
	group := SETTINGS_SECTIONS[.Link_Programs].title
	offers_names, offers_labels := settings.opener_offers_choices()
	placement_names, placement_labels := settings.OPENER_PLACEMENT_NAME, settings.OPENER_PLACEMENT_LABEL
	indices: [settings.OPENER_LIMIT]int
	for index in indices[:settings.openers_in_order(openers, indices[:])] {
		opener := &openers.items[index]
		line := ui.Editor_Row {
			key         = settings_opener_row_key(opener.id),
			title       = opener.name,
			description = opener.command,
			value       = placement_labels[opener.placement],
			detail      = fmt.tprintf(
				"link program open with %s %s",
				settings.set_text(offers_labels, u32(transmute(u8)opener.offers)),
				placement_labels[opener.placement],
			),
			opener      = opener.id,
			kind        = .Opener,
		}
		if ui.editor_add(p, line, group) != nil {return false}
		fields := [settings.Opener_Field]ui.Editor_Row {
			.Name = {
				title = "Name",
				description = "Shown in link menus.",
				value = opener.name,
				default_value = opener.name,
				kind = .Text,
			},
			.Command = {
				title = "Command line",
				description = "%1 is the file or folder; without %1 it follows the command.",
				value = opener.command,
				default_value = opener.command,
				kind = .Text,
			},
			.Icon = {
				title = "Icon",
				description = "PNG path; empty finds one, such as Neovim's.",
				value = opener.icon,
				kind = .Icon_File,
			},
			.Offers = {
				title = "Offered for",
				description = "The links whose menu lists this program.",
				value = settings.opener_offers_text(opener.offers),
				default_value = settings.opener_offers_text(settings.OPENER_OFFERS_ALL),
				kind = .Choice,
				multiple = true,
				choice_mask = u32(transmute(u8)opener.offers),
				choices = offers_names,
				choice_labels = offers_labels,
			},
			.Placement = {
				title = "Opens in",
				description = "Where the program runs.",
				value = placement_names[opener.placement],
				default_value = placement_names[.Right_Split],
				kind = .Choice,
				choices = slice.enumerated_array(&placement_names),
				choice_labels = slice.enumerated_array(&placement_labels),
			},
		}
		for &field_row, field in fields {
			field_row.key = settings.opener_field_key(opener.id, field)
			field_row.opener, field_row.opener_field = opener.id, field
			if ui.editor_add(p, field_row, group) != nil {return false}
		}
	}
	add := ui.Editor_Row {
		key         = OPENER_ADD_KEY,
		title       = "Add Link Program",
		description = "Offer a program, such as an editor, for opening a link's file or folder.",
		value       = "Add Program",
		kind        = .Action,
		action      = .Opener_Add,
	}
	return ui.editor_add(p, add, group) == nil
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
	kept := ui.editor_kept_take(p)
	defer ui.editor_kept_destroy(&kept)
	// A field the user moved off saves what was typed into it, after what the move itself did.
	defer editor_kept_save(app, w, &kept)
	if outcome == .None {return}
	w.dirty = true
	ui.editor_outcome_begin(p, outcome)
	switch outcome {
	case .None, .Changed:
		return
	case .Theme_Customize:
		ui.editor_section_show(p, int(Settings_Area.Colors))
		return
	case .Reset_All:
		settings_reset_ask(app, w)
		return
	case .Font_Filter:
		editor_font_filter(app, w)
		return
	case .Shortcut_Chain:
		// Publication rebuilds the page with the chain still open; it closes once the save applied.
		if shortcut_chain_save(app, ui.editor_chain_changes(p), Settings_Page{p}) {
			ui.editor_chain_close(p)
		}
		return
	case .Assign_Shortcut:
		if chord, free := ui.editor_free_chord(p).?; free {
			palette_open_mode(app, w, .Commands)
			ui.palette_assign(&app.palette, &app.registry, chord)
		}
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
	case .Opener_Action:
		editor_opener_action(app, w, request)
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
	// Motion rows write a context's whole text or a curve or preset change, never their own key.
	if row.motion_part != .None {
		editor_motion_save(app, w, outcome == .Reset)
		return
	}
	if row.kind == .Profile_Add {
		editor_profile_mutate(app, w, {kind = .Add})
		return
	}
	// A color's reset returns it to its base theme instead of writing the shown default.
	if outcome == .Reset && row.action != .Theme_Color {ui.field_set(&p.value, row.default_value)}
	value := ui.field_string(&p.value)
	// A combination of choices is edited as option bits; the file stores their names.
	if row.multiple && outcome != .Reset {value = settings.set_text(row.choices, ui.editor_choice_set(p))}
	value = strings.clone(value, context.temp_allocator)
	if field, is_field := row.profile_field.?; is_field {
		editor_profile_field(app, w, row.profile, field, value)
		return
	}
	if field, is_field := row.opener_field.?; is_field {
		editor_opener_field(app, w, row.opener, field, value)
		return
	}
	switch row.action {
	case .None:
		editor_setting_save(app, w, row, value)
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
	case .Opener_Add:
		editor_opener_mutate(app, w, {kind = .Add})
	}
}

// Saves a field the user moved off without pressing Enter (ui.editor_keep), once the page is at
// rest: an open popup or a pointer drag would not survive the page taking the new revision, so
// until then the field stays kept. The selection stays where the user went. A refusal rings the
// field's row with the reason, unless the event that left it reported a problem of its own.
@(private)
editor_kept_save :: proc(app: ^App, w: ^Window, kept: ^ui.Editor_Kept) {
	if kept.key == "" {return}
	p := &w.editor
	if !ui.editor_resting(p) {
		ui.editor_kept_put(p, kept)
		return
	}
	// Back on the same row with new text in its field, that text is the newer value. Leaving by Tab or
	// the search box keeps the row selected with its saved text, and the kept value saves.
	if row := ui.editor_row(p); row != nil && row.key == kept.key && ui.field_string(&p.value) != row.value {
		return
	}
	w.dirty = true
	for &row in p.rows {
		if row.key != kept.key {continue}
		if field, is_field := row.profile_field.?; is_field {
			editor_profile_field(app, w, row.profile, field, kept.value, kept = true)
			return
		}
		if field, is_field := row.opener_field.?; is_field {
			editor_opener_field(app, w, row.opener, field, kept.value, kept = true)
			return
		}
		editor_setting_save(app, w, &row, kept.value, kept = true)
		return
	}
}

// Shows why a kept field's value was refused on its row, unless the page already shows a problem.
@(private)
editor_kept_refused :: proc(p: ^ui.Editor, profile, key, message: string) {
	if p.error || p.error_text != "" {return}
	ui.editor_error_set(p, profile, key, message)
	ui.editor_message(p, message, true)
}

// The base a field save computes against: the page, or for a `kept` field the page as it keeps
// another row selected.
@(private)
editor_field_base :: proc(p: ^ui.Editor, kept: bool) -> Settings_Base {
	return kept ? Settings_Kept{p} : Settings_Page{p}
}

// Saves a schema setting or shortcut as `value`: the selected row's, or a `kept` one the user left.
@(private)
editor_setting_save :: proc(app: ^App, w: ^Window, row: ^ui.Editor_Row, value: string, kept := false) {
	p := &w.editor
	key := strings.clone(row.key, context.temp_allocator)
	kind := row.kind
	result := settings_change(app, Setting_Value{key, value}, editor_field_base(p, kept))
	if kept && result.status == .Refused {
		editor_kept_refused(p, "", key, result.message)
		return
	}
	if !settings_page_report(p, result, .Setting) {return}
	if kind == .Shortcut {ui.editor_browse(p)}
	text := "Saved and applied."
	if result.message != "" {text = fmt.tprintf("Saved. %s", result.message)}
	if entry := settings.schema_find(key); entry != nil && entry.apply_timing == .New_Sessions {
		text = "Saved. Initial size applies to new sessions."
	}
	ui.editor_message(p, text, false)
}

// Reports a profile or link program change: one that did not apply on the page, one that did by
// showing `select_key` with `message`, scrolled where the page was. With `stay` the selection and
// focus remain where they are, as for a field the user moved off.
@(private)
editor_table_saved :: proc(
	w: ^Window,
	result: Settings_Result,
	workflow: Settings_Workflow,
	select_key, message: string,
	focus := Reveal_Focus.None,
	stay := false,
) {
	if !settings_page_report(&w.editor, result, workflow) {return}
	if stay {
		ui.editor_message(&w.editor, message, false)
		return
	}
	ui.editor_browse(&w.editor)
	settings_reveal_page(
		&w.editor,
		{key = select_key, search = .Preserve, message = message, focus = focus, keep_scroll = true},
	)
}

// Validates and writes one inline profile field as `value`. Empty names and commands, duplicate
// names and a command line whose executable cannot be found stay inline: the row is ringed, the
// field carries the message, and no modal appears.
@(private)
editor_profile_field :: proc(
	app: ^App,
	w: ^Window,
	profile: string,
	field: settings.Profile_Field,
	value: string,
	kept := false,
) {
	id := strings.clone(profile, context.temp_allocator)
	stored := value
	key := settings.profile_field_key(id, field)
	message := "Saved."
	focus := Reveal_Focus.Control
	switch field {
	case .Command, .Directory:
		message = "Saved. Applies to new or restarted shells."
	case .Hidden:
		// The toggle shows "Show in menus"; the file stores the opposite.
		stored = value == "true" ? "false" : "true"
		focus = .None
	case .Name, .Icon:
	}
	result := settings_change(app, Profile_Field_Value{id, field, stored}, editor_field_base(&w.editor, kept))
	if result.status == .Refused {
		if kept {
			editor_kept_refused(&w.editor, id, key, result.message)
			return
		}
		ui.editor_error_set(&w.editor, id, key, result.message)
		ui.editor_message(&w.editor, result.message, true)
		return
	}
	editor_table_saved(w, result, .Profile_Field, key, message, focus, kept)
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
	editor_table_saved(w, result, .Profile, key, message)
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
			editor_table_saved(
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
		editor_table_saved(
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

// Validates and writes one inline link program field as `value`. An empty name or command line,
// or a program offered for no links, stays inline: the row is ringed, the field carries the
// message, and no modal appears.
@(private)
editor_opener_field :: proc(
	app: ^App,
	w: ^Window,
	opener: string,
	field: settings.Opener_Field,
	value: string,
	kept := false,
) {
	id := strings.clone(opener, context.temp_allocator)
	key := settings.opener_field_key(id, field)
	// Text fields keep the keyboard for the next edit; a choice returns to its row.
	focus := field == .Offers || field == .Placement ? Reveal_Focus.None : Reveal_Focus.Control
	result := settings_change(app, Opener_Field_Value{id, field, value}, editor_field_base(&w.editor, kept))
	if result.status == .Refused {
		if kept {
			editor_kept_refused(&w.editor, "", key, result.message)
			return
		}
		ui.editor_error_set(&w.editor, "", key, result.message)
		ui.editor_message(&w.editor, result.message, true)
		// The open list shows the links the program is still offered for.
		if row := ui.editor_row(&w.editor); row != nil && row.key == key {w.editor.choice_set = row.choice_mask}
		return
	}
	// Offered for is a list of links whose popup stays open while each one is switched.
	stay := kept || field == .Offers
	editor_table_saved(w, result, .Opener_Field, key, "Saved. Link menus use it.", focus, stay)
}

@(private)
editor_opener_mutate :: proc(app: ^App, w: ^Window, change: settings.Opener_Mutation) {
	result := settings_change(app, change, Settings_Page{&w.editor})
	if result.status == .Unchanged {return}
	if result.status != .Applied {
		_ = settings_page_report(&w.editor, result, .Opener)
		return
	}
	key := settings_opener_row_key(result.id)
	message: string
	switch change.kind {
	case .Add:
		message = "Link program added. Change its name and command line."
	case .Remove:
		message, key = "Link program removed.", OPENER_ADD_KEY
	case .Move:
		message = "Link program order saved. Link menus follow it."
	}
	// The reveal rebuilds the published page, which then opens the new program's fields.
	if change.kind == .Add {
		ui.editor_opener_set_expanded(&w.editor, result.id)
	} else if change.kind == .Remove && w.editor.opener_expanded == result.id {
		ui.editor_opener_set_expanded(&w.editor, "")
	}
	editor_table_saved(w, result, .Opener, key, message)
}

// Performs the link program write a table control asked for.
@(private)
editor_opener_action :: proc(app: ^App, w: ^Window, request: ui.Editor_Request) {
	#partial switch r in request {
	case ui.Opener_Remove_Request:
		editor_opener_remove_ask(app, w, r.id)
	case ui.Opener_Order_Request:
		editor_opener_mutate(app, w, {kind = .Move, id = r.id, slot = r.slot})
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

// The Colors section's group of actions on the active theme; choosing a theme is General's first row.
@(private)
THEME_MANAGE_GROUP :: "Manage Theme"

// The active theme's management rows, which the Colors board shows as its card, then its colors.
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
		}
		for row in rows {
			if ui.editor_add(p, row, THEME_MANAGE_GROUP) != nil {return false}
		}
	} else if ui.editor_add(p, duplicate, THEME_MANAGE_GROUP) != nil {return false}
	if ui.editor_add(p, {
		key = "theme.export",
		title = "Export Theme File",
		description = "Save a portable JSON file in the themes folder. Share it with its schema file.",
		kind = .Action,
		value = "Export",
		action = .Theme_Export,
	}, THEME_MANAGE_GROUP) != nil {return false}
	// Delete follows the actions that keep the theme.
	if custom := settings.custom_theme_find(s, s.theme.name); settings.theme_custom(s) {
		delete_row := ui.Editor_Row {
			key         = "theme.delete",
			title       = "Delete Theme",
			description = fmt.tprintf(
				"Remove this custom theme and switch to %s.",
				settings.theme_display_name(s, settings.theme_delete_target(s, custom)),
			),
			value       = "Delete…",
			kind        = .Action,
			action      = .Theme_Delete,
		}
		if ui.editor_add(p, delete_row, THEME_MANAGE_GROUP) != nil {return false}
	}
	return settings_add_color_rows(p, s)
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
	case .A, .N, .P, .R, .Backspace, .Delete, .Page_Up, .Page_Down:
		return modifiers == {.Control}
	}
	return false
}

// Keys on the settings tab. Recording a shortcut or a search by keys keeps every key; otherwise text
// fields keep their clipboard and editing chords and other app shortcuts still run, so tabs can be
// switched or closed. The search field keeps Alt+K, which records keys for it.
settings_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	pane_header_cancel(w)
	p := &w.editor
	_ = settings_layout(w)
	w.dirty = true
	key_suppress(w, e)
	// Escape backs out of a delete prompt even when the page has nothing else to leave.
	if e.pressed && e.key == .Escape {ui.editor_theme_delete_disarm(p)}
	if ui.editor_capturing(p) || ui.editor_recording(p) {
		editor_outcome(app, w, ui.editor_key(p, e))
		return
	}
	key, consumed := content_key_prelude(app, w, e, false)
	if consumed {return}
	if shortcut_undo_key(app, key.logical) {return}
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
	search_owns := ui.editor_focus(p) == .Search && ui.key_search_toggles(e)
	if key.found && !editor_owns(key.logical) && !search_owns && action_available(app, w, key.action) {
		run_action(app, w, key.action)
		return
	}
	status_inbox_typed(w, e)
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
		confirmation_ask(app, w, Profile_Remove{owned, name}, focus = .Cancel)
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

// The link program a confirmation asks before deleting, and its name as the page showed it.
Opener_Remove :: struct {
	id, name: string,
}

editor_opener_remove_text :: proc(remove: Opener_Remove) -> Confirmation_Text {
	return {title = fmt.tprintf("Delete %s?", remove.name), label = "Delete"}
}

// Asks before deleting a link program the page lists.
editor_opener_remove_ask :: proc(app: ^App, w: ^Window, id: string) {
	for row in w.editor.rows {
		if row.kind != .Opener || row.opener != id {continue}
		owned, err := strings.clone(id)
		name, name_error := strings.clone(row.title)
		if err != nil || name_error != nil {
			delete(owned)
			delete(name)
			notify(app, .Error, "Could not prepare link program deletion.")
			return
		}
		confirmation_ask(app, w, Opener_Remove{owned, name}, focus = .Cancel)
		return
	}
}

@(private)
editor_opener_remove_finish :: proc(app: ^App, w: ^Window, remove: Opener_Remove, accepted: bool) {
	if accepted {editor_opener_mutate(app, w, {kind = .Remove, id = remove.id})}
}

editor_opener_remove_destroy :: proc(remove: ^Opener_Remove) {
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
		opener_removing := confirmation_subject(w, Opener_Remove)
		opener_group := -1
		for group, index in p.groups {
			if group.title == SETTINGS_SECTIONS[.Link_Programs].title {opener_group = index; break}
		}
		opener_ids := strings.builder_make(context.temp_allocator)
		opener_indices: [settings.OPENER_LIMIT]int
		for index, i in opener_indices[:settings.openers_in_order(&app.settings.openers, opener_indices[:])] {
			if i > 0 {strings.write_byte(&opener_ids, ',')}
			strings.write_string(&opener_ids, app.settings.openers.items[index].id)
		}
		// Link programs whose table line drew their icon in the last frame.
		opener_icons := strings.builder_make(context.temp_allocator)
		for row in p.rows {
			if row.kind != .Opener || row.icon_atlas.width <= 0 {continue}
			if strings.builder_len(opener_icons) > 0 {strings.write_byte(&opener_icons, ',')}
			strings.write_string(&opener_icons, row.opener)
		}
		match, free := "", ""
		rows := 0
		for item in p.items {if item.row >= 0 && item.part == 0 {rows += 1}}
		if p.selected >= 0 && p.selected < len(p.items) && p.items[p.selected].row >= 0 {
			item := p.items[p.selected]
			labels := commands.shortcut_alternatives(p.rows[item.row].value, context.temp_allocator)
			if item.shortcut.hit.match != .None && item.shortcut.alternative < len(labels) {
				match = shortcut_hit_text(labels[item.shortcut.alternative], item.shortcut.hit)
			}
		}
		key_buffer: [commands.SHORTCUT_TEXT_CAP]u8
		if chord, offered := ui.editor_free_chord(p).?; offered {
			free = strings.clone(commands.shortcut_text(chord, key_buffer[:]), context.temp_allocator)
		}
		state_text(r, "settings.match", match)
		state_text(r, "settings.free", free)
		state_value(r, "settings.rows", rows)
		state_value(r, "settings.keys", p.keys.state)
		state_valuef(r, "settings.keys.text", "%s", commands.key_press_text(p.keys.press, key_buffer[:]))
		state_rect(r, "settings.keys.button", ui.editor_keys_rect(page))
		state_value(r, "settings.open", ui.editor_loaded(p))
		state_text(r, "settings.revision", settings_page_revision_word(p))
		state_value(r, "settings.theme_delete_armed", p.delete_armed)
		settings_theme_strip_state(r, p, page)
		state_text(r, "settings.filter", string(p.filter.bytes[:]))
		if p.section >= 0 && p.section < len(p.sections) {
			state_text(r, "settings.section", p.sections[p.section])
		}
		state_value(r, "settings.scroll", p.scroll)
		state_value(r, "settings.group", ui.editor_active_group(p))
		state_text(r, "settings.key", key)
		state_text(r, "settings.value", string(p.value.bytes[:]))
		state_value(r, "settings.editing", ui.editor_editing(p))
		state_value(r, "settings.focus", ui.editor_focus(p))
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
		state_text(r, "settings.opener.expanded", p.opener_expanded)
		state_text(r, "settings.opener.ids", strings.to_string(opener_ids))
		state_text(r, "settings.opener.icons", strings.to_string(opener_icons))
		state_value(r, "settings.opener.app_count", len(app.settings.openers.items))
		state_text(
			r,
			"settings.opener.removing",
			confirmation_asking(w, Opener_Remove) != nil ? opener_removing.id : "",
		)
		opener_title := opener_removing != nil ? editor_opener_remove_text(opener_removing^).title : ""
		state_text(r, "settings.opener.remove_title", opener_title)
		state_text(r, "settings.opener.rows", settings_page_row_rects(p, page, .Opener))
		state_value(r, "settings.opener.group", opener_group)
		state_value(r, "settings.opener.dragging", ui.editor_order_dragging(p, .Openers))
		state_value(r, "settings.opener.drag_target", ui.editor_order_target(p))
		state_text(r, "settings.opener.drag_id", ui.editor_order_opener(p))
		state_rect(r, "settings.slider", selected.slider)
		state_rect(r, "settings.search_rect", page.filter)
		state_rect(r, "settings.outline_rect", page.outline)
		state_rect(r, "settings.list_rect", page.list)
		chain_rows := make([]Chain_Report_Row, len(p.chain.members), context.temp_allocator)
		if settings_active(w) {
			for &row, member in chain_rows {row.row, row.right, row.shown = ui.editor_chain_row(p, page, member)}
		}
		shortcut_chain_state_report(r, "settings", &p.chain, chain_rows, &w.ui_text, w.scale)
		used_by := ui.shortcut_capture_used_by(&p.capture)
		if ui.editor_chained(p) {used_by = ui.shortcut_chain_used_by(&p.chain)}
		state_text(r, "settings.used_by", used_by)
		settings_board_state_report(r, p, page)
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
		Opener,
	}

	// A table's rows as key@x,y,w,h (process) or id@x,y,w,h (profile, link program), joined by ';',
	// so a live journey can aim a drag at a row's grip.
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
			case .Opener:
				if row.kind != .Opener {continue}
				name = row.opener
			}
			rect := ui.editor_row_parts(p, page, index).row
			if !first {strings.write_byte(&builder, ';')}
			first = false
			fmt.sbprintf(&builder, "%s@%g,%g,%g,%g", name, rect.x, rect.y, rect.width, rect.height)
		}
		return strings.to_string(builder)
	}

	// A shortcut label with the parts a search matched in brackets, such as [Alt]+[8], which the
	// palette and Settings report for the selected row.
	shortcut_hit_text :: proc(label: string, hit: commands.Shortcut_Hit) -> string {
		builder := strings.builder_make(context.temp_allocator)
		rest := label
		for part in commands.shortcut_label_next(&rest) {
			if strings.builder_len(builder) > 0 {strings.write_byte(&builder, '+')}
			lit := part.is_modifier ? part.modifier in hit.modifiers : hit.key
			if lit {strings.write_byte(&builder, '[')}
			strings.write_string(&builder, part.text)
			if lit {strings.write_byte(&builder, ']')}
		}
		return strings.to_string(builder)
	}
}
