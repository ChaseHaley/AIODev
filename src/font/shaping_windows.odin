package font

import dw "aio:dwrite"
import "base:runtime"
import "core:slice"
import windows "core:sys/windows"
import "core:unicode/utf16"
import "core:unicode/utf8"

@(private)
SHAPE_CACHE_CAPACITY :: 2048

@(private)
Shape_Key :: struct {
	face: Face_Id,
	size: f32,
	hash: u64,
}

@(private)
Shape_Entry :: struct {
	key:    Shape_Key,
	used:   u64,
	runes:  [dynamic]rune,
	starts: [dynamic]bool,
	glyphs: [dynamic]Shaped_Glyph,
}

@(private)
Shaping :: struct {
	analyzer:                    ^dw.ITextAnalyzer,
	entries:                     [SHAPE_CACHE_CAPACITY]Shape_Entry,
	index:                       map[Shape_Key]int,
	count:                       int,
	clock:                       u64,
	text:                        [dynamic]u16,
	rune_map:                    [dynamic]int,
	scripts:                     [dynamic]dw.Script_Analysis,
	coverage, clusters, indices: [dynamic]u16,
	text_props:                  [dynamic]dw.Shaping_Text_Properties,
	glyph_props:                 [dynamic]dw.Shaping_Glyph_Properties,
	advances:                    [dynamic]f32,
	offsets:                     [dynamic]dw.Glyph_Offset,
	metrics:                     [dynamic]dw.Glyph_Metrics,
	result:                      [dynamic]Shaped_Glyph,
}

@(private, require_results)
shaping_init :: proc(p: ^Shaping, allocator: runtime.Allocator) -> bool {
	for &entry in p.entries {
		entry.runes = make([dynamic]rune, allocator)
		entry.starts = make([dynamic]bool, allocator)
		entry.glyphs = make([dynamic]Shaped_Glyph, allocator)
	}
	p.text = make([dynamic]u16, allocator)
	p.rune_map = make([dynamic]int, allocator)
	p.scripts = make([dynamic]dw.Script_Analysis, allocator)
	p.coverage = make([dynamic]u16, allocator)
	p.clusters = make([dynamic]u16, allocator)
	p.indices = make([dynamic]u16, allocator)
	p.text_props = make([dynamic]dw.Shaping_Text_Properties, allocator)
	p.glyph_props = make([dynamic]dw.Shaping_Glyph_Properties, allocator)
	p.advances = make([dynamic]f32, allocator)
	p.offsets = make([dynamic]dw.Glyph_Offset, allocator)
	p.metrics = make([dynamic]dw.Glyph_Metrics, allocator)
	p.result = make([dynamic]Shaped_Glyph, allocator)
	p.index = make(map[Shape_Key]int, allocator)
	// Odin grows maps at 75% occupancy, before the reserved bucket count is reached.
	return reserve(&p.index, SHAPE_CACHE_CAPACITY * 2) == nil
}

@(private)
shaping_destroy :: proc(p: ^Shaping) {
	for entry in p.entries {
		delete(entry.runes)
		delete(entry.starts)
		delete(entry.glyphs)
	}
	delete(p.text)
	delete(p.rune_map)
	delete(p.scripts)
	delete(p.coverage)
	delete(p.clusters)
	delete(p.indices)
	delete(p.text_props)
	delete(p.glyph_props)
	delete(p.advances)
	delete(p.offsets)
	delete(p.metrics)
	delete(p.result)
	delete(p.index)
	release(p.analyzer)
}

