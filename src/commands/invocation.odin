package commands

import "aio:layout"
import "base:runtime"
import "core:strconv"
import "core:strings"

// Where an invocation came from. Every interface runs commands through one executor; the origin
// only selects defaults that differ between interfaces (D-046).
Origin :: enum u8 {
	Key,
	Palette,
	// A menu, button or other control in the window.
	Menu,
	// The CLI's control pipe.
	Control,
}

// The outcome of an invocation, shared by every interface. The values are the CLI exit codes (D-046).
Status :: enum u8 {
	Ok          = 0,
	Failed      = 1,
	Usage       = 2,
	Target      = 3,
	Unreachable = 4,
	Interrupted = 130,
}

// The arguments a command may take beyond its target pane. A command lists the ones it accepts.
Argument :: enum u8 {
	Direction,
	Ratio,
	Focus,
	Directory,
	Name,
	Profile,
	Text,
	Enter,
	Lines,
	Program,
}
Arguments :: bit_set[Argument;u16]

// One request to run a command. Text fields borrow from the arguments they were parsed from.
Invocation :: struct {
	id:                                      Command_Id,
	origin:                                  Origin,
	// Empty means the caller's own pane, else the focused pane; also `here`, `focused`, an id or a
	// pane name.
	pane:                                    string,
	given:                                   Arguments,
	direction:                               layout.Direction,
	ratio:                                   f32,
	focus:                                   bool,
	directory, name, profile, text, program: string,
	enter:                                   bool,
	lines:                                   int,
}

Parse_Error :: struct {
	argument, advice: string,
}

// The longest pane read the grammar accepts, in rows.
MAX_LINES :: 10000

@(private, rodata)
argument_options := [Argument]string {
	.Direction = "--direction",
	.Ratio     = "--ratio",
	.Focus     = "--focus",
	.Directory = "--cwd",
	.Name      = "--name",
	.Profile   = "--profile",
	.Text      = "<text>",
	.Enter     = "--enter",
	.Lines     = "--lines",
	.Program   = "-- <program> [arguments]",
}

@(private, rodata)
argument_values := [Argument]string {
	.Direction = " left|right|up|down",
	.Ratio     = " 0.05-0.95",
	.Focus     = "",
	.Directory = " <directory>",
	.Name      = " <name>",
	.Profile   = " <id>",
	.Text      = "",
	.Enter     = "",
	.Lines     = " <rows>",
	.Program   = "",
}

// The defaults every interface starts from; key and palette invocations change nothing else.
invocation :: proc(id: Command_Id, origin: Origin) -> Invocation {
	return {id = id, origin = origin, direction = .Right, ratio = 0.5, focus = origin != .Control}
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
	result := invocation(command.id, .Control)
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
		argument: Argument
		switch option {
		case "--pane":
			if seen_pane {return {}, {option, "use --pane once"}}
			if i + 1 == len(args) || args[i + 1] == "" {return {}, {option, "name a pane after --pane"}}
			i += 1
			result.pane, seen_pane = args[i], true
			continue
		case "--direction":
			argument = .Direction
		case "--ratio":
			argument = .Ratio
		case "--focus":
			argument = .Focus
		case "--cwd":
			argument = .Directory
		case "--name":
			argument = .Name
		case "--profile":
			argument = .Profile
		case "--enter":
			argument = .Enter
		case "--lines":
			argument = .Lines
		case:
			if strings.has_prefix(option, "--") || .Text not_in command.arguments || .Text in result.given {
				return {}, {option, "unknown option; use aio help <command> for its options"}
			}
			result.text = option
			result.given += {.Text}
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
			switch value {
			case "left":
				result.direction = .Left
			case "right":
				result.direction = .Right
			case "up":
				result.direction = .Up
			case "down":
				result.direction = .Down
			case:
				return {}, {value, "choose left, right, up or down"}
			}
		case .Ratio:
			ratio, ok := strconv.parse_f32(value)
			if !ok || !(ratio >= 0.05 && ratio <= 0.95) {return {}, {value, "use a ratio from 0.05 to 0.95"}}
			result.ratio = ratio
		case .Lines:
			lines, ok := strconv.parse_int(value, 10)
			if !ok || lines < 1 || lines > MAX_LINES {return {}, {value, "use a row count from 1 to 10000"}}
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
		if argument in missing {return {}, {argument_options[argument], "supply this required argument"}}
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
		strings.write_string(&b, argument_options[argument])
		strings.write_string(&b, argument_values[argument])
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
