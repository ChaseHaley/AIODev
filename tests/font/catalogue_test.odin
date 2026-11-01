package font_test

import "aio:font"
import "core:testing"
import "core:slice"

@(test)
installed_catalogue_and_terminal_filter :: proc(t: ^testing.T) {
	s, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(s)
	items, discovery_error := font.installed_families(s)
	if !testing.expect_value(t, discovery_error, font.Error.None) {return}
	testing.expect(t, len(items) > 0)
	mono, proportional := false, false
	for item in items {
		if item.name == "Consolas" {mono = item.monospaced}
		if item.name == "Segoe UI" {proportional = !item.monospaced}
	}
	testing.expect(t, mono && proportional)
	filtered := font.family_choices(items, false, "Consolas")
	all := font.family_choices(items, true, "Consolas")
	testing.expect(t, len(all) > len(filtered))
	testing.expect(t, slice.contains(filtered, "Consolas"))
	testing.expect(t, !slice.contains(filtered, "Segoe UI"))
	testing.expect(t, slice.contains(all, "Segoe UI"))
	preserved := font.family_choices(items, false, "AIO missing family")
	testing.expect(t, slice.contains(preserved, "AIO missing family"))
	proportional_saved := font.family_choices(items, false, "Segoe UI")
	testing.expect(t, slice.contains(proportional_saved, "Segoe UI"))
	again, again_error := font.installed_families(s)
	testing.expect_value(t, again_error, font.Error.None)
	testing.expect_value(t, raw_data(again), raw_data(items))
}

@(test)
font_choices_sort_and_preserve_empty_catalogue_value :: proc(t: ^testing.T) {
	items := [?]font.Family_Info{{"zeta", true}, {"Alpha", false}, {"Beta", true}}
	choices := font.family_choices(items[:], true, "Beta")
	testing.expect_value(t, len(choices), 3)
	testing.expect_value(t, choices[0], "Alpha")
	testing.expect_value(t, choices[1], "Beta")
	testing.expect_value(t, choices[2], "zeta")
	fallback := font.family_choices(nil, false, "Saved font")
	testing.expect_value(t, len(fallback), 1)
	testing.expect_value(t, fallback[0], "Saved font")
}
