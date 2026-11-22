package settings

import theme_api "cosmos:theme"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// The record the Neovim plugin follows lives at <data directory>\nvim\current.json.
NEOVIM_RECORD_DIRECTORY :: "nvim"
NEOVIM_RECORD_FILE :: "current.json"
NEOVIM_RECORD_VERSION :: 1
// Gives panes the record's path; it is absent outside AIODev, where the plugin does nothing.
NEOVIM_RECORD_VARIABLE :: "AIODEV_THEME_FILE"

@(private)
RECORD_REPLACE_ATTEMPTS :: 5
@(private)
RECORD_REPLACE_WAIT :: 20 * time.Millisecond

@(private)
RECORD_COLORS :: [?]struct {
	key:   string,
	token: theme_api.Token,
} {
	{"foreground", .Foreground},
	{"background", .Background},
	{"selection", .Selection_Background},
	{"search_foreground", .Search_Foreground},
	{"search_background", .Search_Background},
	{"search_selected_background", .Search_Selected_Background},
	{"surface", .Surface},
	{"muted", .Muted},
	{"faint", .Faint},
	{"accent", .Accent},
	{"success", .Success},
	{"warning", .Warning},
	{"danger", .Danger},
	{"info", .Info},
}

@(private)
hex_text :: proc(c: Color) -> string {return fmt.tprintf("#%02x%02x%02x", c.r, c.g, c.b)}

// The Neovim colorscheme theme `id` uses: its own, or else the nearest one its bases name, so a theme
// customized from a community theme keeps that theme's colorscheme (WORK-529). A theme that names
// `aiodev`, the scheme the plugin generates from the palette, opts out of its bases' colorscheme.
theme_neovim :: proc(s: ^Settings, id: string) -> theme_api.Neovim {
	theme := theme_api.find(s.themes[:], id)
	for depth := 0; theme != nil && depth <= theme_api.BASE_DEPTH; depth += 1 {
		if theme.neovim.colorscheme != "" {return theme.neovim}
		theme = theme.base == "" ? nil : theme_api.find(s.themes[:], theme.base)
	}
	return {}
}

// The record the Neovim plugin reads: the active theme's id and name, whether the shell background is
// light, the Neovim colorscheme it names if any, and the colours a generated colorscheme needs, all
// opaque `#rrggbb`. `generation` counts the records one app run has written.
@(require_results)
neovim_record_text :: proc(s: ^Settings, generation: u64, allocator := context.allocator) -> (string, bool) {
	theme := s.active_theme
	builder, error := strings.builder_make(context.temp_allocator)
	if error != nil {return "", false}
	defer strings.builder_destroy(&builder)
	header := fmt.tprintf(
		"{{\n  \"version\": %d,\n  \"generation\": %d,\n",
		NEOVIM_RECORD_VERSION,
		generation,
	)
	if write_parts(&builder, header) != nil {return "", false}
	if !theme_api.write_json_string(&builder, "  ", "theme", s.theme.name, ",\n") ||
	   !theme_api.write_json_string(&builder, "  ", "name", theme_display_name(s, s.theme.name), ",\n") {
		return "", false
	}
	if write_parts(&builder, "  \"light\": ", theme.terminal_light ? "true" : "false", ",\n") != nil {
		return "", false
	}
	if !theme_api.neovim_write(&builder, theme_neovim(s, s.theme.name)) {return "", false}
	if write_parts(&builder, "  \"colors\": {\n") != nil {return "", false}
	cursor := hex_text(theme_api.cursor(theme))
	if !theme_api.write_json_string(&builder, "    ", "cursor", cursor, ",\n") {return "", false}
	for entry in RECORD_COLORS {
		color := hex_text(theme.colors[entry.token].rgb)
		if !theme_api.write_json_string(&builder, "    ", entry.key, color, ",\n") {
			return "", false
		}
	}
	if write_parts(&builder, "    \"palette\": [") != nil {return "", false}
	for i in 0 ..< 16 {
		token := theme_api.Token(int(theme_api.Token.Palette_0) + i)
		if write_parts(&builder, i == 0 ? "" : ", ", `"`, hex_text(theme.colors[token].rgb), `"`) != nil {
			return "", false
		}
	}
	if write_parts(&builder, "]\n  }\n}\n") != nil {return "", false}
	text, clone_error := strings.clone(strings.to_string(builder), allocator)
	return text, clone_error == nil
}

// The path of the record under an instance's data directory; empty when there is none.
@(require_results)
neovim_record_path :: proc(data_directory: string, allocator := context.allocator) -> string {
	if data_directory == "" {return ""}
	return filepath.join({data_directory, NEOVIM_RECORD_DIRECTORY, NEOVIM_RECORD_FILE}, allocator) or_else ""
}

// Replaces the record at `path` with `text`. The text goes to a temporary file beside it, which then
// renames over the record, so a watcher never reads half a record. The rename retries while a reader
// holds the record open.
@(require_results)
neovim_record_write :: proc(path, text: string) -> os.Error {
	os.mkdir_all(filepath.dir(path)) or_return
	temp := fmt.tprintf("%s.tmp", path)
	if error := os.write_entire_file(temp, text); error != nil {
		_ = os.remove(temp)
		return error
	}
	error: os.Error
	for attempt in 1 ..= RECORD_REPLACE_ATTEMPTS {
		error = os.rename(temp, path)
		if error == nil {return nil}
		if error != io.Error.Permission_Denied || attempt == RECORD_REPLACE_ATTEMPTS {break}
		time.sleep(RECORD_REPLACE_WAIT)
	}
	_ = os.remove(temp)
	return error
}
