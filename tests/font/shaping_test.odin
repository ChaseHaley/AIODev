package font_test

import "base:runtime"
import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"
import "aio:font"

@(test)
programming_ligatures :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(s)
	out := make([dynamic]font.Shaped_Glyph)
	defer delete(out)
	for name in ([]string{"Cascadia Code", "Consolas"}) {
		family, load_err := font.family_load(s, name)
		if !testing.expect_value(t, load_err, font.Error.None) {
			continue
		}
		for style in font.Style {
			for run in ([][]rune{{'-', '>', ' '}, {'!', '='}, {'=', '='}}) {
				clear(&out)
				if !testing.expect_value(t, font.shape(s, family, style, run, 24, &out), font.Error.None) {
					continue
				}
				if !testing.expect_value(t, len(out), len(run)) {
					continue
				}
				changed := false
				for g, i in out {
					plain, found := font.glyph_lookup(s, family, style, run[i])
					testing.expect(t, found)
					testing.expect_value(t, g.cluster, i)
					testing.expect_value(t, g.glyph.face, plain.face)
					testing.expect_value(t, g.glyph.scale, plain.scale)
					testing.expect(t, abs(g.advance - font.glyph_advance(s, plain, 24)) < 0.001)
					changed ||= g.glyph.index != plain.index
					if name == "Consolas" {
						testing.expect_value(t, g.glyph, plain)
					}
				}
				testing.expect_value(t, changed, name == "Cascadia Code")
			}
		}
	}
}

@(test)
shaping_fallback_and_clusters :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(s)
	family, load_err := font.family_load(s, "Consolas")
	if !testing.expect_value(t, load_err, font.Error.None) {
		return
	}
	out := make([dynamic]font.Shaped_Glyph)
	defer delete(out)
	for middle in ([]rune{'\u6f22', '\U0001f600'}) {
		run := [3]rune{'a', middle, 'b'}
		clear(&out)
		testing.expect_value(t, font.shape(s, family, .Regular, run[:], 20, &out), font.Error.None)
		if !testing.expect_value(t, len(out), 3) {
			continue
		}
		for g, i in out {
			plain, found := font.glyph_lookup(s, family, .Regular, run[i])
			testing.expect(t, found)
			testing.expect_value(t, g.cluster, i)
			testing.expect_value(t, g.glyph, plain)
			testing.expect_value(t, g.advance, font.glyph_advance(s, plain, 20))
		}
		testing.expect(t, out[1].glyph.face != family.faces[.Regular])
	}
	clear(&out)
	accent := [2]rune{'a', '\u0301'}
	testing.expect_value(t, font.shape(s, family, .Regular, accent[:], 20, &out), font.Error.None)
	testing.expect(t, len(out) > 0)
	for g in out {
		testing.expect_value(t, g.cluster, 0)
	}
}

@(test)
shaping_cache_and_append :: proc(t: ^testing.T) {
	state := Failing_Allocator{backing = context.allocator, remaining = 10000}
	allocator := runtime.Allocator{failing_allocator_proc, &state}
	s, err := font.system_create(allocator)
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(s)
	family, load_err := font.family_load(s, "Cascadia Code")
	if !testing.expect_value(t, load_err, font.Error.None) {
		return
	}
	out := make([dynamic]font.Shaped_Glyph, allocator)
	defer delete(out)
	run := [5]rune{'=', '=', '\u6f22', '-', '>'}
	testing.expect_value(t, font.shape(s, family, .Regular, run[:], 20, &out), font.Error.None)
	saved := slice.clone(out[:])
	defer delete(saved)
	faces := len(s.faces)
	testing.expect(t, reserve(&out, len(out) * 2) == nil)
	state.remaining = 0
	for _ in 0..<16 {
		clear(&out)
		testing.expect_value(t, font.shape(s, family, .Regular, run[:], 20, &out), font.Error.None)
		testing.expect(t, slice.equal(out[:], saved))
		testing.expect_value(t, font.shape(s, family, .Regular, run[:], 20, &out), font.Error.None)
		testing.expect(t, slice.equal(out[len(saved):], saved))
		testing.expect_value(t, len(s.faces), faces)
	}
	testing.expect(t, !state.failed)
	clear(&out)
	for len(out) < cap(out) - 1 {
		_, append_err := append(&out, saved[0])
		testing.expect(t, append_err == nil)
	}
	before := len(out)
	testing.expect_value(t, font.shape(s, family, .Regular, run[:], 20, &out), font.Error.Out_Of_Memory)
	testing.expect_value(t, len(out), before)
}

