package ghostty

Result :: enum i32 {
	Success = 0,
	Out_Of_Memory = -1,
	Invalid_Value = -2,
	Out_Of_Space = -3,
	No_Value = -4,
	Io_Error = -5,
	Limit_Exceeded = -6,
	Rejected = -7,
}

Terminal :: distinct rawptr

Render_State :: distinct rawptr

Render_State_Row_Iterator :: distinct rawptr

Render_State_Row_Cells :: distinct rawptr

Formatter_Format :: enum i32 {
	Plain,
	Vt,
	Html,
}

String :: struct {
	ptr: [^]u8,
	len: uint,
}

Buffer :: struct {
	ptr: [^]u8,
	cap: uint,
	len: uint,
}

Surface_Position :: struct {
	x: f64,
	y: f64,
}

Codepoints :: struct {
	ptr: [^]u32,
	len: uint,
}

sized :: proc($T: typeid) -> T {
	#assert(offset_of(T, size) == 0)
	value: T
	value.size = size_of(T)
	return value
}
