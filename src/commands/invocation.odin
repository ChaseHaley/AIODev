package commands

import "aio:layout"
import "base:runtime"
import "core:fmt"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// The arguments a command may take beyond its target pane. A command lists the ones it accepts.
// Directory and File name paths; the requester's working directory resolves a relative one.
Argument :: enum u8 {
	Direction,
	Ratio,
	Focus,
	Directory,
	Name,
	Profile,
	Text,
	File,
	Enter,
	Lines,
	Program,
}
Arguments :: bit_set[Argument;u16]

// One request to run a command. Text fields borrow from the arguments they were parsed from.
Invocation :: struct {
	id:                                      Command_Id,
	// Empty means the caller's own pane, else the focused pane; also `here`, `focused`, an id or a
	// pane name.
	pane:                                    string,
	given:                                   Arguments,
	direction:                               layout.Direction,
	ratio:                                   f32,
	focus:                                   bool,
	directory, name, profile, text, program: string,
	file:                                    string,
	enter:                                   bool,
	lines:                                   int,
}

Parse_Error :: struct {
	argument, advice: string,
}

// The longest pane read the grammar accepts, in rows.
MAX_LINES :: 10000

// The interactive split defaults; CLI requests explicitly start without focus.
SPLIT_DEFAULT :: Invocation{direction = .Right, ratio = 0.5, focus = true}

// The words that name a direction.
DIRECTION_WORDS :: [layout.Direction]string {
	.Left  = "left",
	.Right = "right",
	.Up    = "up",
	.Down  = "down",
}

// What help says about an argument: what it does, what a command does without it, and one use of it.
Argument_Help :: struct {
	description, default, example: string,
}

// A command's own help for an argument whose shared help does not fit it; empty fields keep the
// shared wording.
Argument_Note :: struct {
	argument: Argument,
	help:     Argument_Help,
}

// How each argument is written: the option naming it, empty for the positional text and program, and
// what usage shows after that option; then its help, worded to hold for every command that takes it.
@(private, rodata)
argument_grammar := [Argument]struct {
	option, usage: string,
	help:          Argument_Help,
} {
	.Direction = {
		"--direction", " left|right|up|down",
		{"the side of the pane the new pane opens on", "right", "--direction down"},
	},
	// This range and parse's message spell layout's split share, and help spells the defaults; the
	// asserts below hold them together.
	.Ratio     = {
		"--ratio", " 0.05-0.95",
		{
			"the new pane's share of the split pane's width (left, right) or height (up, down)",
			"0.5 (half)",
			"--ratio 0.3",
		},
	},
	.Focus     = {"--focus", "", {"moves focus to the new pane", "off (focus stays where it is)", "--focus"}},
	// Where a new pane starts, unless a command's note says otherwise.
	.Directory = {
		"--cwd", " <directory>",
		{
			"the directory the new pane starts in (a relative path is from aio's working directory)",
			"the shell profile's directory (home, ~, unless the profile sets one)",
			`--cwd C:\src\app`,
		},
	},
	.Name      = {
		"--name", " <name>",
		{
			"names the new pane, not its tab (--pane then accepts the name)",
			"none (the pane shows its program's title)",
			"--name build",
		},
	},
	.Profile   = {
		"--profile", " <id>",
		{
			"the shell profile the new pane runs, by id",
			"the default profile (shell.default_profile)",
			"--profile pwsh",
		},
	},
	.Text      = {"", "<text>", {"the command's text", "none", `"hello"`}},
	.File      = {
		"", "<file>",
		{
			"the file to open (a relative path is from aio's working directory)",
			"none (required)",
			"README.md",
		},
	},
	.Enter     = {"--enter", "", {"presses Enter after the text", "off", "--enter"}},
	.Lines     = {
		"--lines", " <rows>",
		{"prints only the screen's last rows, 1 to 10000", "every visible row", "--lines 20"},
	},
	.Program   = {
		"", "-- <program> [arguments]",
		{
			"runs this program in the new pane instead of the profile's shell (only .exe names resolve: " +
			"run .cmd and .ps1 through a shell)",
			"the profile's shell",
			"-- pwsh -NoLogo",
		},
	},
}
#assert(layout.SPLIT_SHARE_MIN == 0.05 && layout.SPLIT_SHARE_MAX == 0.95)
#assert(SPLIT_DEFAULT.direction == .Right && SPLIT_DEFAULT.ratio == 0.5)
#assert(MAX_LINES == 10000)

