package links_test

import "aio:links"
import "core:os"
import "core:strings"
import "core:testing"

// Each test sets its own variable names, so parallel tests never see each other's values.

@(test)
shorthand_targets_resolve_like_the_paths_they_name :: proc(t: ^testing.T) {
	testing.expect_value(t, os.set_env("AIODEV_LINK_DIR", `C:\Link Dir`), nil)
	defer os.unset_env("AIODEV_LINK_DIR")
	home := os.get_env("USERPROFILE", context.temp_allocator)
	cases := [?]struct {target, cwd, path: string} {
		{`%AIODEV_LINK_DIR%\a.txt:12`, "", `C:\Link Dir\a.txt`},
		{`%aiodev_link_dir%\a.txt`, "", `C:\Link Dir\a.txt`},
		{`$env:AIODEV_LINK_DIR\a.txt`, "", `C:\Link Dir\a.txt`},
		{`${env:AIODEV_LINK_DIR}/a.txt`, "", `C:\Link Dir/a.txt`},
		{`$AIODEV_LINK_DIR/a.txt`, "", `C:\Link Dir/a.txt`},
		{`${AIODEV_LINK_DIR}/a.txt`, "", `C:\Link Dir/a.txt`},
		{`src/$AIODEV_LINK_UNSET.txt`, `C:\repo`, `C:\repo\src/$AIODEV_LINK_UNSET.txt`},
		{`%AIODEV_LINK_UNSET%\a.txt`, "", ""},
		{`C:\$Recycle.Bin\a.txt`, "", `C:\$Recycle.Bin\a.txt`},
		{`C:\100%\a%b.txt`, "", `C:\100%\a%b.txt`},
	}
	for c in cases {
		buffer: [links.TARGET_BYTES]u8
		path, ok := links.resolve_file(c.target, c.cwd, nil, buffer[:])
		testing.expectf(t, ok == (c.path != ""), "%s resolved %v", c.target, ok)
		testing.expect_value(t, path, c.path)
	}
	if home == "" {return}
	for target in ([?]string{`~\notes.md`, `~/notes.md`, `%USERPROFILE%\notes.md`}) {
		buffer: [links.TARGET_BYTES]u8
		path, ok := links.resolve_file(target, "", nil, buffer[:])
		testing.expectf(t, ok, "%s resolved", target)
		testing.expect_value(t, path, strings.concatenate({home, target[len(target) - 9:]}, context.temp_allocator) or_else "")
	}
	buffer: [links.TARGET_BYTES]u8
	if _, set := os.lookup_env("HOME", context.temp_allocator); !set {
		path, ok := links.resolve_file(`$HOME\notes.md`, "", nil, buffer[:])
		testing.expect(t, ok)
		testing.expect_value(t, path, strings.concatenate({home, `\notes.md`}, context.temp_allocator) or_else "")
	}
	_, tilde_user := links.resolve_file(`~other\notes.md`, "", nil, buffer[:])
	testing.expect(t, !tilde_user)
}

@(test)
shorthand_paths_are_detected_in_output_and_selections :: proc(t: ^testing.T) {
	testing.expect_value(t, os.set_env("AIODEV_LINK_FIND", `C:\Find Here`), nil)
	defer os.unset_env("AIODEV_LINK_FIND")
	text := `saved %AIODEV_LINK_FIND%\My Notes\a.md and $env:AIODEV_LINK_FIND\b.txt:3 not %AIODEV_LINK_NOPE%\c.txt`
	ranges: [dynamic]links.Range
	defer delete(ranges)
	testing.expect(t, links.find_files(text, false, &ranges))
	testing.expect_value(t, len(ranges), 2)
	if len(ranges) == 2 {
		testing.expect_value(t, text[ranges[0].start:ranges[0].end], `%AIODEV_LINK_FIND%\My Notes\a.md`)
		testing.expect_value(t, text[ranges[1].start:ranges[1].end], `$env:AIODEV_LINK_FIND\b.txt:3`)
	}
	if os.get_env("USERPROFILE", context.temp_allocator) != "" {
		line := `~\Downloads\report.pdf`
		r, ok := links.selection_target(line, false)
		testing.expect(t, ok)
		testing.expect_value(t, line[r.start:r.end], line)
	}
}

@(test)
markdown_hrefs_keep_set_variables_while_decoding_escapes :: proc(t: ^testing.T) {
	testing.expect_value(t, os.set_env("AIODEV_LINK_HREF", `C:\Href`), nil)
	defer os.unset_env("AIODEV_LINK_HREF")
	cases := [?]struct {href, path: string} {
		{`%AIODEV_LINK_HREF%/My%20Notes.md`, `C:\Href/My Notes.md`},
		{`$HOME_NOT_SET_AIODEV/a%20b.md`, `C:\vault\$HOME_NOT_SET_AIODEV/a b.md`},
	}
	for c in cases {
		buffer: [links.TARGET_BYTES]u8
		path, ok := links.resolve_href(c.href, `C:\vault`, nil, buffer[:])
		testing.expectf(t, ok == (c.path != ""), "%s resolved %v", c.href, ok)
		testing.expect_value(t, path, c.path)
	}
}

@(test)
web_input_accepts_shorthand_for_local_pages :: proc(t: ^testing.T) {
	testing.expect_value(t, os.set_env("AIODEV_LINK_WEB", `C:\Pages`), nil)
	defer os.unset_env("AIODEV_LINK_WEB")
	for raw in ([?]string{`%AIODEV_LINK_WEB%\index.html`, `"$env:AIODEV_LINK_WEB/index.html"`}) {
		url, ok := links.normalize_web_input(raw)
		testing.expectf(t, ok, "%s accepted", raw)
		testing.expect_value(t, url, "file:///C:/Pages/index.html")
	}
	url, ok := links.normalize_web_input("example.com/$AIODEV_LINK_WEB")
	testing.expect(t, ok)
	testing.expect_value(t, url, "https://example.com/$AIODEV_LINK_WEB")
}
