package settings

import "aio:colour"
import "core:strings"

group_title :: proc(key: string) -> string {
	dot := strings.index_byte(key, '.')
	switch dot < 0 ? key : key[:dot] {
	case "theme":
		return "Theme"
	case "pane":
		return "Panes"
	case "tab":
		return "Tabs"
	case "tabs":
		return "Tabs"
	case "shell":
		return "Shell"
	case "input":
		return "Input"
	case "process":
		return "Processes"
	case "font":
		return "Font"
	case "interface":
		return "Interface"
	case "window":
		return "Window"
	case "scrollback":
		return "Scrollback"
	case "terminal":
		return "Terminal"
	case "cursor":
		return "Cursor"
	case "colors":
		return "Colors"
	}
	return "Other"
}

// Accepts the forms a person may paste: hex (#rgb, #rrggbb, 0xrrggbb, bare digits), rgb(), hsl(),
// hsv() and "r, g, b". Settings colors are opaque, so `alpha` reports an alpha component that the
// result drops.
parse_color :: proc(text: string) -> (color: Color, ok, alpha: bool) {
	return colour.parse(text, .Permissive)
}

hsv_to_rgb :: proc(hue, saturation, value: f32) -> Color {
	return colour.hsv_to_rgb(hue, saturation, value)
}

rgb_to_hsv :: proc(c: Color) -> (hue, saturation, value: f32) {
	return colour.rgb_to_hsv(c)
}
