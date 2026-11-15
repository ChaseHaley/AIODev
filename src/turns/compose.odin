package turns

import "core:mem"
import "core:slice"
import "core:strings"

// One file's net change over a run of segments. The strings borrow from the segments.
Composed :: struct {
	worktree:  string,
	path:      string,
	before:    Oid,
	after:     Oid,
	// Something else also changed the file while the run was going on.
	marked:    bool,
	// A selected change is shared with another agent's turn.
	ambiguous: bool,
}

// A file's change inside one segment, found by its place in the segment list.
@(private)
Touch :: struct {
	worktree: string,
	path:     string,
	segment:  int,
	change:   int,
}

// A file touched by the run, with the time span in which an outside change would not be in the run.
@(private)
Span :: struct {
	file:  Composed,
	from:  i64,
	to:    i64,
	// The run of this file's touches in the sorted touch list.
	first: int,
	end:   int,
}

@(private)
has_shared_copy :: proc(touches: []Touch, segments: []Segment, c: Change) -> bool {
	for t in touches {
		own := segments[t.segment].changes[t.change]
		if own.shared && own.before == c.before && own.after == c.after {return true}
	}
	return false
}

// The net change per file over the selected segments (ids, any order). For each (worktree, path) touched
// by a selected segment: before = its before in the earliest selected segment touching it, after = its
// latest one. Ambiguous when any of its selected changes is shared (another agent may have made it).
// Marked when an unselected segment changed the same (worktree, path) after that earliest selected
// change began and before the
// latest selected one ended. Those times are compared strictly, so a Between segment that starts the
// moment a turn ends is not an outside change to it. Entries with before == after are dropped. Sorted
// by worktree then path.
@(require_results)
compose :: proc(
	segments: []Segment,
	selected: []u64,
	allocator := context.allocator,
) -> (
	composed: []Composed,
	err: mem.Allocator_Error,
) {
	ids := slice.clone(selected, allocator) or_return
	defer delete(ids, allocator)
	slice.sort(ids)
	chosen := make([]bool, len(segments), allocator) or_return
	defer delete(chosen, allocator)
	count := 0
	for s, i in segments {
		_, chosen[i] = slice.binary_search(ids, s.id)
		if chosen[i] {count += len(s.changes)}
	}
	if count == 0 {return nil, nil}

	touches := make([dynamic]Touch, 0, count, allocator) or_return
	defer delete(touches)
	for s, i in segments {
		if !chosen[i] {continue}
		for c, j in s.changes {
			append(&touches, Touch{c.worktree, c.path, i, j})
		}
	}
	list := segments
	slice.sort_by_with_data(touches[:], touch_less, &list)

	spans := make([dynamic]Span, 0, count, allocator) or_return
	defer delete(spans)
	for lo := 0; lo < len(touches); {
		hi := lo + 1
		for hi < len(touches) && same_file(touches[hi], touches[lo]) {hi += 1}
		first, last := touches[lo], touches[hi - 1]
		span := Span {
			file = {
				worktree = first.worktree,
				path = first.path,
				before = segments[first.segment].changes[first.change].before,
				after = segments[last.segment].changes[last.change].after,
			},
			from = segments[first.segment].started,
			to = segments[last.segment].ended,
		}
		span.first, span.end = lo, hi
		for t in touches[lo:hi] {
			if segments[t.segment].changes[t.change].shared {span.file.ambiguous = true}
		}
		append(&spans, span)
		lo = hi
	}

	for s, i in segments {
		if chosen[i] {continue}
		for c in s.changes {
			at := span_find(spans[:], c.worktree, c.path)
			if at < 0 {continue}
			if s.ended <= spans[at].from || s.started >= spans[at].to {continue}
			// A shared change is copied into every sharing turn; its copy is not an outside change.
			if c.shared && has_shared_copy(touches[spans[at].first:spans[at].end], segments, c) {continue}
			spans[at].file.marked = true
		}
	}

	net := 0
	for span in spans {
		if span.file.before != span.file.after {net += 1}
	}
	if net == 0 {return nil, nil}
	composed = make([]Composed, net, allocator) or_return
	net = 0
	for span in spans {
		if span.file.before == span.file.after {continue}
		composed[net] = span.file
		net += 1
	}
	return composed, nil
}

@(private)
same_file :: proc(a, b: Touch) -> bool {
	return a.path == b.path && a.worktree == b.worktree
}

@(private)
touch_less :: proc(a, b: Touch, user: rawptr) -> bool {
	if c := strings.compare(a.worktree, b.worktree); c != 0 {return c < 0}
	if c := strings.compare(a.path, b.path); c != 0 {return c < 0}
	if a.segment != b.segment {
		segments := (^[]Segment)(user)^
		x, y := segments[a.segment], segments[b.segment]
		if x.started != y.started {return x.started < y.started}
		if x.ended != y.ended {return x.ended < y.ended}
		if x.id != y.id {return x.id < y.id}
		return a.segment < b.segment
	}
	return a.change < b.change
}

// The index of the span for a file, or -1. Spans are sorted by worktree then path.
@(private)
span_find :: proc(spans: []Span, worktree, path: string) -> int {
	lo, hi := 0, len(spans)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		file := spans[mid].file
		c := strings.compare(file.worktree, worktree)
		if c == 0 {c = strings.compare(file.path, path)}
		switch {
		case c == 0:
			return mid
		case c < 0:
			lo = mid + 1
		case:
			hi = mid
		}
	}
	return -1
}
