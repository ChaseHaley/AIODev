package localpath

import w "core:sys/windows"

@(private)
VARIABLE_NAME_UNITS :: 256
@(private)
VARIABLE_VALUE_UNITS :: 4096

// env_value writes the named environment variable's value into out as UTF-8 and returns its length.
// Windows names ignore case. An unset or empty variable is not found; found but not fitting is false
// fits. No allocation: names and values convert through stack buffers.
@(private, require_results)
env_value :: proc(name: string, out: []u8) -> (length: int, found, fits: bool) {
	if name == "" || len(name) >= VARIABLE_NAME_UNITS {return 0, false, true}
	wide_name: [VARIABLE_NAME_UNITS]u16 = ---
	for i in 0 ..< len(name) {wide_name[i] = u16(name[i])}
	wide_name[len(name)] = 0
	value: [VARIABLE_VALUE_UNITS]u16 = ---
	units := int(w.GetEnvironmentVariableW(cstring16(&wide_name[0]), &value[0], VARIABLE_VALUE_UNITS))
	if units == 0 {return 0, false, true}
	if units >= VARIABLE_VALUE_UNITS {return 0, true, false}
	text := cstring16(&value[0])
	needed := int(w.WideCharToMultiByte(w.CP_UTF8, 0, text, i32(units), nil, 0, nil, nil))
	if needed <= 0 {return 0, false, true}
	if needed > len(out) {return 0, true, false}
	written := w.WideCharToMultiByte(w.CP_UTF8, 0, text, i32(units), &out[0], i32(needed), nil, nil)
	return int(written), written > 0, true
}
