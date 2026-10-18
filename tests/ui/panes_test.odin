package ui_test

import "core:testing"
import "aio:layout"
import "aio:ui"

@(test)
pane_cards_keep_nonnegative_geometry_and_draggable_gaps :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75}) {
		for gap in ([?]f32{0, 5, 24}) {
			area := ui.pane_area(1200*scale, 800*scale, 36*scale, gap, scale)
			tree: layout.Layout
			testing.expect_value(t, layout.init(&tree, {id = 1}), nil)
			defer layout.destroy(&tree)
			panes: [dynamic]layout.Pane_Rect
			dividers: [dynamic]layout.Divider
			defer delete(panes)
			defer delete(dividers)
			r := layout.Rect{area.x, area.y, area.width, area.height}
			spacing := ui.pane_gap(gap, scale)
			for count in 1..=4 {
				if count > 1 {
					_, err := layout.split(&tree, 0, count%2 == 0 ? .Horizontal : .Vertical, 0.5, {id = u32(count)})
					testing.expect_value(t, err, nil)
				}
				layout.compute(&tree, r, spacing, &panes)
				layout.dividers(&tree, r, spacing, &dividers)
				testing.expect_value(t, len(panes), count)
				for pane in panes {
					testing.expect(t, pane.rect.width >= 0 && pane.rect.height >= 0)
					testing.expect(t, pane.rect.x >= r.x && pane.rect.y >= r.y)
					testing.expect(t, pane.rect.x+pane.rect.width <= r.x+r.width)
				}
				for d in dividers {
					x, y := d.rect.x+d.rect.width/2, d.rect.y+d.rect.height/2
					_, found := layout.divider_hit_test(dividers[:], x, y, 3*scale)
					testing.expect(t, found)
					testing.expect(t, layout.drag_divider(&tree, d, x+10*scale, y+10*scale, spacing))
				}
			}
		}
	}
	tiny := ui.pane_area(10, 10, 36, 24, 1)
	testing.expect_value(t, tiny.width, f32(0))
	testing.expect_value(t, tiny.height, f32(0))
}
