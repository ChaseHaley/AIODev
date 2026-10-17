#+build windows
package dwrite

import windows "core:sys/windows"

IID :: windows.GUID

foreign import dwrite "system:dwrite.lib"

@(default_calling_convention="system")
foreign dwrite {
	@(link_name="DWriteCreateFactory", require_results)
	create_factory :: proc(
		factoryType: Factory_Type,
		iid: ^IID,
		factory: ^^windows.IUnknown,
	) -> windows.HRESULT ---
}

IFactory_UUID_STRING :: "b859ee5a-d838-4b5b-a2e8-1adc7d93db48"
IFactory_UUID := &IID{
	0xb859ee5a, 0xd838, 0x4b5b, {0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48},
}
IFactory :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^IFactory_VTable,
}
IFactory_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetSystemFontCollection: proc "system" (
		this: ^IFactory,
		fontCollection: ^^IFontCollection,
		checkForUpdates: windows.BOOL,
	) -> windows.HRESULT,
	CreateCustomFontCollection: proc "system" (
		this: ^IFactory,
		collectionLoader: ^IFontCollectionLoader,
		collectionKey: rawptr,
		collectionKeySize: u32,
		fontCollection: ^^IFontCollection,
	) -> windows.HRESULT,
	RegisterFontCollectionLoader: proc "system" (
		this: ^IFactory,
		fontCollectionLoader: ^IFontCollectionLoader,
	) -> windows.HRESULT,
	UnregisterFontCollectionLoader: proc "system" (
		this: ^IFactory,
		fontCollectionLoader: ^IFontCollectionLoader,
	) -> windows.HRESULT,
	CreateFontFileReference: proc "system" (
		this: ^IFactory,
		filePath: windows.wstring,
		lastWriteTime: ^windows.FILETIME,
		fontFile: ^^IFontFile,
	) -> windows.HRESULT,
	CreateCustomFontFileReference: proc "system" (
		this: ^IFactory,
		fontFileReferenceKey: rawptr,
		fontFileReferenceKeySize: u32,
		fontFileLoader: ^IFontFileLoader,
		fontFile: ^^IFontFile,
	) -> windows.HRESULT,
	CreateFontFace: proc "system" (
		this: ^IFactory,
		fontFaceType: Font_Face_Type,
		numberOfFiles: u32,
		fontFiles: [^]^IFontFile,
		faceIndex: u32,
		fontFaceSimulationFlags: Font_Simulations,
		fontFace: ^^IFontFace,
	) -> windows.HRESULT,
	CreateRenderingParams: proc "system" (
		this: ^IFactory,
		renderingParams: ^^IRenderingParams,
	) -> windows.HRESULT,
	CreateMonitorRenderingParams: proc "system" (
		this: ^IFactory,
		monitor: windows.HMONITOR,
		renderingParams: ^^IRenderingParams,
	) -> windows.HRESULT,
	CreateCustomRenderingParams: proc "system" (
		this: ^IFactory,
		gamma: f32,
		enhancedContrast: f32,
		clearTypeLevel: f32,
		pixelGeometry: Pixel_Geometry,
		renderingMode: Rendering_Mode,
		renderingParams: ^^IRenderingParams,
	) -> windows.HRESULT,
	RegisterFontFileLoader: proc "system" (
		this: ^IFactory,
		fontFileLoader: ^IFontFileLoader,
	) -> windows.HRESULT,
	UnregisterFontFileLoader: proc "system" (
		this: ^IFactory,
		fontFileLoader: ^IFontFileLoader,
	) -> windows.HRESULT,
	CreateTextFormat: proc "system" (
		this: ^IFactory,
		fontFamilyName: windows.wstring,
		fontCollection: ^IFontCollection,
		fontWeight: Font_Weight,
		fontStyle: Font_Style,
		fontStretch: Font_Stretch,
		fontSize: f32,
		localeName: windows.wstring,
		textFormat: ^^ITextFormat,
	) -> windows.HRESULT,
	CreateTypography: proc "system" (this: ^IFactory, typography: ^^ITypography) -> windows.HRESULT,
	GetGdiInterop: proc "system" (this: ^IFactory, gdiInterop: ^^IGdiInterop) -> windows.HRESULT,
	CreateTextLayout: proc "system" (
		this: ^IFactory,
		string: windows.wstring,
		stringLength: u32,
		textFormat: ^ITextFormat,
		maxWidth: f32,
		maxHeight: f32,
		textLayout: ^^ITextLayout,
	) -> windows.HRESULT,
	CreateGdiCompatibleTextLayout: proc "system" (
		this: ^IFactory,
		string: windows.wstring,
		stringLength: u32,
		textFormat: ^ITextFormat,
		layoutWidth: f32,
		layoutHeight: f32,
		pixelsPerDip: f32,
		transform: ^Matrix,
		useGdiNatural: windows.BOOL,
		textLayout: ^^ITextLayout,
	) -> windows.HRESULT,
	CreateEllipsisTrimmingSign: proc "system" (
		this: ^IFactory,
		textFormat: ^ITextFormat,
		trimmingSign: ^^IInlineObject,
	) -> windows.HRESULT,
	CreateTextAnalyzer: proc "system" (this: ^IFactory, textAnalyzer: ^^ITextAnalyzer) -> windows.HRESULT,
	CreateNumberSubstitution: proc "system" (
		this: ^IFactory,
		substitutionMethod: Number_Substitution_Method,
		localeName: windows.wstring,
		ignoreUserOverride: windows.BOOL,
		numberSubstitution: ^^INumberSubstitution,
	) -> windows.HRESULT,
	CreateGlyphRunAnalysis: proc "system" (
		this: ^IFactory,
		glyphRun: ^Glyph_Run,
		pixelsPerDip: f32,
		transform: ^Matrix,
		renderingMode: Rendering_Mode,
		measuringMode: Measuring_Mode,
		baselineOriginX: f32,
		baselineOriginY: f32,
		glyphRunAnalysis: ^^IGlyphRunAnalysis,
	) -> windows.HRESULT,
}

