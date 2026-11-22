package ui

import "cosmos:colour"
import "cosmos:font"
import "cosmos:glyphs"
import "cosmos:render"
import "aio:settings"
import "core:log"
import "core:math"
import "core:slice"
import "core:unicode/utf8"

// Every interface color, resolved from the settings theme. Most fields are theme tokens; the
// hover, pressed, shadow, scrim and rim effects derive from them because they model light rather
// than name a role.
Theme :: struct {
	window, pane, surface, border, text, muted, faint, accent, accent_text: render.Color,
	selection, shadow, scrim, hover, pressed, focus, error, success, warning, info: render.Color,
	tab_bar, tab_text, tab_active, tab_active_text, tab_indicator, rail_active: render.Color,
	pane_border, pane_focus: render.Color,
	scrollbar_track, scrollbar, scrollbar_hover, scrollbar_active: render.Color,
	// Markdown code, inline code and frontmatter fills.
	code_background: render.Color,
	// The colours of Markdown's elements.
	markdown: Markdown_Colors,
	// The fills behind added and removed lines of a diff.
	diff_added, diff_removed: render.Color,
	// The text cursor in every text surface, and the text under a block of it; the terminal's cursor
	// colours. Text selection is filled with `text_selection`, and selected text takes
	// `text_selection_text` when the theme sets one.
	caret, caret_text, text_selection: render.Color,
	text_selection_text: Maybe(render.Color),
	// The terminal's 16 colours, which syntax colouring and per-agent tints take their hues from, so
	// every theme's code reads like its terminal.
	palette:                  [16]render.Color,
	// The shared raised-hover look. `rim` is the colour of the pointer-following edge light;
	// `hover_edge` is the hairline that holds a light fill's shape. lift and gloss are the
	// interface.hover_lift and interface.hover_gloss settings.
	rim:        render.Color,
	hover_edge: render.Color,
	hover_lift, hover_gloss: f32,
}

// The interface theme from a resolved settings theme and the interface settings that tune the hover.
theme_from :: proc(t: settings.Theme, interface: settings.Interface_Settings) -> Theme {
	c :: proc(t: settings.Theme, token: settings.Theme_Token) -> render.Color {
		value := t.colors[token]
		return colour.rgba(value.rgb, f32(value.a) / 255)
	}
	text, raised, accent := t.colors[.Text].rgb, t.colors[.Surface].rgb, t.colors[.Accent].rgb
	palette: [16]render.Color
	for &entry, i in palette {entry = c(t, settings.Theme_Token(int(settings.Theme_Token.Palette_0) + i))}
	return {
		palette = palette,
		window = c(t, .Window),
		pane = c(t, .Pane),
		surface = c(t, .Surface),
		text = c(t, .Text),
		muted = c(t, .Muted),
		faint = c(t, .Faint),
		accent = c(t, .Accent),
		accent_text = c(t, .Accent_Text),
		border = c(t, .Border),
		selection = c(t, .Selection),
		focus = c(t, .Focus),
		caret = colour.rgba(settings.theme_cursor(t)),
		caret_text = colour.rgba(settings.theme_cursor_text(t)),
		text_selection = c(t, .Selection_Background),
		text_selection_text = t.colors[.Selection_Foreground].a != 0 ? c(t, .Selection_Foreground) : nil,
		error = c(t, .Danger),
		success = c(t, .Success),
		warning = c(t, .Warning),
		info = c(t, .Info),
		tab_bar = c(t, .Tab_Bar),
		tab_text = c(t, .Tab_Text),
		tab_active = c(t, .Tab_Active),
		tab_active_text = c(t, .Tab_Active_Text),
		tab_indicator = c(t, .Tab_Indicator),
		rail_active = c(t, .Rail_Active),
		pane_border = c(t, .Pane_Border),
		pane_focus = c(t, .Pane_Focus),
		scrollbar_track = c(t, .Scrollbar_Track),
		scrollbar = c(t, .Scrollbar),
		scrollbar_hover = c(t, .Scrollbar_Hover),
		scrollbar_active = c(t, .Scrollbar_Active),
		code_background = c(t, .Code_Background),
		markdown = markdown_colors_from(t),
		diff_added = c(t, .Diff_Added),
		diff_removed = c(t, .Diff_Removed),
		// Light mode's hover is paper: the opaque raised-surface colour, so the seat drawn
		// underneath cannot show through and darken the tile, and its shape comes from the
		// hairline and the seat rather than from ink. Dark mode keeps the translucent lift.
		hover = t.light ? colour.rgba(raised) : colour.rgba(text, 0.05),
		pressed = colour.rgba(text, t.light ? 0.08 : 0.09),
		shadow = {0, 0, 0, t.light ? 0.12 : 0.35},
		scrim = {0, 0, 0, t.light ? 0.08 : 0.18},
		// White light reads as a specular edge on dark surfaces. On a white control the rim
		// must stay faint, or it becomes the dark edge the paper fill exists to avoid.
		rim = colour.rgba(t.light ? accent : text, t.light ? 0.20 : 0.80),
		hover_edge = t.light ? colour.rgba(text, 0.10) : render.Color{0, 0, 0, 0},
		hover_lift = f32(interface.hover_lift),
		hover_gloss = f32(interface.hover_gloss),
	}
}

