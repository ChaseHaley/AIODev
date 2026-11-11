package main

import "aio:commands"
import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:strings"

// One change to the settings. Every surface that writes settings (the page, the palette, toolbar
// buttons, confirmations) describes its change here, and settings_change builds, checks, saves and
// publishes it in one order. Strings are borrowed for the call.
Settings_Edit :: union #no_nil {
	// One key: a schema setting, a shortcut or a custom theme field.
	Setting_Value,
	Profile_Field_Value,
	settings.Profile_Mutation,
	Opener_Field_Value,
	settings.Opener_Mutation,
	Theme_Change,
	settings.Motion_Mutation,
	Factory_Reset,
}

Setting_Value :: struct {
	key, value: string,
}

// One inline profile field, checked as the page checks typing. Hidden takes the file's value.
Profile_Field_Value :: struct {
	id:    string,
	field: settings.Profile_Field,
	value: string,
}

// One inline link program field, checked as the page checks typing. Offers and placement take the
// file's value.
Opener_Field_Value :: struct {
	id:    string,
	field: settings.Opener_Field,
	value: string,
}

// A change to the active theme of the revision.
Theme_Change :: union #no_nil {
	Theme_Color,
	Theme_Name,
	Theme_Rename,
	Theme_Duplicate,
	Theme_Remove,
}

// An empty value returns the color to the base theme.
Theme_Color :: struct {
	token_key, value: string,
}

Theme_Name :: struct {
	name: string,
}

Theme_Rename :: struct {
	id: string,
}

Theme_Duplicate :: struct {}

Theme_Remove :: struct {}

// The factory defaults replace the whole file; open pages drop their drafts.
Factory_Reset :: struct {}

// The revision a change is computed against and must still be in the file when it saves.
Settings_Base :: union #no_nil {
	// The page's own text. The page is publication's origin and keeps its saved field.
	Settings_Page,
	// The page's own text, saving a field the user moved off. Its selected row is another, so the
	// page keeps its selection and pending work as the other pages do.
	Settings_Kept,
	// The file as it is now. Without a settings file, the running settings.
	Settings_Current,
	// The text a confirmation was asked against.
	Settings_Expected,
}

Settings_Page :: struct {
	page: ^ui.Editor,
}

Settings_Kept :: struct {
	page: ^ui.Editor,
}

Settings_Current :: struct {}

Settings_Expected :: struct {
	source: string,
}

Settings_Status :: enum {
	Applied,
	// Nothing to save, such as a profile that no longer exists.
	Unchanged,
	// The change or its shortcuts were refused; `message` says why.
	Refused,
	// The change could not be built.
	Unprepared,
	// The file no longer holds the base revision.
	Conflict,
	// The file could not be read or written.
	Failed,
}

Settings_Result :: struct {
	status:  Settings_Status,
	// Refused: why. Applied: a shortcut warning, or empty. Temporary.
	message: string,
	// The profile, link program or theme the change created, renamed to or selected. Temporary.
	id:      string,
}

// Which surface asked, which picks the wording of a failure.
Settings_Workflow :: enum {
	Setting,
	Profile_Field,
	Profile,
	Opener_Field,
	Opener,
	Process,
	Theme,
	Motion,
	Font_Filter,
	Reset,
}

@(private, rodata)
SETTINGS_FAILURE_TEXT := [Settings_Workflow][Settings_Status]string {
	.Setting = #partial [Settings_Status]string {
		.Unprepared = "Could not allocate settings change.",
		.Conflict = SETTINGS_CONFLICT_TEXT,
		.Failed = "Could not save settings. Check the settings path and permissions.",
	},
	.Profile_Field = #partial [Settings_Status]string {
		.Unprepared = "Could not allocate settings change.",
		.Conflict = SETTINGS_CONFLICT_TEXT,
		.Failed = "Could not save the profile. Check the settings path and permissions.",
	},
	.Profile = #partial [Settings_Status]string {
		.Unprepared = "Could not prepare the profile change.",
		.Conflict = SETTINGS_CONFLICT_TEXT,
		.Failed = "Could not save the profile. Check the settings path and permissions.",
	},
	.Opener_Field = #partial [Settings_Status]string {
		.Unprepared = "Could not allocate settings change.",
		.Conflict = SETTINGS_CONFLICT_TEXT,
		.Failed = "Could not save the link program. Check the settings path and permissions.",
	},
	.Opener = #partial [Settings_Status]string {
		.Unprepared = "Could not prepare the link program change.",
		.Conflict = SETTINGS_CONFLICT_TEXT,
		.Failed = "Could not save the link program. Check the settings path and permissions.",
	},
	.Process = #partial [Settings_Status]string {
		.Unprepared = "Could not prepare program settings.",
		.Conflict = "File changed outside this editor. Reopen Settings to reload it.",
		.Failed = "Could not save program settings.",
	},
	.Theme = #partial [Settings_Status]string {
		.Unprepared = "Could not prepare the theme change.",
		.Conflict = SETTINGS_CONFLICT_TEXT,
		.Failed = "Could not save the theme. Check the settings path and permissions.",
	},
	.Motion = #partial [Settings_Status]string {
		.Unprepared = "Could not prepare the motion change.",
		.Conflict = SETTINGS_CONFLICT_TEXT,
		.Failed = "Could not save motion settings. Check the settings path and permissions.",
	},
	.Font_Filter = #partial [Settings_Status]string {
		.Refused = FONT_FILTER_FAILURE_TEXT,
		.Unprepared = FONT_FILTER_FAILURE_TEXT,
		.Conflict = FONT_FILTER_FAILURE_TEXT,
		.Failed = FONT_FILTER_FAILURE_TEXT,
	},
	.Reset = #partial [Settings_Status]string {
		.Unprepared = "Could not prepare factory defaults.",
		.Conflict = RESET_FAILURE_TEXT,
		.Failed = RESET_FAILURE_TEXT,
	},
}

