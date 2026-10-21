package termbench_settings

import "core:fmt"
import "core:os"
import "aio:settings"

require :: proc(ok: bool, message: string) {
	if !ok {
		fmt.eprintln(message)
		os.exit(1)
	}
}

read_text :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	require(err == nil, "cannot read parser fixture input")
	return string(data)
}

main :: proc() {
	require(len(os.args) == 6, "expected legacy/settings/command/directory/groups fixture paths")
	command := read_text(os.args[3])
	directory := read_text(os.args[4])
	groups := read_text(os.args[5])
	before, diagnostics, before_error := settings.parse(read_text(os.args[1]))
	defer settings.destroy(&before)
	defer settings.diagnostics_destroy(&diagnostics)
	require(before_error == nil, "legacy parser allocation failed")
	require(len(diagnostics) == 1, "legacy command did not reproduce its single diagnostic")
	issue := diagnostics[0]
	require(issue.line == 1 && issue.key == "shell.command" && issue.kind == .Invalid_Value &&
		issue.message == "expected a closing double quote", "unexpected legacy command diagnostic")
	require(before.shell.command != command, "legacy command unexpectedly round-tripped")

	after, issues, after_error := settings.parse(read_text(os.args[2]))
	defer settings.destroy(&after)
	defer settings.diagnostics_destroy(&issues)
	require(after_error == nil, "generated settings parser allocation failed")
	for problem in issues {
		fmt.eprintf("line %d %s: %s\n", problem.line, problem.key, problem.message)
	}
	require(len(issues) == 0, "generated settings produced diagnostics")
	require(after.shell.command == command, "shell.command changed during settings round-trip")
	require(after.shell.directory == directory, "shell.directory changed during settings round-trip")
	require(after.process.padding_groups == groups, "process.padding_groups changed during settings round-trip")
}
