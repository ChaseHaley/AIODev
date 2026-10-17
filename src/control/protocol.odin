package control

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"

MAX_MESSAGE :: 4 * 1024 * 1024
Wake :: struct { procedure: proc(user: rawptr), user: rawptr }
Response :: struct { ok: bool, text: string }

@(private)
valid_pipe_name :: proc(name: string) -> bool {
	return strings.has_prefix(name, `\\.\pipe\`) && len(name) > len(`\\.\pipe\`) &&
	       !strings.contains(name, "\x00") && utf8.valid_string(name)
}
Message :: struct {
	id: u64,
	args: []string,
	request: Request,
	parse_error: Parse_Error,
	allocator: runtime.Allocator,
}

message_destroy :: proc(m: ^Message) {
	if m == nil { return }
	request_destroy(&m.request)
	for arg in m.args {
		delete(arg, m.allocator)
	}
	delete(m.args, m.allocator)
	free(m, m.allocator)
}

@(require_results)
pipe_name :: proc(app_id: string, allocator := context.allocator) -> (string, Error) {
	if app_id == "" || strings.contains_any(app_id, "\\/\x00") || !utf8.valid_string(app_id) {
		return "", .Invalid_Argument
	}
	s, err := strings.concatenate({`\\.\pipe\`, app_id, ".control"}, allocator)
	if err != nil { return "", .Out_Of_Memory }
	return s, .None
}

@(private, require_results)
decode_request :: proc(data: []u8, allocator := context.allocator) -> (^Message, Error) {
	if len(data) > MAX_MESSAGE { return nil, .Protocol }
	text := strings.trim_space(string(data))
	if len(text) == 0 || text[0] != '[' { return nil, .Protocol }
	tokens := json.make_tokenizer(text, .JSON)
	opening, opening_error := json.get_token(&tokens)
	if opening_error != nil || opening.kind != .Open_Bracket { return nil, .Protocol }
	allow_end := true
	for {
		token, token_error := json.get_token(&tokens)
		if token_error != nil { return nil, .Protocol }
		if token.kind == .Close_Bracket && allow_end {
			break
		}
		if token.kind != .String { return nil, .Protocol }
		separator, separator_error := json.get_token(&tokens)
		if separator_error != nil { return nil, .Protocol }
		if separator.kind == .Close_Bracket {
			break
		}
		if separator.kind != .Comma { return nil, .Protocol }
		allow_end = false
	}
	ending, ending_error := json.get_token(&tokens)
	if (ending_error != nil && ending_error != .EOF) || ending.kind != .EOF { return nil, .Protocol }
	m, err := new(Message, allocator)
	if err != nil { return nil, .Out_Of_Memory }
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
	m.request, m.parse_error = parse(m.args, allocator)
	return m, .None
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
	if opening_error != nil || opening.kind != .Open_Brace { return {}, .Protocol }
	seen_ok, seen_text := false, false
	for _ in 0..<2 {
		key_token, key_error := json.get_token(&tokens)
		if key_error != nil || key_token.kind != .String { return {}, .Protocol }
		key: string
		if json.unmarshal_string(key_token.text, &key, .JSON, allocator) != nil {
			delete(key, allocator)
			return {}, .Out_Of_Memory
		}
		is_ok, is_text := key == "ok", key == "text"
		delete(key, allocator)
		colon, colon_error := json.get_token(&tokens)
		if colon_error != nil || colon.kind != .Colon { return {}, .Protocol }
		value, value_error := json.get_token(&tokens)
		if value_error != nil { return {}, .Protocol }
		if is_ok && !seen_ok && (value.kind == .True || value.kind == .False) {
			seen_ok = true
		} else if is_text && !seen_text && value.kind == .String {
			seen_text = true
		} else {
			return {}, .Protocol
		}
		separator, separator_error := json.get_token(&tokens)
		if separator_error != nil { return {}, .Protocol }
		if separator.kind == .Close_Brace {
			break
		}
		if separator.kind != .Comma { return {}, .Protocol }
	}
	ending, ending_error := json.get_token(&tokens)
	if !seen_ok || !seen_text || ending.kind != .EOF ||
	   (ending_error != nil && ending_error != .EOF) { return {}, .Protocol }
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
