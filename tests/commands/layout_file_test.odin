package commands_test

import "core:strings"
import "core:testing"
import "aio:commands"
import "aio:layout"

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
	testing.expect(t, file.root == nil)
	testing.expect_value(t, len(file.floats), 0)
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

@(test)
layout_file_reads_nested_root_and_pane_settings :: proc(t: ^testing.T) {
	file, failure := parse(`{
		"root": {
			"split": "right", "ratio": 0.25,
			"first": {"name": "left", "command": ["tool.exe", "two words"], "profile": "pwsh"},
			"second": {
				"split": "down",
				"first": {"name": "upper", "cwd": "src"},
				"second": {"cwd": "E:\\other"}
			}
		},
		"tab": "Tree", "cwd": "D:\\work"
	}`)
	if !testing.expectf(t, failure == nil, "%v", failure) {return}
	testing.expect_value(t, file.tab, "Tree")
	testing.expect_value(t, len(file.columns), 0)
	if !testing.expect(t, file.root != nil && file.root.split) {return}
	testing.expect_value(t, file.root.direction, layout.Direction.Right)
	testing.expect_value(t, file.root.ratio, f32(0.25))
	if !testing.expect(t, file.root.first != nil && file.root.second != nil) {return}
	testing.expect(t, !file.root.first.split)
	testing.expect(t, file.root.first.first == nil && file.root.first.second == nil)
	testing.expect_value(t, file.root.first.pane,
		commands.Layout_Pane{"left", `tool.exe "two words"`, `D:\work`, "pwsh"})
	lower := file.root.second
	testing.expect(t, lower.split)
	testing.expect_value(t, lower.direction, layout.Direction.Down)
	testing.expect_value(t, lower.ratio, f32(0.5))
	if !testing.expect(t, lower.first != nil && lower.second != nil) {return}
	testing.expect_value(t, lower.first.pane, commands.Layout_Pane{name = "upper", directory = `D:\work\src`})
	testing.expect_value(t, lower.second.pane.directory, `E:\other`)
}

@(test)
layout_file_reads_leaf_root_and_float_units :: proc(t: ^testing.T) {
	file, failure := parse(`{
		"root": {"name": "main", "cwd": "src"},
		"floats": [
			{"bounds": [-0.2, 2, 3, 0.4], "pane": {"name": "share", "cwd": "float"}},
			{"unit": "cells", "bounds": [-2, 4, 80, 24],
			 "pane": {"command": ["pwsh.exe"], "profile": "shell"}},
			{"unit": "share", "bounds": [0, 0, 1, 1], "pane": {}}
		]
	}`, caller = `D:\caller`)
	if !testing.expectf(t, failure == nil, "%v", failure) {return}
	if !testing.expect(t, file.root != nil && !file.root.split) {return}
	testing.expect_value(t, file.root.pane, commands.Layout_Pane{name = "main", directory = `D:\caller\src`})
	if !testing.expect_value(t, len(file.floats), 3) {return}
	testing.expect_value(t, file.floats[0],
		commands.Layout_Float{commands.Layout_Pane{name = "share", directory = `D:\caller\float`},
			layout.Rect{-0.2, 2, 3, 0.4}, false})
	testing.expect_value(t, file.floats[1],
		commands.Layout_Float{commands.Layout_Pane{program = "pwsh.exe", directory = `D:\caller`,
			profile = "shell"}, layout.Rect{-2, 4, 80, 24}, true})
	testing.expect(t, !file.floats[2].cells)
	testing.expect_value(t, file.floats[2].pane.directory, `D:\caller`)

	columns, columns_failure := parse(`{
		"columns": [[{}]], "floats": [{"bounds": [0, 0, 1, 1], "pane": {"name": "float"}}]
	}`)
	if !testing.expectf(t, columns_failure == nil, "%v", columns_failure) {return}
	testing.expect(t, columns.root == nil)
	testing.expect_value(t, columns.floats[0].pane.name, "float")
}

