// Package colour owns the colour value: three opaque RGB channels, one hex digit grammar, the
// canonical formatter, the alpha report and the float and HSV conversions.
//
// The settings file and the control attribute reader accept the canonical `#rrggbb` text alone; a
// person may paste more, so both accept sets are explicit policies over the same grammar. `alpha`
// reports an alpha channel that the text carried; the value itself stays opaque. Interface theme
// colours may blend, so the Translucent forms keep that channel.
package colour

import "core:math"
import "core:strconv"
import "core:strings"

// Value is an opaque RGB colour. The settings and terminal packages name the same [3]u8 channels.
Value :: [3]u8

// RGBA is the float representation of a Value, in the drawing channel order.
RGBA :: [4]f32

// HEX_LENGTH is the length of the canonical `#rrggbb` text.
HEX_LENGTH :: 7

// Translucent is a Value with a fourth alpha byte; 255 is opaque.
Translucent :: [4]u8

// HEX_ALPHA_LENGTH is the length of the canonical `#rrggbbaa` text.
HEX_ALPHA_LENGTH :: 9

// Parse_Policy is the accept set a caller offers. Both policies read the same hex grammar: Strict
// takes the canonical opaque form alone, and Permissive adds the short and eight-digit hex forms,
// a `0x` prefix, bare digits, rgb()/hsl()/hsv() channels and comma-separated channels.
Parse_Policy :: enum {
	Strict,
	Permissive,
}

// parse reads one textual colour under `policy`. `alpha` reports an alpha channel in the text;
// the returned value is opaque either way.
@(require_results)
parse :: proc(text: string, policy: Parse_Policy) -> (value: Value, ok, alpha: bool) {
	if policy == .Strict && len(text) != HEX_LENGTH {return}
	translucent: Translucent
	translucent, ok, alpha = parse_channels(text, policy)
	return translucent.rgb, ok, alpha
}

// parse_translucent reads the same grammar as parse but keeps the alpha channel; text without one
// is opaque. Strict takes `#rrggbb` and `#rrggbbaa`.
@(require_results)
parse_translucent :: proc(text: string, policy: Parse_Policy) -> (value: Translucent, ok: bool) {
	if policy == .Strict && len(text) != HEX_LENGTH && len(text) != HEX_ALPHA_LENGTH {return}
	value, ok, _ = parse_channels(text, policy)
	return
}

@(private, require_results)
parse_channels :: proc(text: string, policy: Parse_Policy) -> (value: Translucent, ok, alpha: bool) {
	if policy == .Strict {
		if text[0] != '#' {return}
		return hex_value(text[1:])
	}
	t := strings.trim_space(text)
	lower := strings.to_lower(t, context.temp_allocator)
	if strings.has_prefix(lower, "#") {return hex_value(lower[1:])}
	if strings.has_prefix(lower, "0x") {return hex_value(lower[2:])}
	if c, hex, a := hex_value(lower); hex && len(lower) >= 6 {return c, true, a}
	name := ""
	arguments := lower
	if open := strings.index_byte(lower, '('); open >= 0 {
		if !strings.has_suffix(lower, ")") {return}
		name = strings.trim_space(lower[:open])
		arguments = lower[open + 1:len(lower) - 1]
	}
	fields: [5]string
	count := 0
	separated, _ := strings.replace_all(arguments, ",", " ", context.temp_allocator)
	rest, _ := strings.replace_all(separated, "/", " ", context.temp_allocator)
	for field in strings.fields_iterator(&rest) {
		if count == len(fields) {return}
		fields[count] = field
		count += 1
	}
	if count != 3 && count != 4 {return}
	alpha = count == 4
	value.a = 255
	if alpha {
		a := color_component(fields[3], 1) or_return
		if a < 0 || a > 1 {return}
		value.a = u8(math.round(a * 255))
	}
	values: [3]f32
	switch name {
	case "", "rgb", "rgba":
		for i in 0 ..< 3 {
			values[i] = color_component(fields[i], 255) or_return
			if values[i] < 0 || values[i] > 255 {return}
		}
		value.rgb = {u8(math.round(values[0])), u8(math.round(values[1])), u8(math.round(values[2]))}
		return value, true, alpha
	case "hsl", "hsla", "hsv", "hsva", "hsb":
		values[0] = color_component(fields[0], 360) or_return
		for i in 1 ..< 3 {
			v := color_component(fields[i], 100) or_return
			if v < 0 || v > 100 {return}
			values[i] = v / 100
		}
		if name == "hsl" || name == "hsla" {
			value.rgb = hsl_to_rgb(values[0], values[1], values[2])
		} else {
			value.rgb = hsv_to_rgb(values[0], values[1], values[2])
		}
		return value, true, alpha
	}
	return
}

