package platform_test

import "core:os"
import "core:strings"
import "core:testing"
import p "aio:platform"

@(test)
local_file_within_limit_refuses_directories_devices_and_large_files :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-local-file-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer os.remove(directory)

	icon := strings.concatenate({directory, `\icon.png`})
	defer delete(icon)
	defer os.remove(icon)
	if !testing.expect_value(t, os.write_entire_file(icon, "png"), nil) {return}
	testing.expect(t, p.local_file_within_limit(icon, 32 << 20), "a small local file is allowed")
	testing.expect(t, !p.local_file_within_limit(icon, 2), "the size limit applies")
	testing.expect(t, !p.local_file_within_limit(directory, 32 << 20), "a directory is refused")

	device := strings.concatenate({`\\?\`, icon})
	defer delete(device)
	testing.expect(t, !p.local_file_within_limit(device, 32 << 20), "a device path is refused")
	testing.expect(t, !p.local_file_within_limit(`\\server\share\icon.png`, 32 << 20))
	missing := strings.concatenate({directory, `\missing.png`})
	defer delete(missing)
	testing.expect(t, !p.local_file_within_limit(missing, 32 << 20))

	oversized := strings.concatenate({directory, `\oversized.png`})
	defer delete(oversized)
	defer os.remove(oversized)
	if !testing.expect_value(t, os.write_entire_file(oversized, "png"), nil) {return}
	file, open_error := os.open(oversized, os.O_RDWR)
	if !testing.expect_value(t, open_error, nil) {return}
	truncate_error := os.truncate(file, (32 << 20) + 1)
	os.close(file)
	if !testing.expect_value(t, truncate_error, nil) {return}
	testing.expect(
		t,
		!p.local_file_within_limit(oversized, 32 << 20),
		"an oversized file is refused without being read",
	)
}
