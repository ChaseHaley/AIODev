package settings

import "base:runtime"
import "core:fmt"
import "core:strings"

// The most items an ordered list (profiles, link programs) holds; sizes the scratch of ordering.
@(private)
ORDER_LIMIT :: PROFILE_LIMIT

// Why a list mutation such as profile_mutate returned no revision.
Mutation_Error :: enum {None, Unavailable, Limit, Edit, Allocation}

// Sets `key` in the owned revision `text`; a refusal returns edit_text's owned message as `issue`.
@(private, require_results)
mutation_edit :: proc(
	text: ^string,
	key, value: string,
	allocator: runtime.Allocator,
) -> (issue: string, error: Mutation_Error) {
	message, alloc_error := revision_edit_owned(text, key, value, allocator)
	if alloc_error != nil {return "", .Allocation}
	if message != "" {return message, .Edit}
	return
}

// One entry of an order value such as profile.order: trimmed, possibly empty. `repeated` means an
// earlier entry has the same text.
@(private)
Order_Token :: struct {
	id:              string,
	valid, repeated: bool,
}

// Steps through the comma-separated entries of an order value without allocating; `offset` starts
// at 0. Every entry, empty ones included, is returned so each caller applies its own policy.
@(private)
order_token_next :: proc(text: string, offset: ^int) -> (token: Order_Token, ok: bool) {
	start := offset^
	if start > len(text) {return {}, false}
	end := strings.index_byte(text[start:], ',')
	end = end < 0 ? len(text) : start + end
	offset^ = end + 1
	token.id = strings.trim_space(text[start:end])
	token.valid = id_valid(token.id, PROFILE_ID_MAX_LENGTH)
	for from := 0; from < start; {
		comma := from + strings.index_byte(text[from:], ',')
		token.repeated ||= strings.trim_space(text[from:comma]) == token.id
		from = comma + 1
	}
	return token, true
}

// Parses the order line `key` of a list of `noun`s into `order`. File parsing diagnoses and drops
// malformed or repeated IDs and keeps the rest; `order_line` remembers the line for duplicates.
@(private, require_results)
parse_order :: proc(
	order: ^[dynamic]string,
	order_line: ^int,
	allocator: runtime.Allocator,
	key, noun, value: string,
	line: int,
	diagnostics: ^[dynamic]Diagnostic,
) -> runtime.Allocator_Error {
	if order_line^ > 0 {
		duplicate_key_diagnostic(diagnostics, key, line) or_return
	}
	order_line^ = line
	for id in order {delete(id, allocator)}
	clear(order)
	offset := 0
	for token in order_token_next(value, &offset) {
		if token.id == "" {continue}
		if !token.valid {
			diagnostic_append(
				diagnostics,
				line,
				key,
				fmt.tprintf("invalid %s ID in order; use lowercase letters, digits, - and _", noun),
			) or_return
			continue
		}
		if token.repeated {
			duplicate_key_diagnostic(diagnostics, key, line) or_return
			continue
		}
		owned := strings.clone(token.id, allocator) or_return
		if _, append_error := append(order, owned); append_error != nil {
			delete(owned, allocator)
			return append_error
		}
	}
	return nil
}

// Fills `out` with indices into `items`: the IDs `order` lists first, then unlisted IDs sorted by
// ID. Items `keep` rejects are skipped. Returns the number written; `out` must hold at least
// len(items) entries.
@(private)
items_in_order :: proc(items: []$T, order: []string, out: []int, keep: proc(item: ^T) -> bool) -> int {
	count := 0
	used: [ORDER_LIMIT]bool
	for id in order {
		for &item, index in items {
			if item.id != id || used[index] {continue}
			used[index] = true
			if keep != nil && !keep(&item) {continue}
			if count < len(out) {
				out[count] = index
				count += 1
			}
		}
	}
	pending: [ORDER_LIMIT]int
	pending_count := 0
	for &item, index in items {
		if used[index] {continue}
		if keep != nil && !keep(&item) {continue}
		insert := pending_count
		for insert > 0 && text_less(item.id, items[pending[insert - 1]].id) {
			pending[insert] = pending[insert - 1]
			insert -= 1
		}
		pending[insert] = index
		pending_count += 1
	}
	for index in pending[:pending_count] {
		if count >= len(out) {break}
		out[count] = index
		count += 1
	}
	return count
}

