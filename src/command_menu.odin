package main

import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// What the Commands menu shows (D-092); it is held by Overlay_Command_Menu while the menu shows.
Command_Menu_Mode :: union #no_nil {
	Command_Menu_List,
	Command_Menu_Form,
}

// A search field, then the saved commands the pane can use: its folder's, its profile's and everywhere's.
Command_Menu_List :: struct {}

// Save Command… or Edit…: a command line and a name in Command_Menu.command and .name, then the level to
// keep it at. The menu owns `edit`, the ID of the command being edited, empty for a new one.
Command_Menu_Form :: struct {
	edit:    string,
	// The field that has the keyboard.
	typing:  Command_Form_Field,
	// The last save had no command line. Editing the command clears it.
	invalid: bool,
}

Command_Form_Field :: enum u8 {
	Command,
	Name,
}

Command_Menu_Action :: enum u8 {
	None,
	Search_Field,
	// A saved command: its click runs it, and its submenu holds the rest.
	Run,
	Save,
	Command_Field,
	Name_Field,
	// A level of the form's "Save for" step.
	Level,
}

Command_Menu_Entry :: struct {
	action: Command_Menu_Action,
	// The saved command a Run row stands for, a copy the menu owns.
	id:     string,
	level:  settings.Saved_Command_Level,
}

// A row of a command's submenu, carried as its payload.
Command_Choice :: enum u8 {
	Split_Right,
	Split_Down,
	Float,
	Tab,
	Linked_Window,
	Type,
	Edit,
	Move_Folder,
	Move_Profile,
	Move_Everywhere,
	Remove,
}

// A press on a command row, which lifts it out of the menu once the pointer passes the drag threshold
// and else runs it on release.
Command_Press :: struct {
	row:              int,
	start_x, start_y: f32,
}

// A command row carried out of the menu toward a pane, which a drop types it into. The menu hides while
// one is carried.
Command_Lift :: struct {
	row: int,
}

Command_Drag :: union {
	Command_Press,
	Command_Lift,
}

// Rows hold their own copies of what they show, so a settings change behind an open menu leaves nothing
// dangling; an action looks the command up again when it runs. Which pane and mode the rows are for is
// w.overlay.
Command_Menu :: struct {
	using menu: ui.Menu,
	entries:    [ui.MENU_MAX_ITEMS]Command_Menu_Entry,
	count:      int,
	text:       [dynamic]string,
	// What the list is filtered by. It has the keyboard while the list shows.
	search:     ui.Text_Field,
	command:    ui.Text_Field,
	name:       ui.Text_Field,
	// What else row `submenu.row` can do: run elsewhere, type, edit, move and remove. Its rows' payloads
	// are Command_Choices.
	submenu:    Menu_Submenu,
	drag:       Command_Drag,
}

@(private = "file")
COMMAND_SUBMENU_WIDTH :: f32(232)

@(private = "file", rodata)
COMMAND_CHOICES := [Command_Choice]struct {
	label: string,
	glyph: ui.Icon,
} {
	.Split_Right     = {"Run in Right Split", .Split_Right},
	.Split_Down      = {"Run in Down Split", .Split_Down},
	.Float           = {"Run in Float", .Float_Pane},
	.Tab             = {"Run in New Tab", .Layout_Top},
	.Linked_Window   = {"Run in Linked Window", .Window_Out},
	.Type            = {"Type into This Pane", .Command},
	.Edit            = {"Edit…", .Document},
	.Move_Folder     = {"Move to This Folder", .Folder},
	.Move_Profile    = {"", .Terminal},
	.Move_Everywhere = {"Move to Everywhere", .Globe},
	.Remove          = {"Remove", .Close},
}

@(private = "file", rodata)
COMMAND_LEVEL_GLYPHS := [settings.Saved_Command_Level]ui.Icon {
	.Folder     = .Folder,
	.Profile    = .Terminal,
	.Everywhere = .Globe,
}

command_menu_init :: proc(menu: ^Command_Menu) {
	ui.menu_init(&menu.menu)
	ui.menu_init(&menu.submenu.menu)
}

@(private = "file")
command_menu_text_clear :: proc(menu: ^Command_Menu) {
	for text in menu.text {delete(text)}
	clear(&menu.text)
}

// Frees the ID a Form mode holds; command_menu_close and command_menu_set call it.
command_menu_mode_release :: proc(mode: Command_Menu_Mode) {
	if form, editing := mode.(Command_Menu_Form); editing {delete(form.edit)}
}

// The menu's surface ends: the ID its mode holds, the text being typed, a carried row and the hover go.
command_menu_close :: proc(menu: ^Command_Menu, mode: Command_Menu_Mode) {
	command_menu_mode_release(mode)
	ui.field_release(&menu.search)
	ui.field_release(&menu.command)
	ui.field_release(&menu.name)
	menu.menu.hover_part = .Row
	submenu_reset(&menu.submenu)
	menu.drag = nil
}

// Takes w because a menu still showing when its window is freed holds an ID in w.overlay.
command_menu_destroy :: proc(w: ^Window) {
	if state, shown := w.overlay.(Overlay_Command_Menu); shown {command_menu_mode_release(state.mode)}
	menu := &w.command_menu
	command_menu_text_clear(menu)
	delete(menu.text)
	delete(menu.search.bytes)
	delete(menu.command.bytes)
	delete(menu.name.bytes)
	ui.menu_destroy(&menu.menu)
	ui.menu_destroy(&menu.submenu.menu)
}

command_menu_shown :: proc(w: ^Window) -> bool {
	_, shown := w.overlay.(Overlay_Command_Menu)
	return shown
}

// Whether the pane showing `content` draws its Commands button as open.
command_menu_shown_for :: proc(w: ^Window, content: layout.Content) -> bool {
	state, shown := w.overlay.(Overlay_Command_Menu)
	return shown && state.content == content
}

