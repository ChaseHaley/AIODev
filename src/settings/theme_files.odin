package settings

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

THEME_FILE_MAX_BYTES :: 64 * 1024

@(require_results)
theme_file_parse :: proc(text: string) -> (theme: Custom_Theme, issue: string) {
	if len(text) > THEME_FILE_MAX_BYTES {return {}, "Theme file exceeds 64 KiB."}
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
		switch key {
		case "$schema", "id", "base", "name", "author", "description":
			if _, ok := entry.(json.String); !ok {return {}, "Theme metadata must be strings."}
		case "version":
			if version, ok := entry.(json.Float); !ok || version != 1 {
				return {}, "Expected theme version 1."
			}
		case "colors":
		case:
			return {}, fmt.tprintf("Unknown theme field: %s", key)
		}
	}
	id, id_ok := object["id"].(json.String)
	base, base_ok := object["base"].(json.String)
	version, version_ok := object["version"].(json.Float)
	colors, colors_ok := object["colors"].(json.Object)
	if !id_ok || !theme_id_valid(string(id)) {return {}, "Invalid or reserved theme ID."}
	if !version_ok || version != 1 {return {}, "Expected theme version 1."}
	if !base_ok {return {}, "Expected a built-in base theme."}
	if !colors_ok {return {}, "Expected a colors object."}
	theme.base, base_ok = builtin_parse(string(base))
	if !base_ok {return {}, "Unknown built-in base theme."}
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
	// The caller consumes this temporary ID before the next scratch reset.
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

@(private, require_results)
theme_files_load :: proc(
	s: ^Settings,
	diagnostics: ^[dynamic]Diagnostic,
	directory: string,
) -> runtime.Allocator_Error {
	files, read_error := os.read_directory_by_path(directory, 1024, context.temp_allocator)
	if read_error == .Not_Exist {return nil}
	if read_error != nil {
		return diagnostic_append(diagnostics, 0, directory, "Could not read themes directory.")
	}
	defer os.file_info_slice_delete(files, context.temp_allocator)
	slice.sort_by(files, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	if len(files) == 1024 {
		if err := diagnostic_append(diagnostics, 0, directory, "Only the first 1024 entries were scanned.");
		   err != nil {return err}
	}
	for file in files {
		if file.type != .Regular {continue}
		if !strings.has_suffix(file.name, ".theme.json") {continue}
		path := fmt.tprintf("%s/%s", directory, file.name)
		if file.size > THEME_FILE_MAX_BYTES {
			if err := diagnostic_append(diagnostics, 0, path, "Theme file exceeds 64 KiB.");
			   err != nil {return err}
			continue
		}
		data, error := os.read_entire_file(path, context.temp_allocator)
		if error != nil {
			if err := diagnostic_append(diagnostics, 0, path, "Could not read theme file.");
			   err != nil {return err}
			continue
		}
		theme, issue := theme_file_parse(string(data))
		delete(data, context.temp_allocator)
		if issue != "" {
			if err := diagnostic_append(diagnostics, 0, path, issue); err != nil {return err}
			continue
		}
		if existing := custom_theme_find(s, theme.id); existing != nil {
			if existing.external {
				if err := diagnostic_append(diagnostics, 0, path, "Duplicate theme ID; file ignored.");
				   err != nil {return err}
			}
			continue
		}
		stored, add_error := custom_theme_add(s, theme.id)
		if add_error != nil {return add_error}
		if stored == nil {
			if err := diagnostic_append(diagnostics, 0, path, "Custom theme limit reached.");
			   err != nil {return err}
			continue
		}
		theme.id = stored.id
		stored^ = theme
	}
	return nil
}

@(require_results)
theme_file_text :: proc(s: ^Settings, id: string, allocator := context.allocator) -> (string, bool) {
	if !theme_id_valid(id) {return "", false}
	base := Builtin_Theme{builtin_name(s), s.theme.mode}
	if custom := custom_theme_find(s, s.theme.name); custom != nil {base = custom.base}
	colors := make(map[string]string, context.temp_allocator)
	for info, token in THEME_TOKENS {
		colors[info.key] = theme_color_text(token, s.active_theme.colors[token])
	}
	document := struct {
		schema: string `json:"$schema"`,
		version: int,
		id, base: string,
		colors: map[string]string,
	}{"./theme.schema.json", 1, id, builtin_id(base), colors}
	data, error := json.marshal(document, {pretty = true, sort_maps_by_key = true}, allocator)
	if error != nil {return "", false}
	return string(data), true
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
		if len(id) > PROFILE_ID_MAX_LENGTH {id = fmt.tprintf("export-theme-%d", number)}
		path = fmt.tprintf("%s/%s.theme.json", directory, id)
		file, open_error := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_EXCL)
		if open_error == .Exist {continue}
		if open_error != nil {return "", open_error}
		text, ok := theme_file_text(s, id, context.temp_allocator)
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
