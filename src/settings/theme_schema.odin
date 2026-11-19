package settings

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// The JSON schema of a theme file. Its top-level fields and which are required come from
// THEME_FIELDS; each field's restrictions are the schema's own, written for editors.
@(require_results)
theme_schema_text :: proc(allocator := context.allocator) -> (string, bool) {
	builder, error := strings.builder_make(context.temp_allocator)
	if error != nil {return "", false}
	defer strings.builder_destroy(&builder)
	if write_parts(&builder, `{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "AIODev theme",
  "type": "object",
  "additionalProperties": false,
  "required": [`) != nil {return "", false}
	first := true
	for info in THEME_FIELDS {
		if !info.required {continue}
		if write_parts(&builder, first ? "" : ", ", `"`, info.key, `"`) != nil {return "", false}
		first = false
	}
	if write_parts(&builder, "],\n  \"properties\": {\n") != nil {return "", false}
	first = true
	for info, field in THEME_FIELDS {
		if write_parts(&builder, first ? "" : ",\n", `    "`, info.key, `": `) != nil {return "", false}
		first = false
		if !theme_field_schema(&builder, field) {return "", false}
	}
	if write_parts(&builder, "\n  },\n  \"$defs\": {\n    \"colorReference\": ") != nil {return "", false}
	if !theme_reference_schema(&builder) {return "", false}
	if write_parts(&builder, "\n  }\n}\n") != nil {return "", false}
	text, clone_error := strings.clone(strings.to_string(builder), allocator)
	return text, clone_error == nil
}

@(private, require_results)
theme_field_schema :: proc(builder: ^strings.Builder, field: Theme_Field) -> bool {
	switch field {
	case .Schema, .Author, .Description:
		return write_parts(builder, `{"type": "string"}`) == nil
	case .Version:
		return write_parts(builder, `{"const": 1}`) == nil
	case .Id:
		return write_parts(
			builder,
			`{"type": "string", "pattern": "`,
			ID_PATTERN,
			`", "maxLength": `,
			fmt.tprintf("%d", THEME_ID_MAX_LENGTH),
			`}`,
		) == nil
	case .Name:
		return write_parts(
			builder,
			`{"type": "string", "description": "Display name shown in the theme selector; any text."}`,
		) == nil
	case .Base:
		return write_parts(builder, `{
      "type": "string",
      "description": "ID of another theme that supplies the colors this file leaves out.",
      "pattern": "`, ID_PATTERN, `"
    }`) == nil
	case .Colors:
		if write_parts(builder, `{
      "type": "object",
      "additionalProperties": false,
      "properties": {
`) != nil {return false}
		first := true
		for info in THEME_TOKENS {
			pattern := "^#[0-9a-fA-F]{6}$"
			if info.kind == .Translucent {pattern = "^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$"}
			if info.kind == .Optional {pattern = "^(#[0-9a-fA-F]{6})?$"}
			title, title_error := json.marshal(info.title, allocator = context.temp_allocator)
			description, description_error := json.marshal(info.description, allocator = context.temp_allocator)
			if title_error != nil || description_error != nil {return false}
			quoted_key := fmt.tprintf("%q", info.key)
			quoted_pattern := fmt.tprintf("%q", pattern)
			if write_parts(
				   builder,
				   first ? "" : ",\n",
				   "        ",
				   quoted_key,
				   `: {"type":"string","title":`,
				   string(title),
				   `,"description":`,
				   string(description),
				   `,"anyOf":[{"pattern":`,
				   quoted_pattern,
				   `},{"$ref":"#/$defs/colorReference"}]}`,
			   ) != nil {return false}
			first = false
		}
		return write_parts(builder, "\n      }\n    }") == nil
	}
	return false
}

// The keys a color may follow: every theme color that always has a value.
@(private, require_results)
theme_reference_schema :: proc(builder: ^strings.Builder) -> bool {
	if write_parts(builder, `{
      "description": "The key of another color of this theme, which this color then follows.",
      "enum": [`) != nil {return false}
	first := true
	for info in THEME_TOKENS {
		if info.kind == .Optional {continue}
		line := fmt.tprintf("%s%q", first ? "" : ", ", info.key)
		if write_parts(builder, line) != nil {return false}
		first = false
	}
	return write_parts(builder, "]\n    }") == nil
}
