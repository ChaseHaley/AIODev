package ui

import "core:strings"

QUERY_HISTORY_LIMIT :: 100

// A search box's earlier queries, oldest first, each with the options it ran with: find's case and regex
// toggles, the palette's mode. Up and Down browse it like a shell prompt.
Query_History :: struct($Options: typeid) {
	entries: [dynamic]Query_Entry(Options),
}

Query_Entry :: struct($Options: typeid) {
	query:   string,
	options: Options,
}

// Browsing a history: the entry the query shows, and what was being typed before browsing began,
// restored by moving past the newest entry. The draft is owned.
Query_Browse :: struct($Options: typeid) {
	index: int,
	draft: Query_Entry(Options),
}

query_history_destroy :: proc(h: ^Query_History($Options)) {
	for entry in h.entries {delete(entry.query)}
	delete(h.entries)
	h^ = {}
}

query_history_newest :: proc(h: ^Query_History($Options)) -> (Query_Entry(Options), bool) {
	if h == nil || len(h.entries) == 0 {return {}, false}
	return h.entries[len(h.entries) - 1], true
}

// Records the query as the newest, moving an earlier copy of it. An empty query is not recorded.
query_history_add :: proc(h: ^Query_History($Options), query: string, options: Options) {
	if h == nil || len(query) == 0 {return}
	if last := len(h.entries) - 1; last >= 0 && h.entries[last].query == query {
		h.entries[last].options = options
		return
	}
	// The copy and its slot come first, so a query that cannot be recorded leaves the history as it was.
	copied, err := strings.clone(query)
	if err != nil {return}
	if reserve(&h.entries, len(h.entries) + 1) != nil {
		delete(copied)
		return
	}
	for entry, i in h.entries {
		if entry.query != query {continue}
		delete(entry.query)
		ordered_remove(&h.entries, i)
		break
	}
	if len(h.entries) >= QUERY_HISTORY_LIMIT {
		delete(h.entries[0].query)
		ordered_remove(&h.entries, 0)
	}
	append(&h.entries, Query_Entry(Options){copied, options})
}

// One Up (`older`) or Down from the entry at `index`, or from the draft when `index` is -1. The first
// step back skips an entry equal to `current`; stepping past the newest entry returns -1, the draft.
// False when the step goes nowhere: no history, before the oldest entry, or Down from the draft.
query_history_step :: proc(
	h: ^Query_History($Options),
	index: int,
	current: string,
	older: bool,
) -> (
	next: int,
	ok: bool,
) {
	if h == nil || len(h.entries) == 0 {return -1, false}
	count := len(h.entries)
	browsing := index >= 0 && index < count
	switch {
	case older && !browsing:
		next = count - 1
		if h.entries[next].query == current {next -= 1}
		return next, next >= 0
	case older:
		return index - 1, index > 0
	case !browsing:
		return -1, false
	case index + 1 < count:
		return index + 1, true
	}
	return -1, true
}
