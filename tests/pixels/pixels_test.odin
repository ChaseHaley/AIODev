package pixels_test

import "core:os"
import "core:strings"
import "core:testing"
import "aio:pixels"

// put writes one pixel into an image created by this test.
put :: proc(img: ^pixels.Image, x, y: int, color: [4]u8) {
	at := y * img.stride + x * 4
	img.data[at + 0] = color[0]
	img.data[at + 1] = color[1]
	img.data[at + 2] = color[2]
	img.data[at + 3] = color[3]
}

// filled creates a uniform image, so a test only writes the pixels it cares about.
filled :: proc(t: ^testing.T, width, height: int, color: [4]u8) -> pixels.Image {
	img, err := pixels.image_create(width, height)
	if !testing.expect_value(t, err, pixels.Error.None) {return {}}
	for y in 0 ..< height {
		for x in 0 ..< width {put(&img, x, y, color)}
	}
	return img
}

@(test)
crop_is_a_view_and_sample_reads_exact_pixels :: proc(t: ^testing.T) {
	img, err := pixels.image_create(4, 3)
	if !testing.expect_value(t, err, pixels.Error.None) {return}
	defer pixels.image_destroy(&img)
	for y in 0 ..< 3 {
		for x in 0 ..< 4 {put(&img, x, y, [4]u8{u8(x), u8(y), u8(x + y), 255})}
	}
	region, crop_error := pixels.crop(img, {1, 1, 2, 2})
	if !testing.expect_value(t, crop_error, pixels.Error.None) {return}
	testing.expect_value(t, region.width, 2)
	testing.expect_value(t, region.height, 2)
	corner, corner_error := pixels.sample(region, 1, 1)
	testing.expect_value(t, corner_error, pixels.Error.None)
	testing.expect_value(t, corner, [4]u8{2, 2, 4, 255})

	// A crop borrows its rows, so a later write to the source is visible through it.
	put(&img, 1, 1, [4]u8{9, 8, 7, 6})
	updated, _ := pixels.sample(region, 0, 0)
	testing.expect_value(t, updated, [4]u8{9, 8, 7, 6})
}

@(test)
crop_and_sample_reject_regions_outside_the_image :: proc(t: ^testing.T) {
	img := filled(t, 4, 3, {1, 2, 3, 4})
	if img.data == nil {return}
	defer pixels.image_destroy(&img)
	regions := [?]pixels.Rect {
		{-1, 0, 1, 1},
		{0, -1, 1, 1},
		{0, 0, 0, 1},
		{0, 0, 1, 0},
		{3, 0, 2, 1},
		{0, 2, 1, 2},
	}
	for region in regions {
		_, err := pixels.crop(img, region)
		testing.expectf(t, err == pixels.Error.Invalid_Region, "crop %v was accepted", region)
	}
	for position in ([?][2]int{{-1, 0}, {0, -1}, {4, 0}, {0, 3}}) {
		_, err := pixels.sample(img, position.x, position.y)
		testing.expectf(t, err == pixels.Error.Invalid_Region, "sample %v was accepted", position)
	}
	_, zero_error := pixels.image_create(0, 1)
	testing.expect_value(t, zero_error, pixels.Error.Invalid_Region)
}

@(test)
bgra_readback_converts_and_crops :: proc(t: ^testing.T) {
	source := []u8 {
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		8,
		9,
		10,
		11,
		12,
		13,
		14,
		15,
		16,
	}
	img, err := pixels.image_from_bgra(source, 2, {1, 0, 1, 2})
	if !testing.expect_value(t, err, pixels.Error.None) {return}
	defer pixels.image_destroy(&img)
	testing.expect_value(t, img.width, 1)
	testing.expect_value(t, img.height, 2)
	top, _ := pixels.sample(img, 0, 0)
	testing.expect_value(t, top, [4]u8{7, 6, 5, 8})
	bottom, _ := pixels.sample(img, 0, 1)
	testing.expect_value(t, bottom, [4]u8{15, 14, 13, 16})

	// A source that is not whole rows, or a region past its edge, is refused.
	_, ragged := pixels.image_from_bgra(source[:15], 2, {0, 0, 1, 1})
	testing.expect_value(t, ragged, pixels.Error.Invalid_Region)
	_, outside := pixels.image_from_bgra(source, 2, {1, 0, 2, 1})
	testing.expect_value(t, outside, pixels.Error.Invalid_Region)
}

