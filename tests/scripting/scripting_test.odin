package scripting_test

import "core:strings"
import "core:testing"
import "core:time"
import "aio:events"
import "aio:lua"
import "aio:scripting"

Recorded_Call :: struct {pane: u32, name, fields, origin: string}

Fake :: struct {
	calls: [dynamic]Recorded_Call,
	wanted: events.Kinds,
	logs: int,
}

fake_command :: proc(data: rawptr, pane: u32, name, fields, origin: string) -> string {
	fake := cast(^Fake)data
	append(&fake.calls, Recorded_Call{pane, strings.clone(name), strings.clone(fields), strings.clone(origin)})
	switch name {
	case "pane.split": return `{"ok":true,"status":0,"pane":7}`
	case "pane.read": return `{"ok":true,"status":0,"text":"hello\n"}`
	case "app.view": return `{"ok":true,"status":0,"view":{"root":{"pane":7}}}`
	case "edit.clipboard_read", "settings.get": return `{"ok":true,"status":0,"text":"value"}`
	case "my_action": return `{"ok":true,"status":0,"result":{"answer":42}}`
	case "app.select", "app.input": return `{"ok":true,"status":0,"prompt":21}`
	case "bad": return `{"ok":false,"status":3,"error":"no such pane"}`
	case: return `{"ok":true,"status":0}`
	}
}

fake_interest :: proc(data: rawptr, kinds: events.Kinds) {(cast(^Fake)data).wanted = kinds}
fake_log :: proc(data: rawptr, _: string, _: string) {(cast(^Fake)data).logs += 1}

fake_destroy :: proc(fake: ^Fake) {
	for entry in fake.calls {
		delete(entry.name)
		delete(entry.fields)
		delete(entry.origin)
	}
	delete(fake.calls)
}

// Steps at 0 first, so test clocks count from the moment the state was created.
new_state :: proc(t: ^testing.T, fake: ^Fake, kind: scripting.Host_Kind, budget_ms: f64 = 0) -> ^scripting.State {
	state, message := scripting.create(
		{kind = kind, root = ".", pane = 5, args = `{"flag":true}`, budget_ms = budget_ms},
		{data = fake, command = fake_command, interest = fake_interest, log = fake_log},
	)
	testing.expect(t, state != nil, message)
	if state != nil {_, _ = scripting.step(state, 0)}
	return state
}

check :: proc(t: ^testing.T, state: ^scripting.State, source: string, loc := #caller_location) {
	result := scripting.run_source(state, "test.lua", source)
	testing.expect(t, result.ok, result.message, loc = loc)
}

// Steps with the elapsed real time plus base until nothing is pending or five seconds pass.
drain :: proc(state: ^scripting.State, base: f64) {
	began := time.tick_now()
	for scripting.busy(state) && time.tick_since(began) < 5 * time.Second {
		_, _ = scripting.step(state, base + f64(time.tick_since(began)) / f64(time.Second))
		time.sleep(time.Millisecond)
	}
}

@(test)
commands_share_conversion_and_lazy_namespaces :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Config)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `
		local split = assert(aio.pane.split{direction='right'})
		assert(split.pane == 7 and split.ok == nil and split.status == nil)
		assert(aio.pane.split == aio.pane.split)
		assert(aio.pane.read{}.text == 'hello\n')
		local value, message, status = aio.run('bad')
		assert(value == nil and message == 'no such pane' and status == 3)
		assert(aio.invoke('my_action', {x=1}).answer == 42)
		assert(aio.view().root.pane == 7)
		assert(aio.clipboard.get() == 'value')
		assert(aio.clipboard.set('copied'))
		assert(aio.settings.get('font.size') == 'value')
		assert(aio.settings.set('font.size', 12))
		assert(aio.notify{title='Title', body='Body'})
		assert(aio.stop == nil or type(aio.stop) == 'table')
		print('hello', 42)
	`)
	if !testing.expect_value(t, len(fake.calls), 10) {return}
	testing.expect_value(t, fake.calls[0].pane, u32(5))
	testing.expect_value(t, fake.calls[0].name, "pane.split")
	testing.expect_value(t, fake.calls[0].fields, `{"direction":"right"}`)
	testing.expect_value(t, fake.calls[0].origin, "config")
	testing.expect_value(t, fake.calls[1].fields, `{}`)
	testing.expect_value(t, fake.calls[3].fields, `{"x":1}`)
	testing.expect_value(t, fake.calls[6].fields, `{"text":"copied"}`)
	testing.expect_value(t, fake.calls[8].fields, `{"name":"font.size","text":"12"}`)
	testing.expect_value(t, fake.calls[9].name, "app.notify")
	testing.expect_value(t, fake.calls[9].fields, `{"text":"Body","title":"Title"}`)
	testing.expect_value(t, fake.logs, 1)
}

