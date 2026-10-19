package ui

import "core:log"
import "core:math"
import "core:slice"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:settings"

Theme :: struct {
	window, chrome, pane, surface, border, text, muted, faint, accent, accent_text: render.Color,
	selection, shadow, scrim, hover, pressed, focus, error, success, warning, info: render.Color,
}

theme_from :: proc(t: settings.Theme) -> Theme {
	rgb :: proc(c: settings.Color, alpha: f32 = 1) -> render.Color {
		return {f32(c.r)/255, f32(c.g)/255, f32(c.b)/255, alpha}
	}
	return {
		window = rgb(t.window), chrome = rgb(t.chrome), pane = rgb(t.pane), surface = rgb(t.raised),
		text = rgb(t.text), muted = rgb(t.muted), faint = rgb(t.faint),
		accent = rgb(t.accent), accent_text = rgb(t.accent_text),
		border = rgb(t.text, t.light ? 0.09 : 0.08),
		hover = rgb(t.text, t.light ? 0.04 : 0.05), pressed = rgb(t.text, t.light ? 0.08 : 0.09),
		selection = rgb(t.accent, t.light ? 0.10 : 0.14), focus = rgb(t.accent, 0.50),
		shadow = {0, 0, 0, t.light ? 0.12 : 0.35}, scrim = {0, 0, 0, t.light ? 0.08 : 0.18},
		error = rgb(t.danger), success = rgb(t.success), warning = rgb(t.warning), info = rgb(t.info),
	}
}

@(private) UI_FAMILIES :: [?]string{"Segoe UI Variable Text", "Segoe UI"}
@(private) ICON_FAMILIES :: [?]string{"Segoe Fluent Icons", "Segoe MDL2 Assets"}
@(private) ELLIPSIS :: "…"

Text :: struct {
	fonts: ^font.System,
	cache: ^glyphs.Cache,
	family, strong_family, icons: font.Family,
	has_icons: bool,
	size_px, ascent, line_height: f32,
}

@(require_results)
text_init :: proc(t: ^Text, fonts: ^font.System, cache: ^glyphs.Cache, size_px: f32) -> bool {
	t.fonts, t.cache = fonts, cache
	for name in UI_FAMILIES {
		family, err := font.family_load(fonts, name)
		if err == .None {
			t.family, t.strong_family = family, family
			if strong, strong_error := font.family_load(fonts, name, true); strong_error == .None {
				t.strong_family = strong
			}
			for icon_name in ICON_FAMILIES {
				if icons, icon_error := font.family_load(fonts, icon_name); icon_error == .None {
					t.icons, t.has_icons = icons, true
					break
				}
			}
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

Text_Style :: enum { Body, Strong, Small, Label, Input, Keycap }

text_styled :: proc(t: ^Text, style: Text_Style) -> Text {
	copy := t^
	size := f32(12)
	#partial switch style {
	case .Small: size = 11
	case .Label: size = 10.5
	case .Input: size = 13
	case .Keycap: size = 10
	}
	if style == .Strong || style == .Label { copy.family = t.strong_family }
	text_set_size(&copy, t.size_px*size/12)
	return copy
}

draw_fading_text :: proc(t: ^Text, list: ^render.Draw_List, s: string,
	x, baseline: f32, color: render.Color, width: f32) -> glyphs.Result {
	if width <= 0 { return .Ok }
	pen := x
	clipped := text_width(t, s) > width
	for r in s {
		if pen >= x+width { break }
		g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r)
		if !found { continue }
		start := len(list.glyphs)
		if result := draw_glyph(t, list, g, pen, baseline, color); result != .Ok { return result }
		if clipped && len(list.glyphs) > start {
			glyph := &list.glyphs[start]
			glyph.flags |= render.GLYPH_FADE
			glyph.fade_start, glyph.fade_end = x+width*0.8, x+width
		}
		pen += font.glyph_advance(t.fonts, g, t.size_px)
	}
	return .Ok
}

@(private)
focus_ring_draw :: proc(list: ^render.Draw_List, rect: render.Rect, theme: Theme, scale: f32) {
	gap := render.Rect{rect.x-scale, rect.y-scale, rect.width+2*scale, rect.height+2*scale}
	ring := render.Rect{rect.x-3*scale, rect.y-3*scale, rect.width+6*scale, rect.height+6*scale}
	draw_rect(list, {rect = gap, color = theme.window, radius = 7*scale, stroke = scale})
	draw_rect(list, {rect = ring, color = theme.accent, radius = 9*scale, stroke = 2*scale})
}

// Centers the glyph's rasterized ink in `area`; draw_text instead places the pen on a baseline, which
// leaves symbols such as × visibly off center inside small buttons.
draw_glyph_centered :: proc(t: ^Text, list: ^render.Draw_List, r: rune, area: render.Rect,
	c: render.Color) -> glyphs.Result {
	g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r)
	if !found { return .Ok }
	entry, result := glyphs.glyph(t.cache, g, t.size_px)
	if result != .Ok || entry.size.x == 0 { return result }
	at := render.Rect{math.round(area.x+(area.width-entry.size.x)/2), math.round(area.y+(area.height-entry.size.y)/2),
		entry.size.x, entry.size.y}
	if render.push_glyph(list, {rect = at, atlas = entry.atlas, color = c}) != .None {
		log.error("ui: the draw list ran out of memory")
	}
	return .Ok
}

