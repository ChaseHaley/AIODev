package app_test

import "cosmos:testkit"

@(init)
warm :: proc "contextless" () {
	testkit.warm_directwrite()
}
