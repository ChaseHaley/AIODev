package commands

import "core:reflect"
import "core:strings"
import "core:unicode/utf8"
import "aio:fuzzy"
import "aio:input"

Command_Id :: distinct u32
Shortcut :: struct { key: input.Key, modifiers: input.Modifiers }
MAX_SHORTCUTS :: 4
Shortcut_Set :: struct { items: [MAX_SHORTCUTS]Shortcut, count: int }
Override :: struct { id: Command_Id, shortcuts: []Shortcut }
Command :: struct {
	id: Command_Id,
	name, title: string,
	shortcuts, defaults: Shortcut_Set,
	disabled: bool,
}
Error :: enum {
	None,
	Duplicate_Id,
	Duplicate_Name,
	Duplicate_Shortcut,
	Invalid_UTF8,
	Out_Of_Memory,
	Output_Too_Small,
	Unknown_Command,
	Invalid_Shortcut,
}
Registry :: struct { items: [dynamic]Command }
Search_Result :: struct { command: ^Command, score: f64, positions: []int }

create :: proc(allocator := context.allocator) -> Registry {
	registry: Registry
	registry.items.allocator = allocator
	return registry
}

destroy :: proc(registry: ^Registry) {
	for item in registry.items {
		delete(item.name, registry.items.allocator)
		delete(item.title, registry.items.allocator)
	}
	delete(registry.items)
	registry^ = {}
}

@(private)
normalized :: proc(modifiers: input.Modifiers) -> input.Modifiers {
	return modifiers & {.Control, .Shift, .Alt, .Super, .Leader}
}

@(require_results)
register :: proc(registry: ^Registry, command: Command) -> Error {
	if !utf8.valid_string(command.name) || !utf8.valid_string(command.title) {
		return .Invalid_UTF8
	}
	for item in registry.items {
		if item.id == command.id { return .Duplicate_Id }
		if item.name == command.name { return .Duplicate_Name }
	}
	assert(command.shortcuts.count >= 0 && command.shortcuts.count <= MAX_SHORTCUTS)
	for i in 0..<command.shortcuts.count {
		binding := command.shortcuts.items[i]
		if find_by_shortcut(registry, binding) != nil { return .Duplicate_Shortcut }
	}
	owned := command
	owned.defaults = command.shortcuts
	allocator := registry.items.allocator
	name, name_error := strings.clone(command.name, allocator)
	if name_error != nil { return .Out_Of_Memory }
	title, title_error := strings.clone(command.title, allocator)
	if title_error != nil {
		delete(name, allocator)
		return .Out_Of_Memory
	}
	owned.name, owned.title = name, title
	_, err := append(&registry.items, owned)
	if err != nil {
		delete(name, allocator)
		delete(title, allocator)
		return .Out_Of_Memory
	}
	return .None
}

find :: proc{find_id, find_name}

@(private, require_results)
find_id :: proc(registry: ^Registry, id: Command_Id) -> ^Command {
	for &item in registry.items {
		if item.id == id { return &item }
	}
	return nil
}

@(private, require_results)
find_name :: proc(registry: ^Registry, name: string) -> ^Command {
	for &item in registry.items {
		if item.name == name { return &item }
	}
	return nil
}

@(require_results)
find_by_shortcut :: proc(registry: ^Registry, shortcut: Shortcut) -> ^Command {
	for &item in registry.items {
		for binding in active_shortcuts(&item) {
			if binding.key == shortcut.key &&
			   normalized(binding.modifiers) == normalized(shortcut.modifiers) {
				return &item
			}
		}
	}
	return nil
}

@(require_results)
set_enabled :: proc(registry: ^Registry, id: Command_Id, enabled: bool) -> bool {
	command := find(registry, id)
	if command == nil { return false }
	command.disabled = !enabled
	return true
}

