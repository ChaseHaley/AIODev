package conpty_loader

import "aio:pty"
import "core:fmt"
import "core:os"
import "core:strings"
import w "core:sys/windows"

// The fixtures expose names only; no fake ConPTY entry point is ever called.
main :: proc() {
	if len(os.args) != 3 {os.exit(2)}
	expected := os.args[1] == "true"
	bundled := pty.bundled_conpty()
	module := w.GetModuleHandleW(w.L("conpty.dll"))
	dependency := w.GetModuleHandleW(w.L("aio_work127_dependency.dll"))
	path := "-"
	buffer: [131072]u8
	if dependency != nil {
		wide: [32768]u16
		n := w.GetModuleFileNameW(dependency, &wide[0], u32(len(wide)))
		if n == 0 || n >= u32(len(wide)) {
			fmt.eprintf("GetModuleFileNameW failed: %v\n", w.GetLastError())
			os.exit(1)
		}
		path = w.wstring_to_utf8(buffer[:], cstring16(&wide[0]))
		if path == "" {os.exit(1)}
	}
	fmt.printf("bundled=%t module=%t dependency=%s\n", bundled, module != nil, path)
	if bundled != expected || (module != nil) != expected || !strings.equal_fold(path, os.args[2]) {
		os.exit(1)
	}
}
