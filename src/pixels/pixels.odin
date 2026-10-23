package pixels

import "core:image/png"
import "core:os"

// Pixel evidence for the control channel: crop, sample, profile, diff, and a small PNG
// writer. Everything here is pure except png_read and png_write, which touch one file.

// Image is an 8-bit RGBA raster. A readback conversion owns its data; a crop is a view
// that shares the source rows, so only the pixels of a region are ever copied.
Image :: struct {
	width, height: int,
	stride:        int,
	data:          []u8,
}

Rect :: struct {
	x, y, width, height: int,
}

Error :: enum {
	None,
	Invalid_Region,
	Out_Of_Memory,
	Not_An_Image,
	Size_Mismatch,
	Read_Failed,
	Write_Failed,
}

// Profile describes one row or column: the dominant color, its share of the line, and
// how many distinct colors appear across it.
Profile :: struct {
	dominant: [4]u8,
	coverage: f32,
	colors:   int,
}

// MAX_BOXES bounds a diff report to one box per separated row band.
MAX_BOXES :: 8
// BAND_GAP is how many unchanged rows end a band, so small gaps do not split a change.
BAND_GAP :: 4

Box :: struct {
	x, y, width, height: int,
}

Diff :: struct {
	changed: int,
	boxes:   [MAX_BOXES]Box,
	count:   int,
}

@(private)
Color_Count :: struct {
	color: [4]u8,
	count: int,
}

// rect_within reports whether r is a positive rectangle inside width x height.
@(require_results)
rect_within :: proc(width, height: int, r: Rect) -> bool {
	if r.x < 0 || r.y < 0 || r.width <= 0 || r.height <= 0 {return false}
	return r.x + r.width <= width && r.y + r.height <= height
}

@(require_results)
image_create :: proc(width, height: int) -> (Image, Error) {
	if width <= 0 || height <= 0 {return {}, .Invalid_Region}
	data, allocation_error := make([]u8, width * height * 4)
	if allocation_error != nil {return {}, .Out_Of_Memory}
	return {width, height, width * 4, data}, .None
}

// image_destroy frees an image from image_create, image_from_bgra, or png_read. A crop
// borrows another image's data, so destroying a crop would free memory it does not own.
image_destroy :: proc(img: ^Image) {
	if img == nil {return}
	delete(img.data)
	img^ = {}
}

// crop returns a view of the region inside img without copying pixels.
@(require_results)
crop :: proc(img: Image, r: Rect) -> (Image, Error) {
	if !rect_within(img.width, img.height, r) {return {}, .Invalid_Region}
	offset := r.y * img.stride + r.x * 4
	return {r.width, r.height, img.stride, img.data[offset:]}, .None
}

@(require_results)
sample :: proc(img: Image, x, y: int) -> ([4]u8, Error) {
	if x < 0 || y < 0 || x >= img.width || y >= img.height {return {}, .Invalid_Region}
	at := y * img.stride + x * 4
	return {img.data[at], img.data[at + 1], img.data[at + 2], img.data[at + 3]}, .None
}

// image_from_bgra copies one region of a top-down BGRA readback into a packed RGBA image.
// Surfaces read back as BGRA, and PNG evidence is stored as RGBA.
@(require_results)
image_from_bgra :: proc(source: []u8, width: int, region: Rect) -> (Image, Error) {
	if width <= 0 || len(source) % (width * 4) != 0 {return {}, .Invalid_Region}
	height := len(source) / (width * 4)
	if !rect_within(width, height, region) {return {}, .Invalid_Region}
	img, err := image_create(region.width, region.height)
	if err != .None {return {}, err}
	for y in 0 ..< region.height {
		from_row := (region.y + y) * width * 4 + region.x * 4
		to_row := y * img.stride
		for x in 0 ..< region.width {
			from := from_row + x * 4
			to := to_row + x * 4
			img.data[to + 0] = source[from + 2]
			img.data[to + 1] = source[from + 1]
			img.data[to + 2] = source[from + 0]
			img.data[to + 3] = source[from + 3]
		}
	}
	return img, .None
}

// profile counts colors along one row, or one column when columns is set. Equally common
// colors resolve to the lowest packed #rrggbbaa value, so a profile is reproducible and
// does not depend on the order a GPU blended the pixels. Rows and columns are narrow, so
// a short list of distinct colors beats a hash map and needs no allocation per line.
@(require_results)
profile :: proc(img: Image, index: int, columns: bool) -> (Profile, Error) {
	across, steps := img.height, img.width
	if columns {across, steps = img.width, img.height}
	if index < 0 || index >= across {return {}, .Invalid_Region}
	counts, allocation_error := make([dynamic]Color_Count, 0, 8)
	if allocation_error != nil {return {}, .Out_Of_Memory}
	defer delete(counts)
	for step in 0 ..< steps {
		x, y := columns ? index : step, columns ? step : index
		at := y * img.stride + x * 4
		color := [4]u8{img.data[at], img.data[at + 1], img.data[at + 2], img.data[at + 3]}
		seen := false
		for &entry in counts {
			if entry.color != color {continue}
			entry.count += 1
			seen = true
			break
		}
		if !seen {
			if _, err := append(&counts, Color_Count{color, 1}); err != nil {
				return {}, .Out_Of_Memory
			}
		}
	}
	best := 0
	for entry, i in counts {
		champion := counts[best]
		if entry.count < champion.count {continue}
		if entry.count == champion.count && packed(entry.color) > packed(champion.color) {continue}
		best = i
	}
	return Profile {
		dominant = counts[best].color,
		coverage = f32(counts[best].count) / f32(steps),
		colors = len(counts),
	}, .None
}

