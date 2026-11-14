package commands_test

import "aio:commands"
import "aio:layout"
import "core:encoding/json"
import "core:strings"
import "core:testing"

@(private)
fields_parse :: proc(
	t: ^testing.T,
	registry: ^commands.Registry,
	name, fields: string,
) -> commands.Invocation {
	result, err := commands.parse_fields(registry, name, fields, context.temp_allocator)
	testing.expect_value(t, err, commands.Parse_Error{})
	return result
}

@(test)
fields_maps_builtin_arguments_and_defaults :: proc(t: ^testing.T) {
	registry := invocation_registry(t)
	defer commands.destroy(&registry)
	split := fields_parse(t, &registry, "pane.split", `{
		"pane":17,"direction":"down","ratio":0.3,"focus":true,"cwd":"C:\\work",
		"name":"agent","profile":"pwsh","command":["claude","--model","two words"]
	}`)
	testing.expect_value(t, split.id, commands.Command_Id(2))
	testing.expect_value(t, split.pane, "17")
	testing.expect_value(t, split.direction, layout.Direction.Down)
	testing.expect_value(t, split.ratio, f32(0.3))
	testing.expect(t, split.focus)
	testing.expect_value(t, split.directory, `C:\work`)
	testing.expect_value(t, split.name, "agent")
	testing.expect_value(t, split.profile, "pwsh")
	testing.expect_value(t, split.program, `claude --model "two words"`)
	testing.expect_value(t, split.fields, "")
	testing.expect_value(t, split.given, commands.Arguments{
		.Direction, .Ratio, .Focus, .Directory, .Name, .Profile, .Program,
	})
	tab := fields_parse(t, &registry, "tab.new", `{"tab_name":"Agents","focus":false,"command":"pwsh"}`)
	testing.expect_value(t, tab.tab_name, "Agents")
	testing.expect_value(t, tab.program, "pwsh")
	testing.expect(t, !tab.focus && .Focus not_in tab.given)
	quoted := fields_parse(t, &registry, "pane.split", `{"command":"C:\\Program Files\\tool.exe"}`)
	testing.expect_value(t, quoted.program, `"C:\Program Files\tool.exe"`)
	argv := fields_parse(t, &registry, "pane.split", `{"command":["tool.exe","","a\"b","日本"]}`)
	expected, join_error := commands.command_line_join(
		{"tool.exe", "", "a\"b", "日本"}, context.temp_allocator,
	)
	testing.expect_value(t, join_error, nil)
	testing.expect_value(t, argv.program, expected)
	all_flags := fields_parse(t, &registry, "pane.read", `{"scrollback":true,"unwrap":true}`)
	testing.expect(t, all_flags.scrollback && all_flags.unwrap)
	next := fields_parse(t, &registry, "tab.next", `{}`)
	testing.expect_value(t, next.id, commands.Command_Id(1))
	testing.expect_value(t, next.given, commands.Arguments{})
	testing.expect_value(t, next.direction, layout.Direction.Right)
	testing.expect_value(t, next.ratio, f32(0.5))
	testing.expect(t, !next.focus)
	workspace := fields_parse(t, &registry, "workspace.rename", `{"text":"Tools","workspace":42}`)
	testing.expect_value(t, workspace.workspace, "42")
}

