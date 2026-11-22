package app_test

import app "../../src"
import "cosmos:input"
import "cosmos:render"
import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private)
board_center_press :: proc(f: ^Profile_Fixture, r: render.Rect) {
	w := f.state.windows[0]
	p := &w.editor
	outcome := ui.editor_press(p, p.fit_layout, nil, r.x + r.width / 2, r.y + r.height / 2, false)
	app.editor_outcome(&f.state, w, outcome)
}

// Customize Colors opens the board; a hex value typed on a theme file's color saves a custom copy,
// Reset returns the color to the theme it copied, a picker drag saves its color, and Delete takes
// two presses on its card button.
@(test)
color_board_edits_save_a_custom_copy_reset_and_delete :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "color-board", PROFILE_FIXTURE_SETTINGS) {return}
	p := profile_open(&f)
	w := f.state.windows[0]
	app.run_action(&f.state, w, .Customize_Colors)
	p = &w.editor
	ui.editor_fit(p, ui.editor_layout({0, 40, 1200, 1400}, 1, true))
	if !testing.expect(t, ui.color_board_shown(p)) {return}
	testing.expect_value(t, ui.color_board_token_key(p), "colors.window")
	theme := strings.clone(f.state.settings.theme.name, context.temp_allocator)
	testing.expect(t, !settings.theme_custom(&f.state.settings))
	// Every color shows as a tile, and the board takes far fewer lines than its rows would.
	tiles := 0
	for item in p.items {
		if item.row >= 0 && p.rows[item.row].action == .Theme_Color {tiles += 1}
	}
	testing.expect_value(t, tiles, len(settings.Theme_Token))
	testing.expect(t, ui.color_board_lines(p, p.fit_layout) * 2 < len(p.items))

	profile_press(&f, {key = .Tab})
	profile_press(&f, {key = .Arrow_Right})
	testing.expect_value(t, ui.editor_row(p).key, "colors.tab_bar")
	profile_press(&f, {key = .Enter})
	ui.editor_text(p, "#203040")
	profile_press(&f, {key = .Enter})
	copy := strings.clone(f.state.settings.theme.name, context.temp_allocator)
	testing.expect_value(t, copy, fmt.tprintf("%s-custom", theme))
	testing.expect(t, settings.theme_custom(&f.state.settings))
	testing.expect_value(t, p.message, fmt.tprintf("Saved as new theme %s.", copy))
	testing.expect(t, profile_file_has(f.path, fmt.tprintf("theme.custom.%s.tab_bar = #203040", copy)))
	testing.expect(t, ui.color_board_shown(p))
	testing.expect_value(t, ui.color_board_token_key(p), "colors.tab_bar")
	testing.expect_value(t, p.board.control, ui.Board_Control.Tile)
	testing.expect(t, profile_item(p, "theme.rename") >= 0, "the copy's card renames it")

	board_center_press(&f, ui.color_board_rect(p, p.fit_layout, .Reset))
	testing.expect_value(t, p.message, "Color returned to the base theme.")
	testing.expect(t, profile_file_lacks(f.path, fmt.tprintf("theme.custom.%s.tab_bar", copy)))
	testing.expect_value(t, f.state.settings.theme.name, copy)

	wheel := ui.color_board_rect(p, p.fit_layout, .Wheel)
	outcome := ui.editor_press(p, p.fit_layout, nil, wheel.x + wheel.width - 3, wheel.y + wheel.height / 2, false)
	app.editor_outcome(&f.state, w, outcome)
	app.editor_outcome(&f.state, w, ui.editor_release(p))
	testing.expect(t, !p.error)
	testing.expect(t, !profile_file_lacks(f.path, fmt.tprintf("theme.custom.%s.tab_bar", copy)))
	testing.expect_value(t, ui.color_board_token_key(p), "colors.tab_bar")

	// A palette jump to a color lands on its tile, and a search still finds it among every section.
	app.settings_reveal_page(p, {key = "colors.cursor"})
	testing.expect(t, ui.color_board_shown(p))
	testing.expect_value(t, ui.color_board_token_key(p), "colors.cursor")
	profile_press(&f, {key = .F, modifiers = {.Control}})
	ui.editor_text(p, "cursor")
	testing.expect(t, !ui.color_board_shown(p))
	testing.expect(t, ui.editor_section_counts(p)[int(app.Settings_Area.Colors)] >= 2)
	testing.expect(t, profile_item(p, "colors.cursor_text") >= 0)
	profile_press(&f, input.Key_Event{key = .Escape})

	delete_button := ui.editor_row_parts(p, p.fit_layout, profile_item(p, "theme.delete")).row
	board_center_press(&f, delete_button)
	testing.expect(t, p.delete_armed)
	testing.expect_value(t, f.state.settings.theme.name, copy)
	board_center_press(&f, ui.editor_row_parts(p, p.fit_layout, profile_item(p, "theme.delete")).row)
	testing.expect_value(t, f.state.settings.theme.name, theme)
}

