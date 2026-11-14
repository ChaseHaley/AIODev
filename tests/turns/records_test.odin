package turns_test

import "aio:turns"
import "core:strings"
import "core:testing"

SHA1_A :: "0123456789abcdef0123456789abcdef01234567"
SHA1_B :: "fedcba9876543210fedcba9876543210fedcba98"
SHA256_A :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
SHA1_SHORT :: "0123456789abcdef0123456789abcdef0123456"

@(private)
sample_changes :: proc() -> [3]turns.Change {
	return {
		{"C:/work/repo", "src/main.odin", SHA1_A, SHA1_B, false},
		{"C:/work/repo", "docs/déjà vu \"quoted\" \\ 日本語.md", "", SHA1_A, true},
		{"C:/work/repo/sub", "gone.txt", SHA1_B, "", false},
	}
}

@(private)
sample_segment :: proc(changes: []turns.Change) -> turns.Segment {
	return {
		id = 0xfedc_ba98_7654_3210,
		kind = .Turn,
		session = {pane_key = "0123456789abcdef0123456789abcdef", harness = "claude", session = "s-1"},
		started = 1_760_000_000_123,
		ended = 1_760_000_099_456,
		end_state = .Done,
		title = "Fix the \"parser\"\nthen the tests — é",
		sources = {.Status, .Hooks},
		added = 120,
		removed = 7,
		changes = changes,
	}
}

@(private)
encoded_sample :: proc(t: ^testing.T) -> string {
	changes := sample_changes()
	text, ok := turns.segment_encode(sample_segment(changes[:]), context.temp_allocator)
	testing.expect(t, ok)
	return text
}

@(private)
expect_rejected :: proc(t: ^testing.T, data: string, why: string) {
	s, ok := turns.segment_decode(transmute([]u8)data)
	if ok {turns.segment_destroy(&s)}
	testing.expectf(t, !ok, "%s should be rejected", why)
}

@(test)
segment_round_trips_with_unicode_paths_and_empty_oids :: proc(t: ^testing.T) {
	changes := sample_changes()
	want := sample_segment(changes[:])
	text, ok := turns.segment_encode(want)
	defer delete(text)
	testing.expect(t, ok)
	got, decoded := turns.segment_decode(transmute([]u8)text)
	defer turns.segment_destroy(&got)
	testing.expect(t, decoded)
	testing.expect_value(t, got.id, want.id)
	testing.expect_value(t, got.kind, want.kind)
	testing.expect_value(t, got.session, want.session)
	testing.expect_value(t, got.started, want.started)
	testing.expect_value(t, got.ended, want.ended)
	testing.expect_value(t, got.end_state, want.end_state)
	testing.expect_value(t, got.title, want.title)
	testing.expect_value(t, got.sources, want.sources)
	testing.expect_value(t, got.added, 120)
	testing.expect_value(t, got.removed, 7)
	testing.expect_value(t, len(got.changes), 3)
	for c, i in got.changes {
		testing.expect_value(t, c, changes[i])
	}
}

@(test)
every_kind_end_state_and_source_set_round_trips :: proc(t: ^testing.T) {
	kinds := [?]turns.Segment_Kind{.Turn, .Between}
	end_states := [?]turns.End_State{.Unknown, .Done, .Idle, .Error, .Ended}
	source_sets := [?]bit_set[turns.Signal_Source]{{}, {.Status}, {.Hooks}, {.Status, .Hooks}}
	for kind in kinds {
		for end_state in end_states {
			for sources in source_sets {
				want := turns.Segment {
					id = 1,
					kind = kind,
					end_state = end_state,
					sources = sources,
				}
				text, ok := turns.segment_encode(want)
				testing.expect(t, ok)
				got, decoded := turns.segment_decode(transmute([]u8)text)
				testing.expect(t, decoded)
				testing.expect_value(t, got.kind, kind)
				testing.expect_value(t, got.end_state, end_state)
				testing.expect_value(t, got.sources, sources)
				testing.expect_value(t, len(got.changes), 0)
				turns.segment_destroy(&got)
				delete(text)
			}
		}
	}
}

