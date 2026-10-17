package fuzzy_test

import "core:math"
import "core:testing"
import "aio:fuzzy"

@(test)
scoring_and_positions :: proc(t: ^testing.T) {
	s, allocation_error := new(fuzzy.Scratch)
	if allocation_error != nil { testing.fail_now(t, "scratch allocation failed") }
	defer free(s)
	positions: [8]int
	result, err := fuzzy.match_positions("rs", "Restart Shell", positions[:], s)
	testing.expect_value(t, err, fuzzy.Error.None)
	testing.expect(t, result.matched && result.scored)
	testing.expect_value(t, positions[0], 0)
	testing.expect_value(t, positions[1], 8)
	weak, weak_error := fuzzy.score("rs", "reverse", s)
	testing.expect_value(t, weak_error, fuzzy.Error.None)
	testing.expect(t, result.score > weak.score)
	exact, exact_error := fuzzy.score("QUIT", "quit", s)
	testing.expect_value(t, exact_error, fuzzy.Error.None)
	testing.expect(t, math.is_inf(exact.score, 1))
	for separator in " _-./\\" {
		candidate := [3]u8{'a', u8(separator), 'b'}
		boundary, boundary_error := fuzzy.score("b", string(candidate[:]), s)
		inner, inner_error := fuzzy.score("b", "aab", s)
		testing.expect_value(t, boundary_error, fuzzy.Error.None)
		testing.expect_value(t, inner_error, fuzzy.Error.None)
		testing.expect(t, boundary.score > inner.score)
	}
	camel, camel_error := fuzzy.match_positions("fb", "fooBar", positions[:], s)
	testing.expect_value(t, camel_error, fuzzy.Error.None)
	testing.expect(t, camel.matched)
	testing.expect_value(t, positions[1], 3)
	consecutive, consecutive_error := fuzzy.match_positions("abc", "axbyc abc", positions[:], s)
	testing.expect_value(t, consecutive_error, fuzzy.Error.None)
	testing.expect(t, consecutive.matched)
	testing.expect_value(t, positions[0], 6)
	testing.expect_value(t, positions[1], 7)
	testing.expect_value(t, positions[2], 8)
}

@(test)
unicode_and_errors :: proc(t: ^testing.T) {
	s, allocation_error := new(fuzzy.Scratch)
	if allocation_error != nil { testing.fail_now(t, "scratch allocation failed") }
	defer free(s)
	positions: [4]int
	result, err := fuzzy.match_positions("kσé", "KςÉ", positions[:], s)
	testing.expect_value(t, err, fuzzy.Error.None)
	testing.expect(t, result.matched)
	testing.expect_value(t, positions[0], 0)
	testing.expect_value(t, positions[1], 3)
	testing.expect_value(t, positions[2], 5)
	_, invalid := fuzzy.score("\xff", "abc", s)
	testing.expect_value(t, invalid, fuzzy.Error.Invalid_UTF8)
	_, invalid_candidate := fuzzy.score("", "\xff", s)
	testing.expect_value(t, invalid_candidate, fuzzy.Error.Invalid_UTF8)
	_, short := fuzzy.match_positions("ab", "abc", positions[:1], s)
	testing.expect_value(t, short, fuzzy.Error.Output_Too_Small)
	for candidate in ([?]string{"", "a", "ba", "xyz"}) {
		missing, missing_error := fuzzy.score("ab", candidate, s)
		testing.expect_value(t, missing_error, fuzzy.Error.None)
		testing.expect(t, !missing.matched)
	}
}

