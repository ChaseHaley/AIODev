package settings

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

THEME_FILE_MAX_BYTES :: 64 * 1024
@(private)
THEME_FILE_SIZE_NOTICE :: "Theme file exceeds 64 KiB."

// The top-level fields of a theme file, in the order the schema lists them.
Theme_Field :: enum {
	Schema,
	Version,
	Id,
	Name,
	Author,
	Description,
	Base,
	Colors,
}

Theme_Field_Kind :: enum {
	String,
	// The format version, which must be 1.
	Version,
	// The colors object, checked token by token.
	Colors,
}

Theme_Field_Info :: struct {
	key:      string,
	kind:     Theme_Field_Kind,
	required: bool,
}

// What theme_file_parse accepts and theme_schema_text describes at the top level of a theme file.
@(rodata)
THEME_FIELDS := [Theme_Field]Theme_Field_Info {
	.Schema      = {key = "$schema", kind = .String},
	.Version     = {key = "version", kind = .Version, required = true},
	.Id          = {key = "id", kind = .String, required = true},
	.Name        = {key = "name", kind = .String},
	.Author      = {key = "author", kind = .String},
	.Description = {key = "description", kind = .String},
	.Base        = {key = "base", kind = .String},
	.Colors      = {key = "colors", kind = .Colors, required = true},
}

@(private)
theme_field_find :: proc(key: string) -> (Theme_Field_Info, bool) {
	for info in THEME_FIELDS {if info.key == key {return info, true}}
	return {}, false
}

@(require_results)
theme_file_parse :: proc(text: string) -> (theme: Custom_Theme, issue: string) {
	if len(text) > THEME_FILE_MAX_BYTES {return {}, THEME_FILE_SIZE_NOTICE}
	lexer := json.make_tokenizer(text, .JSON)
	depth, completed := 0, false
	previous := json.Token_Kind.Invalid
	for {
		token, token_error := json.get_token(&lexer)
		if token.kind == .EOF {break}
		if token_error != .None {return {}, "Invalid JSON theme file."}
		if completed {return {}, "Unexpected content after theme object."}
		if token.kind == .Open_Brace || token.kind == .Open_Bracket {depth += 1}
		if depth > 4 {return {}, "Theme JSON nesting is too deep."}
		if token.kind == .Close_Brace || token.kind == .Close_Bracket {
			if previous == .Comma {return {}, "Trailing commas are not valid JSON."}
			depth -= 1
			if depth == 0 {completed = true}
		}
		if token.kind == .String && token.text == `""` &&
		   (previous == .Open_Brace || previous == .Comma) {return {}, "Empty theme keys are invalid."}
		previous = token.kind
	}
	value, error := json.parse(text, spec = .JSON, allocator = context.temp_allocator)
	if error != .None {return {}, "Invalid JSON theme file."}
	defer json.destroy_value(value, context.temp_allocator)
	object, object_ok := value.(json.Object)
	if !object_ok {return {}, "Expected a theme object."}
	for key, entry in object {
		info, known := theme_field_find(key)
		if !known {return {}, fmt.tprintf("Unknown theme field: %s", key)}
		switch info.kind {
		case .String:
			if _, ok := entry.(json.String); !ok {return {}, "Theme metadata must be strings."}
		case .Version:
			if version, ok := entry.(json.Float); !ok || version != 1 {
				return {}, "Expected theme version 1."
			}
		case .Colors:
		}
	}
	id, id_ok := object["id"].(json.String)
	version, version_ok := object["version"].(json.Float)
	colors, colors_ok := object["colors"].(json.Object)
	if !id_ok || !theme_id_valid(string(id)) {return {}, "Invalid theme ID."}
	if !version_ok || version != 1 {return {}, "Expected theme version 1."}
	if !colors_ok {return {}, "Expected a colors object."}
	if base, has_base := object["base"].(json.String); has_base {
		if !theme_id_valid(string(base)) {return {}, "Invalid base theme ID."}
		// Temporary like the ID below.
		cloned, clone_error := strings.clone(theme_legacy_base(string(base)), context.temp_allocator)
		if clone_error != nil {return {}, "Could not allocate base theme ID."}
		theme.base = cloned
	}
	if name, has_name := object["name"].(json.String); has_name && name != "" {
		cloned, clone_error := strings.clone(string(name), context.temp_allocator)
		if clone_error != nil {return {}, "Could not allocate theme name."}
		theme.name = cloned
	}
	for key, entry in colors {
		token, known := token_find(key)
		if !known {return {}, fmt.tprintf("Unknown theme color: %s", key)}
		color_text, ok := entry.(json.String)
		if !ok {return {}, fmt.tprintf("Expected a color string for %s", key)}
		color, valid := theme_color_parse(token, string(color_text), .Strict)
		if !valid {return {}, fmt.tprintf("Invalid theme color: %s", key)}
		theme.colors[token] = color
		theme.overrides += {token}
	}
	// The caller consumes these temporary IDs before the next scratch reset.
	cloned, clone_error := strings.clone(string(id), context.temp_allocator)
	if clone_error != nil {return {}, "Could not allocate theme ID."}
	theme.id = cloned
	theme.base_set, theme.external = true, true
	return
}