// Selawik is Microsoft's open substitute for Segoe UI, for a font system without the installed fonts.
@(private)
UI_FAMILIES :: [?]string{"Segoe UI Variable Text", "Segoe UI", "Selawik"}
@(private)
ICON_FAMILIES :: [?]string{"Segoe Fluent Icons", "Segoe MDL2 Assets"}
@(private)
ELLIPSIS :: "…"

Text :: struct {
	fonts:                        ^font.System,
	cache:                        ^glyphs.Cache,
	family, strong_family, icons: font.Family,
	has_icons:                    bool,
	size_px, ascent, line_height: f32,
	// The window's field carets; nil draws every caret where it is.
	carets:                       ^Carets,
}

@(require_results)
text_init :: proc(
	t: ^Text, fonts: ^font.System, cache: ^glyphs.Cache, size_px: f32, preferred: string = "",
) -> bool {
	t.fonts, t.cache = fonts, cache
	for name in ([4]string{preferred, UI_FAMILIES[0], UI_FAMILIES[1], UI_FAMILIES[2]}) {
		if name == "" {continue}
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

// The baseline that centres `t`'s capitals, and so digits and most lowercase, on the middle of the band
// from `y` that is `height` tall. A line box centred on its ascent and descent sits capitals low, so a
// label beside an icon uses this to share the icon's centre line.
baseline_caps :: proc(y, height: f32, t: ^Text) -> f32 {
	m := font.face_metrics(t.fonts, t.family.faces[.Regular], t.size_px)
	return math.round(y + height / 2 + m.cap_height / 2)
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
) -> render.Build_Status {
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
) -> render.Build_Status {
	entry, result := glyphs.glyph(t.cache, g, t.size_px)
	if result != .Ok || entry.size.x == 0 {
		return result
	}
	left, top := math.round(x + entry.offset.x), math.round(baseline + entry.offset.y)
	at := render.Rect{left, top, entry.size.x, entry.size.y}
	_ = render.push_glyph(list, {rect = at, atlas = entry.atlas, color = c})
	return .Ok
}

// Splits `s` into lines no wider than `width`, breaking at spaces where possible.
wrap :: proc(t: ^Text, s: string, width: f32, out: ^[dynamic]string) {
	clear(out)
	lines := Wrap_Lines{text = t, s = s, width = width, last_space = -1}
	for start, end in wrap_next(&lines) {append(out, s[start:end])}
}

// Walks the lines `wrap` splits a string into, without storing them. Start with `last_space = -1`.
@(private)
Wrap_Lines :: struct {
	text:                            ^Text,
	s:                               string,
	width:                           f32,
	offset, line_start, last_space:  int,
	line_width, width_through_space: f32,
}

// The next line's byte range; the space a line breaks at belongs to neither line.
@(private)
wrap_next :: proc(w: ^Wrap_Lines) -> (start, end: int, ok: bool) {
	for w.offset < len(w.s) {
		offset := w.offset
		r, size := utf8.decode_rune_in_string(w.s[offset:])
		w.offset += size
		advance: f32
		if g, found := font.glyph_lookup(w.text.fonts, w.text.family, .Regular, r); found {
			advance = font.glyph_advance(w.text.fonts, g, w.text.size_px)
		}
		broke := false
		if w.line_width + advance > w.width && offset > w.line_start {
			broke, start = true, w.line_start
			if w.last_space > w.line_start {
				end = w.last_space
				w.line_start = w.last_space + 1
				w.line_width -= w.width_through_space
			} else {
				end = offset
				w.line_start, w.line_width = offset, 0
			}
			w.last_space = -1
		}
		w.line_width += advance
		if r == ' ' {
			w.last_space, w.width_through_space = offset, w.line_width
		}
		if broke {return start, end, true}
	}
	if w.line_start < len(w.s) {
		start, end = w.line_start, len(w.s)
		w.line_start = len(w.s)
		return start, end, true
	}
	return 0, 0, false
}

draw_rect :: proc(list: ^render.Draw_List, instance: render.Rect_Instance) {
	_ = render.push_rect(list, instance)
}

// A widget that clips its own drawing opens a clip scope and closes it before returning, so its
// caller keeps drawing in the layer it was in. The list has no pop, so closing pushes that layer
// again.
@(private)
Clip_Scope :: struct {
	previous: render.Layer,
	restore:  bool,
}

@(private)
clip_scope_open :: proc(list: ^render.Draw_List, clip: render.Rect, radius: f32 = 0) -> (Clip_Scope, bool) {
	scope: Clip_Scope
	if count := len(list.layers); count > 0 {scope = {list.layers[count - 1], true}}
	return scope, render.push_layer(list, clip, radius) == .None
}

@(private)
clip_scope_close :: proc(list: ^render.Draw_List, scope: Clip_Scope) {
	if scope.restore {_ = render.push_layer(list, scope.previous.clip, scope.previous.radius)}
}

// The type ramp: four sizes and two weights. Body is the interface font size setting (13 DIPs by
// default); the other sizes keep their ratio to it. Hierarchy comes from size first, then weight,
// then the text colour roles, never from a size outside this ramp.
Text_Style :: enum {
	// Primary interface text: tabs, rows, menus, buttons, fields and palette results.
	Body,
	// Body emphasis: notice titles, group headings and the label of a primary or destructive button.
	Strong,
	// Secondary text: descriptions, paths, hints, counts, shortcuts and keycaps.
	Detail,
	// The title of a dialog or overlay, semibold.
	Title,
	// The one large element of a surface: the everything palette query and a page title.
	Display,
}

text_styled :: proc(t: ^Text, style: Text_Style) -> Text {
	copy := t^
	ratio := f32(1)
	switch style {
	case .Body, .Strong:
	case .Detail:
		ratio = 11.0 / 13
	case .Title:
		ratio = 15.0 / 13
	case .Display:
		ratio = 20.0 / 13
	}
	if style == .Strong || style == .Title {copy.family = t.strong_family}
	text_set_size(&copy, t.size_px * ratio)
	return copy
}

// The terminal's font at 0.9 of `t`'s size, as Markdown sets its code; for source text and diffs.
@(private = "file")
MONO_RATIO :: f32(0.9)

text_mono :: proc(t: ^Text, family: font.Family) -> Text {
	copy := t^
	copy.family, copy.strong_family = family, family
	text_set_size(&copy, t.size_px * MONO_RATIO)
	return copy
}

// Draws one line that fades out over its last fifth when wider than `width`. Runes whose byte offsets
// appear in `highlights` use `highlight`, as draw_text's do.
draw_fading_text :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	s: string,
	x, baseline: f32,
	color: render.Color,
	width: f32,
	highlights: []int = nil,
	highlight: render.Color = {},
) -> render.Build_Status {
	if width <= 0 {return .Ok}
	pen := x
	clipped := text_width(t, s) > width
	next := 0
	for r, offset in s {
		if pen >= x + width {break}
		g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r)
		if !found {continue}
		start := len(list.glyphs)
		c := color
		for next < len(highlights) && highlights[next] < offset {next += 1}
		if next < len(highlights) && highlights[next] == offset {c = highlight}
		if result := draw_glyph(t, list, g, pen, baseline, c); result != .Ok {return result}
		if clipped && len(list.glyphs) > start {
			glyph := &list.glyphs[start]
			glyph.flags |= render.GLYPH_FADE
			glyph.fade_start, glyph.fade_end = x + width * 0.8, x + width
		}
		pen += font.glyph_advance(t.fonts, g, t.size_px)
	}
	return .Ok
}