@(test)
fields_maps_text_and_both_file_grammars :: proc(t: ^testing.T) {
	registry := invocation_registry(t)
	defer commands.destroy(&registry)
	send := fields_parse(t, &registry, "pane.send", `{"pane":"build","text":"echo hi","enter":true}`)
	testing.expect_value(t, send.pane, "build")
	testing.expect_value(t, send.text, "echo hi")
	testing.expect(t, send.enter)
	from_file := fields_parse(t, &registry, "pane.send", `{"file":"prompt.txt","enter":false}`)
	testing.expect_value(t, from_file.text_file, "prompt.txt")
	testing.expect_value(t, from_file.text, "")
	testing.expect_value(t, from_file.given, commands.Arguments{.Text_File})
	markdown := fields_parse(t, &registry, "pane.open_markdown", `{"file":"README.md","focus":true}`)
	testing.expect_value(t, markdown.file, "README.md")
	testing.expect_value(t, markdown.text_file, "")
	testing.expect_value(t, markdown.given, commands.Arguments{.File, .Focus})
	program := fields_parse(t, &registry, "pane.split", `{"command_file":"fork.json"}`)
	testing.expect_value(t, program.command_file, "fork.json")
	reading := fields_parse(t, &registry, "pane.read", `{"lines":20.0,"scrollback":true,"unwrap":false}`)
	testing.expect_value(t, reading.lines, 20)
	testing.expect(t, reading.scrollback && !reading.unwrap)
	testing.expect_value(t, reading.given, commands.Arguments{.Lines, .Scrollback})
}

@(test)
fields_formats_numbers_arrays_and_rectangles :: proc(t: ^testing.T) {
	registry := invocation_registry(t)
	defer commands.destroy(&registry)
	Case :: struct {fields, text: string}
	cases := [?]Case{
		{`{"text":12}`, "12"},
		{`{"text":12.0}`, "12"},
		{`{"text":-12.25}`, "-12.25"},
		{`{"text":9223372036854775807}`, "9223372036854775807"},
		{`{"text":[1,2.0,-3.5]}`, "1,2,-3.5"},
		{`{"text":{"h":4,"w":3.5,"y":2,"x":1}}`, "1,2,3.5,4"},
		{`{"text":[]}`, "[]"},
		{`{"text":["one", 2, true, null]}`, `["one",2,true,null]`},
		{`{"text":{"nested": [1, 2]}}`, `{"nested":[1,2]}`},
		{`{"text":{"x":1}}`, `{"x":1}`},
		{`{"text":null}`, "null"},
	}
	for item in cases {
		result := fields_parse(t, &registry, "pane.send", item.fields)
		testing.expect_value(t, result.text, item.text)
	}
	// A fifth property or a nonnumeric coordinate must not disappear into rectangle shorthand.
	for object in ([?]string{`{"x":1,"y":2,"w":3,"h":4,"extra":5}`, `{"x":1,"y":2,"w":3,"h":"4"}`}) {
		fields := strings.concatenate({`{"text":`, object, "}"}, context.temp_allocator)
		result := fields_parse(t, &registry, "pane.send", fields)
		value, err := json.parse_string(result.text, .JSON, allocator = context.temp_allocator)
		testing.expect_value(t, err, json.Error.None)
		decoded, ok := value.(json.Object)
		testing.expect(t, ok)
		testing.expect_value(t, len(decoded), strings.contains(object, "extra") ? 5 : 4)
	}
}

@(test)
fields_reports_canonical_accepted_names :: proc(t: ^testing.T) {
	registry := invocation_registry(t)
	defer commands.destroy(&registry)
	Case :: struct {name, fields, key, advice: string}
	cases := [?]Case{
		{"tab.next", `{"bogus":1}`, "bogus", "no argument named bogus; tab.next takes pane"},
		{"pane.send", `{"wat":1}`, "wat", "no argument named wat; pane.send takes pane, text, enter, file"},
		{"pane.open_markdown", `{"text":"x"}`, "text",
		 "no argument named text; pane.open_markdown takes pane, direction, focus, file"},
		{"tab.new", `{"tab-name":"x"}`, "tab-name",
		 "no argument named tab-name; tab.new takes pane, focus, name, command, tab_name"},
		{"pane.send", `{"text_file":"x"}`, "text_file",
		 "no argument named text_file; pane.send takes pane, text, enter, file"},
	}
	for item in cases {
		_, err := commands.parse_fields(&registry, item.name, item.fields, context.temp_allocator)
		testing.expect_value(t, err.argument, item.key)
		testing.expect_value(t, err.advice, item.advice)
	}
}

