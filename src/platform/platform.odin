package platform

import "aio:input"

Init_Result :: enum {
	Failed,
	Primary,
	Secondary,
}
Error :: enum {
	None,
	Invalid_Argument,
	Not_Initialized,
	Invalid_Window,
	Out_Of_Memory,
	Os,
	Queue_Full,
	// A service failed to start earlier and is not tried again.
	Unavailable,
}
Window_Desc :: struct {
	title:            string,
	width, height:    i32,
	hidden, inactive: bool,
	tabbed_title_bar: bool,
}
// The window's own caption buttons, in their order from the left at the right edge of the title bar.
Caption_Button :: enum u8 {
	Minimize,
	Maximize,
	Close,
}
// Title bar geometry in 96-DPI pixels. The native hit test and the drawn caption both read it, so the
// buttons Windows reports and the buttons the app draws stay the same.
TITLE_BAR_HEIGHT :: 40
CAPTION_BUTTON_WIDTH :: 46
CAPTION_WIDTH :: CAPTION_BUTTON_WIDTH * len(Caption_Button)
// A window's restored rectangle in workspace coordinates, and whether it is maximized over it.
Window_Placement :: struct {
	left, top, right, bottom: i32,
	maximized:                bool,
}
// Names the target a notification click reports back; 0 means no target.
Notification_Token :: distinct u32
// Taskbar button progress. Paused and Error tint the bar; Indeterminate has no value.
Progress_State :: enum {
	None,
	Indeterminate,
	Normal,
	Paused,
	Error,
}
Cursor_Shape :: enum {
	Arrow,
	Text,
	Hand,
	Resize_Horizontal,
	Resize_Vertical,
	Resize_Northwest_Southeast,
	Resize_Northeast_Southwest,
	Resize_All,
	Hidden,
}
Tray_Menu_Item :: struct {
	id:                  u32,
	title:               string,
	disabled, separator: bool,
}
Resize_Event :: struct {
	window:        input.Window_Id,
	width, height: i32,
}
Dpi_Event :: struct {
	window: input.Window_Id,
	dpi:    u32,
}
Focus_Event :: struct {
	window:  input.Window_Id,
	focused: bool,
}
Mouse_Leave_Event :: struct {
	window: input.Window_Id,
}
Capture_Lost_Event :: struct {
	window: input.Window_Id,
}
Close_Request_Event :: struct {
	window: input.Window_Id,
}
Tray_Event :: struct {}
Tray_Menu_Event :: struct {
	id: u32,
}
// A click on a native notification raised by tray_notify, carrying back the token it was given.
Tray_Notification_Event :: struct {
	token: Notification_Token,
}
Notification_Error_Event :: struct {
	code: u32,
}
Activate_Request_Event :: struct {}
Settings_Event :: struct {}
Wake_Event :: struct {}
Event :: union {
	input.Key_Event,
	input.Text_Event,
	input.Mouse_Button_Event,
	input.Mouse_Move_Event,
	Mouse_Leave_Event,
	input.Mouse_Wheel_Event,
	Resize_Event,
	Dpi_Event,
	Focus_Event,
	Capture_Lost_Event,
	Close_Request_Event,
	Tray_Event,
	Tray_Menu_Event,
	Tray_Notification_Event,
	Notification_Error_Event,
	Activate_Request_Event,
	Settings_Event,
	Wake_Event,
}

@(require_results)
clipboard_crlf :: proc(text: string, out: []u8) -> (string, bool) {
	n := 0
	for c, i in transmute([]u8)text {
		if c == '\n' && (i == 0 || text[i - 1] != '\r') {
			if n == len(out) {return "", false}
			out[n] = '\r'
			n += 1
		}
		if n == len(out) {return "", false}
		out[n] = c
		n += 1
	}
	return string(out[:n]), true
}