@(test)
segment_without_changes_or_text_round_trips :: proc(t: ^testing.T) {
	text, ok := turns.segment_encode(turns.Segment{id = max(u64), kind = .Between})
	defer delete(text)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(text, `"id":"ffffffffffffffff"`))
	got, decoded := turns.segment_decode(transmute([]u8)text)
	defer turns.segment_destroy(&got)
	testing.expect(t, decoded)
	testing.expect_value(t, got.id, max(u64))
	testing.expect_value(t, got.kind, turns.Segment_Kind.Between)
}

@(test)
sha256_object_ids_round_trip :: proc(t: ^testing.T) {
	changes := [?]turns.Change{{"/r", "f", SHA256_A, "", false}}
	text, ok := turns.segment_encode(turns.Segment{id = 2, changes = changes[:]})
	defer delete(text)
	testing.expect(t, ok)
	got, decoded := turns.segment_decode(transmute([]u8)text)
	defer turns.segment_destroy(&got)
	testing.expect(t, decoded)
	testing.expect_value(t, got.changes[0].before, SHA256_A)
}

@(test)
segment_file_names_are_sixteen_lowercase_hex_digits :: proc(t: ^testing.T) {
	a := turns.segment_file_name(0xAB)
	defer delete(a)
	b := turns.segment_file_name(max(u64))
	defer delete(b)
	testing.expect_value(t, a, "00000000000000ab.json")
	testing.expect_value(t, b, "ffffffffffffffff.json")
}

@(test)
object_ids_are_empty_or_lowercase_sha1_or_sha256 :: proc(t: ^testing.T) {
	testing.expect(t, turns.oid_valid(""))
	testing.expect(t, turns.oid_valid(SHA1_A))
	testing.expect(t, turns.oid_valid(SHA256_A))
	bad := [?]string {
		"abc",
		SHA1_SHORT,
		strings.concatenate({SHA1_A, "0"}, context.temp_allocator),
		"0123456789ABCDEF0123456789abcdef01234567",
		"g123456789abcdef0123456789abcdef01234567",
		"0123456789abcdef0123456789abcdef0123456 ",
		"../0123456789abcdef0123456789abcdef012345",
	}
	for o in bad {
		testing.expectf(t, !turns.oid_valid(o), "%q is not an object id", o)
	}
	free_all(context.temp_allocator)
}

@(test)
decode_rejects_unknown_values_and_bad_shapes :: proc(t: ^testing.T) {
	valid := encoded_sample(t)
	defer free_all(context.temp_allocator)
	swap :: proc(text, from, to: string) -> string {
		replaced, _ := strings.replace(text, from, to, 1, context.temp_allocator)
		return replaced
	}
	expect_rejected(t, swap(valid, `"kind":"turn"`, `"kind":"bogus"`), "an unknown kind")
	expect_rejected(t, swap(valid, `"end_state":"done"`, `"end_state":"bogus"`), "an unknown end state")
	expect_rejected(t, swap(valid, `"status"`, `"bogus"`), "an unknown source")
	expect_rejected(t, swap(valid, `"version":1`, `"version":2`), "another version")
	expect_rejected(t, swap(valid, `"added":120`, `"added":-1`), "a negative added count")
	expect_rejected(t, swap(valid, `"removed":7`, `"removed":-7`), "a negative removed count")
	expect_rejected(t, swap(valid, `"added":120`, `"added":"120"`), "a text count")
	expect_rejected(t, swap(valid, `"id":"fedcba9876543210"`, `"id":"FEDCBA9876543210"`), "an uppercase id")
	expect_rejected(t, swap(valid, `"id":"fedcba9876543210"`, `"id":"fedcba98765432"`), "a short id")
	expect_rejected(t, swap(valid, `"id":"fedcba9876543210"`, `"id":"fedcba987654321g"`), "a non-hex id")
	expect_rejected(t, swap(valid, `"started":1760000000123`, `"started":1.5`), "a fractional time")
	expect_rejected(t, swap(valid, `"shared":true`, `"shared":"yes"`), "a text flag")
	expect_rejected(t, swap(valid, `"path":"src/main.odin"`, `"path":""`), "an empty path")
	expect_rejected(t, swap(valid, `"title"`, `"name"`), "a missing title")
	expect_rejected(t, swap(valid, `"changes":[`, `"changes":{"x":`), "changes that are not a list")
	expect_rejected(t, "[]", "a list")
	expect_rejected(t, "", "nothing")
	expect_rejected(t, "not json", "text")
	expect_rejected(t, valid[:len(valid) / 2], "a truncated file")
}

