package dwrite

import windows "core:sys/windows"

Analysis_Source :: struct {
	using interface: ITextAnalysisSource,
	text:            []u16,
	locale:          windows.wstring,
	methods:         ITextAnalysisSource_VTable,
}

@(require_results)
analysis_source_init :: proc(
	source: ^Analysis_Source,
	text: []u16,
	locale: windows.wstring,
) -> bool {
	if source == nil || locale == nil || len(text) > int(max(u32)) {
		return false
	}
	source^ = Analysis_Source {
		text = text,
		locale = locale,
		methods = {
			iunknown_vtable = {source_query_interface, source_add_ref, source_release},
			GetTextAtPosition = source_text_at,
			GetTextBeforePosition = source_text_before,
			GetParagraphReadingDirection = source_reading_direction,
			GetLocaleName = source_locale,
			GetNumberSubstitution = source_number_substitution,
		},
	}
	// The source and its borrowed text must remain at this address until MapCharacters returns.
	source.vtable = &source.methods
	return true
}

@(private, require_results)
source_query_interface :: proc "system" (
	this: ^windows.IUnknown,
	iid: ^windows.GUID,
	object: ^rawptr,
) -> windows.HRESULT {
	if object == nil {
		return failure(windows.E_POINTER)
	}
	object^ = nil
	if iid == nil {
		return failure(windows.E_POINTER)
	}
	if iid^ != windows.IUnknown_UUID^ && iid^ != ITextAnalysisSource_UUID^ {
		return failure(windows.E_NOINTERFACE)
	}
	object^ = this
	return windows.S_OK
}

@(private)
source_add_ref :: proc "system" (this: ^windows.IUnknown) -> u32 {
	return 1
}

@(private)
source_release :: proc "system" (this: ^windows.IUnknown) -> u32 {
	return 1
}

@(private, require_results)
source_text_at :: proc "system" (
	this: ^ITextAnalysisSource,
	position: u32,
	text: ^windows.wstring,
	length: ^u32,
) -> windows.HRESULT {
	if text == nil || length == nil {
		return failure(windows.E_POINTER)
	}
	source := cast(^Analysis_Source)this
	text^ = nil
	length^ = 0
	if int(position) < len(source.text) {
		text^ = windows.wstring(&source.text[position])
		length^ = u32(len(source.text)) - position
	}
	return windows.S_OK
}

@(private, require_results)
source_text_before :: proc "system" (
	this: ^ITextAnalysisSource,
	position: u32,
	text: ^windows.wstring,
	length: ^u32,
) -> windows.HRESULT {
	if text == nil || length == nil {
		return failure(windows.E_POINTER)
	}
	source := cast(^Analysis_Source)this
	text^ = nil
	length^ = 0
	if int(position) > len(source.text) {
		return windows.S_OK
	}
	if position != 0 {
		text^ = windows.wstring(raw_data(source.text))
		length^ = position
	}
	return windows.S_OK
}

@(private)
source_reading_direction :: proc "system" (this: ^ITextAnalysisSource) -> Reading_Direction {
	return .Left_To_Right
}

@(private, require_results)
source_locale :: proc "system" (
	this: ^ITextAnalysisSource,
	position: u32,
	length: ^u32,
	locale: ^windows.wstring,
) -> windows.HRESULT {
	if length == nil || locale == nil {
		return failure(windows.E_POINTER)
	}
	source := cast(^Analysis_Source)this
	length^ = 0
	locale^ = nil
	if int(position) > len(source.text) {
		return failure(windows.E_INVALIDARG)
	}
	length^ = u32(len(source.text)) - position
	locale^ = source.locale
	return windows.S_OK
}

@(private, require_results)
source_number_substitution :: proc "system" (
	this: ^ITextAnalysisSource,
	position: u32,
	length: ^u32,
	substitution: ^^INumberSubstitution,
) -> windows.HRESULT {
	if length == nil || substitution == nil {
		return failure(windows.E_POINTER)
	}
	source := cast(^Analysis_Source)this
	length^ = 0
	substitution^ = nil
	if int(position) > len(source.text) {
		return failure(windows.E_INVALIDARG)
	}
	length^ = u32(len(source.text)) - position
	return windows.S_OK
}