IFactory1_UUID_STRING :: "30572f99-dac6-41db-a16e-0486307e606a"
IFactory1_UUID := &IID{
	0x30572f99, 0xdac6, 0x41db, {0xa1, 0x6e, 0x04, 0x86, 0x30, 0x7e, 0x60, 0x6a},
}
IFactory1 :: struct #raw_union {
	#subtype ifactory: IFactory,
	using vtable: ^IFactory1_VTable,
}
IFactory1_VTable :: struct {
	using ifactory_vtable: IFactory_VTable,
	GetEudcFontCollection: proc "system" (
		this: ^IFactory1,
		fontCollection: ^^IFontCollection,
		checkForUpdates: windows.BOOL,
	) -> windows.HRESULT,
	CreateCustomRenderingParams_1: proc "system" (
		this: ^IFactory1,
		gamma: f32,
		enhancedContrast: f32,
		enhancedContrastGrayscale: f32,
		clearTypeLevel: f32,
		pixelGeometry: Pixel_Geometry,
		renderingMode: Rendering_Mode,
		renderingParams: ^^IRenderingParams1,
	) -> windows.HRESULT,
}

IFactory2_UUID_STRING :: "0439fc60-ca44-4994-8dee-3a9af7b732ec"
IFactory2_UUID := &IID{
	0x0439fc60, 0xca44, 0x4994, {0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec},
}
IFactory2 :: struct #raw_union {
	#subtype ifactory1: IFactory1,
	using vtable: ^IFactory2_VTable,
}
IFactory2_VTable :: struct {
	using ifactory1_vtable: IFactory1_VTable,
	GetSystemFontFallback: proc "system" (
		this: ^IFactory2,
		fontFallback: ^^IFontFallback,
	) -> windows.HRESULT,
	CreateFontFallbackBuilder: proc "system" (
		this: ^IFactory2,
		fontFallbackBuilder: ^^IFontFallbackBuilder,
	) -> windows.HRESULT,
	TranslateColorGlyphRun: proc "system" (
		this: ^IFactory2,
		baselineOriginX: f32,
		baselineOriginY: f32,
		glyphRun: ^Glyph_Run,
		glyphRunDescription: ^Glyph_Run_Description,
		measuringMode: Measuring_Mode,
		worldToDeviceTransform: ^Matrix,
		colorPaletteIndex: u32,
		colorLayers: ^^IColorGlyphRunEnumerator,
	) -> windows.HRESULT,
	CreateCustomRenderingParams_2: proc "system" (
		this: ^IFactory2,
		gamma: f32,
		enhancedContrast: f32,
		grayscaleEnhancedContrast: f32,
		clearTypeLevel: f32,
		pixelGeometry: Pixel_Geometry,
		renderingMode: Rendering_Mode,
		gridFitMode: Grid_Fit_Mode,
		renderingParams: ^^IRenderingParams2,
	) -> windows.HRESULT,
	CreateGlyphRunAnalysis_2: proc "system" (
		this: ^IFactory2,
		glyphRun: ^Glyph_Run,
		transform: ^Matrix,
		renderingMode: Rendering_Mode,
		measuringMode: Measuring_Mode,
		gridFitMode: Grid_Fit_Mode,
		antialiasMode: Text_Antialias_Mode,
		baselineOriginX: f32,
		baselineOriginY: f32,
		glyphRunAnalysis: ^^IGlyphRunAnalysis,
	) -> windows.HRESULT,
}

