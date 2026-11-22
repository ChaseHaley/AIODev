package fixtures_test

import "aio:settings"
import "core:strconv"

// The interface settings at their schema defaults, so a test builds the theme the application builds.
default_interface :: proc() -> settings.Interface_Settings {
	lift, _ := strconv.parse_f64(settings.schema_find("interface.hover_lift").default_value)
	gloss, _ := strconv.parse_f64(settings.schema_find("interface.hover_gloss").default_value)
	return {hover_lift = lift, hover_gloss = gloss}
}