@(require_results)
theme_directory :: proc() -> string {
	path, error := os.get_executable_directory(context.temp_allocator)
	if error != nil {return ""}
	return fmt.tprintf("%s/themes", path)
}

// A complete theme file: every color of `theme` in token order, so it needs no base. Empty
// metadata is left out.
@(require_results)
theme_file_text :: proc(
	id: string,
	theme: Theme,
	name := "",
	description := "",
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	if !theme_id_valid(id) {return "", false}
	// A value that cannot be quoted fails the file rather than writing an empty string in its place.
	field :: proc(b: ^strings.Builder, indent, key, value, separator: string) -> bool {
		quoted_key, key_error := json.marshal(key, allocator = context.temp_allocator)
		quoted_value, value_error := json.marshal(value, allocator = context.temp_allocator)
		if key_error != nil || value_error != nil {return false}
		return write_parts(b, indent, string(quoted_key), ": ", string(quoted_value), separator) == nil
	}
	builder, error := strings.builder_make(context.temp_allocator)
	if error != nil {return "", false}
	defer strings.builder_destroy(&builder)
	if write_parts(&builder, "{\n  \"$schema\": \"./theme.schema.json\",\n  \"version\": 1,\n") != nil ||
	   !field(&builder, "  ", "id", id, ",\n") {return "", false}
	if name != "" && !field(&builder, "  ", "name", name, ",\n") {return "", false}
	if description != "" && !field(&builder, "  ", "description", description, ",\n") {return "", false}
	if write_parts(&builder, "  \"colors\": {\n") != nil {return "", false}
	for info, token in THEME_TOKENS {
		separator := token == max(Theme_Token) ? "\n" : ",\n"
		value := theme_color_text(token, theme.colors[token])
		if !field(&builder, "    ", info.key, value, separator) {return "", false}
	}
	if write_parts(&builder, "  }\n}\n") != nil {return "", false}
	text, clone_error := strings.clone(strings.to_string(builder), allocator)
	return text, clone_error == nil
}

// Exclusive creation never replaces another creator's file, including repeated exports.
@(require_results)
theme_export :: proc(s: ^Settings, directory: string) -> (path: string, error: os.Error) {
	if directory == "" {return "", os.General_Error.Invalid_File}
	if error = os.mkdir_all(directory); error != nil {return}
	schema, schema_ok := theme_schema_text(context.temp_allocator)
	if !schema_ok {return "", os.General_Error.Invalid_File}
	schema_path := fmt.tprintf("%s/theme.schema.json", directory)
	schema_file, schema_error := os.open(schema_path, os.O_WRONLY | os.O_CREATE | os.O_EXCL)
	if schema_error == nil {
		n, write_error := os.write(schema_file, transmute([]u8)schema)
		close_error := os.close(schema_file)
		if write_error != nil || close_error != nil || n != len(schema) {
			_ = os.remove(schema_path)
			return "", os.General_Error.Invalid_File
		}
	} else if schema_error != .Exist {return "", schema_error}
	for number := 1; number <= 1000; number += 1 {
		id := fmt.tprintf("export-%s-%d", s.theme.name, number)
		if len(id) > THEME_ID_MAX_LENGTH {id = fmt.tprintf("export-theme-%d", number)}
		path = fmt.tprintf("%s/%s.theme.json", directory, id)
		file, open_error := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_EXCL)
		if open_error == .Exist {continue}
		if open_error != nil {return "", open_error}
		name := theme_display_name(s, s.theme.name)
		text, ok := theme_file_text(id, s.active_theme, name, allocator = context.temp_allocator)
		if !ok {
			_ = os.close(file)
			_ = os.remove(path)
			return "", os.General_Error.Invalid_File
		}
		n, write_error := os.write(file, transmute([]u8)text)
		sync_error := os.sync(file)
		close_error := os.close(file)
		if write_error != nil || sync_error != nil || close_error != nil || n != len(text) {
			_ = os.remove(path)
			return "", os.General_Error.Invalid_File
		}
		return path, nil
	}
	return "", os.General_Error.Exist
}