// Appends shaped glyphs in visual order; runes no font can display emit no glyph.
// clusters gives each rune's grapheme cluster id (equal ids are adjacent); nil makes every
// rune its own cluster. A multi-rune cluster the primary face cannot fully display, or one
// that requests emoji presentation, is shaped whole in the system fallback font, so ZWJ
// sequences, flags, keycaps, and skin tones become the single glyph the fallback font defines.
@(require_results)
shape :: proc(
	s: ^System,
	family: Family,
	style: Style,
	runes: []rune,
	size_px: f32,
	out: ^[dynamic]Shaped_Glyph,
	clusters: []int = nil,
) -> Error {
	assert(s != nil)
	assert(out != nil)
	assert(style <= .Bold_Italic)
	assert(clusters == nil || len(clusters) == len(runes))
	for id in family.faces {
		_ = face_get(s, id)
	}
	if !valid_size(size_px) {
		return .Invalid_Argument
	}
	units := 0
	hash: u64 = 14695981039346656037
	for r, i in runes {
		if !utf8.valid_rune(r) {return .Invalid_Argument}
		units += r >= 0x10000 ? 2 : 1
		// Keep each run addressable by DirectWrite's 16-bit cluster indices.
		if units > int(max(u16)) {return .Invalid_Argument}
		hash = (hash ~ u64(r)) * 1099511628211
		hash = (hash ~ u64(cluster_starts(clusters, i))) * 1099511628211
	}
	if len(runes) == 0 {return .None}
	p := &s.shaping
	p.clock += 1
	id := family.faces[style]
	key := Shape_Key{id, size_px, hash}
	index, indexed := p.index[key]
	if indexed {
		entry := &p.entries[index]
		if slice.equal(entry.runes[:], runes) && same_starts(entry.starts[:], clusters) {
			entry.used = p.clock
			return shape_append(out, entry.glyphs[:])
		}
	}
	if resize(&p.coverage, len(runes)) != nil {return .Out_Of_Memory}
	face := face_get(s, id).handle
	if !checked(
		face->GetGlyphIndices(cast([^]u32)raw_data(runes), u32(len(runes)), raw_data(p.coverage)),
		"GetGlyphIndices(shape)",
	) {
		return .DirectWrite
	}
	clear(&p.result)
	start := 0
	for start < len(runes) {
		end := cluster_end(clusters, start, len(runes))
		if syllable, composed := hangul_syllable(runes[start:end]); composed {
			g, found := glyph_lookup(s, family, style, syllable)
			if found {
				_, err := append(
					&p.result,
					Shaped_Glyph{g, start, glyph_advance(s, g, size_px), {}},
				)
				if err != nil {return .Out_Of_Memory}
			}
			start = end
			continue
		}
		if needs_fallback(p.coverage[start:end], runes[start:end]) {
			if err := shape_fallback(s, family, style, runes[start:end], start, size_px);
			   err != .None {
				return err
			}
			start = end
			continue
		}
		if p.coverage[start] == 0 {
			g, found := glyph_lookup(s, family, style, runes[start])
			if found {
				_, err := append(
					&p.result,
					Shaped_Glyph{g, start, glyph_advance(s, g, size_px), {}},
				)
				if err != nil {return .Out_Of_Memory}
			}
			start = end
			continue
		}
		// Extend over following clusters the primary face displays, so ligatures span cells.
		for end < len(runes) {
			next := cluster_end(clusters, end, len(runes))
			if p.coverage[end] == 0 ||
			   needs_fallback(p.coverage[end:next], runes[end:next]) {break}
			end = next
		}
		if err := shape_span(s, id, runes[start:end], start, size_px, 1); err != .None {return err}
		start = end
	}
	// DirectWrite reports clusters per rune when a font does not ligate a sequence; attribute
	// every glyph to the first rune of its grapheme cluster so callers place them together.
	for &g in p.result {
		for g.cluster > 0 && !cluster_starts(clusters, g.cluster) {
			g.cluster -= 1
		}
	}
	if !indexed {
		index = p.count
		if index == SHAPE_CACHE_CAPACITY {
			index = 0
			for entry, i in p.entries {
				if entry.used < p.entries[index].used {
					index = i
				}
			}
		}
	}
	entry := &p.entries[index]
	// Reserve every buffer before replacing a valid cache entry.
	if reserve(&entry.runes, len(runes)) != nil ||
	   reserve(&entry.glyphs, len(p.result)) != nil ||
	   reserve(&entry.starts, len(runes)) != nil {
		return .Out_Of_Memory
	}
	clear(&entry.runes)
	clear(&entry.glyphs)
	clear(&entry.starts)
	_, rune_err := append(&entry.runes, ..runes)
	_, glyph_err := append(&entry.glyphs, ..p.result[:])
	if rune_err != nil || glyph_err != nil {return .Out_Of_Memory}
	for i in 0 ..< len(runes) {
		if _, err := append(&entry.starts, cluster_starts(clusters, i));
		   err != nil {return .Out_Of_Memory}
	}
	if index < p.count {
		delete_key(&p.index, entry.key)
	}
	entry.key, entry.used = key, p.clock
	p.index[key] = index
	if !indexed && p.count < SHAPE_CACHE_CAPACITY {
		p.count += 1
	}
	return shape_append(out, entry.glyphs[:])
}

