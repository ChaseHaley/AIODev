package ghostty

Point_Coordinate :: struct {
	x: u16,
	y: u32,
}

Point_Tag :: enum i32 {
	Active   = 0,
	Viewport = 1,
	Screen   = 2,
	History  = 3,
}

Point_Value :: struct #raw_union {
	coordinate: Point_Coordinate,
	_padding:   [2]u64,
}

Point :: struct {
	tag:   Point_Tag,
	value: Point_Value,
}
