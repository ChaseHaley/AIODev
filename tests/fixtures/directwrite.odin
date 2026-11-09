package fixtures_test

import "base:runtime"
import "aio:font"
import test_fonts "fonts"

// DirectWrite raises and catches a C++ exception the first time a process exercises some
// shaping paths (seen in Cascadia Code's contextual alternates). Odin's test runner treats any
// first-chance exception on a test thread as fatal and then hangs, so test packages that use
// DirectWrite call this from an @(init) proc, before the runner installs its handler, to take
// that one-time exception outside any test.
warm_directwrite :: proc "contextless" () {
	context = runtime.default_context()
	warm_fonts(font.system_create, {"Cascadia Code", "Cascadia Mono", "Consolas", "Segoe UI", "Segoe UI Emoji"})
	private :: proc(allocator := context.allocator) -> (^font.System, font.Error) {
		return font.system_create_private(test_fonts.files(), allocator)
	}
	warm_fonts(private, {test_fonts.MONO, test_fonts.CODE, test_fonts.UI, test_fonts.EMOJI, "Consolas"})
}

@(private = "file")
warm_fonts :: proc(create: proc(allocator := context.allocator) -> (^font.System, font.Error), names: []string) {
	s, err := create()
	if err != .None { return }
	defer font.system_destroy(s)
	_, _ = font.installed_families(s)
	cases, parse_err := unicode_cases()
	if parse_err != "" { return }
	defer unicode_cases_destroy(cases)
	out: [dynamic]font.Shaped_Glyph
	defer delete(out)
	for name in names {
		family, load_err := font.family_load(s, name)
		if load_err != .None { continue }
		_, _ = font.family_load(s, name, true)
		for c in cases {
			clear(&out)
			if font.shape(s, family, .Regular, c.stored, 20, &out) != .None { continue }
			for g in out {
				bitmap, _ := font.glyph_rasterize(s, g.glyph, 20, context.allocator, color = true)
				font.bitmap_destroy(&bitmap, context.allocator)
			}
		}
	}
}
