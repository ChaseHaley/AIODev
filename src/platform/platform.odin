package platform

import "aio:input"

Window_Id :: distinct u64
Init_Result :: enum { Failed, Primary, Secondary }
Error :: enum { None, Invalid_Argument, Not_Initialized, Invalid_Window, Out_Of_Memory, Os, Queue_Full }
Window_Desc :: struct {
	title: string,
	width, height: i32,
	hidden, inactive: bool,
}
Cursor_Shape :: enum { Arrow, Text, Hand, Resize_Horizontal, Resize_Vertical, Hidden }
Tray_Menu_Item :: struct { id: u32, title: string, disabled, separator: bool }
Key_Event :: struct {
	window: Window_Id,
	key: input.Key,
	modifiers: input.Modifiers,
	pressed, repeat: bool,
	text: string,
	unshifted: rune,
	native: Native_Key,
}
Text_Event :: struct { window: Window_Id, text: string }
Mouse_Button_Event :: struct {
	window: Window_Id,
	button: input.Mouse_Button,
	pressed: bool,
	x, y: i32,
	modifiers: input.Modifiers,
	time_ns: i64,
}
Mouse_Move_Event :: struct {
	window: Window_Id,
	x, y: i32,
	buttons: input.Mouse_Buttons,
	modifiers: input.Modifiers,
	time_ns: i64,
}
Mouse_Wheel_Event :: struct {
	window: Window_Id,
	x, y: i32,
	delta_x, delta_y: f32,
	modifiers: input.Modifiers,
	time_ns: i64,
}
Resize_Event :: struct { window: Window_Id, width, height: i32 }
Dpi_Event :: struct { window: Window_Id, dpi: u32 }
Focus_Event :: struct { window: Window_Id, focused: bool }
Mouse_Leave_Event :: struct { window: Window_Id }
Close_Request_Event :: struct { window: Window_Id }
Tray_Event :: struct {}
Tray_Menu_Event :: struct { id: u32 }
Activate_Request_Event :: struct {}
Settings_Event :: struct {}
Wake_Event :: struct {}
Event :: union {
	Key_Event, Text_Event, Mouse_Button_Event, Mouse_Move_Event, Mouse_Leave_Event, Mouse_Wheel_Event,
	Resize_Event, Dpi_Event, Focus_Event, Close_Request_Event, Tray_Event,
	Tray_Menu_Event, Activate_Request_Event, Settings_Event, Wake_Event,
}

@(require_results)
clipboard_crlf :: proc(text: string, out: []u8) -> (string, bool) {
	n := 0
	for c, i in transmute([]u8)text {
		if c == '\n' && (i == 0 || text[i-1] != '\r') {
			if n == len(out) { return "", false }
			out[n] = '\r'
			n += 1
		}
		if n == len(out) { return "", false }
		out[n] = c
		n += 1
	}
	return string(out[:n]), true
}
