package links

import "aio:localpath"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "cosmos:winpath"

@(private)
OBSIDIAN_OPEN :: "obsidian://open?"

// Only the open action is admitted by terminal detection. The click validates its query.
@(require_results)
obsidian_open :: proc(uri: string) -> bool {
	return len(uri) > len(OBSIDIAN_OPEN) && strings.equal_fold(uri[:len(OBSIDIAN_OPEN)], OBSIDIAN_OPEN)
}

// Resolve a vault-relative note using Obsidian's Windows vault registry. Read it only on a click,
// so moving a vault does not require restarting AIODev. The result borrows the temporary allocator.
@(require_results)
resolve_obsidian :: proc(uri, app_data: string) -> (string, bool) {
	if !obsidian_open(uri) || len(uri) > TARGET_BYTES || !localpath.local_absolute(app_data) {return "", false}
	query := uri[len(OBSIDIAN_OPEN):]
	for c in query {
		if c <= ' ' || c == '#' || c == '\\' {return "", false}
	}
	vault, file: string
	for field in strings.split_iterator(&query, "&") {
		at := strings.index_byte(field, '=')
		if at < 0 {continue}
		switch field[:at] {
		case "vault":
			if vault != "" || at + 1 == len(field) {return "", false}
			vault = field[at + 1:]
		case "file":
			if file != "" || at + 1 == len(field) {return "", false}
			file = field[at + 1:]
		}
	}
	if vault == "" || file == "" {return "", false}
	decoded: [TARGET_BYTES]u8 = ---
	name, name_ok := obsidian_decode(vault, decoded[:])
	if !name_ok || !localpath.valid_characters(name) || strings.contains_any(name, `/\`) {return "", false}
	note, note_ok := obsidian_decode(file, decoded[len(name):])
	if !note_ok || !obsidian_note_path(note) {return "", false}

	registry := strings.concatenate({app_data, `\obsidian\obsidian.json`}, context.temp_allocator)
	data, read_error := os.read_entire_file(registry, context.temp_allocator)
	if read_error != nil {return "", false}
	Vault :: struct {path: string}
	config: struct {vaults: map[string]Vault}
	if json.unmarshal(data, &config, allocator = context.temp_allocator) != nil {return "", false}
	root := ""
	if exact, found := config.vaults[name]; found {
		root = exact.path
	} else {
		for _, entry in config.vaults {
			path := strings.trim_right(entry.path, `/\`)
			if !strings.equal_fold(filepath.base(path), name) {continue}
			if root != "" {return "", false}
			root = path
		}
	}
	if !localpath.local_absolute(root) {return "", false}
	extension := strings.equal_fold(filepath.ext(note), ".md") ? "" : ".md"
	path := strings.concatenate({strings.trim_right(root, `/\`), `\`, note, extension}, context.temp_allocator)
	canonical, admitted := localpath.canonical_file_below(path, root)
	if !admitted || !strings.equal_fold(filepath.ext(canonical), ".md") {return "", false}
	return canonical, true
}

@(private, require_results)
obsidian_decode :: proc(raw: string, out: []u8) -> (string, bool) {
	n := 0
	for i := 0; i < len(raw); i += 1 {
		c := raw[i]
		if c == '%' {
			if i + 2 >= len(raw) {return "", false}
			hi, lo := hex_digit(raw[i + 1]), hex_digit(raw[i + 2])
			if hi < 0 || lo < 0 {return "", false}
			c = u8(hi * 16 + lo)
			i += 2
		} else if c == '+' {
			c = ' '
		}
		out[n] = c
		n += 1
	}
	return string(out[:n]), true
}

@(private, require_results)
obsidian_note_path :: proc(path: string) -> bool {
	if !localpath.valid_characters(path) {return false}
	start := 0
	for i := 0; i <= len(path); i += 1 {
		if i < len(path) && !winpath.is_separator(path[i]) {continue}
		part := path[start:i]
		if part == "" || part == "." || part == ".." {return false}
		start = i + 1
	}
	return true
}