@(test)
fields_rejects_wrong_shapes_types_and_grammar :: proc(t: ^testing.T) {
	registry := invocation_registry(t)
	defer commands.destroy(&registry)
	Case :: struct {name, fields: string}
	cases := [?]Case{
		{"", `{}`}, {"missing", `{}`},
		{"tab.next", ""}, {"tab.next", `[]`}, {"tab.next", `null`}, {"tab.next", `42`},
		{"tab.next", `"text"`}, {"tab.next", `true`}, {"tab.next", `{"pane":`},
		{"tab.next", `{} {}`}, {"tab.next", `{"pane":"a",}`},
		{"tab.next", "{\"pane\":\"\xff\"}"},
		{"pane.split", `{"focus":"true"}`}, {"pane.split", `{"focus":1}`},
		{"pane.read", `{"unwrap":0}`}, {"pane.read", `{"scrollback":[]}`},
		{"pane.send", `{"text":true}`}, {"pane.send", `{"text":false}`},
		{"tab.next", `{"pane":false}`}, {"pane.read", `{"lines":true}`},
		{"pane.split", `{"cwd":42}`}, {"pane.split", `{"name":42}`},
		{"pane.split", `{"profile":42}`}, {"pane.split", `{"direction":42}`},
		{"tab.new", `{"tab_name":42}`}, {"pane.split", `{"command_file":42}`},
		{"pane.send", `{"file":42}`}, {"pane.open_markdown", `{"file":42}`},
		{"pane.split", `{"cwd":{"path":"x"}}`}, {"pane.split", `{"name":null}`},
		{"pane.send", `{}`}, {"pane.read", `{"lines":0}`}, {"pane.read", `{"lines":1.5}`},
		{"pane.split", `{"ratio":0.99}`}, {"pane.split", `{"direction":"sideways"}`},
		{"pane.send", `{"text":"hi","file":"prompt.txt"}`},
		{"pane.split", `{"command_file":"fork.json","command":["pwsh"]}`},
		{"pane.split", `{"command":42}`}, {"pane.split", `{"command":true}`},
		{"pane.split", `{"command":{}}`}, {"pane.split", `{"command":["pwsh",3]}`},
		{"pane.split", `{"command":[["pwsh"]]}`}, {"pane.split", `{"command":[]}`},
		{"pane.split", `{"command":""}`}, {"pane.split", `{"command":[""]}`},
	}
	for item in cases {
		_, err := commands.parse_fields(&registry, item.name, item.fields, context.temp_allocator)
		testing.expectf(t, err.advice != "", "%s %s gave %v", item.name, item.fields, err)
	}
	for program in ([?]string{`"pwsh"`, `["pwsh"]`, `[]`}) {
		fields := strings.concatenate({`{"command":`, program, "}"}, context.temp_allocator)
		_, err := commands.parse_fields(&registry, "tab.next", fields, context.temp_allocator)
		testing.expect_value(t, err, commands.Parse_Error{"--", "this command runs no program"})
	}
}

@(test)
fields_runtime_preserves_object_json_unchanged :: proc(t: ^testing.T) {
	registry := invocation_registry(t)
	defer commands.destroy(&registry)
	id, register_error := commands.register_runtime(&registry, {
		name = "custom", title = "Custom", required = {.Text},
	})
	if !testing.expect_value(t, register_error, commands.Error.None) {return}
	fields := " \n{\"pane\":false,\"command\":17,\"custom_value\":[true,{\"x\":1}]}\t"
	result := fields_parse(t, &registry, "custom", fields)
	testing.expect_value(t, result.id, id)
	testing.expect_value(t, result.fields, fields)
	testing.expect_value(t, result.pane, "")
	testing.expect_value(t, result.given, commands.Arguments{})
	testing.expect_value(t, fields_parse(t, &registry, "custom", `{}`).fields, "{}")
	for invalid in ([?]string{`[]`, `null`, `"string"`, `{} []`, `{"bad":}`}) {
		_, err := commands.parse_fields(&registry, "custom", invalid, context.temp_allocator)
		testing.expect(t, err.advice != "")
	}
}
