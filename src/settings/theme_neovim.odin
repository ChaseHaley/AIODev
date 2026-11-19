package settings

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

NEOVIM_PLUGIN_PATTERN :: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"
NEOVIM_COLORSCHEME_PATTERN :: "^[A-Za-z0-9_.-]+$"
NEOVIM_PLUGIN_MAX_LENGTH :: 100
NEOVIM_COLORSCHEME_MAX_LENGTH :: 64

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

Neovim_Background :: enum {
	Auto,
	Dark,
	Light,
}

// The Neovim colorscheme a theme file names, as data: the plugin repository that provides it, the
// colorscheme to apply, and the 'background' it needs when that is not simply the theme's own. A
// theme without one has an empty colorscheme. Its strings are owned by whoever holds the theme.
Neovim_Theme :: struct {
	plugin, colorscheme: string,
	background:          Neovim_Background,
}

@(private)
neovim_name_byte :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
		c == '_' || c == '.' || c == '-'
}

neovim_colorscheme_valid :: proc(text: string) -> bool {
	if len(text) == 0 || len(text) > NEOVIM_COLORSCHEME_MAX_LENGTH {return false}
	for i in 0 ..< len(text) {
		if !neovim_name_byte(text[i]) {return false}
	}
	return true
}

// `owner/repository`, the form a plugin manager takes.
neovim_plugin_valid :: proc(text: string) -> bool {
	if len(text) == 0 || len(text) > NEOVIM_PLUGIN_MAX_LENGTH {return false}
	slash := strings.index_byte(text, '/')
	if slash <= 0 || slash == len(text) - 1 {return false}
	for i in 0 ..< len(text) {
		if i != slash && !neovim_name_byte(text[i]) {return false}
	}
	return true
}

// Reads the `neovim` object of a theme file. `n`'s strings and `issue` are temporary.
@(private, require_results)
neovim_theme_parse :: proc(value: json.Value) -> (n: Neovim_Theme, issue: string) {
	object, is_object := value.(json.Object)
	if !is_object {return {}, "Expected a neovim object."}
	for key in object {
		if key != "plugin" && key != "colorscheme" && key != "background" {
			return {}, fmt.tprintf("Unknown neovim field: %s", key)
		}
	}
	plugin, plugin_ok := object["plugin"].(json.String)
	if !plugin_ok || !neovim_plugin_valid(string(plugin)) {
		return {}, "Invalid neovim plugin; use owner/repository."
	}
	colorscheme, colorscheme_ok := object["colorscheme"].(json.String)
	if !colorscheme_ok || !neovim_colorscheme_valid(string(colorscheme)) {
		return {}, "Invalid neovim colorscheme."
	}
	if background, has_background := object["background"]; has_background {
		text, text_ok := background.(json.String)
		switch {
		case text_ok && text == "dark":
			n.background = .Dark
		case text_ok && text == "light":
			n.background = .Light
		case:
			return {}, "Neovim background must be dark or light."
		}
	}
	cloned_plugin, plugin_error := strings.clone(string(plugin), context.temp_allocator)
	cloned_colorscheme, colorscheme_error := strings.clone(string(colorscheme), context.temp_allocator)
	if plugin_error != nil || colorscheme_error != nil {return {}, "Could not allocate neovim theme."}
	n.plugin, n.colorscheme = cloned_plugin, cloned_colorscheme
	return
}

@(private, require_results)
neovim_theme_clone :: proc(
	n: Neovim_Theme,
	allocator: runtime.Allocator,
) -> (
	c: Neovim_Theme,
	err: runtime.Allocator_Error,
) {
	c.background = n.background
	c.plugin = strings.clone(n.plugin, allocator) or_return
	c.colorscheme, err = strings.clone(n.colorscheme, allocator)
	if err != nil {delete(c.plugin, allocator)}
	return
}

@(private)
neovim_theme_destroy :: proc(n: Neovim_Theme, allocator: runtime.Allocator) {
	delete(n.plugin, allocator)
	delete(n.colorscheme, allocator)
}

@(private)
neovim_background_text :: proc(b: Neovim_Background) -> string {
	switch b {
	case .Auto:
		return ""
	case .Dark:
		return "dark"
	case .Light:
		return "light"
	}
	return ""
}

// Writes `"key": "value"` with the value quoted as JSON; false when it cannot be quoted.
@(private, require_results)
write_json_string :: proc(b: ^strings.Builder, indent, key, value, separator: string) -> bool {
	quoted_key, key_error := json.marshal(key, allocator = context.temp_allocator)
	quoted_value, value_error := json.marshal(value, allocator = context.temp_allocator)
	if key_error != nil || value_error != nil {return false}
	return write_parts(b, indent, string(quoted_key), ": ", string(quoted_value), separator) == nil
}

// The neovim object as a theme file writes it, at the top level: a trailing comma follows.
@(private, require_results)
write_neovim_theme :: proc(b: ^strings.Builder, n: Neovim_Theme) -> bool {
	if n.colorscheme == "" {return true}
	background := neovim_background_text(n.background)
	if write_parts(b, "  \"neovim\": {\n") != nil {return false}
	if !write_json_string(b, "    ", "plugin", n.plugin, ",\n") {return false}
	if !write_json_string(b, "    ", "colorscheme", n.colorscheme, background == "" ? "\n" : ",\n") {
		return false
	}
	if background != "" && !write_json_string(b, "    ", "background", background, "\n") {return false}
	return write_parts(b, "  },\n") == nil
}

@(private)
RECORD_COLORS :: [?]struct {
	key:   string,
	token: Theme_Token,
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
	if !write_json_string(&builder, "  ", "theme", s.theme.name, ",\n") ||
	   !write_json_string(&builder, "  ", "name", theme_display_name(s, s.theme.name), ",\n") {
		return "", false
	}
	if write_parts(&builder, "  \"light\": ", theme.terminal_light ? "true" : "false", ",\n") != nil {
		return "", false
	}
	if custom := custom_theme_find(s, s.theme.name); custom != nil {
		if !write_neovim_theme(&builder, custom.neovim) {return "", false}
	}
	if write_parts(&builder, "  \"colors\": {\n") != nil {return "", false}
	if !write_json_string(&builder, "    ", "cursor", hex_text(theme_cursor(theme)), ",\n") {return "", false}
	for entry in RECORD_COLORS {
		if !write_json_string(&builder, "    ", entry.key, hex_text(theme.colors[entry.token].rgb), ",\n") {
			return "", false
		}
	}
	if write_parts(&builder, "    \"palette\": [") != nil {return "", false}
	for i in 0 ..< 16 {
		token := Theme_Token(int(Theme_Token.Palette_0) + i)
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