// Draws an icon-font glyph centered in `area`, sized to `fraction` of the area's height. Without an icon
// font nothing is drawn.
draw_icon :: proc(t: ^Text, list: ^render.Draw_List, icon: rune, area: render.Rect, c: render.Color,
	fraction: f32) -> glyphs.Result {
	if !t.has_icons { return .Ok }
	icons := t^
	icons.family = t.icons
	text_set_size(&icons, area.height*fraction*0.6)
	return draw_glyph_centered(&icons, list, icon, area, c)
}

// Supply the whole emoji sequence to system fallback, including variation selectors and ZWJ.
draw_cluster_centered :: proc(t: ^Text, list: ^render.Draw_List, cluster: string, area: render.Rect,
	c: render.Color, size_px: f32) -> glyphs.Result {
	runes: [32]rune
	clusters: [32]int
	count := 0
	for r in cluster {
		if count == len(runes) { return .Ok }
		runes[count] = r
		count += 1
	}
	if count == 0 || size_px <= 0 || area.width <= 0 || area.height <= 0 { return .Ok }
	// Cache hits append into bounded stack storage without per-icon scratch allocation.
	storage: [64]font.Shaped_Glyph
	shaped := slice.into_dynamic(storage[:])
	if err := font.shape(t.fonts, t.family, .Regular, runes[:count], size_px, &shaped, clusters[:count]);
	   err != .None {
		log.errorf("ui: shaping an icon failed: %v", err)
		return .Ok
	}
	width: f32
	for g in shaped { width += g.advance }
	fit := width > 0 ? min(1, area.width/width) : 1
	draw_size := size_px*fit
	m := font.face_metrics(t.fonts, t.family.faces[.Regular], draw_size)
	baseline := math.round(area.y+(area.height-m.ascent-m.descent)/2+m.ascent)
	pen := area.x+(area.width-width*fit)/2
	for g in shaped {
		entry, result := glyphs.glyph(t.cache, g.glyph, draw_size, true)
		if result != .Ok { return result }
		if entry.size.x > 0 {
			at := render.Rect{math.round(pen+g.offset.x*fit+entry.offset.x),
				math.round(baseline-g.offset.y*fit+entry.offset.y), entry.size.x, entry.size.y}
			flags := entry.color ? render.GLYPH_COLOR : 0
			if render.push_glyph(list, {rect = at, atlas = entry.atlas, color = c, flags = flags}) != .None {
				log.error("ui: the draw list ran out of memory")
			}
		}
		pen += g.advance*fit
	}
	return .Ok
}