// The defaults every interface starts from: a new pane splits right, taking half the space. `focus`
// says whether a pane a command creates takes focus: interactive commands always focus it, a CLI
// request only when it passes --focus (D-046).
invocation :: proc(id: Command_Id, focus: bool) -> Invocation {
	return {id = id, direction = SPLIT_DEFAULT.direction, ratio = SPLIT_DEFAULT.ratio, focus = focus}
}

// A direction word, such as `left`.
@(require_results)
parse_direction :: proc(word: string) -> (layout.Direction, bool) {
	@(static, rodata)
	words := DIRECTION_WORDS
	for spelling, direction in words {
		if spelling == word {return direction, true}
	}
	return {}, false
}

// A split's share for the new pane, within layout's split share range.
@(require_results)
parse_ratio :: proc(text: string) -> (f32, bool) {
	ratio, ok := strconv.parse_f32(text)
	if !ok || !(ratio >= layout.SPLIT_SHARE_MIN && ratio <= layout.SPLIT_SHARE_MAX) {return 0, false}
	return ratio, true
}

// The argument an option names, such as Directory for --cwd.
@(private, require_results)
option_argument :: proc(option: string) -> (Argument, bool) {
	for grammar, argument in argument_grammar {
		if grammar.option != "" && grammar.option == option {return argument, true}
	}
	return {}, false
}

// Where an invocation keeps a path argument; nil for an argument that names no path.
@(private)
argument_path :: proc(invocation: ^Invocation, argument: Argument) -> ^string {
	#partial switch argument {
	case .Directory:
		return &invocation.directory
	case .File:
		return &invocation.file
	}
	return nil
}

// Makes the given path arguments absolute against `directory`, the working directory of whoever
// sent the command line; an empty directory leaves them as given. Joined paths use allocator.
@(require_results)
invocation_paths_resolve :: proc(
	invocation: ^Invocation,
	directory: string,
	allocator := context.allocator,
) -> runtime.Allocator_Error {
	if directory == "" {return nil}
	for argument in invocation.given {
		path := argument_path(invocation, argument)
		if path == nil || filepath.is_abs(path^) {continue}
		path^ = filepath.join({directory, path^}, allocator) or_return
	}
	return nil
}

// How a diagnostic names an argument: its option, or its positional form.
@(private)
argument_name :: proc(argument: Argument) -> string {
	grammar := argument_grammar[argument]
	return grammar.option != "" ? grammar.option : grammar.usage
}

// Writes how usage shows an argument, such as `--ratio 0.05-0.95`.
argument_write :: proc(b: ^strings.Builder, argument: Argument) {
	strings.write_string(b, argument_grammar[argument].option)
	strings.write_string(b, argument_grammar[argument].usage)
}

// The help for one of the command's arguments: the command's own note over the shared wording.
@(require_results)
argument_help :: proc(command: ^Command, argument: Argument) -> Argument_Help {
	help := argument_grammar[argument].help
	for note in command.notes {
		if note.argument != argument {continue}
		if note.help.description != "" {help.description = note.help.description}
		if note.help.default != "" {help.default = note.help.default}
		if note.help.example != "" {help.example = note.help.example}
	}
	return help
}

