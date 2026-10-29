package settings

import "core:strings"
import "core:unicode/utf8"

Profile_Value_Facts :: struct {
	trimmed:                  string,
	empty, valid, name_taken: bool,
}

// Text is borrowed and never rewritten. Name comparisons ignore surrounding space and case;
// detected-only candidates share a namespace, separate from explicit profiles. An unknown ID
// represents a new explicit profile. No filesystem checks or allocations occur here.
profile_value_facts :: proc(value: string, profiles: ^Profiles = nil, id := "") -> Profile_Value_Facts {
	facts := Profile_Value_Facts {
		trimmed = strings.trim_space(value),
		valid   = utf8.valid_string(value) && !strings.contains(value, "\x00"),
	}
	facts.empty = facts.trimmed == ""
	if profiles == nil || facts.empty || !facts.valid {return facts}
	detected := false
	if profile := profile_find(profiles, id); profile != nil {detected = profile.detected}
	for &other in profiles.items {
		if other.id == id || other.detected != detected {continue}
		if strings.equal_fold(strings.trim_space(other.name), facts.trimmed) {
			facts.name_taken = true
			break
		}
	}
	return facts
}
