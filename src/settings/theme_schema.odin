package settings

import "core:encoding/json"
import "core:fmt"
import "core:strings"

@(require_results)
theme_schema_text :: proc(allocator := context.allocator) -> (string, bool) {
	builder, error := strings.builder_make(context.temp_allocator)
	if error != nil {return "", false}
	defer strings.builder_destroy(&builder)
	if write_parts(&builder, `{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "AIODev Theme",
  "type": "object",
  "additionalProperties": false,
  "required": ["version", "id", "colors"],
  "properties": {
    "$schema": {"type": "string"},
    "version": {"const": 1},
    "id": {"type": "string", "pattern": "^[a-z0-9][a-z0-9_-]*$", "maxLength": `,
		fmt.tprintf("%d", PROFILE_ID_MAX_LENGTH), `},
    "name": {"type": "string", "description": "Display name shown in the theme selector; any text."},
    "author": {"type": "string"},
    "description": {"type": "string"},
    "base": {
      "type": "string",
      "description": "ID of another theme that supplies the colors this file leaves out.",
      "pattern": "^[a-z0-9][a-z0-9_-]*$"
    },
    "colors": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
`,
	) != nil {return "", false}
	for info, token in THEME_TOKENS {
		pattern := "^#[0-9a-fA-F]{6}$"
		if info.kind == .Translucent {pattern = "^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$"}
		if info.kind == .Optional {pattern = "^(#[0-9a-fA-F]{6})?$"}
		property := struct {type, title, description, pattern: string} {
			"string", info.title, info.description, pattern,
		}
		data, marshal_error := json.marshal(property, allocator = context.temp_allocator)
		if marshal_error != nil {return "", false}
		if token != .Window && write_parts(&builder, ",\n") != nil {return "", false}
		if write_parts(&builder, fmt.tprintf("        %q: %s", info.key, data)) != nil {return "", false}
	}
	if write_parts(&builder, "\n      }\n    }\n  }\n}\n") != nil {return "", false}
	text, clone_error := strings.clone(strings.to_string(builder), allocator)
	return text, clone_error == nil
}
