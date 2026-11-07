package cli_protocol_test

import "core:testing"
import "aio:cli_protocol"
import "aio:control"

@(test)
request_header_round_trip :: proc(t: ^testing.T) {
	command := []string{"pane.split", "--direction", "down"}
	for format in cli_protocol.Format {
		args := cli_protocol.request_encode({caller = "7", format = format, command = command})
		defer delete(args)
		testing.expect_value(t, len(args), cli_protocol.HEADER_LENGTH + len(command))
		request, ok := cli_protocol.request_decode(args)
		testing.expect(t, ok)
		testing.expect_value(t, request.caller, "7")
		testing.expect_value(t, request.format, format)
		testing.expect_value(t, len(request.command), len(command))
		testing.expect_value(t, request.command[0], "pane.split")
	}
	for bad in ([][]string{{}, {"", "text"}, {"", "yaml", "pane.list"}}) {
		_, ok := cli_protocol.request_decode(bad)
		testing.expect(t, !ok)
	}
}

@(test)
status_round_trip :: proc(t: ^testing.T) {
	for status in cli_protocol.Status {
		testing.expect_value(t, cli_protocol.response_status(cli_protocol.response(status, "x")), status)
	}
	// A reply without a status, such as a verification reply, maps ok to Ok and failure to Failed.
	testing.expect_value(t, cli_protocol.response_status(control.Response{ok = true}), cli_protocol.Status.Ok)
	testing.expect_value(t, cli_protocol.response_status(control.Response{}), cli_protocol.Status.Failed)
}

@(test)
pane_status_words :: proc(t: ^testing.T) {
	for word, status in cli_protocol.PANE_STATUS_WORDS {
		parsed, ok := cli_protocol.pane_status_parse(word)
		testing.expect(t, ok)
		testing.expect_value(t, parsed, status)
	}
	testing.expect_value(t, cli_protocol.PANE_STATUS_WORDS[.Closed], "closed")
	_, ok := cli_protocol.pane_status_parse("stopped")
	testing.expect(t, !ok)
}
