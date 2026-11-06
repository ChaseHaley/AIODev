package markdown

import "aio:line_match"
import "core:log"
import "core:strings"
import "core:time"

// Find in a document: the plain text it reads as, a line at a time, as terminal find reads a screen.

// A match in Document.text.
Match :: struct {
	start, end: int,
}

// Lives beside the document it searches and is told when that document changes.
Search :: struct {
	active, invalid: bool,
	// A pass has reached the end of the document.
	complete:        bool,
	matcher:         line_match.Matcher,
	// In document order, published as the pass finds them.
	matches:         [dynamic]Match,
	// Index into matches, or -1.
	selected:        int,
	// Where the selected match started before a reload, or -1.
	keep:            int,
	next:            int,
	// Changes when a pass finishes, so the window redraws.
	revision:        int,
}

search_destroy :: proc(s: ^Search) {
	line_match.destroy(&s.matcher)
	delete(s.matches)
	s^ = {}
}

// Starts a search from the top of the document; an empty needle ends it.
search_set :: proc(s: ^Search, needle: string, options: line_match.Options = {}) {
	line_match.destroy(&s.matcher)
	clear(&s.matches)
	s.active, s.invalid, s.complete = false, false, false
	s.selected, s.keep, s.next = -1, -1, 0
	s.revision += 1
	if len(needle) == 0 {return}
	switch line_match.init(&s.matcher, needle, options) {
	case .Out_Of_Memory:
		log.error("markdown: copying the search text failed")
	case .Invalid:
		s.active, s.invalid = true, true
	case .Ok:
		s.active = true
	}
}

// Searches a reloaded document again, keeping the selection on the same match or the next one.
search_restart :: proc(s: ^Search) {
	if !s.active || s.invalid {return}
	s.keep = -1
	if s.selected >= 0 && s.selected < len(s.matches) {s.keep = s.matches[s.selected].start}
	clear(&s.matches)
	s.complete, s.selected, s.next = false, -1, 0
}

search_pending :: proc(s: ^Search) -> bool {
	return s.active && !s.invalid && !s.complete
}

// Advances the pass for a bounded time, so a long document never stalls a frame.
search_update :: proc(s: ^Search, doc: ^Document, budget: time.Duration) {
	if !search_pending(s) {return}
	text := string(doc.text[:])
	start := time.tick_now()
	for s.next < len(text) {
		line := text[s.next:]
		if end := strings.index_byte(line, '\n'); end >= 0 {line = line[:end]}
		line_match.begin(&s.matcher, line)
		for {
			first, end, found := line_match.next(&s.matcher)
			if !found {break}
			if _, err := append(&s.matches, Match{s.next + first, s.next + end}); err != nil {
				log.error("markdown: storing a search match failed")
				search_finish(s)
				return
			}
		}
		s.next += len(line) + 1
		if time.tick_since(start) >= budget {return}
	}
	search_finish(s)
}

@(private)
search_finish :: proc(s: ^Search) {
	s.complete = true
	s.revision += 1
	if s.keep < 0 {return}
	index := search_first_after(s.matches[:], s.keep)
	s.selected = min(index, len(s.matches) - 1)
	s.keep = -1
}

// The first match that starts at or after `offset`.
@(private)
search_first_after :: proc(matches: []Match, offset: int) -> int {
	low, high := 0, len(matches)
	for low < high {
		middle := (low + high) / 2
		if matches[middle].start < offset {low = middle + 1} else {high = middle}
	}
	return low
}

// Selects the next match toward the top of the document, or toward the bottom, wrapping at either end.
// As in a terminal, the first step up lands on the last match. False when there is nothing to select.
@(require_results)
search_select :: proc(s: ^Search, upward: bool) -> bool {
	total := len(s.matches)
	if !s.active || total == 0 {return false}
	switch {
	case s.selected < 0 || s.selected >= total:
		s.selected = upward ? total - 1 : 0
	case upward:
		s.selected = (s.selected - 1 + total) % total
	case:
		s.selected = (s.selected + 1) % total
	}
	s.keep = -1
	return true
}
