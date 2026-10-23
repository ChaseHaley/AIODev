package font_test

import "core:testing"
import "aio:font"

// A 10 point font at 96 and 144 DPI. The fallback decision is one per run and never reads the
// size, so it must reach the same face at both scales.
FALLBACK_DPI_SIZES :: [2]f32{f32(10) * f32(96) / 72, f32(10) * f32(144) / 72}

// DirectWrite maps the emoji and stops at the letter, so no single face covers this cluster.
// Lookup and shaping must agree: each rune draws from the face lookup picks on its own, which
// are different faces, instead of the whole cluster drawing from the face that mapped first.
@(test)
fallback_partial_mapping_uses_per_rune_faces :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) { return }
	defer font.system_destroy(s)
	family, load_err := font.family_load(s, "Consolas")
	if !testing.expect_value(t, load_err, font.Error.None) { return }
	out := make([dynamic]font.Shaped_Glyph)
	defer delete(out)
	run := [2]rune{0x1f600, 'a'}
	clusters := [2]int{0, 0}
	for size in FALLBACK_DPI_SIZES {
		clear(&out)
		if !testing.expect_value(t, font.shape(s, family, .Regular, run[:], size, &out, clusters[:]), font.Error.None) {
			continue
		}
		if !testing.expect_value(t, len(out), len(run)) { continue }
		for g, i in out {
			plain, found := font.glyph_lookup(s, family, .Regular, run[i])
			testing.expect(t, found)
			testing.expect_value(t, g.cluster, 0)
			testing.expect_value(t, g.glyph, plain)
			testing.expect(t, abs(g.advance - font.glyph_advance(s, plain, size)) < 0.001)
		}
		testing.expect(t, out[0].glyph.face != out[1].glyph.face)
	}
}

// A keycap the text family covers only partly. Because the cluster asks for emoji presentation,
// the mapping is taken from the system emoji family, which covers all three units, and the
// whole cluster draws as one glyph there at every scale.
@(test)
fallback_emoji_cluster_uses_emoji_face :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) { return }
	defer font.system_destroy(s)
	family, load_err := font.family_load(s, "Consolas")
	if !testing.expect_value(t, load_err, font.Error.None) { return }
	emoji, emoji_err := font.family_load(s, "Segoe UI Emoji")
	if !testing.expect_value(t, emoji_err, font.Error.None) { return }
	out := make([dynamic]font.Shaped_Glyph)
	defer delete(out)
	run := [3]rune{'1', 0xfe0f, 0x20e3}
	clusters := [3]int{0, 0, 0}
	for size in FALLBACK_DPI_SIZES {
		clear(&out)
		if !testing.expect_value(t, font.shape(s, family, .Regular, run[:], size, &out, clusters[:]), font.Error.None) {
			continue
		}
		if !testing.expect_value(t, len(out), 1) { continue }
		testing.expect_value(t, out[0].cluster, 0)
		testing.expect_value(t, out[0].glyph.face, emoji.faces[.Regular])
		testing.expect(t, out[0].glyph.face != family.faces[.Regular])
		testing.expect(t, abs(out[0].advance - font.glyph_advance(s, out[0].glyph, size)) < 0.001)
	}
}
