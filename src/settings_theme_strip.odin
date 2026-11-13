package main

import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:strings"

// Used only when AIO_CONTROL is set.
_ :: strings

// Lists every theme on the Theme row's filmstrip in the theme selector's order, each with the colours
// it resolves to and what kind of theme it is.
@(private, require_results)
settings_theme_strip_load :: proc(p: ^ui.Editor, s: ^settings.Settings) -> bool {
	ids, names := settings_theme_choices(s)
	sources := make([dynamic]ui.Theme_Card_Source, 0, len(ids), context.temp_allocator)
	for id, i in ids {
		theme := settings.custom_theme_find(s, id)
		if theme == nil {continue}
		resolved := settings.custom_theme_resolve(s, theme)
		detail := fmt.tprintf("Theme file · %s", resolved.light ? "light" : "dark")
		if !theme.external {
			detail = "Custom"
			if theme.base != "" {
				detail = fmt.tprintf("Custom · based on %s", settings.theme_display_name(s, theme.base))
			}
		}
		source := ui.Theme_Card_Source {
			id     = id,
			name   = names[i],
			detail = detail,
			custom = !theme.external,
			theme  = resolved,
		}
		append(&sources, source)
	}
	return ui.editor_theme_strip_load(p, THEME_KEY, sources[:], s.theme.name) == nil
}

when AIO_CONTROL {
	// The strip's cards as drawn, `id@x,y,width,height` joined by `;`, with the applied and focused
	// themes, the Customize button and whether anything still moves.
	settings_theme_strip_state :: proc(r: ^State_Report, p: ^ui.Editor, page: ui.Editor_Layout) {
		strip := &p.strip
		state_text(r, "settings.theme.applied", ui.editor_strip_card_id(p, strip.applied))
		state_text(r, "settings.theme.focus", ui.editor_strip_card_id(p, strip.focus))
		state_value(r, "settings.theme.customize_focus", strip.customize_focus)
		state_value(r, "settings.theme.moving", ui.editor_strip_animating(p))
		state_valuef(r, "settings.theme.scroll", "%g", strip.scroll.value)
		head := -1
		for item, index in p.items {
			if item.row >= 0 && item.part == 0 && p.rows[item.row].kind == .Theme_Strip {head = index; break}
		}
		cards := strings.builder_make(context.temp_allocator)
		if head >= 0 && page.scale > 0 {
			for card, i in strip.cards {
				rect := ui.editor_strip_card_rect(p, page, head, i)
				if i > 0 {strings.write_byte(&cards, ';')}
				fmt.sbprintf(&cards, "%s@%g,%g,%g,%g", card.id, rect.x, rect.y, rect.width, rect.height)
			}
			state_rect(r, "settings.theme.customize", ui.editor_strip_customize_rect(p, page, head))
		}
		state_text(r, "settings.theme.cards", strings.to_string(cards))
	}
}
