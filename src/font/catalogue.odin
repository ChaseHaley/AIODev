package font

import "core:slice"
import "core:strings"

// Portable discovery data. The System owns names; callers borrow the catalogue.
Family_Info :: struct {
	name:       string,
	monospaced: bool,
}

// The returned temporary list borrows names and preserves a saved value even when
// that family is unavailable or hidden by the monospaced filter.
family_choices :: proc(items: []Family_Info, all: bool, current: string) -> []string {
	choices := make([dynamic]string, context.temp_allocator)
	found := false
	for item in items {
		if !all && !item.monospaced && item.name != current {continue}
		append(&choices, item.name)
		if item.name == current {found = true}
	}
	if !found && current != "" {append(&choices, current)}
	slice.sort_by(choices[:], proc(a, b: string) -> bool {
		return strings.compare(strings.to_lower(a, context.temp_allocator),
		                       strings.to_lower(b, context.temp_allocator)) < 0
	})
	return choices[:]
}
