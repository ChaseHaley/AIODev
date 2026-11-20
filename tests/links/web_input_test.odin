package links_test

import "core:testing"
import "aio:links"

@(test)
normalize_web_input_adds_schemes_and_refuses_others :: proc(t: ^testing.T) {
	cases := [?]struct {
		raw, want: string,
	} {
		{"https://example.com/a", "https://example.com/a"},
		{"  http://example.com  ", "http://example.com"},
		{"example.com", "https://example.com"},
		{"example.com/path?q=1", "https://example.com/path?q=1"},
		{"localhost:3000", "http://localhost:3000"},
		{"LOCALHOST:3000/path", "http://LOCALHOST:3000/path"},
		{"localhost.run/path", "https://localhost.run/path"},
		{"127.0.0.10:8080/x", "https://127.0.0.10:8080/x"},
		{"127.0.0.1:8080/x", "http://127.0.0.1:8080/x"},
		{"[::1]:9000", "http://[::1]:9000"},
		{"", ""},
		{"   ", ""},
		{"file:///C:/My%20Reports/index.html#details", "file:///C:/My%20Reports/index.html#details"},
		{" FILE:///d:/preview folder/index.html ", "FILE:///d:/preview folder/index.html"},
		{"file:///C:/café.html?draft=1", "file:///C:/café.html?draft=1"},
		{"file://server/share/report.html", ""},
		{"file:////server/share/report.html", ""},
		{"file:///x", ""},
		{`file:///C:/preview\report.html`, ""},
		{"file:///C:/preview\x00/report.html", ""},
		{"javascript:alert(1)", ""},
		{"ftp://example.com", ""},
		{"two words", ""},
		{"http://[::1]:8080/x", "http://[::1]:8080/x"},
		{"\texample.com\n", "https://example.com"},
		{"JavaScript:alert(1)", ""},
		// A scheme with no slashes is not a host and port.
		{"about:blank", ""},
		{"data:text/html,hi", ""},
		{"file:relative.html", ""},
		{"mailto:someone@example.com", ""},
		{"localhost:", ""},
		{"example.com:443/a", "https://example.com:443/a"},
	}
	for c in cases {
		got, ok := links.normalize_web_input(c.raw, context.temp_allocator)
		testing.expectf(t, ok == (c.want != ""), "%q: accepted = %v", c.raw, ok)
		testing.expectf(t, got == c.want, "%q: got %q, want %q", c.raw, got, c.want)
	}
}
