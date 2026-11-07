package links_test

import "core:testing"
import "aio:links"

@(test)
file_targets_resolve_only_against_local_reported_directories :: proc(t: ^testing.T) {
	cases := [?]struct { target, cwd, path: string } {
		{`C:\src\main.odin:42:3`, "", `C:\src\main.odin`},
		{`src/main.odin:42`, `file://localhost/C:/repo`, `C:/repo\src/main.odin`},
		{`readme.md`, `C:\repo`, `C:\repo\readme.md`},
		{`readme.md`, "", ""},
		{`readme.md`, `file://remote/C:/repo`, ""},
		{`file:///C:/My%20Files/a.txt`, "", `C:/My Files/a.txt`},
		{`file://remote/share/a.txt`, "", ""},
		{`\\server\share\a.txt`, "", ""},
		{`C:\a.txt:stream`, "", ""},
		{`file:///C:/a%00.txt`, "", ""},
		{`C:\src\main.odin(42:3)`, "", `C:\src\main.odin`},
		{`C:\src\main.cpp(42,3)`, "", `C:\src\main.cpp`},
		{`C:\src\main.cpp(42)`, "", `C:\src\main.cpp`},
		{`C:\src\notes(draft).txt`, "", `C:\src\notes(draft).txt`},
		{`C:\src\main.odin(42:3:1)`, "", ""},
		{`file://Box/C:/a.txt`, "", `C:/a.txt`},
		{`file://box.lan/C:/a.txt`, "", `C:/a.txt`},
		{`readme.md`, `file://BOX/C:/repo`, `C:/repo\readme.md`},
		{`file://other/C:/a.txt`, "", ""},
		{"C:\\COM\u00b9.txt", "", ""},
		{"C:\\lpt\u00b3\\a.txt", "", ""},
	}
	hosts := [?]string{"box", "box.lan", ""}
	for c in cases {
		buffer: [4096]u8
		path, ok := links.resolve_file(c.target, c.cwd, hosts[:], buffer[:])
		testing.expectf(t, ok == (c.path != ""), "%s resolved %v", c.target, ok)
		testing.expect_value(t, path, c.path)
	}
}

@(test)
file_detection_requires_a_cwd_for_relative_names :: proc(t: ^testing.T) {
	text := `error C:\src\a.odin:12:4 and src/b.odin README.md C:\src\c.odin(7:2) Error:`
	for relative in ([?]bool{false, true}) {
		ranges: [dynamic]links.Range
		defer delete(ranges)
		testing.expect(t, links.find_files(text, relative, &ranges))
		testing.expect_value(t, len(ranges), relative ? 4 : 2)
		if len(ranges) > 0 {
			testing.expect_value(t, text[ranges[0].start:ranges[0].end], `C:\src\a.odin:12:4`)
			last := ranges[len(ranges) - 1]
			testing.expect_value(t, text[last.start:last.end], `C:\src\c.odin(7:2)`)
		}
	}
}

@(test)
quoted_targets_start_after_an_assignment :: proc(t: ^testing.T) {
	text := `path="C:\My Dir\a.txt" and "src/b c.odin"`
	ranges: [dynamic]links.Range
	defer delete(ranges)
	testing.expect(t, links.find_files(text, true, &ranges))
	testing.expect_value(t, len(ranges), 2)
	if len(ranges) == 2 {
		testing.expect_value(t, text[ranges[0].start:ranges[0].end], `C:\My Dir\a.txt`)
		testing.expect_value(t, text[ranges[1].start:ranges[1].end], `src/b c.odin`)
	}
}

@(test)
relative_names_need_evidence_of_a_file :: proc(t: ^testing.T) {
	text := `e.g v1.2 3.14 1/2 node.js notes.txt .gitignore`
	ranges: [dynamic]links.Range
	defer delete(ranges)
	testing.expect(t, links.find_files(text, true, &ranges))
	testing.expect_value(t, len(ranges), 3)
	if len(ranges) == 3 {
		testing.expect_value(t, text[ranges[0].start:ranges[0].end], "node.js")
		testing.expect_value(t, text[ranges[1].start:ranges[1].end], "notes.txt")
		testing.expect_value(t, text[ranges[2].start:ranges[2].end], ".gitignore")
	}
}

