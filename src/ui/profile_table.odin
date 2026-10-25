package ui

import "aio:render"
import "aio:settings"
import "base:runtime"
import "core:fmt"
import "core:strings"

// One profile as the settings table reads it. The strings are owned by Profile_Table.
Profile_Row :: struct {
	id, name, command, directory, icon, badge, note: string,
	hidden, detected, is_default, listed:           bool,
}

// The user profiles in profile.order order and the detected shells that are not overridden.
Profile_Table :: struct {
	rows, detected: [dynamic]Profile_Row,
	allocator:      runtime.Allocator,
}

// A caller-supplied check keeps the table model free of the filesystem. It answers whether the
// command line's executable can be found, and nil means the caller does not check.
Profile_Command_Check :: #type proc(command: string) -> bool

// The content width below which the Directory column is dropped. Name and command keep the room.
PROFILE_DIRECTORY_MIN_WIDTH :: 700
// Below these the Actions and Icon columns are dropped before any cell could overlap.
PROFILE_ACTIONS_MIN_WIDTH :: 520
PROFILE_ICON_MIN_WIDTH :: 420

// One column's cell inside a table row. Zero-sized cells are not shown.
Profile_Columns :: struct {
	handle, icon, name, command, directory, default, hidden, actions: render.Rect,
	directory_shown, actions_shown, icon_shown:                      bool,
}

@(private)
profile_table_init :: proc(table: ^Profile_Table, allocator := context.allocator) {
	table.allocator = allocator
	table.rows.allocator = allocator
	table.detected.allocator = allocator
}

profile_table_destroy :: proc(table: ^Profile_Table) {
	for &row in table.rows {profile_row_destroy(&row, table.allocator)}
	for &row in table.detected {profile_row_destroy(&row, table.allocator)}
	delete(table.rows)
	delete(table.detected)
	table^ = {}
}

@(private)
profile_row_destroy :: proc(row: ^Profile_Row, allocator: runtime.Allocator) {
	for field in ([?]string{row.id, row.name, row.command, row.directory, row.icon, row.badge, row.note}) {
		delete(field, allocator)
	}
}

@(private)
profile_row_note :: proc(
	profiles: ^settings.Profiles,
	profile: ^settings.Profile,
) -> string {
	if strings.trim_space(profile.name) == "" {return "A profile needs a name."}
	if strings.trim_space(profile.command) == "" {return "A profile needs a command line."}
	// Enabled profiles are compared with each other, and detected candidates with each other: a
	// detected shell that merely shares a default name is not yet a duplicate in the table.
	target := strings.trim_space(profile.name)
	for &other in profiles.items {
		if other.id == profile.id || other.detected != profile.detected {continue}
		if strings.equal_fold(strings.trim_space(other.name), target) {
			return "Another profile uses this name."
		}
	}
	return ""
}

// Builds the table from the resolved profile list. Detection marks its own rows, so only file
// profiles take part in the main table; duplicate names and unreadable commands become row notes.
@(require_results)
profile_table_build :: proc(
	profiles: ^settings.Profiles,
	command_exists: Profile_Command_Check = nil,
	allocator := context.allocator,
) -> (
	table: Profile_Table,
	alloc_error: runtime.Allocator_Error,
) {
	profile_table_init(&table, allocator)
	success := false
	defer if !success {profile_table_destroy(&table)}
	default := settings.profile_default(profiles)
	ids := make([]int, len(profiles.items), context.temp_allocator)
	count := settings.profiles_in_order(profiles, ids)
	for index in ids[:count] {
		profile := &profiles.items[index]
		row := Profile_Row {
			hidden     = profile.hidden,
			detected   = profile.detected,
			is_default = default != nil && profile.id == default.id,
			listed     = settings.profile_order_has(profiles, profile.id),
		}
		row_ok := false
		defer if !row_ok {profile_row_destroy(&row, allocator)}
		row.id = strings.clone(profile.id, allocator) or_return
		row.name = strings.clone(profile.name, allocator) or_return
		row.command = strings.clone(profile.command, allocator) or_return
		row.directory = strings.clone(profile.directory, allocator) or_return
		row.icon = strings.clone(profile.icon, allocator) or_return
		row.badge = strings.clone(
			settings.shell_icon(settings.shell_executable(profile.command), ""),
			allocator,
		) or_return
		note := profile_row_note(profiles, profile)
		if note == "" &&
		   !profile.detected &&
		   command_exists != nil &&
		   !command_exists(profile.command) {
			executable := settings.shell_executable(profile.command)
			note = fmt.tprintf("Command not found: %s.", executable)
		}
		row.note = strings.clone(note, allocator) or_return
		target := profile.detected ? &table.detected : &table.rows
		if _, append_error := append(target, row); append_error != nil {return {}, append_error}
		row_ok = true
	}
	success = true
	return table, nil
}

