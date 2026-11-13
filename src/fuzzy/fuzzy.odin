package fuzzy

import "core:math"
import "core:unicode"
import "core:unicode/utf8"

// The palette's and Settings' one matcher. A field first gets a match class, the explainable answer to
// "how does this text contain the query": exact, prefix, substring, word starts, scattered letters. The
// class costs one pass over the field with no allocation and rejects most fields at once. Only a field
// that matches is scored, fzy style: a dynamic program over the field rewards consecutive letters and
// letters at word starts and charges for gaps, so it ranks fields within one class.
MAX_SCORED_RUNES :: 256
NO_SCORE :: -1.0e30
// The word-start class tracks every query prefix in one machine word: bit k of a state means the first
// k query runes are matched. A longer query is never a word-start match.
@(private)
MAX_WORDS_RUNES :: 63

Error :: enum {
	None,
	Invalid_UTF8,
	Output_Too_Small,
}

// Best first. Words: the query is a sequence of pieces, each starting at a word start of the field, in
// order, so "c1" is the start of "card" then "1" in "(card 1) foo" and "rs" is "Restart Shell". A word
// starts the field, follows a space or punctuation, changes between letter and digit, or is a camel
// hump; punctuation itself starts a piece too, so a typed separator never breaks the run. Scattered:
// the query's runes appear in order anywhere.
Class :: enum u8 {
	Exact,
	Prefix,
	Substring,
	Words,
	Scattered,
	None,
}

Result :: struct {
	score:   f64,
	class:   Class,
	matched: bool,
	scored:  bool,
}

Ranked :: struct {
	index: int,
	score: f64,
}

Scratch :: struct {
	matches, gaps:      [MAX_SCORED_RUNES][MAX_SCORED_RUNES]f64,
	candidate, pattern: [MAX_SCORED_RUNES]rune,
	offsets:            [MAX_SCORED_RUNES]int,
	bonuses:            [MAX_SCORED_RUNES]f64,
}

// One representative of each simple case-folding orbit; ASCII skips the Unicode tables.
@(private)
fold :: proc(r: rune) -> rune {
	if r < 0x80 {
		return r >= 'a' && r <= 'z' ? r - ('a' - 'A') : r
	}
	result := r
	for next := unicode.simple_fold(r); next != r; next = unicode.simple_fold(next) {
		result = min(result, next)
	}
	return result
}

@(private)
Kind :: enum u8 {
	Other,
	Lower,
	Upper,
	Digit,
}

@(private)
kind :: proc(r: rune) -> Kind {
	switch r {
	case 'a' ..= 'z':
		return .Lower
	case 'A' ..= 'Z':
		return .Upper
	case '0' ..= '9':
		return .Digit
	}
	if r < 0x80 {return .Other}
	if unicode.is_upper(r) {return .Upper}
	if unicode.is_letter(r) {return .Lower}
	if unicode.is_digit(r) {return .Digit}
	return .Other
}

// What starting a match at `current` after `previous` earns. Every positive bonus marks a word start.
@(private)
bonus :: proc(previous, current: rune) -> f64 {
	switch previous {
	case '/', '\\':
		return 0.9
	case ' ', '_', '-':
		return 0.8
	case '.':
		return 0.6
	}
	before, at := kind(previous), kind(current)
	switch {
	case at == .Other:
		return 0
	case before == .Other:
		return 0.8
	case before == .Lower && at == .Upper:
		return 0.7
	case (before == .Digit) != (at == .Digit):
		return 0.7
	}
	return 0
}

// The class of `candidate` for `query`, without scoring. Both must be valid UTF-8.
@(require_results)
classify :: proc(query, candidate: string) -> Class {
	pattern: [MAX_WORDS_RUNES]rune
	m := 0
	for r in query {
		if m == MAX_WORDS_RUNES {return classify_long(query, candidate)}
		pattern[m] = fold(r)
		m += 1
	}
	if m == 0 {return .Prefix}
	// Most fields lack the query's letters in order; one cheap pass turns them away.
	{
		k := 0
		for r in candidate {
			if fold(r) == pattern[k] {
				k += 1
				if k == m {break}
			}
		}
		if k < m {return .None}
	}
	full := u64(1) << uint(m)
	last := u64(1) << uint(m - 1)
	// Shift-and: bit k of `inside` means pattern[:k+1] ends at this rune. `run` holds the query prefixes
	// whose last word-start piece reaches the previous rune, `closed` the ones a new piece may follow.
	inside, run, closed: u64 = 0, 0, 1
	previous: rune
	words := false
	n := 0
	for r, offset in candidate {
		c := fold(r)
		equal: u64
		for k in 0 ..< m {
			if pattern[k] == c {equal |= u64(1) << uint(k)}
		}
		inside = ((inside << 1) | 1) & equal
		if inside & last != 0 {
			if n != m - 1 {return .Substring}
			// The query is the field's start; the field is exact if nothing follows.
			return offset + utf8.rune_size(r) == len(candidate) ? .Exact : .Prefix
		}
		closed |= run
		next := (run & equal) << 1
		if n == 0 || bonus(previous, r) > 0 || kind(r) == .Other {next |= (closed & equal) << 1}
		run = next
		if run & full != 0 {words = true}
		previous = r
		n += 1
	}
	return words ? .Words : .Scattered
}

