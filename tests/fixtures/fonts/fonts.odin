// Fonts for tests and the headless build, so their text draws the same on every machine (D-040,
// WORK-351). They are not shipped; licences are in this folder (README.txt).
package test_fonts

import "aio:font"

MONO :: "Cascadia Mono"
// Cascadia Mono with programming ligatures.
CODE :: "Cascadia Code"
UI :: "Selawik"
EMOJI :: "Twemoji Mozilla"

@(private)
FILES := [?][]u8 {
	#load("CascadiaMono.ttf"),
	#load("CascadiaMonoItalic.ttf"),
	#load("CascadiaCode.ttf"),
	#load("selawk.ttf"),
	#load("selawksb.ttf"),
	#load("selawkb.ttf"),
	#load("Twemoji.Mozilla.ttf"),
}

// The bundled families, monospace first so fallback prefers it, then the interface and emoji fonts.
files :: proc() -> font.Font_Files {
	return {files = FILES[:], emoji_family = EMOJI}
}
