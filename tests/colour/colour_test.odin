package colour_test

import "aio:colour"
import "core:testing"

@(test)
strict_policy_accepts_the_canonical_file_form_only :: proc(t: ^testing.T) {
	Cases :: struct {
		text:  string,
		value: colour.Value,
	}
	cases := [?]Cases{
		{"#ff8800", {255, 136, 0}},
		{"#FF8800", {255, 136, 0}},
		{"#000000", {0, 0, 0}},
	}
	for c in cases {
		value, ok, alpha := colour.parse(c.text, .Strict)
		testing.expectf(t, ok, "%q should parse", c.text)
		testing.expect_value(t, value, c.value)
		testing.expect_value(t, alpha, false)
	}
	for text in ([?]string{
		"",
		"#ff880",
		"#ff880080",
		"#f80",
		"#f80f",
		"ff8800",
		"0xff8800",
		"rgb(255, 136, 0)",
		"default",
		" #ff8800",
		"#ff8800 ",
		"#gggggg",
	}) {
		_, ok, _ := colour.parse(text, .Strict)
		testing.expectf(t, !ok, "%q should be rejected", text)
	}
}

@(test)
permissive_policy_accepts_pasted_representations :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		value: colour.Value,
		alpha: bool,
	}
	cases := [?]Case{
		{"#ff8800", {255, 136, 0}, false},
		{"  #F80 ", {255, 136, 0}, false},
		{"#f80f", {255, 136, 0}, true},
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
		value, ok, alpha := colour.parse(c.text, .Permissive)
		testing.expectf(t, ok, "%q should parse", c.text)
		testing.expect_value(t, value, c.value)
		testing.expectf(t, alpha == c.alpha, "%q alpha %v", c.text, alpha)
	}
	for text in ([?]string{
		"",
		"#12",
		"#12345",
		"#ggg",
		"blue",
		"default",
		"rgb(256, 0, 0)",
		"rgb(1, 2)",
		"hsl(0, 120%, 50%)",
		"rgb(1, 2, 3",
		"rgb(nan, 0, 0)",
		"1 2 3 4 5",
	}) {
		_, ok, _ := colour.parse(text, .Permissive)
		testing.expectf(t, !ok, "%q should be rejected", text)
	}
}

@(test)
alpha_is_reported_permissively_and_refused_by_the_strict_policy :: proc(t: ^testing.T) {
	value, ok, alpha := colour.parse("#ff880080", .Permissive)
	testing.expect(t, ok)
	testing.expect_value(t, value, colour.Value{255, 136, 0})
	testing.expect_value(t, alpha, true)
	_, strict_ok, strict_alpha := colour.parse("#ff880080", .Strict)
	testing.expect(t, !strict_ok)
	testing.expect_value(t, strict_alpha, false)
	opaque, opaque_ok, opaque_alpha := colour.parse("#ff8800", .Permissive)
	testing.expect(t, opaque_ok)
	testing.expect_value(t, opaque, value)
	testing.expect_value(t, opaque_alpha, false)
}

@(test)
format_writes_the_canonical_lowercase_form :: proc(t: ^testing.T) {
	buffer: [colour.HEX_LENGTH]u8
	testing.expect_value(t, colour.HEX_LENGTH, 7)
	testing.expect_value(t, colour.format(colour.Value{0xAB, 0x12, 0xEF}, buffer[:]), "#ab12ef")
	for value in ([?]colour.Value{{0, 0, 0}, {255, 255, 255}, {18, 52, 86}, {0xab, 0xcd, 0xef}}) {
		text := colour.format(value, buffer[:])
		parsed, ok, alpha := colour.parse(text, .Strict)
		testing.expectf(t, ok, "%q should parse strictly", text)
		testing.expect_value(t, parsed, value)
		testing.expect_value(t, alpha, false)
	}
}

@(test)
rgba_scales_channels_and_carries_alpha :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		colour.rgba(colour.Value{255, 128, 0}),
		colour.RGBA{1, f32(128) / 255, 0, 1},
	)
	testing.expect_value(t, colour.rgba(colour.Value{0, 0, 0}, 0.25), colour.RGBA{0, 0, 0, 0.25})
	testing.expect_value(t, colour.rgba(colour.Value{255, 255, 255}, 0), colour.RGBA{1, 1, 1, 0})
}

@(test)
hsv_conversion_round_trips_primary_and_grey_values :: proc(t: ^testing.T) {
	for c in ([?]colour.Value{{255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {18, 52, 86}, {128, 128, 128},
		{0, 0, 0}}) {
		h, s, v := colour.rgb_to_hsv(c)
		testing.expect_value(t, colour.hsv_to_rgb(h, s, v), c)
	}
	testing.expect_value(t, colour.hsv_to_rgb(-120, 1, 1), colour.Value{0, 0, 255})
	testing.expect_value(t, colour.hsv_to_rgb(720, 2, 1), colour.Value{255, 0, 0})
}
