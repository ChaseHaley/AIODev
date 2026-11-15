package syntax_test

import "core:strings"
import "core:testing"
import "aio:syntax"

@(private="file")
lex :: proc(t: ^testing.T, lexer: syntax.Lexer, language: syntax.Language, text: string) -> []syntax.Token {
	tokens := make([dynamic]syntax.Token, context.temp_allocator)
	testing.expect(t, lexer(language, text, &tokens))
	return tokens[:]
}

// The first occurrence of `needle` is exactly one token of `kind`.
@(private="file")
expect_token :: proc(
	t: ^testing.T,
	tokens: []syntax.Token,
	text, needle: string,
	kind: syntax.Token_Kind,
	loc := #caller_location,
) {
	start := strings.index(text, needle)
	if start < 0 {
		testing.expectf(t, false, "%q is not in the text", needle, loc = loc)
		return
	}
	for token in tokens {
		if int(token.start) == start && int(token.end) == start + len(needle) {
			testing.expectf(t, token.kind == kind, "%q is %v, want %v", needle, token.kind, kind, loc = loc)
			return
		}
	}
	testing.expectf(t, false, "no token spans %q", needle, loc = loc)
}

// No token touches the first occurrence of `needle`.
@(private="file")
expect_plain :: proc(t: ^testing.T, tokens: []syntax.Token, text, needle: string, loc := #caller_location) {
	start := strings.index(text, needle)
	testing.expectf(t, start >= 0, "%q is not in the text", needle, loc = loc)
	for token in tokens {
		if int(token.start) < start + len(needle) && int(token.end) > start {
			testing.expectf(t, false, "%q overlaps a %v token", needle, token.kind, loc = loc)
			return
		}
	}
}

// Every token is non-empty, in range and after the one before it.
@(private="file")
expect_sane :: proc(
	t: ^testing.T,
	lexer: syntax.Lexer,
	language: syntax.Language,
	text: string,
	loc := #caller_location,
) -> bool {
	tokens := make([dynamic]syntax.Token, context.temp_allocator)
	if !testing.expect(t, lexer(language, text, &tokens), loc = loc) {return false}
	previous: u32 = 0
	for token in tokens {
		if token.start >= token.end || token.start < previous || int(token.end) > len(text) {
			shown := text[:min(len(text), 200)]
			testing.expectf(t, false, "%v: bad token %v in %q", language, token, shown, loc = loc)
			return false
		}
		previous = token.end
	}
	return true
}

@(test)
python_keywords_names_and_decorators :: proc(t: ^testing.T) {
	text := "@app.route(\"/\")\ndef greet(name: str, size: Size) -> None:\n\treturn True if a @ b else MAX\n"
	tokens := lex(t, syntax.lex_python, .Python, text)
	expect_token(t, tokens, text, "@app.route", .Attribute)
	expect_token(t, tokens, text, "\"/\"", .String)
	expect_token(t, tokens, text, "def", .Keyword)
	expect_token(t, tokens, text, "greet", .Function)
	expect_token(t, tokens, text, "str", .Type)
	expect_token(t, tokens, text, "Size", .Type)
	expect_token(t, tokens, text, "None", .Constant)
	expect_token(t, tokens, text, "return", .Keyword)
	expect_token(t, tokens, text, "True", .Constant)
	expect_plain(t, tokens, text, "@ b")
	expect_plain(t, tokens, text, "MAX")
}

@(test)
python_strings_numbers_and_comments :: proc(t: ^testing.T) {
	text := "x = rb'\\x00' + f\"{y}\" # note\r\nn = 0x_ff + 1_000 + 3.14e-2 + 7j + .5\r\nz = 'open\r\nw = 9\n"
	tokens := lex(t, syntax.lex_python, .Python, text)
	expect_token(t, tokens, text, "rb'\\x00'", .String)
	expect_token(t, tokens, text, "f\"{y}\"", .String)
	expect_token(t, tokens, text, "# note", .Comment)
	expect_token(t, tokens, text, "0x_ff", .Number)
	expect_token(t, tokens, text, "1_000", .Number)
	expect_token(t, tokens, text, "3.14e-2", .Number)
	expect_token(t, tokens, text, "7j", .Number)
	expect_token(t, tokens, text, ".5", .Number)
	// A one-line string left open ends with its line, before the CR.
	expect_token(t, tokens, text, "'open", .String)
	expect_token(t, tokens, text, "9", .Number)
}

