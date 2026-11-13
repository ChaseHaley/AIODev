package app_test

import app "../../src"
import "aio:input"
import "aio:render"
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
