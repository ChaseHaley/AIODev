package commands

import "aio:input"
import "base:runtime"
import "core:reflect"
import "core:strings"
import "core:unicode/utf8"

Command_Id :: distinct u32
Shortcut :: struct {
	key:       input.Key,
	modifiers: input.Modifiers,
}
Shortcut_Set :: struct {
	items: []Shortcut,
	count: int,
}
Override :: struct {
	id:        Command_Id,
	shortcuts: []Shortcut,
}
Command :: struct {
	id:                  Command_Id,
	name, title:         string,
	shortcuts, defaults: Shortcut_Set,
	disabled:            bool,
	// The arguments the command accepts, and those it cannot run without.
	arguments, required: Arguments,
	// Hidden commands serve the CLI and scripts: they stay out of the palette and shortcut lists.
	hidden:              bool,
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
Registry :: struct {
	items: [dynamic]Command,
}

create :: proc(allocator := context.allocator) -> Registry {
	registry: Registry
	registry.items.allocator = allocator
	return registry
}

destroy :: proc(registry: ^Registry) {
	for item in registry.items {
		delete(item.name, registry.items.allocator)
		delete(item.title, registry.items.allocator)
		delete(item.shortcuts.items, registry.items.allocator)
		delete(item.defaults.items, registry.items.allocator)
	}
	delete(registry.items)
	registry^ = {}
}

@(private)
normalized :: proc(modifiers: input.Modifiers) -> input.Modifiers {
	return modifiers & {.Control, .Shift, .Alt, .Super, .Leader, .Physical}
}

logical_key :: proc(physical: input.Key, unshifted: rune) -> input.Key {
	// Digit-row defaults follow their number positions even on layouts such as
	// AZERTY, whose unshifted row includes named punctuation (' and -).
	if physical >= .Digit_0 && physical <= .Digit_9 {return physical}
	if unshifted < ' ' || (physical > .Slash && physical != .Space) {return physical}
	if unshifted >= 'a' &&
	   unshifted <= 'z' {return input.Key(int(input.Key.A) + int(unshifted - 'a'))}
	if unshifted >= 'A' &&
	   unshifted <= 'Z' {return input.Key(int(input.Key.A) + int(unshifted - 'A'))}
	if unshifted >= '0' &&
	   unshifted <= '9' {return input.Key(int(input.Key.Digit_0) + int(unshifted - '0'))}
	switch unshifted {
	case '`':
		return .Backquote
	case '\\':
		return .Backslash
	case '[':
		return .Bracket_Left
	case ']':
		return .Bracket_Right
	case ',':
		return .Comma
	case '=':
		return .Equal
	case '-':
		return .Minus
	case '.':
		return .Period
	case '\'':
		return .Quote
	case ';':
		return .Semicolon
	case '/':
		return .Slash
	case ' ':
		return .Space
	}
	// Ghostty also falls back to the physical key when the layout character has
	// no named key identity (for example Cyrillic letters or AZERTY '&').
	return physical
}

// A prefix reserves the same named chord in both identity modes. Direct
// logical/physical bindings remain distinct and retain physical-first dispatch.
prefix_conflicts :: proc(prefix, binding: Shortcut) -> bool {
	return(
		prefix.key == binding.key &&
		normalized(prefix.modifiers) - {.Physical} == normalized(binding.modifiers) - {.Physical} \
	)
}

shortcut_matches :: proc(
	binding: Shortcut,
	physical: input.Key,
	modifiers: input.Modifiers,
	unshifted: rune,
) -> bool {
	key := .Physical in binding.modifiers ? physical : logical_key(physical, unshifted)
	return(
		binding.key == key &&
		normalized(binding.modifiers) - {.Physical} == normalized(modifiers) - {.Physical} \
	)
}

@(require_results)
find_by_key :: proc(
	registry: ^Registry,
	physical: input.Key,
	modifiers: input.Modifiers,
	unshifted: rune,
) -> ^Command {
	logical := logical_key(physical, unshifted)
	mods := normalized(modifiers) - {.Physical}
	fallback: ^Command
	for &item in registry.items {
		for binding in active_shortcuts(&item) {
			if normalized(binding.modifiers) - {.Physical} != mods {continue}
			is_physical := .Physical in binding.modifiers
			if binding.key != (is_physical ? physical : logical) {continue}
			if is_physical {return &item}
			if fallback == nil {fallback = &item}
		}
	}
	return fallback
}

@(require_results)
unbind :: proc(registry: ^Registry, id: Command_Id, shortcut: Shortcut) -> bool {
	item := find(registry, id)
	if item == nil {return false}
	for binding, i in active_shortcuts(item) {
		if binding.key != shortcut.key ||
		   normalized(binding.modifiers) != normalized(shortcut.modifiers) {
			continue
		}
		for j := i;
		    j + 1 < item.shortcuts.count;
		    j += 1 {item.shortcuts.items[j] = item.shortcuts.items[j + 1]}
		item.shortcuts.count -= 1
		return true
	}
	return false
}

@(require_results)
register :: proc(registry: ^Registry, command: Command) -> Error {
	if !utf8.valid_string(command.name) || !utf8.valid_string(command.title) {
		return .Invalid_UTF8
	}
	for item in registry.items {
		if item.id == command.id {return .Duplicate_Id}
		if item.name == command.name {return .Duplicate_Name}
	}
	assert(command.shortcuts.count >= 0 && command.shortcuts.count <= len(command.shortcuts.items))
	for i in 0 ..< command.shortcuts.count {
		binding := command.shortcuts.items[i]
		if find_by_shortcut(registry, binding) != nil {return .Duplicate_Shortcut}
	}
	owned := command
	allocator := registry.items.allocator
	name, name_error := strings.clone(command.name, allocator)
	if name_error != nil {return .Out_Of_Memory}
	title, title_error := strings.clone(command.title, allocator)
	if title_error != nil {
		delete(name, allocator)
		return .Out_Of_Memory
	}
	owned.name, owned.title = name, title
	active, active_error := make([]Shortcut, command.shortcuts.count, allocator)
	defaults, defaults_error := make([]Shortcut, command.shortcuts.count, allocator)
	if active_error != nil || defaults_error != nil {
		delete(active, allocator)
		delete(defaults, allocator)
		delete(name, allocator)
		delete(title, allocator)
		return .Out_Of_Memory
	}
	copy(active, command.shortcuts.items[:command.shortcuts.count])
	copy(defaults, active)
	owned.shortcuts, owned.defaults = {active, len(active)}, {defaults, len(defaults)}
	_, err := append(&registry.items, owned)
	if err != nil {
		delete(active, allocator)
		delete(defaults, allocator)
		delete(name, allocator)
		delete(title, allocator)
		return .Out_Of_Memory
	}
	return .None
}

find :: proc {
	find_id,
	find_name,
}

@(private, require_results)
find_id :: proc(registry: ^Registry, id: Command_Id) -> ^Command {
	for &item in registry.items {
		if item.id == id {return &item}
	}
	return nil
}

@(private, require_results)
find_name :: proc(registry: ^Registry, name: string) -> ^Command {
	for &item in registry.items {
		if item.name == name {return &item}
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
	if command == nil {return false}
	command.disabled = !enabled
	return true
}

@(private)
KEY_LABELS :: #partial [input.Key]string {
	.Unidentified           = "Unknown",
	.Backquote              = "`",
	.Backslash              = "\\",
	.Bracket_Left           = "[",
	.Bracket_Right          = "]",
	.Comma                  = ",",
	.Digit_0                = "0",
	.Digit_1                = "1",
	.Digit_2                = "2",
	.Digit_3                = "3",
	.Digit_4                = "4",
	.Digit_5                = "5",
	.Digit_6                = "6",
	.Digit_7                = "7",
	.Digit_8                = "8",
	.Digit_9                = "9",
	.Equal                  = "=",
	.Intl_Backslash         = "Intl Backslash",
	.Intl_Ro                = "Ro",
	.Intl_Yen               = "Yen",
	.Minus                  = "-",
	.Period                 = ".",
	.Quote                  = "'",
	.Semicolon              = ";",
	.Slash                  = "/",
	.Alt_Left               = "Left Alt",
	.Alt_Right              = "Right Alt",
	.Caps_Lock              = "Caps Lock",
	.Context_Menu           = "Menu",
	.Control_Left           = "Left Ctrl",
	.Control_Right          = "Right Ctrl",
	.Meta_Left              = "Left " + SUPER_LABEL,
	.Meta_Right             = "Right " + SUPER_LABEL,
	.Shift_Left             = "Left Shift",
	.Shift_Right            = "Right Shift",
	.Kana_Mode              = "Kana",
	.Non_Convert            = "NonConvert",
	.Page_Down              = "PageDown",
	.Page_Up                = "PageUp",
	.Arrow_Down             = "Down",
	.Arrow_Left             = "Left",
	.Arrow_Right            = "Right",
	.Arrow_Up               = "Up",
	.Num_Lock               = "Num Lock",
	.Numpad_0               = "Num 0",
	.Numpad_1               = "Num 1",
	.Numpad_2               = "Num 2",
	.Numpad_3               = "Num 3",
	.Numpad_4               = "Num 4",
	.Numpad_5               = "Num 5",
	.Numpad_6               = "Num 6",
	.Numpad_7               = "Num 7",
	.Numpad_8               = "Num 8",
	.Numpad_9               = "Num 9",
	.Numpad_Add             = "Num+",
	.Numpad_Backspace       = "Num Backspace",
	.Numpad_Clear           = "Num Clear",
	.Numpad_Clear_Entry     = "Num Clear Entry",
	.Numpad_Comma           = "Num ,",
	.Numpad_Decimal         = "Num .",
	.Numpad_Divide          = "Num/",
	.Numpad_Enter           = "Num Enter",
	.Numpad_Equal           = "Num=",
	.Numpad_Memory_Add      = "Num Memory+",
	.Numpad_Memory_Clear    = "Num Memory Clear",
	.Numpad_Memory_Recall   = "Num Memory Recall",
	.Numpad_Memory_Store    = "Num Memory Store",
	.Numpad_Memory_Subtract = "Num Memory-",
	.Numpad_Multiply        = "Num*",
	.Numpad_Paren_Left      = "Num (",
	.Numpad_Paren_Right     = "Num )",
	.Numpad_Subtract        = "Num-",
	.Numpad_Separator       = "Num Separator",
	.Numpad_Up              = "Num Up",
	.Numpad_Down            = "Num Down",
	.Numpad_Right           = "Num Right",
	.Numpad_Left            = "Num Left",
	.Numpad_Begin           = "Num Begin",
	.Numpad_Home            = "Num Home",
	.Numpad_End             = "Num End",
	.Numpad_Insert          = "Num Insert",
	.Numpad_Delete          = "Num Delete",
	.Numpad_Page_Up         = "Num PageUp",
	.Numpad_Page_Down       = "Num PageDown",
	.Escape                 = "Esc",
	.Fn_Lock                = "Fn Lock",
	.Print_Screen           = "PrtSc",
	.Scroll_Lock            = "Scroll Lock",
	.Browser_Back           = "Browser Back",
	.Browser_Favorites      = "Browser Favorites",
	.Browser_Forward        = "Browser Forward",
	.Browser_Home           = "Browser Home",
	.Browser_Refresh        = "Browser Refresh",
	.Browser_Search         = "Browser Search",
	.Browser_Stop           = "Browser Stop",
	.Launch_App_1           = "Launch App 1",
	.Launch_App_2           = "Launch App 2",
	.Launch_Mail            = "Mail",
	.Media_Play_Pause       = "Play/Pause",
	.Media_Select           = "Select Media",
	.Media_Stop             = "Stop Media",
	.Media_Track_Next       = "Next Track",
	.Media_Track_Previous   = "Previous Track",
	.Audio_Volume_Down      = "Volume Down",
	.Audio_Volume_Mute      = "Mute",
	.Audio_Volume_Up        = "Volume Up",
	.Wake_Up                = "Wake",
}

@(require_results)
shortcut_label :: proc(shortcut: Shortcut, out: []u8) -> (string, Error) {
	@(static, rodata)
	key_labels := KEY_LABELS
	key, known := reflect.enum_name_from_value(shortcut.key)
	if !known {
		key = "Unknown"
	} else if label := key_labels[shortcut.key]; label != "" {
		key = label
	}
	length := 0
	for modifier in ([?]input.Modifier{.Leader, .Physical, .Control, .Shift, .Alt, .Super}) {
		if modifier not_in shortcut.modifiers {continue}
		text: string
		#partial switch modifier {
		case .Control:
			text = "Ctrl+"
		case .Shift:
			text = "Shift+"
		case .Alt:
			text = "Alt+"
		case .Super:
			text = SUPER_LABEL + "+"
		case .Leader:
			text = "Leader+"
		case .Physical:
			text = "Physical+"
		}
		if len(out) - length < len(text) {return "", .Output_Too_Small}
		length += copy(out[length:], text)
	}
	if len(out) - length < len(key) {return "", .Output_Too_Small}
	length += copy(out[length:], key)
	return string(out[:length]), .None
}