@(test)
drive_paths_extend_across_spaces_only_with_evidence :: proc(t: ^testing.T) {
	cases := [?]struct { text, target: string } {
		{`C:\Program Files\App\read me.txt done`, `C:\Program Files\App\read me.txt`},
		{`C:\Users\John Doe\Documents`, `C:\Users\John Doe\Documents`},
		{`C:\My Dir\a.odin:12:4 failed`, `C:\My Dir\a.odin:12:4`},
		{`C:\My Dir\a.odin(7,2) failed`, `C:\My Dir\a.odin(7,2)`},
		{`C:\foo\bar.txt and src\x.odin`, `C:\foo\bar.txt`},
		{`C:\Program Files`, `C:\Program`},
		{`C:\Program, Files\x.txt`, `C:\Program`},
		{`C:\a  b\c.txt`, `C:\a`},
		{`C:\a --flag b\c.txt`, `C:\a`},
		{`C:\a | b\c.txt`, `C:\a`},
	}
	for c in cases {
		ranges: [dynamic]links.Range
		defer delete(ranges)
		testing.expect(t, links.find_files(c.text, false, &ranges))
		testing.expectf(t, len(ranges) > 0, "%s found nothing", c.text)
		if len(ranges) > 0 {
			testing.expect_value(t, c.text[ranges[0].start:ranges[0].end], c.target)
		}
	}
	two := `copy C:\a\b.txt C:\c\d.txt`
	ranges: [dynamic]links.Range
	defer delete(ranges)
	testing.expect(t, links.find_files(two, false, &ranges))
	testing.expect_value(t, len(ranges), 2)
}

@(test)
row_breaks_only_join_words_that_did_not_fit :: proc(t: ^testing.T) {
	edge := proc(tail, head: string, used, indent, columns: int) -> links.Row_Edge {
		return {tail, head, tail, head, len(tail), len(head), used, indent, columns}
	}
	cases := [?]struct {
		edge: links.Row_Edge,
		join: links.Row_Join,
	} {
		{edge(`C:\Users\chal`, `e\AppData\x.txt`, 40, 0, 40), .Word},
		{edge(`C:\Users\My`, `Folder\x.txt`, 39, 2, 40), .Word},
		{edge(`C:\`, `Users\x.txt`, 40, 0, 40), .Direct},
		{edge(`https://a.io/`, `path`, 40, 2, 40), .Direct},
		{edge(`https://a.io/abc`, `def/g`, 40, 2, 40), .Direct},
		{edge(`C:\aaaaaaaaaaaaaaaaaaaaaaaaa`, `bbbbbbbbbbbbbbb`, 39, 2, 40), .Direct},
		{edge(`https://a.io/abc`, `for`, 40, 0, 40), .Word},
		{edge(`C:\Program`, `Files\App\aaaaaaaaaaaaaaaaaaaaaaa.txt`, 20, 2, 40), .Word},
		{edge(`C:\Program`, `Files`, 20, 0, 40), .None},
		{edge(`anything`, ``, 40, 0, 40), .None},
		{edge(``, `word`, 0, 0, 40), .None},
		{edge(`plainword`, `next`, 40, 0, 40), .None},
		{edge(`plainword`, `next.txt`, 40, 0, 40), .Word},
	}
	for c in cases {
		testing.expect_value(t, links.row_join(c.edge), c.join)
	}
}

@(test)
candidates_run_longest_first_and_keep_the_target :: proc(t: ^testing.T) {
	line := "run C:\\My Dir\\a.txt, now"
	start := 4
	end := start + len(`C:\My`)
	ranges: [dynamic]links.Range
	defer delete(ranges)
	testing.expect(t, links.candidates(line, start, end, nil, &ranges))
	got: [dynamic]string
	defer delete(got)
	for r in ranges {append(&got, line[r.start:r.end])}
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, got[0], `C:\My Dir\a.txt, now`)
		testing.expect_value(t, got[1], `C:\My Dir\a.txt`)
		testing.expect_value(t, got[2], `C:\My`)
	}
}

@(test)
candidates_cut_where_a_word_was_broken_and_look_left_for_relative_names :: proc(t: ^testing.T) {
	line := "C:\\a\\b.txtnext"
	cut := [?]int{len(`C:\a\b.txt`)}
	ranges: [dynamic]links.Range
	defer delete(ranges)
	testing.expect(t, links.candidates(line, 0, len(line), cut[:], &ranges))
	testing.expect_value(t, len(ranges), 2)
	if len(ranges) == 2 {
		testing.expect_value(t, line[ranges[1].start:ranges[1].end], `C:\a\b.txt`)
	}

	relative := `in My Folder\a.txt`
	clear(&ranges)
	at := len(`in My `)
	testing.expect(t, links.candidates(relative, at, len(relative), nil, &ranges))
	spellings: [dynamic]string
	defer delete(spellings)
	for r in ranges {append(&spellings, relative[r.start:r.end])}
	testing.expect_value(t, spellings[0], `Folder\a.txt`)
	testing.expect_value(t, spellings[1], `My Folder\a.txt`)
	testing.expect_value(t, spellings[2], `in My Folder\a.txt`)

	clear(&ranges)
	uri := `file:///C:/a.txt more`
	testing.expect(t, links.candidates(uri, 0, len(`file:///C:/a.txt`), nil, &ranges))
	testing.expect_value(t, len(ranges), 0)
}