@(private = "file")
command_menu_state :: proc(w: ^Window) -> ^Overlay_Command_Menu {
	state, _ := &w.overlay.(Overlay_Command_Menu)
	return state
}

command_menu_form :: proc(w: ^Window) -> (Command_Menu_Form, bool) {
	state := command_menu_state(w)
	if state == nil {return {}, false}
	form, editing := state.mode.(Command_Menu_Form)
	return form, editing
}

// Whether a command row is carried out of the menu toward a pane.
command_menu_dragging :: proc(w: ^Window) -> bool {
	_, lifted := w.command_menu.drag.(Command_Lift)
	return lifted && command_menu_shown(w)
}

// The pane the menu is for, as saved commands see it. Its strings are temporary or borrowed.
@(private = "file")
Command_Pane :: struct {
	entry:              ^Session_Entry,
	directory, profile: string,
}

@(private = "file")
command_pane :: proc(app: ^App, content: layout.Content) -> (Command_Pane, bool) {
	entry := workspace_session_for_content(app, content)
	if entry == nil {return {}, false}
	directory, _ := pane_directory(app, entry)
	return {entry, directory, command_profile_id(app, entry.profile_id)}, true
}

// The profile `id` stands for: itself, or the default profile for none.
@(private = "file")
command_profile_id :: proc(app: ^App, id: string) -> string {
	if id != "" {return id}
	if profile := settings.profile_default(&app.settings.profiles); profile != nil {return profile.id}
	return settings.PROFILE_DEFAULT_ID
}

@(private = "file")
command_profile_name :: proc(app: ^App, id: string) -> string {
	profile := settings.profile_find(&app.settings.profiles, command_profile_id(app, id))
	return profile != nil && profile.name != "" ? profile.name : id
}

// The profile `command` runs with from a pane of `pane_profile` (D-092): a folder or profile command's
// own, an everywhere command the pane's.
@(private = "file")
command_run_profile :: proc(app: ^App, command: ^settings.Saved_Command, pane_profile: string) -> string {
	if command.level == .Everywhere {return pane_profile}
	return command_profile_id(app, command.profile)
}

@(private = "file")
command_label :: proc(command: ^settings.Saved_Command) -> string {
	return command.name != "" ? command.name : command.command
}

// Indices into the saved commands that a pane in `pane` offers at `level`, in saved order. A folder's
// commands include those of the folders above it, the nearest folder's first. Temporary.
@(private = "file")
commands_offered :: proc(app: ^App, pane: Command_Pane, level: settings.Saved_Command_Level) -> []int {
	saved := &app.settings.saved_commands
	order: [settings.SAVED_COMMAND_LIMIT]int
	offered := make([dynamic]int, 0, len(saved.items), context.temp_allocator)
	for index in order[:settings.saved_commands_in_order(saved, order[:])] {
		command := &saved.items[index]
		if command.level != level {continue}
		switch level {
		case .Folder:
			if !settings.saved_command_folder_contains(command.folder, pane.directory) {continue}
		case .Profile:
			if command_profile_id(app, command.profile) != pane.profile {continue}
		case .Everywhere:
		}
		append(&offered, index)
	}
	if level == .Folder {
		// Nearest folder first, keeping saved order within a folder.
		for i in 1 ..< len(offered) {
			for j := i; j > 0; j -= 1 {
				near, far := saved.items[offered[j]].folder, saved.items[offered[j - 1]].folder
				if len(near) <= len(far) {break}
				offered[j], offered[j - 1] = offered[j - 1], offered[j]
			}
		}
	}
	return offered[:]
}

// Whether every word of `query` is in one of `texts`, ignoring case.
@(private = "file")
command_matches :: proc(query: string, texts: ..string) -> bool {
	words := query
	for word in strings.fields_iterator(&words) {
		needle := strings.to_lower(word, context.temp_allocator)
		found := false
		for text in texts {
			if strings.contains(strings.to_lower(text, context.temp_allocator), needle) {found = true; break}
		}
		if !found {return false}
	}
	return true
}

@(private = "file")
command_menu_own :: proc(menu: ^Command_Menu, text: string) -> string {
	owned, err := strings.clone(text)
	if err != nil {return ""}
	if _, append_error := append(&menu.text, owned); append_error != nil {
		delete(owned)
		return ""
	}
	return owned
}

// Each row's payload keys its entry; a row the menu could not take gets none.
@(private = "file")
command_menu_push :: proc(menu: ^Command_Menu, item: ui.Menu_Item, entry: Command_Menu_Entry = {}) {
	row := item
	row.payload = u32(menu.count)
	added, err := ui.menu_add(&menu.menu, row)
	if err != nil {log.errorf("adding a command menu row failed: %v", err)}
	if !added {return}
	menu.entries[menu.count] = entry
	menu.count += 1
}

// The entry row `row` stands for, or none for a row out of range.
command_menu_entry :: proc(menu: ^Command_Menu, row: int) -> (Command_Menu_Entry, bool) {
	if row < 0 || row >= len(menu.menu.items) {return {}, false}
	key := int(menu.menu.items[row].payload)
	if key >= menu.count {return {}, false}
	return menu.entries[key], true
}

@(private = "file")
command_level_detail :: proc(pane: Command_Pane, level: settings.Saved_Command_Level) -> string {
	switch level {
	case .Folder: return pane.directory
	case .Profile: return "Any folder"
	case .Everywhere: return "Any shell"
	}
	return ""
}

@(private = "file")
command_level_label :: proc(app: ^App, pane: Command_Pane, level: settings.Saved_Command_Level) -> string {
	switch level {
	case .Folder: return "This Folder"
	case .Profile: return command_profile_name(app, pane.profile)
	case .Everywhere: return "Everywhere"
	}
	return ""
}

