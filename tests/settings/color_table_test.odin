package settings_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "aio:settings"

@(test)
color_entries_and_schema_colors_agree :: proc(t: ^testing.T) {
	table := settings.COLOR_ENTRIES
	count := 0
	for entry in settings.SCHEMA {
		if entry.kind == .Optional_Color {count += 1}
	}
	testing.expect_value(t, count, len(table))
	index := 0
	for entry in settings.SCHEMA {
		if entry.kind != .Optional_Color {continue}
		if index >= len(table) {break}
		color := table[index]
		testing.expectf(
			t,
			entry.key == color.key,
			"schema color %d is %s but the table has %s",
			index,
			entry.key,
			color.key,
		)
		testing.expect_value(t, entry.title, color.title)
		testing.expect_value(t, entry.description, color.description)
		testing.expect_value(
			t,
			entry.offset,
			offset_of(settings.Settings, color_overrides) + color.override_offset,
		)
		index += 1
	}
	testing.expect_value(t, index, len(settings.COLOR_ENTRIES))
}

@(test)
color_entries_resolve_each_override_to_its_own_field :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)
	for entry, i in settings.COLOR_ENTRIES {
		color := settings.Color{u8(i + 1), u8(i + 11), u8(i + 21)}
		fmt.sbprintf(&b, "%s = %s\n", entry.key, settings.color_hex(color))
	}
	s, diagnostics, err := settings.parse(strings.to_string(b))
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	overrides := uintptr(&s.color_overrides)
	colors := uintptr(&s.colors)
	for entry, i in settings.COLOR_ENTRIES {
		expected := settings.Color{u8(i + 1), u8(i + 11), u8(i + 21)}
		override := (cast(^Maybe(settings.Color))(overrides + entry.override_offset))^
		if value, present := override.?; !present || value != expected {
			testing.expectf(t, false, "%s did not store its override", entry.key)
		}
		if entry.resolved_optional {
			resolved := (cast(^Maybe(settings.Color))(colors + entry.resolved_offset))^
			if value, present := resolved.?; !present || value != expected {
				testing.expectf(t, false, "%s did not resolve its optional field", entry.key)
			}
		} else {
			resolved := (cast(^settings.Color)(colors + entry.resolved_offset))^
			testing.expectf(t, resolved == expected, "%s did not resolve its field", entry.key)
		}
	}
}

@(test)
theme_fallback_is_table_driven_except_selection_text :: proc(t: ^testing.T) {
	s, err := settings.defaults()
	testing.expect_value(t, err, nil)
	defer settings.destroy(&s)
	terminal := settings.theme_resolve(s.theme).terminal
	for entry in settings.COLOR_ENTRIES {
		expected := entry.key != "colors.selection_foreground"
		testing.expectf(
			t,
			entry.theme_fallback == expected,
			"%s fallback is %v, expected %v",
			entry.key,
			entry.theme_fallback,
			expected,
		)
		color, ok := settings.theme_color(&s, entry.key)
		testing.expectf(t, ok == entry.theme_fallback, "%s fallback presence", entry.key)
		if !ok {continue}
		testing.expect_value(
			t,
			color,
			(cast(^settings.Color)(uintptr(&terminal) + entry.resolved_offset))^,
		)
	}
}
