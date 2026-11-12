package term_test

import "base:runtime"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:time"
import "aio:term"

Failing_Allocator :: struct {
	backing: mem.Allocator,
	remaining: int,
}

fail_allocation :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]u8, mem.Allocator_Error) {
	a := (^Failing_Allocator)(data)
	if (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) &&
		size > 0 {
		if a.remaining == 0 {
			return nil, .Out_Of_Memory
		}
		a.remaining -= 1
	}
	return a.backing.procedure(a.backing.data, mode, size, alignment, old_memory, old_size, location)
}

check_snapshot_failures :: proc(t: ^testing.T, s: ^term.Session) {
	context.logger = {}
	for allowed in 0 ..< 20 {
		a := Failing_Allocator{context.allocator, allowed}
		allocator := mem.Allocator{fail_allocation, &a}
		snapshot, err := term.program_status(s, allocator)
		if err == nil {
			testing.expect(t, len(snapshot) > 0)
			term.destroy_program_status(snapshot, allocator)
			return
		}
		testing.expect_value(t, err, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect(t, snapshot == nil)
	}
	testing.fail(t)
}

find_status :: proc(records: []term.Program_Status, id: string) -> ^term.Program_Status {
	for &record in records {
		if record.id == id {
			return &record
		}
	}
	return nil
}

status_step :: proc(t: ^testing.T, s: ^term.Session, marker: string) -> []term.Program_Status {
	testing.expect(t, term.send_text(s, "\r"))
	if !await(t, s, shows, marker) {
		return nil
	}
	result, err := term.program_status(s)
	testing.expect(t, err == nil)
	return result
}

@(test)
program_status_hierarchy_lifecycle_and_bound :: proc(t: ^testing.T) {
	wakes: Wakes
	script :: "\"$e = [char]27; function Report($v) { [Console]::Write($e + ']7501;' + $v + [char]7) }; " +
		"Report 'state=working:app=deploy'; Report 'state=working:id=build:app=compiler'; " +
		"Report 'state=done:id=build/test:title=VGVzdOKBpuKAiw==:msg=aMOp4oCuIQ=='; " +
		"Report 'state=nonsense:id=invalid'; " +
		"Report 'state=error:id=build2:title=8J+RqeKAjfCfkrs=:msg=YmVmb3Jl'; " +
		"Report 'state=error:id=build2:title=8J+RqeKAjfCfkrs=:msg=aGn/'; " +
		"[Console]::WriteLine('STATUS_ONE'); " +
		"$null = [Console]::ReadLine(); Report 'state=done:id=build'; " +
		"Report 'state=working:app=updated'; [Console]::WriteLine('STATUS_TWO'); " +
		"$null = [Console]::ReadLine(); Report 'state=clear:id=build'; " +
		"[Console]::WriteLine('STATUS_THREE'); $null = [Console]::ReadLine(); Report 'state=clear'; " +
		"for ($i = 0; $i -lt 256; $i++) { Report ('state=done:id=n' + $i) }; " +
		"Report 'state=error:id=n0'; Report 'state=done:id=n256'; [Console]::WriteLine('STATUS_FOUR'); " +
		"$null = [Console]::ReadLine(); Report 'state=clear'; Report 'state=idle:id=idle'; " +
		"Report 'state=working:id=working'; Report 'state=blocked:id=blocked:kind=question'; " +
		"Report 'state=done:id=done'; Report 'state=error:id=error'; " +
		"[Console]::Write($e + ']133;A' + [char]7); [Console]::WriteLine('STATUS_FIVE'); " +
		"$null = [Console]::ReadLine(); [Console]::Write($e + 'c'); [Console]::WriteLine('STATUS_SIX'); " +
		"$null = [Console]::ReadLine(); Report 'state=working:id=exit-working'; " +
		"Report 'state=done:id=exit-done'; [Console]::WriteLine('STATUS_SEVEN')\""
	s := start(t, POWERSHELL + script, &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, shows, "STATUS_ONE") {
		return
	}
	one := term.program_status(s)
	defer term.destroy_program_status(one)
	testing.expect_value(t, len(one), 4)
	check_snapshot_failures(t, s)
	child := find_status(one, "build/test")
	if testing.expect(t, child != nil) {
		testing.expect_value(t, child.app, "compiler")
		testing.expect_value(t, child.title, "Test")
		testing.expect_value(t, child.message, "h\u00e9!")
	}
	invalid := find_status(one, "build2")
	if testing.expect(t, invalid != nil) {
		testing.expect_value(t, invalid.message, "before")
		testing.expect_value(t, invalid.title, "\U0001f469\u200d\U0001f4bb")
	}
	testing.expect(t, term.take_program_status_change(s))
	testing.expect(t, !term.take_program_status_change(s))
	two := status_step(t, s, "STATUS_TWO")
	defer term.destroy_program_status(two)
	if testing.expect_value(t, len(two), 4) {
		testing.expect_value(t, two[0].id, "")
		testing.expect_value(t, two[1].id, "build")
		testing.expect_value(t, two[1].app, "updated")
		testing.expect_value(t, two[1].state, term.Program_Status_State.Done)
		testing.expect_value(t, two[1].title, "")
		testing.expect_value(t, two[1].message, "")
	}
	child = find_status(two, "build/test")
	if testing.expect(t, child != nil) {
		testing.expect_value(t, child.app, "updated")
	}
	three := status_step(t, s, "STATUS_THREE")
	defer term.destroy_program_status(three)
	testing.expect_value(t, len(three), 2)
	testing.expect(t, find_status(three, "build") == nil && find_status(three, "build/test") == nil)
	testing.expect(t, find_status(three, "build2") != nil)
	four := status_step(t, s, "STATUS_FOUR")
	defer term.destroy_program_status(four)
	if testing.expect_value(t, len(four), 256) {
		testing.expect_value(t, four[0].id, "n256")
		testing.expect_value(t, four[1].id, "n0")
		testing.expect_value(t, four[255].id, "n2")
	}
	testing.expect(t, find_status(four, "n1") == nil)
	five := status_step(t, s, "STATUS_FIVE")
	defer term.destroy_program_status(five)
	testing.expect_value(t, len(five), 2)
	testing.expect(t, find_status(five, "done") != nil && find_status(five, "error") != nil)
	for record in five {testing.expect(t, record.ended)}
	six := status_step(t, s, "STATUS_SIX")
	defer term.destroy_program_status(six)
	testing.expect_value(t, len(six), 0)
	testing.expect(t, term.take_program_status_change(s))
	testing.expect(t, term.send_text(s, "\r"))
	if !await(t, s, exited, "exit") || !await(t, s, shows, "STATUS_SEVEN") {
		return
	}
	start := time.tick_now()
	for {
		seven := term.program_status(s)
		finished := len(seven) == 1 && seven[0].id == "exit-done"
		term.destroy_program_status(seven)
		if finished {
			break
		}
		if time.tick_since(start) > 5 * time.Second {
			testing.fail(t)
			break
		}
		time.sleep(time.Millisecond)
	}
	if child = find_status(one, "build/test"); child != nil {
		testing.expect_value(t, child.message, "h\u00e9!")
	}
	term.restart(s, config("cmd.exe /d /c \"echo STATUS_RESTARTED&ping -n 30 127.0.0.1 > nul\""))
	if await(t, s, shows, "STATUS_RESTARTED") {
		restarted := term.program_status(s)
		defer term.destroy_program_status(restarted)
		testing.expect_value(t, len(restarted), 0)
	}
}

@(test)
program_status_kind_progress_read_and_switch :: proc(t: ^testing.T) {
	wakes: Wakes
	script :: "\"$e = [char]27; function Report($v) { [Console]::Write($e + ']7501;' + $v + [char]7) }; " +
		"Report 'state=blocked:kind=auth:progress=40:app=deploy'; Report 'state=working:id=w:progress=101'; " +
		"Report 'state=done:id=d'; Report 'state=error:id=x'; [Console]::WriteLine('SWITCH_ONE'); " +
		"$null = [Console]::ReadLine(); Report 'state=done:id=dropped'; [Console]::WriteLine('SWITCH_TWO'); " +
		"$null = [Console]::ReadLine(); Report 'state=done:id=back'; [Console]::WriteLine('SWITCH_THREE'); " +
		"$null = [Console]::ReadLine()\""
	s := start(t, POWERSHELL + script, &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, shows, "SWITCH_ONE") {
		return
	}
	one := term.program_status(s)
	defer term.destroy_program_status(one)
	testing.expect_value(t, len(one), 4)
	if root := find_status(one, ""); testing.expect(t, root != nil) {
		testing.expect_value(t, root.kind, term.Program_Status_Kind.Auth)
		testing.expect_value(t, root.progress, i8(40))
	}
	if working := find_status(one, "w"); testing.expect(t, working != nil) {
		testing.expect_value(t, working.progress, i8(-1))
		testing.expect_value(t, working.kind, term.Program_Status_Kind.None)
	}
	testing.expect_value(t, find_status(one, "d").state, term.Program_Status_State.Done)
	_ = term.take_program_status_change(s)
	testing.expect(t, !find_status(one, "d").read)
	term.program_status_read(s, time.now())
	testing.expect(t, term.take_program_status_change(s))
	term.program_status_read(s, time.now())
	testing.expect(t, !term.take_program_status_change(s))
	read := term.program_status(s)
	defer term.destroy_program_status(read)
	testing.expect(t, find_status(read, "d").read && find_status(read, "x").read && find_status(read, "").read)
	testing.expect_value(t, find_status(read, "d").state, term.Program_Status_State.Done)
	term.program_status_mark_unread(s)
	testing.expect(t, term.take_program_status_change(s))
	term.program_status_read(s, time.now())
	held := term.program_status(s)
	defer term.destroy_program_status(held)
	testing.expect(t, !find_status(held, "d").read)
	term.program_status_read(s, time.now(), mark = true)
	term.program_status_dismiss(s, "w")
	term.program_status_dismiss(s, "x")
	term.program_status_dismiss_read(s, ended_only = true)
	kept := term.program_status(s)
	defer term.destroy_program_status(kept)
	testing.expect(t, find_status(kept, "d") != nil)
	term.program_status_dismiss_read(s, ended_only = false)
	remaining := term.program_status(s)
	defer term.destroy_program_status(remaining)
	testing.expect_value(t, len(remaining), 2)
	testing.expect(t, find_status(remaining, "w") != nil && find_status(remaining, "d") == nil)
	term.configure(s, {scrollback_lines = 1000})
	cleared := term.program_status(s)
	defer term.destroy_program_status(cleared)
	testing.expect_value(t, len(cleared), 0)
	two := status_step(t, s, "SWITCH_TWO")
	defer term.destroy_program_status(two)
	testing.expect_value(t, len(two), 0)
	term.configure(s, {scrollback_lines = 1000, program_status_enabled = true})
	three := status_step(t, s, "SWITCH_THREE")
	defer term.destroy_program_status(three)
	if testing.expect_value(t, len(three), 1) {
		testing.expect_value(t, three[0].id, "back")
	}
}

Fake_Wall :: struct {
	nanoseconds: i64,
}

fake_wall_now :: proc(user: rawptr) -> time.Time {
	return {_nsec = sync.atomic_load(&(^Fake_Wall)(user).nanoseconds)}
}

fake_wall_set :: proc(wall: ^Fake_Wall, seconds: i64) {
	sync.atomic_store(&wall.nanoseconds, seconds * i64(time.Second))
}

// A record keeps the time it entered its state through reports that repeat it, until its program
// ends; work reported after that is new, and unread.
@(test)
program_status_since_ended_and_read :: proc(t: ^testing.T) {
	wakes: Wakes
	wall: Fake_Wall
	fake_wall_set(&wall, 100)
	script :: "\"$e = [char]27; function Report($v) { [Console]::Write($e + ']7501;' + $v + [char]7) }; " +
		"Report 'state=working:id=a'; [Console]::WriteLine('SINCE_ONE'); $null = [Console]::ReadLine(); " +
		"Report 'state=working:id=a:msg=c3RpbGw='; Report 'state=done:id=d'; " +
		"[Console]::WriteLine('SINCE_TWO'); $null = [Console]::ReadLine(); " +
		"[Console]::Write($e + ']133;A' + [char]7); [Console]::WriteLine('SINCE_THREE'); " +
		"$null = [Console]::ReadLine(); Report 'state=done:id=d'; [Console]::WriteLine('SINCE_FOUR'); " +
		"$null = [Console]::ReadLine()\""
	cfg := config(POWERSHELL + script)
	cfg.wall_clock = {fake_wall_now, &wall}
	testing.set_fail_timeout(t, 60 * time.Second)
	s, err := term.create(cfg, {on_wake, &wakes})
	if !testing.expect_value(t, err, term.Error.None) {return}
	defer term.destroy(s)
	if !await(t, s, shows, "SINCE_ONE") {return}
	fake_wall_set(&wall, 200)
	two := status_step(t, s, "SINCE_TWO")
	defer term.destroy_program_status(two)
	if a := find_status(two, "a"); testing.expect(t, a != nil) {
		testing.expect_value(t, time.to_unix_seconds(a.since), 100)
		testing.expect_value(t, time.to_unix_seconds(a.updated_at), 200)
		testing.expect_value(t, a.message, "still")
	}
	if d := find_status(two, "d"); testing.expect(t, d != nil) {
		testing.expect(t, !d.ended && !d.read)
		testing.expect_value(t, time.to_unix_seconds(d.since), 200)
	}
	three := status_step(t, s, "SINCE_THREE")
	defer term.destroy_program_status(three)
	if testing.expect_value(t, len(three), 1) {testing.expect(t, three[0].id == "d" && three[0].ended)}
	term.program_status_dismiss_read(s, ended_only = true)
	unread := term.program_status(s)
	defer term.destroy_program_status(unread)
	testing.expect_value(t, len(unread), 1)
	term.program_status_read(s, {_nsec = 250 * i64(time.Second)})
	fake_wall_set(&wall, 300)
	four := status_step(t, s, "SINCE_FOUR")
	defer term.destroy_program_status(four)
	if d := find_status(four, "d"); testing.expect(t, d != nil) {
		testing.expect(t, !d.ended && !d.read)
		testing.expect_value(t, time.to_unix_seconds(d.since), 300)
	}
	term.program_status_read(s, {_nsec = 350 * i64(time.Second)})
	term.program_status_dismiss_read(s, ended_only = true)
	running := term.program_status(s)
	defer term.destroy_program_status(running)
	testing.expect_value(t, len(running), 1)
}
