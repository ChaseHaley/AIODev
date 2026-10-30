package platform_test

import "aio:platform"
import "core:testing"
import "core:os"
import "core:strings"

@(test)
terminal_file_preparation_refuses_missing_and_remote_paths :: proc(t: ^testing.T) {
	for path in ([?]string{`C:\__aiodev_missing_237__.txt`, `\\server\share\file.txt`,
		`file://remote/share/file`, `C:\Windows\win.ini:stream`, `C:\Windows\NUL`}) {
		file, ok := platform.prepare_terminal_file(path)
		testing.expect(t, !ok)
		platform.terminal_file_destroy(&file)
	}
}

@(test)
terminal_file_preparation_checks_real_files_before_classifying :: proc(t: ^testing.T) {
	context.logger = {} // Malformed shortcut load is an expected OS failure.
	directory, err := os.make_directory_temp("", "aio-terminal-file-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	for name in ([?]string{"document.txt", "script.bat", "installer.msi", "shortcut.lnk"}) {
		path := strings.concatenate({directory, `\`, name})
		defer delete(path)
		defer os.remove(path)
		if !testing.expect_value(t, os.write_entire_file(path, "fixture"), nil) {continue}
		file, ok := platform.prepare_terminal_file(path)
		defer platform.terminal_file_destroy(&file)
		if name == "shortcut.lnk" {
			testing.expect(t, !ok, "a malformed shortcut must not be handed to the shell")
		} else {
			testing.expect(t, ok)
			testing.expect_value(t, file.confirm, name != "document.txt")
		}
	}
	file, ok := platform.prepare_terminal_file(directory)
	defer platform.terminal_file_destroy(&file)
	testing.expect(t, ok, "folders use the default handler too")
}

// Dispatch opens only an approved target, and a changed or unapproved target is refused before
// ShellExecute, so nothing here launches a process.
@(test)
terminal_file_dispatch_refuses_unapproved_or_changed_targets :: proc(t: ^testing.T) {
	context.logger = {}
	directory, err := os.make_directory_temp("", "aio-terminal-dispatch-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	document := strings.concatenate({directory, `\document.txt`})
	defer delete(document)
	defer os.remove(document)
	script := strings.concatenate({directory, `\script.bat`})
	defer delete(script)
	defer os.remove(script)
	if !testing.expect_value(t, os.write_entire_file(document, "fixture"), nil) {return}
	if !testing.expect_value(t, os.write_entire_file(script, "fixture"), nil) {return}
	testing.expect(t, !platform.open_terminal_file(script, ""), "an active type needs an approved target")
	testing.expect(t, !platform.open_terminal_file(document, `C:\elsewhere.bat`), "a changed target is refused")
}

// OneDrive marks every synced item with a cloud reparse tag. Machines without it skip.
@(test)
terminal_file_preparation_accepts_cloud_placeholders :: proc(t: ^testing.T) {
	root := os.get_env("OneDrive", context.temp_allocator)
	if root == "" || !os.exists(root) {return}
	file, ok := platform.prepare_terminal_file(root)
	defer platform.terminal_file_destroy(&file)
	testing.expectf(t, ok, "%s is a local sync folder", root)
	testing.expect(t, !file.confirm)
}
