package scripting_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "aio:scripting"

@(test)
declarations_record_every_kind_in_order :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Config)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `local function hello(ctx, args) return 'hi ' .. ctx.origin end
assert(aio.action{name='say_hello', title='Say hello', run=hello, description='Greets', category='Fun',
	keywords={'greet', 'hi'}, args={count='integer', name='string?', opts={type='object'}}, repeats=true})
assert(aio.action{name='plain_2', title='Plain', run=function() end})
assert(aio.action{name='schema', title='S', run=hello, args={type='object', properties={x={type='number'}}}})
assert(aio.mode('resize', {exclusive=true}))
assert(aio.mode('nav-mode'))
assert(aio.bind('Ctrl+B>C', 'pane.split', {direction='right', ratio=0.5}))
assert(aio.unbind('Ctrl+T'))
assert(aio.bind('resize/H', hello))
assert(aio.unbind('resize/H', hello))
assert(aio.bind('Ctrl+Y', 'say_hello'))
assert(aio.unbind('Ctrl+Y', 'say_hello'))
assert(aio.bind('Ctrl+E', 'edit.copy', {}))`)
	testing.expect_value(t, len(scripting.take_errors(state)), 0)
	decls := scripting.declarations(state)
	if !testing.expect_value(t, len(decls.actions), 3) {return}
	hello := decls.actions[0]
	testing.expect_value(t, hello.name, "say_hello")
	testing.expect_value(t, hello.title, "Say hello")
	testing.expect_value(t, hello.description, "Greets")
	testing.expect_value(t, hello.category, "Fun")
	testing.expect_value(t, hello.keywords, "greet hi")
	testing.expect_value(t, hello.args, `{"count":"integer","name":"string?","opts":{"type":"object"}}`)
	testing.expect(t, hello.repeats)
	testing.expect_value(t, hello.file, "test.lua")
	testing.expect_value(t, hello.line, 2)
	testing.expect(t, hello.ref != 0)
	plain := decls.actions[1]
	testing.expect_value(t, plain.name, "plain_2")
	testing.expect_value(t, plain.description, "")
	testing.expect_value(t, plain.category, "")
	testing.expect_value(t, plain.keywords, "")
	testing.expect_value(t, plain.args, "")
	testing.expect(t, !plain.repeats)
	testing.expect_value(t, plain.line, 4)
	testing.expect(t, plain.ref != 0 && plain.ref != hello.ref)
	testing.expect_value(t, decls.actions[2].args, `{"properties":{"x":{"type":"number"}},"type":"object"}`)
	// One function keeps one ref, so the schema action shares hello's.
	testing.expect_value(t, decls.actions[2].ref, hello.ref)
	result := scripting.call(state, hello.ref, `{}`, "")
	testing.expect(t, result.ok && result.finished, result.message)
	testing.expect_value(t, result.value, `"hi config"`)

	if !testing.expect_value(t, len(decls.modes), 2) {return}
	resize := scripting.Mode_Decl{"resize", true, "test.lua", 6}
	nav := scripting.Mode_Decl{"nav-mode", false, "test.lua", 7}
	testing.expect_value(t, decls.modes[0], resize)
	testing.expect_value(t, decls.modes[1], nav)

	if !testing.expect_value(t, len(decls.keys), 7) {return}
	expected := [?]scripting.Key_Decl {
		{.Bind, "Ctrl+B>C", "pane.split", `{"direction":"right","ratio":0.5}`, 0, "test.lua", 8},
		{.Unbind, "Ctrl+T", "", "", 0, "test.lua", 9},
		{.Bind, "resize/H", "", "", hello.ref, "test.lua", 10},
		{.Unbind, "resize/H", "", "", hello.ref, "test.lua", 11},
		{.Bind, "Ctrl+Y", "say_hello", "", 0, "test.lua", 12},
		{.Unbind, "Ctrl+Y", "say_hello", "", 0, "test.lua", 13},
		{.Bind, "Ctrl+E", "edit.copy", `{}`, 0, "test.lua", 14},
	}
	for key, i in decls.keys {testing.expect_value(t, key, expected[i])}
	// Asking again without new declarations hands back the same storage.
	again := scripting.declarations(state)
	testing.expect_value(t, raw_data(again.keys), raw_data(decls.keys))
}

@(test)
declarations_skip_bad_calls_with_their_position :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Config)
	if state == nil {return}
	defer scripting.destroy(state)
	source :: `local function no(text, a, m) assert(a == nil and m:find(text, 1, true), m) end
no('lowercase', aio.action{name='Bad.Name', title='X', run=print})
no('aio.action: norun: run must be a function', aio.action{name='norun', title='X'})
no('args need', aio.bind('Ctrl+A', function() end, {x=1}))
no('target must be', aio.bind('Ctrl+A', 42))
no('aio.mode: name', aio.mode('Bad Mode'))
assert(aio.action{name='dup', title='First', run=print})
assert(aio.action{name='dup', title='Second', run=print})
local ok, a, m = pcall(aio.bind, 7, 'x'); assert(ok); no('aio.bind: key must be a nonempty string', a, m)
no('args.n', aio.action{name='typed', title='T', run=print, args={n='int'}})
no('named values', aio.bind('Ctrl+L', 'x', {1, 2}))
no('filter', aio.bindings('x'))`
	result := scripting.run_source(state, "init.lua", source)
	testing.expect(t, result.ok, result.message)
	errors := scripting.take_errors(state)
	lines := [?]int{2, 3, 4, 5, 6, 8, 9, 10, 11, 12}
	if testing.expect_value(t, len(errors), len(lines)) {
		for err, i in errors {
			testing.expect_value(t, err.file, "init.lua")
			testing.expect_value(t, err.line, lines[i])
		}
		testing.expect_value(t, errors[1].message, "init.lua:3: aio.action: norun: run must be a function")
		testing.expect(t, strings.contains(errors[5].message, "dup was already declared at init.lua:7"))
	}
	decls := scripting.declarations(state)
	if testing.expect_value(t, len(decls.actions), 1) {
		testing.expect_value(t, decls.actions[0].title, "Second")
		testing.expect_value(t, decls.actions[0].line, 8)
	}
	testing.expect_value(t, len(decls.keys), 0)
	testing.expect_value(t, len(decls.modes), 0)
}