@(test)
shaping_errors :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(s)
	family, load_err := font.family_load(s, "Consolas")
	if !testing.expect_value(t, load_err, font.Error.None) {
		return
	}
	out := make([dynamic]font.Shaped_Glyph)
	defer delete(out)
	run := [1]rune{'a'}
	testing.expect_value(t, font.shape(s, family, .Regular, run[:], 20, &out), font.Error.None)
	sentinel := out[0]
	for size in ([]f32{0, -1, math.INF_F32, math.nan_f32()}) {
		testing.expect_value(t, font.shape(s, family, .Regular, run[:], size, &out), font.Error.Invalid_Argument)
	}
	for r in ([]rune{-1, 0xd800, 0x110000}) {
		bad := [1]rune{r}
		testing.expect_value(t, font.shape(s, family, .Regular, bad[:], 20, &out), font.Error.Invalid_Argument)
	}
	testing.expect_value(t, font.shape(s, family, .Regular, nil, 20, &out), font.Error.None)
	too_long := make([]rune, 65536)
	defer delete(too_long)
	for &r in too_long {
		r = 'a'
	}
	testing.expect_value(t, font.shape(s, family, .Regular, too_long, 20, &out), font.Error.Invalid_Argument)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0], sentinel)
	clear(&out)
	absent := [3]rune{'a', 0x10ffff, 'b'}
	for _ in 0..<2 {
		clear(&out)
		testing.expect_value(t, font.shape(s, family, .Regular, absent[:], 20, &out), font.Error.None)
		if testing.expect_value(t, len(out), 2) {
			testing.expect_value(t, out[0].cluster, 0)
			testing.expect_value(t, out[1].cluster, 2)
		}
	}
	denied := make([dynamic]font.Shaped_Glyph, mem.nil_allocator())
	defer delete(denied)
	testing.expect_value(t, font.shape(s, family, .Regular, run[:], 20, &denied), font.Error.Out_Of_Memory)
}

@(test)
shaping_scripts_and_surrogates :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(s)
	out := make([dynamic]font.Shaped_Glyph)
	defer delete(out)
	for name in ([]string{"Consolas", "Segoe UI Emoji"}) {
		family, load_err := font.family_load(s, name)
		if !testing.expect_value(t, load_err, font.Error.None) {
			continue
		}
		run := name == "Consolas" ? []rune{'a', '\u03b1', 'b'} : []rune{'\U0001f600', 'a'}
		clear(&out)
		if !testing.expect_value(t, font.shape(s, family, .Regular, run, 20, &out), font.Error.None) {
			continue
		}
		if !testing.expect_value(t, len(out), len(run)) {
			continue
		}
		for g, i in out {
			plain, found := font.glyph_lookup(s, family, .Regular, run[i])
			testing.expect(t, found)
			testing.expect_value(t, g.cluster, i)
			testing.expect_value(t, g.glyph, plain)
		}
		if name == "Segoe UI Emoji" {
			testing.expect_value(t, out[0].glyph.face, family.faces[.Regular])
		}
	}
}

@(test)
shaping_cache_eviction :: proc(t: ^testing.T) {
	state := Failing_Allocator{backing = context.allocator, remaining = 100000}
	allocator := runtime.Allocator{failing_allocator_proc, &state}
	s, err := font.system_create(allocator)
	if !testing.expect_value(t, err, font.Error.None) {
		return
	}
	defer font.system_destroy(s)
	family, load_err := font.family_load(s, "Consolas")
	if !testing.expect_value(t, load_err, font.Error.None) {
		return
	}
	out := make([dynamic]font.Shaped_Glyph, allocator)
	defer delete(out)
	run := [2]rune{'=', '='}
	for i in 0..<2050 {
		clear(&out)
		size := 10 + f32(i) / 64
		if !testing.expect_value(t, font.shape(s, family, .Regular, run[:], size, &out), font.Error.None) {
			return
		}
	}
	state.remaining = 0
	for i in ([]int{2049, 0, 2048}) {
		clear(&out)
		size := 10 + f32(i) / 64
		testing.expect_value(t, font.shape(s, family, .Regular, run[:], size, &out), font.Error.None)
		if !testing.expect_value(t, len(out), 2) {
			continue
		}
		for g, j in out {
			plain, found := font.glyph_lookup(s, family, .Regular, run[j])
			testing.expect(t, found)
			testing.expect_value(t, g.glyph, plain)
			testing.expect(t, abs(g.advance - font.glyph_advance(s, plain, size)) < 0.001)
		}
	}
	testing.expect(t, !state.failed)
}

@(test)
shaping_allocation_failure_cleanup :: proc(t: ^testing.T) {
	completed := false
	for fail_after in 0..<48 {
		state := Failing_Allocator{backing = context.allocator, remaining = 10000}
		allocator := runtime.Allocator{failing_allocator_proc, &state}
		s, err := font.system_create(allocator)
		if !testing.expect_value(t, err, font.Error.None) {
			return
		}
		family, load_err := font.family_load(s, "Cascadia Code")
		if !testing.expect_value(t, load_err, font.Error.None) {
			font.system_destroy(s)
			return
		}
		out := make([dynamic]font.Shaped_Glyph, allocator)
		state.remaining = fail_after
		run := [3]rune{'-', '>', ' '}
		shape_err := font.shape(s, family, .Regular, run[:], 20, &out)
		if state.failed {
			testing.expect_value(t, shape_err, font.Error.Out_Of_Memory)
			testing.expect_value(t, len(out), 0)
			state.remaining = 10000
			testing.expect_value(t, font.shape(s, family, .Regular, run[:], 20, &out), font.Error.None)
		} else {
			testing.expect_value(t, shape_err, font.Error.None)
			completed = true
		}
		delete(out)
		font.system_destroy(s)
		if completed {
			break
		}
	}
	testing.expect(t, completed)
}
