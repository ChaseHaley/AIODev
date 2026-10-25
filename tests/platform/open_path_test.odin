package platform_test

import p "aio:platform"
import "core:testing"

@(test)
open_path_accepts_only_local_paths :: proc(t: ^testing.T) {
	cases := [?]struct {
		path, note: string,
		allowed:    bool,
	} {
		{`C:\Users\example\AppData\Roaming\AIODev\settings.ini`, "absolute settings path", true},
		{`C:/Users/example/AppData/Roaming/AIODev/settings.ini`, "forward drive path", true},
		{`settings.ini`, "relative local file", true},
		{`folder\settings.ini`, "relative nested file", true},
		{`https://example.com/settings`, "https scheme", false},
		{`http://example.com`, "http scheme", false},
		{`file:///C:/Windows/System32/cmd.exe`, "file scheme", false},
		{`shell:AppsFolder`, "shell scheme", false},
		{`javascript:alert(1)`, "script scheme", false},
		{`mailto:someone@example.com`, "mail scheme", false},
		{`\\server\share\settings.ini`, "UNC network path", false},
		{`//server/share/settings.ini`, "forward UNC path", false},
		{`C:relative\settings.ini`, "drive-relative path", false},
		{"C:\\Users\\example\\settings.ini\x00", "NUL byte", false},
		{"", "empty", false},
	}
	for c in cases {
		testing.expectf(
			t,
			p.open_path_allowed(c.path) == c.allowed,
			"%s (%q): expected allowed=%t",
			c.note,
			c.path,
			c.allowed,
		)
	}
}

// The opener repeats the allowlist at the last boundary. Refused targets must return without
// reaching ShellExecuteW, so this test can run without a browser or any visible window.
@(test)
open_url_refuses_everything_but_plain_web_targets :: proc(t: ^testing.T) {
	for uri in ([?]string {
		"",
		"file:///C:/Windows/win.ini",
		"ssh://example.com/repo",
		"javascript:alert(1)",
		"data:text/html,hello",
		"mailto:someone@example.com",
		"ftp://example.com/file",
		`\\server\share\file`,
		`http://\\server\share`,
		"http://C:/Windows",
		"http://",
		"http:///path",
		"http://user@example.com",
		"http://exa mple.com",
	}) {
		testing.expectf(t, !p.open_url(uri), "opened refused target %q", uri)
	}
}