IFontCollection_UUID_STRING :: "a84cee02-3eea-4eee-a827-87c1a02a0fcc"
IFontCollection_UUID := &IID{
	0xa84cee02, 0x3eea, 0x4eee, {0xa8, 0x27, 0x87, 0xc1, 0xa0, 0x2a, 0x0f, 0xcc},
}
IFontCollection :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^IFontCollection_VTable,
}
IFontCollection_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetFontFamilyCount: proc "system" (this: ^IFontCollection) -> u32,
	GetFontFamily: proc "system" (
		this: ^IFontCollection,
		index: u32,
		fontFamily: ^^IFontFamily,
	) -> windows.HRESULT,
	FindFamilyName: proc "system" (
		this: ^IFontCollection,
		familyName: windows.wstring,
		index: ^u32,
		exists: ^windows.BOOL,
	) -> windows.HRESULT,
	GetFontFromFontFace: proc "system" (
		this: ^IFontCollection,
		fontFace: ^IFontFace,
		font: ^^IFont,
	) -> windows.HRESULT,
}

IFontList_UUID_STRING :: "1a0d8438-1d97-4ec1-aef9-a2fb86ed6acb"
IFontList_UUID := &IID{
	0x1a0d8438, 0x1d97, 0x4ec1, {0xae, 0xf9, 0xa2, 0xfb, 0x86, 0xed, 0x6a, 0xcb},
}
IFontList :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^IFontList_VTable,
}
IFontList_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetFontCollection: proc "system" (
		this: ^IFontList,
		fontCollection: ^^IFontCollection,
	) -> windows.HRESULT,
	GetFontCount: proc "system" (this: ^IFontList) -> u32,
	GetFont: proc "system" (this: ^IFontList, index: u32, font: ^^IFont) -> windows.HRESULT,
}

IFontFamily_UUID_STRING :: "da20d8ef-812a-4c43-9802-62ec4abd7add"
IFontFamily_UUID := &IID{
	0xda20d8ef, 0x812a, 0x4c43, {0x98, 0x02, 0x62, 0xec, 0x4a, 0xbd, 0x7a, 0xdd},
}
IFontFamily :: struct #raw_union {
	#subtype ifontlist: IFontList,
	using vtable: ^IFontFamily_VTable,
}
IFontFamily_VTable :: struct {
	using ifontlist_vtable: IFontList_VTable,
	GetFamilyNames: proc "system" (this: ^IFontFamily, names: ^^ILocalizedStrings) -> windows.HRESULT,
	GetFirstMatchingFont: proc "system" (
		this: ^IFontFamily,
		weight: Font_Weight,
		stretch: Font_Stretch,
		style: Font_Style,
		matchingFont: ^^IFont,
	) -> windows.HRESULT,
	GetMatchingFonts: proc "system" (
		this: ^IFontFamily,
		weight: Font_Weight,
		stretch: Font_Stretch,
		style: Font_Style,
		matchingFonts: ^^IFontList,
	) -> windows.HRESULT,
}

