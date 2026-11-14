package main

import "aio:cli_protocol"
import "aio:commands"
import "aio:events"
import "aio:scripting"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"

// The aio API's LuaCATS definitions for lua-language-server (WORK-485): scripting.META_CORE, the
// hand-written core, then what the command registry, the reply and event structs and, for
// app.lua_types, init.lua's actions describe. types/aio.lua in the repository is the built-in form,
// and a test compares it with this output, so everything comes in enum, struct or sorted order and
// nothing in a map's.

// Where META_CORE takes generated overloads: each marker line is replaced by them.
@(private = "file")
Lua_Types_Splice :: enum u8 {
	Run,
	Invoke,
	On,
	Wait,
}

@(private = "file")
LUA_TYPES_MARKERS :: [Lua_Types_Splice]string {
	.Run    = "--{{run}}",
	.Invoke = "--{{invoke}}",
	.On     = "--{{on}}",
	.Wait   = "--{{wait}}",
}

// What aio.run returns, and so every generated command function.
@(private = "file")
LUA_TYPES_RETURNS :: "aio.Reply?, string?, integer?"

// Lua's reserved words, which cannot name a field or function after a dot.
@(private = "file", rodata)
lua_types_keywords := [?]string {
	"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
	"local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}

@(private = "file")
Lua_Types :: struct {
	body:    strings.Builder,
	splices: [Lua_Types_Splice]strings.Builder,
	// The structs a field named, each written as an aio.<Name> class once, in the order first named.
	classes: [dynamic]typeid,
	written: int,
}

// The complete definition file. include_runtime adds the actions init.lua registered and names the
// build; without them the text is the same on every build, as types/aio.lua holds it.
@(require_results)
lua_types_text :: proc(app: ^App, include_runtime: bool, allocator := context.allocator) -> string {
	g := Lua_Types {
		body    = strings.builder_make(context.temp_allocator),
		classes = make([dynamic]typeid, context.temp_allocator),
	}
	for &splice in g.splices {splice = strings.builder_make(context.temp_allocator)}
	lua_types_reply(&g)
	lua_types_events(&g)
	lua_types_commands(&g, app)
	if include_runtime {lua_types_actions(&g, app)}
	out := strings.builder_make(allocator)
	strings.write_string(&out, "---@meta\n")
	if include_runtime {
		fmt.sbprintf(&out, "-- The aio API for lua-language-server: AIODev build %s, ", cli_protocol.BUILD_ID)
		strings.write_string(&out, "with the actions init.lua declared.\n")
	} else {
		strings.write_string(&out, "-- The aio API for lua-language-server: AIODev's commands, events and ")
		strings.write_string(&out, "replies.\n")
	}
	strings.write_string(&out, "-- Generated: regenerate it with `aio types` rather than editing it.\n\n")
	markers := LUA_TYPES_MARKERS
	core := scripting.META_CORE
	lines: for line in strings.split_lines_iterator(&core) {
		// A checkout that converted line endings must not change the text.
		text := strings.trim_right(line, "\r")
		for marker, splice in markers {
			if text != marker {continue}
			strings.write_string(&out, strings.to_string(g.splices[splice]))
			continue lines
		}
		strings.write_string(&out, text)
		strings.write_byte(&out, '\n')
	}
	strings.write_string(&out, strings.to_string(g.body))
	return strings.to_string(out)
}

// aiodev --lua-types <path>: writes the built-in definitions, as types/aio.lua holds them, without
// starting the app. Returns the process exit code.
@(require_results)
lua_types_write :: proc(path: string) -> int {
	app: App
	app.registry = commands.create()
	defer commands.destroy(&app.registry)
	if err := register_actions(&app.registry); err != .None {
		fmt.eprintln("Registering commands failed:", err)
		return 1
	}
	if err := os.write_entire_file(path, lua_types_text(&app, false, context.temp_allocator)); err != nil {
		fmt.eprintln("Writing", path, "failed:", err)
		return 1
	}
	return 0
}

// aio.Reply from cli_protocol.Reply_Json, without the ok, status and error aio.run removes.
@(private = "file")
lua_types_reply :: proc(g: ^Lua_Types) {
	b := &g.body
	lua_types_section(b, "Replies")
	strings.write_string(b, "\n---A command's reply: the fields the command filled. aio.run removes ok, status ")
	strings.write_string(b, "and error.\n---@class aio.Reply\n")
	skipped := [?]string{"ok", "status", "error"}
	lua_types_fields(g, cli_protocol.Reply_Json, skipped[:])
	lua_types_classes(g)
}

// Writes the classes named since the last call, and those they name in turn.
@(private = "file")
lua_types_classes :: proc(g: ^Lua_Types) {
	for g.written < len(g.classes) {
		id := g.classes[g.written]
		g.written += 1
		strings.write_string(&g.body, "\n---@class ")
		lua_types_class_name(&g.body, "aio.", type_info_of(id).variant.(runtime.Type_Info_Named).name)
		strings.write_byte(&g.body, '\n')
		lua_types_fields(g, id, nil)
	}
}

// A class name: prefix, then an Odin type or enum name without its underscores, so Pane_Report is
// aio.PaneReport.
@(private = "file")
lua_types_class_name :: proc(b: ^strings.Builder, prefix, name: string) {
	strings.write_string(b, prefix)
	for c in transmute([]u8)name {
		if c != '_' {strings.write_byte(b, c)}
	}
}

// A comment line that opens a part of the file, ruled out to a fixed width.
@(private = "file")
lua_types_section :: proc(b: ^strings.Builder, title: string) {
	fmt.sbprintf(b, "\n-- %s ", title)
	for _ in len(title) + 4 ..< 96 {strings.write_byte(b, '-')}
	strings.write_byte(b, '\n')
}

// One field line per struct field the JSON carries, under the name the JSON gives it.
@(private = "file")
lua_types_fields :: proc(g: ^Lua_Types, id: typeid, skipped: []string) {
	b := &g.body
	for field in reflect.struct_fields_zipped(id) {
		key, _, options := strings.partition(reflect.struct_tag_get(field.tag, "json"), ",")
		if key == "-" {continue}
		if key == "" {key = field.name}
		if slice.contains(skipped, key) {continue}
		optional := lua_types_optional(field.type, strings.contains(options, "omitempty"))
		fmt.sbprintf(b, "---@field %s%s ", key, optional ? "?" : "")
		lua_types_type(g, field.type)
		strings.write_byte(b, '\n')
	}
}

// A field Lua may find nil: a Maybe, which marshals as null when empty, or one omitempty leaves out.
// json.marshal's omitempty drops only empty text, lists and maps and nil unions and pointers.
@(private = "file", require_results)
lua_types_optional :: proc(info: ^runtime.Type_Info, omitempty: bool) -> bool {
	#partial switch _ in runtime.type_info_base(info).variant {
	case runtime.Type_Info_Union:
		return true
	case runtime.Type_Info_String,
	     runtime.Type_Info_Slice,
	     runtime.Type_Info_Dynamic_Array,
	     runtime.Type_Info_Map,
	     runtime.Type_Info_Pointer:
		return omitempty
	}
	return false
}