@(test)
ranking_and_bound :: proc(t: ^testing.T) {
	s, allocation_error := new(fuzzy.Scratch)
	if allocation_error != nil { testing.fail_now(t, "scratch allocation failed") }
	defer free(s)
	candidates := [?]string{"Restart Shell", "Reload Settings", "Restart Shell", "Quit"}
	out: [4]fuzzy.Ranked
	count, err := fuzzy.rank("rs", candidates[:], out[:], s)
	testing.expect_value(t, err, fuzzy.Error.None)
	testing.expect_value(t, count, 3)
	testing.expect_value(t, out[0].index, 0)
	testing.expect_value(t, out[1].index, 2)
	count, err = fuzzy.rank("", candidates[:], out[:], s)
	testing.expect_value(t, err, fuzzy.Error.None)
	testing.expect_value(t, count, 4)
	for item, index in out { testing.expect_value(t, item.index, index) }
	_, invalid_query := fuzzy.rank("\xff", nil, nil, s)
	testing.expect_value(t, invalid_query, fuzzy.Error.Invalid_UTF8)
	_, short := fuzzy.rank("", candidates[:], out[:1], s)
	testing.expect_value(t, short, fuzzy.Error.Output_Too_Small)
	long: [fuzzy.MAX_SCORED_RUNES+1]u8
	for &byte in long { byte = 'a' }
	positions: [fuzzy.MAX_SCORED_RUNES+1]int
	bounded, bounded_error := fuzzy.match_positions("aa", string(long[:len(long)-1]), positions[:], s)
	testing.expect_value(t, bounded_error, fuzzy.Error.None)
	testing.expect(t, bounded.matched && bounded.scored)
	fallback, fallback_error := fuzzy.match_positions(string(long[:]), string(long[:]), positions[:], s)
	testing.expect_value(t, fallback_error, fuzzy.Error.None)
	testing.expect(t, fallback.matched && !fallback.scored)
	for offset, index in positions { testing.expect_value(t, offset, index) }
	missing, missing_error := fuzzy.score("b", string(long[:]), s)
	testing.expect_value(t, missing_error, fuzzy.Error.None)
	testing.expect(t, !missing.matched)
}

@(test)
optimal_traceback :: proc(t: ^testing.T) {
	s, allocation_error := new(fuzzy.Scratch)
	if allocation_error != nil { testing.fail_now(t, "scratch allocation failed") }
	defer free(s)
	positions: [3]int
	alphabet := "ab _"
	query := "aba"
	for bits in 0..<4096 {
		candidate: [6]u8
		code := bits
		for &byte in candidate {
			byte = alphabet[code%4]
			code /= 4
		}
		best := fuzzy.NO_SCORE
		for a in 0..<6 {
			for b in a+1..<6 {
				for c in b+1..<6 {
					if candidate[a] != 'a' || candidate[b] != 'b' || candidate[c] != 'a' { continue }
					chosen := [3]int{a, b, c}
					value := -0.005*f64(a)
					for position, index in chosen {
						bonus: f64 = 0
						if position == 0 {
							bonus = 0.9
						} else if candidate[position-1] == ' ' || candidate[position-1] == '_' {
							bonus = 0.8
						}
						if index > 0 {
							gap := position-chosen[index-1]-1
							if gap == 0 {
								bonus = 1
							} else {
								value -= 0.01*f64(gap)
							}
						}
						value += bonus
					}
					value -= 0.005*f64(5-c)
					best = max(best, value)
				}
			}
		}
		result, err := fuzzy.match_positions("aba", string(candidate[:]), positions[:], s)
		testing.expect_value(t, err, fuzzy.Error.None)
		testing.expect_value(t, result.matched, best > fuzzy.NO_SCORE/2)
		if !result.matched { continue }
		testing.expect(t, abs(result.score-best) < 1e-10)
		value := -0.005*f64(positions[0])
		for position, index in positions {
			testing.expect_value(t, candidate[position], query[index])
			bonus: f64 = 0
			if position == 0 {
				bonus = 0.9
			} else if candidate[position-1] == ' ' || candidate[position-1] == '_' {
				bonus = 0.8
			}
			if index > 0 {
				gap := position-positions[index-1]-1
				testing.expect(t, gap >= 0)
				if gap == 0 {
					bonus = 1
				} else {
					value -= 0.01*f64(gap)
				}
			}
			value += bonus
		}
		value -= 0.005*f64(5-positions[2])
		testing.expect(t, abs(value-best) < 1e-10)
	}
}
