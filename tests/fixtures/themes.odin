package fixtures_test

import "aio:settings"
import "base:runtime"
import "core:strconv"
import "core:strings"

// The theme files shipped in themes/, compiled in so tests need no working directory.
SHIPPED_THEMES := #load_directory("../../themes")

// One shipped file's theme; `ok` is false for files that are not themes, such as the schema.
shipped_theme_file :: proc(file: runtime.Load_Directory_File) -> (theme: settings.Theme, ok: bool) {
	if !strings.has_suffix(file.name, ".theme.json") {return}
	issue: string
	theme, issue = settings.theme_from_text(string(file.data))
	return theme, issue == ""
}

shipped_theme :: proc(id: string) -> settings.Theme {
	for file in SHIPPED_THEMES {
		if strings.trim_suffix(file.name, ".theme.json") != id {continue}
		if theme, ok := shipped_theme_file(file); ok {return theme}
	}
	panic("missing shipped theme")
}

// The interface settings at their schema defaults, so a test builds the theme the application builds.
default_interface :: proc() -> settings.Interface_Settings {
	lift, _ := strconv.parse_f64(settings.schema_find("interface.hover_lift").default_value)
	gloss, _ := strconv.parse_f64(settings.schema_find("interface.hover_gloss").default_value)
	return {hover_lift = lift, hover_gloss = gloss}
}