@(test)
python_triple_quoted_strings_span_lines :: proc(t: ^testing.T) {
	text := "s = '''one\n'two' \"three\"\nfour''' # after\nd = \"\"\"x\\\"\"\"\"\n"
	tokens := lex(t, syntax.lex_python, .Python, text)
	expect_token(t, tokens, text, "'''one\n'two' \"three\"\nfour'''", .String)
	expect_token(t, tokens, text, "# after", .Comment)
	expect_token(t, tokens, text, "\"\"\"x\\\"\"\"\"", .String)
}

@(test)
python_crlf_lines_split_around_a_multiline_string :: proc(t: ^testing.T) {
	file, ok := syntax.highlight(.Python, "s = '''a\r\nb''' # c\r\n")
	defer syntax.file_lines_destroy(&file)
	testing.expect(t, ok)
	testing.expect_value(t, len(file.lines), 2)
	if len(file.lines) != 2 {return}
	testing.expect_value(t, file.lines[0][0], syntax.Span{start = 4, end = 8, kind = .String})
	testing.expect_value(t, file.lines[1][0], syntax.Span{start = 0, end = 4, kind = .String})
	testing.expect_value(t, file.lines[1][1], syntax.Span{start = 5, end = 8, kind = .Comment})
}

@(test)
lua_keywords_strings_and_long_brackets :: proc(t: ^testing.T) {
	text := "local function greet(x) return nil end -- tail\r\n" +
		"--[==[ a ]] b ]==] y = \"a\\\"b\" .. [[one\ntwo]] .. [=[x]]=]\n" +
		"local n <const> = 0x1F + 3.5e2 + 1"
	tokens := lex(t, syntax.lex_lua, .Lua, text)
	expect_token(t, tokens, text, "local", .Keyword)
	expect_token(t, tokens, text, "function", .Keyword)
	expect_token(t, tokens, text, "greet", .Function)
	expect_token(t, tokens, text, "nil", .Constant)
	expect_token(t, tokens, text, "-- tail", .Comment)
	expect_token(t, tokens, text, "--[==[ a ]] b ]==]", .Comment)
	expect_plain(t, tokens, text, " y = ")
	expect_token(t, tokens, text, "\"a\\\"b\"", .String)
	expect_token(t, tokens, text, "[[one\ntwo]]", .String)
	expect_token(t, tokens, text, "[=[x]]=]", .String)
	expect_token(t, tokens, text, "const", .Attribute)
	expect_token(t, tokens, text, "0x1F", .Number)
	expect_token(t, tokens, text, "3.5e2", .Number)
}

@(test)
lua_unterminated_long_comment_runs_to_the_end :: proc(t: ^testing.T) {
	text := "x = 1 --[[ open\nstill ]=]"
	tokens := lex(t, syntax.lex_lua, .Lua, text)
	expect_token(t, tokens, text, "--[[ open\nstill ]=]", .Comment)
}

@(test)
shell_keywords_strings_variables_and_comments :: proc(t: ^testing.T) {
	text := "if [ -f \"$path\" ]; then echo 'it\nok' a#b $HOME ${PATH} $1 $@; fi # real\r\n" +
		"greet() { return 42; }\nprintf $'tab\\t' \\\" true\n"
	tokens := lex(t, syntax.lex_shell, .Shell, text)
	expect_token(t, tokens, text, "if", .Keyword)
	expect_token(t, tokens, text, "\"$path\"", .String)
	expect_token(t, tokens, text, "then", .Keyword)
	expect_token(t, tokens, text, "'it\nok'", .String)
	expect_plain(t, tokens, text, "a#b")
	expect_token(t, tokens, text, "$HOME", .Attribute)
	expect_token(t, tokens, text, "${PATH}", .Attribute)
	expect_token(t, tokens, text, "$1", .Attribute)
	expect_token(t, tokens, text, "$@", .Attribute)
	expect_token(t, tokens, text, "fi", .Keyword)
	expect_token(t, tokens, text, "# real", .Comment)
	expect_token(t, tokens, text, "greet", .Function)
	expect_token(t, tokens, text, "42", .Number)
	expect_token(t, tokens, text, "$'tab\\t'", .String)
	expect_plain(t, tokens, text, "\\\"")
	expect_token(t, tokens, text, "true", .Constant)
}

