package lua_test

import "aio:lua"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private)
new_state :: proc(t: ^testing.T) -> ^lua.State {
	state := lua.L_newstate()
	if !testing.expect(t, state != nil) {return nil}
	lua.L_openlibs(state)
	return state
}

@(private)
run :: proc(t: ^testing.T, state: ^lua.State, source: cstring, results: i32) -> bool {
	if !testing.expect_value(t, lua.L_loadstring(state, source), lua.OK) {return false}
	return testing.expect_value(t, lua.pcall(state, 0, results, 0), i32(0))
}

@(test)
arithmetic_runs_in_a_new_state :: proc(t: ^testing.T) {
	state := new_state(t)
	if state == nil {return}
	defer lua.close(state)
	if !run(t, state, "return 1 + 1", 1) {return}
	testing.expect_value(t, lua.tonumber(state, -1), lua.Number(2))
}

@(test)
luajit_version_and_engine_are_enabled :: proc(t: ^testing.T) {
	state := new_state(t)
	if state == nil {return}
	defer lua.close(state)
	if !run(t, state, "return jit.version, jit.status()", 2) {return}
	testing.expect(t, strings.has_prefix(string(lua.tostring(state, -2)), "LuaJIT 2.1"))
	testing.expect(t, bool(lua.toboolean(state, -1)))
}

@(test)
bit_library_is_available_without_external_modules :: proc(t: ^testing.T) {
	state := new_state(t)
	if state == nil {return}
	defer lua.close(state)
	if !run(t, state, "return require('bit').band(6, 3)", 1) {return}
	testing.expect_value(t, lua.tointeger(state, -1), lua.Integer(2))
}

// These error tests run Lua on the test thread on purpose. The build gives LuaJIT's
// SEH error exceptions informational severity, which the test runner ignores.
@(private)
raise_from_odin :: proc "c" (state: ^lua.State) -> i32 {
	lua.L_error(state, "raised from an Odin CFunction")
	return 0
}

@(test)
pcall_catches_an_error_raised_by_an_odin_cfunction :: proc(t: ^testing.T) {
	state := new_state(t)
	if state == nil {return}
	defer lua.close(state)
	lua.pushcfunction(state, raise_from_odin)
	testing.expect_value(t, lua.pcall(state, 0, 0, 0), i32(lua.ERRRUN))
	testing.expect(t, strings.contains(string(lua.tostring(state, -1)), "raised from an Odin CFunction"))
}

@(test)
lua_pcall_inside_a_chunk_catches_error :: proc(t: ^testing.T) {
	state := new_state(t)
	if state == nil {return}
	defer lua.close(state)
	if !run(t, state, "return pcall(error, 'x')", 2) {return}
	testing.expect(t, !bool(lua.toboolean(state, -2)))
	testing.expect_value(t, string(lua.tostring(state, -1)), "x")
}

@(test)
resume_returns_an_error_raised_in_a_coroutine :: proc(t: ^testing.T) {
	state := new_state(t)
	if state == nil {return}
	defer lua.close(state)
	coroutine := lua.newthread(state)
	if !testing.expect_value(t, lua.L_loadstring(coroutine, "error('raised in a coroutine')"), lua.OK) {return}
	testing.expect_value(t, lua.resume(coroutine, 0), lua.ERRRUN)
	testing.expect(t, strings.contains(string(lua.tostring(coroutine, -1)), "raised in a coroutine"))
}

@(private)
Interrupt :: struct {
	state: ^lua.State,
	compiled: sync.Sema,
	hook_result: i32,
}

@(private)
trace_compiled :: proc "c" (state: ^lua.State) -> i32 {
	interrupt := (^Interrupt)(lua.touserdata(state, lua.GLOBALSINDEX - 1))
	sync.post(&interrupt.compiled)
	return 0
}

@(private)
interrupt_hook :: proc "c" (state: ^lua.State, _: ^lua.Debug) {
	lua.pushstring(state, "interrupted from another Odin thread")
	lua.error(state)
}

@(private)
install_interrupt :: proc(worker: ^thread.Thread) {
	interrupt := (^Interrupt)(worker.data)
	sync.wait(&interrupt.compiled)
	// The trace-stop callback runs just before entry. Allow the Lua thread to
	// enter the compiled infinite loop before changing its instruction hook.
	time.sleep(20 * time.Millisecond)
	interrupt.hook_result = lua.sethook(interrupt.state, interrupt_hook, lua.MASKCOUNT, 1)
}

@(test)
another_thread_interrupts_a_jit_compiled_infinite_loop :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)
	state := new_state(t)
	if state == nil {return}
	defer lua.close(state)
	interrupt := Interrupt{state = state}
	lua.pushlightuserdata(state, &interrupt)
	lua.pushcclosure(state, trace_compiled, 1)
	lua.setglobal(state, "trace_compiled")
	source: cstring = `
jit.opt.start("hotloop=1")
local notified = false
jit.attach(function(what)
	if what == "stop" and not notified then
		notified = true
		trace_compiled()
	end
end, "trace")
while true do end
`
	if !testing.expect_value(t, lua.L_loadstring(state, source), lua.OK) {return}
	worker := thread.create(install_interrupt)
	if !testing.expect(t, worker != nil) {return}
	worker.data = &interrupt
	thread.start(worker)
	result := lua.pcall(state, 0, 0, 0)
	thread.join(worker)
	thread.destroy(worker)
	lua.sethook(state, nil, {}, 0)
	testing.expect_value(t, interrupt.hook_result, i32(1))
	testing.expect_value(t, result, i32(lua.ERRRUN))
	testing.expect(t, strings.contains(string(lua.tostring(state, -1)), "interrupted from another Odin thread"))
}
