package term_view_test

import "core:testing"
import "aio:render"
import "aio:term_view"

@(test)
minimum_contrast_preserves_readable_pairs_and_fixes_application_colors :: proc(t: ^testing.T) {
	for background in ([?]render.Color{{1, 1, 1, 1}, {0, 0, 0, 1}, {0.5, 0.5, 0.5, 1}}) {
		for foreground in ([?]render.Color{{1, 1, 1, 1}, {0.9, 0.9, 0.9, 1}, {1, 1, 0, 1},
			{0.3, 0.6, 0.9, 1}, {0, 0, 0, 0.5}, {0, 0, 0, 1}}) {
			original := term_view.contrast_ratio(foreground, background)
			adjusted := term_view.minimum_contrast(foreground, background, 4.5)
			testing.expect(t, term_view.contrast_ratio(adjusted, background) >= 4.499)
			if original >= 4.5 { testing.expect_value(t, adjusted, foreground) }
			testing.expect_value(t, term_view.minimum_contrast(foreground, background, 1), foreground)
		}
	}
	for foreground in ([?]render.Color{{0.2, 0.4, 0.6, 1}, {0.8, 0.7, 0.6, 1}}) {
		background := render.Color{0.5, 0.5, 0.5, 1}
		adjusted := term_view.minimum_contrast(foreground, background, 21)
		testing.expect(t, adjusted == render.Color{0, 0, 0, 1} || adjusted == render.Color{1, 1, 1, 1})
	}
}