// format writes the canonical lowercase `#rrggbb` form of `value` into `buffer` and returns the
// written text. The caller provides at least HEX_LENGTH bytes.
@(require_results)
format :: proc(value: Value, buffer: []u8) -> string {
	assert(len(buffer) >= HEX_LENGTH)
	buffer[0] = '#'
	for channel, i in value {
		at := 1 + i * 2
		buffer[at] = hex_char(channel >> 4)
		buffer[at + 1] = hex_char(channel & 0x0f)
	}
	return string(buffer[:HEX_LENGTH])
}

// format_translucent writes `#rrggbb` for an opaque value and `#rrggbbaa` otherwise. The caller
// provides at least HEX_ALPHA_LENGTH bytes.
@(require_results)
format_translucent :: proc(value: Translucent, buffer: []u8) -> string {
	assert(len(buffer) >= HEX_ALPHA_LENGTH)
	_ = format(value.rgb, buffer)
	if value.a == 255 {return string(buffer[:HEX_LENGTH])}
	buffer[7] = hex_char(value.a >> 4)
	buffer[8] = hex_char(value.a & 0x0f)
	return string(buffer[:HEX_ALPHA_LENGTH])
}

// rgba converts byte channels to the float representation and sets the fourth channel to `alpha`.
@(require_results)
rgba :: proc(value: Value, alpha: f32 = 1) -> RGBA {
	return {f32(value[0]) / 255, f32(value[1]) / 255, f32(value[2]) / 255, alpha}
}

// hsv_to_rgb converts hue, saturation and value, each clamped where a colour cannot use more, to
// byte channels.
hsv_to_rgb :: proc(hue, saturation, value: f32) -> Value {
	h := math.mod(hue, 360)
	if h < 0 {h += 360}
	s, v := clamp(saturation, 0, 1), clamp(value, 0, 1)
	c := v * s
	x := c * (1 - abs(math.mod(h / 60, 2) - 1))
	r, g, b: f32
	switch {
	case h < 60:
		r, g, b = c, x, 0
	case h < 120:
		r, g, b = x, c, 0
	case h < 180:
		r, g, b = 0, c, x
	case h < 240:
		r, g, b = 0, x, c
	case h < 300:
		r, g, b = x, 0, c
	case:
		r, g, b = c, 0, x
	}
	m := v - c
	return {
		u8(math.round((r + m) * 255)),
		u8(math.round((g + m) * 255)),
		u8(math.round((b + m) * 255)),
	}
}

// rgb_to_hsv is the inverse of hsv_to_rgb; grey values report zero hue and saturation.
rgb_to_hsv :: proc(c: Value) -> (hue, saturation, value: f32) {
	r, g, b := f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255
	high, low := max(r, g, b), min(r, g, b)
	delta := high - low
	switch {
	case delta == 0:
		hue = 0
	case high == r:
		hue = 60 * math.mod((g - b) / delta, 6)
	case high == g:
		hue = 60 * ((b - r) / delta + 2)
	case:
		hue = 60 * ((r - g) / delta + 4)
	}
	if hue < 0 {hue += 360}
	saturation = high == 0 ? 0 : delta / high
	return hue, saturation, high
}

@(private, require_results)
hex_value :: proc(digits: string) -> (value: Translucent, ok, alpha: bool) {
	if len(digits) != 3 &&
	   len(digits) != 4 &&
	   len(digits) != 6 &&
	   len(digits) != 8 {return {}, false, false}
	short := len(digits) <= 4
	channels := Translucent{0, 0, 0, 255}
	if len(digits) == 4 || len(digits) == 8 {channels.a = 0}
	for i in 0 ..< len(digits) {
		digit, digit_ok := digit_value(digits[i])
		if !digit_ok {return {}, false, false}
		if short {channels[i] = digit * 17} else {channels[i / 2] = channels[i / 2] * 16 + digit}
	}
	return channels, true, len(digits) == 4 || len(digits) == 8
}

@(private, require_results)
digit_value :: proc(c: u8) -> (u8, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

@(private, require_results)
hex_char :: proc(digit: u8) -> u8 {
	return digit < 10 ? '0' + digit : 'a' + digit - 10
}

@(private)
hsl_to_rgb :: proc(hue, saturation, lightness: f32) -> Value {
	l := clamp(lightness, 0, 1)
	v := l + clamp(saturation, 0, 1) * min(l, 1 - l)
	s := v == 0 ? 0 : 2 * (1 - l / v)
	return hsv_to_rgb(hue, s, v)
}

// Parses one component; `scale` maps a percentage onto the component's full range.
@(private)
color_component :: proc(text: string, scale: f32) -> (f32, bool) {
	t := text
	percent := strings.has_suffix(t, "%")
	if percent {t = t[:len(t) - 1]}
	if strings.has_suffix(t, "deg") {t = t[:len(t) - 3]}
	value, ok := strconv.parse_f32(t)
	if !ok || math.is_nan(value) || math.is_inf(value) {return 0, false}
	return percent ? value / 100 * scale : value, true
}
