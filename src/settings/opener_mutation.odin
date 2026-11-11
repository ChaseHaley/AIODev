package settings

import "base:runtime"
import "core:fmt"
import "core:strings"

Opener_Mutation_Kind :: enum {Add, Remove, Move}

// Add ignores `id`; Move places `id` in the gap before `slot`, counted in display order.
Opener_Mutation :: struct {
	kind: Opener_Mutation_Kind,
	id:   string,
	slot: int,
}

// What Add writes: a working program the owner then edits.
OPENER_NEW_NAME :: "New Program"
OPENER_NEW_COMMAND :: "notepad.exe %1"

// The resolved programs are those `source` parses to. All returned strings are owned; failures
// return no revision, so fields and order are published together.
@(require_results)
opener_mutate :: proc(
	source: string,
	openers: ^Openers,
	change: Opener_Mutation,
	allocator := context.allocator,
) -> (updated, id, issue: string, error: Mutation_Error) {
	if change.kind != .Add && opener_find(openers, change.id) == nil {return "", "", "", .Unavailable}
	if change.kind == .Add && len(openers.items) >= OPENER_LIMIT {return "", "", "", .Limit}

	target := change.id
	if change.kind == .Add {
		// A program the file names without a name or command line was dropped from `openers`,
		// yet its lines remain; a new program never inherits them.
		for number := 1; ; number += 1 {
			target = fmt.tprintf("program-%d", number)
			if opener_find(openers, target) == nil && !item_text_has(source, OPENER_PREFIX, target) {break}
		}
	}
	revision: string
	alloc_error: runtime.Allocator_Error
	if change.kind == .Remove {
		revision, alloc_error = remove_item_text(source, OPENER_PREFIX, target, allocator)
	} else {
		revision, alloc_error = strings.clone(source, allocator)
	}
	if alloc_error != nil {return "", "", "", .Allocation}
	defer delete(revision, allocator)
	if change.kind == .Add {
		placements := OPENER_PLACEMENT_NAME
		values := [Opener_Field]string {
			.Name      = OPENER_NEW_NAME,
			.Command   = OPENER_NEW_COMMAND,
			.Offers    = opener_link_names[.Files],
			.Placement = placements[.Own_Window],
		}
		for value, field in values {
			if issue, error = mutation_edit(&revision, opener_field_key(target, field), value, allocator);
			   error != .None {return "", "", issue, error}
		}
	}
	indices: [OPENER_LIMIT]int
	ordered, moved: [OPENER_LIMIT]string
	written, from := 0, -1
	for index in indices[:openers_in_order(openers, indices[:])] {
		item := &openers.items[index]
		if change.kind == .Remove && item.id == target {continue}
		if item.id == target {from = written}
		ordered[written] = item.id
		written += 1
	}
	if change.kind == .Add {
		ordered[written] = target
		written += 1
	}
	order := ordered[:written]
	if change.kind == .Move {order = order_move(order, from, change.slot, moved[:])}
	if len(order) == 0 {
		// Removing the last program leaves no order to keep, and an empty one is not an edit.
		emptied, empty_error := remove_key_text(revision, OPENER_ORDER_KEY, allocator)
		if empty_error != nil {return "", "", "", .Allocation}
		delete(revision, allocator)
		revision = emptied
	} else {
		order_value, order_error := order_text(order, nil, allocator)
		defer delete(order_value, allocator)
		if order_error != nil {return "", "", "", .Allocation}
		if issue, error = mutation_edit(&revision, OPENER_ORDER_KEY, order_value, allocator); error != .None {
			return "", "", issue, error
		}
	}
	id, alloc_error = strings.clone(target, allocator)
	if alloc_error != nil {return "", "", "", .Allocation}
	updated, revision = revision, ""
	return
}
