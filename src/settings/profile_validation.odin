package settings

import "core:fmt"
import "core:strings"

// The fields of one profile, each a profile.ID.<name> key.
Profile_Field :: enum {
	Name,
	Command,
	Directory,
	Icon,
	Hidden,
}

@(rodata)
profile_field_names := [Profile_Field]string {
	.Name      = "name",
	.Command   = "command",
	.Directory = "directory",
	.Icon      = "icon",
	.Hidden    = "hidden",
}

profile_field_from_name :: proc(name: string) -> (Profile_Field, bool) {
	for candidate, field in profile_field_names {
		if candidate == name {return field, true}
	}
	return {}, false
}

// "profile.ID.field". Temporary.
profile_field_key :: proc(id: string, field: Profile_Field) -> string {
	return fmt.tprintf("%s%s.%s", PROFILE_PREFIX, id, profile_field_names[field])
}

// The surface that checks a profile value. Each keeps its own admission and wording: the file
// accepts one pair of quotes and reports lowercase diagnostics, Settings fields and edits use
// sentences, and the table's row note names a missing command more briefly.
Profile_Validation_Context :: enum {
	File,
	Interactive_Field,
	Table_Note,
}

// In order of precedence: a row note reports the first among a profile's name and command.
// Command_Missing comes from the caller's executable lookup, as validation does no filesystem work.
Profile_Problem :: enum {
	None,
	Invalid_Text,
	Invalid_Boolean,
	Empty_Name,
	Empty_Command,
	Name_Taken,
	Command_Missing,
}

// Checks one field value. A File value may carry one pair of double quotes, which `text` drops;
// otherwise `text` is `value`. Hidden must be exactly true or false. Name uniqueness is checked
// only when `profiles` is given, in the namespace of profile `id`.
profile_field_check :: proc(
	field: Profile_Field,
	value: string,
	ctx: Profile_Validation_Context,
	profiles: ^Profiles = nil,
	id := "",
) -> (
	text: string,
	issue: Profile_Problem,
) {
	if field == .Hidden {
		if value != "true" && value != "false" {return "", .Invalid_Boolean}
		return value, .None
	}
	text = value
	if ctx == .File {
		decode_issue: string
		text, decode_issue = text_value_decode(value)
		if decode_issue != "" {return "", .Invalid_Text}
	} else if !text_valid(value) {
		return "", .Invalid_Text
	}
	empty := strings.trim_space(text) == ""
	#partial switch field {
	case .Name:
		if empty {return "", .Empty_Name}
		if profiles != nil && profile_name_taken(profiles, id, text) {return "", .Name_Taken}
	case .Command:
		if empty {return "", .Empty_Command}
	}
	return text, .None
}

// The first problem among a resolved profile's name and command, as its table row notes it.
profile_check :: proc(profiles: ^Profiles, profile: ^Profile) -> Profile_Problem {
	_, issue := profile_field_check(.Name, profile.name, .Table_Note, profiles, profile.id)
	_, command_issue := profile_field_check(.Command, profile.command, .Table_Note)
	if command_issue != .None && (issue == .None || command_issue < issue) {issue = command_issue}
	return issue
}

// The message for `issue` on `ctx`'s surface; `value` is the value that was checked. Temporary.
profile_problem_text :: proc(
	issue: Profile_Problem,
	ctx: Profile_Validation_Context,
	value: string,
) -> string {
	file := ctx == .File
	switch issue {
	case .None:
	case .Invalid_Text:
		if file {
			_, decode_issue := text_value_decode(value)
			return decode_issue
		}
		return "Expected UTF-8 text without NUL bytes."
	case .Invalid_Boolean:
		if !file {return "Expected true or false."}
		message, message_error := strings.concatenate(
			{"invalid boolean \"", value, "\", expected true or false"},
			context.temp_allocator,
		)
		return message_error == nil ? message : "expected true or false"
	case .Empty_Name:
		return file ? "profile name cannot be empty" : "A profile needs a name."
	case .Empty_Command:
		return file ? "profile command line cannot be empty" : "A profile needs a command line."
	case .Name_Taken:
		return "Another profile uses this name."
	case .Command_Missing:
		executable := shell_executable(value)
		if ctx == .Table_Note {return fmt.tprintf("Command not found: %s.", executable)}
		return fmt.tprintf(
			"Command not found: %s. Check the path, or leave the executable on PATH.",
			executable,
		)
	}
	return ""
}

// Whether another profile in `id`'s namespace uses `name`, ignoring surrounding space and case.
// Detected-only profiles share a namespace separate from explicit ones; an unknown ID is a new
// explicit profile. `name` is borrowed.
profile_name_taken :: proc(profiles: ^Profiles, id, name: string) -> bool {
	trimmed := strings.trim_space(name)
	if trimmed == "" {return false}
	detected := false
	if profile := profile_find(profiles, id); profile != nil {detected = profile.detected}
	for &other in profiles.items {
		if other.id == id || other.detected != detected {continue}
		if strings.equal_fold(strings.trim_space(other.name), trimmed) {return true}
	}
	return false
}
