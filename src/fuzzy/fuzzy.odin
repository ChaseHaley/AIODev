package fuzzy

import "core:math"
import "core:unicode"
import "core:unicode/utf8"

MAX_SCORED_RUNES :: 256
NO_SCORE :: -1.0e30
Error :: enum {
	None,
	Invalid_UTF8,
	Output_Too_Small,
}
Result :: struct {
	score:   f64,
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

@(private)
fold :: proc(r: rune) -> rune {
	result := r
	for next := unicode.simple_fold(r); next != r; next = unicode.simple_fold(next) {
		result = min(result, next)
	}
	return result
}

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
	if unicode.is_lower(previous) && unicode.is_upper(current) {
		return 0.7
	}
	return 0
}

@(require_results)
score :: proc(query, candidate: string, scratch: ^Scratch) -> (Result, Error) {
	return evaluate(query, candidate, nil, scratch)
}

@(require_results)
match_positions :: proc(
	query, candidate: string,
	out: []int,
	scratch: ^Scratch,
) -> (
	Result,
	Error,
) {
	if len(out) < utf8.rune_count(query) {
		return {}, .Output_Too_Small
	}
	return evaluate(query, candidate, out, scratch)
}

@(private, require_results)
evaluate :: proc(query, candidate: string, out: []int, s: ^Scratch) -> (Result, Error) {
	if !utf8.valid_string(query) || !utf8.valid_string(candidate) {
		return {}, .Invalid_UTF8
	}
	m, n := utf8.rune_count(query), utf8.rune_count(candidate)
	if m == 0 {
		return {0, true, true}, .None
	}
	if m > n {
		return {}, .None
	}
	if n > MAX_SCORED_RUNES {
		q, count := 0, 0
		for r, offset in candidate {
			wanted, size := utf8.decode_rune(query[q:])
			if fold(r) == fold(wanted) {
				if out != nil {
					out[count] = offset
				}
				count += 1
				q += size
				if q == len(query) {return {NO_SCORE, true, false}, .None}
			}
		}
		return {}, .None
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
	if value <= NO_SCORE / 2 {return {}, .None}
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
	if m == n {
		value = math.inf_f64(1)
	}
	return {value, true, true}, .None
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
