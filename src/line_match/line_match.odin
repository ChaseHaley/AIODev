package line_match

import "aio:search"
import "base:runtime"
import "core:strings"
import "core:text/regex"
import "core:unicode/utf8"

// Find's matching rules for one line of text at a time, shared by every searchable surface.

Init_Result :: enum u8 {
	Ok,
	// The regular expression does not compile.
	Invalid,
	Out_Of_Memory,
}

Matcher :: struct {
	options:   search.Options,
	// Lowered when matching literal text without case sensitivity.
	needle:    string,
	iterator:  regex.Match_Iterator,
	compiled:  bool,
	allocator: runtime.Allocator,
	line:      string,
	offset:    int,
	finished:  bool,
}

@(require_results)
init :: proc(
	m: ^Matcher,
	needle: string,
	options: search.Options,
	allocator := context.allocator,
) -> Init_Result {
	m^ = {}
	m.options, m.allocator = options, allocator
	copied, err := strings.clone(needle, allocator)
	if err != nil {return .Out_Of_Memory}
	m.needle = copied
	if !options.regex {
		if !options.case_sensitive {
			for &c in transmute([]u8)m.needle {c = ascii_lower(c)}
		}
		return .Ok
	}
	flags: regex.Flags = {.Unicode}
	if !options.case_sensitive {flags += {.Case_Insensitive}}
	iterator, compile_error := regex.create_iterator("", needle, flags, allocator)
	if compile_error != nil {return .Invalid}
	m.iterator, m.compiled = iterator, true
	return .Ok
}

destroy :: proc(m: ^Matcher) {
	if m.compiled {regex.destroy_iterator(m.iterator, m.allocator)}
	delete(m.needle, m.allocator)
	m^ = {}
}

// Starts on a line, which must outlive the calls to next that follow.
begin :: proc(m: ^Matcher, line: string) {
	m.line, m.offset, m.finished = line, 0, false
	if m.compiled {
		m.iterator.vm.memory = line
		regex.reset(&m.iterator)
	}
}

// The next match's byte range in the line. Matches never overlap and are never empty.
@(require_results)
next :: proc(m: ^Matcher) -> (first, end: int, ok: bool) {
	if m.finished {return 0, 0, false}
	if m.compiled {return next_expression(m)}
	if len(m.needle) == 0 {return 0, 0, false}
	found := -1
	if m.options.case_sensitive {
		found = strings.index(m.line[m.offset:], m.needle)
	} else {
		found = index_ascii_fold(m.line[m.offset:], m.needle)
	}
	if found < 0 {
		m.finished = true
		return 0, 0, false
	}
	first = m.offset + found
	end = first + len(m.needle)
	m.offset = end
	return first, end, true
}

@(private, require_results)
next_expression :: proc(m: ^Matcher) -> (first, end: int, ok: bool) {
	it := &m.iterator
	for {
		capture, _, matched := regex.match_iterator(it)
		if !matched {
			m.finished = true
			return 0, 0, false
		}
		found := len(capture.pos) > 0 && capture.pos[0][1] > capture.pos[0][0]
		if found {first, end = capture.pos[0][0], capture.pos[0][1]}
		if it.done {
			// The iterator stops after an empty match; resume one character later so `a*` still finds "aa".
			at := it.vm.string_pointer
			if at >= len(m.line) {
				m.finished = true
			} else {
				previous, size := utf8.decode_rune_in_string(m.line[at:])
				it.done = false
				it.vm.string_pointer = at + size
				it.vm.last_rune = previous
			}
		}
		if found {return first, end, true}
		if m.finished {return 0, 0, false}
	}
}

@(private)
ascii_lower :: proc(c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c
}

// `lowered` is already lower case. Folding ASCII alone keeps multi-byte characters intact.
@(private, require_results)
index_ascii_fold :: proc(text, lowered: string) -> int {
	for start := 0; start + len(lowered) <= len(text); start += 1 {
		same := true
		for i in 0 ..< len(lowered) {
			if ascii_lower(text[start + i]) != lowered[i] {
				same = false
				break
			}
		}
		if same {return start}
	}
	return -1
}
