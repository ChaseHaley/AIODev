package settings

import "core:math"
import "core:strconv"
import "core:strings"

group_title :: proc(key: string) -> string {
	dot := strings.index_byte(key, '.')
	switch dot < 0 ? key : key[:dot] {
	case "theme": return "Theme"
	case "pane": return "Panes"
	case "shell": return "Shell"
	case "input": return "Input"
	case "font": return "Font"
	case "window": return "Window"
	case "scrollback": return "Scrollback"
	case "terminal": return "Terminal"
	case "cursor": return "Cursor"
	case "colors": return "Colors"
	}
	return "Other"
}

hsv_to_rgb :: proc(hue, saturation, value: f32) -> Color {
	h := math.mod(hue, 360)
	if h < 0 { h += 360 }
	s, v := clamp(saturation, 0, 1), clamp(value, 0, 1)
	c := v*s
	x := c*(1-abs(math.mod(h/60, 2)-1))
	r, g, b: f32
	switch {
	case h < 60: r, g, b = c, x, 0
	case h < 120: r, g, b = x, c, 0
	case h < 180: r, g, b = 0, c, x
	case h < 240: r, g, b = 0, x, c
	case h < 300: r, g, b = x, 0, c
	case: r, g, b = c, 0, x
	}
	m := v-c
	return {u8(math.round((r+m)*255)), u8(math.round((g+m)*255)), u8(math.round((b+m)*255))}
}

rgb_to_hsv :: proc(c: Color) -> (hue, saturation, value: f32) {
	r, g, b := f32(c.r)/255, f32(c.g)/255, f32(c.b)/255
	high, low := max(r, g, b), min(r, g, b)
	delta := high-low
	switch {
	case delta == 0: hue = 0
	case high == r: hue = 60*math.mod((g-b)/delta, 6)
	case high == g: hue = 60*((b-r)/delta+2)
	case: hue = 60*((r-g)/delta+4)
	}
	if hue < 0 { hue += 360 }
	saturation = high == 0 ? 0 : delta/high
	return hue, saturation, high
}

@(private)
hsl_to_rgb :: proc(hue, saturation, lightness: f32) -> Color {
	l := clamp(lightness, 0, 1)
	v := l+clamp(saturation, 0, 1)*min(l, 1-l)
	s := v == 0 ? 0 : 2*(1-l/v)
	return hsv_to_rgb(hue, s, v)
}

// Parses one component; `scale` maps a percentage onto the component's full range.
@(private)
color_component :: proc(text: string, scale: f32) -> (f32, bool) {
	t := text
	percent := strings.has_suffix(t, "%")
	if percent { t = t[:len(t)-1] }
	if strings.has_suffix(t, "deg") { t = t[:len(t)-3] }
	value, ok := strconv.parse_f32(t)
	if !ok || math.is_nan(value) || math.is_inf(value) { return 0, false }
	return percent ? value/100*scale : value, true
}

@(private)
hex_color :: proc(digits: string) -> (Color, bool, bool) {
	if len(digits) != 3 && len(digits) != 4 && len(digits) != 6 && len(digits) != 8 { return {}, false, false }
	short := len(digits) <= 4
	values: [4]u8
	for i in 0..<len(digits) {
		d, ok := hex_digit(digits[i])
		if !ok { return {}, false, false }
		if short { values[i] = d*17 } else { values[i/2] = values[i/2]*16+d }
	}
	return {values[0], values[1], values[2]}, true, len(digits) == 4 || len(digits) == 8
}

// Accepts hex (#rgb, #rrggbb, 0xrrggbb, bare digits), rgb(), hsl(), hsv() and "r, g, b". Settings
// colors are opaque, so `alpha` reports an alpha component that the result drops.
parse_color :: proc(text: string) -> (color: Color, ok, alpha: bool) {
	t := strings.trim_space(text)
	lower := strings.to_lower(t, context.temp_allocator)
	if strings.has_prefix(lower, "#") { return hex_color(lower[1:]) }
	if strings.has_prefix(lower, "0x") { return hex_color(lower[2:]) }
	if c, hex, a := hex_color(lower); hex && len(lower) >= 6 { return c, true, a }
	name := ""
	arguments := lower
	if open := strings.index_byte(lower, '('); open >= 0 {
		if !strings.has_suffix(lower, ")") { return }
		name = strings.trim_space(lower[:open])
		arguments = lower[open+1:len(lower)-1]
	}
	fields: [5]string
	count := 0
	separated, _ := strings.replace_all(arguments, ",", " ", context.temp_allocator)
	rest, _ := strings.replace_all(separated, "/", " ", context.temp_allocator)
	for field in strings.fields_iterator(&rest) {
		if count == len(fields) { return }
		fields[count] = field
		count += 1
	}
	if count != 3 && count != 4 { return }
	alpha = count == 4
	values: [3]f32
	switch name {
	case "", "rgb", "rgba":
		for i in 0..<3 {
			values[i] = color_component(fields[i], 255) or_return
			if values[i] < 0 || values[i] > 255 { return }
		}
		return {u8(math.round(values[0])), u8(math.round(values[1])), u8(math.round(values[2]))}, true, alpha
	case "hsl", "hsla", "hsv", "hsva", "hsb":
		values[0] = color_component(fields[0], 360) or_return
		for i in 1..<3 {
			v := color_component(fields[i], 100) or_return
			if v < 0 || v > 100 { return }
			values[i] = v/100
		}
		if name == "hsl" || name == "hsla" { return hsl_to_rgb(values[0], values[1], values[2]), true, alpha }
		return hsv_to_rgb(values[0], values[1], values[2]), true, alpha
	}
	return
}
