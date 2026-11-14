package scripting

import "core:c"
import "core:time"
import "aio:events"
import "aio:lua"

// Natives are the table runtime.lua receives as `native`. runtime.lua validates arguments, so
// these trust their argument types.

// command(pane, name, fields JSON, origin) -> reply JSON
@(private)
native_command :: proc "c" (L: ^lua.State) -> c.int {
	s := state_at(L)
	context = s.ctx
	if s.backend.command == nil {
		push_text(L, `{"ok":false,"status":1,"error":"no command backend"}`)
		return 1
	}
	pane := u32(lua.tointeger(L, 1))
	reply := s.backend.command(s.backend.data, pane, text_at(L, 2), text_at(L, 3), text_at(L, 4))
	push_text(L, reply)
	budget_restart(s)
	return 1
}

// interest({[name] = true}) replaces the kinds this state wants delivered.
@(private)
native_interest :: proc "c" (L: ^lua.State) -> c.int {
	s := state_at(L)
	context = s.ctx
	if s.backend.interest == nil {return 0}
	wanted: events.Kinds
	lua.pushnil(L)
	for lua.next(L, 1) != 0 {
		kind, ok := events.kind_named(text_at(L, -2))
		if ok && bool(lua.toboolean(L, -1)) {wanted += {kind}}
		lua.pop(L, 1)
	}
	s.backend.interest(s.backend.data, wanted)
	return 0
}

// log(level, message)
@(private)
native_log :: proc "c" (L: ^lua.State) -> c.int {
	s := state_at(L)
	context = s.ctx
	if s.backend.log != nil {s.backend.log(s.backend.data, text_at(L, 1), text_at(L, 2))}
	return 0
}

// clock() -> monotonic seconds, for process timeouts and busy waits that cannot use step's clock.
@(private)
native_clock :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushnumber(L, lua.Number(f64(time.tick_since({})) / f64(time.Second)))
	return 1
}

// pause() sleeps briefly between polls of a Script host's busy process wait.
@(private)
native_pause :: proc "c" (_: ^lua.State) -> c.int {
	time.sleep(time.Millisecond)
	return 0
}