@(test)
profile_reports_dominance_coverage_and_a_stable_tie_break :: proc(t: ^testing.T) {
	a := [4]u8{40, 10, 10, 255}
	b := [4]u8{60, 60, 60, 255}
	c := [4]u8{20, 0, 0, 255}
	d := [4]u8{10, 0, 0, 255}
	img := filled(t, 4, 2, {0, 0, 0, 255})
	if img.data == nil {return}
	defer pixels.image_destroy(&img)
	put(&img, 0, 0, a)
	put(&img, 1, 0, a)
	put(&img, 2, 0, a)
	put(&img, 3, 0, b)
	put(&img, 0, 1, c)
	put(&img, 1, 1, c)
	put(&img, 2, 1, d)
	put(&img, 3, 1, d)

	first, first_error := pixels.profile(img, 0, false)
	testing.expect_value(t, first_error, pixels.Error.None)
	testing.expect_value(t, first.dominant, a)
	testing.expect_value(t, first.coverage, f32(0.75))
	testing.expect_value(t, first.colors, 2)

	// Two colors tie here; the lower packed rgba wins even though it appears second.
	tied, tied_error := pixels.profile(img, 1, false)
	testing.expect_value(t, tied_error, pixels.Error.None)
	testing.expect_value(t, tied.dominant, d)
	testing.expect_value(t, tied.coverage, f32(0.5))
	testing.expect_value(t, tied.colors, 2)

	// Columns read the same colors in the other direction.
	column, column_error := pixels.profile(img, 0, true)
	testing.expect_value(t, column_error, pixels.Error.None)
	testing.expect_value(t, column.dominant, c)
	testing.expect_value(t, column.coverage, f32(0.5))
	testing.expect_value(t, column.colors, 2)
	last, last_error := pixels.profile(img, 3, true)
	testing.expect_value(t, last_error, pixels.Error.None)
	testing.expect_value(t, last.dominant, d)

	_, out_of_range := pixels.profile(img, 2, false)
	testing.expect_value(t, out_of_range, pixels.Error.Invalid_Region)
	_, column_range := pixels.profile(img, 4, true)
	testing.expect_value(t, column_range, pixels.Error.Invalid_Region)
}

@(test)
diff_unchanged_and_size_mismatch :: proc(t: ^testing.T) {
	before := filled(t, 4, 4, {1, 2, 3, 4})
	if before.data == nil {return}
	defer pixels.image_destroy(&before)
	after := filled(t, 4, 4, {1, 2, 3, 4})
	if after.data == nil {return}
	defer pixels.image_destroy(&after)
	result, err := pixels.diff(before, after)
	testing.expect_value(t, err, pixels.Error.None)
	testing.expect_value(t, result.changed, 0)
	testing.expect_value(t, result.count, 0)

	narrow := filled(t, 3, 4, {1, 2, 3, 4})
	if narrow.data == nil {return}
	defer pixels.image_destroy(&narrow)
	_, mismatch := pixels.diff(before, narrow)
	testing.expect_value(t, mismatch, pixels.Error.Size_Mismatch)
}