@(private)
packed :: proc(color: [4]u8) -> u32 {
	return u32(color[0]) << 24 | u32(color[1]) << 16 | u32(color[2]) << 8 | u32(color[3])
}

// diff counts changed pixels and groups them into row bands: consecutive changed rows that
// are separated by fewer than BAND_GAP unchanged rows stay in one box. Bands past the
// eighth merge into it, so a report never omits changes but also never grows unbounded.
@(require_results)
diff :: proc(before, after: Image) -> (Diff, Error) {
	if before.width != after.width || before.height != after.height {return {}, .Size_Mismatch}
	result: Diff
	open, gap := false, 0
	top, bottom, left, right: int
	for y in 0 ..< after.height {
		row_left, row_right, row_changed := 0, 0, 0
		for x in 0 ..< after.width {
			at := y * after.stride + x * 4
			was := y * before.stride + x * 4
			if before.data[was + 0] == after.data[at + 0] &&
			   before.data[was + 1] == after.data[at + 1] &&
			   before.data[was + 2] == after.data[at + 2] &&
			   before.data[was + 3] == after.data[at + 3] {continue}
			if row_changed == 0 {row_left = x}
			row_right = x
			row_changed += 1
		}
		result.changed += row_changed
		if row_changed == 0 {
			if !open {continue}
			gap += 1
			// A band closes on the gap, but its bottom stays on the last changed row.
			if gap >= BAND_GAP {add_band(&result, top, bottom, left, right); open = false}
			continue
		}
		gap = 0
		if !open {
			open, top, bottom, left, right = true, y, y, row_left, row_right
			continue
		}
		bottom = y
		left = min(left, row_left)
		right = max(right, row_right)
	}
	if open {add_band(&result, top, bottom, left, right)}
	return result, .None
}

@(private)
add_band :: proc(result: ^Diff, top, bottom, left, right: int) {
	box := Box{left, top, right - left + 1, bottom - top + 1}
	if result.count < MAX_BOXES {
		result.boxes[result.count] = box
		result.count += 1
		return
	}
	last := &result.boxes[MAX_BOXES - 1]
	right_edge := max(last.x + last.width, box.x + box.width)
	bottom_edge := max(last.y + last.height, box.y + box.height)
	last.x, last.y = min(last.x, box.x), min(last.y, box.y)
	last.width, last.height = right_edge - last.x, bottom_edge - last.y
}

// PNG writing. core:image/png only decodes, so this writes the smallest valid container:
// filter 0 on every row and IDAT as stored deflate blocks. The output is a real, readable
// PNG without a compression dependency, and identical pixels produce identical bytes.

@(private)
MAX_STORED_BYTES :: 65535
@(private)
CRC_POLYNOMIAL :: u32(0xEDB88320)
@(private)
ADLER_MODULUS :: u32(65521)
@(private)
ADLER_BLOCK :: 5552

// png_write stores img as an 8-bit RGBA PNG.
@(require_results)
png_write :: proc(path: string, img: Image) -> Error {
	if img.width <= 0 || img.height <= 0 || img.stride < img.width * 4 {return .Invalid_Region}
	row_bytes := img.width * 4
	// Every row carries a leading filter byte; filter 0 means the row is stored as is.
	raw, raw_error := make([]u8, (row_bytes + 1) * img.height)
	if raw_error != nil {return .Out_Of_Memory}
	defer delete(raw)
	for y in 0 ..< img.height {
		start := y * (row_bytes + 1)
		raw[start] = 0
		copy(raw[start + 1:][:row_bytes], img.data[y * img.stride:][:row_bytes])
	}
	idat, idat_ok := zlib_stored(raw)
	if !idat_ok {return .Out_Of_Memory}
	defer delete(idat)
	file, file_error := make([dynamic]u8, 0, len(idat) + 128)
	if file_error != nil {return .Out_Of_Memory}
	defer delete(file)
	signature := [8]u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}
	if _, err := append(&file, ..signature[:]); err != nil {return .Out_Of_Memory}
	header: [13]u8
	put_u32be(header[0:4], u32(img.width))
	put_u32be(header[4:8], u32(img.height))
	header[8] = 8
	header[9] = 6
	if !put_chunk(&file, "IHDR", header[:]) {return .Out_Of_Memory}
	if !put_chunk(&file, "IDAT", idat) {return .Out_Of_Memory}
	if !put_chunk(&file, "IEND", nil) {return .Out_Of_Memory}
	if os.write_entire_file(path, file[:]) != nil {return .Write_Failed}
	return .None
}