@(test)
json_is_data_only_and_rejects_cycles_and_invalid_numbers :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Config)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `
		local json = aio.json
		local text = assert(json.encode({a={1,2,3}, b='a\n"\\', yes=true, no=false}))
		assert(text == '{"a":[1,2,3],"b":"a\\n\\"\\\\","no":false,"yes":true}', text)
		local value = assert(json.decode(text))
		assert(value.a[2] == 2 and value.b == 'a\n"\\' and value.yes and not value.no)
		assert(json.encode({}) == '{}')
		assert(json.encode({1,2}) == '[1,2]')
		assert(json.encode(0.1) == '0.1' and json.encode(1/3) == '0.33333333333333331')
		assert(json.decode(json.encode(1/3)) == 1/3)
		assert(json.decode('null') == nil)
		local list = assert(json.decode('[1,null,3]'))
		assert(list[1] == 1 and list[2] == nil and list[3] == 3)
		assert(json.decode('"\\uD83D\\uDE00"') == '\240\159\152\128')
		local cycle = {}; cycle.self = cycle
		local encoded, message = json.encode(cycle)
		assert(encoded == nil and message:find('cycle'))
		assert(json.encode(function() end) == nil)
		assert(json.encode({f=print}) == nil)
		assert(json.encode(0/0) == nil)
		assert(json.encode(math.huge) == nil)
		assert(json.decode('{"x":1,}') == nil)
		assert(json.decode('[1,]') == nil)
		assert(json.decode('01') == nil)
		assert(json.decode('1e') == nil)
		assert(json.decode('1.e2') == nil)
		assert(json.decode('os.execute("bad")') == nil)
		assert(json.decode('true false') == nil)
		assert(json.encode({a=1}, {indent=2}) == '{\n  "a": 1\n}')
	`)
}

@(test)
events_preserve_context_and_isolate_handler_errors :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Config)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `
		aio.on('pane.exited', function() error('handler failed') end)
		aio.on('pane.exited', function(ctx, ev)
			assert(ctx.pane == 19 and ctx.origin == 'event')
			assert(ev.type == 'pane.exited' and ev.pane == 19 and ev.exit_code == 2)
			aio.pane.read{}
			aio.sleep(0.5)
			aio.pane.read{}
			handled = true
		end)
		assert(not pcall(aio.on, 'not.an.event', function() end))
	`)
	testing.expect(t, .Pane_Exited in fake.wanted)
	scripting.deliver(state, []events.Event{{kind = .Pane_Exited, fields = `{"pane":19,"exit_code":2}`}})
	if !testing.expect_value(t, len(fake.calls), 1) {return}
	testing.expect_value(t, fake.calls[0].pane, u32(19))
	check(t, state, `assert(not handled)`)
	_, _ = scripting.step(state, 1)
	check(t, state, `assert(handled)`)
	if !testing.expect_value(t, len(fake.calls), 2) {return}
	testing.expect_value(t, fake.calls[1].pane, u32(19))
	errors := scripting.take_errors(state)
	if testing.expect_value(t, len(errors), 1) {
		testing.expect(t, strings.contains(errors[0].message, "handler failed"))
		testing.expect_value(t, errors[0].file, "test.lua")
		testing.expect_value(t, errors[0].line, 2)
	}
	testing.expect_value(t, len(scripting.take_errors(state)), 0)
}

@(test)
wait_filters_sleep_and_timeout_resume_through_host_steps :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Script)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `
		assert(aio.args.flag and aio.pane_id == 5)
		local ev = assert(aio.wait('pane.bell', {pane=8}, 2))
		assert(ev.pane == 8 and ev.type == 'pane.bell')
		got_event = true
		assert(aio.sleep(1))
		slept = true
		local value, message = aio.wait('pane.bell', function(e) return e.pane == 9 end, 1)
		assert(value == nil and message == 'timeout')
		timed_out = true
	`)
	testing.expect(t, .Pane_Bell in fake.wanted)
	scripting.deliver(state, []events.Event{{kind = .Pane_Bell, fields = `{"pane":7}`}})
	check(t, state, `assert(not got_event)`)
	scripting.deliver(state, []events.Event{{kind = .Pane_Bell, fields = `{"pane":8}`}})
	check(t, state, `assert(got_event and not slept)`)
	testing.expect(t, .Pane_Bell not_in fake.wanted)
	_, _ = scripting.step(state, 1.5)
	check(t, state, `assert(slept and not timed_out)`)
	scripting.deliver(state, []events.Event{{kind = .Pane_Bell, fields = `{"pane":8}`}})
	check(t, state, `assert(not timed_out)`)
	_, _ = scripting.step(state, 3)
	check(t, state, `assert(timed_out)`)
	testing.expect(t, !scripting.busy(state))
	testing.expect(t, .Pane_Bell not_in fake.wanted)
}