@(private = "file")
command_menu_build_list :: proc(app: ^App, menu: ^Command_Menu, pane: Command_Pane) {
	command_menu_push(menu, {}, {action = .Search_Field})
	query := ui.field_string(&menu.search)
	saved := &app.settings.saved_commands
	shown := 0
	for level in settings.Saved_Command_Level {
		header := false
		for index in commands_offered(app, pane, level) {
			command := &saved.items[index]
			if !command_matches(query, command.name, command.command) {continue}
			if !header {
				if shown > 0 {command_menu_push(menu, {separator = true})}
				label := command_menu_own(menu, command_level_label(app, pane, level))
				detail := command_menu_own(menu, command_level_detail(pane, level))
				command_menu_push(menu, {label = label, detail = detail, glyph = COMMAND_LEVEL_GLYPHS[level]})
				header = true
			}
			shown += 1
			detail := command.command
			if level == .Folder && !strings.equal_fold(command.folder, pane.directory) {
				detail = fmt.tprintf("from %s · %s", filepath.base(command.folder), command.command)
			}
			command_menu_push(
				menu,
				{
					label = command_menu_own(menu, command_label(command)),
					detail = command.name != "" || detail != command.command ? command_menu_own(menu, detail) : "",
					glyph = .Command,
					enabled = true,
					submenu = true,
				},
				{action = .Run, id = command_menu_own(menu, command.id)},
			)
		}
	}
	if shown == 0 {
		command_menu_push(menu, {label = query != "" ? "No commands match" : "No saved commands for this pane"})
	}
	command_menu_push(menu, {separator = true})
	save := ui.Menu_Item{label = "Save Command…", glyph = .Add, shortcut = "Ctrl+S", enabled = true}
	command_menu_push(menu, save, {action = .Save})
}

@(private = "file")
command_menu_build_form :: proc(app: ^App, menu: ^Command_Menu, pane: Command_Pane, form: Command_Menu_Form) {
	command_menu_push(menu, {label = form.edit != "" ? "Edit Command" : "Save a Command"})
	command_menu_push(menu, {}, {action = .Command_Field})
	command_menu_push(menu, {}, {action = .Name_Field})
	if form.invalid {command_menu_push(menu, {label = "Enter a command line.", danger = true})}
	command_menu_push(menu, {separator = true})
	command_menu_push(menu, {label = "Save for"})
	current: Maybe(settings.Saved_Command_Level)
	if command := settings.saved_command_find(&app.settings.saved_commands, form.edit); command != nil {
		if command_level_is(app, command, command.level, pane) {current = command.level}
	}
	for level in settings.Saved_Command_Level {
		item := ui.Menu_Item {
			label   = command_menu_own(menu, command_level_label(app, pane, level)),
			detail  = command_menu_own(menu, command_level_detail(pane, level)),
			glyph   = COMMAND_LEVEL_GLYPHS[level],
			enabled = true,
			checked = current == level,
		}
		command_menu_push(menu, item, {action = .Level, level = level})
	}
}

// Whether `command` is kept at `level` as this pane would keep it: the pane's folder, or its profile.
@(private = "file")
command_level_is :: proc(
	app: ^App,
	command: ^settings.Saved_Command,
	level: settings.Saved_Command_Level,
	pane: Command_Pane,
) -> bool {
	if command.level != level {return false}
	switch level {
	case .Folder: return strings.equal_fold(command.folder, pane.directory)
	case .Profile: return command_profile_id(app, command.profile) == pane.profile
	case .Everywhere: return true
	}
	return false
}