// A color pointed at another through the inspector saves its key, follows that color when it changes,
// and unlinking keeps the color it had resolved to.
@(test)
color_board_links_follow_the_color_they_point_at :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "color-board-links", PROFILE_FIXTURE_SETTINGS) {return}
	_ = profile_open(&f)
	w := f.state.windows[0]
	app.run_action(&f.state, w, .Customize_Colors)
	p := &w.editor
	ui.editor_fit(p, ui.editor_layout({0, 40, 1200, 1400}, 1, true))
	if !testing.expect(t, ui.color_board_shown(p)) {return}
	app.settings_reveal_page(p, {key = "colors.cursor"})
	testing.expect_value(t, ui.color_board_token_key(p), "colors.cursor")

	// The source field lists the theme's colors; Accent is picked from the filtered list.
	board_center_press(&f, ui.color_board_rect(p, p.fit_layout, .Link))
	testing.expect_value(t, ui.editor_popup(p), ui.Editor_Popup.Choice)
	ui.editor_text(p, "accent")
	for _ in 0 ..< 2 {profile_press(&f, {key = .Arrow_Down})}
	profile_press(&f, {key = .Enter})
	copy := strings.clone(f.state.settings.theme.name, context.temp_allocator)
	testing.expect(t, settings.theme_custom(&f.state.settings))
	testing.expect(t, profile_file_has(f.path, fmt.tprintf("theme.custom.%s.cursor = accent", copy)))
	theme := f.state.settings.active_theme
	testing.expect(t, .Cursor in theme.linked)
	testing.expect_value(t, theme.target[.Cursor], settings.Theme_Token.Accent)
	testing.expect_value(t, f.state.settings.colors.cursor, theme.colors[.Accent].rgb)
	testing.expect(t, ui.color_board_rect(p, p.fit_layout, .Unlink).width > 0)

	// Changing Accent moves the cursor with it, and the saved line for the cursor stays a link.
	app.settings_reveal_page(p, {key = "colors.accent"})
	profile_press(&f, {key = .Enter})
	ui.editor_text(p, "#22cc88")
	profile_press(&f, {key = .Enter})
	testing.expect_value(t, f.state.settings.colors.cursor, settings.Color{0x22, 0xcc, 0x88})
	testing.expect_value(t, f.state.settings.active_theme.colors[.Cursor].rgb, settings.Color{0x22, 0xcc, 0x88})
	testing.expect(t, profile_file_has(f.path, fmt.tprintf("theme.custom.%s.cursor = accent", copy)))
	testing.expect(t, profile_file_has(f.path, fmt.tprintf("theme.custom.%s.accent = #22cc88", copy)))

	// Unlink keeps the resolved color as the cursor's own.
	app.settings_reveal_page(p, {key = "colors.cursor"})
	board_center_press(&f, ui.color_board_rect(p, p.fit_layout, .Unlink))
	testing.expect(t, !(.Cursor in f.state.settings.active_theme.linked))
	testing.expect(t, profile_file_has(f.path, fmt.tprintf("theme.custom.%s.cursor = #22cc88", copy)))
	testing.expect_value(t, ui.color_board_rect(p, p.fit_layout, .Unlink), render.Rect{})
}

// The Markdown code colours are findable: text and fill read as a pair in a group of their own, the shared
// code fill follows them, and a search for "code" lists the text tiles beside the fills.
@(test)
the_markdown_code_colors_sit_together_as_text_and_fill_pairs :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "color-board-code", PROFILE_FIXTURE_SETTINGS) {return}
	_ = profile_open(&f)
	w := f.state.windows[0]
	app.run_action(&f.state, w, .Customize_Colors)
	p := &w.editor
	ui.editor_fit(p, ui.editor_layout({0, 40, 1200, 1400}, 1, true))
	labels: [dynamic]string
	defer delete(labels)
	group_titles := map[string]bool{}
	defer delete(group_titles)
	for row in p.rows {
		if row.action != .Theme_Color || !strings.contains(row.key, "code") {continue}
		append(&labels, fmt.tprintf("%s=%s/%s", row.key[len("colors."):], p.groups[row.group].title, row.badge))
		group_titles[p.groups[row.group].title] = true
	}
	expected := [?]string {
		"markdown_inline_code_text=Markdown code/Inline code",
		"markdown_inline_code_background=Markdown code/Inline code fill",
		"markdown_code_block_text=Markdown code/Code block",
		"markdown_code_block_background=Markdown code/Code block fill",
		"code_background=Markdown code/Code fill",
	}
	for want in expected {
		found := false
		for have in labels {found ||= have == want}
		testing.expectf(t, found, "missing %s in %v", want, labels)
	}
	testing.expect_value(t, len(group_titles), 1)

	// Typing in the search shows the code colours as rows, text before fill.
	ui.editor_text(p, "code")
	ui.editor_fit(p, ui.editor_layout({0, 40, 1200, 1400}, 1, true))
	shown: [dynamic]string
	defer delete(shown)
	for item in p.items {
		if item.row >= 0 && p.rows[item.row].action == .Theme_Color {append(&shown, p.rows[item.row].key)}
	}
	for key in ([?]string{"colors.markdown_inline_code_text", "colors.markdown_code_block_text"}) {
		found := false
		for have in shown {found ||= have == key}
		testing.expectf(t, found, "a search for code lists %s; it lists %v", key, shown)
	}
}
