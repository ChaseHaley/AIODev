package commands

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Parses a structured request through the same grammar as the command line. Returned builtin
// strings belong to allocator; runtime fields borrow the original JSON. Use a request allocator.
@(require_results)
parse_fields :: proc(
	registry: ^Registry,
	name, fields: string,
	allocator := context.allocator,
) -> (Invocation, Parse_Error) {
	if name == "" {return {}, {"<command>", "name a command; use aio commands"}}
	command := find(registry, name)
	if command == nil {return {}, {name, "unknown command; use aio commands"}}
	if !utf8.valid_string(fields) {return {}, {"<fields>", "use a UTF-8 JSON object"}}
	// The JSON parser also frees incomplete values through the context allocator.
	context.allocator = allocator
	parser := json.make_parser_from_string(fields, .JSON, true, allocator)
	value, parse_error := json.parse_value(&parser)
	defer json.destroy_value(value, allocator)
	if parse_error == .Out_Of_Memory {return {}, {"<fields>", "not enough memory to read the fields"}}
	object, is_object := value.(json.Object)
	malformed := parse_error != .None || parser.curr_token.kind != .EOF || !is_object
	if malformed || fields_trailing_comma(fields) {
		return {}, {"<fields>", "use one JSON object"}
	}
	if command.runtime {
		result := invocation(command.id, focus = false)
		result.fields = fields
		return result, {}
	}
	return fields_invocation(registry, command, object, allocator)
}

// Odin's strict JSON parser still accepts a comma before a closing brace or bracket; JSON does not.
@(private = "file")
fields_trailing_comma :: proc(fields: string) -> bool {
	tokenizer := json.make_tokenizer(fields, .JSON, true)
	previous := json.Token_Kind.Invalid
	for {
		token, err := json.get_token(&tokenizer)
		if err != .None || token.kind == .EOF {return false}
		if previous == .Comma && (token.kind == .Close_Brace || token.kind == .Close_Bracket) {return true}
		previous = token.kind
	}
}

@(private = "file")
fields_name :: proc(argument: Argument, buffer: []u8) -> string {
	#partial switch argument {
	case .Text: return "text"
	case .File: return "file"
	case .Program: return "command"
	}
	option := argument_grammar[argument].option
	if len(option) < 2 {return ""}
	name := option[2:]
	assert(len(buffer) >= len(name))
	for byte, i in transmute([]u8)name {buffer[i] = byte == '-' ? '_' : byte}
	return string(buffer[:len(name)])
}

@(private = "file")
fields_unknown :: proc(command: ^Command, key: string) -> Parse_Error {
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&builder, "no argument named %s; %s takes pane", key, command.name)
	for argument in Argument {
		if argument not_in command.arguments {continue}
		// File and Text_File share the JSON spelling, with the positional file taking precedence.
		if argument == .Text_File && .File in command.arguments {continue}
		buffer: [128]u8
		fmt.sbprintf(&builder, ", %s", fields_name(argument, buffer[:]))
	}
	return {fmt.tprintf("%s", key), strings.to_string(builder)}
}

@(private = "file")
fields_number :: proc(value: json.Value, buffer: []u8) -> (string, bool) {
	#partial switch number in value {
	case json.Integer: return strconv.write_int(buffer, number, 10), true
	case json.Float:
		// strconv signs every float; JSON's shortest form signs only negatives.
		return strings.trim_prefix(strconv.write_float(buffer, number, 'g', -1, 64), "+"), true
	}
	return "", false
}

@(private = "file")
fields_numeric :: proc(values: []json.Value) -> bool {
	buffer: [64]u8
	for value in values {
		if _, numeric := fields_number(value, buffer[:]); !numeric {return false}
	}
	return true
}

// Joins numeric values with commas into one allocation.
@(private = "file")
fields_join :: proc(values: []json.Value) -> (string, bool) {
	buffer: [64]u8
	size := len(values) - 1
	for value in values {
		number, _ := fields_number(value, buffer[:])
		size += len(number)
	}
	text, err := make([]u8, size)
	if err != nil {return "", false}
	at := 0
	for value, i in values {
		if i > 0 {
			text[at] = ','
			at += 1
		}
		number, _ := fields_number(value, buffer[:])
		at += copy(text[at:], number)
	}
	return string(text), true
}