// Rebuilds the rows for the current mode. A list keeps the selection near where it was unless
// `select_first`; a form selects the level a save takes, the command's own when editing.
@(private = "file")
command_menu_build :: proc(app: ^App, w: ^Window, select_first := false) {
	state := command_menu_state(w)
	if state == nil {return}
	menu := &w.command_menu
	selected, scroll := ui.menu_selected(&menu.menu), menu.menu.scroll
	ui.menu_clear(&menu.menu)
	submenu_reset(&menu.submenu)
	menu.drag = nil
	command_menu_text_clear(menu)
	menu.count = 0
	menu.entries = {}
	pane, found := command_pane(app, state.content)
	if found {
		switch mode in state.mode {
		case Command_Menu_List:
			command_menu_build_list(app, menu, pane)
		case Command_Menu_Form:
			command_menu_build_form(app, menu, pane, mode)
		}
	}
	if _, editing := state.mode.(Command_Menu_Form); editing {
		first := -1
		for item, row in menu.menu.items {
			entry, _ := command_menu_entry(menu, row)
			if entry.action != .Level {continue}
			if first < 0 || item.checked {first = row}
			if item.checked {break}
		}
		ui.menu_select(&menu.menu, first)
	} else if select_first {
		ui.menu_select_edge(&menu.menu, false)
	} else {
		menu.menu.scroll = scroll
		ui.menu_select(&menu.menu, clamp(selected, 0, max(0, len(menu.menu.items) - 1)))
		if len(menu.menu.items) > 0 && !menu.menu.items[ui.menu_selected(&menu.menu)].enabled {
			ui.menu_step(&menu.menu, 1)
		}
	}
	ui.menu_reveal(&menu.menu, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

// The only writer of the mode while the menu shows. Leaving a form frees the ID it held.
@(private = "file")
command_menu_set :: proc(app: ^App, w: ^Window, next: Command_Menu_Mode, select_first := true) {
	state := command_menu_state(w)
	if state == nil {
		command_menu_mode_release(next)
		return
	}
	command_menu_mode_release(state.mode)
	state.mode = next
	command_menu_build(app, w, select_first)
}

@(private = "file")
command_menu_show :: proc(app: ^App, w: ^Window, content: layout.Content, x, y: f32) {
	overlay_open(app, w, Overlay_Command_Menu{content, Command_Menu_List{}})
	ui.field_set(&w.command_menu.search, "")
	ui.menu_anchor(&w.command_menu.menu, x, y)
	command_menu_build(app, w, true)
}

command_menu_open_pane :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	if !CONTENT_POLICY[pane.content.kind].commands {return}
	anchor := pane_header_menu_anchor(w, pane, .Commands)
	command_menu_show(app, w, pane.content, anchor.x, anchor.y)
}

// The Show Commands command: the only way to the menu for a split pane with headers off.
command_menu_open_focused :: proc(app: ^App, w: ^Window) {
	tree := window_tree(w)
	if tree == nil {return}
	for pane in w.panes {
		if pane.node != tree.focus {continue}
		if !CONTENT_POLICY[pane.content.kind].commands {
			notify(app, .Info, "Saved commands run in terminal panes.")
			return
		}
		if !gesture_cancel(app, w) {return}
		command_menu_open_pane(app, w, pane)
		return
	}
}

// Opens the form, empty for a new command or filled in from the command `edit` names.
@(private = "file")
command_form_open :: proc(app: ^App, w: ^Window, edit: string) {
	menu := &w.command_menu
	command := settings.saved_command_find(&app.settings.saved_commands, edit)
	ui.field_set(&menu.command, command != nil ? command.command : "")
	ui.field_set(&menu.name, command != nil ? command.name : "")
	owned := ""
	if command != nil {
		clone, err := strings.clone(edit)
		if err != nil {return}
		owned = clone
	}
	command_menu_set(app, w, Command_Menu_Form{edit = owned})
}

// Saves the form's command at `level`, then shows the list again. An empty command line stays in the
// form with a complaint.
@(private = "file")
command_form_save :: proc(app: ^App, w: ^Window, level: settings.Saved_Command_Level) {
	state := command_menu_state(w)
	form, editing := command_menu_form(w)
	if state == nil || !editing {return}
	pane, found := command_pane(app, state.content)
	if !found {return}
	menu := &w.command_menu
	line := strings.trim_space(ui.field_string(&menu.command))
	if line == "" {
		form.invalid, form.typing = true, .Command
		state.mode = form
		command_menu_build(app, w)
		return
	}
	change := settings.Saved_Command_Mutation {
		kind    = .Add,
		name    = ui.field_string(&menu.name),
		command = line,
		level   = level,
		folder  = pane.directory,
		profile = pane.profile,
	}
	if command := settings.saved_command_find(&app.settings.saved_commands, form.edit); command != nil {
		change.kind, change.id = .Edit, form.edit
		// A command kept where it was keeps its own folder and profile.
		if command.level == level {change.folder, change.profile = command.folder, command.profile}
	}
	if command_settings_change(app, change) {ui.field_set(&menu.search, "")}
	command_menu_set(app, w, Command_Menu_List{})
}

// Saves a change to the saved commands, reporting a failure.
@(private = "file")
command_settings_change :: proc(app: ^App, change: settings.Saved_Command_Mutation) -> bool {
	result := settings_change(app, change, Settings_Current{})
	if result.status == .Applied || result.status == .Unchanged {return true}
	if text := settings_result_text(result, .Saved_Command); text != "" {notify(app, .Error, text)}
	return false
}

// Moves the command row `row` stands for to `level` as the menu's pane keeps it, or removes it.
@(private = "file")
command_menu_change :: proc(app: ^App, w: ^Window, row: int, choice: Command_Choice) {
	state := command_menu_state(w)
	entry, listed := command_menu_entry(&w.command_menu, row)
	if state == nil || !listed || entry.action != .Run {return}
	command := settings.saved_command_find(&app.settings.saved_commands, entry.id)
	pane, found := command_pane(app, state.content)
	if command == nil || !found {return}
	change := settings.Saved_Command_Mutation{kind = .Remove, id = entry.id}
	if choice != .Remove {
		change = {
			kind    = .Edit,
			id      = entry.id,
			name    = command.name,
			command = command.command,
			level   = settings.Saved_Command_Level(int(choice) - int(Command_Choice.Move_Folder)),
			folder  = pane.directory,
			profile = pane.profile,
		}
	}
	_ = command_settings_change(app, change)
	command_menu_build(app, w)
}

// Runs the saved command `id` in a new shell at `placement` beside the pane showing `content` in w, as
// though typed there and Enter pressed. A folder command starts in its folder, with the profile it was
// saved from; a profile command with its profile, in the pane's folder when the pane has that profile;
// an everywhere command with the pane's profile and folder.
command_run :: proc(app: ^App, w: ^Window, content: layout.Content, id: string, placement: Pane_Placement) {
	command := settings.saved_command_find(&app.settings.saved_commands, id)
	if command == nil {
		notify(app, .Error, "That command is no longer saved.")
		return
	}
	pane, found := command_pane(app, content)
	line := strings.clone(command.command, context.temp_allocator)
	launch := Pane_Launch{profile = command_run_profile(app, command, pane.profile)}
	switch command.level {
	case .Folder:
		if !os.is_dir(command.folder) {
			notify(app, .Error, fmt.tprintf("The folder %s is not there any more.", command.folder))
			return
		}
		launch.directory = command.folder
	case .Profile, .Everywhere:
		if found && launch.profile == pane.profile {launch.directory = pane.directory}
	}
	launch.directory = strings.clone(launch.directory, context.temp_allocator)
	launch.profile = strings.clone(launch.profile, context.temp_allocator)
	tree := window_tree(w)
	if tree == nil {return}
	node := layout.find_content(tree, content)
	if node == layout.INVALID_NODE {node = tree.focus}
	session, opened := shell_open_placed(app, w, node, launch, placement)
	if !opened {
		notify(app, .Error, "Could not open a shell.")
		return
	}
	if outcome := pane_send(session_find(app, session), line, true); outcome.status != .Ok {
		notify(app, .Error, "Could not type the command into the new shell.")
	}
}

// Types `text` at the prompt of the pane showing `content`, without Enter, after anything already typed.
// It goes as a paste, so a program with bracketed paste takes it whole.
command_type :: proc(app: ^App, content: layout.Content, text: string) -> bool {
	entry := workspace_session_for_content(app, content)
	if entry == nil || entry.status != .Running {
		notify(app, .Error, "That pane's program is not running.")
		return false
	}
	if term.paste(entry.session, text) != .Sent {
		notify(app, .Error, "That pane is not accepting input.")
		return false
	}
	return true
}

// Whether the command `id` was saved for another profile than the pane showing `content` runs, so a
// drop there warns.
@(private = "file")
command_profile_mismatch :: proc(app: ^App, id: string, content: layout.Content) -> (string, bool) {
	command := settings.saved_command_find(&app.settings.saved_commands, id)
	pane, found := command_pane(app, content)
	if command == nil || !found || command.level == .Everywhere {return "", false}
	profile := command_run_profile(app, command, pane.profile)
	return command_profile_name(app, profile), profile != pane.profile
}

@(private = "file")
command_placement :: proc(choice: Command_Choice) -> Pane_Placement {
	#partial switch choice {
	case .Split_Down: return .Split_Down
	case .Float: return .Float
	case .Tab: return .Tab
	case .Linked_Window: return .Linked_Window
	}
	return .Split_Right
}

