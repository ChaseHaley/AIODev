package settings_test

import "aio:settings"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import theme_api "cosmos:theme"

NEOVIM_FIXTURE :: `{"version":1,"id":"vim","neovim":{"plugin":"folke/tokyonight.nvim","colorscheme":"tokyonight-moon","background":"dark"},"colors":{}}`

@(private)
json_text :: proc(value: json.Value) -> string {
	text, _ := value.(json.String)
	return string(text)
}

@(private)
json_number :: proc(value: json.Value) -> f64 {
	number, _ := value.(json.Float)
	return f64(number)
}

@(private)
json_flag :: proc(value: json.Value) -> bool {
	flag, _ := value.(json.Boolean)
	return bool(flag)
}

@(test)
neovim_object_parses_and_validates :: proc(t: ^testing.T) {
	theme, issue := theme_api.file_parse(NEOVIM_FIXTURE)
	testing.expect_value(t, issue, "")
	testing.expect_value(t, theme.neovim.plugin, "folke/tokyonight.nvim")
	testing.expect_value(t, theme.neovim.colorscheme, "tokyonight-moon")
	testing.expect_value(t, theme.neovim.background, theme_api.Neovim_Background.Dark)
	bare, bare_issue := theme_api.file_parse(
		fixture_replace(NEOVIM_FIXTURE, `,"background":"dark"`, ``),
	)
	testing.expect_value(t, bare_issue, "")
	testing.expect_value(t, bare.neovim.background, theme_api.Neovim_Background.Auto)
	plain, plain_issue := theme_api.file_parse(`{"version":1,"id":"plain","colors":{}}`)
	testing.expect_value(t, plain_issue, "")
	testing.expect_value(t, plain.neovim, theme_api.Neovim{})
	// The plugin only documents where the colorscheme comes from, so a theme may leave it out.
	unnamed, unnamed_issue := theme_api.file_parse(
		fixture_replace(NEOVIM_FIXTURE, `"plugin":"folke/tokyonight.nvim",`, ``),
	)
	testing.expect_value(t, unnamed_issue, "")
	testing.expect_value(t, unnamed.neovim, theme_api.Neovim{"", "tokyonight-moon", .Dark})
	for invalid in ([?]string {
		fixture_replace(NEOVIM_FIXTURE, `"folke/tokyonight.nvim"`, `"tokyonight"`),
		fixture_replace(NEOVIM_FIXTURE, `"folke/tokyonight.nvim"`, `"a/b/c"`),
		fixture_replace(NEOVIM_FIXTURE, `"folke/tokyonight.nvim"`, `"/b"`),
		fixture_replace(NEOVIM_FIXTURE, `"folke/tokyonight.nvim"`, `"a/b|c"`),
		fixture_replace(NEOVIM_FIXTURE, `"folke/tokyonight.nvim"`, `1`),
		fixture_replace(NEOVIM_FIXTURE, `"tokyonight-moon"`, `"two words"`),
		fixture_replace(NEOVIM_FIXTURE, `"tokyonight-moon"`, `"a|b"`),
		fixture_replace(NEOVIM_FIXTURE, `"tokyonight-moon"`, `""`),
		fixture_replace(NEOVIM_FIXTURE, `"dark"`, `"grey"`),
		fixture_replace(NEOVIM_FIXTURE, `"background":"dark"`, `"background":"dark","lua":"os.exit()"`),
		fixture_replace(NEOVIM_FIXTURE, `{"plugin"`, `[{"plugin"`),
		`{"version":1,"id":"vim","neovim":"tokyonight","colors":{}}`,
	}) {
		_, problem := theme_api.file_parse(invalid)
		testing.expect(t, problem != "", invalid)
	}
}

@(test)
neovim_object_roundtrips_through_a_theme_file :: proc(t: ^testing.T) {
	base := theme_api.default()
	named := theme_api.Neovim{"owner/repo.nvim", "scheme-1", .Light}
	text, ok := theme_api.file_text("rt", base, neovim = named)
	testing.expect(t, ok)
	defer delete(text)
	theme, issue := theme_api.file_parse(text)
	testing.expect_value(t, issue, "")
	testing.expect_value(t, theme.neovim, named)
	testing.expect_value(t, theme_api.resolve(nil, &theme), base)
	bare, bare_ok := theme_api.file_text("rt", base)
	testing.expect(t, bare_ok)
	defer delete(bare)
	testing.expect(t, !strings.contains(bare, `"neovim"`))
}

