package main

import "core:unicode/utf8"

// Untrusted text without C0/C1 controls, capped at `limit` bytes on a complete UTF-8 rune.
// Display text keeps replacement runes to show decoding loss; commands dropped into a terminal
// omit them rather than inserting an invalid argument. Callers choose that policy explicitly.
printable_text :: proc(
	text: string,
	limit: int,
	allocator := context.allocator,
	drop_replacement := false,
) -> string {
	bytes := make([dynamic]u8, 0, min(limit, len(text)), allocator)
	for r in text {
		if r < ' ' || r >= 0x7f && r <= 0x9f || drop_replacement && r == utf8.RUNE_ERROR {continue}
		encoded, count := utf8.encode_rune(r)
		if len(bytes) + count > limit {break}
		if _, err := append(&bytes, ..encoded[:count]); err != nil {break}
	}
	return string(bytes[:])
}
