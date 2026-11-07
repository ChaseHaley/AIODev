package instance

import "base:runtime"
import "core:path/filepath"
import "core:strings"

APP_NAME :: "AIODev"
// The app's command-line flags; launchers build command lines from the same spellings.
FLAG_INSTANCE :: "--instance"
FLAG_DATA_DIR :: "--data-dir"
FLAG_NO_ACTIVATE :: "--no-activate"
USAGE ::
	"Usage: " + APP_NAME + " [" + FLAG_INSTANCE + " <name>] [" + FLAG_DATA_DIR + " <dir>] [" +
	FLAG_NO_ACTIVATE + "]"
// A name has 1..MAX_NAME_LENGTH ASCII letters, digits, hyphens or underscores.
MAX_NAME_LENGTH :: 32

// Files an instance keeps in its data directory.
SETTINGS_FILE :: "settings.ini"
LOGS_DIRECTORY :: "logs"
CAPTURES_DIRECTORY :: "captures"

Options :: struct {
	name:     string,
	data_dir: string,
	inactive: bool,
}

Error :: enum {
	None,
	Out_Of_Memory,
	System,
}

Parse_Error :: enum {
	None,
	Unknown_Argument,
	Missing_Value,
	Repeated_Flag,
	Invalid_Name,
	Empty_Data_Dir,
}

@(require_results)
valid_name :: proc(name: string) -> bool {
	if len(name) < 1 || len(name) > MAX_NAME_LENGTH {return false}
	for c in transmute([]u8)name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

@(require_results)
parse :: proc(args: []string) -> (Options, Parse_Error) {
	options: Options
	i := 0
	for i < len(args) {
		switch args[i] {
		case FLAG_INSTANCE:
			if options.name != "" {return {}, .Repeated_Flag}
			value, err := flag_value(args, &i)
			if err != .None {return {}, err}
			if !valid_name(value) {return {}, .Invalid_Name}
			options.name = value
		case FLAG_DATA_DIR:
			if options.data_dir != "" {return {}, .Repeated_Flag}
			value, err := flag_value(args, &i)
			if err != .None {return {}, err}
			if value == "" {return {}, .Empty_Data_Dir}
			options.data_dir = value
		case FLAG_NO_ACTIVATE:
			if options.inactive {return {}, .Repeated_Flag}
			options.inactive = true
		case:
			return {}, .Unknown_Argument
		}
		i += 1
	}
	return options, .None
}

@(private, require_results)
flag_value :: proc(args: []string, index: ^int) -> (string, Parse_Error) {
	index^ += 1
	if index^ == len(args) || strings.has_prefix(args[index^], "--") {
		return "", .Missing_Value
	}
	return args[index^], .None
}

@(require_results)
app_id :: proc(
	options: Options,
	allocator: runtime.Allocator,
) -> (
	string,
	runtime.Allocator_Error,
) {
	if options.name == "" {return strings.clone(APP_NAME, allocator)}
	return strings.concatenate({APP_NAME, ".", options.name}, allocator)
}

// Where an instance keeps its files. An empty field could not be resolved.
Paths :: struct {
	// Machine-local state: --data-dir, else %LOCALAPPDATA%\AIODev.
	local:    string,
	logs:     string,
	log:      string,
	layout:   string,
	// <--data-dir>\settings.ini, else the roaming AIODev\settings.ini, which named instances share
	// with the default instance.
	settings: string,
	// Evidence captures; only an instance with --data-dir has them.
	captures: string,
}

// Lays out the instance's files: under --data-dir when set, else machine-local files under
// local_app_data\AIODev and settings under roaming_app_data\AIODev. An empty root leaves the fields
// under it empty.
@(require_results)
paths_resolve :: proc(
	options: Options,
	local_app_data, roaming_app_data: string,
	allocator := context.allocator,
) -> (
	p: Paths,
	err: runtime.Allocator_Error,
) {
	defer if err != nil {paths_destroy(&p, allocator)}
	if options.data_dir != "" {
		p.local = strings.clone(options.data_dir, allocator) or_return
		p.settings = filepath.join({options.data_dir, SETTINGS_FILE}, allocator) or_return
		p.captures = filepath.join({options.data_dir, CAPTURES_DIRECTORY}, allocator) or_return
	} else {
		if local_app_data != "" {
			p.local = filepath.join({local_app_data, APP_NAME}, allocator) or_return
		}
		if roaming_app_data != "" {
			p.settings = strings.concatenate(
				{roaming_app_data, `\`, APP_NAME, `\`, SETTINGS_FILE},
				allocator,
			) or_return
		}
	}
	if p.local == "" {return p, nil}
	p.logs = filepath.join({p.local, LOGS_DIRECTORY}, allocator) or_return
	suffix := options.name == "" ? "" : "."
	log_name := strings.concatenate({"aiodev", suffix, options.name, ".log"}, allocator) or_return
	defer delete(log_name, allocator)
	p.log = filepath.join({p.logs, log_name}, allocator) or_return
	layout_name := strings.concatenate({"layout", suffix, options.name, ".json"}, allocator) or_return
	defer delete(layout_name, allocator)
	p.layout = filepath.join({p.local, layout_name}, allocator) or_return
	return p, nil
}

paths_destroy :: proc(p: ^Paths, allocator := context.allocator) {
	delete(p.local, allocator)
	delete(p.logs, allocator)
	delete(p.log, allocator)
	delete(p.layout, allocator)
	delete(p.settings, allocator)
	delete(p.captures, allocator)
	p^ = {}
}