@(private)
cluster_starts :: proc(clusters: []int, i: int) -> bool {
	return clusters == nil || i == 0 || clusters[i] != clusters[i - 1]
}

@(private)
cluster_end :: proc(clusters: []int, start, count: int) -> int {
	end := start + 1
	for end < count && !cluster_starts(clusters, end) {
		end += 1
	}
	return end
}

@(private)
same_starts :: proc(starts: []bool, clusters: []int) -> bool {
	for start, i in starts {
		if start != cluster_starts(clusters, i) {return false}
	}
	return true
}

// A multi-rune cluster goes to the fallback font when the primary face lacks one of its runes
// or the cluster asks for emoji presentation.
@(private)
needs_fallback :: proc(coverage: []u16, runes: []rune) -> bool {
	if len(runes) < 2 {return false}
	if emoji_presentation(runes) {return true}
	for c in coverage {
		if c == 0 {return true}
	}
	return false
}

// Reports whether a cluster asks for emoji presentation: VS16, a keycap, a skin tone modifier,
// regional indicators, tags, or a ZWJ sequence that starts with a pictograph. VS15 asks for text.
// Such a cluster maps from the system emoji font first, because a text font that covers the
// base character would otherwise win and draw it as text.
emoji_presentation :: proc(runes: []rune) -> bool {
	if len(runes) < 2 {return false}
	for r in runes {
		if r == 0xfe0e {return false}
	}
	for r in runes {
		switch r {
		case 0xfe0f, 0x20e3, 0x1f3fb ..= 0x1f3ff, 0x1f1e6 ..= 0x1f1ff, 0xe0020 ..= 0xe007f:
			return true
		case 0x200d:
			if pictograph(runes[0]) {return true}
		}
	}
	return false
}

// Approximates Extended_Pictographic with the blocks that hold emoji bases.
@(private)
pictograph :: proc(r: rune) -> bool {
	switch r {
	case 0xa9,
	     0xae,
	     0x203c,
	     0x2049,
	     0x2122,
	     0x2139,
	     0x2194 ..=
	     0x2199,
	     0x21a9 ..=
	     0x21aa,
	     0x231a ..=
	     0x23ff,
	     0x24c2,
	     0x25aa ..=
	     0x25fe,
	     0x2600 ..=
	     0x27bf,
	     0x2934 ..=
	     0x2935,
	     0x2b05 ..=
	     0x2b55,
	     0x3030,
	     0x303d,
	     0x3297,
	     0x3299,
	     0x1f000 ..=
	     0x1faff:
		return true
	}
	return false
}

