package colour_test

import "aio:colour"
import "core:testing"

@(test)
minimum_contrast_preserves_readable_pairs_and_fixes_application_colors :: proc(t: ^testing.T) {
	for background in ([?]colour.RGBA{{1, 1, 1, 1}, {0, 0, 0, 1}, {0.5, 0.5, 0.5, 1}}) {
		for foreground in ([?]colour.RGBA{{1, 1, 1, 1}, {0.9, 0.9, 0.9, 1}, {1, 1, 0, 1},
			{0.3, 0.6, 0.9, 1}, {0, 0, 0, 0.5}, {0, 0, 0, 1}}) {
			original := colour.contrast_ratio(foreground, background)
			adjusted := colour.minimum_contrast(foreground, background, 4.5)
			testing.expect(t, colour.contrast_ratio(adjusted, background) >= 4.499)
			if original >= 4.5 { testing.expect_value(t, adjusted, foreground) }
			testing.expect_value(t, colour.minimum_contrast(foreground, background, 1), foreground)
		}
	}
	for foreground in ([?]colour.RGBA{{0.2, 0.4, 0.6, 1}, {0.8, 0.7, 0.6, 1}}) {
		background := colour.RGBA{0.5, 0.5, 0.5, 1}
		adjusted := colour.minimum_contrast(foreground, background, 21)
		testing.expect(t, adjusted == colour.RGBA{0, 0, 0, 1} || adjusted == colour.RGBA{1, 1, 1, 1})
	}
}
