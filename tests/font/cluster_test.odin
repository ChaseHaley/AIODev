package font_test

import "core:slice"
import "core:testing"
import "aio:font"
import "aio:ghostty"
import fixtures "../fixtures"

// Splits runes into grapheme clusters with the terminal's own rules, as term_view receives them.
terminal_clusters :: proc(runes: []rune) -> []int {
	ids := make([]int, len(runes), context.temp_allocator)
	cps := make([]u32, len(runes), context.temp_allocator)
	for r, i in runes { cps[i] = u32(r) }
	id := 0
	for i := 0; i < len(cps); id += 1 {
		rest := cps[i:]
		n := int(ghostty.unicode_grapheme_width(raw_data(rest), uint(len(rest)), nil))
		for j in i..<i + n { ids[j] = id }
		i += n
	}
	return ids
}

// Every fixture shapes without error, each glyph reports the first rune of its cluster, and a
// cluster the primary face fully displays stays in the primary face.
@(test)
fixture_clusters_shape :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) { return }
	defer font.system_destroy(s)
	family, load_err := font.family_load(s, "Cascadia Mono")
	if !testing.expect_value(t, load_err, font.Error.None) { return }
	cases, parse_err := fixtures.unicode_cases()
	defer fixtures.unicode_cases_destroy(cases)
	if !testing.expect_value(t, parse_err, "") { return }
	out := make([dynamic]font.Shaped_Glyph)
	defer delete(out)
	for c in cases {
		clusters := terminal_clusters(c.stored)
		clear(&out)
		if !testing.expectf(t, font.shape(s, family, .Regular, c.stored, 20, &out, clusters) == .None, "%s: shaping failed", c.id) {
			continue
		}
		for g in out {
			testing.expectf(t, g.glyph.index != 0, "%s: drew .notdef", c.id)
			testing.expectf(t, g.cluster == 0 || clusters[g.cluster] != clusters[g.cluster - 1],
				"%s: glyph names rune %d, inside a cluster", c.id, g.cluster)
		}
	}
	for text in ([][]rune{{'e', 0x301}, {'a', 0x200d}, {'a', 0x30a, 0x323}}) {
		clear(&out)
		testing.expect_value(t, font.shape(s, family, .Regular, text, 20, &out, terminal_clusters(text)), font.Error.None)
		for g in out {
			testing.expectf(t, g.glyph.face == family.faces[.Regular], "%v left the primary face", text)
		}
	}
}

// Emoji sequences shape whole in the system emoji font: one glyph for a sequence the font
// ligates, even when the primary face has a text glyph for the base character.
@(test)
emoji_sequences_use_emoji_font :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) { return }
	defer font.system_destroy(s)
	family, load_err := font.family_load(s, "Cascadia Mono")
	if !testing.expect_value(t, load_err, font.Error.None) { return }
	emoji, emoji_err := font.family_load(s, "Segoe UI Emoji")
	if !testing.expect_value(t, emoji_err, font.Error.None) { return }
	cases, parse_err := fixtures.unicode_cases()
	defer fixtures.unicode_cases_destroy(cases)
	if !testing.expect_value(t, parse_err, "") { return }
	single := []string{
		"emoji.default", "emoji.vs16", "emoji.smiley-vs16", "emoji.keycap", "emoji.skin-tone",
		"emoji.zwj-profession", "emoji.zwj-rainbow-flag", "emoji.tag-sequence",
	}
	// Windows has no flag glyphs; Segoe UI Emoji draws the two regional indicator letters.
	same_font := []string{"emoji.zwj-family", "emoji.flag", "emoji.flag-pair"}
	out := make([dynamic]font.Shaped_Glyph)
	defer delete(out)
	checked := 0
	for c in cases {
		one := slice.contains(single, c.id)
		if !one && !slice.contains(same_font, c.id) { continue }
		checked += 1
		clear(&out)
		testing.expect_value(t, font.shape(s, family, .Regular, c.stored, 20, &out, terminal_clusters(c.stored)), font.Error.None)
		if one {
			testing.expectf(t, len(out) == 1, "%s: %d glyphs, expected one", c.id, len(out))
		}
		testing.expectf(t, len(out) > 0, "%s: drew nothing", c.id)
		for g in out {
			testing.expectf(t, g.glyph.face == emoji.faces[.Regular], "%s: glyph from face %v, not the emoji font", c.id, g.glyph.face)
		}
	}
	testing.expect_value(t, checked, len(single) + len(same_font))
	// VS15 asks for text presentation, so the primary face keeps a character it covers.
	text := []rune{0x263a, 0xfe0e}
	clear(&out)
	testing.expect_value(t, font.shape(s, family, .Regular, text, 20, &out, terminal_clusters(text)), font.Error.None)
	testing.expect(t, len(out) > 0 && out[0].glyph.face == family.faces[.Regular])
}
