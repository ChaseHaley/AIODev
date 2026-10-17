package term_view_test

import fixtures "../fixtures"

// Takes DirectWrite's one-time internal exception before the test runner is watching.
@(init)
warm :: proc "contextless" () {
	fixtures.warm_directwrite()
}
