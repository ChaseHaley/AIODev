package idle_shell

import "core:os"

// Native app tests need a live ConPTY child, but no shell interpreter or startup output.
// Script execution and shell-specific behavior remain in the PTY and live tests.
main :: proc() {
	buffer: [4096]u8
	for {
		count, error := os.read(os.stdin, buffer[:])
		if error != nil || count == 0 {return}
	}
}