// Every label fits: six modifier prefixes plus the longest key label stay well under this.
SHORTCUT_TEXT_CAP :: 128

// The separator between a set's labels and between a field's alternatives.
SHORTCUT_SEPARATOR :: ", "

// Shortcut text is total: out holds SHORTCUT_TEXT_CAP bytes, a label always fits them, so a short
// write is a programmer error and callers consume text without a failure branch of their own.
@(require_results)
shortcut_text :: proc(shortcut: Shortcut, out: []u8) -> string {
	label, err := shortcut_label(shortcut, out)
	assert(err == .None)
	return label
}

// The stored text of alternatives: each trimmed, empty ones dropped, joined by SHORTCUT_SEPARATOR.
// Allocation failure yields the empty text.
@(require_results)
shortcut_alternatives_text :: proc(alternatives: []string, allocator := context.allocator) -> string {
	builder, builder_error := strings.builder_make(allocator)
	if builder_error != nil {return ""}
	defer strings.builder_destroy(&builder)
	first := true
	for alternative in alternatives {
		text := strings.trim_space(alternative)
		if text == "" {continue}
		if !first {strings.write_string(&builder, SHORTCUT_SEPARATOR)}
		strings.write_string(&builder, text)
		first = false
	}
	text, clone_error := strings.clone(strings.to_string(builder), allocator)
	if clone_error != nil {return ""}
	return text
}

