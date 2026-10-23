package font

import dw "aio:dwrite"
import "base:runtime"
import "core:log"
import "core:math"
import "core:slice"
import windows "core:sys/windows"
import "core:unicode/utf16"
import "core:unicode/utf8"

System :: struct {
	allocator:  runtime.Allocator,
	factory:    ^dw.IFactory2,
	collection: ^dw.IFontCollection,
	fallback:   ^dw.IFontFallback,
	faces:      [dynamic]Face,
	families:   [dynamic]Loaded_Family,
	cache:      map[Lookup_Key]Lookup_Result,
	gamma:      Text_Gamma,
	shaping:    Shaping,
	// Real DirectWrite shaping runs since startup. The render thread owns the counter, so it
	// needs no lock and perf_read sees it from that same thread.
	shape_calls: u64,
}

@(private)
Face :: struct {
	handle:      ^dw.IFontFace,
	metrics:     dw.Font_Metrics,
	glyph_count: u16,
	files:       []File_Identity,
	index:       u32,
	simulations: dw.Font_Simulations,
}

@(private)
File_Identity :: struct {
	file:   ^dw.IFontFile,
	loader: ^windows.IUnknown,
	key:    []u8,
}

@(private)
Loaded_Family :: struct {
	value:            Family,
	name:             windows.wstring,
	collection_index: u32,
	semibold:         bool,
}

@(private)
Lookup_Key :: struct {
	family: Family,
	style:  Style,
	r:      rune,
}

@(private)
Lookup_Result :: struct {
	glyph: Glyph,
	found: bool,
}

@(private, require_results)
checked :: proc(hr: windows.HRESULT, call: string) -> bool {
	if hr < 0 {
		log.errorf("%s failed: HRESULT 0x%08x", call, cast(u32)hr)
		return false
	}
	return true
}

@(private)
release :: proc(object: rawptr) {
	if object != nil {
		unknown := cast(^windows.IUnknown)object
		_ = unknown->Release()
	}
}

@(require_results)
system_create :: proc(allocator := context.allocator) -> (^System, Error) {
	s, alloc_err := new(System, allocator)
	if alloc_err != nil || s == nil {
		return nil, .Out_Of_Memory
	}
	s.allocator = allocator
	s.faces = make([dynamic]Face, allocator)
	s.families = make([dynamic]Loaded_Family, allocator)
	s.cache = make(map[Lookup_Key]Lookup_Result, allocator)
	ok := false
	defer if !ok {
		system_destroy(s)
	}
	if !shaping_init(&s.shaping, allocator) {
		return nil, .Out_Of_Memory
	}
	if !checked(
		dw.create_factory(.Shared, dw.IFactory2_UUID, cast(^^windows.IUnknown)&s.factory),
		"DWriteCreateFactory",
	) {
		return nil, .DirectWrite
	}
	if !checked(
		   s.factory->GetSystemFontCollection(&s.collection, false),
		   "GetSystemFontCollection",
	   ) ||
	   !checked(s.factory->GetSystemFontFallback(&s.fallback), "GetSystemFontFallback") {
		return nil, .DirectWrite
	}
	params: ^dw.IRenderingParams
	if !checked(s.factory->CreateRenderingParams(&params), "CreateRenderingParams") {
		return nil, .DirectWrite
	}
	defer release(params)
	grayscale: ^dw.IRenderingParams1
	if !checked(
		params->QueryInterface(dw.IRenderingParams1_UUID, cast(^rawptr)&grayscale),
		"QueryInterface(RenderingParams1)",
	) {
		return nil, .DirectWrite
	}
	defer release(grayscale)
	s.gamma = {params->GetGamma(), grayscale->GetGrayscaleEnhancedContrast()}
	if reserve(&s.cache, 256) != nil {
		return nil, .Out_Of_Memory
	}
	ok = true
	return s, .None
}

system_destroy :: proc(s: ^System) {
	if s == nil {
		return
	}
	shaping_destroy(&s.shaping)
	for &face in s.faces {
		face_destroy(&face, s.allocator)
	}
	for family in s.families {
		delete(family.name, s.allocator)
	}
	delete(s.families)
	delete(s.faces)
	delete(s.cache)
	release(s.fallback)
	release(s.collection)
	release(s.factory)
	free(s, s.allocator)
}

