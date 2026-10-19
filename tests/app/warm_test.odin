package app_test

import fixtures "../fixtures"

@(init)
warm :: proc "contextless" () {
	fixtures.warm_directwrite()
}