// A JSON value's Lua type. Named structs become classes; a Maybe is its value's type, and any other
// union, such as json.Value, is any.
@(private = "file")
lua_types_type :: proc(g: ^Lua_Types, info: ^runtime.Type_Info) {
	b := &g.body
	if named, is_named := info.variant.(runtime.Type_Info_Named); is_named {
		if _, is_struct := named.base.variant.(runtime.Type_Info_Struct); is_struct {
			lua_types_class_name(b, "aio.", named.name)
			if !slice.contains(g.classes[:], info.id) {append(&g.classes, info.id)}
			return
		}
	}
	// Replies and events hold only these kinds; anything else would still read as any.
	#partial switch variant in runtime.type_info_base(info).variant {
	case runtime.Type_Info_Boolean:
		strings.write_string(b, "boolean")
	case runtime.Type_Info_Integer:
		strings.write_string(b, "integer")
	case runtime.Type_Info_Float:
		strings.write_string(b, "number")
	case runtime.Type_Info_String:
		strings.write_string(b, "string")
	case runtime.Type_Info_Slice:
		lua_types_type(g, variant.elem)
		strings.write_string(b, "[]")
	case runtime.Type_Info_Array:
		lua_types_type(g, variant.elem)
		strings.write_string(b, "[]")
	case runtime.Type_Info_Dynamic_Array:
		lua_types_type(g, variant.elem)
		strings.write_string(b, "[]")
	case runtime.Type_Info_Union:
		if len(variant.variants) == 1 {
			lua_types_type(g, variant.variants[0])
		} else {
			strings.write_string(b, "any")
		}
	case:
		strings.write_string(b, "any")
	}
}

