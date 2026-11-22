package app_test

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:frecency"
import "aio:views"

@(test)
palette_usage_survives_a_restart_without_session_ids :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-palette-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	path := strings.concatenate({directory, "/palette.json"}, context.temp_allocator)
	now := time.time_to_unix(time.now())

	first: app.App
	if !testing.expect_value(t, views.palette_init(&first.palette, nil), nil) { return }
	defer views.palette_destroy(&first.palette)
	defer app.palette_usage_store_destroy(&first.palette_store)
	app.palette_usage_enable(&first, strings.clone(path))
	usage := &first.palette.usage
	testing.expect(t, frecency.record(&usage.commands, "pane.split_right", now - 60))
	testing.expect(t, frecency.record(&usage.commands, "pane.split_right", now))
	testing.expect(t, frecency.record(&usage.settings, "terminal.font_size", now - 24 * 60 * 60))
	testing.expect(t, frecency.record(&usage.tabs, 7, now))
	// Without a recorded use pending, nothing is written.
	app.palette_usage_save(&first)
	testing.expect(t, !os.exists(path))
	app.palette_usage_touch(&first)
	app.palette_usage_save(&first)
	testing.expect(t, os.exists(path))

	second: app.App
	if !testing.expect_value(t, views.palette_init(&second.palette, nil), nil) { return }
	defer views.palette_destroy(&second.palette)
	defer app.palette_usage_store_destroy(&second.palette_store)
	app.palette_usage_enable(&second, strings.clone(path))
	app.palette_usage_load(&second)
	restored := &second.palette.usage
	for key, saved in usage.commands.entries {
		loaded, found := restored.commands.entries[key]
		if !testing.expectf(t, found, "%s was not restored", key) { continue }
		testing.expect_value(t, loaded.count, saved.count)
		testing.expect_value(t, loaded.last, saved.last)
		testing.expect(t, math.abs(loaded.weight - saved.weight) < 1e-9)
	}
	testing.expect_value(t, len(restored.commands.entries), 1)
	testing.expect_value(t, len(restored.settings.entries), 1)
	testing.expect_value(t, restored.settings.entries["terminal.font_size"].count, 1)
	// Tab ids are handed out again at each launch, so they are not saved.
	testing.expect_value(t, len(restored.tabs.entries), 0)
	// The unchanged usage is not written again.
	app.palette_usage_touch(&second)
	before, _ := os.stat(path, context.temp_allocator)
	app.palette_usage_save(&second)
	after, _ := os.stat(path, context.temp_allocator)
	testing.expect_value(t, after.modification_time, before.modification_time)

	// A damaged file starts the order over instead of failing startup.
	testing.expect_value(t, os.write_entire_file(path, "{"), nil)
	third: app.App
	if !testing.expect_value(t, views.palette_init(&third.palette, nil), nil) { return }
	defer views.palette_destroy(&third.palette)
	defer app.palette_usage_store_destroy(&third.palette_store)
	app.palette_usage_enable(&third, strings.clone(path))
	app.palette_usage_load(&third)
	testing.expect_value(t, len(third.palette.usage.commands.entries), 0)
}