// Runs a submenu row on the command row `row` stands for. Running or typing closes the menu.
@(private = "file")
command_choose :: proc(app: ^App, w: ^Window, row: int, choice: Command_Choice) {
	state := command_menu_state(w)
	entry, listed := command_menu_entry(&w.command_menu, row)
	if state == nil || !listed || entry.action != .Run {return}
	content := state.content
	id := strings.clone(entry.id, context.temp_allocator)
	switch choice {
	case .Split_Right, .Split_Down, .Float, .Tab, .Linked_Window:
		overlay_close(app, w)
		command_run(app, w, content, id, command_placement(choice))
	case .Type:
		command := settings.saved_command_find(&app.settings.saved_commands, id)
		if command == nil {return}
		text := strings.clone(command.command, context.temp_allocator)
		overlay_close(app, w)
		_ = command_type(app, content, text)
	case .Edit:
		command_form_open(app, w, id)
	case .Move_Folder, .Move_Profile, .Move_Everywhere, .Remove:
		command_menu_change(app, w, row, choice)
	}
}

// Fills the submenu with what row `row`'s command can do besides its click: the other placements, typing,
// editing, the levels it is not at and removing.
@(private = "file")
command_submenu_open :: proc(app: ^App, w: ^Window, row: int, select_first: bool) {
	menu := &w.command_menu
	sub := &menu.submenu
	state := command_menu_state(w)
	entry, listed := command_menu_entry(menu, row)
	if state == nil || !listed || entry.action != .Run {
		submenu_close(w, sub)
		return
	}
	if current, open := sub.row.?; open && current == row && !select_first {return}
	command := settings.saved_command_find(&app.settings.saved_commands, entry.id)
	pane, found := command_pane(app, state.content)
	if command == nil || !found {return}
	ui.menu_clear(&sub.menu)
	add :: proc(sub: ^Menu_Submenu, item: ui.Menu_Item) {_, _ = ui.menu_add(&sub.menu, item)}
	// Moving and removing follow a divider of their own.
	divided := false
	for choice in Command_Choice {
		face := COMMAND_CHOICES[choice]
		item := ui.Menu_Item{label = face.label, glyph = face.glyph, enabled = true, payload = u32(choice)}
		#partial switch choice {
		case .Split_Right:
			item.shortcut = "Default"
		case .Type:
			add(sub, {separator = true})
			item.shortcut = "Alt+Enter"
		case .Move_Folder, .Move_Profile, .Move_Everywhere:
			level := settings.Saved_Command_Level(int(choice) - int(Command_Choice.Move_Folder))
			if command_level_is(app, command, level, pane) {continue}
			if choice == .Move_Profile {
				label := fmt.tprintf("Move to %s", command_profile_name(app, pane.profile))
				item.label = command_menu_own(menu, label)
			}
		}
		if choice >= .Move_Folder && !divided {
			add(sub, {separator = true})
			divided = true
		}
		add(sub, item)
	}
	submenu_place(w, sub, &menu.menu, row, COMMAND_SUBMENU_WIDTH, select_first)
}

@(private = "file")
command_submenu_parent :: proc(w: ^Window) -> ^ui.Menu {
	if _, editing := command_menu_form(w); editing || !command_menu_shown(w) {return nil}
	return &w.command_menu.menu
}

command_submenu_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	parent := command_submenu_parent(w)
	if parent == nil || command_menu_dragging(w) {return}
	if submenu_tick(app, w, &w.command_menu.submenu, parent, command_submenu_open, now) {
		command_menu_hover(app, w, w.pointer.x, w.pointer.y, false)
	}
}

command_submenu_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	if command_submenu_parent(w) == nil {return {}, false}
	return submenu_deadline(&w.command_menu.submenu)
}

command_submenu_shown :: proc(w: ^Window) -> bool {
	return command_submenu_parent(w) != nil && submenu_shown(&w.command_menu.submenu)
}

// The click of row `row`: a command runs at Right Split, Save Command… opens the form, and in the form a
// level saves there.
@(private = "file")
command_menu_activate :: proc(app: ^App, w: ^Window, row: int) {
	entry, listed := command_menu_entry(&w.command_menu, row)
	if !listed {return}
	switch entry.action {
	case .None, .Search_Field:
	case .Run:
		command_choose(app, w, row, .Split_Right)
	case .Save:
		command_form_open(app, w, "")
	case .Command_Field, .Name_Field:
		form, editing := command_menu_form(w)
		if !editing {return}
		form.typing = entry.action == .Command_Field ? .Command : .Name
		command_menu_state(w).mode = form
		w.dirty = true
	case .Level:
		command_form_save(app, w, entry.level)
	}
}