@(private)
face_destroy :: proc(face: ^Face, allocator: runtime.Allocator) {
	for file in face.files {
		release(file.loader)
		release(file.file)
	}
	delete(face.files, allocator)
	release(face.handle)
	face^ = {}
}

@(private, require_results)
face_intern :: proc(s: ^System, font: ^dw.IFont) -> (Face_Id, Error) {
	face: Face
	defer face_destroy(&face, s.allocator)
	if !checked(font->CreateFontFace(&face.handle), "CreateFontFace") {
		return 0, .DirectWrite
	}
	face.glyph_count = face.handle->GetGlyphCount()
	face.index = face.handle->GetIndex()
	face.simulations = face.handle->GetSimulations()
	face.handle->GetMetrics(&face.metrics)
	if face.metrics.designUnitsPerEm == 0 {
		return 0, .DirectWrite
	}
	count: u32
	if !checked(face.handle->GetFiles(&count, nil), "GetFiles(count)") {
		return 0, .DirectWrite
	}
	files, alloc_err := make([]^dw.IFontFile, int(count), s.allocator)
	if alloc_err != nil {
		return 0, .Out_Of_Memory
	}
	defer {
		for file in files {
			release(file)
		}
		delete(files, s.allocator)
	}
	if !checked(face.handle->GetFiles(&count, raw_data(files)), "GetFiles") {
		return 0, .DirectWrite
	}
	face.files, alloc_err = make([]File_Identity, len(files), s.allocator)
	if alloc_err != nil {
		return 0, .Out_Of_Memory
	}
	for file, i in files {
		face.files[i].file = file
		files[i] = nil
		key: rawptr
		length: u32
		if !checked(file->GetReferenceKey(&key, &length), "GetReferenceKey") {
			return 0, .DirectWrite
		}
		face.files[i].key = (cast([^]u8)key)[:int(length)]
		loader: ^dw.IFontFileLoader
		if !checked(file->GetLoader(&loader), "GetLoader") {
			return 0, .DirectWrite
		}
		hr := loader->QueryInterface(windows.IUnknown_UUID, cast(^rawptr)&face.files[i].loader)
		release(loader)
		if !checked(hr, "QueryInterface(font loader)") {
			return 0, .DirectWrite
		}
	}
	for existing, i in s.faces {
		if existing.index != face.index ||
		   existing.simulations != face.simulations ||
		   len(existing.files) != len(face.files) {
			continue
		}
		equal := true
		for file, j in face.files {
			if file.loader != existing.files[j].loader ||
			   !slice.equal(file.key, existing.files[j].key) {
				equal = false
				break
			}
		}
		if equal {
			return Face_Id(i + 1), .None
		}
	}
	if len(s.faces) >= int(max(u32)) {
		return 0, .Out_Of_Memory
	}
	_, alloc_err = append(&s.faces, face)
	if alloc_err != nil {
		return 0, .Out_Of_Memory
	}
	face = {}
	return Face_Id(len(s.faces)), .None
}

@(private)
style_values :: proc(style: Style) -> (dw.Font_Weight, dw.Font_Style) {
	weight: dw.Font_Weight = .Normal
	slant: dw.Font_Style = .Normal
	if style == .Bold || style == .Bold_Italic {
		weight = .Bold
	}
	if style == .Italic || style == .Bold_Italic {
		slant = .Italic
	}
	return weight, slant
}

