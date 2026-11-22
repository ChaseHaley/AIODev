package ui_test

import "cosmos:testkit"

// Takes DirectWrite's one-time internal exception before the test runner is watching.
@(init)
warm :: proc "contextless" () {
	testkit.warm_directwrite()
}