// An aio.event class per event from EVENT_FIELDS, the aio.EventName union, and the overloads that
// give aio.on's handler and aio.wait's result the event's class.
@(private = "file")
lua_types_events :: proc(g: ^Lua_Types) {
	names := events.NAMES
	fields := EVENT_FIELDS
	b := &g.body
	lua_types_section(b, "Event fields")
	strings.write_string(b, "\n---The name of an event aio.on and aio.wait take.\n---@alias aio.EventName\n")
	for name in names {fmt.sbprintf(b, "---| %q\n", name)}
	for kind in events.Kind {
		class := strings.builder_make(context.temp_allocator)
		lua_types_class_name(&class, "aio.event.", fmt.tprint(kind))
		event := strings.to_string(class)
		fmt.sbprintf(b, "\n---The fields of %s.\n---@class %s\n", names[kind], event)
		fmt.sbprintf(b, "---@field type %q\n", names[kind])
		lua_types_fields(g, fields[kind], nil)
		fmt.sbprintf(
			&g.splices[.On],
			"---@overload fun(name: %q, fn: fun(ctx: aio.Ctx, ev: %s)): fun(ctx: aio.Ctx, ev: %s)\n",
			names[kind],
			event,
			event,
		)
		fmt.sbprintf(
			&g.splices[.Wait],
			"---@overload fun(name: %q, filter?: table|fun(ev: %s): boolean, timeout?: number): %s?, string?\n",
			names[kind],
			event,
			event,
		)
	}
	lua_types_classes(g)
}

// Whether a name can follow a dot in Lua.
@(private = "file", require_results)
lua_types_identifier :: proc(name: string) -> bool {
	if name == "" || name[0] >= '0' && name[0] <= '9' {return false}
	for c in transmute([]u8)name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_') {return false}
	}
	return !slice.contains(lua_types_keywords[:], name)
}

// Every built-in command: its fields class and an aio.run overload, and `aio.<namespace>.<name>`
// where runtime.lua's namespace lookup reaches it. A namespace META_CORE makes a function, such as
// aio.view, cannot be indexed, and a helper META_CORE defines, such as aio.settings.get, wins over
// the command of that name; those commands are reached through aio.run.
@(private = "file")
lua_types_commands :: proc(g: ^Lua_Types, app: ^App) {
	@(static, rodata)
	descriptors := ACTIONS
	list := make([dynamic]^commands.Command, 0, len(app.registry.items), context.temp_allocator)
	for &command in app.registry.items {
		if !command.runtime {append(&list, &command)}
	}
	slice.sort_by(list[:], proc(a, b: ^commands.Command) -> bool {return a.name < b.name})
	b := &g.body
	lua_types_section(b, "Command functions")
	namespace := ""
	for command in list {
		action, builtin := action_builtin(command.id)
		targeted := builtin && descriptors[action].spec.control != .Unnamed
		prefix, _, name := strings.partition(command.name, ".")
		shadowed := strings.contains(scripting.META_CORE, fmt.tprintf("\nfunction aio.%s(", prefix))
		reachable := !shadowed && lua_types_identifier(prefix) && lua_types_identifier(name)
		if reachable && prefix != namespace {
			namespace = prefix
			if !strings.contains(scripting.META_CORE, fmt.tprintf("\naio.%s = ", prefix)) {
				// Not a format: fmt reads braces as a placeholder.
				fmt.sbprintf(b, "\n---The %s.* commands.\naio.%s = ", prefix, prefix)
				strings.write_string(b, "{}\n")
			}
		}
		required := lua_types_command_fields(g, command, targeted)
		optional := required ? "" : "?"
		fmt.sbprintf(
			&g.splices[.Run],
			"---@overload fun(name: %q, fields%s: aio.fields.%s): %s\n",
			command.name,
			optional,
			command.name,
			LUA_TYPES_RETURNS,
		)
		helper := fmt.tprintf("\nfunction aio.%s(", command.name)
		if !reachable || strings.contains(scripting.META_CORE, helper) {continue}
		strings.write_byte(b, '\n')
		lua_types_doc(b, command.title)
		if command.summary != "" {
			strings.write_string(b, "---\n")
			lua_types_doc(b, command.summary)
		}
		fmt.sbprintf(b, "---@param fields%s aio.fields.%s\n", optional, command.name)
		strings.write_string(b, "---@return aio.Reply? reply\n---@return string? message\n")
		strings.write_string(b, "---@return integer? status\n")
		fmt.sbprintf(b, "function aio.%s(fields) end\n", command.name)
	}
}