@(test)
shell_heredoc_bodies_are_strings :: proc(t: ^testing.T) {
	text := "cat <<-EOF; cat <<'END'\n\thello $x # no\n\tEOF\nraw `x`\nEND\necho $((1<<2)) done\n"
	tokens := lex(t, syntax.lex_shell, .Shell, text)
	expect_token(t, tokens, text, "EOF", .String)
	expect_token(t, tokens, text, "'END'", .String)
	expect_token(t, tokens, text, "\thello $x # no\n\tEOF", .String)
	expect_token(t, tokens, text, "raw `x`\nEND", .String)
	expect_token(t, tokens, text, "2", .Number)
	expect_token(t, tokens, text, "done", .Keyword)
}

@(test)
shell_heredoc_terminator_ignores_crlf :: proc(t: ^testing.T) {
	text := "cat <<EOF\r\nbody\r\nEOF\r\nexit\r\n"
	tokens := lex(t, syntax.lex_shell, .Shell, text)
	expect_token(t, tokens, text, "body\r\nEOF", .String)
	expect_token(t, tokens, text, "exit", .Keyword)
}

@(test)
shell_unterminated_heredoc_runs_to_the_end :: proc(t: ^testing.T) {
	text := "cat <<EOF\nnever closed\n"
	tokens := lex(t, syntax.lex_shell, .Shell, text)
	expect_token(t, tokens, text, "never closed\n", .String)
}

@(test)
shell_here_string_is_not_a_heredoc :: proc(t: ^testing.T) {
	text := "cat <<< \"$x\" <<<word\nnext line\ntr a b <<<EOF\nbody\nEOF\n"
	tokens := lex(t, syntax.lex_shell, .Shell, text)
	expect_token(t, tokens, text, "\"$x\"", .String)
	expect_plain(t, tokens, text, "word")
	expect_plain(t, tokens, text, "next line")
	expect_plain(t, tokens, text, "body")
}

@(test)
powershell_keywords_types_variables_and_operators :: proc(t: ^testing.T) {
	text := "[CmdletBinding()]\nfunction Get-Thing { param([string[]]$Name) " +
		"IF ($Name -eq $null -and $env:PATH) { Write-Host -Path 10kb 0xFF; return } } # done\r\n$a[7]"
	tokens := lex(t, syntax.lex_powershell, .PowerShell, text)
	expect_token(t, tokens, text, "CmdletBinding", .Attribute)
	expect_token(t, tokens, text, "function", .Keyword)
	expect_token(t, tokens, text, "Get-Thing", .Function)
	expect_token(t, tokens, text, "param", .Keyword)
	expect_token(t, tokens, text, "string", .Type)
	expect_token(t, tokens, text, "$Name", .Attribute)
	expect_token(t, tokens, text, "IF", .Keyword)
	expect_token(t, tokens, text, "-eq", .Operator)
	expect_token(t, tokens, text, "$null", .Constant)
	expect_token(t, tokens, text, "-and", .Operator)
	expect_token(t, tokens, text, "$env:PATH", .Attribute)
	expect_token(t, tokens, text, "Write-Host", .Function)
	expect_plain(t, tokens, text, "-Path")
	expect_token(t, tokens, text, "10kb", .Number)
	expect_token(t, tokens, text, "0xFF", .Number)
	expect_token(t, tokens, text, "return", .Keyword)
	expect_token(t, tokens, text, "# done", .Comment)
	expect_token(t, tokens, text, "$a", .Attribute)
	expect_token(t, tokens, text, "7", .Number)
}

