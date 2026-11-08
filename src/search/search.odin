package search

import "core:time"

// What every searchable surface shows in the find bar and how a step moves its selection. Each surface
// keeps its own scanner: a terminal refreshes live output under its lock, a document scans an immutable
// text and restarts after a reload.

Options :: struct {
	case_sensitive, regex: bool,
}

Progress :: enum u8 {
	Off,
	Searching,
	Complete,
	// The regular expression does not compile.
	Invalid,
	// The search stopped with no matches, such as when memory ran out.
	Failed,
}

// How a surface counts its matches, which is also the way Next reads.
Order :: enum u8 {
	// A terminal reads from its newest line up.
	Newest_First,
	// A document reads from its first line down.
	Document_Order,
}

// Next and Previous follow the reading order (Enter and Shift+Enter); Up and Down are directions on
// screen (the bar's arrows), whatever the order.
Step :: enum u8 {
	Next,
	Previous,
	Up,
	Down,
}

Summary :: struct {
	progress: Progress,
	total:    int,
	// Position of the selected match counted in `order`, or -1 when none is selected.
	selected: int,
	// Changes when a refresh moves the scanner's results without changing the counts.
	revision: int,
	order:    Order,
}

// How long one frame may spend scanning, so a long search never stalls drawing.
STEP_BUDGET :: 2 * time.Millisecond

// Whether `step` moves the selection up the screen for a surface counting in `order`.
moves_up :: proc(order: Order, step: Step) -> bool {
	switch step {
	case .Up:
		return true
	case .Down:
		return false
	case .Next:
		return order == .Newest_First
	case .Previous:
		return order == .Document_Order
	}
	return false
}

// The index a step selects among `total` matches, wrapping at either end. With none selected,
// stepping back starts at the last match and forward at the first. Needs total > 0.
step_index :: proc(selected, total: int, back: bool) -> int {
	switch {
	case selected < 0 || selected >= total:
		return back ? total - 1 : 0
	case back:
		return (selected - 1 + total) % total
	}
	return (selected + 1) % total
}
