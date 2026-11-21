package neovim

Msgpack_Kind :: enum u8 {
	Nil,
	Boolean,
	Integer,
	// A uint64 above max(i64); integer holds its bits.
	Unsigned,
	Float,
	String,
	Binary,
	Array,
	Map,
	// bytes is the payload and integer the application type.
	Ext,
}

// Strings and binary data borrow the reader's bytes. count is the number of array elements or
// map pairs that follow the header.
Msgpack_Value :: struct {
	kind: Msgpack_Kind,
	boolean: bool,
	integer: i64,
	real: f64,
	bytes: []u8,
	count: int,
}

Msgpack_Error :: enum u8 {
	None,
	// The object is cut off: more bytes may complete it.
	Short,
	// No continuation can make these bytes valid.
	Malformed,
}

Msgpack_Reader :: struct {
	data: []u8,
	offset: int,
}

@(private)
take :: proc(r: ^Msgpack_Reader, count: int) -> (bytes: []u8, ok: bool) {
	if count < 0 || len(r.data) - r.offset < count {return nil, false}
	bytes = r.data[r.offset:r.offset + count]
	r.offset += count
	return bytes, true
}

@(private)
big_endian :: proc(bytes: []u8) -> (value: u64) {
	for b in bytes {value = value << 8 | u64(b)}
	return value
}

@(private)
take_number :: proc(r: ^Msgpack_Reader, width: int) -> (value: u64, ok: bool) {
	bytes := take(r, width) or_return
	return big_endian(bytes), true
}

// Reads one header or scalar. An array or map yields only its header; its elements are read next.
// On any error the offset is left where it was.
@(require_results)
msgpack_read :: proc(r: ^Msgpack_Reader) -> (value: Msgpack_Value, error: Msgpack_Error) {
	start := r.offset
	defer if error != .None {r.offset = start}
	head, head_ok := take(r, 1)
	if !head_ok {return {}, .Short}
	tag := head[0]
	switch {
	case tag <= 0x7f:
		return {kind = .Integer, integer = i64(tag)}, .None
	case tag >= 0xe0:
		return {kind = .Integer, integer = i64(i8(tag))}, .None
	case tag <= 0x8f:
		return {kind = .Map, count = int(tag & 0x0f)}, .None
	case tag <= 0x9f:
		return {kind = .Array, count = int(tag & 0x0f)}, .None
	case tag <= 0xbf:
		bytes, ok := take(r, int(tag & 0x1f))
		if !ok {return {}, .Short}
		return {kind = .String, bytes = bytes}, .None
	}
	switch tag {
	case 0xc0:
		return {kind = .Nil}, .None
	case 0xc2, 0xc3:
		return {kind = .Boolean, boolean = tag == 0xc3}, .None
	case 0xc4 ..= 0xc6, 0xd9 ..= 0xdb:
		base: u8 = tag >= 0xd9 ? 0xd9 : 0xc4
		length, length_ok := take_number(r, 1 << (tag - base))
		if !length_ok {return {}, .Short}
		bytes, ok := take(r, int(length))
		if !ok {return {}, .Short}
		return {kind = tag >= 0xd9 ? .String : .Binary, bytes = bytes}, .None
	case 0xc7 ..= 0xc9:
		length, length_ok := take_number(r, 1 << (tag - 0xc7))
		if !length_ok {return {}, .Short}
		return read_ext(r, int(length))
	case 0xd4 ..= 0xd8:
		return read_ext(r, 1 << (tag - 0xd4))
	case 0xca:
		bits, ok := take_number(r, 4)
		if !ok {return {}, .Short}
		return {kind = .Float, real = f64(transmute(f32)u32(bits))}, .None
	case 0xcb:
		bits, ok := take_number(r, 8)
		if !ok {return {}, .Short}
		return {kind = .Float, real = transmute(f64)bits}, .None
	case 0xcc ..= 0xcf:
		width := 1 << (tag - 0xcc)
		bits, ok := take_number(r, width)
		if !ok {return {}, .Short}
		if bits > u64(max(i64)) {return {kind = .Unsigned, integer = i64(bits)}, .None}
		return {kind = .Integer, integer = i64(bits)}, .None
	case 0xd0 ..= 0xd3:
		width := 1 << (tag - 0xd0)
		bits, ok := take_number(r, width)
		if !ok {return {}, .Short}
		shift := u64(64 - 8 * width)
		return {kind = .Integer, integer = i64(bits << shift) >> shift}, .None
	case 0xdc, 0xdd, 0xde, 0xdf:
		count, ok := take_number(r, 2 << ((tag - 0xdc) & 1))
		if !ok {return {}, .Short}
		return {kind = tag >= 0xde ? .Map : .Array, count = int(count)}, .None
	}
	return {}, .Malformed
}

@(private)
read_ext :: proc(r: ^Msgpack_Reader, length: int) -> (value: Msgpack_Value, error: Msgpack_Error) {
	type_byte, type_ok := take(r, 1)
	if !type_ok {return {}, .Short}
	payload, ok := take(r, length)
	if !ok {return {}, .Short}
	return {kind = .Ext, integer = i64(i8(type_byte[0])), bytes = payload}, .None
}