// The stored text of a set: its labels in order, joined by SHORTCUT_SEPARATOR.
@(require_results)
shortcut_set_text :: proc(set: Shortcut_Set, allocator := context.allocator) -> string {
	labels := make([]string, set.count, context.temp_allocator)
	buffer: [SHORTCUT_TEXT_CAP]u8
	for shortcut, i in set.items[:set.count] {
		label := shortcut_text(shortcut, buffer[:])
		labels[i], _ = strings.clone(label, context.temp_allocator)
	}
	return shortcut_alternatives_text(labels, allocator)
}

active_shortcuts :: proc(command: ^Command) -> []Shortcut {
	return command.shortcuts.items[:command.shortcuts.count]
}

@(require_results)
set_shortcuts :: proc(registry: ^Registry, id: Command_Id, shortcuts: []Shortcut) -> Error {
	command := find(registry, id)
	if command == nil {return .Unknown_Command}
	for shortcut in shortcuts {
		if other := find_by_shortcut(registry, shortcut); other != nil && other.id != id {
			return .Duplicate_Shortcut
		}
	}
	items := command.shortcuts.items
	if len(shortcuts) > len(items) {
		err: runtime.Allocator_Error
		items, err = make([]Shortcut, len(shortcuts), registry.items.allocator)
		if err != nil {return .Out_Of_Memory}
	}
	bindings := Shortcut_Set{items, len(shortcuts)}
	for shortcut, i in shortcuts {
		bindings.items[i] = {shortcut.key, normalized(shortcut.modifiers)}
	}
	if raw_data(items) != raw_data(command.shortcuts.items) {
		delete(command.shortcuts.items, registry.items.allocator)
	}
	command.shortcuts = bindings
	return .None
}

