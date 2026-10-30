package links

import "core:strings"
import "core:unicode/utf8"

// Absolute local drive paths only. UNC, device names and alternate data streams never reach an opener.
@(require_results)
local_absolute :: proc(path: string) -> bool {
	if len(path) < 3 || !((path[0] >= 'A' && path[0] <= 'Z') ||
	   (path[0] >= 'a' && path[0] <= 'z')) || path[1] != ':' ||
	   (path[2] != '/' && path[2] != '\\') {return false}
	return path_characters(path[2:])
}

@(private, require_results)
path_characters :: proc(path: string) -> bool {
	if path == "" || !utf8.valid_string(path) {return false}
	for c in path {
		if c < 32 || (c >= 127 && c <= 159) || c == ':' || c == '"' || c == '<' ||
		   c == '>' || c == '|' || c == '?' || c == '*' || c == 0x2028 || c == 0x2029 ||
		   (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069) ||
		   c == 0x200b || c == 0xfeff {return false}
	}
	start := 0
	for i := 0; i <= len(path); i += 1 {
		if i != len(path) && path[i] != '/' && path[i] != '\\' {continue}
		part := path[start:i]
		if part != "" && part != "." && part != ".." {
			if part[len(part) - 1] == '.' || part[len(part) - 1] == ' ' {return false}
			base := part
			if dot := strings.index_byte(part, '.'); dot >= 0 {base = part[:dot]}
			for reserved in ([?]string{"con", "prn", "aux", "nul", "conin$", "conout$"}) {
				if strings.equal_fold(base, reserved) {return false}
			}
			if len(base) == 4 && base[3] >= '0' && base[3] <= '9' &&
			   (strings.equal_fold(base[:3], "com") || strings.equal_fold(base[:3], "lpt")) {
				return false
			}
		}
		start = i + 1
	}
	return true
}

@(private, require_results)
hex_digit :: proc(c: u8) -> int {
	if c >= '0' && c <= '9' {return int(c - '0')}
	if c >= 'a' && c <= 'f' {return int(c - 'a') + 10}
	if c >= 'A' && c <= 'F' {return int(c - 'A') + 10}
	return -1
}

@(private, require_results)
local_authority :: proc(host: string, hosts: []string) -> bool {
	if host == "" || strings.equal_fold(host, "localhost") {return true}
	for name in hosts {
		if name != "" && strings.equal_fold(host, name) {return true}
	}
	return false
}

// URI decoding happens exactly once, before path validation. Remote authorities are refused
// before any filesystem access; hosts lists this machine's own names, which shells and ls
// write into OSC 7 and OSC 8. WSL shares are deliberately excluded with all other UNC paths.
@(private, require_results)
file_uri_path :: proc(uri: string, hosts: []string, buffer: []u8) -> (string, bool) {
	if len(uri) < 8 || !strings.equal_fold(uri[:7], "file://") {return "", false}
	rest := uri[7:]
	slash := strings.index_byte(rest, '/')
	if slash < 0 {return "", false}
	if !local_authority(rest[:slash], hosts) {return "", false}
	raw := rest[slash + 1:]
	at := 0
	for i := 0; i < len(raw); i += 1 {
		if at >= len(buffer) {return "", false}
		c := raw[i]
		if c == '#' || c == '?' {return "", false}
		if c == '%' {
			if i + 2 >= len(raw) {return "", false}
			hi, lo := hex_digit(raw[i + 1]), hex_digit(raw[i + 2])
			if hi < 0 || lo < 0 {return "", false}
			c = u8(hi * 16 + lo)
			i += 2
		}
		buffer[at] = c
		at += 1
	}
	path := string(buffer[:at])
	return path, local_absolute(path)
}

// Compiler locations: path:12, path:12:4, and the Odin and MSVC forms path(12), path(12,4)
// and path(12:4).
@(private, require_results)
strip_location :: proc(path: string) -> string {
	if strings.has_suffix(path, ")") {
		open := strings.last_index_byte(path, '(')
		if open > 0 {
			digits, separated := 0, false
			numbers := true
			for c in transmute([]u8)path[open + 1:len(path) - 1] {
				if c >= '0' && c <= '9' {digits += 1; continue}
				if (c == ',' || c == ':') && digits > 0 && !separated {
					separated, digits = true, 0
					continue
				}
				numbers = false
				break
			}
			if numbers && digits > 0 {return path[:open]}
		}
	}
	end := len(path)
	for _ in 0 ..< 2 {
		at := end
		for at > 0 && path[at - 1] >= '0' && path[at - 1] <= '9' {at -= 1}
		if at == end || at == 0 || path[at - 1] != ':' {break}
		end = at - 1
	}
	return path[:end]
}

