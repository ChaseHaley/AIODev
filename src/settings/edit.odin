package settings

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

schema_find :: proc(key: string) -> ^Schema_Entry {
	@(static, rodata) schema := SCHEMA
	for &entry in schema {
		if entry.key == key { return &entry }
	}
	return nil
}

value_text :: proc(s: ^Settings, entry: Schema_Entry) -> string {
	p := rawptr(uintptr(s) + entry.offset)
	switch entry.kind {
	case .String: return (cast(^string)p)^
	case .Int: return fmt.tprintf("%d", (cast(^int)p)^)
	case .Float: return fmt.tprintf("%g", (cast(^f64)p)^)
	case .Bool: return (cast(^bool)p)^ ? "true" : "false"
	case .Enum: return entry.enum_names[(cast(^int)p)^]
	case .Color: return color_text((cast(^Color)p)^)
	case .Optional_Color:
		if c, ok := (cast(^Maybe(Color))p)^.?; ok { return color_text(c) }
	}
	return ""
}

@(private)
color_text :: proc(c: Color) -> string {
	return fmt.tprintf("#%02x%02x%02x", c.r, c.g, c.b)
}

// The returned message is owned by the caller, even when validation fails.
@(require_results)
edit_text :: proc(text, key, value: string, allocator := context.allocator) -> (
	updated, message: string, err: runtime.Allocator_Error,
) {
	if strings.contains_any(value, "\r\n\x00") {
		message, err = strings.clone("Use a single line without NUL bytes.", allocator)
		return
	}
	serialized := value
	if entry := schema_find(key); entry != nil {
		if entry.kind == .String { serialized = fmt.tprintf("\"%s\"", value) }
		s, default_error := defaults(allocator)
		if default_error != nil { err = default_error; return }
		defer destroy(&s)
		issue, assign_error := assign(&s, entry^, serialized)
		if assign_error != nil { err = assign_error; return }
		if p, ok := issue.?; ok { message = p.message; return }
	} else if !strings.has_prefix(key, KEY_BINDING_PREFIX) {
		message, err = strings.clone("Unknown setting.", allocator)
		return
	}
	b, build_error := strings.builder_make(allocator)
	if build_error != nil { err = build_error; return }
	defer strings.builder_destroy(&b)
	eol := strings.contains(text, "\r\n") ? "\r\n" : "\n"
	rest := text
	written := false
	for len(rest) > 0 {
		end := strings.index_byte(rest, '\n')
		if end < 0 { end = len(rest)-1 }
		raw := rest[:end+1]
		rest = rest[end+1:]
		line := strings.trim_space(strings.trim_prefix(raw, "\xef\xbb\xbf"))
		equal := strings.index_byte(line, '=')
		if equal >= 0 && strings.trim_space(line[:equal]) == key {
			if written { continue }
			if strings.has_prefix(raw, "\xef\xbb\xbf") {
				if err = write_parts(&b, "\xef\xbb\xbf"); err != nil { return }
			}
			if err = write_parts(&b, key, " = ", serialized, eol); err != nil { return }
			written = true
		} else {
			if err = write_parts(&b, raw); err != nil { return }
		}
	}
	if !written {
		if len(text) > 0 && text[len(text)-1] != '\n' {
			if err = write_parts(&b, eol); err != nil { return }
		}
		if err = write_parts(&b, key, " = ", serialized, eol); err != nil { return }
	}
	updated, err = strings.clone(strings.to_string(b), allocator)
	return
}

Save_Error :: enum { None, Conflict, IO }

@(require_results)
save :: proc(path, expected, updated: string) -> Save_Error {
	f, err := os.create_temp_file(os.dir(path), ".aiodev-settings-*")
	if err != nil { log.errorf("creating settings temporary file failed: %v", err); return .IO }
	name := strings.clone(os.name(f), context.temp_allocator)
	defer if cleanup_error := os.remove(name); cleanup_error != nil && cleanup_error != .Not_Exist {
		log.errorf("removing settings temporary file failed: %v", cleanup_error)
	}
	n, write_error := os.write(f, transmute([]u8)updated)
	sync_error := os.sync(f)
	close_error := os.close(f)
	if write_error != nil || n != len(updated) || sync_error != nil || close_error != nil {
		log.errorf("writing settings failed: %v, %v, %v (%d/%d bytes)",
			write_error, sync_error, close_error, n, len(updated))
		return .IO
	}
	current, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil { log.errorf("reading settings before save failed: %v", read_error); return .IO }
	if string(current) != expected { return .Conflict }
	if rename_error := os.rename(name, path); rename_error != nil {
		log.errorf("replacing settings failed: %v", rename_error)
		return .IO
	}
	return .None
}