// Overrides replace defaults; an override that cannot apply falls back to its command's defaults, or
// leaves the command unbound when those are taken too.
@(require_results)
rebind :: proc(registry: ^Registry, overrides: []Override, errors: []Error) -> Error {
	assert(len(errors) >= len(overrides))
	for &command in registry.items {command.shortcuts.count = 0}
	for &command in registry.items {
		overridden := false
		for override in overrides {
			if override.id == command.id {
				overridden = true
				break
			}
		}
		if !overridden {
			if err := set_shortcuts(registry, command.id, command.defaults.items);
			   err != .None {return err}
		}
	}
	for override, i in overrides {
		errors[i] = set_shortcuts(registry, override.id, override.shortcuts)
		command := find(registry, override.id)
		if errors[i] == .None || command == nil {continue}
		defaults := command.defaults.items[:command.defaults.count]
		if set_shortcuts(registry, command.id, defaults) != .None {
			command.shortcuts.count = 0
		}
	}
	return .None
}

@(require_results)
parse_shortcut :: proc(text: string) -> (Shortcut, bool) {
	rest := strings.trim_space(text)
	modifiers: input.Modifiers
	for {
		plus := strings.index_byte(rest, '+')
		if plus < 0 {break}
		prefix := strings.trim_space(rest[:plus])
		modifier: input.Modifier
		recognized := true
		switch {
		case strings.equal_fold(prefix, "Ctrl"):
			modifier = .Control
		case strings.equal_fold(prefix, "Shift"):
			modifier = .Shift
		case strings.equal_fold(prefix, "Alt"):
			modifier = .Alt
		case strings.equal_fold(prefix, SUPER_LABEL):
			modifier = .Super
		case strings.equal_fold(prefix, "Leader"):
			modifier = .Leader
		case strings.equal_fold(prefix, "Physical"):
			modifier = .Physical
		case:
			recognized = false
		}
		if !recognized {break}
		if modifier in modifiers {return {}, false}
		modifiers += {modifier}
		rest = strings.trim_space(rest[plus + 1:])
	}
	buffer: [SHORTCUT_TEXT_CAP]u8
	for key in input.Key {
		label, err := shortcut_label({key, {}}, buffer[:])
		if err != .None {return {}, false}
		if strings.equal_fold(rest, label) {return {key, modifiers}, true}
	}
	return {}, false
}

