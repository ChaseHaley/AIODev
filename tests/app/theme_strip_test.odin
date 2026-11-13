package app_test

import app "../../src"
import "aio:settings"
import "aio:ui"
import "core:testing"

@(private)
theme_strip_card :: proc(p: ^ui.Editor, id: string) -> int {
	for card, i in p.strip.cards {if card.id == id {return i}}
	return -1
}

// The strip saves as the theme dropdown did: a click on a spine and Enter on a card each switch the
// app's theme, the rebuilt page keeps showing the strip with that card opening, and Customize opens
// the Colors section.
@(test)
theme_strip_click_and_enter_apply_and_customize_opens_colors :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	w, ok := theme_delete_open(t, &f, "theme-strip")
	if !ok {return}
	s := &f.state
	p := &w.editor
	app.settings_reveal_page(p, {key = "theme.name"})
	testing.expect_value(t, p.section, int(app.Settings_Area.General))
	testing.expect_value(t, ui.editor_row(p).kind, ui.Row_Kind.Theme_Strip)
	testing.expect_value(t, ui.editor_strip_card_id(p, p.strip.applied), "alpha")
	beta := theme_strip_card(p, "beta")
	if !testing.expect(t, beta > theme_strip_card(p, "alpha") && theme_strip_card(p, "alpha") >= 0) {return}
	testing.expect(t, theme_strip_card(p, "studio-dark") >= 0)

	l := app.settings_layout(w)
	if !testing.expect(t, l.list.width > 0) {return}
	card := ui.editor_strip_card_rect(p, l, p.selected, beta)
	app.editor_outcome(s, w, ui.editor_press(p, l, nil, card.x + card.width / 2, card.y + 20, false))
	testing.expect_value(t, s.settings.theme.name, "beta")
	testing.expect_value(t, s.settings.active_theme.colors[.Cursor].rgb, settings.Color{4, 5, 6})
	testing.expect_value(t, ui.editor_row(p).kind, ui.Row_Kind.Theme_Strip)
	testing.expect_value(t, ui.editor_strip_card_id(p, p.strip.applied), "beta")
	testing.expect(t, ui.editor_strip_animating(p))

	app.settings_key(s, w, {key = .Arrow_Left, pressed = true})
	testing.expect_value(t, ui.editor_strip_card_id(p, p.strip.focus), "alpha")
	app.settings_key(s, w, {key = .Enter, pressed = true})
	testing.expect_value(t, s.settings.theme.name, "alpha")
	testing.expect_value(t, ui.editor_strip_card_id(p, p.strip.applied), "alpha")

	app.settings_key(s, w, {key = .Tab, pressed = true})
	testing.expect(t, p.strip.customize_focus)
	app.settings_key(s, w, {key = .Enter, pressed = true})
	testing.expect_value(t, p.section, int(app.Settings_Area.Colors))
	testing.expect_value(t, s.settings.theme.name, "alpha")
}