// Resolve a printed target using only a shell-reported local cwd. The returned string borrows
// buffer; there is no filesystem access or allocation. File URIs name literal files, not locations.
@(require_results)
resolve_file :: proc(target, cwd: string, hosts: []string, buffer: []u8) -> (string, bool) {
	if len(target) >= 5 && strings.equal_fold(target[:5], "file:") {
		path, ok := file_uri_path(target, hosts, buffer)
		if !ok {return "", false}
		return path, true
	}
	path := strip_location(target)
	if local_absolute(path) {
		if len(path) > len(buffer) {return "", false}
		copy(buffer, transmute([]u8)path)
		return string(buffer[:len(path)]), true
	}
	if !path_characters(path) || path[0] == '/' || path[0] == '\\' {return "", false}
	base := cwd
	if len(cwd) >= 5 && strings.equal_fold(cwd[:5], "file:") {
		decoded, ok := file_uri_path(cwd, hosts, buffer)
		if !ok {return "", false}
		base = decoded
	}
	if !local_absolute(base) || len(base) + 1 + len(path) > len(buffer) {return "", false}
	copy(buffer, transmute([]u8)base)
	buffer[len(base)] = '\\'
	copy(buffer[len(base) + 1:], transmute([]u8)path)
	return string(buffer[:len(base) + 1 + len(path)]), true
}

// Bare names need a dot or a directory separator to avoid turning ordinary prose into links.
// Quoted paths may contain spaces. The original byte range retains compiler location suffixes.
// Printed file URIs need an empty or localhost authority; machine names are honoured in OSC 8.
@(require_results)
find_files :: proc(text: string, relative: bool, out: ^[dynamic]Range) -> bool {
	at := 0
	buffer: [4096]u8 = ---
	for at < len(text) {
		for at < len(text) && (text[at] <= ' ' || text[at] == '(' || text[at] == '[') {at += 1}
		if at == len(text) {break}
		quote := u8(0)
		if text[at] == '"' || text[at] == '\'' || text[at] == '`' {
			quote = text[at]
			at += 1
		}
		start := at
		for at < len(text) {
			c := text[at]
			if quote != 0 && c == quote || quote == 0 &&
			   (c <= ' ' || c == '"' || c == '\'' || c == '`' || c == '<' || c == '>' || c == '|') {
				break
			}
			at += 1
		}
		end := quote != 0 ? at : trim_prose(text, start, at)
		if end > start {
			candidate := text[start:end]
			shaped := strings.contains_any(candidate, ".\\/")
			cwd := relative ? "C:/" : ""
			if shaped {
				if _, ok := resolve_file(candidate, cwd, nil, buffer[:]); ok {
					if _, err := append(out, Range{start, end}); err != nil {return false}
				}
			}
		}
		if at < len(text) {at += 1}
	}
	return true
}

// Includes shell-active formats absent from a stock PATHEXT. Empty PATHEXT entries never match.
@(require_results)
file_needs_confirmation :: proc(path, pathext: string) -> bool {
	ext := ""
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {break}
		if path[i] == '.' {ext = path[i:]; break}
	}
	for active in ([?]string{
		".exe", ".com", ".bat", ".cmd", ".ps1", ".psm1", ".psd1", ".vbs", ".vbe", ".js", ".jse",
		".wsf", ".wsh", ".msc", ".scr", ".pif", ".cpl", ".dll", ".ocx", ".sys", ".drv", ".reg",
		".lnk", ".url", ".website", ".scf", ".msi", ".msp", ".mst", ".hta", ".chm", ".hlp",
		".library-ms", ".settingcontent-ms", ".appref-ms", ".application", ".gadget", ".inf", ".ins",
		".isp", ".sct", ".wsc", ".appx", ".appxbundle", ".msix", ".msixbundle", ".appinstaller",
		".py", ".pyw", ".pl", ".rb", ".sh", ".bash", ".jar", ".jnlp", ".diagcab",
	}) {
		if strings.equal_fold(ext, active) {return true}
	}
	start := 0
	for i := 0; i <= len(pathext); i += 1 {
		if i < len(pathext) && pathext[i] != ';' {continue}
		entry := strings.trim_space(pathext[start:i])
		if entry != "" && ext != "" && strings.equal_fold(ext, entry) {return true}
		start = i + 1
	}
	return false
}