@(require_results)
parse_shortcuts :: proc(text: string, out: []Shortcut) -> (int, Error) {
	rest := strings.trim_space(text)
	count := 0
	for rest != "" {
		found := false
		for end in 1 ..= len(rest) {
			if end < len(rest) && rest[end] != ',' {continue}
			shortcut, ok := parse_shortcut(rest[:end])
			if !ok {continue}
			if count == len(out) {return 0, .Output_Too_Small}
			out[count] = shortcut
			count += 1
			if end == len(rest) {return count, .None}
			rest = strings.trim_space(rest[end + 1:])
			if rest == "" {return 0, .Invalid_Shortcut}
			found = true
			break
		}
		if !found {return 0, .Invalid_Shortcut}
	}
	return count, .None
}

// The alternatives of a stored value, as display-ready labels: the canonical label of each parsed
// shortcut, or, when the value does not parse, its comma-separated parts as typed, trimmed, so the
// settings editor still shows what the field holds.
@(require_results)
shortcut_alternatives :: proc(text: string, allocator := context.allocator) -> []string {
	if strings.trim_space(text) == "" {return nil}
	storage := make([]Shortcut, len(text) + 1, context.temp_allocator)
	count, err := parse_shortcuts(text, storage)
	if err != .None {
		parts, _ := strings.split(text, ",", allocator)
		for &part in parts {part = strings.trim_space(part)}
		return parts
	}
	labels := make([]string, count, allocator)
	buffer: [SHORTCUT_TEXT_CAP]u8
	for shortcut, i in storage[:count] {
		label := shortcut_text(shortcut, buffer[:])
		labels[i], _ = strings.clone(label, allocator)
	}
	return labels
}