IFont_UUID_STRING :: "acd16696-8c14-4f5d-877e-fe3fc1d32737"
IFont_UUID := &IID{
	0xacd16696, 0x8c14, 0x4f5d, {0x87, 0x7e, 0xfe, 0x3f, 0xc1, 0xd3, 0x27, 0x37},
}
IFont :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^IFont_VTable,
}
IFont_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetFontFamily: proc "system" (this: ^IFont, fontFamily: ^^IFontFamily) -> windows.HRESULT,
	GetWeight: proc "system" (this: ^IFont) -> Font_Weight,
	GetStretch: proc "system" (this: ^IFont) -> Font_Stretch,
	GetStyle: proc "system" (this: ^IFont) -> Font_Style,
	IsSymbolFont: proc "system" (this: ^IFont) -> windows.BOOL,
	GetFaceNames: proc "system" (this: ^IFont, names: ^^ILocalizedStrings) -> windows.HRESULT,
	GetInformationalStrings: proc "system" (
		this: ^IFont,
		informationalStringID: Informational_String_Id,
		informationalStrings: ^^ILocalizedStrings,
		exists: ^windows.BOOL,
	) -> windows.HRESULT,
	GetSimulations: proc "system" (this: ^IFont) -> Font_Simulations,
	GetMetrics: proc "system" (this: ^IFont, fontMetrics: ^Font_Metrics),
	HasCharacter: proc "system" (this: ^IFont, unicodeValue: u32, exists: ^windows.BOOL) -> windows.HRESULT,
	CreateFontFace: proc "system" (this: ^IFont, fontFace: ^^IFontFace) -> windows.HRESULT,
}

IFontFace_UUID_STRING :: "5f49804d-7024-4d43-bfa9-d25984f53849"
IFontFace_UUID := &IID{
	0x5f49804d, 0x7024, 0x4d43, {0xbf, 0xa9, 0xd2, 0x59, 0x84, 0xf5, 0x38, 0x49},
}
IFontFace :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^IFontFace_VTable,
}
IFontFace_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetType: proc "system" (this: ^IFontFace) -> Font_Face_Type,
	GetFiles: proc "system" (
		this: ^IFontFace,
		numberOfFiles: ^u32,
		fontFiles: [^]^IFontFile,
	) -> windows.HRESULT,
	GetIndex: proc "system" (this: ^IFontFace) -> u32,
	GetSimulations: proc "system" (this: ^IFontFace) -> Font_Simulations,
	IsSymbolFont: proc "system" (this: ^IFontFace) -> windows.BOOL,
	GetMetrics: proc "system" (this: ^IFontFace, fontFaceMetrics: ^Font_Metrics),
	GetGlyphCount: proc "system" (this: ^IFontFace) -> u16,
	GetDesignGlyphMetrics: proc "system" (
		this: ^IFontFace,
		glyphIndices: [^]u16,
		glyphCount: u32,
		glyphMetrics: [^]Glyph_Metrics,
		isSideways: windows.BOOL,
	) -> windows.HRESULT,
	GetGlyphIndices: proc "system" (
		this: ^IFontFace,
		codePoints: [^]u32,
		codePointCount: u32,
		glyphIndices: [^]u16,
	) -> windows.HRESULT,
	TryGetFontTable: proc "system" (
		this: ^IFontFace,
		openTypeTableTag: u32,
		tableData: ^rawptr,
		tableSize: ^u32,
		tableContext: ^rawptr,
		exists: ^windows.BOOL,
	) -> windows.HRESULT,
	ReleaseFontTable: proc "system" (this: ^IFontFace, tableContext: rawptr),
	GetGlyphRunOutline: proc "system" (
		this: ^IFontFace,
		emSize: f32,
		glyphIndices: [^]u16,
		glyphAdvances: [^]f32,
		glyphOffsets: [^]Glyph_Offset,
		glyphCount: u32,
		isSideways: windows.BOOL,
		isRightToLeft: windows.BOOL,
		geometrySink: ^IGeometrySink,
	) -> windows.HRESULT,
	GetRecommendedRenderingMode: proc "system" (
		this: ^IFontFace,
		emSize: f32,
		pixelsPerDip: f32,
		measuringMode: Measuring_Mode,
		renderingParams: ^IRenderingParams,
		renderingMode: ^Rendering_Mode,
	) -> windows.HRESULT,
	GetGdiCompatibleMetrics: proc "system" (
		this: ^IFontFace,
		emSize: f32,
		pixelsPerDip: f32,
		transform: ^Matrix,
		fontFaceMetrics: ^Font_Metrics,
	) -> windows.HRESULT,
	GetGdiCompatibleGlyphMetrics: proc "system" (
		this: ^IFontFace,
		emSize: f32,
		pixelsPerDip: f32,
		transform: ^Matrix,
		useGdiNatural: windows.BOOL,
		glyphIndices: [^]u16,
		glyphCount: u32,
		glyphMetrics: [^]Glyph_Metrics,
		isSideways: windows.BOOL,
	) -> windows.HRESULT,
}