@(private)
SETTINGS_CONFLICT_TEXT :: "File changed outside this editor. Close and reopen Settings to reload it."
@(private)
FONT_FILTER_FAILURE_TEXT :: "Could not save font filtering. Reopen Settings and try again."
@(private)
RESET_FAILURE_TEXT :: "Could not reset settings. Reopen Settings and try again."

// What `workflow` says about a result that did not apply: a refusal's own reason, else the
// workflow's failure wording. Empty for a result with nothing to report.
settings_result_text :: proc(result: Settings_Result, workflow: Settings_Workflow) -> string {
	failure := SETTINGS_FAILURE_TEXT[workflow][result.status]
	if result.status == .Refused && failure == "" {return result.message}
	return failure
}

// Shows a result that did not apply on the page that asked. True when the change applied.
settings_page_report :: proc(p: ^ui.Editor, result: Settings_Result, workflow: Settings_Workflow) -> bool {
	if result.status == .Applied {return true}
	if text := settings_result_text(result, workflow); text != "" {ui.editor_message(p, text, true)}
	return false
}

// Saves one setting from outside the page, such as the palette or a toolbar button, and reports
// a refusal or `failure` as a notice. A shortcut warning is shown once the change applies.
settings_save_value :: proc(app: ^App, key, value, failure: string) -> bool {
	result := settings_change(app, Setting_Value{key, value}, Settings_Current{})
	switch result.status {
	case .Applied:
		if result.message != "" {notify(app, .Info, result.message)}
		return true
	case .Unchanged:
		return true
	case .Refused:
		notify(app, .Error, result.message)
	case .Unprepared, .Conflict, .Failed:
		notify(app, .Error, failure)
	}
	return false
}

// Builds the revision `edit` makes of `base`, checks its shortcuts when the change can affect them,
// saves it over exactly `base`, applies it to the running app and publishes it to every open
// settings page. A rejected change leaves the file, the running settings and every page as they
// were; a conflict marks the pages showing `base` as behind the file. Without a settings file only
// a schema setting can change, and it applies to the running settings directly.
@(require_results)
settings_change :: proc(app: ^App, edit: Settings_Edit, base: Settings_Base) -> Settings_Result {
	if app.settings_path == "" {return settings_change_memory(app, edit)}
	source: string
	origin: ^ui.Editor
	switch b in base {
	case Settings_Page:
		source, origin = ui.editor_source(b.page), b.page
	case Settings_Kept:
		source = ui.editor_source(b.page)
	case Settings_Current:
		data, read_error := os.read_entire_file(app.settings_path, context.temp_allocator)
		if read_error != nil {return {status = .Failed}}
		source = string(data)
	case Settings_Expected:
		source = b.source
	}
	// Publication replaces pages, which may own `source`.
	previous, previous_error := strings.clone(source, context.temp_allocator)
	if previous_error != nil {return {status = .Unprepared}}
	built := settings_edit_build(app, edit, previous)
	defer delete(built.revision)
	if built.result.status != .Applied {return built.result}
	revision, revision_error := strings.clone(built.revision, context.temp_allocator)
	if revision_error != nil {return {status = .Unprepared}}
	loaded, diagnostics, parse_error := settings.parse(revision, inputs = &app.settings_inputs)
	defer settings.destroy(&loaded)
	defer settings.diagnostics_destroy(&diagnostics)
	if parse_error != nil {return {status = .Failed}}
	result := built.result
	if value, ok := edit.(Setting_Value); ok && settings.setting_affects_bindings(value.key) {
		problem, warning := settings_bindings_check(&loaded, app.settings_path)
		if problem != "" {return {status = .Refused, message = problem}}
		result.message = warning
	}
	switch settings.save(app.settings_path, previous, revision) {
	case .None:
	case .Conflict:
		for window in app.windows {
			p := &window.editor
			if ui.editor_source(p) == previous {ui.editor_revision_stale(p, .Changed_Outside)}
		}
		return {status = .Conflict}
	case .IO:
		return {status = .Failed}
	}
	publication: Settings_Publication = Publish_Saved{previous, revision, origin}
	if _, reset := edit.(Factory_Reset); reset {publication = Publish_Reset{revision}}
	settings_revision_apply(app, loaded, &diagnostics, nil, publication)
	loaded = {}
	return result
}

