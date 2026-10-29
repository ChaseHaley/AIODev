package settings

import "base:runtime"
import "core:fmt"
import "core:strings"

Profile_Mutation_Kind :: enum {Add, Duplicate, Enable, Remove, Move}

Profile_Mutation :: struct {
	kind: Profile_Mutation_Kind,
	id:   string,
	slot: int,
}

Profile_Mutation_Error :: enum {None, Unavailable, Limit, Edit, Allocation}

// The resolved profiles include cached detection for this source. All returned strings are owned;
// failures return no revision, so fields, order and default repair are published together.
@(require_results)
profile_mutate :: proc(
	source: string,
	profiles: ^Profiles,
	change: Profile_Mutation,
	allocator := context.allocator,
) -> (updated, id, issue: string, error: Profile_Mutation_Error) {
	profile := profile_find(profiles, change.id)
	if change.kind != .Add && profile == nil {return "", "", "", .Unavailable}
	if (change.kind == .Add || change.kind == .Duplicate) && len(profiles.items) >= PROFILE_LIMIT {
		return "", "", "", .Limit
	}
	if change.kind == .Enable && !profile.detected {return "", "", "", .Unavailable}
	if change.kind == .Remove && (profile.id == PROFILE_DEFAULT_ID || profile.detected) {
		return "", "", "", .Unavailable
	}
	if change.kind == .Move && profile.detected {return "", "", "", .Unavailable}
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
		revision, alloc_error = remove_profile_text(source, target, allocator)
	} else {
		revision, alloc_error = strings.clone(source, allocator)
	}
	if alloc_error != nil {return "", "", "", .Allocation}
	defer delete(revision, allocator)
	if change.kind == .Add || change.kind == .Duplicate || change.kind == .Enable {
		values := Profile {
			name = "New Profile", command = DEFAULT_PROFILE_COMMAND, directory = DEFAULT_PROFILE_DIRECTORY,
		}
		count := 3
		if change.kind != .Add {
			values = profile^
			count = 4
			if change.kind == .Duplicate {values.name = fmt.tprintf("%s copy", profile.name)}
		}
		pairs := [5][2]string {
			{"name", values.name}, {"command", values.command}, {"directory", values.directory},
			{"hidden", "false"}, {"icon", values.icon},
		}
		if change.kind == .Duplicate && values.icon != "" {count = 5}
		for pair in pairs[:count] {
			key := fmt.tprintf("profile.%s.%s", target, pair[0])
			if issue, error = profile_mutation_edit(&revision, key, pair[1], allocator); error != .None {
				return "", "", issue, error
			}
		}
	}
	indices: [PROFILE_LIMIT]int
	ordered, detected, moved: [PROFILE_LIMIT]string
	count := profiles_in_order(profiles, indices[:])
	written, other_count, from := 0, 0, -1
	for index in indices[:count] {
		item := &profiles.items[index]
		if change.kind == .Remove && item.id == target {continue}
		if item.detected {
			if change.kind == .Move {
				if profile_order_has(profiles, item.id) {
					detected[other_count] = item.id
					other_count += 1
				}
				continue
			}
			if !(change.kind == .Enable && item.id == target) && !profile_order_has(profiles, item.id) {
				continue
			}
		}
		if item.id == target {from = written}
		ordered[written] = item.id
		written += 1
		if change.kind == .Duplicate && item.id == change.id {
			ordered[written] = target
			written += 1
			from = written - 1
		}
	}
	if (change.kind == .Add || change.kind == .Duplicate || change.kind == .Enable) && from < 0 {
		ordered[written] = target
		written += 1
	}
	order := ordered[:written]
	if change.kind == .Move {order = profile_move(order, from, change.slot, moved[:])}
	order_text, order_error := profile_order_text(order, detected[:other_count], allocator)
	defer delete(order_text, allocator)
	if order_error != nil {return "", "", "", .Allocation}
	if issue, error = profile_mutation_edit(&revision, PROFILE_ORDER_KEY, order_text, allocator);
	   error != .None {return "", "", issue, error}
	if change.kind == .Remove && profiles.default_id == target {
		if issue, error = profile_mutation_edit(
			&revision, "shell.default_profile", PROFILE_DEFAULT_ID, allocator,
		); error != .None {return "", "", issue, error}
	}
	id, alloc_error = strings.clone(target, allocator)
	if alloc_error != nil {return "", "", "", .Allocation}
	updated, revision = revision, ""
	return
}

@(private, require_results)
profile_mutation_edit :: proc(
	text: ^string,
	key, value: string,
	allocator: runtime.Allocator,
) -> (issue: string, error: Profile_Mutation_Error) {
	updated, message, alloc_error := edit_text(text^, key, value, allocator)
	if alloc_error != nil {
		delete(updated, allocator)
		delete(message, allocator)
		return "", .Allocation
	}
	if message != "" {
		delete(updated, allocator)
		return message, .Edit
	}
	delete(message, allocator)
	delete(text^, allocator)
	text^ = updated
	return
}