IFontFile_UUID_STRING :: "739d886a-cef5-47dc-8769-1a8b41bebbb0"
IFontFile_UUID := &IID{
	0x739d886a, 0xcef5, 0x47dc, {0x87, 0x69, 0x1a, 0x8b, 0x41, 0xbe, 0xbb, 0xb0},
}
IFontFile :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^IFontFile_VTable,
}
IFontFile_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetReferenceKey: proc "system" (
		this: ^IFontFile,
		fontFileReferenceKey: ^rawptr,
		fontFileReferenceKeySize: ^u32,
	) -> windows.HRESULT,
	GetLoader: proc "system" (this: ^IFontFile, fontFileLoader: ^^IFontFileLoader) -> windows.HRESULT,
	Analyze: proc "system" (
		this: ^IFontFile,
		isSupportedFontType: ^windows.BOOL,
		fontFileType: ^Font_File_Type,
		fontFaceType: ^Font_Face_Type,
		numberOfFaces: ^u32,
	) -> windows.HRESULT,
}

IFontFileLoader_UUID_STRING :: "727cad4e-d6af-4c9e-8a08-d695b11caa49"
IFontFileLoader_UUID := &IID{
	0x727cad4e, 0xd6af, 0x4c9e, {0x8a, 0x08, 0xd6, 0x95, 0xb1, 0x1c, 0xaa, 0x49},
}
IFontFileLoader :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^IFontFileLoader_VTable,
}
IFontFileLoader_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	CreateStreamFromKey: proc "system" (
		this: ^IFontFileLoader,
		fontFileReferenceKey: rawptr,
		fontFileReferenceKeySize: u32,
		fontFileStream: ^^IFontFileStream,
	) -> windows.HRESULT,
}

IFontFallback_UUID_STRING :: "EFA008F9-F7A1-48BF-B05C-F224713CC0FF"
IFontFallback_UUID := &IID{
	0xEFA008F9, 0xF7A1, 0x48BF, {0xB0, 0x5C, 0xF2, 0x24, 0x71, 0x3C, 0xC0, 0xFF},
}
IFontFallback :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^IFontFallback_VTable,
}
IFontFallback_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	MapCharacters: proc "system" (
		this: ^IFontFallback,
		analysisSource: ^ITextAnalysisSource,
		textPosition: u32,
		textLength: u32,
		baseFontCollection: ^IFontCollection,
		baseFamilyName: windows.wstring,
		baseWeight: Font_Weight,
		baseStyle: Font_Style,
		baseStretch: Font_Stretch,
		mappedLength: ^u32,
		mappedFont: ^^IFont,
		scale: ^f32,
	) -> windows.HRESULT,
}

