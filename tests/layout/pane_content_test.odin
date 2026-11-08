package layout_test

import "aio:layout"
import "core:testing"

@(test)
pane_content_queries_reject_missing_and_non_pane_nodes :: proc(t: ^testing.T) {
	tree: layout.Layout
	_, ok := layout.pane_content(&tree, layout.INVALID_NODE)
	testing.expect(t, !ok)
	_, ok = layout.focused_content(&tree)
	testing.expect(t, !ok)
	if !testing.expect_value(t, layout.init(&tree, {.Terminal, 7}), nil) {return}
	defer layout.destroy(&tree)
	first := tree.root
	content, focused := layout.focused_content(&tree)
	testing.expect(t, focused)
	testing.expect_value(t, content, layout.Content{.Terminal, 7})
	second, err := layout.split_direction(&tree, first, .Right, 0.5, {.Settings, 0})
	if !testing.expect_value(t, err, nil) {return}
	content, ok = layout.pane_content(&tree, second)
	testing.expect(t, ok)
	testing.expect_value(t, content, layout.Content{.Settings, 0})
	_, ok = layout.pane_content(&tree, tree.root)
	testing.expect(t, !ok)
	tree.focus = tree.root
	_, ok = layout.focused_content(&tree)
	testing.expect(t, !ok)
	if !testing.expect(t, layout.remove(&tree, second)) {return}
	_, ok = layout.pane_content(&tree, second)
	testing.expect(t, !ok)
	_, ok = layout.pane_content(&tree, layout.Node_Id(len(tree.nodes)))
	testing.expect(t, !ok)
}