@(test)
layout_file_rejects_invalid_tree_and_float_shapes :: proc(t: ^testing.T) {
	Case :: struct {
		text, field: string,
	}
	cases := [?]Case{
		{`{"floats": []}`, "columns"},
		{`{"root": {}, "columns": [[{}]]}`, "root"},
		{`{"root": null}`, "root"},
		{`{"root": []}`, "root"},
		{`{"root": {"ratio": 0.5}}`, "root.ratio"},
		{`{"root": {"first": {}}}`, "root.first"},
		{`{"root": {"name": 2}}`, "root.name"},
		{`{"root": {"split": null, "first": {}, "second": {}}}`, "root.split"},
		{`{"root": {"split": "left", "first": {}, "second": {}}}`, "root.split"},
		{`{"root": {"split": "up", "first": {}, "second": {}}}`, "root.split"},
		{`{"root": {"split": "right"}}`, "root.first"},
		{`{"root": {"split": "right", "first": {}}}`, "root.second"},
		{`{"root": {"split": "right", "first": null, "second": {}}}`, "root.first"},
		{`{"root": {"split": "right", "first": {}, "second": []}}`, "root.second"},
		{`{"root": {"split": "right", "name": "mixed", "first": {}, "second": {}}}`, "root.name"},
		{`{"root": {"split": "right", "ratio": "0.5", "first": {}, "second": {}}}`, "root.ratio"},
		{`{"root": {"split": "right", "ratio": false, "first": {}, "second": {}}}`, "root.ratio"},
		{`{"root": {"split": "right", "ratio": 0.049, "first": {}, "second": {}}}`, "root.ratio"},
		{`{"root": {"split": "right", "ratio": 0.951, "first": {}, "second": {}}}`, "root.ratio"},
		{`{"root": {"split": "right", "ratio": 1e39, "first": {}, "second": {}}}`, "root.ratio"},
		{`{"root": {"split": "right", "ratio": 1e309, "first": {}, "second": {}}}`, "root.ratio"},
		{`{"root": {"split": "down", "first": {}, "second": {"cwd": "relative"}}}`, "root.second.cwd"},
		{`{"root": {"split": "down", "first": {}, "second": {"command": ["git", 2]}}}`,
		 "root.second.command[1]"},
		{`{"root": {"split": "down", "first": {}, "second": {"split": "down", "first": {}}}}`,
		 "root.second.second"},
		{`{"root": {}, "floats": null}`, "floats"},
		{`{"root": {}, "floats": [3]}`, "floats[0]"},
		{`{"root": {}, "floats": [{}]}`, "floats[0].bounds"},
		{`{"root": {}, "floats": [{"bounds": [0, 0, 1, 1]}]}`, "floats[0].pane"},
		{`{"root": {}, "floats": [{"bounds": {}, "pane": {}}]}`, "floats[0].bounds"},
		{`{"root": {}, "floats": [{"bounds": [0, 0, 1], "pane": {}}]}`, "floats[0].bounds"},
		{`{"root": {}, "floats": [{"bounds": [0, 0, 1, 1, 1], "pane": {}}]}`, "floats[0].bounds"},
		{`{"root": {}, "floats": [{"bounds": [null, 0, 1, 1], "pane": {}}]}`, "floats[0].bounds[0]"},
		{`{"root": {}, "floats": [{"bounds": [0, "0", 1, 1], "pane": {}}]}`, "floats[0].bounds[1]"},
		{`{"root": {}, "floats": [{"bounds": [0, 0, 0, 1], "pane": {}}]}`, "floats[0].bounds[2]"},
		{`{"root": {}, "floats": [{"bounds": [0, 0, 1, -1], "pane": {}}]}`, "floats[0].bounds[3]"},
		{`{"root": {}, "floats": [{"bounds": [1e39, 0, 1, 1], "pane": {}}]}`, "floats[0].bounds[0]"},
		{`{"root": {}, "floats": [{"bounds": [0, 0, 1e39, 1], "pane": {}}]}`, "floats[0].bounds[2]"},
		{`{"root": {}, "floats": [{"bounds": [0, 0, 1, -1e309], "pane": {}}]}`, "floats[0].bounds[3]"},
		{`{"root": {}, "floats": [{"bounds": [0, 0, 1e-100, 1], "pane": {}}]}`, "floats[0].bounds[2]"},
		{`{"root": {}, "floats": [{"unit": "pixels", "bounds": [0, 0, 1, 1], "pane": {}}]}`,
		 "floats[0].unit"},
		{`{"root": {}, "floats": [{"unit": null, "bounds": [0, 0, 1, 1], "pane": {}}]}`, "floats[0].unit"},
		{`{"root": {}, "floats": [{"extra": 1, "bounds": [0, 0, 1, 1], "pane": {}}]}`, "floats[0].extra"},
		{`{"root": {}, "floats": [{"bounds": [0, 0, 1, 1], "pane": null}]}`, "floats[0].pane"},
		{`{"root": {}, "floats": [{"bounds": [0, 0, 1, 1], "pane": {"split": "right"}}]}`,
		 "floats[0].pane.split"},
		{`{"root": {}, "floats": [{"bounds": [0, 0, 1, 1], "pane": {"command": [""]}}]}`,
		 "floats[0].pane.command[0]"},
	}
	for item in cases {
		_, failure := parse(item.text)
		problem, failed := failure.?
		testing.expectf(t, failed && problem.field == item.field && problem.advice != "",
			"%q gave %v", item.text, failure)
	}
}

@(private = "file")
write_layout_chain :: proc(builder: ^strings.Builder, panes: int) {
	for _ in 1 ..< panes {
		strings.write_string(builder, `{"split": "right", "first": {}, "second": `)
	}
	strings.write_string(builder, `{}`)
	for _ in 1 ..< panes {strings.write_byte(builder, '}')}
}

