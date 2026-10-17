package dwrite_test

import "core:testing"
import windows "core:sys/windows"
import "aio:dwrite"

@(test)
abi_layouts :: proc(t: ^testing.T) {
	P :: size_of(rawptr)
	testing.expect_value(t, size_of(dwrite.IFactory_VTable), 24 * P)
	testing.expect_value(t, size_of(dwrite.IFactory1_VTable), 26 * P)
	testing.expect_value(t, size_of(dwrite.IFactory2_VTable), 31 * P)
	testing.expect_value(t, offset_of(dwrite.IFactory2_VTable, GetSystemFontFallback), 26 * P)
	testing.expect_value(t, offset_of(dwrite.IFactory2_VTable, CreateGlyphRunAnalysis_2), 30 * P)
	testing.expect_value(t, size_of(dwrite.IFontCollection_VTable), 7 * P)
	testing.expect_value(t, size_of(dwrite.IFontList_VTable), 6 * P)
	testing.expect_value(t, size_of(dwrite.IFontFamily_VTable), 9 * P)
	testing.expect_value(t, size_of(dwrite.IFont_VTable), 14 * P)
	testing.expect_value(t, size_of(dwrite.IFontFace_VTable), 18 * P)
	testing.expect_value(t, size_of(dwrite.IFontFile_VTable), 6 * P)
	testing.expect_value(t, size_of(dwrite.IFontFileLoader_VTable), 4 * P)
	testing.expect_value(t, size_of(dwrite.IFontFallback_VTable), 4 * P)
	testing.expect_value(t, size_of(dwrite.IGlyphRunAnalysis_VTable), 6 * P)
	testing.expect_value(t, size_of(dwrite.IRenderingParams_VTable), 8 * P)
	testing.expect_value(t, size_of(dwrite.IRenderingParams1_VTable), 9 * P)
	testing.expect_value(t, size_of(dwrite.IRenderingParams2_VTable), 10 * P)
	testing.expect_value(t, size_of(dwrite.ILocalizedStrings_VTable), 9 * P)
	testing.expect_value(t, size_of(dwrite.ITextAnalysisSource_VTable), 8 * P)
	testing.expect_value(t, size_of(dwrite.Font_Metrics), 20)
	testing.expect_value(t, size_of(dwrite.Glyph_Metrics), 28)
	testing.expect_value(t, size_of(dwrite.Glyph_Offset), 8)
	testing.expect_value(t, size_of(dwrite.Matrix), 24)
	testing.expect_value(t, size_of(dwrite.Glyph_Run), 48)
	testing.expect_value(t, offset_of(dwrite.Glyph_Run, glyphIndices), 16)
	testing.expect_value(t, offset_of(dwrite.Glyph_Run, isSideways), 40)
	testing.expect_value(t, offset_of(dwrite.Analysis_Source, interface), 0)
}

