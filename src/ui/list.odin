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

// How far a key moves a list of `count` items showing `visible` rows: list_step's chords by one, Page
// Up and Page Down by a page, Ctrl+Home and Ctrl+End to either end. Plain Home and End are not list
// keys: a search field over the list keeps them for its caret, as every text field does.
list_key_step :: proc(e: input.Key_Event, visible, count: int) -> int {
	if step := list_step(e); step != 0 {return step}
	if !e.pressed {return 0}
	jump := .Control in e.modifiers && .Shift not_in e.modifiers && .Alt not_in e.modifiers
	#partial switch e.key {
	case .Page_Up:
		return -max(1, visible)
	case .Page_Down:
		return max(1, visible)
	case .Home:
		if jump {return -max(1, count)}
	case .End:
		if jump {return max(1, count)}
	}
	return 0
}