@(test)
diff_groups_changes_into_separated_row_bands :: proc(t: ^testing.T) {
	before := filled(t, 8, 12, {0, 0, 0, 255})
	if before.data == nil {return}
	defer pixels.image_destroy(&before)
	after := filled(t, 8, 12, {0, 0, 0, 255})
	if after.data == nil {return}
	defer pixels.image_destroy(&after)
	changed := [4]u8{255, 255, 255, 255}
	put(&after, 2, 0, changed)
	put(&after, 3, 0, changed)
	// Four unchanged rows close the first band.
	put(&after, 0, 5, changed)
	// Only three unchanged rows separate the next change, so it joins the second band.
	put(&after, 6, 9, changed)
	// Four more unchanged rows close the last band.
	put(&after, 7, 11, changed)

	result, err := pixels.diff(before, after)
	testing.expect_value(t, err, pixels.Error.None)
	testing.expect_value(t, result.changed, 5)
	testing.expect_value(t, result.count, 2)
	testing.expect_value(t, result.boxes[0], pixels.Box{2, 0, 2, 1})
	testing.expect_value(t, result.boxes[1], pixels.Box{0, 5, 8, 7})
}

@(test)
diff_merges_bands_past_the_eighth_box :: proc(t: ^testing.T) {
	before := filled(t, 4, 91, {0, 0, 0, 255})
	if before.data == nil {return}
	defer pixels.image_destroy(&before)
	after := filled(t, 4, 91, {0, 0, 0, 255})
	if after.data == nil {return}
	defer pixels.image_destroy(&after)
	changed := [4]u8{9, 9, 9, 255}
	for row := 0; row <= 90; row += 10 {put(&after, 1, row, changed)}
	result, err := pixels.diff(before, after)
	testing.expect_value(t, err, pixels.Error.None)
	testing.expect_value(t, result.changed, 10)
	testing.expect_value(t, result.count, pixels.MAX_BOXES)
	// Bands one past the last box extend it instead of disappearing.
	testing.expect_value(t, result.boxes[pixels.MAX_BOXES - 1], pixels.Box{1, 70, 1, 21})
}

@(test)
png_round_trip_preserves_pixels_and_bytes :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-pixels-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	first := strings.concatenate({directory, `\first.png`})
	defer delete(first)
	defer os.remove(first)
	second := strings.concatenate({directory, `\second.png`})
	defer delete(second)
	defer os.remove(second)

	img, image_error := pixels.image_create(3, 2)
	if !testing.expect_value(t, image_error, pixels.Error.None) {return}
	defer pixels.image_destroy(&img)
	colors := [?][4]u8 {
		{255, 0, 0, 255},
		{0, 255, 0, 128},
		{0, 0, 255, 255},
		{1, 2, 3, 4},
		{250, 251, 252, 253},
		{0, 0, 0, 0},
	}
	for color, i in colors {put(&img, i % 3, i / 3, color)}
	testing.expect_value(t, pixels.png_write(first, img), pixels.Error.None)
	testing.expect_value(t, pixels.png_write(second, img), pixels.Error.None)

	loaded, read_error := pixels.png_read(first)
	if !testing.expect_value(t, read_error, pixels.Error.None) {return}
	defer pixels.image_destroy(&loaded)
	testing.expect_value(t, loaded.width, 3)
	testing.expect_value(t, loaded.height, 2)
	for color, i in colors {
		actual, _ := pixels.sample(loaded, i % 3, i / 3)
		testing.expectf(t, actual == color, "pixel %d: got %v, expected %v", i, actual, color)
	}

	// Identical pixels produce identical bytes, so captures are reproducible evidence.
	written, written_error := os.read_entire_file(first, context.allocator)
	if !testing.expect_value(t, written_error, nil) {return}
	defer delete(written)
	again, again_error := os.read_entire_file(second, context.allocator)
	if !testing.expect_value(t, again_error, nil) {return}
	defer delete(again)
	testing.expectf(t, string(written) == string(again), "the PNG encoder is not deterministic")

	missing := strings.concatenate({directory, `\missing.png`})
	defer delete(missing)
	_, missing_error := pixels.png_read(missing)
	testing.expect_value(t, missing_error, pixels.Error.Read_Failed)
	text := strings.concatenate({directory, `\text.png`})
	defer delete(text)
	defer os.remove(text)
	if !testing.expect_value(t, os.write_entire_file(text, "not a png"), nil) {return}
	_, text_error := pixels.png_read(text)
	testing.expect_value(t, text_error, pixels.Error.Read_Failed)
}
