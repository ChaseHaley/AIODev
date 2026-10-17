package font

import "base:runtime"
import "core:slice"
import "core:unicode/utf16"
import "core:unicode/utf8"
import windows "core:sys/windows"
import dw "aio:dwrite"

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
	key: Shape_Key,
	used: u64,
	runes: [dynamic]rune,
	glyphs: [dynamic]Shaped_Glyph,
}

@(private)
Shaping :: struct {
	analyzer: ^dw.ITextAnalyzer,
	entries: [SHAPE_CACHE_CAPACITY]Shape_Entry,
	index: map[Shape_Key]int,
	count: int,
	clock: u64,
	text: [dynamic]u16,
	rune_map: [dynamic]int,
	scripts: [dynamic]dw.Script_Analysis,
	coverage, clusters, indices: [dynamic]u16,
	text_props: [dynamic]dw.Shaping_Text_Properties,
	glyph_props: [dynamic]dw.Shaping_Glyph_Properties,
	advances: [dynamic]f32,
	offsets: [dynamic]dw.Glyph_Offset,
	metrics: [dynamic]dw.Glyph_Metrics,
	result: [dynamic]Shaped_Glyph,
}

@(private, require_results)
shaping_init :: proc(p: ^Shaping, allocator: runtime.Allocator) -> bool {
	for &entry in p.entries {
		entry.runes = make([dynamic]rune, allocator)
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
@(require_results)
shape :: proc(
	s: ^System, family: Family, style: Style, runes: []rune, size_px: f32,
	out: ^[dynamic]Shaped_Glyph,
) -> Error {
	assert(s != nil)
	assert(out != nil)
	assert(style <= .Bold_Italic)
	for id in family.faces {
		_ = face_get(s, id)
	}
	if !valid_size(size_px) {
		return .Invalid_Argument
	}
	units := 0
	hash: u64 = 14695981039346656037
	for r in runes {
		if !utf8.valid_rune(r) { return .Invalid_Argument }
		units += r >= 0x10000 ? 2 : 1
		// Keep each run addressable by DirectWrite's 16-bit cluster indices.
		if units > int(max(u16)) { return .Invalid_Argument }
		hash = (hash ~ u64(r)) * 1099511628211
	}
	if len(runes) == 0 { return .None }
	p := &s.shaping
	p.clock += 1
	id := family.faces[style]
	key := Shape_Key{id, size_px, hash}
	index, indexed := p.index[key]
	if indexed {
		entry := &p.entries[index]
		if slice.equal(entry.runes[:], runes) {
			entry.used = p.clock
			return shape_append(out, entry.glyphs[:])
		}
	}
	if resize(&p.coverage, len(runes)) != nil { return .Out_Of_Memory }
	face := face_get(s, id).handle
	if !checked(face->GetGlyphIndices(cast([^]u32)raw_data(runes), u32(len(runes)),
	                                raw_data(p.coverage)), "GetGlyphIndices(shape)") {
		return .DirectWrite
	}
	clear(&p.result)
	start := 0
	for start < len(runes) {
		if p.coverage[start] == 0 {
			g, found := glyph_lookup(s, family, style, runes[start])
			if found {
				_, err := append(&p.result, Shaped_Glyph{g, start, glyph_advance(s, g, size_px), {}})
				if err != nil { return .Out_Of_Memory }
			}
			start += 1
			continue
		}
		end := start + 1
		for end < len(runes) && p.coverage[end] != 0 {
			end += 1
		}
		if err := shape_span(s, id, runes[start:end], start, size_px); err != .None { return err }
		start = end
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
	// Reserve both buffers before replacing a valid cache entry.
	if reserve(&entry.runes, len(runes)) != nil || reserve(&entry.glyphs, len(p.result)) != nil {
		return .Out_Of_Memory
	}
	clear(&entry.runes)
	clear(&entry.glyphs)
	_, rune_err := append(&entry.runes, ..runes)
	_, glyph_err := append(&entry.glyphs, ..p.result[:])
	if rune_err != nil || glyph_err != nil { return .Out_Of_Memory }
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

@(private, require_results)
shape_append :: proc(out: ^[dynamic]Shaped_Glyph, glyphs: []Shaped_Glyph) -> Error {
	if reserve(out, len(out) + len(glyphs)) != nil {
		return .Out_Of_Memory
	}
	_, err := append(out, ..glyphs)
	return err == nil ? .None : .Out_Of_Memory
}

@(private, require_results)
shape_span :: proc(s: ^System, id: Face_Id, runes: []rune, base: int, size: f32) -> Error {
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
	if resize(&p.scripts, n) != nil || resize(&p.clusters, n) != nil ||
	   resize(&p.text_props, n) != nil {
		return .Out_Of_Memory
	}
	if p.analyzer == nil && !checked(s.factory->CreateTextAnalyzer(&p.analyzer), "CreateTextAnalyzer") {
		return .DirectWrite
	}
	source: dw.Analysis_Source
	sink: dw.Script_Sink
	if !dw.analysis_source_init(&source, p.text[:n], windows.L("en-us")) ||
	   !dw.script_sink_init(&sink, p.scripts[:]) {
		return .Invalid_Argument
	}
	if !checked(p.analyzer->AnalyzeScript(&source.interface, 0, u32(n), &sink.interface), "AnalyzeScript") {
		return .DirectWrite
	}
	start := 0
	for start < n {
		end := start + 1
		for end < n && p.scripts[end] == p.scripts[start] {
			end += 1
		}
		if err := shape_script(s, id, start, end, size); err != .None { return err }
		start = end
	}
	return .None
}

@(private, require_results)
shape_script :: proc(s: ^System, id: Face_Id, start, end: int, size: f32) -> Error {
	p := &s.shaping
	n := u32(end - start)
	capacity := min(int(max(u16)), int(n) * 3 / 2 + 16)
	features := [2]dw.Font_Feature{
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
		hr := p.analyzer->GetGlyphs(text, n, face.handle, false, false, &p.scripts[start],
			windows.L("en-us"), nil, &feature_ptr, &n, 1, u32(capacity), raw_data(p.clusters),
			raw_data(p.text_props), raw_data(p.indices), raw_data(p.glyph_props), &count)
		if hr == windows.HRESULT_FROM_WIN32(windows.ERROR_INSUFFICIENT_BUFFER) &&
		   capacity < int(max(u16)) {
			capacity = min(int(max(u16)), capacity * 2)
			continue
		}
		if !checked(hr, "GetGlyphs") { return .DirectWrite }
		break
	}
	if count == 0 { return .None }
	if resize(&p.advances, int(count)) != nil || resize(&p.offsets, int(count)) != nil ||
	   resize(&p.metrics, int(count)) != nil || reserve(&p.result, len(p.result) + int(count)) != nil {
		return .Out_Of_Memory
	}
	if !checked(p.analyzer->GetGlyphPlacements(text, raw_data(p.clusters), raw_data(p.text_props), n,
		raw_data(p.indices), raw_data(p.glyph_props), count, face.handle, size, false, false,
		&p.scripts[start], windows.L("en-us"), &feature_ptr, &n, 1, raw_data(p.advances),
		raw_data(p.offsets)), "GetGlyphPlacements") ||
	   !checked(face.handle->GetDesignGlyphMetrics(raw_data(p.indices), count, raw_data(p.metrics), false),
	            "GetDesignGlyphMetrics(shape)") {
		return .DirectWrite
	}
	cluster, next := 0, 0
	for i in 0..<int(count) {
		for next < int(n) && int(p.clusters[next]) <= i {
			cluster = next
			value := p.clusters[next]
			for next < int(n) && p.clusters[next] == value {
				next += 1
			}
		}
		g := Glyph{id, p.indices[i], 1, f32(p.metrics[i].advanceWidth) / f32(face.metrics.designUnitsPerEm)}
		o := p.offsets[i]
		_, err := append(&p.result, Shaped_Glyph{g, p.rune_map[start + cluster], p.advances[i],
		                                      {o.advanceOffset, o.ascenderOffset}})
		if err != nil { return .Out_Of_Memory }
	}
	return .None
}
