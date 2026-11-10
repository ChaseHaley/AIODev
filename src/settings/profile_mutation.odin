package settings

import "base:runtime"
import "core:fmt"
import "core:strings"

Profile_Mutation_Kind :: enum {Add, Duplicate, Remove, Move}

Profile_Mutation :: struct {
	kind: Profile_Mutation_Kind,
	id:   string,
	slot: int,
}

// The resolved profiles include cached detection for this source. All returned strings are owned;
// failures return no revision, so fields, order and default repair are published together.
@(require_results)
profile_mutate :: proc(
	source: string,
	profiles: ^Profiles,
	change: Profile_Mutation,
	allocator := context.allocator,
) -> (updated, id, issue: string, error: Mutation_Error) {
	profile := profile_find(profiles, change.id)
	if change.kind != .Add && profile == nil {return "", "", "", .Unavailable}
	if (change.kind == .Add || change.kind == .Duplicate) && len(profiles.items) >= PROFILE_LIMIT {
		return "", "", "", .Limit
	}
	if change.kind == .Remove && !profile_can_remove(profile) {
		return "", "", "", .Unavailable
	}

	target := change.id
	if change.kind == .Add || change.kind == .Duplicate {
		for number := 1; ; number += 1 {
			target = fmt.tprintf("profile-%d", number)
			if profile_find(profiles, target) == nil {break}
		}
	}
	revision: string
	alloc_error: runtime.Allocator_Error
	if change.kind == .Remove {
		revision, alloc_error = remove_item_text(source, PROFILE_PREFIX, target, allocator)
	} else {
		revision, alloc_error = strings.clone(source, allocator)
	}
	if alloc_error != nil {return "", "", "", .Allocation}
	defer delete(revision, allocator)
	if change.kind == .Add || change.kind == .Duplicate {
		values := Profile {
			name = "New Profile", command = DEFAULT_PROFILE_COMMAND, directory = DEFAULT_PROFILE_DIRECTORY,
		}
		fields := bit_set[Profile_Field]{.Name, .Command, .Directory}
		if change.kind != .Add {
			values = profile^
			fields += {.Hidden}
			if change.kind == .Duplicate {values.name = fmt.tprintf("%s copy", profile.name)}
		}
		if change.kind == .Duplicate && values.icon != "" {fields += {.Icon}}
		base := values.name
		for number := 2; profile_name_taken(profiles, "", values.name); number += 1 {
			values.name = fmt.tprintf("%s %d", base, number)
		}
		// The order new lines are appended in.
		for field in ([?]Profile_Field{.Name, .Command, .Directory, .Hidden, .Icon}) {
			if field not_in fields {continue}
			value := field == .Hidden ? "false" : profile_text(&values, field)^
			if issue, error = mutation_edit(
				&revision, profile_field_key(target, field), value, allocator,
			); error != .None {
				return "", "", issue, error
			}
		}
	}
	indices: [PROFILE_LIMIT]int
	ordered, moved: [PROFILE_LIMIT]string
	count := profiles_in_order(profiles, indices[:])
	written, from := 0, -1
	for index in indices[:count] {
		item := &profiles.items[index]
		if change.kind == .Remove && item.id == target {continue}
		if item.detected && change.kind != .Move && !profile_order_has(profiles, item.id) {continue}
		if item.id == target {from = written}
		ordered[written] = item.id
		written += 1
		if change.kind == .Duplicate && item.id == change.id {
			ordered[written] = target
			written += 1
			from = written - 1
		}
	}
	if (change.kind == .Add || change.kind == .Duplicate) && from < 0 {
		ordered[written] = target
		written += 1
	}
	order := ordered[:written]
	if change.kind == .Move {order = order_move(order, from, change.slot, moved[:])}
	order_value, order_error := order_text(order, nil, allocator)
	defer delete(order_value, allocator)
	if order_error != nil {return "", "", "", .Allocation}
	if issue, error = mutation_edit(&revision, PROFILE_ORDER_KEY, order_value, allocator);
	   error != .None {return "", "", issue, error}
	if change.kind == .Remove && profiles.default_id == target {
		if issue, error = mutation_edit(
			&revision, "shell.default_profile", PROFILE_DEFAULT_ID, allocator,
		); error != .None {return "", "", issue, error}
	}
	id, alloc_error = strings.clone(target, allocator)
	if alloc_error != nil {return "", "", "", .Allocation}
	updated, revision = revision, ""
	return
}