@(private)
KEY_LABELS :: #partial [input.Key]string{
	.Unidentified = "Unknown",
	.Backquote = "`",
	.Backslash = "\\",
	.Bracket_Left = "[",
	.Bracket_Right = "]",
	.Comma = ",",
	.Digit_0 = "0",
	.Digit_1 = "1",
	.Digit_2 = "2",
	.Digit_3 = "3",
	.Digit_4 = "4",
	.Digit_5 = "5",
	.Digit_6 = "6",
	.Digit_7 = "7",
	.Digit_8 = "8",
	.Digit_9 = "9",
	.Equal = "=",
	.Intl_Backslash = "Intl Backslash",
	.Intl_Ro = "Ro",
	.Intl_Yen = "Yen",
	.Minus = "-",
	.Period = ".",
	.Quote = "'",
	.Semicolon = ";",
	.Slash = "/",
	.Alt_Left = "Left Alt",
	.Alt_Right = "Right Alt",
	.Caps_Lock = "Caps Lock",
	.Context_Menu = "Menu",
	.Control_Left = "Left Ctrl",
	.Control_Right = "Right Ctrl",
	.Meta_Left = "Left " + SUPER_LABEL,
	.Meta_Right = "Right " + SUPER_LABEL,
	.Shift_Left = "Left Shift",
	.Shift_Right = "Right Shift",
	.Kana_Mode = "Kana",
	.Non_Convert = "NonConvert",
	.Page_Down = "PageDown",
	.Page_Up = "PageUp",
	.Arrow_Down = "Down",
	.Arrow_Left = "Left",
	.Arrow_Right = "Right",
	.Arrow_Up = "Up",
	.Num_Lock = "Num Lock",
	.Numpad_0 = "Num 0",
	.Numpad_1 = "Num 1",
	.Numpad_2 = "Num 2",
	.Numpad_3 = "Num 3",
	.Numpad_4 = "Num 4",
	.Numpad_5 = "Num 5",
	.Numpad_6 = "Num 6",
	.Numpad_7 = "Num 7",
	.Numpad_8 = "Num 8",
	.Numpad_9 = "Num 9",
	.Numpad_Add = "Num+",
	.Numpad_Backspace = "Num Backspace",
	.Numpad_Clear = "Num Clear",
	.Numpad_Clear_Entry = "Num Clear Entry",
	.Numpad_Comma = "Num ,",
	.Numpad_Decimal = "Num .",
	.Numpad_Divide = "Num/",
	.Numpad_Enter = "Num Enter",
	.Numpad_Equal = "Num=",
	.Numpad_Memory_Add = "Num Memory+",
	.Numpad_Memory_Clear = "Num Memory Clear",
	.Numpad_Memory_Recall = "Num Memory Recall",
	.Numpad_Memory_Store = "Num Memory Store",
	.Numpad_Memory_Subtract = "Num Memory-",
	.Numpad_Multiply = "Num*",
	.Numpad_Paren_Left = "Num (",
	.Numpad_Paren_Right = "Num )",
	.Numpad_Subtract = "Num-",
	.Numpad_Separator = "Num Separator",
	.Numpad_Up = "Num Up",
	.Numpad_Down = "Num Down",
	.Numpad_Right = "Num Right",
	.Numpad_Left = "Num Left",
	.Numpad_Begin = "Num Begin",
	.Numpad_Home = "Num Home",
	.Numpad_End = "Num End",
	.Numpad_Insert = "Num Insert",
	.Numpad_Delete = "Num Delete",
	.Numpad_Page_Up = "Num PageUp",
	.Numpad_Page_Down = "Num PageDown",
	.Escape = "Esc",
	.Fn_Lock = "Fn Lock",
	.Print_Screen = "PrtSc",
	.Scroll_Lock = "Scroll Lock",
	.Browser_Back = "Browser Back",
	.Browser_Favorites = "Browser Favorites",
	.Browser_Forward = "Browser Forward",
	.Browser_Home = "Browser Home",
	.Browser_Refresh = "Browser Refresh",
	.Browser_Search = "Browser Search",
	.Browser_Stop = "Browser Stop",
	.Launch_App_1 = "Launch App 1",
	.Launch_App_2 = "Launch App 2",
	.Launch_Mail = "Mail",
	.Media_Play_Pause = "Play/Pause",
	.Media_Select = "Select Media",
	.Media_Stop = "Stop Media",
	.Media_Track_Next = "Next Track",
	.Media_Track_Previous = "Previous Track",
	.Audio_Volume_Down = "Volume Down",
	.Audio_Volume_Mute = "Mute",
	.Audio_Volume_Up = "Volume Up",
	.Wake_Up = "Wake",
}

@(require_results)
shortcut_label :: proc(shortcut: Shortcut, out: []u8) -> (string, Error) {
	@(static, rodata) key_labels := KEY_LABELS
	key, known := reflect.enum_name_from_value(shortcut.key)
	if !known {
		key = "Unknown"
	} else if label := key_labels[shortcut.key]; label != "" {
		key = label
	}
	length := 0
	for modifier in ([?]input.Modifier{.Leader, .Control, .Shift, .Alt, .Super}) {
		if modifier not_in shortcut.modifiers { continue }
		text: string
		#partial switch modifier {
		case .Control: text = "Ctrl+"
		case .Shift: text = "Shift+"
		case .Alt: text = "Alt+"
		case .Super: text = SUPER_LABEL + "+"
		case .Leader: text = "Leader+"
		}
		if len(out)-length < len(text) { return "", .Output_Too_Small }
		length += copy(out[length:], text)
	}
	if len(out)-length < len(key) { return "", .Output_Too_Small }
	length += copy(out[length:], key)
	return string(out[:length]), .None
}

