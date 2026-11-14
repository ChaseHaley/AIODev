package scripting

import "core:c"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"
import "aio:lua"

// The watchdog sleeps on changed while nothing is armed, so an idle state costs no wakeups.
@(private)
Budget :: struct {
	watchdog: ^thread.Thread,
	mutex: sync.Mutex,
	changed: sync.Cond,
	closing: bool,
	// The coroutine of the entry point that is running, or nil between entry points.
	armed: ^lua.State,
	started: time.Tick,
	message: string,
}

@(private, require_results)
budget_start :: proc(s: ^State) -> bool {
	ms := s.config.budget_ms
	if ms <= 0 {return true}
	if ms == f64(i64(ms)) {
		s.budget.message = fmt.aprintf("took longer than %d ms", i64(ms), allocator = s.allocator)
	} else {
		s.budget.message = fmt.aprintf("took longer than %v ms", ms, allocator = s.allocator)
	}
	s.budget.watchdog = thread.create(watchdog_main)
	if s.budget.watchdog == nil {return false}
	s.budget.watchdog.data = s
	thread.start(s.budget.watchdog)
	return true
}

@(private)
budget_stop :: proc(s: ^State) {
	if s.budget.watchdog != nil {
		sync.mutex_lock(&s.budget.mutex)
		s.budget.closing = true
		sync.cond_signal(&s.budget.changed)
		sync.mutex_unlock(&s.budget.mutex)
		thread.join(s.budget.watchdog)
		thread.destroy(s.budget.watchdog)
		s.budget.watchdog = nil
	}
	delete(s.budget.message, s.allocator)
	s.budget.message = ""
}

@(private)
watchdog_main :: proc(t: ^thread.Thread) {
	s := cast(^State)t.data
	b := &s.budget
	limit := time.Duration(s.config.budget_ms * f64(time.Millisecond))
	sync.mutex_lock(&b.mutex)
	defer sync.mutex_unlock(&b.mutex)
	for !b.closing {
		if b.armed == nil {
			sync.cond_wait(&b.changed, &b.mutex)
			continue
		}
		remaining := limit - time.tick_since(b.started)
		if remaining > 0 {
			_ = sync.cond_wait_with_timeout(&b.changed, &b.mutex, remaining)
			continue
		}
		// Setting the hook again every millisecond catches code that swallows the interrupt with
		// pcall and keeps looping. The mutex keeps this from racing native_disarm's clear.
		_ = lua.sethook(b.armed, budget_hook, lua.MASKCOUNT, 1)
		_ = sync.cond_wait_with_timeout(&b.changed, &b.mutex, time.Millisecond)
	}
}

// The only place that interrupts Lua. LuaJIT built with CHECKHOOK makes compiled traces notice
// the count hook the watchdog set asynchronously; the hook then runs on the Lua thread, where
// raising is allowed.
@(private)
budget_hook :: proc "c" (L: ^lua.State, _: ^lua.Debug) {
	s := state_at(L)
	_ = lua.sethook(L, nil, {}, 0)
	// Hooks are global to a LuaJIT state. The main thread only runs scheduler bookkeeping between
	// resumes, which must not be cut short; the watchdog's next pass catches the script again.
	if L == s.L {return}
	lua.L_where(L, 0)
	push_text(L, s.budget.message)
	lua.concat(L, 2)
	_ = lua.error(L)
}

// arm(co) starts the budget for the entry point about to resume.
@(private)
native_arm :: proc "c" (L: ^lua.State) -> c.int {
	s := state_at(L)
	if s.budget.watchdog == nil {return 0}
	sync.mutex_lock(&s.budget.mutex)
	s.budget.armed, s.budget.started = lua.tothread(L, 1), time.tick_now()
	sync.cond_signal(&s.budget.changed)
	sync.mutex_unlock(&s.budget.mutex)
	return 0
}

@(private)
native_disarm :: proc "c" (L: ^lua.State) -> c.int {
	s := state_at(L)
	if s.budget.watchdog == nil {return 0}
	sync.mutex_lock(&s.budget.mutex)
	if s.budget.armed != nil {_ = lua.sethook(s.budget.armed, nil, {}, 0)}
	s.budget.armed = nil
	sync.mutex_unlock(&s.budget.mutex)
	return 0
}

// Time spent inside the host's command handling is not the script's, so the budget restarts.
@(private)
budget_restart :: proc "contextless" (s: ^State) {
	if s.budget.watchdog == nil {return}
	sync.mutex_lock(&s.budget.mutex)
	if s.budget.armed != nil {
		_ = lua.sethook(s.budget.armed, nil, {}, 0)
		s.budget.started = time.tick_now()
	}
	sync.mutex_unlock(&s.budget.mutex)
}