IGlyphRunAnalysis_UUID_STRING :: "7d97dbf7-e085-42d4-81e3-6a883bded118"
IGlyphRunAnalysis_UUID := &IID{
	0x7d97dbf7, 0xe085, 0x42d4, {0x81, 0xe3, 0x6a, 0x88, 0x3b, 0xde, 0xd1, 0x18},
}
IGlyphRunAnalysis :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^IGlyphRunAnalysis_VTable,
}
IGlyphRunAnalysis_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetAlphaTextureBounds: proc "system" (
		this: ^IGlyphRunAnalysis,
		textureType: Texture_Type,
		textureBounds: ^windows.RECT,
	) -> windows.HRESULT,
	CreateAlphaTexture: proc "system" (
		this: ^IGlyphRunAnalysis,
		textureType: Texture_Type,
		textureBounds: ^windows.RECT,
		alphaValues: [^]u8,
		bufferSize: u32,
	) -> windows.HRESULT,
	GetAlphaBlendParams: proc "system" (
		this: ^IGlyphRunAnalysis,
		renderingParams: ^IRenderingParams,
		blendGamma: ^f32,
		blendEnhancedContrast: ^f32,
		blendClearTypeLevel: ^f32,
	) -> windows.HRESULT,
}

IRenderingParams_UUID_STRING :: "2f0da53a-2add-47cd-82ee-d9ec34688e75"
IRenderingParams_UUID := &IID{
	0x2f0da53a, 0x2add, 0x47cd, {0x82, 0xee, 0xd9, 0xec, 0x34, 0x68, 0x8e, 0x75},
}
IRenderingParams :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^IRenderingParams_VTable,
}
IRenderingParams_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetGamma: proc "system" (this: ^IRenderingParams) -> f32,
	GetEnhancedContrast: proc "system" (this: ^IRenderingParams) -> f32,
	GetClearTypeLevel: proc "system" (this: ^IRenderingParams) -> f32,
	GetPixelGeometry: proc "system" (this: ^IRenderingParams) -> Pixel_Geometry,
	GetRenderingMode: proc "system" (this: ^IRenderingParams) -> Rendering_Mode,
}

IRenderingParams1_UUID_STRING :: "94413cf4-a6fc-4248-8b50-6674348fcad3"
IRenderingParams1_UUID := &IID{
	0x94413cf4, 0xa6fc, 0x4248, {0x8b, 0x50, 0x66, 0x74, 0x34, 0x8f, 0xca, 0xd3},
}
IRenderingParams1 :: struct #raw_union {
	#subtype irenderingparams: IRenderingParams,
	using vtable: ^IRenderingParams1_VTable,
}
IRenderingParams1_VTable :: struct {
	using irenderingparams_vtable: IRenderingParams_VTable,
	GetGrayscaleEnhancedContrast: proc "system" (this: ^IRenderingParams1) -> f32,
}

IRenderingParams2_UUID_STRING :: "F9D711C3-9777-40AE-87E8-3E5AF9BF0948"
IRenderingParams2_UUID := &IID{
	0xF9D711C3, 0x9777, 0x40AE, {0x87, 0xE8, 0x3E, 0x5A, 0xF9, 0xBF, 0x09, 0x48},
}
IRenderingParams2 :: struct #raw_union {
	#subtype irenderingparams1: IRenderingParams1,
	using vtable: ^IRenderingParams2_VTable,
}
IRenderingParams2_VTable :: struct {
	using irenderingparams1_vtable: IRenderingParams1_VTable,
	GetGridFitMode: proc "system" (this: ^IRenderingParams2) -> Grid_Fit_Mode,
}

ILocalizedStrings_UUID_STRING :: "08256209-099a-4b34-b86d-c22b110e7771"
ILocalizedStrings_UUID := &IID{
	0x08256209, 0x099a, 0x4b34, {0xb8, 0x6d, 0xc2, 0x2b, 0x11, 0x0e, 0x77, 0x71},
}
ILocalizedStrings :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^ILocalizedStrings_VTable,
}
ILocalizedStrings_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetCount: proc "system" (this: ^ILocalizedStrings) -> u32,
	FindLocaleName: proc "system" (
		this: ^ILocalizedStrings,
		localeName: windows.wstring,
		index: ^u32,
		exists: ^windows.BOOL,
	) -> windows.HRESULT,
	GetLocaleNameLength: proc "system" (
		this: ^ILocalizedStrings,
		index: u32,
		length: ^u32,
	) -> windows.HRESULT,
	GetLocaleName: proc "system" (
		this: ^ILocalizedStrings,
		index: u32,
		localeName: windows.wstring,
		size: u32,
	) -> windows.HRESULT,
	GetStringLength: proc "system" (this: ^ILocalizedStrings, index: u32, length: ^u32) -> windows.HRESULT,
	GetString: proc "system" (
		this: ^ILocalizedStrings,
		index: u32,
		stringBuffer: windows.wstring,
		size: u32,
	) -> windows.HRESULT,
}