@(test)
declarations_bindings_filter_recorded_key_ops :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Config)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `aio.bind('Ctrl+B>C', 'pane.split', {direction='right'})
aio.bind('resize/H', 'pane.resize', {dx=-1})
aio.unbind('resize/H')
local fn = function() end
aio.bind('Ctrl+/', fn)
local all = aio.bindings()
assert(#all == 4)
assert(all[1].op == 'bind' and all[1].key == 'Ctrl+B>C' and all[1].mode == nil)
assert(all[1].action == 'pane.split')
assert(all[1].args.direction == 'right' and all[1].fn == nil and all[1].source == 'test.lua:1')
assert(all[2].key == 'H' and all[2].mode == 'resize' and all[2].args.dx == -1)
assert(all[3].op == 'unbind' and all[3].key == 'H' and all[3].action == nil and all[3].fn == nil)
assert(all[4].fn == fn and all[4].key == 'Ctrl+/' and all[4].mode == nil and all[4].args == nil)
assert(#aio.bindings{mode='resize'} == 2)
assert(#aio.bindings{key='H'} == 2)
assert(#aio.bindings{action='pane.split'} == 1)
assert(#aio.bindings{mode='resize', action='pane.resize'} == 1)
assert(#aio.bindings{key='nothing'} == 0)
all[1].args.direction = 'down'
assert(aio.bindings()[1].args.direction == 'right')`)
	testing.expect_value(t, len(scripting.take_errors(state)), 0)
}

@(test)
declarations_raise_after_load_and_in_scripts :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Config)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `aio.after(0.5, function() aio.mode('late') end)
aio.action{name='late', title='Late', run=function() aio.bind('Ctrl+L', 'x') end}`)
	_, _ = scripting.step(state, 1)
	errors := scripting.take_errors(state)
	if testing.expect_value(t, len(errors), 1) {
		testing.expect_value(t, errors[0].message, "test.lua:1: aio.mode works only while init.lua loads")
	}
	decls := scripting.declarations(state)
	if !testing.expect_value(t, len(decls.actions), 1) {return}
	result := scripting.call(state, decls.actions[0].ref, `{}`, "")
	testing.expect(t, !result.ok)
	testing.expect_value(t, result.message, "test.lua:2: aio.bind works only while init.lua loads")
	testing.expect_value(t, len(scripting.declarations(state).keys), 0)

	script := new_state(t, &fake, .Script)
	if script == nil {return}
	defer scripting.destroy(script)
	names := [?]string{"action", "bind", "unbind", "mode", "bindings"}
	for name in names {
		source := fmt.tprintf("aio.%s('x')", name)
		run := scripting.run_source(script, "script.lua", source)
		testing.expect(t, !run.ok)
		expected := fmt.tprintf("script.lua:1: aio.%s works only while init.lua loads", name)
		testing.expect_value(t, run.message, expected)
	}
}

@(test)
declarations_from_a_required_file_carry_its_path :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-decl-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove(directory), nil)
	init_path := fmt.aprintf("%s\\init.lua", directory)
	defer delete(init_path)
	keys_path := fmt.aprintf("%s\\keys.lua", directory)
	defer delete(keys_path)
	init_source :: "require('keys')\naio.mode('nav')\n"
	if !testing.expect_value(t, os.write_entire_file(init_path, init_source), nil) {return}
	defer os.remove(init_path)
	keys_source := "-- keys\naio.bind('Ctrl+K', 'pane.split')\naio.mode('Bad')\n"
	if !testing.expect_value(t, os.write_entire_file(keys_path, keys_source), nil) {return}
	defer os.remove(keys_path)

	fake: Fake
	defer fake_destroy(&fake)
	config := scripting.Config{kind = .Config, root = directory}
	backend := scripting.Backend{data = &fake, command = fake_command}
	state, message := scripting.create(config, backend)
	if !testing.expect(t, state != nil, message) {return}
	defer scripting.destroy(state)
	result := scripting.run_file(state, init_path)
	testing.expect(t, result.ok, result.message)
	errors := scripting.take_errors(state)
	if testing.expect_value(t, len(errors), 1) {
		testing.expect_value(t, errors[0].file, keys_path)
		testing.expect_value(t, errors[0].line, 3)
	}
	decls := scripting.declarations(state)
	if testing.expect_value(t, len(decls.keys), 1) {
		testing.expect_value(t, decls.keys[0].file, keys_path)
		testing.expect_value(t, decls.keys[0].line, 2)
	}
	if testing.expect_value(t, len(decls.modes), 1) {
		testing.expect_value(t, decls.modes[0].file, init_path)
		testing.expect_value(t, decls.modes[0].line, 2)
	}
}
