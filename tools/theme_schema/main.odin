package theme_schema

import "aio:settings"
import "core:os"

main :: proc() {
	text, ok := settings.theme_schema_text()
	if !ok {os.exit(1)}
	defer delete(text)
	if error := os.write_entire_file("themes/theme.schema.json", transmute([]u8)text); error != nil {
		os.exit(1)
	}
}
