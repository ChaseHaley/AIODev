package fixtures_test

import "base:runtime"
import "aio:font"

// DirectWrite raises and catches a C++ exception the first time a process exercises some
// shaping paths (seen in Cascadia Code's contextual alternates). Odin's test runner treats any
// first-chance exception on a test thread as fatal and then hangs, so test packages that use
// DirectWrite call this from an @(init) proc, before the runner installs its handler, to take
// that one-time exception outside any test.
warm_directwrite :: proc "contextless" () {
	context = runtime.default_context()
	s, err := font.system_create()
	if err != .None { return }
	defer font.system_destroy(s)
	cases, parse_err := unicode_cases()
	if parse_err != "" { return }
	defer unicode_cases_destroy(cases)
	out: [dynamic]font.Shaped_Glyph
	defer delete(out)
	for name in ([]string{"Cascadia Code", "Cascadia Mono", "Consolas", "Segoe UI", "Segoe UI Emoji"}) {
		family, load_err := font.family_load(s, name)
		if load_err != .None { continue }
		for c in cases {
			clear(&out)
			if font.shape(s, family, .Regular, c.stored, 20, &out) != .None { continue }
			for g in out {
				bitmap, _ := font.glyph_rasterize(s, g.glyph, 20, context.allocator)
				font.bitmap_destroy(&bitmap, context.allocator)
			}
		}
	}
}