@(require_results)
family_load :: proc(s: ^System, name: string, semibold: bool = false) -> (Family, Error) {
	assert(s != nil)
	if len(name) == 0 || len(name) > int(max(i32)) || !utf8.valid_string(name) {
		return {}, .Invalid_Argument
	}
	for c in name {
		if c == 0 {
			return {}, .Invalid_Argument
		}
	}
	wide := windows.utf8_to_wstring(name, s.allocator)
	if wide == nil {
		return {}, .Out_Of_Memory
	}
	keep_name := false
	defer if !keep_name {
		delete(wide, s.allocator)
	}
	index: u32
	exists: windows.BOOL
	if !checked(s.collection->FindFamilyName(wide, &index, &exists), "FindFamilyName") {
		return {}, .DirectWrite
	}
	if !exists {
		return {}, .Family_Not_Found
	}
	for family in s.families {
		if family.collection_index == index && family.semibold == semibold {
			return family.value, .None
		}
	}
	handle: ^dw.IFontFamily
	if !checked(s.collection->GetFontFamily(index, &handle), "GetFontFamily") {
		return {}, .DirectWrite
	}
	defer release(handle)
	family: Family
	for style in Style {
		weight, slant := style_values(style)
		if semibold && style == .Regular {weight = .Semi_Bold}
		font: ^dw.IFont
		if !checked(
			handle->GetFirstMatchingFont(weight, .Normal, slant, &font),
			"GetFirstMatchingFont",
		) {
			return {}, .DirectWrite
		}
		id, err := face_intern(s, font)
		release(font)
		if err != .None {
			return {}, err
		}
		family.faces[style] = id
	}
	_, alloc_err := append(&s.families, Loaded_Family{family, wide, index, semibold})
	if alloc_err != nil {
		return {}, .Out_Of_Memory
	}
	keep_name = true
	return family, .None
}

@(private)
face_get :: proc(s: ^System, id: Face_Id) -> ^Face {
	assert(s != nil)
	assert(id != 0 && u64(id) <= u64(len(s.faces)))
	return &s.faces[int(id) - 1]
}

face_metrics :: proc(s: ^System, face: Face_Id, size_px: f32) -> Face_Metrics {
	f := face_get(s, face)
	if !valid_size(size_px) {
		return {}
	}
	m := f.metrics
	scale := size_px / f32(m.designUnitsPerEm)
	return {
		ascent = f32(m.ascent) * scale,
		descent = f32(m.descent) * scale,
		line_gap = f32(m.lineGap) * scale,
		underline_position = f32(m.underlinePosition) * scale,
		underline_thickness = f32(m.underlineThickness) * scale,
		strikethrough_position = f32(m.strikethroughPosition) * scale,
		strikethrough_thickness = f32(m.strikethroughThickness) * scale,
		cap_height = f32(m.capHeight) * scale,
	}
}

@(private)
valid_size :: proc(size: f32) -> bool {
	return size > 0 && !math.is_inf(size) && !math.is_nan(size)
}

@(require_results)
glyph_lookup :: proc(s: ^System, family: Family, style: Style, r: rune) -> (Glyph, bool) {
	assert(s != nil)
	assert(style <= .Bold_Italic)
	for id in family.faces {
		_ = face_get(s, id)
	}
	if !utf8.valid_rune(r) {
		return {}, false
	}
	key := Lookup_Key{family, style, r}
	if cached, ok := s.cache[key]; ok {
		return cached.glyph, cached.found
	}
	// Reserve below half full so the insertion cannot allocate after DirectWrite succeeds.
	if reserve(&s.cache, (len(s.cache) + 1) * 2) != nil {
		return {}, false
	}
	result := lookup_uncached(s, family, style, r)
	s.cache[key] = result
	return result.glyph, result.found
}

@(private, require_results)
lookup_uncached :: proc(s: ^System, family: Family, style: Style, r: rune) -> Lookup_Result {
	code := u32(r)
	id := family.faces[style]
	face := face_get(s, id)
	index: u16
	if !checked(face.handle->GetGlyphIndices(&code, 1, &index), "GetGlyphIndices") {
		return {}
	}
	scale: f32 = 1
	if index == 0 {
		text: [2]u16
		length := 1
		if code < 0x10000 {
			text[0] = u16(code)
		} else {
			high, low := utf16.encode_surrogate_pair(r)
			text[0], text[1] = u16(high), u16(low)
			length = 2
		}
		mapping, found, _ := fallback_resolve(s, family, style, text[:length])
		if !found {
			return {}
		}
		id, scale = mapping.face, mapping.scale
		face = face_get(s, id)
		if !checked(face.handle->GetGlyphIndices(&code, 1, &index), "GetGlyphIndices(fallback)") ||
		   index == 0 {
			return {}
		}
	}
	metrics: dw.Glyph_Metrics
	if !checked(
		face.handle->GetDesignGlyphMetrics(&index, 1, &metrics, false),
		"GetDesignGlyphMetrics",
	) {
		return {}
	}
	advance_em := f32(metrics.advanceWidth) * scale / f32(face.metrics.designUnitsPerEm)
	return {Glyph{id, index, scale, advance_em}, true}
}