ITextAnalysisSource_UUID_STRING :: "688e1a58-5094-47c8-adc8-fbcea60ae92b"
ITextAnalysisSource_UUID := &IID{
	0x688e1a58, 0x5094, 0x47c8, {0xad, 0xc8, 0xfb, 0xce, 0xa6, 0x0a, 0xe9, 0x2b},
}
ITextAnalysisSource :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^ITextAnalysisSource_VTable,
}
ITextAnalysisSource_VTable :: struct {
	using iunknown_vtable: windows.IUnknown_VTable,
	GetTextAtPosition: proc "system" (
		this: ^ITextAnalysisSource,
		textPosition: u32,
		textString: ^windows.wstring,
		textLength: ^u32,
	) -> windows.HRESULT,
	GetTextBeforePosition: proc "system" (
		this: ^ITextAnalysisSource,
		textPosition: u32,
		textString: ^windows.wstring,
		textLength: ^u32,
	) -> windows.HRESULT,
	GetParagraphReadingDirection: proc "system" (this: ^ITextAnalysisSource) -> Reading_Direction,
	GetLocaleName: proc "system" (
		this: ^ITextAnalysisSource,
		textPosition: u32,
		textLength: ^u32,
		localeName: ^windows.wstring,
	) -> windows.HRESULT,
	GetNumberSubstitution: proc "system" (
		this: ^ITextAnalysisSource,
		textPosition: u32,
		textLength: ^u32,
		numberSubstitution: ^^INumberSubstitution,
	) -> windows.HRESULT,
}

Factory_Type :: enum i32 {
	Shared,
	Isolated,
}

IFontCollectionLoader :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^windows.IUnknown_VTable,
}

Font_Face_Type :: enum i32 {
	Cff,
	Truetype,
	Opentype_Collection,
	Type1,
	Vector,
	Bitmap,
	Unknown,
	Raw_Cff,
	Truetype_Collection = Opentype_Collection,
}

Font_Simulations :: enum i32 {
	None = 0x0000,
	Bold = 0x0001,
	Oblique = 0x0002,
}

Pixel_Geometry :: enum i32 {
	Flat,
	Rgb,
	Bgr,
}

Rendering_Mode :: enum i32 {
	Default,
	Aliased,
	Gdi_Classic,
	Gdi_Natural,
	Natural,
	Natural_Symmetric,
	Outline,
	Cleartype_Gdi_Classic = Gdi_Classic,
	Cleartype_Gdi_Natural = Gdi_Natural,
	Cleartype_Natural = Natural,
	Cleartype_Natural_Symmetric = Natural_Symmetric,
}

Font_Weight :: enum i32 {
	Thin = 100,
	Extra_Light = 200,
	Ultra_Light = 200,
	Light = 300,
	Semi_Light = 350,
	Normal = 400,
	Regular = 400,
	Medium = 500,
	Demi_Bold = 600,
	Semi_Bold = 600,
	Bold = 700,
	Extra_Bold = 800,
	Ultra_Bold = 800,
	Black = 900,
	Heavy = 900,
	Extra_Black = 950,
	Ultra_Black = 950,
}

Font_Style :: enum i32 {
	Normal,
	Oblique,
	Italic,
}

Font_Stretch :: enum i32 {
	Undefined = 0,
	Ultra_Condensed = 1,
	Extra_Condensed = 2,
	Condensed = 3,
	Semi_Condensed = 4,
	Normal = 5,
	Medium = 5,
	Semi_Expanded = 6,
	Expanded = 7,
	Extra_Expanded = 8,
	Ultra_Expanded = 9,
}