@(test)
row_breaks_read_as_a_space_or_as_nothing :: proc(t: ^testing.T) {
	text := "C:\\My\nFolder\\ab\ncd.txt"
	testing.expect_value(t, links.break_variants(text), 4)
	buffer: [64]u8
	spaces, ok := links.break_variant(text, 3, buffer[:])
	testing.expect(t, ok)
	testing.expect_value(t, spaces, `C:\My Folder\ab cd.txt`)
	joined, joined_ok := links.break_variant(text, 0, buffer[:])
	testing.expect(t, joined_ok)
	testing.expect_value(t, joined, `C:\MyFolder\abcd.txt`)
	mixed, mixed_ok := links.break_variant(text, 1, buffer[:])
	testing.expect(t, mixed_ok)
	testing.expect_value(t, mixed, `C:\My Folder\abcd.txt`)
}

@(test)
break_readings_descend_masks_and_cap_variable_breaks :: proc(t: ^testing.T) {
	buffer: [32]u8
	readings := links.break_readings("a\nb\nc\nd\ne", buffer[:])
	expected := [?]string{
		"a b c d e",
		"ab c d e",
		"a bc d e",
		"abc d e",
		"a b cd e",
		"ab cd e",
		"a bcd e",
		"abcd e",
	}
	count := 0
	for reading in links.break_readings_next(&readings) {
		if testing.expect(t, count < len(expected)) {
			testing.expect_value(t, reading, expected[count])
		}
		count += 1
	}
	testing.expect_value(t, count, len(expected))
	reading, more := links.break_readings_next(&readings)
	testing.expect(t, !more)
	testing.expect_value(t, reading, "")
}

@(test)
break_readings_skip_oversized_variants_without_losing_shorter_ones :: proc(t: ^testing.T) {
	buffer: [4]u8
	readings := links.break_readings("a\nb\nc", buffer[:])
	expected := [?]string{"ab c", "a bc", "abc"}
	count := 0
	for reading in links.break_readings_next(&readings) {
		if testing.expect(t, count < len(expected)) {
			testing.expect_value(t, reading, expected[count])
		}
		count += 1
	}
	testing.expect_value(t, count, len(expected))

	readings = links.break_readings("a\nbc", buffer[:2])
	for _ in 0 ..< 2 {
		reading, more := links.break_readings_next(&readings)
		testing.expect(t, !more)
		testing.expect_value(t, reading, "")
	}
}

@(test)
break_readings_yield_unbroken_and_empty_text_once :: proc(t: ^testing.T) {
	buffer: [4]u8
	for text in ([?]string{"path", ""}) {
		readings := links.break_readings(text, buffer[:])
		reading, more := links.break_readings_next(&readings)
		testing.expect(t, more)
		testing.expect_value(t, reading, text)
		_, again := links.break_readings_next(&readings)
		testing.expect(t, !again)
	}
}

@(test)
selected_text_is_a_target_when_it_can_name_one :: proc(t: ^testing.T) {
	cases := [?]struct {
		raw:      string,
		relative: bool,
		target:   string,
	} {
		{`C:\Program Files\App`, false, `C:\Program Files\App`},
		{"  C:\\Users\\John Doe\\My Fi\r\n     le.pdf  ", false, "C:\\Users\\John Doe\\My Fi\nle.pdf"},
		{`"C:\My Dir\a.txt"`, false, `C:\My Dir\a.txt`},
		{`C:\My Dir\a.txt.`, false, `C:\My Dir\a.txt`},
		{"https://example.com/a\n  /b", false, "https://example.com/a\n/b"},
		{"ht\ntps://example.com/a", false, "ht\ntps://example.com/a"},
		{`My Folder\a b.txt`, true, `My Folder\a b.txt`},
		{`My Folder\a b.txt`, false, ""},
		{`just some words`, true, ""},
		{`\\server\share\a.txt`, true, ""},
		{``, true, ""},
	}
	for c in cases {
		line: [dynamic]u8
		defer delete(line)
		if !links.selection_line(c.raw, &line) {
			testing.expect_value(t, c.target, "")
			continue
		}
		text := string(line[:])
		r, ok := links.selection_target(text, c.relative)
		testing.expectf(t, ok == (c.target != ""), "%q gave %v", c.raw, ok)
		if ok {testing.expect_value(t, text[r.start:r.end], c.target)}
	}
}
