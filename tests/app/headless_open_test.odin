package app_test

// The desktop build's opener launches files for real, so it compiles this out.
@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:slice"
@(require) import "core:testing"
@(require) import "core:time"
@(require) import app "../../src"
import "cosmos:platform"

when platform.HEADLESS {
	// Defect guard (WORK-446): a headless instance's file opener records the file in os.opened_paths
	// after the usual checks and starts nothing; the script here would leave a marker if it ran.
	@(test)
	headless_file_open_is_recorded_and_not_executed :: proc(t: ^testing.T) {
		root, err := os.make_directory_temp("", "aio-headless-open-*", context.allocator)
		if !testing.expect_value(t, err, nil) {return}
		defer {testing.expect_value(t, os.remove_all(root), nil); delete(root)}
		script := fmt.aprintf(`%s\run.cmd`, root)
		defer delete(script)
		marker := fmt.aprintf(`%s\ran.txt`, root)
		defer delete(marker)
		body := "@echo ran>\"%~dp0ran.txt\"\r\n"
		if !testing.expect_value(t, os.write_entire_file(script, transmute([]u8)body), nil) {return}

		testing.expect(t, !app.system_open_file(script, ""), "an active type needs an approved target")
		testing.expect(t, !slice.contains(platform.opened_paths(), script))
		testing.expect(t, app.system_open_file(script, script))
		testing.expect(t, slice.contains(platform.opened_paths(), script))
		time.sleep(500 * time.Millisecond)
		testing.expect(t, !os.exists(marker), "the headless opener ran the file")
	}
}