// A query longer than the word-start state: exact, prefix, substring or scattered only.
@(private)
classify_long :: proc(query, candidate: string) -> Class {
	starts :: proc(value, prefix: string) -> bool {
		v, p := value, prefix
		for len(p) > 0 {
			if len(v) == 0 {return false}
			a, a_size := utf8.decode_rune(v)
			b, b_size := utf8.decode_rune(p)
			if fold(a) != fold(b) {return false}
			v, p = v[a_size:], p[b_size:]
		}
		return true
	}
	if starts(candidate, query) {
		return utf8.rune_count(candidate) == utf8.rune_count(query) ? .Exact : .Prefix
	}
	for _, offset in candidate {
		if offset > 0 && starts(candidate[offset:], query) {return .Substring}
	}
	rest := query
	for r in candidate {
		if len(rest) == 0 {break}
		wanted, size := utf8.decode_rune(rest)
		if fold(r) == fold(wanted) {rest = rest[size:]}
	}
	return len(rest) == 0 ? .Scattered : .None
}

// Classifies and scores `candidate`. A class looser than `loosest` is no match, and is not scored.
@(require_results)
score :: proc(
	query, candidate: string,
	scratch: ^Scratch,
	loosest := Class.Scattered,
) -> (
	Result,
	Error,
) {
	return evaluate(query, candidate, nil, scratch, loosest)
}

@(require_results)
match_positions :: proc(
	query, candidate: string,
	out: []int,
	scratch: ^Scratch,
	loosest := Class.Scattered,
) -> (
	Result,
	Error,
) {
	if len(out) < utf8.rune_count(query) {
		return {class = .None}, .Output_Too_Small
	}
	return evaluate(query, candidate, out, scratch, loosest)
}

@(private, require_results)
evaluate :: proc(query, candidate: string, out: []int, s: ^Scratch, loosest: Class) -> (Result, Error) {
	if !utf8.valid_string(query) || !utf8.valid_string(candidate) {
		return {class = .None}, .Invalid_UTF8
	}
	class := classify(query, candidate)
	if class > loosest {return {class = .None}, .None}
	m, n := utf8.rune_count(query), utf8.rune_count(candidate)
	if m == 0 {
		return {0, class, true, true}, .None
	}
	if n > MAX_SCORED_RUNES {
		if out != nil {
			q, count := 0, 0
			for r, offset in candidate {
				wanted, size := utf8.decode_rune(query[q:])
				if fold(r) == fold(wanted) {
					out[count] = offset
					count += 1
					q += size
					if q == len(query) {break}
				}
			}
		}
		return {NO_SCORE, class, true, false}, .None
	}
	i := 0
	for r in query {
		s.pattern[i] = fold(r)
		i += 1
	}
	previous: rune = '/'
	i = 0
	for r, offset in candidate {
		s.candidate[i] = fold(r)
		s.offsets[i] = offset
		s.bonuses[i] = bonus(previous, r)
		previous = r
		i += 1
	}
	for row in 0 ..< m {
		gap := -0.01
		if row == m - 1 {
			gap = -0.005
		}
		best := NO_SCORE
		for col in 0 ..< n {
			value := NO_SCORE
			if s.pattern[row] == s.candidate[col] {
				if row == 0 {
					value = f64(col) * (-0.005) + s.bonuses[col]
				} else if col > 0 {
					value = max(
						s.gaps[row - 1][col - 1] + s.bonuses[col],
						s.matches[row - 1][col - 1] + 1,
					)
				}
			}
			s.matches[row][col] = value
			best = max(value, best + gap)
			s.gaps[row][col] = best
		}
	}
	value := s.gaps[m - 1][n - 1]
	if out != nil {
		col := n - 1
		consecutive := false
		for row := m - 1; row >= 0; row -= 1 {
			for col >= 0 {
				if s.matches[row][col] > NO_SCORE / 2 &&
				   (consecutive || s.matches[row][col] == s.gaps[row][col]) {
					out[row] = s.offsets[col]
					consecutive =
						row > 0 &&
						col > 0 &&
						s.matches[row][col] == s.matches[row - 1][col - 1] + 1
					col -= 1
					break
				}
				col -= 1
			}
		}
	}
	if class == .Exact {
		value = math.inf_f64(1)
	}
	return {value, class, true, true}, .None
}

@(require_results)
rank :: proc(
	query: string,
	candidates: []string,
	out: []Ranked,
	scratch: ^Scratch,
) -> (
	int,
	Error,
) {
	if !utf8.valid_string(query) {return 0, .Invalid_UTF8}
	if len(out) < len(candidates) {return 0, .Output_Too_Small}
	count := 0
	for candidate, index in candidates {
		result, err := score(query, candidate, scratch)
		if err != .None {return 0, err}
		if !result.matched {continue}
		position := count
		for position > 0 && out[position - 1].score < result.score {
			out[position] = out[position - 1]
			position -= 1
		}
		out[position] = {index, result.score}
		count += 1
	}
	return count, .None
}