@(require_results)
search :: proc(
	registry: ^Registry,
	query: string,
	out: []Search_Result,
	positions: []int,
	scratch: ^fuzzy.Scratch,
	allocator := context.temp_allocator,
) -> (int, Error) {
	if !utf8.valid_string(query) { return 0, .Invalid_UTF8 }
	count := len(registry.items)
	width := utf8.rune_count(query)
	if len(out) < count || (width > 0 && len(positions)/width < count) {
		return 0, .Output_Too_Small
	}
	titles, title_error := make([]string, count, allocator)
	if title_error != nil { return 0, .Out_Of_Memory }
	defer delete(titles, allocator)
	indices, index_error := make([]int, count, allocator)
	if index_error != nil { return 0, .Out_Of_Memory }
	defer delete(indices, allocator)
	ranked, rank_error := make([]fuzzy.Ranked, count, allocator)
	if rank_error != nil { return 0, .Out_Of_Memory }
	defer delete(ranked, allocator)
	n := 0
	for item, index in registry.items {
		if item.disabled { continue }
		titles[n], indices[n] = item.title, index
		n += 1
	}
	matched, err := fuzzy.rank(query, titles[:n], ranked[:n], scratch)
	switch err {
	case .None:
	case .Invalid_UTF8: return 0, .Invalid_UTF8
	case .Output_Too_Small: unreachable()
	}
	for result, index in ranked[:matched] {
		command := &registry.items[indices[result.index]]
		highlights := positions[index*width:(index+1)*width]
		_, position_error := fuzzy.match_positions(query, command.title, highlights, scratch)
		switch position_error {
		case .None:
		case .Invalid_UTF8: return 0, .Invalid_UTF8
		case .Output_Too_Small: unreachable()
		}
		out[index] = {command, result.score, highlights}
	}
	return matched, .None
}

active_shortcuts :: proc(command: ^Command) -> []Shortcut {
	return command.shortcuts.items[:command.shortcuts.count]
}

@(require_results)
set_shortcuts :: proc(registry: ^Registry, id: Command_Id, shortcuts: []Shortcut) -> Error {
	command := find(registry, id)
	if command == nil { return .Unknown_Command }
	assert(len(shortcuts) <= MAX_SHORTCUTS)
	for shortcut in shortcuts {
		if other := find_by_shortcut(registry, shortcut); other != nil && other.id != id {
			return .Duplicate_Shortcut
		}
	}
	bindings := Shortcut_Set{count = len(shortcuts)}
	for shortcut, i in shortcuts {
		bindings.items[i] = {shortcut.key, normalized(shortcut.modifiers)}
	}
	command.shortcuts = bindings
	return .None
}

// Overrides replace defaults; an override that cannot apply falls back to its command's defaults, or
// leaves the command unbound when those are taken too.
rebind :: proc(registry: ^Registry, overrides: []Override, errors: []Error) {
	assert(len(errors) >= len(overrides))
	for &command in registry.items { command.shortcuts = {} }
	for &command in registry.items {
		overridden := false
		for override in overrides {
			if override.id == command.id {
				overridden = true
				break
			}
		}
		if !overridden { command.shortcuts = command.defaults }
	}
	for override, i in overrides {
		errors[i] = set_shortcuts(registry, override.id, override.shortcuts)
		command := find(registry, override.id)
		if errors[i] == .None || command == nil { continue }
		defaults := command.defaults.items[:command.defaults.count]
		if set_shortcuts(registry, command.id, defaults) != .None {
			command.shortcuts = {}
		}
	}
}

@(require_results)
parse_shortcut :: proc(text: string) -> (Shortcut, bool) {
	rest := strings.trim_space(text)
	modifiers: input.Modifiers
	for {
		plus := strings.index_byte(rest, '+')
		if plus < 0 { break }
		prefix := strings.trim_space(rest[:plus])
		modifier: input.Modifier
		recognized := true
		switch {
		case strings.equal_fold(prefix, "Ctrl"): modifier = .Control
		case strings.equal_fold(prefix, "Shift"): modifier = .Shift
		case strings.equal_fold(prefix, "Alt"): modifier = .Alt
		case strings.equal_fold(prefix, SUPER_LABEL): modifier = .Super
		case strings.equal_fold(prefix, "Leader"): modifier = .Leader
		case: recognized = false
		}
		if !recognized { break }
		if modifier in modifiers { return {}, false }
		modifiers += {modifier}
		rest = strings.trim_space(rest[plus+1:])
	}
	buffer: [128]u8
	for key in input.Key {
		label, err := shortcut_label({key, {}}, buffer[:])
		if err != .None { return {}, false }
		if strings.equal_fold(rest, label) { return {key, modifiers}, true }
	}
	return {}, false
}

@(require_results)
parse_shortcuts :: proc(text: string, out: []Shortcut) -> (int, Error) {
	rest := strings.trim_space(text)
	count := 0
	for rest != "" {
		found := false
		for end in 1..=len(rest) {
			if end < len(rest) && rest[end] != ',' { continue }
			shortcut, ok := parse_shortcut(rest[:end])
			if !ok { continue }
			if count == len(out) { return 0, .Output_Too_Small }
			out[count] = shortcut
			count += 1
			if end == len(rest) { return count, .None }
			rest = strings.trim_space(rest[end+1:])
			if rest == "" { return 0, .Invalid_Shortcut }
			found = true
			break
		}
		if !found { return 0, .Invalid_Shortcut }
	}
	return count, .None
}