ITextFormat :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^windows.IUnknown_VTable,
}

ITypography :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^windows.IUnknown_VTable,
}

IGdiInterop :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^windows.IUnknown_VTable,
}

ITextLayout :: struct #raw_union {
	#subtype itextformat: ITextFormat,
	using vtable: ^windows.IUnknown_VTable,
}

Matrix :: struct {
	m11: f32,
	m12: f32,
	m21: f32,
	m22: f32,
	dx: f32,
	dy: f32,
}

IInlineObject :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^windows.IUnknown_VTable,
}

ITextAnalyzer :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^ITextAnalyzer_VTable,
}

Number_Substitution_Method :: enum i32 {
	From_Culture,
	Contextual,
	None,
	National,
	Traditional,
}

INumberSubstitution :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^windows.IUnknown_VTable,
}

Glyph_Run :: struct {
	fontFace: ^IFontFace,
	fontEmSize: f32,
	glyphCount: u32,
	glyphIndices: [^]u16,
	glyphAdvances: [^]f32,
	glyphOffsets: [^]Glyph_Offset,
	isSideways: windows.BOOL,
	bidiLevel: u32,
}

Measuring_Mode :: enum i32 {
	Natural,
	Gdi_Classic,
	Gdi_Natural,
}

IFontFallbackBuilder :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^windows.IUnknown_VTable,
}

Glyph_Run_Description :: struct {
	localeName: windows.wstring,
	string: windows.wstring,
	stringLength: u32,
	clusterMap: [^]u16,
	textPosition: u32,
}

IColorGlyphRunEnumerator :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^windows.IUnknown_VTable,
}

Grid_Fit_Mode :: enum i32 {
	Default,
	Disabled,
	Enabled,
}

Text_Antialias_Mode :: enum i32 {
	Cleartype,
	Grayscale,
}

Informational_String_Id :: enum i32 {
	None,
	Copyright_Notice,
	Version_Strings,
	Trademark,
	Manufacturer,
	Designer,
	Designer_Url,
	Description,
	Font_Vendor_Url,
	License_Description,
	License_Info_Url,
	Win32_Family_Names,
	Win32_Subfamily_Names,
	Typographic_Family_Names,
	Typographic_Subfamily_Names,
	Sample_Text,
	Full_Name,
	Postscript_Name,
	Postscript_Cid_Name,
	Weight_Stretch_Style_Family_Name,
	Design_Script_Language_Tag,
	Supported_Script_Language_Tag,
	Preferred_Family_Names = Typographic_Family_Names,
	Preferred_Subfamily_Names = Typographic_Subfamily_Names,
	Wws_Family_Name = Weight_Stretch_Style_Family_Name,
}

Font_Metrics :: struct {
	designUnitsPerEm: u16,
	ascent: u16,
	descent: u16,
	lineGap: i16,
	capHeight: u16,
	xHeight: u16,
	underlinePosition: i16,
	underlineThickness: u16,
	strikethroughPosition: i16,
	strikethroughThickness: u16,
}

Glyph_Metrics :: struct {
	leftSideBearing: i32,
	advanceWidth: u32,
	rightSideBearing: i32,
	topSideBearing: i32,
	advanceHeight: u32,
	bottomSideBearing: i32,
	verticalOriginY: i32,
}

Glyph_Offset :: struct {
	advanceOffset: f32,
	ascenderOffset: f32,
}

IGeometrySink :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^windows.IUnknown_VTable,
}

Font_File_Type :: enum i32 {
	Unknown,
	Cff,
	Truetype,
	Opentype_Collection,
	Type1_Pfm,
	Type1_Pfb,
	Vector,
	Bitmap,
	Truetype_Collection = Opentype_Collection,
}

IFontFileStream :: struct #raw_union {
	#subtype iunknown: windows.IUnknown,
	using vtable: ^windows.IUnknown_VTable,
}

Texture_Type :: enum i32 {
	Aliased_1x1,
	Cleartype_3x1,
}

Reading_Direction :: enum i32 {
	Left_To_Right = 0,
	Right_To_Left = 1,
	Top_To_Bottom = 2,
	Bottom_To_Top = 3,
}
