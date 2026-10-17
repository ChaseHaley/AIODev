package ui

import "core:log"
import "core:math"
import "aio:font"
import "aio:glyphs"
import "aio:render"

Theme :: struct {
	surface, border, text, muted, accent, selection, shadow, error: render.Color,
}

theme_from :: proc(background, foreground, accent, error: render.Color) -> Theme {
	mix :: proc(a, b: render.Color, t: f32) -> render.Color {
		c := a + (b - a) * t
		c.a = 1
		return c
	}
	return {
		surface = mix(background, foreground, 0.07),
		border = mix(background, foreground, 0.18),
		text = foreground,
		muted = mix(background, foreground, 0.55),
		accent = accent,
		selection = mix(background, accent, 0.30),
		shadow = {0, 0, 0, 0.45},
		error = error,
	}
}

@(private) UI_FAMILIES :: [?]string{"Segoe UI Variable Text", "Segoe UI"}
@(private) ELLIPSIS :: "…"

Text :: struct {
	fonts: ^font.System,
	cache: ^glyphs.Cache,
	family: font.Family,
	size_px, ascent, line_height: f32,
}

@(require_results)
text_init :: proc(t: ^Text, fonts: ^font.System, cache: ^glyphs.Cache, size_px: f32) -> bool {
	t.fonts, t.cache = fonts, cache
	for name in UI_FAMILIES {
		family, err := font.family_load(fonts, name)
		if err == .None {
			t.family = family
			text_set_size(t, size_px)
			return true
		}
	}
	return false
}

text_set_size :: proc(t: ^Text, size_px: f32) {
	m := font.face_metrics(t.fonts, t.family.faces[.Regular], size_px)
	t.size_px = size_px
	t.ascent = math.round(m.ascent)
	t.line_height = math.round(m.ascent + m.descent + m.line_gap)
}

text_width :: proc(t: ^Text, s: string) -> f32 {
	width: f32
	for r in s {
		if g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r); found {
			width += font.glyph_advance(t.fonts, g, t.size_px)
		}
	}
	return width
}

// Draws one line starting at the pen position on the baseline. Runes whose byte offsets appear in
// `highlights` use `highlight`; text wider than `max_width` (when positive) ends in an ellipsis.
draw_text :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	s: string,
	x, baseline: f32,
	color: render.Color,
	max_width: f32 = 0,
	highlights: []int = nil,
	highlight: render.Color = {},
) -> glyphs.Result {
	limit := max_width > 0 ? max_width - text_width(t, ELLIPSIS) : max(f32)
	clipped := max_width > 0 && text_width(t, s) > max_width
	pen := x
	next := 0
	for r, offset in s {
		g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r)
		if !found {
			continue
		}
		advance := font.glyph_advance(t.fonts, g, t.size_px)
		if clipped && pen + advance - x > limit {
			break
		}
		c := color
		for next < len(highlights) && highlights[next] < offset {
			next += 1
		}
		if next < len(highlights) && highlights[next] == offset {
			c = highlight
		}
		if result := draw_glyph(t, list, g, pen, baseline, c); result != .Ok {
			return result
		}
		pen += advance
	}
	if clipped {
		return draw_text(t, list, ELLIPSIS, pen, baseline, color)
	}
	return .Ok
}

@(private)
draw_glyph :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	g: font.Glyph,
	x, baseline: f32,
	c: render.Color,
) -> glyphs.Result {
	entry, result := glyphs.glyph(t.cache, g, t.size_px)
	if result != .Ok || entry.size.x == 0 {
		return result
	}
	left, top := math.round(x + entry.offset.x), math.round(baseline + entry.offset.y)
	at := render.Rect{left, top, entry.size.x, entry.size.y}
	if render.push_glyph(list, {rect = at, atlas = entry.atlas, color = c}) != .None {
		log.error("ui: the draw list ran out of memory")
	}
	return .Ok
}

// Splits `s` into lines no wider than `width`, breaking at spaces where possible.
wrap :: proc(t: ^Text, s: string, width: f32, out: ^[dynamic]string) {
	clear(out)
	line_start, last_space := 0, -1
	line_width, width_through_space: f32
	for r, offset in s {
		advance: f32
		if g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r); found {
			advance = font.glyph_advance(t.fonts, g, t.size_px)
		}
		if line_width + advance > width && offset > line_start {
			if last_space > line_start {
				append(out, s[line_start:last_space])
				line_start = last_space + 1
				line_width -= width_through_space
			} else {
				append(out, s[line_start:offset])
				line_start, line_width = offset, 0
			}
			last_space = -1
		}
		line_width += advance
		if r == ' ' {
			last_space, width_through_space = offset, line_width
		}
	}
	if line_start < len(s) {
		append(out, s[line_start:])
	}
}

@(private)
draw_rect :: proc(list: ^render.Draw_List, instance: render.Rect_Instance) {
	if render.push_rect(list, instance) != .None {
		log.error("ui: the draw list ran out of memory")
	}
}
