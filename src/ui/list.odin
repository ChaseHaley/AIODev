package ui

import "aio:platform"

// Callers supply logical keys and own wrapping, clamping and paging.
list_step :: proc(e: platform.Key_Event) -> int {
	if !e.pressed {return 0}
	control := .Control in e.modifiers && .Alt not_in e.modifiers
	#partial switch e.key {
	case .Arrow_Up:
		return -1
	case .Arrow_Down:
		return 1
	case .P:
		if control {return -1}
	case .N:
		if control {return 1}
	}
	return 0
}