// Only complete numeric rectangles use the positional x,y,w,h spelling. Every other object keeps
// its JSON structure, as do arrays that contain anything other than numbers.
@(private = "file")
fields_value :: proc(value: json.Value) -> (string, bool) {
	#partial switch item in value {
	case json.String: return string(item), true
	case json.Integer, json.Float:
		single := [1]json.Value{value}
		return fields_join(single[:])
	case json.Array:
		if len(item) > 0 && fields_numeric(item[:]) {return fields_join(item[:])}
	case json.Object:
		if len(item) == 4 {
			rectangle := [4]json.Value{item["x"], item["y"], item["w"], item["h"]}
			if fields_numeric(rectangle[:]) {return fields_join(rectangle[:])}
		}
	}
	return fields_json(value)
}

@(private = "file")
fields_json :: proc(value: json.Value) -> (string, bool) {
	text, err := json.unparse(value, {spec = .JSON})
	return text, err == nil
}

@(private = "file")
fields_invocation :: proc(
	registry: ^Registry,
	command: ^Command,
	object: json.Object,
	allocator: runtime.Allocator,
) -> (result: Invocation, failure: Parse_Error) {
	capacity := 1 + 2 * len(object)
	if array, ok := object["command"].(json.Array); ok {capacity += len(array)}
	args, args_error := make([dynamic]string, 0, capacity, allocator)
	if args_error != nil {return {}, {"<fields>", "not enough memory for the arguments"}}
	defer delete(args)
	owned, owned_error := make([dynamic]string, 0, len(object), allocator)
	if owned_error != nil {return {}, {"<fields>", "not enough memory for the arguments"}}
	defer {
		for text in owned {delete(text, allocator)}
		delete(owned)
	}
	// Error arguments may point into the parsed object or the temporary argument strings below.
	defer if failure.argument != "" {failure.argument = fmt.tprintf("%s", failure.argument)}
	append(&args, command.name)
	program: json.Value
	have_program := false
	for key, value in object {
		if key == "command" {program, have_program = value, true; continue}
		argument: Argument
		option := "--pane"
		if key != "pane" {
			found := false
			for candidate in Argument {
				if candidate not_in command.arguments {continue}
				buffer: [128]u8
				if fields_name(candidate, buffer[:]) != key {continue}
				argument, found = candidate, true
				break
			}
			if !found {return {}, fields_unknown(command, key)}
			option = argument_grammar[argument].option
			if option != "" && argument_grammar[argument].usage == "" {
				enabled, boolean := value.(json.Boolean)
				if !boolean {return {}, {key, "use a boolean for this flag"}}
				if enabled {append(&args, option)}
				continue
			}
		}
		if _, boolean := value.(json.Boolean); boolean {return {}, {key, "use a value, not a boolean"}}
		if key != "pane" {
			#partial switch argument {
			case .Direction, .Directory, .Name, .Profile, .Tab_Name, .Command_File, .Text_File, .File:
				if _, text := value.(json.String); !text {return {}, {key, "use a string for this argument"}}
			}
		}
		text, ok := fields_value(value)
		if !ok {return {}, {key, "not enough memory for the argument"}}
		if _, borrowed := value.(json.String); !borrowed {append(&owned, text)}
		if option != "" {append(&args, option)}
		append(&args, text)
	}
	if have_program {
		append(&args, "--")
		if .Program not_in command.arguments {return parse_invocation(registry, args[:], allocator)}
		#partial switch value in program {
		case json.String:
			if value == "" {return {}, {"command", "name a program"}}
			append(&args, string(value))
		case json.Array:
			for item, i in value {
				text, ok := item.(json.String)
				if !ok {return {}, {"command", "use a string or an array of strings"}}
				if i == 0 && text == "" {return {}, {"command", "name a program"}}
				append(&args, string(text))
			}
		case:
			return {}, {"command", "use a string or an array of strings"}
		}
	}
	result, failure = parse_invocation(registry, args[:], allocator)
	if failure.advice != "" {return {}, failure}
	// Keep only the strings the invocation actually uses, in one caller-owned allocation.
	// New catalogue arguments add Invocation fields in other modules; discover string fields so
	// their values survive the parsed object's destruction without another hand-maintained list.
	string_storage: [size_of(Invocation) / size_of(string)]^string
	count := 0
	for field in reflect.struct_fields_zipped(Invocation) {
		if field.type.id != string || field.name == "program" {continue}
		value := reflect.struct_field_value(result, field)
		string_storage[count] = cast(^string)value.data
		count += 1
	}
	strings_used := string_storage[:count]
	size := 0
	for text in strings_used {size += len(text^)}
	if size == 0 {return result, {}}
	backing, err := make([]u8, size, allocator)
	if err != nil {
		delete(result.program, allocator)
		return {}, {"<fields>", "not enough memory for the invocation"}
	}
	at := 0
	for text in strings_used {
		end := at + len(text^)
		copy(backing[at:end], transmute([]u8)text^)
		text^ = string(backing[at:end])
		at = end
	}
	return result, {}
}
