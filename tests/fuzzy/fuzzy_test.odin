package fuzzy_test

import "core:math"
import "core:testing"
import "aio:fuzzy"

@(private="file")
scratch :: proc(t: ^testing.T) -> ^fuzzy.Scratch {
	s, err := new(fuzzy.Scratch)
	if err != nil {testing.fail_now(t, "scratch allocation failed")}
	return s
}

@(test)
positions_follow_the_matched_characters :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	positions: [8]int
	result, err := fuzzy.match_positions("rs", "Restart Shell", positions[:], s)
	testing.expect_value(t, err, fuzzy.Error.None)
	testing.expect(t, result.matched && result.scored)
	testing.expect_value(t, positions[0], 0)
	testing.expect_value(t, positions[1], 8)
}

@(test)
a_spread_match_scores_below_a_prefix_match :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	positions: [8]int
	strong, err := fuzzy.match_positions("rs", "Restart Shell", positions[:], s)
	testing.expect_value(t, err, fuzzy.Error.None)
	weak, weak_error := fuzzy.score("rs", "reverse", s)
	testing.expect_value(t, weak_error, fuzzy.Error.None)
	testing.expect(t, strong.score > weak.score)
}

@(test)
exact_case_insensitive_query_scores_infinite :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	exact, err := fuzzy.score("QUIT", "quit", s)
	testing.expect_value(t, err, fuzzy.Error.None)
	testing.expect(t, math.is_inf(exact.score, 1))
}

@(test)
separator_and_camel_case_boundaries_score_higher :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	positions: [8]int
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
}

@(test)
a_consecutive_run_wins_over_a_scattered_one :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	positions: [8]int
	result, err := fuzzy.match_positions("abc", "axbyc abc", positions[:], s)
	testing.expect_value(t, err, fuzzy.Error.None)
	testing.expect(t, result.matched)
	testing.expect_value(t, positions[0], 6)
	testing.expect_value(t, positions[1], 7)
	testing.expect_value(t, positions[2], 8)
}

@(test)
unicode_folding_matches_across_forms :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	positions: [4]int
	result, err := fuzzy.match_positions("kσé", "KςÉ", positions[:], s)
	testing.expect_value(t, err, fuzzy.Error.None)
	testing.expect(t, result.matched)
	testing.expect_value(t, positions[0], 0)
	testing.expect_value(t, positions[1], 3)
	testing.expect_value(t, positions[2], 5)
}

@(test)
invalid_utf8_at_either_side_is_reported :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	_, invalid_query := fuzzy.score("\xff", "abc", s)
	testing.expect_value(t, invalid_query, fuzzy.Error.Invalid_UTF8)
	_, invalid_candidate := fuzzy.score("", "\xff", s)
	testing.expect_value(t, invalid_candidate, fuzzy.Error.Invalid_UTF8)
}

@(test)
a_short_output_buffer_is_reported :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	positions: [4]int
	candidates := [?]string{"Restart Shell", "Reload Settings", "Restart Shell", "Quit"}
	ranked: [4]fuzzy.Ranked
	_, short_positions := fuzzy.match_positions("ab", "abc", positions[:1], s)
	testing.expect_value(t, short_positions, fuzzy.Error.Output_Too_Small)
	_, short_ranking := fuzzy.rank("", candidates[:], ranked[:1], s)
	testing.expect_value(t, short_ranking, fuzzy.Error.Output_Too_Small)
}

@(test)
missing_query_characters_never_match :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	for candidate in ([?]string{"", "a", "ba", "xyz"}) {
		missing, missing_error := fuzzy.score("ab", candidate, s)
		testing.expect_value(t, missing_error, fuzzy.Error.None)
		testing.expect(t, !missing.matched)
	}
}