// Parses `name [options] [text] [-- program arguments]` against the command's accepted arguments.
// Text fields borrow from args; the program line is allocated with allocator.
@(require_results)
parse_invocation :: proc(
	registry: ^Registry,
	args: []string,
	allocator := context.allocator,
) -> (
	Invocation,
	Parse_Error,
) {
	if len(args) == 0 || args[0] == "" {return {}, {"<command>", "name a command; use aio commands"}}
	command := find(registry, args[0])
	if command == nil {return {}, {args[0], "unknown command; use aio commands"}}
	result := invocation(command.id, focus = false)
	seen_pane := false
	for i := 1; i < len(args); i += 1 {
		option := args[i]
		if option == "--" {
			if .Program not_in command.arguments {return {}, {option, "this command runs no program"}}
			if i + 1 == len(args) {return {}, {option, "name a program after --"}}
			line, err := command_line_join(args[i + 1:], allocator)
			if err != nil {return {}, {option, "not enough memory for the program line"}}
			result.program = line
			result.given += {.Program}
			break
		}
		if option == "--pane" {
			if seen_pane {return {}, {option, "use --pane once"}}
			if i + 1 == len(args) || args[i + 1] == "" {return {}, {option, "name a pane after --pane"}}
			i += 1
			result.pane, seen_pane = args[i], true
			continue
		}
		argument, named := option_argument(option)
		if !named {
			// The positional argument: text, or a file for a command that takes one.
			positional := .File in command.arguments ? Argument.File : Argument.Text
			if strings.has_prefix(option, "--") || positional not_in command.arguments ||
			   positional in result.given {
				return {}, {option, "unknown option; use aio help <command> for its options"}
			}
			if positional == .File {result.file = option} else {result.text = option}
			result.given += {positional}
			continue
		}
		if argument not_in command.arguments {
			return {}, {option, "this command does not take that option; use aio help <command>"}
		}
		if argument in result.given {return {}, {option, "use this option once"}}
		result.given += {argument}
		if argument == .Focus || argument == .Enter {
			if argument == .Focus {result.focus = true} else {result.enter = true}
			continue
		}
		if i + 1 == len(args) {return {}, {option, "supply a value after this option"}}
		i += 1
		value := args[i]
		#partial switch argument {
		case .Direction:
			direction, valid := parse_direction(value)
			if !valid {return {}, {value, "choose left, right, up or down"}}
			result.direction = direction
		case .Ratio:
			ratio, valid := parse_ratio(value)
			if !valid {return {}, {value, "use a ratio from 0.05 to 0.95"}}
			result.ratio = ratio
		case .Lines:
			lines, ok := strconv.parse_int(value, 10)
			if !ok || lines < 1 || lines > MAX_LINES {
				return {}, {value, fmt.tprintf("use a row count from 1 to %d", MAX_LINES)}
			}
			result.lines = lines
		case .Directory, .Name, .Profile:
			if value == "" {return {}, {option, "supply a nonempty value"}}
			#partial switch argument {
			case .Directory:
				result.directory = value
			case .Name:
				result.name = value
			case:
				result.profile = value
			}
		}
	}
	missing := command.required - result.given
	for argument in Argument {
		if argument in missing {return {}, {argument_name(argument), "supply this required argument"}}
	}
	return result, {}
}

// The command's grammar on one line, such as `pane.send [--pane <pane>] [--enter] <text>`.
@(require_results)
usage :: proc(command: ^Command, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, command.name)
	strings.write_string(&b, " [--pane <pane>]")
	for argument in Argument {
		if argument not_in command.arguments {continue}
		required := argument in command.required
		strings.write_string(&b, required ? " " : " [")
		argument_write(&b, argument)
		if !required {strings.write_byte(&b, ']')}
	}
	return strings.to_string(b)
}

// Joins arguments into one Windows command line that CommandLineToArgvW splits back unchanged.
@(require_results)
command_line_join :: proc(
	args: []string,
	allocator := context.allocator,
) -> (
	string,
	runtime.Allocator_Error,
) {
	b, err := strings.builder_make(allocator)
	if err != nil {return "", err}
	for arg, index in args {
		if index > 0 {strings.write_byte(&b, ' ')}
		if arg != "" && !strings.contains_any(arg, " \t\n\v\"") {
			strings.write_string(&b, arg)
			continue
		}
		strings.write_byte(&b, '"')
		backslashes := 0
		for i in 0 ..< len(arg) {
			c := arg[i]
			if c == '\\' {
				backslashes += 1
				continue
			}
			// Backslashes double only before a quote, which itself gains one.
			count := c == '"' ? 2 * backslashes + 1 : backslashes
			for _ in 0 ..< count {strings.write_byte(&b, '\\')}
			strings.write_byte(&b, c)
			backslashes = 0
		}
		for _ in 0 ..< 2 * backslashes {strings.write_byte(&b, '\\')}
		strings.write_byte(&b, '"')
	}
	return strings.to_string(b), nil
}
