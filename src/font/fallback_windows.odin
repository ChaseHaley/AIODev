package font

import dw "aio:dwrite"
import windows "core:sys/windows"

// The family DirectWrite's system fallback maps a run from.
@(private)
Fallback_Base :: enum u8 {
	// The run's own family, so text stays in the family that drew the rest of the line.
	Family,
	// The system emoji family, so a run that asks for emoji presentation cannot be drawn as
	// text by a family that covers its base character.
	Emoji,
}

// One interned fallback face and the scale to draw it at.
@(private)
Fallback_Face :: struct {
	face:  Face_Id,
	scale: f32,
}

// The DirectWrite fallback protocol shared by single-rune lookup and cluster shaping: map a
// UTF-16 run from a base family through the system fallback and intern the face it reports.
// found is false when no single face covers the whole run. err is set only when a face could not
// be interned, so callers can tell "no face" apart from an allocation failure.
@(private, require_results)
fallback_resolve :: proc(
	s: ^System,
	family: Family,
	style: Style,
	units: []u16,
	base := Fallback_Base.Family,
) -> (
	mapping: Fallback_Face,
	found: bool,
	err: Error,
) {
	assert(s != nil)
	assert(len(units) > 0)
	source: dw.Analysis_Source
	assert(dw.analysis_source_init(&source, units, windows.L("en-us")))
	weight, slant := style_values(style)
	base_family: windows.wstring
	if base == .Emoji {
		base_family = windows.L("Segoe UI Emoji")
	} else {
		base_family = family_name(s, family)
	}
	mapped: u32
	font: ^dw.IFont
	scale: f32 = 1
	hr := s.fallback->MapCharacters(
		&source.interface,
		0,
		u32(len(units)),
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
	// One face must cover the whole run. A partial mapping leaves the remaining units to another
	// face, and drawing them all in this one drops their glyphs or attributes them to the wrong
	// family, so both callers reject it and fall back per rune.
	if !checked(hr, "MapCharacters") ||
	   font == nil ||
	   mapped != u32(len(units)) ||
	   !valid_size(scale) {
		return {}, false, .None
	}
	id, intern_err := face_intern(s, font)
	if intern_err != .None {
		return {}, false, intern_err
	}
	return {id, scale}, true, .None
}
