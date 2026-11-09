package term_view_test

import "core:slice"
import "core:testing"

// With the bundled fonts on WARP, a screen of text, a fallback character, an emoji and colours
// draws to the same bytes every time, in a fresh font system and device each time.
@(test)
bundled_fonts_on_warp_render_identical_bytes :: proc(t: ^testing.T) {
	SCREEN :: "\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[31mred\x1b[0m\r\n" +
		"\u03b1\u03b2\u03b3 \U0001f600 \x1b[44m->\x1b[0m"
	frames: [2][]u8
	defer for pixels in frames {delete(pixels)}
	for &pixels in frames {
		f, ok := headless_create(t)
		defer fixture_destroy(&f)
		if !ok {return}
		write(&f, SCREEN)
		_, rendered := render_frame(t, &f, {family = f.family})
		pixels = slice.clone(rendered)
	}
	drawn := false
	for i := 0; i < len(frames[0]); i += 4 {
		if frames[0][i] != 0 || frames[0][i + 1] != 0 || frames[0][i + 2] != 0 {drawn = true; break}
	}
	testing.expect(t, drawn, "the screen drew nothing")
	testing.expect(t, slice.equal(frames[0], frames[1]), "two renders differ")
}
