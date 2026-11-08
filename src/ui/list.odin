package ui

import "aio:input"

// The Ctrl chords that step a list besides the arrows, and the keycaps hints name them by.
LIST_PREVIOUS_KEY :: input.Key.P
LIST_NEXT_KEY :: input.Key.N
LIST_PREVIOUS_LABEL :: "Ctrl+P"
LIST_NEXT_LABEL :: "Ctrl+N"

// Callers supply logical keys and own wrapping, clamping and paging.
list_step :: proc(e: input.Key_Event) -> int {
	if !e.pressed {return 0}
	control := .Control in e.modifiers && .Alt not_in e.modifiers
	switch {
	case e.key == .Arrow_Up:
		return -1
	case e.key == .Arrow_Down:
		return 1
	case control && e.key == LIST_PREVIOUS_KEY:
		return -1
	case control && e.key == LIST_NEXT_KEY:
		return 1
	}
	return 0
}
