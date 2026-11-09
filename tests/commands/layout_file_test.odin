package commands_test

import "core:strings"
import "core:testing"
import "aio:commands"

@(private = "file")
parse :: proc(
	text: string,
	base := `C:\layouts`,
	caller := "",
) -> (
	commands.Layout_File,
	Maybe(commands.Layout_Error),
) {
	return commands.layout_file_parse(transmute([]u8)text, base, caller, context.temp_allocator)
}

@(test)
layout_file_reads_columns_in_order :: proc(t: ^testing.T) {
	text := "\uFEFF" + `{
		"tab": "Card 4 review",
		"cwd": "D:\\work",
		"columns": [
			[
				{"name": "A1", "command": ["claude.exe", "--model", "two words"], "profile": "pwsh"},
				{"name": "A2", "command": ["pwsh.exe"], "cwd": "sub"}
			],
			[{"name": "A3", "cwd": "E:\\other"}],
			[{}]
		]
	}`
	file, failure := parse(text)
	if !testing.expectf(t, failure == nil, "%v", failure) {return}
	testing.expect_value(t, file.tab, "Card 4 review")
	if !testing.expect_value(t, len(file.columns), 3) {return}
	testing.expect_value(t, len(file.columns[0]), 2)
	testing.expect_value(
		t,
		file.columns[0][0],
		commands.Layout_Pane{"A1", `claude.exe --model "two words"`, `D:\work`, "pwsh"},
	)
	testing.expect_value(t, file.columns[0][1], commands.Layout_Pane{"A2", "pwsh.exe", `D:\work\sub`, ""})
	testing.expect_value(t, file.columns[1][0], commands.Layout_Pane{"A3", "", `E:\other`, ""})
	testing.expect_value(t, file.columns[2][0], commands.Layout_Pane{directory = `D:\work`})
}

// A relative layout cwd belongs to the file's folder; without one, the layout's cwd is the caller's
// directory, and with neither, panes take a new tab's default.
@(test)
layout_file_resolves_directories_against_the_file :: proc(t: ^testing.T) {
	file, failure := parse(`{"cwd": "..\\repo", "columns": [[{"cwd": "src"}]]}`, `C:\work\layouts`, `D:\caller`)
	if !testing.expectf(t, failure == nil, "%v", failure) {return}
	testing.expect_value(t, file.columns[0][0].directory, `C:\work\repo\src`)
	called, called_failure := parse(`{"columns": [[{"cwd": "src"}, {}]]}`, caller = `D:\caller`)
	if !testing.expectf(t, called_failure == nil, "%v", called_failure) {return}
	testing.expect_value(t, called.columns[0][0].directory, `D:\caller\src`)
	testing.expect_value(t, called.columns[0][1].directory, `D:\caller`)
	plain, plain_failure := parse(`{"columns": [[{"name": "only"}]]}`)
	if !testing.expectf(t, plain_failure == nil, "%v", plain_failure) {return}
	testing.expect_value(t, plain.tab, "")
	testing.expect_value(t, plain.columns[0][0], commands.Layout_Pane{name = "only"})
}

@(test)
layout_file_rejects_invalid_layouts :: proc(t: ^testing.T) {
	Case :: struct {
		text, field: string,
	}
	many := strings.builder_make(context.temp_allocator)
	strings.write_string(&many, `{"columns": [[`)
	for i in 0 ..= commands.LAYOUT_PANES_MAX {
		if i > 0 {strings.write_byte(&many, ',')}
		strings.write_string(&many, `{"name": "p`)
		strings.write_int(&many, i)
		strings.write_string(&many, `"}`)
	}
	strings.write_string(&many, `]]}`)
	cases := [?]Case{
		{``, ""},
		{`{"columns": [[{}]]`, ""},
		{`{"columns": [[{}]]} trailing`, ""},
		{`{"columns": [[{}]], "columns": [[{}]]}`, ""},
		{`[[{}]]`, ""},
		{`{}`, "columns"},
		{`{"columns": []}`, "columns"},
		{`{"columns": {}}`, "columns"},
		{`{"columns": [[]]}`, "columns[0]"},
		{`{"columns": [[{}], "pane"]}`, "columns[1]"},
		{`{"columns": [[{}, 3]]}`, "columns[0][1]"},
		{`{"grid": 3, "columns": [[{}]]}`, "grid"},
		{`{"tab": 4, "columns": [[{}]]}`, "tab"},
		{`{"tab": "", "columns": [[{}]]}`, "tab"},
		{`{"cwd": null, "columns": [[{}]]}`, "cwd"},
		{`{"columns": [[{"title": "x"}]]}`, "columns[0][0].title"},
		{`{"columns": [[{"name": ""}]]}`, "columns[0][0].name"},
		{`{"columns": [[{"profile": 1}]]}`, "columns[0][0].profile"},
		{`{"columns": [[{"command": "claude.exe"}]]}`, "columns[0][0].command"},
		{`{"columns": [[{"command": []}]]}`, "columns[0][0].command"},
		{`{"columns": [[{"command": [""]}]]}`, "columns[0][0].command[0]"},
		{`{"columns": [[{}], [{"command": ["git", 2]}]]}`, "columns[1][0].command[1]"},
		{`{"columns": [[{"cwd": "relative"}]]}`, "columns[0][0].cwd"},
		{strings.to_string(many), "columns"},
	}
	for item in cases {
		_, failure := parse(item.text)
		problem, failed := failure.?
		testing.expectf(
			t,
			failed && problem.field == item.field && problem.advice != "",
			"%q gave %v",
			item.text,
			failure,
		)
	}
}