@(test)
powershell_strings_here_strings_and_block_comments :: proc(t: ^testing.T) {
	text := "<# block\r\ncomment #>\n$s = @\"\nline \"q\" $x\n\"@\n$t = 'it''s' + \"a`\"b\"\n" +
		"$u = @'\nraw\n'@ # after\n@{ k = 1 }"
	tokens := lex(t, syntax.lex_powershell, .PowerShell, text)
	expect_token(t, tokens, text, "<# block\r\ncomment #>", .Comment)
	expect_token(t, tokens, text, "@\"\nline \"q\" $x\n\"@", .String)
	expect_token(t, tokens, text, "'it'", .String)
	expect_token(t, tokens, text, "'s'", .String)
	expect_token(t, tokens, text, "\"a`\"b\"", .String)
	expect_token(t, tokens, text, "@'\nraw\n'@", .String)
	expect_token(t, tokens, text, "# after", .Comment)
	expect_token(t, tokens, text, "1", .Number)
}

@(test)
script_lexers_survive_random_and_truncated_input :: proc(t: ^testing.T) {
	Case :: struct {
		language: syntax.Language,
		lexer:    syntax.Lexer,
		sample:   string,
	}
	cases := [?]Case {
		{.Python, syntax.lex_python, "@d\ndef f(x='''a\\'''', y=r\"\\\"\"): return 0x1F # c\n"},
		{.Lua, syntax.lex_lua, "--[==[ c ]==] s = [[a]] .. 'b\\'' -- d\nlocal x <close> = 1"},
		{.Shell, syntax.lex_shell, "cat <<-'EOF' <<X\n\ta\n\tEOF\nb\nX\necho \"$(x)\" ${y} $'z' # c\n"},
		{.PowerShell, syntax.lex_powershell, "<# c #> $a = @\"\nx\n\"@; [int]$b -eq 'q''r' # d\n"},
	}
	alphabet := "\"'`#<>!-[]{}()=:;,.$@*&|/\\\n\r \t0123456789aZx_EOFrb~%+\x80\xff"
	state: u64 = 0x9e3779b97f4a7c15
	buffer: [256]u8
	for c in cases {
		for k in 0 ..= len(c.sample) {
			if !expect_sane(t, c.lexer, c.language, c.sample[:k]) {return}
		}
		for _ in 0 ..< 400 {
			state ~= state << 13
			state ~= state >> 7
			state ~= state << 17
			length := int(state % u64(len(buffer)))
			for i in 0 ..< length {
				state ~= state << 13
				state ~= state >> 7
				state ~= state << 17
				buffer[i] = alphabet[state % u64(len(alphabet))]
			}
			if !expect_sane(t, c.lexer, c.language, string(buffer[:length])) {return}
			free_all(context.temp_allocator)
		}
	}
}

@(test)
script_lexers_stay_linear_on_repeated_bytes :: proc(t: ^testing.T) {
	patterns := []string {
		"<", "$", "[", "`", "\"", "'", "#", "-", "@", "{", "(", "=", "\\", " ", "\n", "a", "0", ".", "<<<x ",
		"<< ", "<<'", "<<-", "${", "$'", "@\"", "@' ", "--[", "[=", "-a", "[a", "<#", "a-", "a(", "\"\\",
	}
	text := make([]u8, 256 * 1024)
	defer delete(text)
	Case :: struct {
		language: syntax.Language,
		lexer:    syntax.Lexer,
	}
	lexers := [?]Case {
		{.Python, syntax.lex_python},
		{.Lua, syntax.lex_lua},
		{.Shell, syntax.lex_shell},
		{.PowerShell, syntax.lex_powershell},
	}
	for l in lexers {
		for pattern in patterns {
			for i in 0 ..< len(text) {text[i] = pattern[i % len(pattern)]}
			if !expect_sane(t, l.lexer, l.language, string(text)) {return}
			free_all(context.temp_allocator)
		}
	}
}
