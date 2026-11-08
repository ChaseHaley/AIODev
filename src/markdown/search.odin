package markdown

import "aio:line_match"
import "aio:search"
import "core:log"
import "core:strings"
import "core:time"

// Find in a document: the plain text it reads as, a line at a time, as terminal find reads a screen.

// A match in Document.text.
Match :: struct {
	start, end: int,
}

// Where a search stands. The matcher holds a needle in every phase but Off and Failed.
Search_Phase :: enum u8 {
	Off,
	// The regular expression does not compile.
	Invalid,
	// A pass reads the document from `next`, publishing matches as it finds them.
	Scanning,
	Complete,
	// Memory ran out; the search holds no needle and no matches.
	Failed,
}

// Lives beside the document it searches and is told when that document changes. Only the procedures in
// this file write it.
Search :: struct {
	phase:    Search_Phase,
	matcher:  line_match.Matcher,
	// In document order, published as the pass finds them.
	matches:  [dynamic]Match,
	// Index into matches, or -1.
	selected: int,
	// While scanning, where the selected match started before a reload, or -1.
	keep:     int,
	next:     int,
	// Changes when a pass finishes, so the window redraws.
	revision: int,
}

search_destroy :: proc(s: ^Search) {
	line_match.destroy(&s.matcher)
	delete(s.matches)
	s^ = {}
}

// Starts a search from the top of the document; an empty needle ends it.
search_set :: proc(s: ^Search, needle: string, options: search.Options = {}) {
	line_match.destroy(&s.matcher)
	clear(&s.matches)
	s.phase = .Off
	s.selected, s.keep, s.next = -1, -1, 0
	s.revision += 1
	if len(needle) == 0 {return}
	switch line_match.init(&s.matcher, needle, options) {
	case .Out_Of_Memory:
		log.error("markdown: copying the search text failed")
		s.phase = .Failed
	case .Invalid:
		s.phase = .Invalid
	case .Ok:
		s.phase = .Scanning
	}
}

// Searches a reloaded document again, keeping the selection on the same match or the next one.
search_restart :: proc(s: ^Search) {
	if s.phase != .Scanning && s.phase != .Complete {return}
	s.keep = -1
	if s.selected >= 0 && s.selected < len(s.matches) {s.keep = s.matches[s.selected].start}
	clear(&s.matches)
	s.phase, s.selected, s.next = .Scanning, -1, 0
}

search_pending :: proc(s: ^Search) -> bool {
	return s.phase == .Scanning
}

// Advances the pass for a bounded time, so a long document never stalls a frame. Running out of memory
// ends the search rather than presenting part of the document's matches as all of them.
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
				search_fail(s)
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
	s.phase = .Complete
	s.revision += 1
	if s.keep < 0 {return}
	index := search_first_after(s.matches[:], s.keep)
	s.selected = min(index, len(s.matches) - 1)
	s.keep = -1
}

@(private)
search_fail :: proc(s: ^Search) {
	line_match.destroy(&s.matcher)
	clear(&s.matches)
	s.phase = .Failed
	s.selected, s.keep = -1, -1
	s.revision += 1
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
// With none selected, stepping down starts at the first match and up at the last. False when there is
// nothing to select.
@(require_results)
search_select :: proc(s: ^Search, upward: bool) -> bool {
	total := len(s.matches)
	if total == 0 {return false}
	s.selected = search.step_index(s.selected, total, upward)
	s.keep = -1
	return true
}

// What the find bar shows, counted from the first line down. A document that is not `shown` has
// nothing to find, whatever it last searched.
search_summary :: proc(s: ^Search, shown: bool) -> search.Summary {
	summary := search.Summary {
		selected = -1,
		order    = .Document_Order,
	}
	switch s.phase {
	case .Off:
		return summary
	case .Invalid:
		summary.progress = .Invalid
	case .Scanning:
		summary.progress = .Searching
	case .Complete:
		summary.progress = .Complete
	case .Failed:
		summary.progress = .Failed
	}
	if !shown {
		if summary.progress == .Searching {summary.progress = .Complete}
		return summary
	}
	summary.total, summary.selected, summary.revision = len(s.matches), s.selected, s.revision
	return summary
}
