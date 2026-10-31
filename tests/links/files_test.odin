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
active_file_types_need_confirmation_even_without_pathext :: proc(t: ^testing.T) {
	for path in ([?]string{`C:\a.EXE`, `C:\a.ps1`, `C:\a.lnk`, `C:\a.url`, `C:\a.msi`,
		`C:\a.hta`, `C:\a.scf`, `C:\a.library-ms`, `C:\a.settingcontent-ms`, `C:\a.appref-ms`,
		`C:\a.msu`, `C:\a.search-ms`, `C:\a.iqy`, `C:\a.xll`, `C:\a.iso`, `C:\a.vhdx`}) {
		testing.expectf(t, links.file_needs_confirmation(path, ""), "%s must be confirmed", path)
	}
	testing.expect(t, links.file_needs_confirmation(`C:\a.custom`, ".EXE;;.CUSTOM;"))
	testing.expect(t, !links.file_needs_confirmation(`C:\a.txt`, ".EXE;;"))
}