// Plugin and colorscheme per bundled theme, and none for the AIODev originals.
BUNDLED_NEOVIM :: [?]struct {
	id, plugin, colorscheme: string,
	background:              theme_api.Neovim_Background,
} {
	{"catppuccin-latte", "catppuccin/nvim", "catppuccin-latte", .Auto},
	{"catppuccin-frappe", "catppuccin/nvim", "catppuccin-frappe", .Auto},
	{"catppuccin-macchiato", "catppuccin/nvim", "catppuccin-macchiato", .Auto},
	{"catppuccin-mocha", "catppuccin/nvim", "catppuccin-mocha", .Auto},
	{"tokyonight-day", "folke/tokyonight.nvim", "tokyonight-day", .Auto},
	{"tokyonight-moon", "folke/tokyonight.nvim", "tokyonight-moon", .Auto},
	{"tokyonight-night", "folke/tokyonight.nvim", "tokyonight-night", .Auto},
	{"tokyonight-storm", "folke/tokyonight.nvim", "tokyonight-storm", .Auto},
	{"gruvbox-dark", "ellisonleao/gruvbox.nvim", "gruvbox", .Dark},
	{"gruvbox-light", "ellisonleao/gruvbox.nvim", "gruvbox", .Light},
	{"dracula", "Mofiqul/dracula.nvim", "dracula", .Auto},
	{"one-dark", "navarasu/onedark.nvim", "onedark", .Auto},
	{"nord", "gbprod/nord.nvim", "nord", .Auto},
	{"palenight", "drewtempelmeyer/palenight.vim", "palenight", .Auto},
}

@(test)
bundled_themes_name_their_neovim_colorschemes :: proc(t: ^testing.T) {
	s, d, error := parse_themes("", THEMES)
	testing.expect_value(t, error, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, len(d), 0)
	for expected in BUNDLED_NEOVIM {
		theme := theme_api.find(s.themes[:], expected.id)
		if !testing.expect(t, theme != nil, expected.id) {continue}
		testing.expect_value(t, theme.neovim.plugin, expected.plugin)
		testing.expect_value(t, theme.neovim.colorscheme, expected.colorscheme)
		testing.expect_value(t, theme.neovim.background, expected.background)
	}
	for id in ([?]string{"studio-dark", "studio-light", "tide-dark", "tide-light", "ember-dark", "ember-light"}) {
		theme := theme_api.find(s.themes[:], id)
		if !testing.expect(t, theme != nil, id) {continue}
		testing.expect_value(t, theme.neovim, theme_api.Neovim{})
	}
}