// Shapes one cluster in the font DirectWrite's system fallback picks for the whole cluster.
// When no font maps it, each rune falls back on its own, as single runes do.
@(private, require_results)
shape_fallback :: proc(
	s: ^System,
	family: Family,
	style: Style,
	runes: []rune,
	base: int,
	size: f32,
) -> Error {
	p := &s.shaping
	if resize(&p.text, len(runes) * 2) != nil {return .Out_Of_Memory}
	n := utf16.encode(p.text[:], runes)
	source: dw.Analysis_Source
	if !dw.analysis_source_init(&source, p.text[:n], windows.L("en-us")) {
		return .Invalid_Argument
	}
	weight, slant := style_values(style)
	mapped: u32
	font: ^dw.IFont
	scale: f32 = 1
	base_family := family_name(s, family)
	if emoji_presentation(runes) {base_family = windows.L("Segoe UI Emoji")}
	hr := s.fallback->MapCharacters(
		&source.interface,
		0,
		u32(n),
		s.collection,
		base_family,
		weight,
		slant,
		.Normal,
		&mapped,
		&font,
		&scale,
	)
	defer release(font)
	if checked(hr, "MapCharacters(cluster)") && font != nil && mapped > 0 && valid_size(scale) {
		id, err := face_intern(s, font)
		if err == .Out_Of_Memory {return err}
		if err == .None {
			return shape_span(s, id, runes, base, size, scale)
		}
	}
	for r, i in runes {
		g, found := glyph_lookup(s, family, style, r)
		if !found {continue}
		if _, err := append(&p.result, Shaped_Glyph{g, base + i, glyph_advance(s, g, size), {}});
		   err != nil {
			return .Out_Of_Memory
		}
	}
	return .None
}

@(private, require_results)
shape_append :: proc(out: ^[dynamic]Shaped_Glyph, glyphs: []Shaped_Glyph) -> Error {
	if reserve(out, len(out) + len(glyphs)) != nil {
		return .Out_Of_Memory
	}
	_, err := append(out, ..glyphs)
	return err == nil ? .None : .Out_Of_Memory
}

@(private, require_results)
shape_span :: proc(s: ^System, id: Face_Id, runes: []rune, base: int, size, scale: f32) -> Error {
	p := &s.shaping
	if resize(&p.text, len(runes) * 2) != nil || resize(&p.rune_map, len(runes) * 2) != nil {
		return .Out_Of_Memory
	}
	n := utf16.encode(p.text[:], runes)
	at := 0
	for r, i in runes {
		p.rune_map[at] = base + i
		at += 1
		if r >= 0x10000 {
			p.rune_map[at] = base + i
			at += 1
		}
	}
	if resize(&p.scripts, n) != nil ||
	   resize(&p.clusters, n) != nil ||
	   resize(&p.text_props, n) != nil {
		return .Out_Of_Memory
	}
	if p.analyzer == nil &&
	   !checked(s.factory->CreateTextAnalyzer(&p.analyzer), "CreateTextAnalyzer") {
		return .DirectWrite
	}
	source: dw.Analysis_Source
	sink: dw.Script_Sink
	if !dw.analysis_source_init(&source, p.text[:n], windows.L("en-us")) ||
	   !dw.script_sink_init(&sink, p.scripts[:]) {
		return .Invalid_Argument
	}
	if !checked(
		p.analyzer->AnalyzeScript(&source.interface, 0, u32(n), &sink.interface),
		"AnalyzeScript",
	) {
		return .DirectWrite
	}
	start := 0
	for start < n {
		end := start + 1
		for end < n && p.scripts[end] == p.scripts[start] {
			end += 1
		}
		if err := shape_script(s, id, start, end, size, scale); err != .None {return err}
		start = end
	}
	return .None
}

