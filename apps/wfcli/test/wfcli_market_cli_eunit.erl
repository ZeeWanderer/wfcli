%%%-------------------------------------------------------------------
%% EUnit coverage for dedicated market CLI arguments.
%%%-------------------------------------------------------------------
-module(wfcli_market_cli_eunit).

-include_lib("eunit/include/eunit.hrl").

market_has_no_silent_default_limit_test() ->
    ?assertNot(maps:is_key(limit, wfcli_market_cli:default_opts())).

market_limit_and_ttl_are_explicit_test() ->
    Parsed = wfcli_market_cli:parse_args(
               ["--limit", "5", "--ttl", "120", "saryn"],
               wfcli_market_cli:default_opts()),
    ?assertEqual(5, maps:get(limit, Parsed)),
    ?assertEqual(120, maps:get(ttl, Parsed)),
    ?assertEqual(["saryn"], maps:get(query_tokens, Parsed)),
    ?assertEqual([], maps:get(errors, Parsed)).

market_rejects_bad_limit_test() ->
    Parsed = wfcli_market_cli:parse_args(["--limit", "many"],
                                         wfcli_market_cli:default_opts()),
    ?assertMatch([_ | _], maps:get(errors, Parsed)).

market_rejects_excessive_limit_test() ->
    Parsed = wfcli_market_cli:parse_args(["--limit", "101"],
                                         wfcli_market_cli:default_opts()),
    ?assertMatch([_ | _], maps:get(errors, Parsed)).
