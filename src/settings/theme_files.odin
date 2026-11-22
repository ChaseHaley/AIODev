package settings

import "cosmos:theme"
import "core:fmt"
import "core:os"

// Exclusive creation never replaces another creator's file, including repeated exports.
@(require_results)
theme_export :: proc(s: ^Settings, directory: string) -> (path: string, error: os.Error) {
	if directory == "" {return "", os.General_Error.Invalid_File}
	if error = os.mkdir_all(directory); error != nil {return}
	schema, schema_ok := theme.schema_text(context.temp_allocator)
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
		if len(id) > theme.ID_MAX_LENGTH {id = fmt.tprintf("export-theme-%d", number)}
		path = fmt.tprintf("%s/%s.theme.json", directory, id)
		file, open_error := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_EXCL)
		if open_error == .Exist {continue}
		if open_error != nil {return "", open_error}
		name := theme_display_name(s, s.theme.name)
		neovim := theme_neovim(s, s.theme.name)
		text, ok := theme.file_text(
			id,
			s.active_theme,
			name,
			neovim = neovim,
			allocator = context.temp_allocator,
		)
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