@(test)
theme_export_keeps_the_neovim_object :: proc(t: ^testing.T) {
	directory, temp_error := os.mkdir_temp("tests/settings", "theme-neovim-", context.allocator)
	if !testing.expect_value(t, temp_error, nil) {return}
	defer delete(directory)
	defer os.remove_all(directory)
	s, d, error := parse_themes("theme.name = tokyonight-storm\n", THEMES)
	testing.expect_value(t, error, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	path, export_error := settings.theme_export(&s, directory)
	testing.expect_value(t, export_error, nil)
	data, read_error := os.read_entire_file(path, context.allocator)
	testing.expect_value(t, read_error, nil)
	defer delete(data)
	theme, issue := theme_api.file_parse(string(data))
	testing.expect_value(t, issue, "")
	testing.expect_value(t, theme.neovim.colorscheme, "tokyonight-storm")
	testing.expect_value(t, theme.neovim.plugin, "folke/tokyonight.nvim")
}

// The record of `source`'s theme, parsed back from its text.
@(private)
record_object :: proc(t: ^testing.T, source: string, generation: u64) -> json.Object {
	s, d, error := parse_themes(source, THEMES)
	testing.expect_value(t, error, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	text, ok := settings.neovim_record_text(&s, generation, context.temp_allocator)
	testing.expect(t, ok)
	value, parse_error := json.parse(text, spec = .JSON, allocator = context.temp_allocator)
	testing.expect_value(t, parse_error, json.Error.None)
	return value.(json.Object)
}

@(test)
neovim_record_holds_the_theme_and_its_colors :: proc(t: ^testing.T) {
	record := record_object(t, "theme.name = tokyonight-day\n", 7)
	testing.expect_value(t, json_number(record["version"]), f64(1))
	testing.expect_value(t, json_number(record["generation"]), f64(7))
	testing.expect_value(t, json_text(record["theme"]), "tokyonight-day")
	testing.expect_value(t, json_text(record["name"]), "Tokyo Night Day")
	testing.expect_value(t, json_flag(record["light"]), true)
	neovim := record["neovim"].(json.Object)
	testing.expect_value(t, json_text(neovim["plugin"]), "folke/tokyonight.nvim")
	testing.expect_value(t, json_text(neovim["colorscheme"]), "tokyonight-day")
	colors := record["colors"].(json.Object)
	testing.expect_value(t, json_text(colors["background"]), "#e1e2e7")
	testing.expect_value(t, json_text(colors["foreground"]), "#3760bf")
	testing.expect_value(t, len(colors["palette"].(json.Array)), 16)
	for key in ([?]string {
		"cursor", "selection", "search_foreground", "search_background", "search_selected_background",
		"surface", "muted", "faint", "accent", "success", "warning", "danger", "info",
	}) {
		text, is_text := colors[key].(json.String)
		testing.expectf(t, is_text && len(text) == 7 && text[0] == '#', "colors.%s is %v", key, colors[key])
	}
	dark := record_object(t, "theme.name = tokyonight-storm\n", 1)
	testing.expect_value(t, json_flag(dark["light"]), false)
}

@(test)
neovim_record_leaves_out_neovim_for_unmapped_themes :: proc(t: ^testing.T) {
	for source in ([?]string {
		"theme.name = studio-dark\n",
		"theme.name = tide-light\n",
		"theme.name = mine\ntheme.custom.mine.base = tide-dark\ntheme.custom.mine.accent = #123456\n",
		"theme.name = mine\ntheme.custom.mine.accent = #123456\n",
	}) {
		record := record_object(t, source, 1)
		_, has_neovim := record["neovim"]
		testing.expectf(t, !has_neovim, "the record of %q names a Neovim colorscheme", source)
	}
	record := record_object(t, "theme.name = mine\ntheme.custom.mine.base = tide-dark\ntheme.custom.mine.name = Mine\n", 1)
	testing.expect_value(t, json_text(record["theme"]), "mine")
	testing.expect_value(t, json_text(record["name"]), "Mine")
}

// The record's neovim object, or nil when it has none.
@(private)
record_neovim :: proc(t: ^testing.T, source: string) -> json.Object {
	record := record_object(t, source, 1)
	neovim, _ := record["neovim"].(json.Object)
	return neovim
}

@(test)
customizing_a_mapped_theme_keeps_its_neovim_colorscheme :: proc(t: ^testing.T) {
	// The first color edit on a bundled theme makes a custom theme based on it.
	updated, created, issue, edit_error := edit_color("theme.name = tokyonight-day\n", "accent", "#123456", THEMES)
	defer delete(updated)
	defer delete(created)
	testing.expect_value(t, edit_error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, issue, "")
	testing.expect_value(t, created, "tokyonight-day-custom")
	neovim := record_neovim(t, updated)
	testing.expect_value(t, json_text(neovim["colorscheme"]), "tokyonight-day")
	testing.expect_value(t, json_text(neovim["plugin"]), "folke/tokyonight.nvim")

	// Through a chain of bases, with the background the mapped theme needs.
	chained := record_neovim(t, "theme.name = b\ntheme.custom.a.base = gruvbox-light\ntheme.custom.b.base = a\n")
	testing.expect_value(t, json_text(chained["colorscheme"]), "gruvbox")
	testing.expect_value(t, json_text(chained["background"]), "light")

	// A theme file based on a mapped theme inherits it as a settings theme does.
	directory, temp_error := os.mkdir_temp("tests/settings", "theme-neovim-base-", context.allocator)
	if !testing.expect_value(t, temp_error, nil) {return}
	defer delete(directory)
	defer os.remove_all(directory)
	storm, read_error := os.read_entire_file(fmt.tprintf("%s/tokyonight-storm.theme.json", THEMES), context.allocator)
	if !testing.expect_value(t, read_error, nil) {return}
	defer delete(storm)
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/tokyonight-storm.theme.json", directory), storm), nil)
	file := `{"version":1,"id":"storm-file","base":"tokyonight-storm","colors":{"accent":"#123456"}}`
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/storm-file.theme.json", directory), file), nil)
	s, d, error := parse_themes("theme.name = storm-file\n", directory)
	testing.expect_value(t, error, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, len(d), 0)
	testing.expect_value(t, settings.theme_neovim(&s, "storm-file").colorscheme, "tokyonight-storm")
}

@(test)
a_custom_theme_can_name_its_own_neovim_colorscheme :: proc(t: ^testing.T) {
	base := "theme.name = mine\ntheme.custom.mine.base = tokyonight-day\n"
	generated := record_neovim(t, fmt.tprintf("%stheme.custom.mine.neovim = aiodev\n", base))
	testing.expect_value(t, json_text(generated["colorscheme"]), "aiodev")
	_, has_plugin := generated["plugin"]
	testing.expect(t, !has_plugin)
	other := record_neovim(t, "theme.name = mine\ntheme.custom.mine.neovim = kanagawa-wave\n")
	testing.expect_value(t, json_text(other["colorscheme"]), "kanagawa-wave")
	// A theme based on one that opted out keeps the opt-out.
	child := record_neovim(
		t,
		"theme.name = kid\ntheme.custom.mine.base = tokyonight-day\ntheme.custom.mine.neovim = aiodev\ntheme.custom.kid.base = mine\n",
	)
	testing.expect_value(t, json_text(child["colorscheme"]), "aiodev")

	for value in ([?]string{"two words", "a|b", ""}) {
		s, d, error := parse_themes(fmt.tprintf("%stheme.custom.mine.neovim = %s\n", base, value), THEMES)
		testing.expect_value(t, error, nil)
		testing.expectf(t, len(d) == 1, "neovim = %q gave %d diagnostics", value, len(d))
		testing.expect_value(t, settings.theme_neovim(&s, "mine").colorscheme, "tokyonight-day")
		settings.destroy(&s)
		settings.diagnostics_destroy(&d)
	}
	_, issue := settings.custom_theme_value("theme.custom.mine.neovim", "a|b", .Strict)
	testing.expect(t, issue != "")
	serialized, accepted := settings.custom_theme_value("theme.custom.mine.neovim", "aiodev", .Strict)
	testing.expect_value(t, accepted, "")
	testing.expect_value(t, serialized, "aiodev")
}

@(test)
copies_and_exports_keep_the_neovim_colorscheme_a_theme_uses :: proc(t: ^testing.T) {
	source := "theme.name = mine\ntheme.custom.mine.base = tokyonight-day\ntheme.custom.mine.neovim = aiodev\n"
	updated, created, error := edit_duplicate(source, THEMES)
	defer delete(updated)
	defer delete(created)
	testing.expect_value(t, error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, created, "mine-copy")
	testing.expect_value(t, json_text(record_neovim(t, updated)["colorscheme"]), "aiodev")

	directory, temp_error := os.mkdir_temp("tests/settings", "theme-neovim-export-", context.allocator)
	if !testing.expect_value(t, temp_error, nil) {return}
	defer delete(directory)
	defer os.remove_all(directory)
	for entry in ([?]struct {
		source, plugin, colorscheme: string,
	} {
		{"theme.name = mine\ntheme.custom.mine.base = tokyonight-storm\n", "folke/tokyonight.nvim", "tokyonight-storm"},
		{source, "", "aiodev"},
	}) {
		s, d, parse_error := parse_themes(entry.source, THEMES)
		testing.expect_value(t, parse_error, nil)
		path, export_error := settings.theme_export(&s, directory)
		settings.destroy(&s)
		settings.diagnostics_destroy(&d)
		if !testing.expect_value(t, export_error, nil) {continue}
		data, read_error := os.read_entire_file(path, context.allocator)
		testing.expect_value(t, read_error, nil)
		theme, issue := theme_api.file_parse(string(data))
		delete(data)
		testing.expect_value(t, issue, "")
		testing.expect_value(t, theme.neovim.plugin, entry.plugin)
		testing.expect_value(t, theme.neovim.colorscheme, entry.colorscheme)
	}
}

@(test)
neovim_record_write_replaces_the_file_atomically :: proc(t: ^testing.T) {
	directory, temp_error := os.mkdir_temp("tests/settings", "record-", context.allocator)
	if !testing.expect_value(t, temp_error, nil) {return}
	defer delete(directory)
	defer os.remove_all(directory)
	path := settings.neovim_record_path(directory, context.temp_allocator)
	testing.expect(t, strings.has_suffix(path, "nvim\\current.json") || strings.has_suffix(path, "nvim/current.json"))
	testing.expect_value(t, settings.neovim_record_path("", context.temp_allocator), "")
	testing.expect_value(t, settings.neovim_record_write(path, "first"), nil)
	read, read_error := os.read_entire_file(path, context.allocator)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(read), "first")
	delete(read)
	testing.expect_value(t, settings.neovim_record_write(path, "second"), nil)
	read, read_error = os.read_entire_file(path, context.allocator)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(read), "second")
	delete(read)
	entries, list_error := os.read_directory_by_path(fmt.tprintf("%s/nvim", directory), 16, context.temp_allocator)
	testing.expect_value(t, list_error, nil)
	testing.expect_value(t, len(entries), 1)
	testing.expect(t, settings.neovim_record_write(fmt.tprintf("%s/nvim/current.json/x", directory), "third") != nil)
}