@(private)
focus_ring_draw :: proc(list: ^render.Draw_List, rect: render.Rect, theme: Theme, scale: f32) {
	gap := render.Rect {
		rect.x - scale,
		rect.y - scale,
		rect.width + 2 * scale,
		rect.height + 2 * scale,
	}
	ring := render.Rect {
		rect.x - 3 * scale,
		rect.y - 3 * scale,
		rect.width + 6 * scale,
		rect.height + 6 * scale,
	}
	// The ring follows a control's corner outward: one DIP of gap, then two of ring.
	gap_radius, ring_radius := (RADIUS_CONTROL + 1) * scale, (RADIUS_CONTROL + 3) * scale
	draw_rect(list, {rect = gap, color = theme.window, radius = gap_radius, stroke = scale})
	draw_rect(list, {rect = ring, color = theme.accent, radius = ring_radius, stroke = 2 * scale})
}

// Centers the glyph's rasterized ink in `area`; draw_text instead places the pen on a baseline, which
// leaves symbols such as × visibly off center inside small buttons.
draw_glyph_centered :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	r: rune,
	area: render.Rect,
	c: render.Color,
) -> render.Build_Status {
	g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r)
	if !found {return .Ok}
	entry, result := glyphs.glyph(t.cache, g, t.size_px)
	if result != .Ok || entry.size.x == 0 {return result}
	at := render.Rect {
		math.round(area.x + (area.width - entry.size.x) / 2),
		math.round(area.y + (area.height - entry.size.y) / 2),
		entry.size.x,
		entry.size.y,
	}
	_ = render.push_glyph(list, {rect = at, atlas = entry.atlas, color = c})
	return .Ok
}

