package pty_test

import "aio:pty"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import w "core:sys/windows"

@(private="file")
Cancel_Read :: struct {
	p: pty.Pty,
	ready: sync.Sema,
	delay: time.Duration,
	err: pty.Error,
}

@(private="file")
cancel_read_main :: proc(t: ^thread.Thread) {
	r := (^Cancel_Read)(t.data)
	sync.post(&r.ready)
	if r.delay != 0 {time.sleep(r.delay)}
	buffer: [16]u8
	for {
		_, err := pty.read(&r.p, buffer[:])
		if err != .None {r.err = err; return}
	}
}

@(test)
cancel_reads_without_waiting_for_pipe_eof :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)
	delays := [?]time.Duration{0, 25 * time.Millisecond}
	for delay in delays {
		r := Cancel_Read{delay = delay}
		writer: w.HANDLE
		if !testing.expect(t, bool(w.CreatePipe(&r.p.output, &writer, nil, 0))) {return}
		reader: ^thread.Thread
		defer {
			testing.expect(t, bool(w.CloseHandle(writer)))
			if reader != nil {thread.destroy(reader)}
			testing.expect(t, bool(w.CloseHandle(r.p.output)))
		}
		reader = thread.create(cancel_read_main)
		if !testing.expect(t, reader != nil) {return}
		reader.data = &r
		thread.start(reader)
		sync.wait(&r.ready)
		if delay == 0 {time.sleep(5 * time.Millisecond)}
		started := time.tick_now()
		if !testing.expect_value(t, pty.cancel_reads(reader), pty.Error.None) {return}
		thread.join(reader)
		testing.expectf(t, time.tick_since(started) < time.Second, "reader waited for an open writer (delay %v)", delay)
		testing.expect_value(t, r.err, pty.Error.Closed)
		testing.expect_value(t, pty.cancel_reads(reader), pty.Error.None)
		// Cancellation stops this reader without closing or poisoning the underlying pipe.
		byte: u8 = 'x'
		count: u32
		if !testing.expect(t, bool(w.WriteFile(writer, &byte, 1, &count, nil))) {return}
		if !testing.expect_value(t, count, u32(1)) {return}
		buffer: [1]u8
		n, err := pty.read(&r.p, buffer[:])
		testing.expect_value(t, err, pty.Error.None)
		testing.expect_value(t, n, 1)
		testing.expect_value(t, buffer[0], byte)
	}
	testing.expect_value(t, pty.cancel_reads(nil), pty.Error.None)
}
