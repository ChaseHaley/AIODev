package turns

import "core:slice"

// A changed block is a removed run followed by an added run. A no-newline marker belongs to the
// preceding side, not to the content being compared. The gaps before `added` and `next` are markers.
diff_change_block :: proc(lines: []Diff_Line, first: int) -> (old_end, added, new_end, next: int) {
	old_end = first
	for old_end < len(lines) && lines[old_end].kind == .Removed {old_end += 1}
	added = change_skip_marker(lines, first, old_end)
	new_end = added
	for new_end < len(lines) && lines[new_end].kind == .Added {new_end += 1}
	next = change_skip_marker(lines, added, new_end)
	return
}

@(private = "file")
change_skip_marker :: proc(lines: []Diff_Line, first, end: int) -> int {
	return end + 1 if end > first && end < len(lines) && lines[end].kind == .No_Newline else end
}

// A highlighted line can have at most one changed range for every two tokens, rounded up.
DIFF_EDIT_RANGE_LIMIT :: 32
@(private = "file")
EDIT_TOKENS :: 2 * DIFF_EDIT_RANGE_LIMIT
@(private = "file")
EDIT_BYTES :: 1024
@(private = "file")
ALIGN_LINES :: 32
@(private = "file")
REFINE_WORK :: 4 * 1024 * 1024

@(private = "file")
Edit_Token :: struct {
	start, end, weight: u16,
}

@(private = "file")
Edit_Line :: struct {
	text: string,
	count, weight: int,
	tokens: [EDIT_TOKENS]Edit_Token,
}

@(private = "file")
Edit_Scratch :: struct {
	old, new: [ALIGN_LINES]Edit_Line,
	words: [EDIT_TOKENS + 1][EDIT_TOKENS + 1]u16,
	pairs: [ALIGN_LINES + 1][ALIGN_LINES + 1]int,
	scores: [ALIGN_LINES][ALIGN_LINES]int,
}

// Refines the parsed patch for display on the worker. Nothing changes the patch's line order or
// numbers. Unmatched and oversized blocks still have their original whole-line diff.
diff_refine :: proc(d: ^Diff) {
	scratch: Edit_Scratch = ---
	edits: [dynamic]Diff_Edit
	ranges: [dynamic]Diff_Range
	edits.allocator = context.allocator
	ranges.allocator = context.allocator
	defer delete(edits)
	defer delete(ranges)
	work := REFINE_WORK
	for &h in d.hunk_slab {
		if len(h.edits) != 0 {continue}
		clear(&edits)
		clear(&ranges)
		for i := 0; i < len(h.lines); {
			if h.lines[i].kind != .Removed {
				i += 1
				continue
			}
			old_end, added, new_end, next := diff_change_block(h.lines, i)
			old, new := h.lines[i:old_end], h.lines[added:new_end]
			if len(new) > 0 && len(old) <= ALIGN_LINES && len(new) <= ALIGN_LINES {
				if !refine_block(&scratch, old, new, i, added, &work, &edits, &ranges) {return}
			}
			i = next
		}
		if len(edits) == 0 {continue}
		kept_edits, edit_err := slice.clone(edits[:], d.allocator)
		if edit_err != nil {return}
		kept_ranges, range_err := slice.clone(ranges[:], d.allocator)
		if range_err != nil {
			delete(kept_edits, d.allocator)
			return
		}
		h.edits, h.edit_ranges = kept_edits, kept_ranges
		if work <= 0 {return}
	}
}

// Spaces do not make two lines similar. Whole words carry more weight than punctuation, and a
// word can only match as a whole. Iterating runes keeps all range boundaries on UTF-8 characters.
@(private = "file")
edit_tokenize :: proc(out: ^Edit_Line, text: string) {
	out.text, out.count, out.weight = text, 0, 0
	if len(text) > EDIT_BYTES {return}
	start, kind := 0, 0
	for r, at in text {
		word := r >= 0x80 || 'a' <= r && r <= 'z' || 'A' <= r && r <= 'Z' || '0' <= r && r <= '9' || r == '_'
		next := 1 if word else (2 if r == ' ' || r == '\t' else 3)
		if at > 0 && (kind != next || kind == 3) {
			if !edit_token_add(out, start, at, kind) {return}
			start = at
		}
		kind = next
	}
	if len(text) > 0 {_ = edit_token_add(out, start, len(text), kind)}
}

@(private = "file", require_results)
edit_token_add :: proc(line: ^Edit_Line, start, end, kind: int) -> bool {
	if line.count == EDIT_TOKENS {
		line.count, line.weight = 0, 0
		return false
	}
	weight := min(end - start, 24) if kind == 1 else (1 if kind == 3 else 0)
	line.tokens[line.count] = {u16(start), u16(end), u16(weight)}
	line.count += 1
	line.weight += weight
	return true
}