// Lays out the table's columns inside one row. Columns are placed left to right and every width
// is clipped to the remaining room, so cells never overlap; text columns absorb the space the
// fixed controls leave, and the Directory column is the first to go when the content narrows.
profile_columns :: proc(row: render.Rect, scale: f32) -> Profile_Columns {
	s := scale
	pad := 10 * s
	gap := 8 * s
	limit := row.x + max(0, row.width - pad)
	x := row.x + pad
	show_icon := row.width >= PROFILE_ICON_MIN_WIDTH * s
	show_actions := row.width >= PROFILE_ACTIONS_MIN_WIDTH * s
	show_directory := row.width >= PROFILE_DIRECTORY_MIN_WIDTH * s
	handle_width := 20 * s
	icon_width := show_icon ? 30 * s : 0
	default_width := 44 * s
	hidden_width := 48 * s
	actions_width := show_actions ? 76 * s : 0
	fixed := handle_width + icon_width + default_width + hidden_width + actions_width
	gap_count := 4
	if show_icon {gap_count += 1}
	if show_directory {gap_count += 1}
	if show_actions {gap_count += 1}
	text_room := max(0, limit - x - fixed - f32(gap_count) * gap)
	directory_width := f32(0)
	if show_directory {
		directory_width = clamp(text_room * 0.28, 120 * s, 200 * s)
		if text_room - directory_width - gap < 160 * s {
			show_directory, directory_width = false, 0
		}
	}
	remaining := text_room - (show_directory ? directory_width + gap : 0)
	name_width := clamp(remaining * 0.36, 90 * s, 210 * s)
	command_width := max(0, remaining - name_width)
	if remaining > 0 && command_width < 60 * s {
		name_width = max(0, name_width - (60 * s - command_width))
		command_width = max(0, remaining - name_width)
	}
	if remaining <= 0 {name_width, command_width = 0, 0}
	columns := Profile_Columns {
		directory_shown = show_directory,
		actions_shown   = show_actions,
		icon_shown      = show_icon,
	}
	columns.handle = profile_cell(x, limit, handle_width, row)
	x = columns.handle.x + columns.handle.width + gap
	if show_icon {
		columns.icon = profile_cell(x, limit, icon_width, row)
		x = columns.icon.x + columns.icon.width + gap
	}
	columns.name = profile_cell(x, limit, name_width, row)
	x = columns.name.x + columns.name.width + gap
	columns.command = profile_cell(x, limit, command_width, row)
	x = columns.command.x + columns.command.width + gap
	if show_directory {
		columns.directory = profile_cell(x, limit, directory_width, row)
		x = columns.directory.x + columns.directory.width + gap
	}
	columns.default = profile_cell(x, limit, default_width, row)
	x = columns.default.x + columns.default.width + gap
	columns.hidden = profile_cell(x, limit, hidden_width, row)
	x = columns.hidden.x + columns.hidden.width + gap
	if show_actions {columns.actions = profile_cell(x, limit, actions_width, row)}
	return columns
}

@(private)
profile_cell :: proc(x, limit, width: f32, row: render.Rect) -> render.Rect {
	return {x, row.y, min(width, max(0, limit - x)), row.height}
}

// The clickable cells of one table or detected row. Actions are right-aligned inside their column.
Profile_Parts :: struct {
	handle, icon, name, command, directory: render.Rect,
	radio, toggle:                          render.Rect,
	expand, duplicate, remove:              render.Rect,
	enable, chevron:                        render.Rect,
}

profile_row_parts :: proc(kind: Row_Kind, row: render.Rect, scale: f32) -> Profile_Parts {
	s := scale
	cy := row.y + row.height / 2
	parts := Profile_Parts{}
	switch kind {
	case .Profile:
		columns := profile_columns(row, s)
		parts.handle = columns.handle
		parts.icon = columns.icon
		parts.name = columns.name
		parts.command = columns.command
		parts.directory = columns.directory
		parts.radio = {
			columns.default.x + (columns.default.width - 22 * s) / 2,
			cy - 11 * s,
			22 * s,
			22 * s,
		}
		parts.toggle = {
			columns.hidden.x + (columns.hidden.width - 40 * s) / 2,
			cy - 11 * s,
			40 * s,
			22 * s,
		}
		if columns.actions.width > 0 {
			size := min(24 * s, columns.actions.width / 3)
			gap := max(0, (columns.actions.width - size * 3) / 2)
			x := columns.actions.x
			parts.expand = {x, cy - size / 2, size, size}
			x += size + gap
			parts.duplicate = {x, cy - size / 2, size, size}
			x += size + gap
			parts.remove = {x, cy - size / 2, size, size}
		}
	case .Detected:
		parts.icon = {row.x + 12 * s, cy - 13 * s, 26 * s, 26 * s}
		parts.enable = {row.x + row.width - 12 * s - 64 * s, cy - 15 * s, 64 * s, 30 * s}
		parts.radio = {parts.enable.x - 12 * s - 22 * s, cy - 11 * s, 22 * s, 22 * s}
		name_width := clamp(row.width * 0.24, 100 * s, 180 * s)
		name_room := max(0, parts.radio.x - 12 * s - (parts.icon.x + parts.icon.width + 8 * s))
		name_width = min(name_width, name_room)
		parts.name = {parts.icon.x + parts.icon.width + 8 * s, row.y, name_width, row.height}
		command_x := min(parts.name.x + parts.name.width + 8 * s, parts.radio.x - 8 * s)
		parts.command = {
			command_x,
			row.y,
			max(0, parts.radio.x - 8 * s - command_x),
			row.height,
		}
	case .Detected_Header:
		parts.chevron = {row.x + 12 * s, cy - 11 * s, 22 * s, 22 * s}
	case .Profile_Add, .Text, .Integer, .Number, .Toggle, .Choice, .Color, .Optional_Color,
	     .Shortcut, .Action, .Profile_Icon:
	}
	return parts
}
