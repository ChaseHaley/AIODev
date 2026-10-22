package ghostty

Reader_Fn :: proc "c" (userdata: rawptr, buffer: [^]u8, capacity: uint, out_read: ^uint) -> bool

Writer_Fn :: proc "c" (userdata: rawptr, data: [^]u8, len: uint) -> bool

Reader :: struct {
	read:     Reader_Fn,
	userdata: rawptr,
}

Writer :: struct {
	write:    Writer_Fn,
	userdata: rawptr,
}

Mime_Reader_Fn :: proc "c" (userdata: rawptr, mime: String, writer: Writer) -> bool

Mime_Reader :: struct {
	read:     Mime_Reader_Fn,
	userdata: rawptr,
}