@(private = "file")
edit_equal :: proc(a, b: ^Edit_Line, i, j: int) -> bool {
	x, y := a.tokens[i], b.tokens[j]
	return a.text[x.start:x.end] == b.text[y.start:y.end]
}

// A weighted longest common subsequence over lexical tokens. For display, an unchanged space
// between edits is worth keeping; for line alignment it has no weight.
@(private = "file")
edit_words :: proc(s: ^Edit_Scratch, a, b: ^Edit_Line, display: bool) -> int {
	dp := &s.words
	for j in 0 ..= b.count {dp[a.count][j] = 0}
	for i := a.count - 1; i >= 0; i -= 1 {
		dp[i][b.count] = 0
		weight := max(u16(display), a.tokens[i].weight)
		for j := b.count - 1; j >= 0; j -= 1 {
			score := max(dp[i + 1][j], dp[i][j + 1])
			if weight > 0 && edit_equal(a, b, i, j) {score = max(score, weight + dp[i + 1][j + 1])}
			dp[i][j] = score
		}
	}
	return int(dp[0][0])
}

@(private = "file", require_results)
refine_block :: proc(
	s: ^Edit_Scratch, old, new: []Diff_Line, left, right: int, work: ^int,
	edits: ^[dynamic]Diff_Edit, ranges: ^[dynamic]Diff_Range,
) -> bool {
	a, b := len(old), len(new)
	n, m := 0, 0
	for line, i in old {
		edit_tokenize(&s.old[i], line.text)
		n += s.old[i].count
	}
	for line, i in new {
		edit_tokenize(&s.new[i], line.text)
		m += s.new[i].count
	}
	// One pass for all candidate scores and at most one more for their chosen matches.
	cost := a * b + 2 * n * m
	if cost > work^ {return true}
	work^ -= cost
	for j in 0 ..= b {s.pairs[a][j] = 0}
	for i := a - 1; i >= 0; i -= 1 {
		s.pairs[i][b] = 0
		for j := b - 1; j >= 0; j -= 1 {
			x, y := &s.old[i], &s.new[j]
			rank := 0
			if x.count > 0 && y.count > 0 {
				if x.text == y.text {
					rank = 100
				} else if total := x.weight + y.weight; total > 0 {
					rank = 200 * edit_words(s, x, y, false) / total
				}
			}
			// Prefer a strong correspondence to several weak ones and never cross source lines.
			rank = max(0, rank - 45)
			score := rank * rank
			s.scores[i][j] = score
			s.pairs[i][j] = max(s.pairs[i + 1][j], s.pairs[i][j + 1], s.pairs[i + 1][j + 1] + score)
		}
	}
	for i, j := 0, 0; i < a && j < b; {
		score := s.scores[i][j]
		if score > 0 && s.pairs[i][j] == s.pairs[i + 1][j + 1] + score {
			if !refine_edit(s, i, j, left, right, edits, ranges) {return false}
			i, j = i + 1, j + 1
		} else if s.pairs[i + 1][j] > s.pairs[i][j + 1] {
			i += 1
		} else {
			j += 1
		}
	}
	return true
}

@(private = "file", require_results)
refine_edit :: proc(
	s: ^Edit_Scratch, i, j, left, right: int, edits: ^[dynamic]Diff_Edit, ranges: ^[dynamic]Diff_Range,
) -> bool {
	a, b := &s.old[i], &s.new[j]
	start := len(ranges^)
	edit := Diff_Edit{left + i, right + j, start, start, start}
	if a.text != b.text {
		_ = edit_words(s, a, b, true)
		old, new: [DIFF_EDIT_RANGE_LIMIT]Diff_Range
		old_n, new_n, old_at, new_at := 0, 0, 0, 0
		for x, y := 0, 0; x < a.count && y < b.count; {
			u, v := a.tokens[x], b.tokens[y]
			if edit_equal(a, b, x, y) && s.words[x][y] == max(1, u.weight) + s.words[x + 1][y + 1] {
				refine_range(old[:], &old_n, old_at, int(u.start))
				refine_range(new[:], &new_n, new_at, int(v.start))
				old_at, new_at = int(u.end), int(v.end)
				x, y = x + 1, y + 1
			} else if s.words[x + 1][y] > s.words[x][y + 1] {
				x += 1
			} else {
				y += 1
			}
		}
		refine_range(old[:], &old_n, old_at, len(a.text))
		refine_range(new[:], &new_n, new_at, len(b.text))
		if _, err := append(ranges, ..old[:old_n]); err != nil {return false}
		if _, err := append(ranges, ..new[:new_n]); err != nil {return false}
		edit.split, edit.end = start + old_n, start + old_n + new_n
	}
	_, err := append(edits, edit)
	return err == nil
}

@(private = "file")
refine_range :: proc(out: []Diff_Range, n: ^int, start, end: int) {
	if start == end {return}
	out[n^] = {start, end}
	n^ += 1
}