// A command's fields class, with the keys commands.parse_fields accepts. Returns whether a field is
// required, which makes the fields table itself required.
@(private = "file", require_results)
lua_types_command_fields :: proc(g: ^Lua_Types, command: ^commands.Command, targeted: bool) -> bool {
	types := commands.ARGUMENT_LUA_TYPES
	b := &g.body
	fmt.sbprintf(b, "\n---The fields of %s.\n---@class aio.fields.%s\n", command.name, command.name)
	if targeted {
		pane := cli_protocol.PANE_OPTION
		fmt.sbprintf(b, "---@field pane? string|integer %s; default: %s\n", pane.description, pane.default)
	}
	required := false
	for argument in commands.Argument {
		if argument not_in command.arguments {continue}
		// Text_File's key is file, which a command taking a positional file gives to that file.
		if argument == .Text_File && .File in command.arguments {continue}
		key_buffer: [128]u8
		key := commands.argument_field(argument, key_buffer[:])
		alternative, has_alternative := commands.argument_alternative(command, argument)
		needed := argument in command.required && !has_alternative
		required ||= needed
		help := commands.argument_help(command, argument)
		fmt.sbprintf(b, "---@field %s%s %s %s; ", key, needed ? "" : "?", types[argument], help.description)
		if needed {
			strings.write_string(b, "required\n")
		} else if has_alternative && argument in command.required {
			other_buffer: [128]u8
			other := commands.argument_field(alternative, other_buffer[:])
			fmt.sbprintf(b, "required unless %s is given\n", other)
		} else {
			fmt.sbprintf(b, "default: %s\n", help.default)
		}
	}
	return required
}

// For app.lua_types: an args class per action init.lua registered, and aio.run and aio.invoke
// overloads with its name. An action replaced by a later one of the same name, or one that could not
// register, has no command, so it is left out.
@(private = "file")
lua_types_actions :: proc(g: ^Lua_Types, app: ^App) {
	instance := app.lua.current
	if instance == nil {return}
	list := make([dynamic]scripting.Action_Decl, 0, len(instance.decls.actions), context.temp_allocator)
	for action, i in instance.decls.actions {
		if i < len(instance.ids) && instance.ids[i] != 0 {append(&list, action)}
	}
	if len(list) == 0 {return}
	slice.sort_by(list[:], proc(a, b: scripting.Action_Decl) -> bool {return a.name < b.name})
	lua_types_section(&g.body, "Actions init.lua declared")
	for action in list {
		class, required := lua_types_action_args(g, action)
		optional := required ? "" : "?"
		fmt.sbprintf(
			&g.splices[.Run],
			"---@overload fun(name: %q, fields%s: %s): %s\n",
			action.name,
			optional,
			class,
			LUA_TYPES_RETURNS,
		)
		fmt.sbprintf(
			&g.splices[.Invoke],
			"---@overload fun(name: %q, args%s: %s): any, string?, integer?\n",
			action.name,
			optional,
			class,
		)
	}
}

// An action's args class from its type words, and whether one is required. Without args, or with a
// JSON Schema for all of them, the action takes a plain table.
@(private = "file", require_results)
lua_types_action_args :: proc(
	g: ^Lua_Types,
	action: scripting.Action_Decl,
) -> (
	class: string,
	required: bool,
) {
	if action.args == "" {return "table", false}
	context.allocator = context.temp_allocator
	spec, spec_error := json.parse_string(action.args, .JSON, true, context.temp_allocator)
	declared, is_object := spec.(json.Object)
	if spec_error != nil || !is_object || "type" in declared {return "table", false}
	class = fmt.tprintf("aio.args.%s", action.name)
	b := &g.body
	strings.write_byte(b, '\n')
	lua_types_doc(b, action.title)
	if action.description != "" {
		strings.write_string(b, "---\n")
		lua_types_doc(b, action.description)
	}
	fmt.sbprintf(b, "---@class %s\n", class)
	names := make([dynamic]string, 0, len(declared))
	for name in declared {append(&names, name)}
	slice.sort(names[:])
	for name in names {
		// A per-argument schema is kept unchecked, so its argument may be left out.
		word, optional := "any", true
		#partial switch value in declared[name] {
		case json.String:
			word = strings.trim_suffix(value, "?")
			optional = strings.has_suffix(value, "?")
		case json.Object:
			if schema_type, is_text := value["type"].(json.String); is_text {word = schema_type}
		}
		required ||= !optional
		if lua_types_identifier(name) {
			fmt.sbprintf(b, "---@field %s%s ", name, optional ? "?" : "")
		} else {
			fmt.sbprintf(b, "---@field [%q]%s ", name, optional ? "?" : "")
		}
		strings.write_string(b, lua_types_word(word))
		strings.write_byte(b, '\n')
	}
	return class, required
}

// The Lua type of an action's type word or a schema's type.
@(private = "file", require_results)
lua_types_word :: proc(word: string) -> string {
	switch word {
	case "string", "number", "integer", "boolean":
		return word
	case "object":
		return "table"
	case "array":
		return "any[]"
	}
	return "any"
}

// Text as doc comment lines.
@(private = "file")
lua_types_doc :: proc(b: ^strings.Builder, text: string) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		strings.write_string(b, "---")
		strings.write_string(b, strings.trim_right(line, "\r"))
		strings.write_byte(b, '\n')
	}
}