// A built revision: owned `revision` when the result is Applied.
@(private)
Settings_Built :: struct {
	revision: string,
	result:   Settings_Result,
}

// The revision `edit` makes of `source`. Profile, link program and theme changes resolve against
// the revision `source` parses to, never against the running settings, which a page may be behind.
@(private, require_results)
settings_edit_build :: proc(app: ^App, edit: Settings_Edit, source: string) -> (built: Settings_Built) {
	switch e in edit {
	case Setting_Value:
		return settings_text_edit(source, e.key, e.value)
	case Factory_Reset:
		defaults, err := settings.default_text()
		if err != nil {return {result = {status = .Unprepared}}}
		return {revision = defaults}
	case Profile_Field_Value, settings.Profile_Mutation, Opener_Field_Value, settings.Opener_Mutation,
	     Theme_Change, settings.Motion_Mutation:
	}
	model, diagnostics, parse_error := settings.parse(source, inputs = &app.settings_inputs)
	settings.diagnostics_destroy(&diagnostics)
	defer settings.destroy(&model)
	if parse_error != nil {return {result = {status = .Unprepared}}}
	#partial switch e in edit {
	case Profile_Field_Value:
		return settings_profile_field_edit(&model, source, e)
	case Opener_Field_Value:
		return settings_opener_field_edit(&model, source, e)
	case settings.Profile_Mutation:
		return settings_profile_mutation_edit(&model, source, e)
	case settings.Opener_Mutation:
		return settings_opener_mutation_edit(&model, source, e)
	case Theme_Change:
		return settings_theme_edit(&model, source, e)
	case settings.Motion_Mutation:
		return settings_motion_edit(&model, source, e)
	}
	return
}

@(private, require_results)
settings_text_edit :: proc(source, key, value: string) -> Settings_Built {
	updated, message, err := settings.edit_text(source, key, value)
	defer delete(message)
	if err != nil || message != "" {
		delete(updated)
		if err != nil {return {result = {status = .Unprepared}}}
		refused := Settings_Built{result = {status = .Refused}}
		refused.result.message, _ = strings.clone(message, context.temp_allocator)
		return refused
	}
	return {revision = updated}
}

// Empty names and commands, duplicate names and a command line whose executable cannot be found are
// refused with the page's inline wording.
@(private, require_results)
settings_profile_field_edit :: proc(
	model: ^settings.Settings,
	source: string,
	change: Profile_Field_Value,
) -> Settings_Built {
	problem := settings.Profile_Problem.None
	if change.field != .Hidden {
		_, problem = settings.profile_field_check(
			change.field, change.value, .Interactive_Field, &model.profiles, change.id,
		)
	}
	if problem == .None && change.field == .Command && !profile_command_exists(change.value) {
		problem = .Command_Missing
	}
	if problem != .None {
		text := settings.profile_problem_text(problem, .Interactive_Field, change.value)
		return {result = {status = .Refused, message = text}}
	}
	return settings_text_edit(source, settings.profile_field_key(change.id, change.field), change.value)
}

@(private, require_results)
settings_profile_mutation_edit :: proc(
	model: ^settings.Settings,
	source: string,
	change: settings.Profile_Mutation,
) -> (
	built: Settings_Built,
) {
	updated, id, issue, error := settings.profile_mutate(source, &model.profiles, change)
	defer delete(id)
	defer delete(issue)
	switch error {
	case .None:
		built.revision = updated
		built.result.id, _ = strings.clone(id, context.temp_allocator)
	case .Unavailable:
		built.result.status = .Unchanged
	case .Edit:
		built.result.status = .Refused
		built.result.message, _ = strings.clone(issue, context.temp_allocator)
	case .Limit:
		built.result = {status = .Refused, message = "Profile limit reached. Remove one before duplicating."}
		if change.kind == .Add {
			built.result.message = "Profile limit reached. Remove one before adding another."
		}
	case .Allocation:
		built.result.status = .Unprepared
	}
	if error != .None {delete(updated)}
	return
}

