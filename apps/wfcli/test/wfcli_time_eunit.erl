%%%-------------------------------------------------------------------
%% EUnit tests for shared time helpers.
%%%-------------------------------------------------------------------
-module(wfcli_time_eunit).

-include_lib("eunit/include/eunit.hrl").

format_millis_raw_utc_test() ->
    Output = wfcli_time:format_millis(1701430200000, #{raw => true}),
    ?assert(re:run(Output, "Z$", []) =/= nomatch).

format_millis_local_offset_test() ->
    Output = wfcli_time:format_millis(1701430200000, #{raw => false}),
    ?assert(re:run(Output, "Z$", []) =:= nomatch),
    ?assert(re:run(Output, "[+-][0-9]{2}:[0-9]{2}$", []) =/= nomatch).

format_millis_string_input_test() ->
    Output = wfcli_time:format_millis("1701430200000", #{raw => false}),
    ?assert(re:run(Output, "[+-][0-9]{2}:[0-9]{2}$", []) =/= nomatch).

format_millis_passthrough_test() ->
    ?assertEqual("soon", wfcli_time:format_millis("soon", #{raw => false})).