// The selected row's submenu, opened from the keyboard.
@(private = "file")
command_submenu_open_selected :: proc(app: ^App, w: ^Window) {
	row := ui.menu_selected(&w.command_menu.menu)
	if entry, listed := command_menu_entry(&w.command_menu, row); listed && entry.action == .Run {
		command_submenu_open(app, w, row, true)
	}
}

// In the list the search field has the keyboard: Up and Down move, Enter runs, Alt+Enter types into the
// pane, Right, Ctrl+Enter, the Menu key or Shift+F10 open the row's submenu and Ctrl+S opens the form. In
// the form the field being typed in has it: Tab moves between the fields, Up and Down pick the level and
// Enter saves there. Escape steps back.
command_menu_key :: proc(app: ^App, w: ^Window, raw, logical: input.Key_Event) {
	state := command_menu_state(w)
	if state == nil || !logical.pressed {return}
	menu := &w.command_menu
	if _, lifted := menu.drag.(Command_Lift); lifted {
		if logical.key == .Escape {command_drag_end(w)}
		return
	}
	sub := &menu.submenu
	if command_submenu_shown(w) {
		switch submenu_key(w, sub, logical) {
		case .Pass:
		case .Taken:
			return
		case .Chosen:
			row, _ := sub.row.?
			command_choose(app, w, row, Command_Choice(sub.items[ui.menu_selected(&sub.menu)].payload))
			return
		}
	}
	if form, editing := state.mode.(Command_Menu_Form); editing {
		field := form.typing == .Command ? &menu.command : &menu.name
		#partial switch logical.key {
		case .Escape:
			command_menu_set(app, w, Command_Menu_List{})
			return
		case .Tab:
			form.typing = form.typing == .Command ? .Name : .Command
			state.mode = form
			w.dirty = true
			return
		case .Enter, .Numpad_Enter:
			command_menu_activate(app, w, ui.menu_selected(&menu.menu))
			return
		}
		if step := ui.list_step(logical); step != 0 {
			ui.menu_step(&menu.menu, step)
			w.dirty = true
			return
		}
		if field_edit_key(app, field, raw).change != .None && form.invalid && form.typing == .Command {
			form.invalid = false
			state.mode = form
			command_menu_build(app, w)
		}
		w.dirty = true
		return
	}
	#partial switch logical.key {
	case .Enter, .Numpad_Enter:
		row := ui.menu_selected(&menu.menu)
		if .Control in logical.modifiers {
			command_submenu_open_selected(app, w)
		} else if .Alt in logical.modifiers {
			command_choose(app, w, row, .Type)
		} else {
			command_menu_activate(app, w, row)
		}
		return
	case .Context_Menu:
		command_submenu_open_selected(app, w)
		return
	case .Arrow_Right:
		// Right moves the search's caret until it reaches the end, then opens the row's submenu.
		search := &menu.search
		if logical.modifiers == {} && search.cursor == len(search.bytes) && search.anchor == search.cursor {
			command_submenu_open_selected(app, w)
			return
		}
	case .F10:
		if logical.modifiers == {.Shift} {
			command_submenu_open_selected(app, w)
			return
		}
	case .S:
		if logical.modifiers == {.Control} {
			command_form_open(app, w, "")
			return
		}
	case .Escape:
		// Escape clears a search before it closes the menu.
		if ui.field_string(&menu.search) != "" {
			ui.field_set(&menu.search, "")
			command_menu_build(app, w, true)
			return
		}
		overlay_close(app, w)
		return
	}
	if step := ui.list_step(logical); step != 0 {
		submenu_close(w, sub)
		ui.menu_step(&menu.menu, step)
		ui.menu_reveal(&menu.menu, f32(w.width), f32(w.height), w.scale)
		w.dirty = true
		return
	}
	if field_edit_key(app, &menu.search, raw).change != .None {command_menu_build(app, w, true)}
	w.dirty = true
}

