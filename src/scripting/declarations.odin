package scripting

import "core:c"
import "core:strings"
import "aio:lua"

// What a Config host's top level declared through aio.action, aio.bind, aio.unbind and aio.mode.
// args is JSON text: an object of type words (or per-argument schemas), or a whole JSON Schema when
// the Lua table had a type key; "" when absent. ref is the run function's registry reference.
Action_Decl :: struct {
	name, title, description, category, keywords, args: string,
	repeats: bool,
	ref: i32,
	file: string,
	line: int,
}

Key_Op :: enum u8 {Bind, Unbind}

// key is as written, e.g. "resize/Ctrl+B>C". command is the name target, "" for a function or an
// unbind of everything. fields is the JSON of args or "". ref is the function target, 0 for none;
// one function keeps one ref, so an unbind names the same ref as the bind it removes.
Key_Decl :: struct {
	op: Key_Op,
	key, command, fields: string,
	ref: i32,
	file: string,
	line: int,
}

Mode_Decl :: struct {
	name: string,
	exclusive: bool,
	file: string,
	line: int,
}

// keys keep declaration order, unbinds included.
Declarations :: struct {
	actions: []Action_Decl,
	keys: []Key_Decl,
	modes: []Mode_Decl,
}

// The result is valid until destroy, or until a later run records more declarations and this is
// called again. Refs stay owned by the state until ref_release or destroy.
@(require_results)
declarations :: proc(s: ^State) -> Declarations {
	L := s.L
	get_runtime(s, "declarations")
	if lua.pcall(L, 0, 4, 0) != 0 {
		record_runtime_error(s)
		return s.declared
	}
	top := lua.gettop(L)
	serial := int(lua.tointeger(L, top - 3))
	if serial != s.declared_serial {
		declarations_free(s)
		s.declared_serial = serial
		s.declared = {
			actions = read_actions(s, top - 2), keys = read_keys(s, top - 1), modes = read_modes(s, top),
		}
	}
	lua.pop(L, 4)
	return s.declared
}

// ref(fn) -> a registry reference keeping fn alive for the host.
@(private)
native_ref :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushvalue(L, 1)
	lua.pushinteger(L, lua.Integer(lua.L_ref(L, lua.REGISTRYINDEX)))
	return 1
}

// Field readers work on the table at the top of the stack.
@(private, require_results)
text_field :: proc(s: ^State, key: cstring) -> string {
	lua.getfield(s.L, -1, key)
	text := strings.clone(text_at(s.L, -1), s.allocator)
	lua.pop(s.L, 1)
	return text
}

@(private, require_results)
int_field :: proc(s: ^State, key: cstring) -> int {
	lua.getfield(s.L, -1, key)
	value := int(lua.tointeger(s.L, -1))
	lua.pop(s.L, 1)
	return value
}

@(private, require_results)
bool_field :: proc(s: ^State, key: cstring) -> bool {
	lua.getfield(s.L, -1, key)
	value := bool(lua.toboolean(s.L, -1))
	lua.pop(s.L, 1)
	return value
}

@(private, require_results)
read_actions :: proc(s: ^State, list: c.int) -> []Action_Decl {
	result := make([]Action_Decl, int(lua.objlen(s.L, list)), s.allocator)
	for &decl, i in result {
		lua.rawgeti(s.L, list, c.int(i + 1))
		decl = {
			name = text_field(s, "name"), title = text_field(s, "title"),
			description = text_field(s, "description"), category = text_field(s, "category"),
			keywords = text_field(s, "keywords"), args = text_field(s, "args"),
			repeats = bool_field(s, "repeats"), ref = i32(int_field(s, "ref")),
			file = text_field(s, "file"), line = int_field(s, "line"),
		}
		lua.pop(s.L, 1)
	}
	return result
}

@(private, require_results)
read_keys :: proc(s: ^State, list: c.int) -> []Key_Decl {
	result := make([]Key_Decl, int(lua.objlen(s.L, list)), s.allocator)
	for &decl, i in result {
		lua.rawgeti(s.L, list, c.int(i + 1))
		lua.getfield(s.L, -1, "op")
		op := text_at(s.L, -1) == "unbind" ? Key_Op.Unbind : Key_Op.Bind
		lua.pop(s.L, 1)
		decl = {
			op = op, key = text_field(s, "key"), command = text_field(s, "command"),
			fields = text_field(s, "fields"), ref = i32(int_field(s, "ref")),
			file = text_field(s, "file"), line = int_field(s, "line"),
		}
		lua.pop(s.L, 1)
	}
	return result
}

@(private, require_results)
read_modes :: proc(s: ^State, list: c.int) -> []Mode_Decl {
	result := make([]Mode_Decl, int(lua.objlen(s.L, list)), s.allocator)
	for &decl, i in result {
		lua.rawgeti(s.L, list, c.int(i + 1))
		decl = {
			name = text_field(s, "name"), exclusive = bool_field(s, "exclusive"),
			file = text_field(s, "file"), line = int_field(s, "line"),
		}
		lua.pop(s.L, 1)
	}
	return result
}

// Frees the copy declarations handed out; the refs stay in the Lua registry.
@(private)
declarations_free :: proc(s: ^State) {
	a := s.allocator
	for decl in s.declared.actions {
		texts := [?]string{
			decl.name, decl.title, decl.description, decl.category, decl.keywords, decl.args, decl.file,
		}
		for text in texts {delete(text, a)}
	}
	for decl in s.declared.keys {
		texts := [?]string{decl.key, decl.command, decl.fields, decl.file}
		for text in texts {delete(text, a)}
	}
	for decl in s.declared.modes {
		delete(decl.name, a)
		delete(decl.file, a)
	}
	delete(s.declared.actions, a)
	delete(s.declared.keys, a)
	delete(s.declared.modes, a)
	s.declared = {}
}
