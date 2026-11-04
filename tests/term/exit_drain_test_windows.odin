package term_test

import "aio:term"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
destroy_after_natural_exit_drains_final_recording :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-exit-drain-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path := strings.concatenate({directory, "/capture.bin"}, context.temp_allocator)
	defer os.remove(path)
	for _ in 0 ..< 3 {
		wakes: Wakes
		s := start(t, POWERSHELL + "\"[Console]::WriteLine('READY'); $null = [Console]::ReadLine(); " +
			"1..200 | ForEach-Object { [Console]::WriteLine('DRAIN_LINE_' + $_) }; " +
			"[Console]::WriteLine('AIO_FINAL_OUTPUT')\"", &wakes)
		if s == nil {return}
		defer if s != nil {term.destroy(s)}
		if !await(t, s, shows, "READY") {return}
		if !testing.expect_value(t, term.record_start(s, path), term.Record_Start_Error.None) {return}
		press_and_release(s, enter({}, 0))
		if !await(t, s, exited, "exit") {return}
		// Do not wait for the screen's final line: destroy must finish the remaining output itself.
		term.destroy(s)
		s = nil
		data, read_error := os.read_entire_file(path, context.temp_allocator)
		if !testing.expect_value(t, read_error, nil) {return}
		testing.expect(t, strings.contains(string(data), "DRAIN_LINE_200"))
		testing.expect(t, strings.contains(string(data), "AIO_FINAL_OUTPUT"))
	}
}
