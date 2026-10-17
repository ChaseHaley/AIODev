package instance

import "base:runtime"
import "core:strings"

APP_NAME :: "AIODev"
USAGE :: "Usage: AIODev [--instance <name>] [--data-dir <dir>] [--no-activate]"

Options :: struct {
	name: string,
	data_dir: string,
	inactive: bool,
}

Error :: enum { None, Out_Of_Memory, System }

Parse_Error :: enum {
	None,
	Unknown_Argument,
	Missing_Value,
	Repeated_Flag,
	Invalid_Name,
	Empty_Data_Dir,
}

@(require_results)
parse :: proc(args: []string) -> (Options, Parse_Error) {
	options: Options
	i := 0
	for i < len(args) {
		switch args[i] {
		case "--instance":
			if options.name != "" { return {}, .Repeated_Flag }
			value, err := flag_value(args, &i)
			if err != .None { return {}, err }
			if len(value) < 1 || len(value) > 32 { return {}, .Invalid_Name }
			for c in transmute([]u8)value {
				if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
				     c >= '0' && c <= '9' || c == '-' || c == '_') {
					return {}, .Invalid_Name
				}
			}
			options.name = value
		case "--data-dir":
			if options.data_dir != "" { return {}, .Repeated_Flag }
			value, err := flag_value(args, &i)
			if err != .None { return {}, err }
			if value == "" { return {}, .Empty_Data_Dir }
			options.data_dir = value
		case "--no-activate":
			if options.inactive { return {}, .Repeated_Flag }
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
app_id :: proc(options: Options, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	if options.name == "" { return strings.clone(APP_NAME, allocator) }
	return strings.concatenate({APP_NAME, ".", options.name}, allocator)
}

@(require_results)
log_file_name :: proc(options: Options, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	if options.name == "" { return strings.clone("aiodev.log", allocator) }
	return strings.concatenate({"aiodev.", options.name, ".log"}, allocator)
}
