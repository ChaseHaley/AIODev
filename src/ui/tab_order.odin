package ui

tab_selection_update :: proc(marked: []bool, index, anchor: int, toggle, range: bool) {
	if index < 0 || index >= len(marked) {return}
	if range {
		first := clamp(anchor, 0, len(marked) - 1)
		for &value, i in marked {
			inside := i >= min(first, index) && i <= max(first, index)
			value = inside || (toggle && value)
		}
	} else if toggle {marked[index] = !marked[index]} else {
		for &value, i in marked {value = i == index}
	}
}

// `slot` counts unselected tabs preceding the group. The result indexes the original list.
tab_group_order :: proc(marked: []bool, slot: int, out: []int) -> bool {
	if len(out) != len(marked) {return false}
	count := 0
	for value in marked {if value {count += 1}}
	if count == 0 || slot < 0 || slot > len(marked) - count {return false}
	at, unmarked := 0, 0
	for value, i in marked {
		if value {continue}
		if unmarked == slot {
			for selected, j in marked {if selected {out[at] = j; at += 1}}
		}
		out[at], at, unmarked = i, at + 1, unmarked + 1
	}
	if unmarked == slot {
		for selected, j in marked {if selected {out[at] = j; at += 1}}
	}
	return true
}
