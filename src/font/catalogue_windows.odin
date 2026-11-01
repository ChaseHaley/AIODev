package font

import dw "aio:dwrite"
import windows "core:sys/windows"

// Enumerates the same installed collection used for loading, including per-user fonts.
// Cache once per System lifetime; restart after installing additional fonts.
@(require_results)
installed_families :: proc(s: ^System) -> ([]Family_Info, Error) {
	if s == nil {return nil, .Invalid_Argument}
	if len(s.catalogue) > 0 {return s.catalogue[:], .None}
	s.catalogue = make([dynamic]Family_Info, s.allocator)
	complete := false
	defer if !complete {
		for entry in s.catalogue {delete(entry.name, s.allocator)}
		delete(s.catalogue)
		s.catalogue = {}
	}
	for index in 0 ..< s.collection->GetFontFamilyCount() {
		item, err := catalogue_family(s, index)
		if err != .None {
			return nil, err
		}
		if _, alloc_err := append(&s.catalogue, item); alloc_err != nil {
			delete(item.name, s.allocator)
			return nil, .Out_Of_Memory
		}
	}
	complete = true
	return s.catalogue[:], .None
}

@(private, require_results)
catalogue_family :: proc(s: ^System, index: u32) -> (Family_Info, Error) {
	family: ^dw.IFontFamily
	if !checked(s.collection->GetFontFamily(index, &family), "GetFontFamily") {return {}, .DirectWrite}
	defer release(family)
	names: ^dw.ILocalizedStrings
	if !checked(family->GetFamilyNames(&names), "GetFamilyNames") {return {}, .DirectWrite}
	defer release(names)
	locale := windows.utf8_to_wstring("en-us", context.temp_allocator)
	name_index: u32
	exists: windows.BOOL
	if !checked(names->FindLocaleName(locale, &name_index, &exists), "FindLocaleName") {
		return {}, .DirectWrite
	}
	if !exists {name_index = 0}
	length: u32
	if !checked(names->GetStringLength(name_index, &length), "GetStringLength") {return {}, .DirectWrite}
	wide := make([]u16, int(length) + 1, context.temp_allocator)
	if !checked(names->GetString(name_index, windows.wstring(raw_data(wide)), length + 1), "GetString") {
		return {}, .DirectWrite
	}
	regular: ^dw.IFont
	if !checked(family->GetFirstMatchingFont(.Normal, .Normal, .Normal, &regular), "GetFirstMatchingFont") {
		return {}, .DirectWrite
	}
	defer release(regular)
	extended: ^dw.IFont1
	if !checked(regular->QueryInterface(dw.IFont1_UUID, cast(^rawptr)&extended), "QueryInterface(Font1)") {
		return {}, .DirectWrite
	}
	defer release(extended)
	name, alloc_err := windows.wstring_to_utf8(windows.wstring(raw_data(wide)), int(length), s.allocator)
	if alloc_err != nil {return {}, .Out_Of_Memory}
	return {name, bool(extended->IsMonospacedFont()) && !bool(regular->IsSymbolFont())}, .None
}