command_menu_wheel :: proc(app: ^App, w: ^Window, rows: int) {
	if command_menu_dragging(w) {return}
	menu := &w.command_menu
	submenu_close(w, &menu.submenu)
	ui.menu_wheel(&menu.menu, rows)
	ui.menu_reveal(&menu.menu, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

// Typing goes to the form's field being typed in, or else to the list's search.
command_menu_text_input :: proc(app: ^App, w: ^Window, text: string) {
	state := command_menu_state(w)
	if state == nil || command_menu_dragging(w) {return}
	menu := &w.command_menu
	if form, editing := state.mode.(Command_Menu_Form); editing {
		field := form.typing == .Command ? &menu.command : &menu.name
		if ui.field_text(field, text) != .None && form.invalid && form.typing == .Command {
			form.invalid = false
			state.mode = form
			command_menu_build(app, w)
		}
		w.dirty = true
		return
	}
	if ui.field_text(&menu.search, text) != .None {command_menu_build(app, w, true)}
}

// The box of the field row `action` names, with the field it edits.
@(private = "file")
command_field_box :: proc(w: ^Window, action: Command_Menu_Action) -> (ui.Field_Box, ^ui.Text_Field, bool) {
	menu := &w.command_menu
	field := &menu.search
	#partial switch action {
	case .Command_Field: field = &menu.command
	case .Name_Field: field = &menu.name
	}
	for i in 0 ..< len(menu.menu.items) {
		if entry, _ := command_menu_entry(menu, i); entry.action != action {continue}
		rect := ui.menu_row_rect(&menu.menu, i, f32(w.width), f32(w.height), w.scale)
		return ui.field_box_standard(field, &w.ui_text, rect, w.scale), field, true
	}
	return {}, nil, false
}

@(private = "file", rodata)
COMMAND_FIELDS := [?]Command_Menu_Action{.Search_Field, .Command_Field, .Name_Field}

// A carried row ends: the menu shows again as it was.
@(private = "file")
command_drag_end :: proc(w: ^Window) {
	if w.command_menu.drag != nil {w.dirty = true}
	w.command_menu.drag = nil
}

// The terminal pane under x, y that a carried command would be typed into.
@(private = "file")
command_drop_target :: proc(app: ^App, w: ^Window, x, y: f32) -> (layout.Pane_Rect, bool) {
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found || workspace_session_for_content(app, pane.content) == nil {return {}, false}
	return pane, true
}

// A press past the drag threshold lifts its row out of the menu; a lifted row follows the pointer. True
// while the press or lift has the pointer.
@(private = "file")
command_drag_hover :: proc(app: ^App, w: ^Window, x, y: f32, left_held: bool) -> bool {
	menu := &w.command_menu
	if menu.drag == nil {return false}
	if !left_held {
		command_drag_end(w)
		return false
	}
	if press, pressed := menu.drag.(Command_Press); pressed {
		if math.abs(x - press.start_x) < DRAG_THRESHOLD * w.scale &&
		   math.abs(y - press.start_y) < DRAG_THRESHOLD * w.scale {
			pointer_set(app, w, .Hand)
			return true
		}
		menu.drag = Command_Lift{press.row}
		submenu_reset(&menu.submenu)
	}
	w.dirty = true
	pointer_set(app, w, .Hand)
	return true
}

// The release of a press on a command row: a press that never lifted runs its row if released on it, and
// a lifted row dropped on a terminal pane types its command there. A drop elsewhere shows the menu again.
@(private = "file")
command_drag_release :: proc(app: ^App, w: ^Window, x, y: f32) {
	menu := &w.command_menu
	switch drag in menu.drag {
	case nil:
	case Command_Press:
		menu.drag = nil
		if ui.menu_hit(&menu.menu, x, y, f32(w.width), f32(w.height), w.scale) == drag.row {
			command_menu_activate(app, w, drag.row)
		}
	case Command_Lift:
		menu.drag = nil
		w.dirty = true
		entry, listed := command_menu_entry(menu, drag.row)
		target, over := command_drop_target(app, w, x, y)
		if !listed || !over {return}
		command := settings.saved_command_find(&app.settings.saved_commands, entry.id)
		if command == nil {return}
		text := strings.clone(command.command, context.temp_allocator)
		overlay_close(app, w)
		if command_type(app, target.content, text) {
			if tree := window_tree(w); tree != nil {pane_focus(app, w, target.node)}
		}
	}
}

command_menu_hover :: proc(app: ^App, w: ^Window, x, y: f32, left_held: bool) {
	if command_drag_hover(app, w, x, y, left_held) {return}
	menu := &w.command_menu
	if parent := command_submenu_parent(w); parent != nil {
		if submenu_hover(app, w, &menu.submenu, parent, command_submenu_open, x, y) {
			over := ui.menu_hit(&menu.submenu.menu, x, y, f32(w.width), f32(w.height), w.scale) >= 0
			pointer_set(app, w, over ? .Hand : .Arrow)
			return
		}
	}
	for action in COMMAND_FIELDS {
		box, field, shown := command_field_box(w, action)
		if !shown {continue}
		if field.dragging && left_held {
			ui.field_pointer(field, ui.field_box_offset(box, x), false, true)
			w.dirty = true
		}
		if render.rect_contains(box.rect, x, y) {
			pointer_set(app, w, .Text)
			return
		}
	}
	shape := platform.Cursor_Shape.Arrow
	if hit := ui.menu_hit(&menu.menu, x, y, f32(w.width), f32(w.height), w.scale); hit >= 0 {
		item := menu.menu.items[hit]
		if item.enabled && !item.separator {
			if hit != ui.menu_selected(&menu.menu) {ui.menu_select(&menu.menu, hit); w.dirty = true}
			shape = .Hand
		}
	}
	pointer_set(app, w, shape)
}

// A left click runs a row, and a press on a command row may become a drag that types it into a pane. A
// right click on a command row opens its submenu.
command_menu_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	menu := &w.command_menu
	x, y := f32(e.x), f32(e.y)
	if !e.pressed {
		w.dirty = true
		ui.field_release(&menu.search)
		ui.field_release(&menu.command)
		ui.field_release(&menu.name)
		if e.button == .Left {command_drag_release(app, w, x, y)}
		return
	}
	gesture_swallow(w, e.button, .Command_Menu)
	width, height := f32(w.width), f32(w.height)
	if command_submenu_shown(w) {
		if hit := ui.menu_hit(&menu.submenu.menu, x, y, width, height, w.scale); hit >= 0 {
			if e.button == .Left && menu.submenu.items[hit].enabled && !menu.submenu.items[hit].separator {
				row, _ := menu.submenu.row.?
				command_choose(app, w, row, Command_Choice(menu.submenu.items[hit].payload))
			}
			return
		}
	}
	hit := ui.menu_hit(&menu.menu, x, y, width, height, w.scale)
	if hit < 0 {
		overlay_close(app, w)
		return
	}
	entry, _ := command_menu_entry(menu, hit)
	if e.button == .Right {
		if entry.action == .Run {
			ui.menu_select(&menu.menu, hit)
			command_submenu_open(app, w, hit, true)
		}
		return
	}
	if e.button != .Left {return}
	for action in COMMAND_FIELDS {
		if entry.action != action {continue}
		if box, field, shown := command_field_box(w, action); shown {
			command_menu_activate(app, w, hit)
			ui.field_pointer(field, ui.field_box_offset(box, x), true, .Shift in e.modifiers)
			w.dirty = true
		}
		return
	}
	item := menu.menu.items[hit]
	if !item.enabled || item.separator {return}
	ui.menu_select(&menu.menu, hit)
	if entry.action == .Run {
		menu.drag = Command_Press{hit, x, y}
		w.dirty = true
		return
	}
	command_menu_activate(app, w, hit)
}