@(test)
ranking_orders_by_score_and_keeps_equal_scores_in_place :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	candidates := [?]string{"Restart Shell", "Reload Settings", "Restart Shell", "Quit"}
	ranked: [4]fuzzy.Ranked
	count, err := fuzzy.rank("rs", candidates[:], ranked[:], s)
	testing.expect_value(t, err, fuzzy.Error.None)
	testing.expect_value(t, count, 3)
	testing.expect_value(t, ranked[0].index, 0)
	testing.expect_value(t, ranked[1].index, 2)
	count, err = fuzzy.rank("", candidates[:], ranked[:], s)
	testing.expect_value(t, err, fuzzy.Error.None)
	testing.expect_value(t, count, 4)
	for item, index in ranked {testing.expect_value(t, item.index, index)}
	_, invalid_query := fuzzy.rank("\xff", nil, nil, s)
	testing.expect_value(t, invalid_query, fuzzy.Error.Invalid_UTF8)
}

@(test)
long_candidates_stop_scoring_but_still_match :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	long: [fuzzy.MAX_SCORED_RUNES + 1]u8
	for &byte in long {byte = 'a'}
	positions: [fuzzy.MAX_SCORED_RUNES + 1]int
	bounded, bounded_error := fuzzy.match_positions("aa", string(long[:len(long) - 1]), positions[:], s)
	testing.expect_value(t, bounded_error, fuzzy.Error.None)
	testing.expect(t, bounded.matched && bounded.scored)
	fallback, fallback_error := fuzzy.match_positions(string(long[:]), string(long[:]), positions[:], s)
	testing.expect_value(t, fallback_error, fuzzy.Error.None)
	testing.expect(t, fallback.matched && !fallback.scored)
	for offset, index in positions {testing.expect_value(t, offset, index)}
	missing, missing_error := fuzzy.score("b", string(long[:]), s)
	testing.expect_value(t, missing_error, fuzzy.Error.None)
	testing.expect(t, !missing.matched)
}

// The matcher must agree with an exhaustive oracle on every six-rune candidate over this
// alphabet: the oracle tries every ordered choice of three matching positions and keeps the
// best score under the published bonus and gap rules.
@(test)
optimal_traceback_matches_an_exhaustive_oracle :: proc(t: ^testing.T) {
	s := scratch(t)
	defer free(s)
	positions: [3]int
	alphabet := "ab _"
	query := "aba"
	for bits in 0 ..< 4096 {
		candidate: [6]u8
		code := bits
		for &byte in candidate {
			byte = alphabet[code % 4]
			code /= 4
		}
		best := fuzzy.NO_SCORE
		for first in 0 ..< 6 {
			for second in first + 1 ..< 6 {
				for third in second + 1 ..< 6 {
					if candidate[first] != 'a' ||
					   candidate[second] != 'b' ||
					   candidate[third] != 'a' {continue}
					chosen := [3]int{first, second, third}
					value := -0.005 * f64(first)
					for position, index in chosen {
						bonus: f64 = 0
						if position == 0 {
							bonus = 0.9
						} else if candidate[position - 1] == ' ' ||
						   candidate[position - 1] == '_' {
							bonus = 0.8
						}
						if index > 0 {
							gap := position - chosen[index - 1] - 1
							if gap == 0 {
								bonus = 1
							} else {
								value -= 0.01 * f64(gap)
							}
						}
						value += bonus
					}
					value -= 0.005 * f64(5 - third)
					best = max(best, value)
				}
			}
		}
		result, err := fuzzy.match_positions(query, string(candidate[:]), positions[:], s)
		testing.expect_value(t, err, fuzzy.Error.None)
		testing.expect_value(t, result.matched, best > fuzzy.NO_SCORE / 2)
		if !result.matched {continue}
		testing.expect(t, abs(result.score - best) < 1e-10)
		value := -0.005 * f64(positions[0])
		for position, index in positions {
			testing.expect_value(t, candidate[position], query[index])
			bonus: f64 = 0
			if position == 0 {
				bonus = 0.9
			} else if candidate[position - 1] == ' ' ||
			   candidate[position - 1] == '_' {
				bonus = 0.8
			}
			if index > 0 {
				gap := position - positions[index - 1] - 1
				testing.expect(t, gap >= 0)
				if gap == 0 {
					bonus = 1
				} else {
					value -= 0.01 * f64(gap)
				}
			}
			value += bonus
		}
		value -= 0.005 * f64(5 - positions[2])
		testing.expect(t, abs(value - best) < 1e-10)
	}
}