@(test)
timers_cancel_coalesce_and_enforce_live_limit :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Script)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `
		count = 0
		repeating = aio.every(1, function(ctx)
			assert(ctx.origin == 'timer' and ctx.pane == 5)
			count = count + 1
			aio.sleep(5)
		end)
		local cancelled = aio.after(1, function() error('cancelled timer ran') end)
		cancelled:cancel()
		assert(not cancelled:active())
		aio.after(1, function() once = true end)
	`)
	next, has_next := scripting.step(state, 0.5)
	testing.expect(t, has_next && next > 0.5 && next < 1.5)
	_, _ = scripting.step(state, 1.5)
	check(t, state, `assert(count == 1 and once and repeating:active())`)
	// The first run sleeps until about 6.5; ticks due meanwhile are skipped, not queued.
	_, _ = scripting.step(state, 4)
	_, _ = scripting.step(state, 6)
	check(t, state, `assert(count == 1)`)
	_, _ = scripting.step(state, 7)
	check(t, state, `assert(count == 2); repeating:cancel(); assert(not repeating:active())`)
	testing.expect_value(t, len(scripting.take_errors(state)), 0)
	_, stopped_early := scripting.stopped(state)
	testing.expect(t, !stopped_early)
	check(t, state, `
		local live = {}
		for i = 1, 1024 do live[i] = assert(aio.after(100, function() end)) end
		local ok, message = pcall(aio.after, 1, function() end)
		assert(not ok and message:find('1024'))
		for _, timer in ipairs(live) do timer:cancel() end
		assert(aio.after(1, function() end))
	`)
	code, stopped := scripting.stopped(state)
	testing.expect(t, stopped)
	testing.expect_value(t, code, 1)
}

@(test)
config_refuses_loading_yields_and_keeps_state_after_budget_error :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Config, 25)
	if state == nil {return}
	defer scripting.destroy(state)
	result := scripting.run_source(state, "init.lua", `aio.sleep(1)`)
	testing.expect(t, !result.ok)
	testing.expect_value(t, result.message, "init.lua:1: aio.sleep cannot run while init.lua loads")
	began := time.tick_now()
	result = scripting.run_source(state, "budget.lua", "local n = 0\nwhile true do n = n + 1 end")
	testing.expect(t, !result.ok)
	testing.expect(t, time.tick_since(began) < 2 * time.Second)
	testing.expect_value(t, result.message, "budget.lua:2: took longer than 25 ms")
	testing.expect_value(t, result.file, "budget.lua")
	testing.expect_value(t, result.line, 2)
	check(t, state, `assert(2 + 2 == 4)`)
	// A handler gets its own budget, and its interruption is collected rather than raised.
	check(t, state, `aio.on('pane.bell', function() while true do end end)`)
	scripting.deliver(state, []events.Event{{kind = .Pane_Bell, fields = `{"pane":5}`}})
	errors := scripting.take_errors(state)
	if testing.expect_value(t, len(errors), 1) {testing.expect(t, strings.contains(errors[0].message, "took longer than 25 ms"))}
	result = scripting.run_source(state, "popen.lua", `io.popen('echo hi')`)
	testing.expect_value(t, result.message, "popen.lua:1: use aio.system")
	result = scripting.run_source(state, "execute.lua", `os.execute('echo hi')`)
	testing.expect_value(t, result.message, "execute.lua:1: use aio.system")
	result = scripting.run_source(state, "location.lua", "local a = 1\nerror('located')")
	testing.expect(t, !result.ok)
	testing.expect_value(t, result.file, "location.lua")
	testing.expect_value(t, result.line, 2)
	check(t, state, `assert(bit.band(6, 3) == 2 and jit.version and ffi.sizeof('int') == 4)`)
	check(t, state, `assert(package.path == '.\\?.lua;.\\?\\init.lua')`)
}

@(test)
registry_calls_report_exact_false_and_can_suspend :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Config)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `
		function binding(ctx, args) assert(ctx.pane == 11 and args.key == 'a'); return false end
		function falsy() return nil end
		function waiting_binding() aio.sleep(1); called = true; return false end
	`)
	L := scripting.lua_state(state)
	lua.getglobal(L, "binding")
	ref := lua.L_ref(L, lua.REGISTRYINDEX)
	result := scripting.call(state, ref, `{"pane":11,"origin":"key"}`, `{"key":"a"}`)
	testing.expect(t, result.ok && result.finished && result.returned_false, result.message)
	testing.expect_value(t, result.value, "false")
	scripting.ref_release(state, ref)
	lua.getglobal(L, "falsy")
	ref = lua.L_ref(L, lua.REGISTRYINDEX)
	result = scripting.call(state, ref, `{}`, "")
	testing.expect(t, result.ok && result.finished && !result.returned_false, result.message)
	scripting.ref_release(state, ref)
	lua.getglobal(L, "waiting_binding")
	ref = lua.L_ref(L, lua.REGISTRYINDEX)
	result = scripting.call(state, ref, `{}`, "")
	testing.expect(t, result.ok && !result.finished && !result.returned_false, result.message)
	scripting.ref_release(state, ref)
	_, _ = scripting.step(state, 1.5)
	check(t, state, `assert(called)`)
}

