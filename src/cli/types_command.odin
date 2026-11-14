package cli

import "core:fmt"
import "core:os"
import "core:path/filepath"

// `aio types`: the parts that need no running AIODev, so tests reach them. types_command_windows.odin
// asks AIODev for the definitions over the pipe.

// The hidden command that answers with the complete definition file, the user's actions included.
LUA_TYPES_COMMAND :: "app.lua_types"
// Where the definitions go beside init.lua, and where the packaged built-ins sit beside aio.exe.
TYPES_FOLDER :: "types"
TYPES_FILE :: "aio.lua"
LUARC_FILE :: ".luarc.json"
// What aio types writes to .luarc.json: lua-language-server reads the definitions from types.
LUARC_TEXT :: `{
  "runtime.version": "LuaJIT",
  "workspace.library": ["types"]
}
`
// The hint for a .luarc.json aio types keeps.
LUARC_SETTINGS :: `"runtime.version": "LuaJIT", "workspace.library": ["types"]`
// The suffix of the file a write goes through before it replaces its target.
@(private)
TEMP_SUFFIX :: ".tmp"

Lua_Types :: struct {
	// The data folder of the instance whose init.lua folder receives the definitions; "" for the
	// default instance or --instance.
	data_dir: string,
	// Replaces an existing .luarc.json too.
	force:    bool,
}

// What became of .luarc.json.
Luarc_State :: enum u8 {
	Created,
	Replaced,
	Kept,
}

@(rodata)
LUARC_STATE_WORDS := [Luarc_State]string {
	.Created  = "created",
	.Replaced = "replaced",
	.Kept     = "kept",
}

Types_Written :: struct {
	// The definition file, <folder>\types\aio.lua.
	path:  string,
	// <folder>\.luarc.json and what became of it.
	luarc: string,
	state: Luarc_State,
}

// Reads types' options, which may come in any order after the command. --json may follow it too.
// Strings borrow from o.args.
@(require_results)
types_options :: proc(o: Options) -> (Options, string) {
	o := o
	o.typing = true
	for j := 1; j < len(o.args); j += 1 {
		switch o.args[j] {
		case "--data-dir":
			if o.lua_types.data_dir != "" || j + 1 == len(o.args) || o.args[j + 1] == "" {
				return {}, "use --data-dir once with a directory"
			}
			j += 1
			o.lua_types.data_dir = o.args[j]
		case "--force":
			if o.lua_types.force {return {}, "use --force once"}
			o.lua_types.force = true
		case "--json":
			if o.json {return {}, "use --json once"}
			o.json = true
		case:
			return {}, "types takes --data-dir and --force"
		}
	}
	return o, ""
}

// The packaged built-in definitions, types\aio.lua in `directory`, the folder holding aio.exe; false
// when the file is missing or unreadable.
@(require_results)
types_builtins :: proc(directory: string, allocator := context.allocator) -> (string, bool) {
	parts := [3]string{directory, TYPES_FOLDER, TYPES_FILE}
	path, join_error := filepath.join(parts[:], context.temp_allocator)
	if join_error != nil {return "", false}
	data, err := os.read_entire_file(path, allocator)
	if err != nil {return "", false}
	return string(data), true
}

// Writes the definitions to <folder>\types\aio.lua, creating the folders, and .luarc.json beside it
// when none exists or `force` is set. Each file goes through a temporary file and a rename, so an
// editor never reads half of it. On failure the problem says what failed.
@(require_results)
types_write :: proc(
	folder, text: string,
	force: bool,
	allocator := context.allocator,
) -> (
	written: Types_Written,
	problem: string,
) {
	types_parts := [2]string{folder, TYPES_FOLDER}
	types_folder, types_error := filepath.join(types_parts[:], allocator)
	if types_error != nil {return {}, "not enough memory for the types path"}
	file_parts := [2]string{types_folder, TYPES_FILE}
	path, path_error := filepath.join(file_parts[:], allocator)
	if path_error != nil {return {}, "not enough memory for the types path"}
	luarc_parts := [2]string{folder, LUARC_FILE}
	luarc, luarc_error := filepath.join(luarc_parts[:], allocator)
	if luarc_error != nil {return {}, "not enough memory for the .luarc.json path"}
	written.path = path
	written.luarc = luarc
	if err := os.make_directory_all(types_folder); err != nil {
		return {}, fmt.aprintf("could not create %s", types_folder, allocator = allocator)
	}
	if !file_replace(path, text) {return {}, fmt.aprintf("could not write %s", path, allocator = allocator)}
	exists := os.exists(luarc)
	if exists && !force {
		written.state = .Kept
		return
	}
	if !file_replace(luarc, LUARC_TEXT) {
		return {}, fmt.aprintf("could not write %s", luarc, allocator = allocator)
	}
	written.state = exists ? .Replaced : .Created
	return
}

// Writes `text` to path + TEMP_SUFFIX, then renames it over `path`; the temporary file is gone either way.
@(private, require_results)
file_replace :: proc(path, text: string) -> bool {
	temp := fmt.tprintf("%s%s", path, TEMP_SUFFIX)
	if os.write_entire_file(temp, text) != nil || os.rename(temp, path) != nil {
		os.remove(temp)
		return false
	}
	return true
}
