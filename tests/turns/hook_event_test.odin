package turns_test

import "aio:turns"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

KEY :: "0123456789abcdef0123456789abcdef"

@(private)
SAMPLE_PATHS := [2]string{"C:/work/a.odin", "C:/work/b c.odin"}

@(private)
sample :: proc(kind: turns.Hook_Kind) -> turns.Hook_Event {
	return {
		pane_key = KEY,
		harness = "claude",
		session = "abc-1",
		cwd = `C:\work`,
		prompt = "fix the \"bug\"\nnow",
		kind = kind,
		paths = SAMPLE_PATHS[:],
		written = 1_700_000_000_123,
	}
}

@(test)
hook_event_round_trips :: proc(t: ^testing.T) {
	for kind in turns.Hook_Kind {
		want := sample(kind)
		text, encoded := turns.hook_event_encode(want)
		testing.expect(t, encoded)
		got, decoded := turns.hook_event_decode(transmute([]u8)text)
		testing.expect(t, decoded)
		testing.expect_value(t, got.pane_key, want.pane_key)
		testing.expect_value(t, got.harness, want.harness)
		testing.expect_value(t, got.session, want.session)
		testing.expect_value(t, got.cwd, want.cwd)
		testing.expect_value(t, got.prompt, want.prompt)
		testing.expect_value(t, got.kind, want.kind)
		testing.expect_value(t, got.written, want.written)
		testing.expect(t, slice.equal(got.paths, want.paths))
		turns.hook_event_destroy(&got)
		testing.expect(t, got.pane_key == "" && got.paths == nil)
		delete(text)
	}
}

@(test)
hook_event_without_paths_round_trips :: proc(t: ^testing.T) {
	want := sample(.Stop)
	want.paths = nil
	text, encoded := turns.hook_event_encode(want)
	testing.expect(t, encoded)
	got, decoded := turns.hook_event_decode(transmute([]u8)text)
	testing.expect(t, decoded)
	testing.expect_value(t, len(got.paths), 0)
	turns.hook_event_destroy(&got)
	delete(text)
	// Codex is the other harness.
	want.harness = "codex"
	text, encoded = turns.hook_event_encode(want)
	testing.expect(t, encoded)
	delete(text)
}

@(test)
hook_event_encode_rejects_bad_fields :: proc(t: ^testing.T) {
	for key in ([]string {
			"",
			"0123456789abcdef0123456789abcde",
			"0123456789abcdef0123456789abcdef0",
			"0123456789ABCDEF0123456789abcdef",
			"0123456789abcdeg0123456789abcdef",
		}) {
		e := sample(.Prompt)
		e.pane_key = key
		_, encoded := turns.hook_event_encode(e, context.temp_allocator)
		testing.expectf(t, !encoded, "pane key %q should be rejected", key)
	}
	for harness in ([]string{"", "omp", "Claude", "claude "}) {
		e := sample(.Prompt)
		e.harness = harness
		_, encoded := turns.hook_event_encode(e, context.temp_allocator)
		testing.expectf(t, !encoded, "harness %q should be rejected", harness)
	}
	big := make([]string, 100, context.temp_allocator)
	long := strings.repeat("x", 1000, context.temp_allocator)
	for &path in big {path = long}
	e := sample(.Edit)
	e.paths = big
	_, encoded := turns.hook_event_encode(e, context.temp_allocator)
	testing.expect(t, !encoded)
}

