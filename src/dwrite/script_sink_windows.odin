package dwrite

import windows "core:sys/windows"

Script_Sink :: struct {
	using interface: ITextAnalysisSink,
	scripts:         []Script_Analysis,
	methods:         ITextAnalysisSink_VTable,
}

@(require_results)
script_sink_init :: proc(sink: ^Script_Sink, scripts: []Script_Analysis) -> bool {
	if sink == nil || len(scripts) > int(max(u32)) {
		return false
	}
	sink^ = {
		scripts = scripts,
		methods = {
			iunknown_vtable = {script_query_interface, script_add_ref, script_release},
			SetScriptAnalysis = script_set,
			SetLineBreakpoints = script_line_breakpoints,
			SetBidiLevel = script_bidi,
			SetNumberSubstitution = script_substitution,
		},
	}
	// DirectWrite borrows the sink and its output storage for the duration of AnalyzeScript.
	sink.vtable = &sink.methods
	return true
}

@(private, require_results)
script_query_interface :: proc "system" (
	this: ^windows.IUnknown,
	iid: ^windows.GUID,
	object: ^rawptr,
) -> windows.HRESULT {
	if object == nil {return failure(windows.E_POINTER)}
	object^ = nil
	if iid == nil {return failure(windows.E_POINTER)}
	if iid^ != windows.IUnknown_UUID^ && iid^ != ITextAnalysisSink_UUID^ {
		return failure(windows.E_NOINTERFACE)
	}
	object^ = this
	return windows.S_OK
}

@(private)
script_add_ref :: proc "system" (this: ^windows.IUnknown) -> u32 {
	return 1
}

@(private)
script_release :: proc "system" (this: ^windows.IUnknown) -> u32 {
	return 1
}

@(private, require_results)
script_set :: proc "system" (
	this: ^ITextAnalysisSink,
	position, length: u32,
	analysis: ^Script_Analysis,
) -> windows.HRESULT {
	sink := cast(^Script_Sink)this
	if analysis == nil {return failure(windows.E_POINTER)}
	if u64(position) + u64(length) > u64(len(sink.scripts)) {
		return failure(windows.E_INVALIDARG)
	}
	for &script in sink.scripts[int(position):int(position) + int(length)] {
		script = analysis^
	}
	return windows.S_OK
}

@(private, require_results)
script_line_breakpoints :: proc "system" (
	this: ^ITextAnalysisSink,
	position, length: u32,
	breakpoints: [^]Line_Breakpoint,
) -> windows.HRESULT {
	return failure(windows.E_NOTIMPL)
}

@(private, require_results)
script_bidi :: proc "system" (
	this: ^ITextAnalysisSink,
	position, length: u32,
	explicit_level, resolved_level: u8,
) -> windows.HRESULT {
	return failure(windows.E_NOTIMPL)
}

@(private, require_results)
script_substitution :: proc "system" (
	this: ^ITextAnalysisSink,
	position, length: u32,
	substitution: ^INumberSubstitution,
) -> windows.HRESULT {
	return failure(windows.E_NOTIMPL)
}
