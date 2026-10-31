package control

import "base:runtime"
import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

MAX_MESSAGE :: 4 * 1024 * 1024
// Real requests use fewer than ten arguments. Capping the decoded array keeps a
// small line from expanding into a large allocation before parsing.
MAX_ARGUMENTS :: 64
Wake :: struct {
	procedure: proc(user: rawptr),
	user:      rawptr,
}
// `status` carries a CLI exit status (commands.Status); zero is left off the wire, so verification
// replies keep their two-key form.
Response :: struct {
	ok:     bool,
	text:   string,
	status: u8,
}

@(private)
valid_pipe_name :: proc(name: string) -> bool {
	return(
		strings.has_prefix(name, `\\.\pipe\`) &&
		len(name) > len(`\\.\pipe\`) &&
		!strings.contains(name, "\x00") &&
		utf8.valid_string(name) \
	)
}
Message :: struct {
	id:          u64,
	args:        []string,
	request:     Request,
	parse_error: Parse_Error,
	allocator:   runtime.Allocator,
}

message_destroy :: proc(m: ^Message) {
	if m == nil {return}
	request_destroy(&m.request)
	for arg in m.args {
		delete(arg, m.allocator)
	}
	delete(m.args, m.allocator)
	free(m, m.allocator)
}

// The verification channel's pipe; only verify builds serve it.
@(require_results)
pipe_name :: proc(app_id: string, allocator := context.allocator) -> (string, Error) {
	return instance_pipe_name(app_id, ".control", allocator)
}

// The CLI's pipe, served while the control.enabled setting is on.
@(require_results)
cli_pipe_name :: proc(app_id: string, allocator := context.allocator) -> (string, Error) {
	return instance_pipe_name(app_id, ".cli", allocator)
}

@(private, require_results)
instance_pipe_name :: proc(app_id, suffix: string, allocator: runtime.Allocator) -> (string, Error) {
	if app_id == "" || strings.contains_any(app_id, "\\/\x00") || !utf8.valid_string(app_id) {
		return "", .Invalid_Argument
	}
	s, err := strings.concatenate({`\\.\pipe\`, app_id, suffix}, allocator)
	if err != nil {return "", .Out_Of_Memory}
	return s, .None
}

// A raw server hands requests over unparsed, for callers with their own grammar.
@(private, require_results)
decode_request :: proc(data: []u8, raw: bool, allocator := context.allocator) -> (^Message, Error) {
	if len(data) > MAX_MESSAGE {return nil, .Protocol}
	text := strings.trim_space(string(data))
	if len(text) == 0 || text[0] != '[' {return nil, .Protocol}
	tokens := json.make_tokenizer(text, .JSON)
	opening, opening_error := json.get_token(&tokens)
	if opening_error != nil || opening.kind != .Open_Bracket {return nil, .Protocol}
	allow_end := true
	arguments := 0
	for {
		token, token_error := json.get_token(&tokens)
		if token_error != nil {return nil, .Protocol}
		if token.kind == .Close_Bracket && allow_end {
			break
		}
		if token.kind != .String {return nil, .Protocol}
		arguments += 1
		if arguments > MAX_ARGUMENTS {return nil, .Protocol}
		separator, separator_error := json.get_token(&tokens)
		if separator_error != nil {return nil, .Protocol}
		if separator.kind == .Close_Bracket {
			break
		}
		if separator.kind != .Comma {return nil, .Protocol}
		allow_end = false
	}
	ending, ending_error := json.get_token(&tokens)
	if (ending_error != nil && ending_error != .EOF) || ending.kind != .EOF {return nil, .Protocol}
	m, err := new(Message, allocator)
	if err != nil {return nil, .Out_Of_Memory}
	m.allocator = allocator
	if decode_error := json.unmarshal(data, &m.args, .JSON, allocator); decode_error != nil {
		message_destroy(m)
		if cause, ok := decode_error.(json.Error); ok && cause == .Out_Of_Memory {
			return nil, .Out_Of_Memory
		}
		return nil, .Protocol
	}
	for arg in m.args {
		if !utf8.valid_string(arg) {
			message_destroy(m)
			return nil, .Protocol
		}
	}
	if !raw {m.request, m.parse_error = parse(m.args, allocator)}
	return m, .None
}

@(private, require_results)
encode_response :: proc(response: Response, allocator := context.allocator) -> ([]u8, Error) {
	if response.status == 0 {
		Plain :: struct {
			ok:   bool,
			text: string,
		}
		return encode(Plain{response.ok, response.text}, allocator)
	}
	return encode(response, allocator)
}

@(private, require_results)
encode :: proc(value: any, allocator := context.allocator) -> ([]u8, Error) {
	data, err := json.marshal(value, {}, allocator)
	if err != nil {
		delete(data, allocator)
		return nil, .Out_Of_Memory
	}
	if len(data) > MAX_MESSAGE {
		delete(data, allocator)
		return nil, .Protocol
	}
	return data, .None
}

@(private, require_results)
decode_response :: proc(data: []u8, allocator: runtime.Allocator) -> (Response, Error) {
	tokens := json.make_tokenizer(string(data), .JSON)
	opening, opening_error := json.get_token(&tokens)
	if opening_error != nil || opening.kind != .Open_Brace {return {}, .Protocol}
	seen_ok, seen_text, seen_status := false, false, false
	for _ in 0 ..< 3 {
		key_token, key_error := json.get_token(&tokens)
		if key_error != nil || key_token.kind != .String {return {}, .Protocol}
		key: string
		if json.unmarshal_string(key_token.text, &key, .JSON, allocator) != nil {
			delete(key, allocator)
			return {}, .Out_Of_Memory
		}
		is_ok, is_text, is_status := key == "ok", key == "text", key == "status"
		delete(key, allocator)
		colon, colon_error := json.get_token(&tokens)
		if colon_error != nil || colon.kind != .Colon {return {}, .Protocol}
		value, value_error := json.get_token(&tokens)
		if value_error != nil {return {}, .Protocol}
		if is_ok && !seen_ok && (value.kind == .True || value.kind == .False) {
			seen_ok = true
		} else if is_text && !seen_text && value.kind == .String {
			seen_text = true
		} else if is_status && !seen_status && value.kind == .Float {
			// The tokenizer reports every number as Float; a status is plain decimal digits.
			status, valid := strconv.parse_uint(value.text, 10)
			if !valid || status > uint(max(u8)) {return {}, .Protocol}
			seen_status = true
		} else {
			return {}, .Protocol
		}
		separator, separator_error := json.get_token(&tokens)
		if separator_error != nil {return {}, .Protocol}
		if separator.kind == .Close_Brace {
			break
		}
		if separator.kind != .Comma {return {}, .Protocol}
	}
	ending, ending_error := json.get_token(&tokens)
	if !seen_ok ||
	   !seen_text ||
	   ending.kind != .EOF ||
	   (ending_error != nil && ending_error != .EOF) {return {}, .Protocol}
	response: Response
	if decode_error := json.unmarshal(data, &response, .JSON, allocator); decode_error != nil {
		response_destroy(&response, allocator)
		if cause, ok := decode_error.(json.Error); ok && cause == .Out_Of_Memory {
			return {}, .Out_Of_Memory
		}
		return {}, .Protocol
	}
	if !utf8.valid_string(response.text) {
		response_destroy(&response, allocator)
		return {}, .Protocol
	}
	return response, .None
}

response_destroy :: proc(response: ^Response, allocator := context.allocator) {
	delete(response.text, allocator)
	response^ = {}
}