@(test)
prompts_resume_with_original_items_and_one_based_index :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Script)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `
		local items = {{name='first'}, {name='second'}}
		local item, index = aio.ui.select(items, {prompt='Choose', format_item=function(i) return i.name end})
		assert(item == items[2] and index == 2)
		chosen = true
	`)
	if !testing.expect_value(t, len(fake.calls), 1) {return}
	testing.expect_value(t, fake.calls[0].name, "app.select")
	testing.expect_value(t, fake.calls[0].fields, `{"items":"[\"first\",\"second\"]","title":"Choose"}`)
	scripting.deliver(state, []events.Event{{kind = .Prompt_Closed, fields = `{"prompt":20,"cancelled":false,"index":1}`}})
	check(t, state, `assert(not chosen)`)
	scripting.deliver(state, []events.Event{{kind = .Prompt_Closed, fields = `{"prompt":21,"cancelled":false,"index":2}`}})
	check(t, state, `
		assert(chosen)
		aio.ui.input({prompt='Name', default='x'}, function(text) assert(text == nil); cancelled = true end)
	`)
	scripting.deliver(state, []events.Event{{kind = .Prompt_Closed, fields = `{"prompt":21,"cancelled":true}`}})
	check(t, state, `assert(cancelled)`)
	testing.expect_value(t, len(scripting.take_errors(state)), 0)
}

@(test)
layout_builders_produce_the_layout_document :: proc(t: ^testing.T) {
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Config)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `
		local left = aio.layout.pane{name='editor', command={'nvim'}, cwd='C:\\src', profile='dev'}
		local right = aio.layout.pane{command={'cmd.exe'}}
		local root = aio.layout.split('right', 0.4, left, right)
		local floating = aio.layout.float{bounds={0.1,0.2,0.3,0.4}, unit='share', pane=right}
		assert(aio.layout.apply{tab='Work', cwd='C:\\src', root=root, floats={floating}})
		assert(aio.layout.split('left', 0.5, {}, {}) == nil)
		assert(aio.layout.split('down', 1.5, {}, {}) == nil)
	`)
	if !testing.expect_value(t, len(fake.calls), 1) {return}
	testing.expect_value(t, fake.calls[0].name, "layout.apply")
	testing.expect_value(
		t,
		fake.calls[0].fields,
		`{"layout":{"cwd":"C:\\src","floats":[{"bounds":[0.1,0.2,0.3,0.4],"pane":{"command":["cmd.exe"]},"unit":"share"}],` +
		`"root":{"first":{"command":["nvim"],"cwd":"C:\\src","name":"editor","profile":"dev"},"ratio":0.4,` +
		`"second":{"command":["cmd.exe"]},"split":"right"},"tab":"Work"}}`,
	)
}

@(test)
system_wait_collects_text_and_callback_scope_terminates_children :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 30 * time.Second)
	fake: Fake
	defer fake_destroy(&fake)
	state := new_state(t, &fake, .Script)
	if state == nil {return}
	defer scripting.destroy(state)
	check(t, state, `
		local process = assert(aio.system({'cmd.exe', '/d', '/c', 'echo hi'}))
		assert(process.pid > 0)
		local result = assert(process:wait())
		assert(result.stdout == 'hi\n' and result.stderr == '' and result.code == 0 and result.ok and not result.timed_out)
		collected = true
		local missing, message = aio.system({'aio-no-such-program.exe'})
		assert(missing == nil and type(message) == 'string')
	`)
	drain(state, 0)
	check(t, state, `assert(collected)`)
	check(t, state, `
		aio.on('pane.bell', function()
			child = assert(aio.system({'cmd.exe', '/d', '/c', 'ping -n 30 127.0.0.1 >nul'}))
			survivor = assert(aio.system({'cmd.exe', '/d', '/c', 'ping -n 2 127.0.0.1 >nul'}, {detach = true}))
		end)
	`)
	scripting.deliver(state, []events.Event{{kind = .Pane_Bell, fields = `{"pane":5}`}})
	drain(state, 10)
	check(t, state, `
		assert(child:is_closing() and child:wait().code ~= 0)
		assert(survivor:wait().code == 0)
	`)
	testing.expect_value(t, len(scripting.take_errors(state)), 0)
}
