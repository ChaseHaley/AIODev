package links_test

import "core:strings"
import "core:testing"
import "aio:links"

@(test)
allowed_accepts_only_plain_web_targets :: proc(t: ^testing.T) {
	cases := [?]struct {
		uri, note: string,
		allowed:   bool,
	} {
		{"https://example.com", "https", true},
		{"http://example.com/path?q=1#frag", "http with path and query", true},
		{"HTTPS://EXAMPLE.COM", "case-insensitive scheme", true},
		{"http://127.0.0.1:8080/link", "loopback with port", true},
		{"http://[::1]:8080/", "IPv6 literal", true},
		{"file:///C:/Windows/win.ini", "file scheme", false},
		{"ssh://example.com/repo", "ssh scheme", false},
		{"javascript:alert(1)", "script scheme", false},
		{"data:text/html,hello", "data scheme", false},
		{"mailto:someone@example.com", "mail scheme", false},
		{"ftp://example.com/file", "ftp scheme", false},
		{`\\server\share\file`, "UNC path", false},
		{"//example.com/path", "protocol-relative path", false},
		{`http://\\server\share`, "backslash authority", false},
		{"http://C:/Windows", "drive-letter authority", false},
		{"http://example.com:80", "port", true},
		{"http://example.com:", "empty port", false},
		{"http://", "empty authority", false},
		{"http:///path", "path without authority", false},
		{"http://.example.com", "leading dot", false},
		{"http://user@example.com", "credentials", false},
		{"http://exa mple.com", "space", false},
		{"http://example.com/\x00", "NUL", false},
		{"http://example.com/\t", "tab", false},
		{"http://example.com/\u0085", "C1 control", false},
		{"http://example.com/\u2028", "line separator", false},
		{"http://example.com/\u00a0", "non-breaking space", false},
		{"https://example.com/a\\b", "backslash in path", false},
		{"", "empty", false},
		{"C:\\Users\\file.txt", "plain path", false},
	}
	for c in cases {
		testing.expectf(
			t,
			links.allowed(c.uri) == c.allowed,
			"%s (%q): expected allowed=%t",
			c.note,
			c.uri,
			c.allowed,
		)
	}
}

Find_Case :: struct {
	text:    string,
	targets: []string,
	note:    string,
}

@(test)
find_keeps_targets_and_drops_prose_punctuation :: proc(t: ^testing.T) {
	cases := [?]Find_Case{
		{"see https://example.com/a.", {"https://example.com/a"}, "trailing sentence period"},
		{"(https://example.com/path)", {"https://example.com/path"}, "prose parenthesis"},
		{
			"https://example.com/path_(x)",
			{"https://example.com/path_(x)"},
			"balanced parenthesis stays",
		},
		{
			"https://example.com/a, and https://example.com/b;",
			{"https://example.com/a", "https://example.com/b"},
			"two targets with comma and semicolon",
		},
		{"'https://example.com/a'", {"https://example.com/a"}, "quoted target"},
		{"https://example.com/a]", {"https://example.com/a"}, "unbalanced square bracket"},
		{"HTTPS://EXAMPLE.COM/A", {"HTTPS://EXAMPLE.COM/A"}, "uppercase scheme"},
		{"xhttps://example.com", {}, "not a URL inside a longer word"},
		{
			"file:///C:/Windows https://example.com",
			{"https://example.com"},
			"other schemes are ignored",
		},
		{
			"https://example.com/\nhttps://second.example",
			{"https://example.com/", "https://second.example"},
			"a hard break starts a new scan and a new target",
		},
		{"https://example.com/?a=(b)", {"https://example.com/?a=(b)"}, "balanced query parens"},
		{"see https://example.com/a\u2026", {"https://example.com/a"}, "unicode ellipsis"},
		{"\u201chttps://example.com/a\u201d", {"https://example.com/a"}, "curly quotes"},
		{
			"https://example.com/a,https://example.com/b",
			{"https://example.com/a", "https://example.com/b"},
			"adjacent comma-separated targets",
		},
		{
			"https://a;https://b",
			{"https://a", "https://b"},
			"adjacent semicolon-separated targets",
		},
		{"\u770b https://example.com/a\u3002", {"https://example.com/a"}, "CJK full stop"},
		{"https://example.com/a\u00a0", {"https://example.com/a"}, "non-breaking space"},
		{"https://example.com/a\u2014", {"https://example.com/a"}, "em dash"},
	}
	for c in cases {
		ranges: [dynamic]links.Range
		defer delete(ranges)
		testing.expectf(t, links.find(c.text, &ranges), "%s: scan failed", c.note)
		if !testing.expectf(t, len(ranges) == len(c.targets), "%s: got %v", c.note, ranges) {
			continue
		}
		cursor := 0
		for target, i in c.targets {
			offset := strings.index(c.text[cursor:], target)
			if !testing.expectf(t, offset >= 0, "%s: target %q missing", c.note, target) {
				continue
			}
			start := cursor + offset
			expected := links.Range{start, start + len(target)}
			testing.expectf(
				t,
				ranges[i] == expected,
				"%s: range %d is %v, expected %v (got %q)",
				c.note,
				i,
				ranges[i],
				expected,
				c.text[ranges[i].start:ranges[i].end],
			)
			cursor = start + len(target)
		}
	}
}

@(test)
find_rejects_targets_the_opener_would_refuse :: proc(t: ^testing.T) {
	for text in ([?]string {
		"http://",
		"http:///path",
		"http://C:/Windows",
		"javascript:alert(1)",
		"file:///C:/Windows",
	}) {
		ranges: [dynamic]links.Range
		defer delete(ranges)
		testing.expect(t, links.find(text, &ranges))
		testing.expectf(t, len(ranges) == 0, "%q produced %v", text, ranges)
	}
}
