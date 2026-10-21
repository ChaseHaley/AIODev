package dwrite

import windows "core:sys/windows"

ITextAnalyzer_UUID_STRING :: "b7e6163e-7f46-43b4-84b3-e4e6249c365d"
ITextAnalyzer_UUID := &IID {
	0xb7e6163e,
	0x7f46,
	0x43b4,
	{0x84, 0xb3, 0xe4, 0xe6, 0x24, 0x9c, 0x36, 0x5d},
}

ITextAnalyzer_VTable :: struct {
	using iunknown_vtable:           windows.IUnknown_VTable,
	AnalyzeScript:                   proc "system" (
		this: ^ITextAnalyzer,
		analysisSource: ^ITextAnalysisSource,
		textPosition, textLength: u32,
		analysisSink: ^ITextAnalysisSink,
	) -> windows.HRESULT,
	AnalyzeBidi:                     proc "system" (
		this: ^ITextAnalyzer,
		analysisSource: ^ITextAnalysisSource,
		textPosition, textLength: u32,
		analysisSink: ^ITextAnalysisSink,
	) -> windows.HRESULT,
	AnalyzeNumberSubstitution:       proc "system" (
		this: ^ITextAnalyzer,
		analysisSource: ^ITextAnalysisSource,
		textPosition, textLength: u32,
		analysisSink: ^ITextAnalysisSink,
	) -> windows.HRESULT,
	AnalyzeLineBreakpoints:          proc "system" (
		this: ^ITextAnalyzer,
		analysisSource: ^ITextAnalysisSource,
		textPosition, textLength: u32,
		analysisSink: ^ITextAnalysisSink,
	) -> windows.HRESULT,
	GetGlyphs:                       proc "system" (
		this: ^ITextAnalyzer,
		textString: windows.wstring,
		textLength: u32,
		fontFace: ^IFontFace,
		isSideways, isRightToLeft: windows.BOOL,
		scriptAnalysis: ^Script_Analysis,
		localeName: windows.wstring,
		numberSubstitution: ^INumberSubstitution,
		features: [^]^Typographic_Features,
		featureRangeLengths: [^]u32,
		featureRanges, maxGlyphCount: u32,
		clusterMap: [^]u16,
		textProps: [^]Shaping_Text_Properties,
		glyphIndices: [^]u16,
		glyphProps: [^]Shaping_Glyph_Properties,
		actualGlyphCount: ^u32,
	) -> windows.HRESULT,
	GetGlyphPlacements:              proc "system" (
		this: ^ITextAnalyzer,
		textString: windows.wstring,
		clusterMap: [^]u16,
		textProps: [^]Shaping_Text_Properties,
		textLength: u32,
		glyphIndices: [^]u16,
		glyphProps: [^]Shaping_Glyph_Properties,
		glyphCount: u32,
		fontFace: ^IFontFace,
		fontEmSize: f32,
		isSideways, isRightToLeft: windows.BOOL,
		scriptAnalysis: ^Script_Analysis,
		localeName: windows.wstring,
		features: [^]^Typographic_Features,
		featureRangeLengths: [^]u32,
		featureRanges: u32,
		glyphAdvances: [^]f32,
		glyphOffsets: [^]Glyph_Offset,
	) -> windows.HRESULT,
	GetGdiCompatibleGlyphPlacements: proc "system" (
		this: ^ITextAnalyzer,
		textString: windows.wstring,
		clusterMap: [^]u16,
		textProps: [^]Shaping_Text_Properties,
		textLength: u32,
		glyphIndices: [^]u16,
		glyphProps: [^]Shaping_Glyph_Properties,
		glyphCount: u32,
		fontFace: ^IFontFace,
		fontEmSize: f32,
		pixelsPerDip: f32,
		transform: ^Matrix,
		useGdiNatural, isSideways, isRightToLeft: windows.BOOL,
		scriptAnalysis: ^Script_Analysis,
		localeName: windows.wstring,
		features: [^]^Typographic_Features,
		featureRangeLengths: [^]u32,
		featureRanges: u32,
		glyphAdvances: [^]f32,
		glyphOffsets: [^]Glyph_Offset,
	) -> windows.HRESULT,
}

ITextAnalysisSink_UUID_STRING :: "5810cd44-0ca0-4701-b3fa-bec5182ae4f6"
ITextAnalysisSink_UUID := &IID {
	0x5810cd44,
	0x0ca0,
	0x4701,
	{0xb3, 0xfa, 0xbe, 0xc5, 0x18, 0x2a, 0xe4, 0xf6},
}
ITextAnalysisSink :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^ITextAnalysisSink_VTable,
}
ITextAnalysisSink_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	SetScriptAnalysis:     proc "system" (
		this: ^ITextAnalysisSink,
		textPosition, textLength: u32,
		scriptAnalysis: ^Script_Analysis,
	) -> windows.HRESULT,
	SetLineBreakpoints:    proc "system" (
		this: ^ITextAnalysisSink,
		textPosition, textLength: u32,
		lineBreakpoints: [^]Line_Breakpoint,
	) -> windows.HRESULT,
	SetBidiLevel:          proc "system" (
		this: ^ITextAnalysisSink,
		textPosition, textLength: u32,
		explicitLevel, resolvedLevel: u8,
	) -> windows.HRESULT,
	SetNumberSubstitution: proc "system" (
		this: ^ITextAnalysisSink,
		textPosition, textLength: u32,
		numberSubstitution: ^INumberSubstitution,
	) -> windows.HRESULT,
}

Script_Shapes :: enum i32 {
	Default   = 0,
	No_Visual = 1,
}

Script_Analysis :: struct {
	script: u16,
	shapes: Script_Shapes,
}

Shaping_Text_Properties :: bit_field u16 {
	isShapedAlone:        u16 | 1,
	reserved1:            u16 | 1,
	canBreakShapingAfter: u16 | 1,
	reserved:             u16 | 13,
}

Shaping_Glyph_Properties :: bit_field u16 {
	justification:    u16 | 4,
	isClusterStart:   u16 | 1,
	isDiacritic:      u16 | 1,
	isZeroWidthSpace: u16 | 1,
	reserved:         u16 | 9,
}

Line_Breakpoint :: bit_field u8 {
	breakConditionBefore: u8 | 2,
	breakConditionAfter:  u8 | 2,
	isWhitespace:         u8 | 1,
	isSoftHyphen:         u8 | 1,
	padding:              u8 | 2,
}

Font_Feature_Tag :: distinct u32
FONT_FEATURE_TAG_CONTEXTUAL_ALTERNATES :: Font_Feature_Tag(0x746c6163)
FONT_FEATURE_TAG_STANDARD_LIGATURES :: Font_Feature_Tag(0x6167696c)

Font_Feature :: struct {
	nameTag:   Font_Feature_Tag,
	parameter: u32,
}

Typographic_Features :: struct {
	features:     [^]Font_Feature,
	featureCount: u32,
}
