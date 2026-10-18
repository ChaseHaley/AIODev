package settings

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"

shell_executable :: proc(command: string) -> string {
	text := strings.trim_space(command)
	if len(text) == 0 { return "" }
	end := 0
	if text[0] == '"' {
		text = text[1:]
		for end < len(text) && text[end] != '"' { end += 1 }
	} else {
		for end < len(text) && text[end] != ' ' && text[end] != '\t' { end += 1 }
	}
	text = text[:end]
	start := 0
	for c, i in text {
		if c == '/' || c == '\\' { start = i+1 }
	}
	text = text[start:]
	if len(text) >= 4 && strings.equal_fold(text[len(text)-4:], ".exe") { text = text[:len(text)-4] }
	return text
}

shell_icon :: proc(executable, override: string) -> string {
	if override != "" { return override }
	if strings.equal_fold(executable, "cmd") { return "C:" }
	for name in ([?]string{"wsl", "bash", "zsh", "fish", "sh"}) {
		if strings.equal_fold(executable, name) { return "$" }
	}
	return ">_"
}

@(private)
hex_digit :: proc(c: u8) -> (u8, bool) {
	if c >= '0' && c <= '9' { return c-'0', true }
	if c >= 'a' && c <= 'f' { return c-'a'+10, true }
	if c >= 'A' && c <= 'F' { return c-'A'+10, true }
	return 0, false
}

@(require_results)
directory_label :: proc(raw: string, allocator := context.allocator) -> (string, runtime.Allocator_Error) {
	text := raw
	uri := strings.has_prefix(text, "file://")
	if !uri { return strings.clone(raw, allocator) }
	if uri {
		text = text[7:]
		if slash := strings.index_byte(text, '/'); slash >= 0 { text = text[slash:] }
		if len(text) >= 3 && text[0] == '/' && text[2] == ':' { text = text[1:] }
	}
	builder, err := strings.builder_make(allocator)
	if err != nil { return "", err }
	defer strings.builder_destroy(&builder)
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c == '%' && i+2 < len(text) {
			hi, hi_ok := hex_digit(text[i+1])
			lo, lo_ok := hex_digit(text[i+2])
			if hi_ok && lo_ok && hi*16+lo >= ' ' {
				c = hi*16+lo
				i += 2
			}
		}
		if strings.write_byte(&builder, c) != 1 { return "", .Out_Of_Memory }
	}
	decoded := strings.to_string(builder)
	if !utf8.valid_string(decoded) { return strings.clone(raw, allocator) }
	return strings.clone(decoded, allocator)
}