// Draws an icon-font glyph centered in `area` with the font at `size_px` pixels. Without an icon font
// nothing is drawn.
draw_icon :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	icon: rune,
	area: render.Rect,
	c: render.Color,
	size_px: f32,
) -> render.Build_Status {
	if !t.has_icons {return .Ok}
	icons := t^
	icons.family = t.icons
	text_set_size(&icons, size_px)
	return draw_glyph_centered(&icons, list, icon, area, c)
}

// Supply the whole emoji sequence to system fallback, including variation selectors and ZWJ.
draw_cluster_centered :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	cluster: string,
	area: render.Rect,
	c: render.Color,
	size_px: f32,
) -> render.Build_Status {
	runes: [32]rune
	clusters: [32]int
	count := 0
	for r in cluster {
		if count == len(runes) {return .Ok}
		runes[count] = r
		count += 1
	}
	if count == 0 || size_px <= 0 || area.width <= 0 || area.height <= 0 {return .Ok}
	// Cache hits append into bounded stack storage without per-icon scratch allocation.
	storage: [64]font.Shaped_Glyph
	shaped := slice.into_dynamic(storage[:])
	if err := font.shape(
		t.fonts,
		t.family,
		.Regular,
		runes[:count],
		size_px,
		&shaped,
		clusters[:count],
	); err != .None {
		log.errorf("ui: shaping an icon failed: %v", err)
		return .Ok
	}
	width: f32
	for g in shaped {width += g.advance}
	fit := width > 0 ? min(1, area.width / width) : 1
	draw_size := size_px * fit
	m := font.face_metrics(t.fonts, t.family.faces[.Regular], draw_size)
	baseline := math.round(area.y + (area.height - m.ascent - m.descent) / 2 + m.ascent)
	pen := area.x + (area.width - width * fit) / 2
	for g in shaped {
		entry, result := glyphs.glyph(t.cache, g.glyph, draw_size, true)
		if result != .Ok {return result}
		if entry.size.x > 0 {
			at := render.Rect {
				math.round(pen + g.offset.x * fit + entry.offset.x),
				math.round(baseline - g.offset.y * fit + entry.offset.y),
				entry.size.x,
				entry.size.y,
			}
			flags := entry.color ? render.GLYPH_COLOR : 0
			_ = render.push_glyph(
				list,
				{rect = at, atlas = entry.atlas, color = c, flags = flags},
			)
		}
		pen += g.advance * fit
	}
	return .Ok
}

// The baseline that centres one line of `t` in a row `height` tall starting at `y`.
baseline_in :: proc(y, height: f32, t: ^Text) -> f32 {return y + (height - t.line_height) / 2 + t.ascent}

// The most bytes of a title or path a row measures; see clip_bytes.
CLIP_BYTES :: 512

// The start of `s` of at most `limit` bytes, cut on a rune boundary. Long titles and paths only ever show
// their start, so drawing never measures the rest.
clip_bytes :: proc(s: string, limit: int) -> string {
	if len(s) <= limit {return s}
	end := limit
	for end > 0 && (s[end] & 0xC0) == 0x80 {end -= 1}
	return s[:end]
}

// How many spaces a tab spans in code.
TAB_COLUMNS :: 4

// How wide a space is in `t`, which a tab spans TAB_COLUMNS times.
code_space :: proc(t: ^Text) -> f32 {
	if g, found := font.glyph_lookup(t.fonts, t.family, .Regular, ' '); found {
		return font.glyph_advance(t.fonts, g, t.size_px)
	}
	return 0
}

// How one rune of a code line lays out: a tab advances TAB_COLUMNS spaces from the pen and draws
// nothing, a rune without a glyph takes no room and draws nothing, and any other draws `glyph`. Painting,
// measuring and the hit test all read this, so they cannot disagree.
code_rune :: proc(t: ^Text, r: rune, space: f32) -> (glyph: font.Glyph, advance: f32, drawn: bool) {
	if r == '\t' {return {}, TAB_COLUMNS * space, false}
	g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r)
	if !found {return {}, 0, false}
	return g, font.glyph_advance(t.fonts, g, t.size_px), true
}