@(test)
analysis_source_callbacks :: proc(t: ^testing.T) {
	text := [4]u16{'A', 0xd83d, 0xde00, 'B'}
	source: dwrite.Analysis_Source
	if !testing.expect(t, dwrite.analysis_source_init(&source, text[:], windows.L("en-us"))) {
		return
	}
	i := &source.interface
	p: windows.wstring
	n: u32
	for position in u32(0)..<4 {
		testing.expect_value(t, i->GetTextAtPosition(position, &p, &n), windows.HRESULT(0))
		testing.expect_value(t, p, windows.wstring(&text[position]))
		testing.expect_value(t, n, 4 - position)
	}
	for position in ([]u32{4, 5, max(u32)}) {
		testing.expect_value(t, i->GetTextAtPosition(position, &p, &n), windows.HRESULT(0))
		testing.expect(t, p == nil && n == 0)
	}
	for position in u32(1)..=4 {
		testing.expect_value(t, i->GetTextBeforePosition(position, &p, &n), windows.HRESULT(0))
		testing.expect_value(t, p, windows.wstring(&text[0]))
		testing.expect_value(t, n, position)
	}
	for position in ([]u32{0, 5, max(u32)}) {
		testing.expect_value(t, i->GetTextBeforePosition(position, &p, &n), windows.HRESULT(0))
		testing.expect(t, p == nil && n == 0)
	}
	testing.expect_value(t, i->GetLocaleName(1, &n, &p), windows.HRESULT(0))
	testing.expect_value(t, n, u32(3))
	testing.expect_value(t, p, source.locale)
	substitution: ^dwrite.INumberSubstitution
	testing.expect_value(t, i->GetNumberSubstitution(2, &n, &substitution), windows.HRESULT(0))
	testing.expect_value(t, n, u32(2))
	testing.expect(t, substitution == nil)
	testing.expect_value(t, i->GetParagraphReadingDirection(), dwrite.Reading_Direction.Left_To_Right)
	testing.expect(t, i->GetTextAtPosition(0, nil, &n) < 0)
	testing.expect(t, i->GetTextBeforePosition(0, &p, nil) < 0)
	testing.expect(t, i->GetLocaleName(5, &n, &p) < 0)
	testing.expect(t, i->GetLocaleName(0, nil, &p) < 0)
	testing.expect(t, i->GetNumberSubstitution(5, &n, &substitution) < 0)
	testing.expect(t, i->GetNumberSubstitution(0, &n, nil) < 0)
		for id in ([]^windows.GUID{dwrite.ITextAnalysisSource_UUID, windows.IUnknown_UUID}) {
		iid := id
		object: rawptr
		testing.expect_value(t, i->QueryInterface(iid, &object), windows.HRESULT(0))
		testing.expect_value(t, object, rawptr(i))
		testing.expect_value(t, i->Release(), u32(1))
	}
	iid := windows.GUID{}
	object := rawptr(i)
	testing.expect(t, i->QueryInterface(&iid, &object) < 0)
	testing.expect(t, object == nil)
	testing.expect(t, i->QueryInterface(nil, &object) < 0)
	testing.expect(t, i->QueryInterface(&iid, nil) < 0)
	testing.expect_value(t, i->AddRef(), u32(1))
	testing.expect_value(t, i->Release(), u32(1))
	testing.expect(t, !dwrite.analysis_source_init(nil, text[:], source.locale))
	testing.expect(t, !dwrite.analysis_source_init(&source, nil, nil))
	testing.expect(t, dwrite.analysis_source_init(&source, nil, windows.L("en-us")))
	testing.expect_value(t, i->GetTextAtPosition(0, &p, &n), windows.HRESULT(0))
	testing.expect(t, p == nil && n == 0)
}

@(test)
factory_collection_and_localized_strings :: proc(t: ^testing.T) {
	iid := dwrite.IFactory2_UUID
	unknown: ^windows.IUnknown
	hr := dwrite.create_factory(.Isolated, iid, &unknown)
	if !testing.expect(t, hr >= 0) {
		return
	}
	defer _ = unknown->Release()
	factory := cast(^dwrite.IFactory2)unknown
	collection: ^dwrite.IFontCollection
	if !testing.expect(t, factory->GetSystemFontCollection(&collection, false) >= 0) {
		return
	}
	defer _ = collection->Release()
	testing.expect(t, collection->GetFontFamilyCount() > 0)
	index: u32
	exists: windows.BOOL
	hr = collection->FindFamilyName(windows.L("Consolas"), &index, &exists)
	if !testing.expect(t, hr >= 0 && bool(exists)) {
		return
	}
	family: ^dwrite.IFontFamily
	if !testing.expect(t, collection->GetFontFamily(index, &family) >= 0) {
		return
	}
	defer _ = family->Release()
	names: ^dwrite.ILocalizedStrings
	if !testing.expect(t, family->GetFamilyNames(&names) >= 0) {
		return
	}
	defer _ = names->Release()
	testing.expect(t, names->GetCount() > 0)
	if !testing.expect(t, names->FindLocaleName(windows.L("en-us"), &index, &exists) >= 0 && bool(exists)) {
		return
	}
	length: u32
	if !testing.expect(t, names->GetStringLength(index, &length) >= 0) {
		return
	}
	buffer := make([]u16, int(length) + 1)
	defer delete(buffer)
	testing.expect(t, names->GetString(index, windows.wstring(raw_data(buffer)), u32(len(buffer))) >= 0)
	testing.expect_value(t, length, u32(8))
	testing.expect_value(t, buffer[0], u16('C'))
	testing.expect_value(t, buffer[length], u16(0))
}
