package ghostty

when ODIN_OS == .Windows {
	foreign import lib {"../../vendor/ghostty/ghostty-vt-static.lib", "system:ntdll.lib"}
}

Mouse_Event :: distinct rawptr

Mouse_Action :: enum i32 {
	Press   = 0,
	Release = 1,
	Motion  = 2,
}

Mouse_Button :: enum i32 {
	Unknown = 0,
	Left    = 1,
	Right   = 2,
	Middle  = 3,
	Four    = 4,
	Five    = 5,
	Six     = 6,
	Seven   = 7,
	Eight   = 8,
	Nine    = 9,
	Ten     = 10,
	Eleven  = 11,
}

Mouse_Position :: struct {
	x: f32,
	y: f32,
}

@(default_calling_convention = "c", link_prefix = "ghostty_")
foreign lib {
	@(require_results)
	mouse_event_new :: proc(allocator: ^Allocator, event: ^Mouse_Event) -> Result ---
	mouse_event_free :: proc(event: Mouse_Event) ---
	mouse_event_set_action :: proc(event: Mouse_Event, action: Mouse_Action) ---
	@(require_results)
	mouse_event_get_action :: proc(event: Mouse_Event) -> Mouse_Action ---
	mouse_event_set_button :: proc(event: Mouse_Event, button: Mouse_Button) ---
	mouse_event_clear_button :: proc(event: Mouse_Event) ---
	@(require_results)
	mouse_event_get_button :: proc(event: Mouse_Event, out_button: ^Mouse_Button) -> bool ---
	mouse_event_set_mods :: proc(event: Mouse_Event, mods: Mods) ---
	@(require_results)
	mouse_event_get_mods :: proc(event: Mouse_Event) -> Mods ---
	mouse_event_set_position :: proc(event: Mouse_Event, position: Mouse_Position) ---
	@(require_results)
	mouse_event_get_position :: proc(event: Mouse_Event) -> Mouse_Position ---
}