// A link program that no longer exists is left alone rather than recreated by its field; empty
// names and commands and unknown choices are refused with the page's inline wording.
@(private, require_results)
settings_opener_field_edit :: proc(
	model: ^settings.Settings,
	source: string,
	change: Opener_Field_Value,
) -> Settings_Built {
	if settings.opener_find(&model.openers, change.id) == nil {return {result = {status = .Unchanged}}}
	_, problem := settings.opener_field_check(change.field, change.value, .Interactive_Field)
	if problem != .None {
		text := settings.opener_problem_text(problem, .Interactive_Field, change.value)
		return {result = {status = .Refused, message = text}}
	}
	return settings_text_edit(source, settings.opener_field_key(change.id, change.field), change.value)
}

@(private, require_results)
settings_opener_mutation_edit :: proc(
	model: ^settings.Settings,
	source: string,
	change: settings.Opener_Mutation,
) -> (
	built: Settings_Built,
) {
	updated, id, issue, error := settings.opener_mutate(source, &model.openers, change)
	defer delete(id)
	defer delete(issue)
	switch error {
	case .None:
		built.revision = updated
		built.result.id, _ = strings.clone(id, context.temp_allocator)
	case .Unavailable:
		built.result.status = .Unchanged
	case .Edit:
		built.result.status = .Refused
		built.result.message, _ = strings.clone(issue, context.temp_allocator)
	case .Limit:
		built.result = {
			status = .Refused, message = "Link program limit reached. Remove one before adding another.",
		}
	case .Allocation:
		built.result.status = .Unprepared
	}
	if error != .None {delete(updated)}
	return
}

@(private, require_results)
settings_motion_edit :: proc(
	model: ^settings.Settings,
	source: string,
	change: settings.Motion_Mutation,
) -> Settings_Built {
	revision, message, err := settings.motion_mutate(model, source, change)
	defer delete(message)
	if err != nil {return {result = {status = .Unprepared}}}
	if message != "" {
		refused := Settings_Built{result = {status = .Refused}}
		refused.result.message, _ = strings.clone(message, context.temp_allocator)
		return refused
	}
	return {revision = revision}
}

@(private, require_results)
settings_theme_edit :: proc(
	model: ^settings.Settings,
	source: string,
	change: Theme_Change,
) -> (
	built: Settings_Built,
) {
	updated, id, issue: string
	error: settings.Theme_Edit_Error
	switch c in change {
	case Theme_Color:
		updated, id, issue, error = settings.theme_color_edit(model, source, c.token_key, c.value)
		if error == .None && updated == source {
			delete(updated)
			return {result = {status = .Unchanged}}
		}
	case Theme_Name:
		updated, issue, error = settings.theme_name_edit(model, source, c.name)
	case Theme_Rename:
		updated, issue, error = settings.theme_rename(model, source, c.id)
		built.result.id = c.id
	case Theme_Duplicate:
		updated, id, error = settings.theme_duplicate(model, source)
		if error == .Invalid {issue = "Custom theme limit reached. Delete one before saving another."}
	case Theme_Remove:
		updated, id, error = settings.theme_delete(model, source)
	}
	defer delete(id)
	switch error {
	case .None:
		built.revision = updated
		if id != "" {built.result.id, _ = strings.clone(id, context.temp_allocator)}
		return
	case .Allocation:
		built.result.status = .Unprepared
	case .Invalid:
		built.result = {status = .Refused, message = issue}
	case .Unavailable:
		built.result = {status = .Refused, message = "Theme files cannot be renamed or deleted here."}
	}
	delete(updated)
	return
}

// Without a settings file, a schema setting changes the running settings and every window
// follows it at once, relaid out for sizes and sides. Nothing else has a running form to change.
@(private, require_results)
settings_change_memory :: proc(app: ^App, edit: Settings_Edit) -> Settings_Result {
	value, is_value := edit.(Setting_Value)
	entry := is_value ? settings.schema_find(value.key) : nil
	if entry == nil {return {status = .Failed}}
	message, err := settings.setting_assign(&app.settings, entry^, value.value)
	if err != nil {return {status = .Unprepared}}
	if message != "" {return {status = .Refused, message = message}}
	for window in app.windows {
		window_apply_settings(app, window)
		rail_reveal_active(window)
		window_relayout(app, window)
	}
	status_apply_settings(app)
	return {status = .Applied}
}