@(test)
layout_file_bounds_tree_depth_and_total_panes :: proc(t: ^testing.T) {
	chain := strings.builder_make(context.temp_allocator)
	strings.write_string(&chain, `{"root": `)
	write_layout_chain(&chain, commands.LAYOUT_PANES_MAX)
	strings.write_string(&chain, `}`)
	_, chain_failure := parse(strings.to_string(chain))
	testing.expectf(t, chain_failure == nil, "%v", chain_failure)

	deep := strings.builder_make(context.temp_allocator)
	strings.write_string(&deep, `{"root": `)
	write_layout_chain(&deep, commands.LAYOUT_PANES_MAX + 1)
	strings.write_string(&deep, `}`)
	_, depth_failure := parse(strings.to_string(deep))
	depth_problem, too_deep := depth_failure.?
	path := strings.builder_make(context.temp_allocator)
	strings.write_string(&path, "root")
	for _ in 1 ..< commands.LAYOUT_PANES_MAX {strings.write_string(&path, ".second")}
	strings.write_string(&path, ".first")
	testing.expectf(t, too_deep && depth_problem.field == strings.to_string(path), "%v", depth_failure)

	many := strings.builder_make(context.temp_allocator)
	strings.write_string(&many, `{"root": {"split": "down", "first": `)
	write_layout_chain(&many, 8)
	strings.write_string(&many, `, "second": `)
	write_layout_chain(&many, 9)
	strings.write_string(&many, `}}`)
	_, many_failure := parse(strings.to_string(many))
	many_problem, too_many := many_failure.?
	testing.expectf(t, too_many && strings.has_prefix(many_problem.field, "root.second"), "%v", many_failure)

	shapes := [?]bool{false, true}
	for tree in shapes {
		for panes in commands.LAYOUT_PANES_MAX - 1 ..= commands.LAYOUT_PANES_MAX {
			text := strings.builder_make(context.temp_allocator)
			if tree {
				strings.write_string(&text, `{"root": `)
				write_layout_chain(&text, panes)
			} else {
				strings.write_string(&text, `{"columns": [[`)
				for i in 0 ..< panes {
					if i > 0 {strings.write_byte(&text, ',')}
					strings.write_string(&text, `{}`)
				}
				strings.write_string(&text, `]]`)
			}
			strings.write_string(&text, `, "floats": [{"bounds": [0, 0, 1, 1], "pane": {}}]}`)
			file, failure := parse(strings.to_string(text))
			if panes == commands.LAYOUT_PANES_MAX - 1 {
				if testing.expectf(t, failure == nil, "%v", failure) {
					testing.expect_value(t, len(file.floats), 1)
				}
			} else {
				problem, failed := failure.?
				testing.expectf(t, failed && problem.field == "floats[0].pane", "%v", failure)
			}
		}
	}
}

@(test)
layout_file_accepts_split_ratio_boundaries :: proc(t: ^testing.T) {
	file, failure := parse(`{"root": {"split": "right", "ratio": 0.05, "first": {},
		"second": {"split": "down", "ratio": 0.95, "first": {}, "second": {}}}}`)
	if !testing.expectf(t, failure == nil, "%v", failure) {return}
	if !testing.expect(t, file.root != nil && file.root.second != nil) {return}
	testing.expect_value(t, file.root.ratio, layout.SPLIT_SHARE_MIN)
	testing.expect_value(t, file.root.second.ratio, layout.SPLIT_SHARE_MAX)
}

@(test)
layout_file_bounds_inline_size_and_json_recursion :: proc(t: ^testing.T) {
	text := make([]u8, commands.LAYOUT_FILE_SIZE_MAX + 1, context.temp_allocator)
	for &c in text {c = ' '}
	document := `{"root": {}}`
	copy(text, transmute([]u8)document)
	_, exact_failure := commands.layout_file_parse(text[:commands.LAYOUT_FILE_SIZE_MAX], "", "",
		context.temp_allocator)
	testing.expectf(t, exact_failure == nil, "%v", exact_failure)
	_, large_failure := commands.layout_file_parse(text, "", "", context.temp_allocator)
	large_problem, too_large := large_failure.?
	testing.expectf(t, too_large && large_problem.field == "" &&
		strings.contains(large_problem.advice, "bytes"), "%v", large_failure)

	deep := strings.builder_make(context.temp_allocator)
	strings.write_string(&deep, `{"root": `)
	for _ in 0 ..< 256 {strings.write_byte(&deep, '[')}
	strings.write_string(&deep, `{}`)
	for _ in 0 ..< 256 {strings.write_byte(&deep, ']')}
	strings.write_byte(&deep, '}')
	_, depth_failure := parse(strings.to_string(deep))
	depth_problem, too_deep := depth_failure.?
	testing.expectf(t, too_deep && depth_problem.field == "" &&
		strings.contains(depth_problem.advice, "nested"), "%v", depth_failure)

	quoted := strings.builder_make(context.temp_allocator)
	strings.write_string(&quoted, `{"root": {"name": "\"`)
	for _ in 0 ..< 256 {strings.write_string(&quoted, "[{")}
	strings.write_string(&quoted, `\""}}`)
	_, quoted_failure := parse(strings.to_string(quoted))
	testing.expectf(t, quoted_failure == nil, "%v", quoted_failure)
}
