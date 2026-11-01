package platform_test

import p "aio:platform"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
executable_icon_reads_resources_and_refuses_files_without_them :: proc(t: ^testing.T) {
	root := os.get_env("SystemRoot", context.temp_allocator)
	if root == "" {root = `C:\Windows`}
	system := strings.concatenate({root, `\System32\`}, context.temp_allocator)
	cmd := strings.concatenate({system, "cmd.exe"}, context.temp_allocator)
	pixels: [28 * 28 * 4]u8
	for size in ([?]int{16, 28}) {
		testing.expect(t, p.executable_icon(cmd, size, pixels[:]))
		opaque := 0
		for i := 3; i < size * size * 4; i += 4 {
			if pixels[i] > 0 {opaque += 1}
			testing.expect(t, pixels[i - 1] <= pixels[i] && pixels[i - 3] <= pixels[i], "premultiplied")
		}
		testing.expect(t, opaque > 0 && opaque < size * size, "transparency survives")
	}
	// A file with no icon resource must not come back as the generic application icon.
	ntdll := strings.concatenate({system, "ntdll.dll"}, context.temp_allocator)
	missing := strings.concatenate({system, "missing-aiodev.exe"}, context.temp_allocator)
	testing.expect(t, !p.executable_icon(ntdll, 16, pixels[:]))
	testing.expect(t, !p.executable_icon(missing, 16, pixels[:]))
	testing.expect(t, !p.executable_icon(cmd, 29, pixels[:]), "a buffer too small is refused")
}
