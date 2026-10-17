package dwrite_test

import "core:testing"
import windows "core:sys/windows"
import "aio:dwrite"

@(test)
shaping_abi :: proc(t: ^testing.T) {
	P :: size_of(rawptr)
	testing.expect_value(t, size_of(dwrite.ITextAnalyzer_VTable), 10 * P)
	testing.expect_value(t, offset_of(dwrite.ITextAnalyzer_VTable, AnalyzeScript), 3 * P)
	testing.expect_value(t, offset_of(dwrite.ITextAnalyzer_VTable, GetGlyphs), 7 * P)
	testing.expect_value(t, offset_of(dwrite.ITextAnalyzer_VTable, GetGlyphPlacements), 8 * P)
	testing.expect_value(t, offset_of(dwrite.ITextAnalyzer_VTable, GetGdiCompatibleGlyphPlacements), 9 * P)
	testing.expect_value(t, size_of(dwrite.ITextAnalysisSink_VTable), 7 * P)
	testing.expect_value(t, offset_of(dwrite.ITextAnalysisSink_VTable, SetScriptAnalysis), 3 * P)
	testing.expect_value(t, offset_of(dwrite.ITextAnalysisSink_VTable, SetNumberSubstitution), 6 * P)
	testing.expect_value(t, size_of(dwrite.Script_Analysis), 8)
	testing.expect_value(t, offset_of(dwrite.Script_Analysis, shapes), 4)
	testing.expect_value(t, size_of(dwrite.Shaping_Text_Properties), 2)
	testing.expect_value(t, size_of(dwrite.Shaping_Glyph_Properties), 2)
	testing.expect_value(t, align_of(dwrite.Shaping_Glyph_Properties), 2)
	testing.expect_value(t, size_of(dwrite.Line_Breakpoint), 1)
	testing.expect_value(t, size_of(dwrite.Font_Feature), 8)
	testing.expect_value(t, size_of(dwrite.Typographic_Features), 16)
	testing.expect_value(t, offset_of(dwrite.Typographic_Features, featureCount), 8)
	testing.expect_value(t, offset_of(dwrite.Script_Sink, interface), 0)
	text := dwrite.Shaping_Text_Properties{isShapedAlone = 1, canBreakShapingAfter = 1}
	testing.expect_value(t, transmute(u16)text, u16(5))
	glyph := dwrite.Shaping_Glyph_Properties{justification = 3, isClusterStart = 1, isZeroWidthSpace = 1}
	testing.expect_value(t, transmute(u16)glyph, u16(0x53))
}

@(test)
script_sink_callbacks :: proc(t: ^testing.T) {
	scripts: [4]dwrite.Script_Analysis
	sink: dwrite.Script_Sink
	testing.expect(t, !dwrite.script_sink_init(nil, scripts[:]))
	if !testing.expect(t, dwrite.script_sink_init(&sink, scripts[:])) {
		return
	}
	i := &sink.interface
	analysis := dwrite.Script_Analysis{17, .No_Visual}
	testing.expect_value(t, i->SetScriptAnalysis(1, 2, &analysis), windows.HRESULT(0))
	testing.expect_value(t, scripts[0], dwrite.Script_Analysis{})
	testing.expect_value(t, scripts[1], analysis)
	testing.expect_value(t, scripts[2], analysis)
	testing.expect_value(t, scripts[3], dwrite.Script_Analysis{})
	testing.expect_value(t, i->SetScriptAnalysis(4, 0, &analysis), windows.HRESULT(0))
	testing.expect(t, i->SetScriptAnalysis(0, 1, nil) < 0)
	testing.expect(t, i->SetScriptAnalysis(3, 2, &analysis) < 0)
	testing.expect(t, i->SetScriptAnalysis(max(u32), max(u32), &analysis) < 0)
	testing.expect(t, i->SetLineBreakpoints(0, 0, nil) < 0)
	testing.expect(t, i->SetBidiLevel(0, 0, 0, 0) < 0)
	testing.expect(t, i->SetNumberSubstitution(0, 0, nil) < 0)
	for iid in ([]^windows.GUID{windows.IUnknown_UUID, dwrite.ITextAnalysisSink_UUID}) {
		object: rawptr
		testing.expect_value(t, i->QueryInterface(iid, &object), windows.HRESULT(0))
		testing.expect_value(t, object, rawptr(i))
	}
	object := rawptr(i)
	unknown := windows.GUID{}
	testing.expect(t, i->QueryInterface(&unknown, &object) < 0)
	testing.expect(t, object == nil)
	testing.expect(t, i->QueryInterface(nil, &object) < 0)
	testing.expect(t, i->QueryInterface(&unknown, nil) < 0)
	testing.expect_value(t, i->AddRef(), u32(1))
	testing.expect_value(t, i->Release(), u32(1))
	testing.expect(t, dwrite.script_sink_init(&sink, nil))
	testing.expect(t, i->SetScriptAnalysis(0, 1, &analysis) < 0)
}

@(test)
analyzer_scripts :: proc(t: ^testing.T) {
	unknown: ^windows.IUnknown
	if !testing.expect(t, dwrite.create_factory(.Isolated, dwrite.IFactory_UUID, &unknown) >= 0) {
		return
	}
	defer _ = unknown->Release()
	factory := cast(^dwrite.IFactory)unknown
	analyzer: ^dwrite.ITextAnalyzer
	if !testing.expect(t, factory->CreateTextAnalyzer(&analyzer) >= 0) {
		return
	}
	defer _ = analyzer->Release()
	object: rawptr
	if testing.expect(t, analyzer->QueryInterface(dwrite.ITextAnalyzer_UUID, &object) >= 0) {
		_ = (cast(^windows.IUnknown)object)->Release()
	}
	text := [4]u16{'a', 'b', '\u03b1', '\u03b2'}
	scripts: [4]dwrite.Script_Analysis
	source: dwrite.Analysis_Source
	sink: dwrite.Script_Sink
	if !testing.expect(t, dwrite.analysis_source_init(&source, text[:], windows.L("en-us"))) {
		return
	}
	if !testing.expect(t, dwrite.script_sink_init(&sink, scripts[:])) {
		return
	}
	testing.expect(t, analyzer->AnalyzeScript(&source.interface, 0, 4, &sink.interface) >= 0)
	testing.expect_value(t, scripts[0], scripts[1])
	testing.expect_value(t, scripts[2], scripts[3])
	testing.expect(t, scripts[0].script != scripts[2].script)
}
