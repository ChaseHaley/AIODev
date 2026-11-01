package vector_test

import "core:math"
import "core:testing"
import "aio:vector"

@(private)
draw :: proc(t: ^testing.T, data: string, size: int, rule := vector.Fill_Rule.Nonzero) -> []u8 {
	coverage := make([]u8, size * size, context.temp_allocator)
	testing.expect(t, vector.fill({data}, 24, rule, size, coverage), data)
	return coverage
}

@(private)
total :: proc(coverage: []u8) -> f64 {
	sum: f64
	for value in coverage {sum += f64(value) / 255}
	return sum
}

@(test)
filled_square_covers_every_pixel_and_half_square_covers_the_left_half :: proc(t: ^testing.T) {
	for value in draw(t, "M0 0H24V24H0Z", 8) {testing.expect_value(t, value, 255)}
	half := draw(t, "M0 0H12V24H0Z", 8)
	for y in 0 ..< 8 {
		for x in 0 ..< 8 {testing.expect_value(t, half[y * 8 + x], x < 4 ? 255 : 0)}
	}
}

@(test)
edges_between_pixels_cover_them_partly :: proc(t: ^testing.T) {
	// Six units of 24 at 10 pixels end two and a half pixels in.
	coverage := draw(t, "M0 0H6V24H0Z", 10)
	testing.expect_value(t, coverage[0], 255)
	testing.expect_value(t, coverage[1], 255)
	testing.expect_value(t, coverage[2], 128)
	testing.expect_value(t, coverage[3], 0)
}

@(test)
fill_rules_differ_on_a_nested_square_wound_the_same_way :: proc(t: ^testing.T) {
	data := "M0 0H24V24H0ZM6 6H18V18H6Z"
	testing.expect_value(t, draw(t, data, 4)[5], 255)
	testing.expect_value(t, draw(t, data, 4, .Even_Odd)[5], 0)
	testing.expect_value(t, draw(t, data, 4, .Even_Odd)[0], 255)
}

@(test)
arc_circle_covers_its_area :: proc(t: ^testing.T) {
	coverage := draw(t, "M12 2a10 10 0 1 0 0 20a10 10 0 1 0 0-20z", 48)
	expected := math.PI * 20 * 20
	testing.expectf(t, abs(total(coverage) - expected) < expected * 0.01, "area %v", total(coverage))
}

@(test)
packed_numbers_relative_commands_and_implicit_lines_match_their_spelled_out_forms :: proc(t: ^testing.T) {
	pairs := [?][2]string {
		{"M0 0H24V24H0Z", "m0,0h24v24h-24z"},
		{"M0 0L24 0L0 24Z", "M0 0 24 0 0 24z"},
		{"M.5.5L23.5.5L.5 23.5Z", "M0.5 0.5L23.5 0.5L0.5 23.5Z"},
		{"M2 12a10 10 0 1124 0z", "M2 12a10 10 0 1 1 24 0z"},
		{"M0 12C0 0 12 0 12 12S24 24 24 12Z", "M0 12C0 0 12 0 12 12C12 24 24 24 24 12Z"},
		{"M0 12Q6 0 12 12T24 12Z", "M0 12Q6 0 12 12Q18 24 24 12Z"},
		{"M1e1 0H24V24H10Z", "M10 0H24V24H10Z"},
	}
	for pair in pairs {
		a, b := draw(t, pair[0], 16), draw(t, pair[1], 16)
		for i in 0 ..< len(a) {
			if a[i] != b[i] {testing.expectf(t, false, "%s differs from %s at %d", pair[0], pair[1], i); break}
		}
	}
}

@(test)
malformed_data_and_sizes_are_refused :: proc(t: ^testing.T) {
	coverage: [16]u8
	for data in ([?]string{"M0 0 L", "X1 1", "0 0", "M0 0Z 1 1", "M0 0A1 1 0 2 0 4 4", "M0 0L1"}) {
		testing.expect(t, !vector.fill({data}, 24, .Nonzero, 4, coverage[:]), data)
	}
	testing.expect(t, !vector.fill({"M0 0H24V24Z"}, 24, .Nonzero, 0, coverage[:]))
	testing.expect(t, !vector.fill({"M0 0H24V24Z"}, 24, .Nonzero, 5, coverage[:]))
	testing.expect(t, vector.fill({""}, 24, .Nonzero, 4, coverage[:]))
	for value in coverage {testing.expect_value(t, value, 0)}
}

@(test)
separate_paths_layer_without_cancelling :: proc(t: ^testing.T) {
	coverage: [16]u8
	testing.expect(t, vector.fill({"M0 0H24V24H0Z", "M0 0H12V24H0Z"}, 24, .Even_Odd, 4, coverage[:]))
	for value in coverage {testing.expect_value(t, value, 255)}
}