@(test)
hook_event_decode_rejects_bad_files :: proc(t: ^testing.T) {
	good :: `{"pane_key":"0123456789abcdef0123456789abcdef","harness":"claude","session":"s","cwd":"C:/w",` +
		`"prompt":"p","kind":"prompt","paths":[],"written":5}`
	got, decoded := turns.hook_event_decode(transmute([]u8)string(good))
	testing.expect(t, decoded)
	testing.expect_value(t, got.written, 5)
	turns.hook_event_destroy(&got)

	for text in ([]string {
			"",
			"{",
			"[]",
			"null",
			`{}`,
			// pane key
			`{"pane_key":"short","harness":"claude","kind":"stop"}`,
			`{"pane_key":"0123456789ABCDEF0123456789abcdef","harness":"claude","kind":"stop"}`,
			`{"pane_key":7,"harness":"claude","kind":"stop"}`,
			// harness
			`{"pane_key":"0123456789abcdef0123456789abcdef","harness":"omp","kind":"stop"}`,
			`{"pane_key":"0123456789abcdef0123456789abcdef","kind":"stop"}`,
			// kind
			`{"pane_key":"0123456789abcdef0123456789abcdef","harness":"claude","kind":"start"}`,
			`{"pane_key":"0123456789abcdef0123456789abcdef","harness":"claude"}`,
			// wrong types
			`{"pane_key":"0123456789abcdef0123456789abcdef","harness":"claude","kind":"edit","paths":"a"}`,
			`{"pane_key":"0123456789abcdef0123456789abcdef","harness":"claude","kind":"edit","paths":[1]}`,
			`{"pane_key":"0123456789abcdef0123456789abcdef","harness":"claude","kind":"stop","written":"1"}`,
			`{"pane_key":"0123456789abcdef0123456789abcdef","harness":"claude","kind":"stop","cwd":3}`,
		}) {
		_, ok := turns.hook_event_decode(transmute([]u8)text, context.temp_allocator)
		testing.expectf(t, !ok, "%q should be rejected", text)
	}

	oversize := make([]u8, turns.HOOK_EVENT_LIMIT + 1, context.temp_allocator)
	slice.fill(oversize, ' ')
	copy(oversize, good)
	_, ok := turns.hook_event_decode(oversize, context.temp_allocator)
	testing.expect(t, !ok)
	// A field over its own limit is rejected even inside the file's limit.
	long := strings.repeat("x", 5000, context.temp_allocator)
	text := strings.concatenate(
		{`{"pane_key":"0123456789abcdef0123456789abcdef","harness":"claude","kind":"stop","session":"`, long, `"}`},
		context.temp_allocator,
	)
	_, long_ok := turns.hook_event_decode(transmute([]u8)text, context.temp_allocator)
	testing.expect(t, !long_ok)
}

@(test)
hook_event_decode_rejects_a_non_string_path :: proc(t: ^testing.T) {
	// Nothing is left allocated; the leak tracker flags what is.
	text :: `{"pane_key":"0123456789abcdef0123456789abcdef","harness":"codex","kind":"edit","session":"s",` +
		`"cwd":"C:/w","prompt":"p","paths":["a",3]}`
	_, ok := turns.hook_event_decode(transmute([]u8)string(text))
	testing.expect(t, !ok)
}

@(test)
hook_event_prompt_is_cut_on_a_rune_boundary :: proc(t: ^testing.T) {
	// Each euro sign is three bytes, so byte 200 falls inside one.
	e := sample(.Prompt)
	e.prompt = strings.repeat("€", 100, context.temp_allocator)
	text, encoded := turns.hook_event_encode(e)
	defer delete(text)
	testing.expect(t, encoded)
	got, decoded := turns.hook_event_decode(transmute([]u8)text)
	defer turns.hook_event_destroy(&got)
	testing.expect(t, decoded)
	testing.expect_value(t, len(got.prompt), 198)
	testing.expect(t, utf8.valid_string(got.prompt))
	testing.expect(t, strings.has_prefix(e.prompt, got.prompt))

	// A file written by something else is cut the same way.
	long := strings.repeat("é", 300, context.temp_allocator)
	raw := strings.concatenate(
		{`{"pane_key":"0123456789abcdef0123456789abcdef","harness":"codex","kind":"prompt","prompt":"`, long, `"}`},
		context.temp_allocator,
	)
	cut, cut_ok := turns.hook_event_decode(transmute([]u8)raw)
	defer turns.hook_event_destroy(&cut)
	testing.expect(t, cut_ok)
	testing.expect_value(t, len(cut.prompt), 200)
	testing.expect(t, utf8.valid_string(cut.prompt))

	short := sample(.Prompt)
	short.prompt = "short"
	short_text, short_encoded := turns.hook_event_encode(short, context.temp_allocator)
	testing.expect(t, short_encoded)
	kept, kept_ok := turns.hook_event_decode(transmute([]u8)short_text, context.temp_allocator)
	testing.expect(t, kept_ok)
	testing.expect_value(t, kept.prompt, "short")
}

@(test)
marker_round_trips :: proc(t: ^testing.T) {
	for pid in ([]u32{1, 4242, max(u32)}) {
		text := turns.marker_encode(pid)
		defer delete(text)
		got, ok := turns.marker_decode(transmute([]u8)text)
		testing.expect(t, ok)
		testing.expect_value(t, got, pid)
	}
	pid, ok := turns.marker_decode(transmute([]u8)string(`{ "pid": 77 }`))
	testing.expect(t, ok)
	testing.expect_value(t, pid, 77)
}

@(test)
marker_rejects_anything_else :: proc(t: ^testing.T) {
	for text in ([]string {
			"",
			"{",
			"[]",
			"7",
			`{}`,
			`{"pid":0}`,
			`{"pid":-1}`,
			`{"pid":"7"}`,
			`{"pid":4294967296}`,
			`{"pid":1.5}`,
		}) {
		_, ok := turns.marker_decode(transmute([]u8)text)
		testing.expectf(t, !ok, "%q should be rejected", text)
	}
}