// zlib_stored wraps raw bytes in a zlib stream of stored (uncompressed) deflate blocks.
@(private)
zlib_stored :: proc(raw: []u8) -> ([]u8, bool) {
	blocks := (len(raw) + MAX_STORED_BYTES - 1) / MAX_STORED_BYTES
	payload, allocation_error := make([]u8, 2 + blocks * 5 + len(raw) + 4)
	if allocation_error != nil {return nil, false}
	// CMF/FLG for deflate with a 32 KiB window; the check bits accept it as is.
	payload[0], payload[1] = 0x78, 0x01
	at, offset := 2, 0
	for {
		count := min(len(raw) - offset, MAX_STORED_BYTES)
		final := offset + count == len(raw)
		payload[at] = final ? 1 : 0
		payload[at + 1] = u8(count)
		payload[at + 2] = u8(count >> 8)
		inverse := u16(count) ~ 0xFFFF
		payload[at + 3] = u8(inverse)
		payload[at + 4] = u8(inverse >> 8)
		at += 5
		copy(payload[at:][:count], raw[offset:][:count])
		at += count
		offset += count
		if final {break}
	}
	put_u32be(payload[at:at + 4], adler32(raw))
	return payload, true
}

@(private)
put_u32be :: proc(dst: []u8, value: u32) {
	dst[0] = u8(value >> 24)
	dst[1] = u8(value >> 16)
	dst[2] = u8(value >> 8)
	dst[3] = u8(value)
}

@(private)
put_chunk :: proc(file: ^[dynamic]u8, kind: string, payload: []u8) -> bool {
	if len(kind) != 4 {return false}
	length: [4]u8
	put_u32be(length[:], u32(len(payload)))
	checksum: [4]u8
	put_u32be(checksum[:], crc32(kind, payload))
	if _, err := append(file, ..length[:]); err != nil {return false}
	if _, err := append(file, ..transmute([]u8)kind); err != nil {return false}
	if len(payload) > 0 {
		if _, err := append(file, ..payload); err != nil {return false}
	}
	_, err := append(file, ..checksum[:])
	return err == nil
}

// crc32 covers a chunk type and its payload, as the PNG specification requires.
@(private)
crc32 :: proc(kind: string, payload: []u8) -> u32 {
	crc := u32(0xFFFFFFFF)
	for byte in transmute([]u8)kind {crc = crc32_byte(crc, byte)}
	for byte in payload {crc = crc32_byte(crc, byte)}
	return crc ~ 0xFFFFFFFF
}

@(private)
crc32_byte :: proc(crc: u32, byte: u8) -> u32 {
	result := crc ~ u32(byte)
	for _ in 0 ..< 8 {
		if result & 1 == 1 {result = (result >> 1) ~ CRC_POLYNOMIAL} else {result >>= 1}
	}
	return result
}

@(private)
adler32 :: proc(data: []u8) -> u32 {
	low, high := u32(1), u32(0)
	// 5552 is the largest block whose sums cannot overflow before the modulo.
	for start := 0; start < len(data); start += ADLER_BLOCK {
		end := min(start + ADLER_BLOCK, len(data))
		for byte in data[start:end] {
			low += u32(byte)
			high += low
		}
		low %= ADLER_MODULUS
		high %= ADLER_MODULUS
	}
	return high << 16 | low
}

// png_read decodes an 8-bit RGB or RGBA PNG into a packed RGBA image. It reads the file
// first so a missing baseline stays distinct from one that is not a usable PNG.
@(require_results)
png_read :: proc(path: string) -> (Image, Error) {
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {return {}, .Read_Failed}
	defer delete(data)
	loaded, load_error := png.load_from_bytes(data)
	// The loader may have allocated before it failed, so always hand the result to destroy.
	defer png.destroy(loaded)
	if load_error != nil || loaded == nil {return {}, .Read_Failed}
	if loaded.depth != 8 || loaded.channels < 3 || loaded.channels > 4 {return {}, .Not_An_Image}
	img, err := image_create(loaded.width, loaded.height)
	if err != .None {return {}, err}
	for y in 0 ..< loaded.height {
		for x in 0 ..< loaded.width {
			from := (y * loaded.width + x) * loaded.channels
			to := y * img.stride + x * 4
			img.data[to + 0] = loaded.pixels.buf[from + 0]
			img.data[to + 1] = loaded.pixels.buf[from + 1]
			img.data[to + 2] = loaded.pixels.buf[from + 2]
			img.data[to + 3] = loaded.channels == 4 ? loaded.pixels.buf[from + 3] : 255
		}
	}
	return img, .None
}