@(test)
decode_rejects_invalid_object_ids :: proc(t: ^testing.T) {
	valid := encoded_sample(t)
	defer free_all(context.temp_allocator)
	for bad in ([?]string{"XYZ", SHA1_SHORT, "0123456789ABCDEF0123456789abcdef01234567"}) {
		for key in ([?]string{"before", "after"}) {
			from := strings.concatenate({`"`, key, `":"`, SHA1_A, `"`}, context.temp_allocator)
			to := strings.concatenate({`"`, key, `":"`, bad, `"`}, context.temp_allocator)
			text, _ := strings.replace(valid, from, to, 1, context.temp_allocator)
			testing.expect(t, text != valid)
			expect_rejected(t, text, "an invalid object id")
		}
	}
}

@(test)
decode_rejects_invalid_utf8_and_oversize_and_deep_files :: proc(t: ^testing.T) {
	valid := encoded_sample(t)
	defer free_all(context.temp_allocator)
	broken := transmute([]u8)strings.clone(valid, context.temp_allocator)
	at := strings.index(valid, "parser")
	broken[at] = 0xff
	s, ok := turns.segment_decode(broken)
	if ok {turns.segment_destroy(&s)}
	testing.expect(t, !ok)

	big := make([]u8, turns.SEGMENT_LIMIT + 1, context.temp_allocator)
	for i in 0 ..< len(big) {big[i] = ' '}
	copy(big, valid)
	s, ok = turns.segment_decode(big)
	if ok {turns.segment_destroy(&s)}
	testing.expect(t, !ok)

	// The same bytes at exactly the limit are not refused for their size.
	s, ok = turns.segment_decode(big[:turns.SEGMENT_LIMIT])
	testing.expect(t, ok)
	if ok {turns.segment_destroy(&s)}

	nested := strings.repeat("[", 100000, context.temp_allocator)
	expect_rejected(t, nested, "a deeply nested file")
}

@(test)
decode_rejects_nul_in_text :: proc(t: ^testing.T) {
	valid := encoded_sample(t)
	defer free_all(context.temp_allocator)
	text, _ := strings.replace(valid, `"harness":"claude"`, `"harness":"cl\u0000ude"`, 1, context.temp_allocator)
	expect_rejected(t, text, "NUL in text")
}

@(test)
encode_refuses_what_decode_would_refuse :: proc(t: ^testing.T) {
	good := [?]turns.Change{{"/r", "f", SHA1_A, "", false}}
	cases := [?]turns.Segment {
		{id = 1, added = -1},
		{id = 1, removed = -1},
		{id = 1, title = "bad \xff text"},
		{id = 1, session = {pane_key = "a\x00b"}},
	}
	for c, i in cases {
		text, ok := turns.segment_encode(c)
		testing.expectf(t, !ok, "case %d should not encode", i)
		testing.expect_value(t, text, "")
	}
	bad_changes := [?][1]turns.Change {
		{{"/r", "f", "XYZ", "", false}},
		{{"/r", "f", "", "01234", false}},
		{{"/r", "", "", SHA1_A, false}},
		{{"", "f", "", SHA1_A, false}},
		{{"/r", "\xc3(", "", SHA1_A, false}},
	}
	for &c, i in bad_changes {
		text, ok := turns.segment_encode(turns.Segment{id = 1, changes = c[:]})
		testing.expectf(t, !ok, "change case %d should not encode", i)
		testing.expect_value(t, text, "")
	}
	text, ok := turns.segment_encode(turns.Segment{id = 1, changes = good[:]})
	testing.expect(t, ok)
	delete(text)
}

@(test)
encode_escapes_control_characters_so_the_file_stays_one_valid_document :: proc(t: ^testing.T) {
	want := turns.Segment {
		id = 3,
		title = "tab\there\r\nbell\a",
	}
	text, ok := turns.segment_encode(want)
	defer delete(text)
	testing.expect(t, ok)
	got, decoded := turns.segment_decode(transmute([]u8)text)
	defer turns.segment_destroy(&got)
	testing.expect(t, decoded)
	testing.expect_value(t, got.title, want.title)
}