glyph_advance :: proc(s: ^System, glyph: Glyph, size_px: f32) -> f32 {
	_ = face_get(s, glyph.face)
	if !valid_size(size_px) {
		return 0
	}
	return glyph.advance_em * size_px
}

// Rasterizes one glyph. With color set, a glyph the font defines in color (COLR layers, as in
// Segoe UI Emoji) comes back as premultiplied RGBA; any other glyph comes back as coverage.
@(require_results)
glyph_rasterize :: proc(
	s: ^System,
	glyph: Glyph,
	size_px: f32,
	allocator: runtime.Allocator,
	color := false,
) -> (
	Bitmap,
	Error,
) {
	face := face_get(s, glyph.face)
	if !valid_size(size_px) ||
	   !valid_size(glyph.scale) ||
	   !valid_size(size_px * glyph.scale) ||
	   glyph.index == 0 ||
	   glyph.index >= face.glyph_count {
		return {}, .Invalid_Argument
	}
	index := glyph.index
	run := dw.Glyph_Run {
		fontFace     = face.handle,
		fontEmSize   = size_px * glyph.scale,
		glyphCount   = 1,
		glyphIndices = &index,
	}
	if color {
		bitmap, found, err := rasterize_color(s, &run, allocator)
		if found || err != .None {
			return bitmap, err
		}
	}
	coverage, bounds, err := rasterize_coverage(s, &run, 0, 0, allocator)
	if err != .None || coverage == nil {
		return {}, err
	}
	return {
			coverage,
			bounds.right - bounds.left,
			bounds.bottom - bounds.top,
			bounds.left,
			-bounds.top,
			false,
		},
		.None
}

// Returns nil pixels for an empty glyph.
@(private, require_results)
rasterize_coverage :: proc(
	s: ^System,
	run: ^dw.Glyph_Run,
	x, y: f32,
	allocator: runtime.Allocator,
) -> (
	[]u8,
	windows.RECT,
	Error,
) {
	analysis: ^dw.IGlyphRunAnalysis
	hr := s.factory->CreateGlyphRunAnalysis_2(
		run,
		nil,
		.Natural_Symmetric,
		.Natural,
		.Enabled,
		.Grayscale,
		x,
		y,
		&analysis,
	)
	if !checked(hr, "CreateGlyphRunAnalysis") {
		return nil, {}, .DirectWrite
	}
	defer release(analysis)
	bounds: windows.RECT
	if !checked(analysis->GetAlphaTextureBounds(.Aliased_1x1, &bounds), "GetAlphaTextureBounds") {
		return nil, {}, .DirectWrite
	}
	width := i64(bounds.right) - i64(bounds.left)
	height := i64(bounds.bottom) - i64(bounds.top)
	if width == 0 || height == 0 {
		return nil, {}, .None
	}
	if width < 0 ||
	   height < 0 ||
	   width > i64(max(i32)) ||
	   height > i64(max(i32)) ||
	   width * height > i64(max(u32)) / 4 ||
	   bounds.top == min(i32) {
		return nil, {}, .Invalid_Argument
	}
	pixels, alloc_err := make([]u8, int(width * height), allocator)
	if alloc_err != nil || pixels == nil {
		return nil, {}, .Out_Of_Memory
	}
	hr = analysis->CreateAlphaTexture(.Aliased_1x1, &bounds, raw_data(pixels), u32(len(pixels)))
	if !checked(hr, "CreateAlphaTexture") {
		delete(pixels, allocator)
		return nil, {}, .DirectWrite
	}
	return pixels, bounds, .None
}