command_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	if command_menu_dragging(w) {return command_drag_draw(app, w)}
	menu := &w.command_menu
	s := w.scale
	width, height := f32(w.width), f32(w.height)
	if result := ui.menu_draw(&menu.menu, &w.list, &w.ui_text, app.theme, width, height, s, w.pointer);
	   result != .Ok {return result}
	form, editing := command_menu_form(w)
	for action in COMMAND_FIELDS {
		box, _, shown := command_field_box(w, action)
		if !shown {continue}
		focused := !editing || form.typing == (action == .Command_Field ? .Command : .Name)
		radius := ui.RADIUS_CONTROL * s
		if render.push_rect(&w.list, {rect = box.rect, color = app.theme.pane, radius = radius}) != .None {
			return .Ok
		}
		ink := editing && focused ? app.theme.accent : app.theme.border
		if render.push_rect(&w.list, {rect = box.rect, color = ink, radius = radius, stroke = s}) != .None {
			return .Ok
		}
		placeholder := "Search commands"
		#partial switch action {
		case .Command_Field: placeholder = "Command line"
		case .Name_Field: placeholder = "Name (optional)"
		}
		if result := ui.field_box_draw(box, &w.list, app.theme, ui.field_box_baseline(box), focused, placeholder);
		   result != .Ok {return result}
	}
	if command_submenu_shown(w) {
		return ui.menu_draw(&menu.submenu.menu, &w.list, &w.ui_text, app.theme, width, height, s, w.pointer)
	}
	return .Ok
}

// While a command is carried the menu hides. The terminal pane under the pointer shows where a drop
// types it, warning when the command was saved for another profile, and the command's name follows the
// pointer.
@(private = "file")
command_drag_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	menu := &w.command_menu
	lift := menu.drag.(Command_Lift)
	entry, _ := command_menu_entry(menu, lift.row)
	s := w.scale
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	strong := ui.text_styled(&w.ui_text, .Strong)
	detail := ui.text_styled(&w.ui_text, .Detail)
	if target, over := command_drop_target(app, w, w.pointer.x, w.pointer.y); over {
		r := render.Rect{target.rect.x, target.rect.y, target.rect.width, target.rect.height}
		radius := f32(app.settings.pane.corner_radius) * s
		fill := app.theme.accent
		fill.a = 0.16
		if render.push_rect(&w.list, {rect = r, color = fill, radius = radius}) != .None {return .Ok}
		edge := render.Rect_Instance{rect = r, color = app.theme.accent, radius = radius, stroke = 2 * s}
		if render.push_rect(&w.list, edge) != .None {return .Ok}
		title := content_pane_title(app, workspace_session_for_content(app, target.content), target.content)
		lines := [3]string{fmt.tprintf("Type into %s", title), "Not run", ""}
		if profile, mismatch := command_profile_mismatch(app, entry.id, target.content); mismatch {
			lines[2] = fmt.tprintf("Saved for %s", profile)
		}
		y := r.y + r.height / 2 - strong.line_height
		for line, i in lines {
			if line == "" {continue}
			text := i == 0 ? &strong : &detail
			ink := i == 0 ? app.theme.text : i == 2 ? app.theme.warning : app.theme.muted
			width := ui.text_width(text, line)
			x := r.x + max(8 * s, (r.width - width) / 2)
			if result := ui.draw_text(text, &w.list, line, x, y + text.ascent, ink, max(1, r.width - 16 * s));
			   result != .Ok {return result}
			y += text.line_height + ui.SPACE_1 * s
		}
	}
	label := lift.row < len(menu.menu.items) ? menu.menu.items[lift.row].label : ""
	pad := ui.SPACE_2 * s
	chip := render.Rect {
		w.pointer.x + 12 * s,
		w.pointer.y + 12 * s,
		min(ui.text_width(&w.ui_text, label), 240 * s) + 2 * pad,
		ui.HEIGHT_COMPACT * s,
	}
	if ui.panel_draw(&w.list, ui.popover_panel(chip, s), app.theme) != .None {return .Ok}
	baseline := chip.y + (chip.height - w.ui_text.line_height) / 2 + w.ui_text.ascent
	return ui.draw_text(&w.ui_text, &w.list, label, chip.x + pad, baseline, app.theme.text, chip.width - 2 * pad)
}

when AIO_CONTROL {
	// The Commands menu's keys; commands.mode is list or form, and empty while it is closed.
	command_menu_state_report :: proc(r: ^State_Report, w: ^Window) {
		mode := ""
		if state, shown := w.overlay.(Overlay_Command_Menu); shown {
			switch _ in state.mode {
			case Command_Menu_List: mode = "list"
			case Command_Menu_Form: mode = "form"
			}
		}
		menu := &w.command_menu
		labels := strings.builder_make(context.temp_allocator)
		for item, row in menu.menu.items {
			if entry, _ := command_menu_entry(menu, row); entry.action != .Run {continue}
			if strings.builder_len(labels) > 0 {strings.write_byte(&labels, ';')}
			strings.write_string(&labels, item.label)
		}
		state_value(r, "commands.open", command_menu_shown(w))
		state_text(r, "commands.mode", mode)
		state_text(r, "commands.rows", strings.to_string(labels))
		state_value(r, "commands.submenu", command_submenu_shown(w))
		state_value(r, "commands.dragging", command_menu_dragging(w))
		state_text(r, "commands.query", ui.field_string(&menu.search))
	}
}

// Command menu pointer surface

@(private)
command_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return command_menu_shown(w)}

@(private)
command_menu_pointer_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner == .Command_Menu {command_menu_hover(app, w, f32(e.x), f32(e.y), .Left in e.buttons)}
}

@(private)
command_menu_pointer_cancel :: proc(app: ^App, w: ^Window) {
	ui.field_release(&w.command_menu.search)
	ui.field_release(&w.command_menu.command)
	ui.field_release(&w.command_menu.name)
	command_drag_end(w)
}

@(private)
command_menu_leave :: proc(_: ^App, w: ^Window) {
	w.command_menu.menu.hover_part = .Row
}