// Consumes one whole object with everything nested in it. Iterative, so a hostile nesting depth
// costs no stack. On any error the offset is left where it was.
@(require_results)
msgpack_skip :: proc(r: ^Msgpack_Reader) -> (error: Msgpack_Error) {
	start := r.offset
	defer if error != .None {r.offset = start}
	pending := 1
	for pending > 0 {
		value := msgpack_read(r) or_return
		pending -= 1
		#partial switch value.kind {
		case .Array: pending += value.count
		case .Map: pending += 2 * value.count
		}
	}
	return .None
}

// failed records an allocation failure, so callers can build a whole message and test once.
Msgpack_Writer :: struct {
	bytes: [dynamic]u8,
	failed: bool,
}

@(private)
put :: proc(w: ^Msgpack_Writer, bytes: ..u8) {
	if _, err := append(&w.bytes, ..bytes); err != nil {w.failed = true}
}

@(private)
put_number :: proc(w: ^Msgpack_Writer, tag: u8, value: u64, width: int) {
	buffer: [9]u8
	buffer[0] = tag
	for index in 0 ..< width {buffer[1 + index] = u8(value >> u64(8 * (width - 1 - index)))}
	put(w, ..buffer[:1 + width])
}

msgpack_write_nil :: proc(w: ^Msgpack_Writer) {
	put(w, 0xc0)
}

msgpack_write_bool :: proc(w: ^Msgpack_Writer, value: bool) {
	put(w, value ? 0xc3 : 0xc2)
}

msgpack_write_uint :: proc(w: ^Msgpack_Writer, value: u64) {
	switch {
	case value <= 0x7f: put(w, u8(value))
	case value <= u64(max(u8)): put_number(w, 0xcc, value, 1)
	case value <= u64(max(u16)): put_number(w, 0xcd, value, 2)
	case value <= u64(max(u32)): put_number(w, 0xce, value, 4)
	case: put_number(w, 0xcf, value, 8)
	}
}

// Picks the smallest encoding, as Neovim's own packer does.
msgpack_write_int :: proc(w: ^Msgpack_Writer, value: i64) {
	switch {
	case value >= 0: msgpack_write_uint(w, u64(value))
	case value >= -32: put(w, u8(value))
	case value >= i64(min(i8)): put_number(w, 0xd0, u64(value), 1)
	case value >= i64(min(i16)): put_number(w, 0xd1, u64(value), 2)
	case value >= i64(min(i32)): put_number(w, 0xd2, u64(value), 4)
	case: put_number(w, 0xd3, u64(value), 8)
	}
}

msgpack_write_f32 :: proc(w: ^Msgpack_Writer, value: f32) {
	put_number(w, 0xca, u64(transmute(u32)value), 4)
}

msgpack_write_f64 :: proc(w: ^Msgpack_Writer, value: f64) {
	put_number(w, 0xcb, transmute(u64)value, 8)
}

// Header only; the caller appends length bytes with msgpack_write_raw.
msgpack_write_str_header :: proc(w: ^Msgpack_Writer, length: int) {
	switch {
	case length < 32: put(w, 0xa0 | u8(length))
	case length <= int(max(u8)): put_number(w, 0xd9, u64(length), 1)
	case length <= int(max(u16)): put_number(w, 0xda, u64(length), 2)
	case: put_number(w, 0xdb, u64(length), 4)
	}
}

msgpack_write_raw :: proc(w: ^Msgpack_Writer, bytes: []u8) {
	if _, err := append(&w.bytes, ..bytes); err != nil {w.failed = true}
}

msgpack_write_str :: proc(w: ^Msgpack_Writer, text: string) {
	msgpack_write_str_header(w, len(text))
	msgpack_write_raw(w, transmute([]u8)text)
}

msgpack_write_bin :: proc(w: ^Msgpack_Writer, bytes: []u8) {
	switch {
	case len(bytes) <= int(max(u8)): put_number(w, 0xc4, u64(len(bytes)), 1)
	case len(bytes) <= int(max(u16)): put_number(w, 0xc5, u64(len(bytes)), 2)
	case: put_number(w, 0xc6, u64(len(bytes)), 4)
	}
	msgpack_write_raw(w, bytes)
}

msgpack_write_array :: proc(w: ^Msgpack_Writer, count: int) {
	switch {
	case count < 16: put(w, 0x90 | u8(count))
	case count <= int(max(u16)): put_number(w, 0xdc, u64(count), 2)
	case: put_number(w, 0xdd, u64(count), 4)
	}
}

msgpack_write_map :: proc(w: ^Msgpack_Writer, count: int) {
	switch {
	case count < 16: put(w, 0x80 | u8(count))
	case count <= int(max(u16)): put_number(w, 0xde, u64(count), 2)
	case: put_number(w, 0xdf, u64(count), 4)
	}
}

msgpack_write_ext :: proc(w: ^Msgpack_Writer, type_id: i8, payload: []u8) {
	switch len(payload) {
	case 1: put(w, 0xd4)
	case 2: put(w, 0xd5)
	case 4: put(w, 0xd6)
	case 8: put(w, 0xd7)
	case 16: put(w, 0xd8)
	case:
		switch {
		case len(payload) <= int(max(u8)): put_number(w, 0xc7, u64(len(payload)), 1)
		case len(payload) <= int(max(u16)): put_number(w, 0xc8, u64(len(payload)), 2)
		case: put_number(w, 0xc9, u64(len(payload)), 4)
		}
	}
	put(w, u8(type_id))
	msgpack_write_raw(w, payload)
}
