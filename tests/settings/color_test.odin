package settings_test

import "core:strings"
import "core:testing"
import "aio:settings"

@(test)
parse_color_accepts_pasted_representations :: proc(t: ^testing.T) {
	Case :: struct { text: string, color: settings.Color, alpha: bool }
	cases := [?]Case{
		{"#ff8800", {255, 136, 0}, false},
		{"  #F80 ", {255, 136, 0}, false},
		{"ff8800", {255, 136, 0}, false},
		{"0xFF8800", {255, 136, 0}, false},
		{"#ff880080", {255, 136, 0}, true},
		{"rgb(255, 136, 0)", {255, 136, 0}, false},
		{"rgb(100% 0% 0%)", {255, 0, 0}, false},
		{"rgba(255,136,0,0.5)", {255, 136, 0}, true},
		{"rgb(255 136 0 / 50%)", {255, 136, 0}, true},
		{"255, 136, 0", {255, 136, 0}, false},
		{"hsl(120, 100%, 50%)", {0, 255, 0}, false},
		{"hsl(240deg 100% 25%)", {0, 0, 128}, false},
		{"hsla(0, 0%, 100%, 1)", {255, 255, 255}, true},
		{"hsv(60, 100%, 100%)", {255, 255, 0}, false},
		{"HSB(0, 0%, 0%)", {0, 0, 0}, false},
	}
	for c in cases {
		color, ok, alpha := settings.parse_color(c.text)
		testing.expectf(t, ok, "%q should parse", c.text)
		testing.expectf(t, color == c.color, "%q gave %v, expected %v", c.text, color, c.color)
		testing.expectf(t, alpha == c.alpha, "%q alpha %v", c.text, alpha)
	}
	for text in ([?]string{"", "#12", "#ggg", "blue", "rgb(256, 0, 0)", "rgb(1, 2)", "hsl(0, 120%, 50%)",
		"rgb(1, 2, 3", "rgb(nan, 0, 0)", "1 2 3 4 5", "#12345"}) {
		_, ok, _ := settings.parse_color(text)
		testing.expectf(t, !ok, "%q should be rejected", text)
	}
}

@(test)
hsv_conversion_round_trips_primary_and_grey_colors :: proc(t: ^testing.T) {
	for c in ([?]settings.Color{{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {18, 52, 86}, {128, 128, 128}, {0, 0, 0}}) {
		h, s, v := settings.rgb_to_hsv(c)
		testing.expect_value(t, settings.hsv_to_rgb(h, s, v), c)
	}
	testing.expect_value(t, settings.hsv_to_rgb(-120, 1, 1), settings.Color{0, 0, 255})
	testing.expect_value(t, settings.hsv_to_rgb(720, 2, 1), settings.Color{255, 0, 0})
}

@(test)
every_setting_has_a_friendly_title_and_group :: proc(t: ^testing.T) {
	for entry in settings.SCHEMA {
		testing.expectf(t, entry.title != "" && entry.title != entry.key && !strings.contains(entry.title, "."),
			"%s needs a readable title", entry.key)
		testing.expectf(t, settings.group_title(entry.key) != "Other", "%s needs a group", entry.key)
	}
	testing.expect_value(t, settings.schema_find("pane.gap").title, "Pane Gap")
	testing.expect_value(t, settings.group_title("pane.gap"), "Panes")
}

@(test)
edit_text_normalizes_pasted_theme_colors :: proc(t: ^testing.T) {
	key :: "theme.custom.mine.cursor"
	updated, message, err := settings.edit_text(key + " = #000000\n", key, "rgb(255, 136, 0)")
	defer delete(updated)
	defer delete(message)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, message, "")
	testing.expect_value(t, updated, key + " = #ff8800\n")
	border, border_message, border_error := settings.edit_text("", "theme.custom.mine.border", "rgba(255,136,0,0.5)")
	defer delete(border)
	defer delete(border_message)
	testing.expect_value(t, border_error, nil)
	testing.expect_value(t, border, "theme.custom.mine.border = #ff880080\n")
	opaque, opaque_message, opaque_error := settings.edit_text("", "theme.custom.mine.border", "#ff8800ff")
	defer delete(opaque)
	defer delete(opaque_message)
	testing.expect_value(t, opaque_error, nil)
	testing.expect_value(t, opaque, "theme.custom.mine.border = #ff8800\n")
	rejected, reason, reject_error := settings.edit_text(updated, key, "not a color")
	defer delete(rejected)
	defer delete(reason)
	testing.expect_value(t, reject_error, nil)
	testing.expect(t, reason != "")
}
