package app_test

import "core:fmt"
import "core:os"
import "core:testing"

// Lifecycle tests need real processes and ConPTY handles, but no interpreter startup.
// Tests that execute commands keep their actual shells.
@(private)
idle_shell_settings :: proc(t: ^testing.T, extra := "") -> string {
	directory, error := os.get_executable_directory(context.temp_allocator)
	testing.expect_value(t, error, nil)
	shell := fmt.tprintf("%s/idle-shell.exe", directory)
	testing.expect(t, os.exists(shell), "Run app tests through build.ps1 to build the idle shell fixture")
	return fmt.tprintf("shell.command = \"%s\"\n%s", shell, extra)
}