// Composites a color glyph's layers into premultiplied RGBA. Reports found false for a glyph
// without color layers. Layers that use the text color are drawn white.
@(private, require_results)
rasterize_color :: proc(
	s: ^System,
	run: ^dw.Glyph_Run,
	allocator: runtime.Allocator,
) -> (
	Bitmap,
	bool,
	Error,
) {
	layers: ^dw.IColorGlyphRunEnumerator
	hr := s.factory->TranslateColorGlyphRun(0, 0, run, nil, .Natural, nil, 0, &layers)
	if hr == dw.E_NOCOLOR {
		return {}, false, .None
	}
	if !checked(hr, "TranslateColorGlyphRun") {
		return {}, false, .DirectWrite
	}
	defer release(layers)
	Layer :: struct {
		coverage: []u8,
		bounds:   windows.RECT,
		color:    [4]f32,
	}
	collected := make([dynamic]Layer, allocator)
	defer {
		for layer in collected {delete(layer.coverage, allocator)}
		delete(collected)
	}
	union_bounds := windows.RECT{max(i32), max(i32), min(i32), min(i32)}
	for {
		has_run: windows.BOOL
		if !checked(layers->MoveNext(&has_run), "ColorGlyphRunEnumerator.MoveNext") {
			return {}, true, .DirectWrite
		}
		if !has_run {break}
		current: ^dw.Color_Glyph_Run
		if !checked(layers->GetCurrentRun(&current), "ColorGlyphRunEnumerator.GetCurrentRun") {
			return {}, true, .DirectWrite
		}
		coverage, bounds, err := rasterize_coverage(
			s,
			&current.glyphRun,
			current.baselineOriginX,
			current.baselineOriginY,
			allocator,
		)
		if err != .None {return {}, true, err}
		if coverage == nil {continue}
		c := current.runColor
		layer_color :=
			current.paletteIndex == 0xffff ? [4]f32{1, 1, 1, 1} : [4]f32{c.r, c.g, c.b, c.a}
		if _, append_err := append(&collected, Layer{coverage, bounds, layer_color});
		   append_err != nil {
			delete(coverage, allocator)
			return {}, true, .Out_Of_Memory
		}
		union_bounds.left = min(union_bounds.left, bounds.left)
		union_bounds.top = min(union_bounds.top, bounds.top)
		union_bounds.right = max(union_bounds.right, bounds.right)
		union_bounds.bottom = max(union_bounds.bottom, bounds.bottom)
	}
	if len(collected) == 0 {
		return {}, true, .None
	}
	width := i64(union_bounds.right) - i64(union_bounds.left)
	height := i64(union_bounds.bottom) - i64(union_bounds.top)
	if width > i64(max(i32)) || height > i64(max(i32)) || width * height > i64(max(u32)) / 4 {
		return {}, true, .Invalid_Argument
	}
	pixels, alloc_err := make([]u8, int(width * height * 4), allocator)
	if alloc_err != nil || pixels == nil {
		return {}, true, .Out_Of_Memory
	}
	// Source-over in premultiplied space, bottom layer first, accumulated in floating point.
	accumulated := make([][4]f32, int(width * height), allocator)
	if accumulated == nil {
		delete(pixels, allocator)
		return {}, true, .Out_Of_Memory
	}
	defer delete(accumulated, allocator)
	for layer in collected {
		w := int(layer.bounds.right - layer.bounds.left)
		dx := int(layer.bounds.left - union_bounds.left)
		dy := int(layer.bounds.top - union_bounds.top)
		for value, i in layer.coverage {
			if value == 0 {continue}
			a := f32(value) / 255 * layer.color.a
			p := &accumulated[(dy + i / w) * int(width) + dx + i % w]
			p^ = {layer.color.r * a, layer.color.g * a, layer.color.b * a, a} + p^ * (1 - a)
		}
	}
	for p, i in accumulated {
		for channel in 0 ..< 4 {
			pixels[i * 4 + channel] = u8(math.round(clamp(p[channel], 0, 1) * 255))
		}
	}
	return {pixels, i32(width), i32(height), union_bounds.left, -union_bounds.top, true},
		true,
		.None
}

text_gamma :: proc(s: ^System) -> Text_Gamma {
	assert(s != nil)
	return s.gamma
}

// The name a family was loaded by, which DirectWrite fallback uses as the base family.
@(private)
family_name :: proc(s: ^System, family: Family) -> windows.wstring {
	for loaded in s.families {
		if loaded.value == family {
			return loaded.name
		}
	}
	panic("font: family was not loaded by this system")
}