@(private)
text_less :: proc(a, b: string) -> bool {
	for i in 0 ..< min(len(a), len(b)) {
		if a[i] != b[i] {return a[i] < b[i]}
	}
	return len(a) < len(b)
}

// Whether `id` already has an explicit place in `order`.
@(private)
order_has :: proc(order: []string, id: string) -> bool {
	for known in order {
		if known == id {return true}
	}
	return false
}

// Moves the item at `from` into the gap before `to`, which is indexed in `ids` before the move.
// `out` receives the reordered IDs and must hold at least len(ids) entries.
order_move :: proc(ids: []string, from, to: int, out: []string) -> []string {
	count := min(len(ids), len(out))
	if count == 0 {return out[:0]}
	index := clamp(from, 0, count - 1)
	slot := clamp(to, 0, count)
	if slot > index {slot -= 1}
	written := 0
	for id, i in ids[:count] {
		if i == index {continue}
		if written == slot {
			out[written] = ids[index]
			written += 1
		}
		out[written] = id
		written += 1
	}
	if written < count {
		out[written] = ids[index]
		written += 1
	}
	return out[:written]
}

// The order text after a move: the given IDs in order, then every other ID in `others` that is
// not already listed. Stale IDs are dropped because nothing reads them.
@(require_results)
order_text :: proc(
	ids, others: []string,
	allocator := context.allocator,
) -> (
	text: string,
	alloc_error: runtime.Allocator_Error,
) {
	builder := strings.builder_make(allocator) or_return
	defer strings.builder_destroy(&builder)
	first := true
	for id in ids {
		if id == "" {continue}
		if !first {
			if write_error := write_parts(&builder, ", "); write_error != nil {
				return "", write_error
			}
		}
		if write_error := write_parts(&builder, id); write_error != nil {return "", write_error}
		first = false
	}
	for id in others {
		if id == "" {continue}
		listed := false
		for known in ids {listed ||= known == id}
		if listed {continue}
		if !first {
			if write_error := write_parts(&builder, ", "); write_error != nil {
				return "", write_error
			}
		}
		if write_error := write_parts(&builder, id); write_error != nil {return "", write_error}
		first = false
	}
	return strings.clone(strings.to_string(builder), allocator)
}

// Interactive order edits are all or nothing: any empty, malformed or repeated entry refuses them.
@(private)
order_text_valid :: proc(text: string) -> bool {
	offset := 0
	for token in order_token_next(text, &offset) {
		if !token.valid || token.repeated {return false}
	}
	return true
}

// Removes every PREFIX.ID.* line, such as one profile's, while preserving comments, BOM and line
// endings.
@(require_results)
remove_item_text :: proc(
	text, prefix, id: string,
	allocator := context.allocator,
) -> (
	string,
	runtime.Allocator_Error,
) {
	builder, build_error := strings.builder_make(allocator)
	if build_error != nil {return "", build_error}
	defer strings.builder_destroy(&builder)
	scanner := line_scanner_init(text)
	if scanner.bom {
		if err := write_parts(&builder, UTF8_BOM); err != nil {return "", err}
	}
	key_prefix := fmt.tprintf("%s%s.", prefix, id)
	for {
		line, ok := line_next(&scanner)
		if !ok {break}
		if line.split && strings.has_prefix(line.key, key_prefix) {continue}
		if err := write_parts(&builder, line.raw); err != nil {return "", err}
	}
	return strings.clone(strings.to_string(builder), allocator)
}