@(private, require_results)
shape_script :: proc(s: ^System, id: Face_Id, start, end: int, size, scale: f32) -> Error {
	p := &s.shaping
	n := u32(end - start)
	capacity := min(int(max(u16)), int(n) * 3 / 2 + 16)
	features := [2]dw.Font_Feature {
		{dw.FONT_FEATURE_TAG_CONTEXTUAL_ALTERNATES, 1},
		{dw.FONT_FEATURE_TAG_STANDARD_LIGATURES, 1},
	}
	typography := dw.Typographic_Features{raw_data(features[:]), 2}
	feature_ptr := &typography
	face := face_get(s, id)
	text := windows.wstring(&p.text[start])
	count: u32
	for {
		if resize(&p.indices, capacity) != nil || resize(&p.glyph_props, capacity) != nil {
			return .Out_Of_Memory
		}
		hr := p.analyzer->GetGlyphs(
			text,
			n,
			face.handle,
			false,
			false,
			&p.scripts[start],
			windows.L("en-us"),
			nil,
			&feature_ptr,
			&n,
			1,
			u32(capacity),
			raw_data(p.clusters),
			raw_data(p.text_props),
			raw_data(p.indices),
			raw_data(p.glyph_props),
			&count,
		)
		if hr == windows.HRESULT_FROM_WIN32(windows.ERROR_INSUFFICIENT_BUFFER) &&
		   capacity < int(max(u16)) {
			capacity = min(int(max(u16)), capacity * 2)
			continue
		}
		if !checked(hr, "GetGlyphs") {return .DirectWrite}
		break
	}
	if count == 0 {return .None}
	if resize(&p.advances, int(count)) != nil ||
	   resize(&p.offsets, int(count)) != nil ||
	   resize(&p.metrics, int(count)) != nil ||
	   reserve(&p.result, len(p.result) + int(count)) != nil {
		return .Out_Of_Memory
	}
	if !checked(
		   p.analyzer->GetGlyphPlacements(
			   text,
			   raw_data(p.clusters),
			   raw_data(p.text_props),
			   n,
			   raw_data(p.indices),
			   raw_data(p.glyph_props),
			   count,
			   face.handle,
			   size * scale,
			   false,
			   false,
			   &p.scripts[start],
			   windows.L("en-us"),
			   &feature_ptr,
			   &n,
			   1,
			   raw_data(p.advances),
			   raw_data(p.offsets),
		   ),
		   "GetGlyphPlacements",
	   ) ||
	   !checked(
			   face.handle->GetDesignGlyphMetrics(
				   raw_data(p.indices),
				   count,
				   raw_data(p.metrics),
				   false,
			   ),
			   "GetDesignGlyphMetrics(shape)",
		   ) {
		return .DirectWrite
	}
	cluster, next := 0, 0
	for i in 0 ..< int(count) {
		for next < int(n) && int(p.clusters[next]) <= i {
			cluster = next
			value := p.clusters[next]
			for next < int(n) && p.clusters[next] == value {
				next += 1
			}
		}
		// A font without a glyph for the cluster yields .notdef; draw nothing instead of a box.
		if p.indices[i] == 0 {continue}
		g := Glyph {
			id,
			p.indices[i],
			scale,
			f32(p.metrics[i].advanceWidth) * scale / f32(face.metrics.designUnitsPerEm),
		}
		o := p.offsets[i]
		_, err := append(
			&p.result,
			Shaped_Glyph {
				g,
				p.rune_map[start + cluster],
				p.advances[i],
				{o.advanceOffset, o.ascenderOffset},
			},
		)
		if err != nil {return .Out_Of_Memory}
	}
	return .None
}

// Composes a cluster of modern conjoining jamo (leading consonant, vowel, optional trailing
// consonant) into its precomposed syllable. Windows fonts draw these jamo as separate
// full-width letters instead of joining them, which would not fit the cluster's two cells.
@(private)
hangul_syllable :: proc(runes: []rune) -> (rune, bool) {
	if len(runes) != 2 && len(runes) != 3 {return 0, false}
	l, v := runes[0], runes[1]
	if l < 0x1100 || l > 0x1112 || v < 0x1161 || v > 0x1175 {return 0, false}
	t: rune
	if len(runes) == 3 {
		if runes[2] < 0x11a8 || runes[2] > 0x11c2 {return 0, false}
		t = runes[2] - 0x11a7
	}
	return 0xac00 + ((l - 0x1100) * 21 + (v - 0x1161)) * 28 + t, true
}