// A refusal for the first shortcut problem a revision would have, or the first warning it keeps.
// Both are temporary.
@(private, require_results)
settings_bindings_check :: proc(s: ^settings.Settings, path: string) -> (problem, warning: string) {
	registry := commands.create()
	defer commands.destroy(&registry)
	if register_actions(&registry) != .None {return "Could not validate shortcuts.", ""}
	report, report_error := binding_report(&registry, s)
	for issue in report.issues {
		if issue.severity == .Shortcut_Warning {
			if warning == "" {warning = binding_issue_identity(issue, path)}
		} else if issue.kind == .Duplicate_Shortcut {
			return fmt.tprintf("Assigned to %s. Choose another shortcut.", issue.conflict.winner.title), ""
		} else {
			return fmt.tprintf("%s: %s", issue.key, binding_issue_text(issue, path)), ""
		}
	}
	if report_error != nil {return "Could not validate shortcuts.", ""}
	return "", warning
}

// How a new settings revision reaches the open settings pages.
Settings_Publication :: union #no_nil {
	Publish_Saved,
	Publish_Reloaded,
	Publish_Unavailable,
	Publish_Reset,
}

// A save from this app. Only pages showing `previous` advance: a page predating an external edit
// must still fail the file conflict check. The origin accepts its saved field; other pages keep
// pending text and selection while receiving the new source.
Publish_Saved :: struct {
	previous, revision: string,
	origin:             ^ui.Editor,
}

// Settings were read from the file again. Every page adopts the file, keeping drafts whose rows remain.
Publish_Reloaded :: struct {
	revision: string,
}

// The file could not be read; running settings fell back to defaults, but pages retain their work.
Publish_Unavailable :: struct {}

// A factory reset. Every page adopts the defaults and drops its drafts and table state.
Publish_Reset :: struct {
	revision: string,
}

// Shows a new revision on every open settings page.
@(private)
settings_publish :: proc(app: ^App, publication: Settings_Publication) {
	for window in app.windows {
		p := &window.editor
		if !ui.editor_loaded(p) {continue}
		window.dirty = true
		switch publish in publication {
		case Publish_Saved:
			if ui.editor_source(p) != publish.previous {
				ui.editor_revision_stale(p, .Changed_Outside)
				continue
			}
			settings_publish_page(app, p, publish.revision, p == publish.origin ? .Saved_Origin : .Saved_Other)
		case Publish_Reloaded:
			settings_publish_page(app, p, publish.revision, .Reloaded)
		case Publish_Unavailable:
			ui.editor_revision_stale(p, .Refresh_Failed)
		case Publish_Reset:
			// The page is built afresh rather than carried over, which drops what the user had open.
			replacement, built := settings_page_build(app, publish.revision, nil)
			if !built {
				ui.editor_revision_stale(p, .Refresh_Failed)
				continue
			}
			ui.editor_destroy(p)
			p^ = replacement
		}
	}
}

// Rebuilds one page for `revision` and lets the page adopt it. Every way out short of adopting
// leaves the page behind the revision with its source and drafts intact.
@(private)
settings_publish_page :: proc(app: ^App, p: ^ui.Editor, revision: string, adoption: ui.Editor_Adoption) {
	if !ui.editor_process_capture(p) {
		notify(app, .Error, "Could not preserve the active program draft.")
		ui.editor_revision_stale(p, .Refresh_Failed)
		return
	}
	view, view_error := ui.editor_view_take(p)
	defer ui.editor_view_destroy(&view)
	if view_error != nil {
		notify(app, .Error, "Could not refresh the settings page. Reopen Settings to reload it.")
		ui.editor_revision_stale(p, .Refresh_Failed)
		return
	}
	replacement, built := settings_page_build(app, revision, &view)
	defer ui.editor_destroy(&replacement)
	if !built {
		ui.editor_revision_stale(p, .Refresh_Failed)
		return
	}
	if ui.editor_adopt(p, &replacement, adoption) == .Draft_Copy_Failed {
		notify(app, .Error, "Could not preserve program drafts.")
	}
}

toggle_tab_orientation :: proc(app: ^App) {
	@(static, rodata)
	names := settings.TABS_ORIENTATION_NAME
	next: settings.Tabs_Orientation = app.settings.tabs.orientation == .Horizontal ? .Vertical : .Horizontal
	settings_save_value(app, "tabs.orientation", names[next], "Could not save the tab orientation.")
}
