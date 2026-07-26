%%%-------------------------------------------------------------------
%% EUnit tests for query CLI arg parsing.
%%%-------------------------------------------------------------------
-module(wfcli_query_cli_eunit).

-include_lib("eunit/include/eunit.hrl").

parse_args_fuzz_test() ->
    _ = rand:seed(exsplus, {9, 10, 11}),
    lists:foreach(
      fun(_Idx) ->
          Args = random_args(),
          Parsed = wfcli_query_cli:parse_args(Args, wfcli_query_cli:default_opts()),
          ?assert(is_map(Parsed)),
          ?assert(is_list(maps:get(errors, Parsed, [])))
      end,
      lists:seq(1, 50)).

parse_args_near_miss_suggests_test() ->
    Parsed = wfcli_query_cli:parse_args(["--formatt", "table"], wfcli_query_cli:default_opts()),
    Errors = maps:get(errors, Parsed, []),
    ?assert(lists:any(fun(E) -> string:find(E, "did you mean") =/= nomatch end, Errors)).

query_has_no_default_limit_test() ->
    ?assertNot(maps:is_key(limit, wfcli_query_cli:default_opts())).

daemon_protocol_tracks_market_source_test() ->
    ?assertEqual(5, wfcli_protocol:version()),
    ?assertEqual(wfcli_market_service, wfcli_protocol:owner(#{source => market})).

explicit_limit_is_parsed_test() ->
    Parsed = wfcli_query_cli:parse_args(["--limit", "7", "test"],
                                        wfcli_query_cli:default_opts()),
    ?assertEqual(7, maps:get(limit, Parsed)).

limit_rejects_trailing_garbage_test() ->
    Parsed = wfcli_query_cli:parse_args(["--limit", "7x", "test"],
                                        wfcli_query_cli:default_opts()),
    ?assertMatch([_ | _], maps:get(errors, Parsed)).

worldstate_pagination_uses_explicit_limit_test() ->
    {ok, Result} = wfcli_query_service:paginate_worldstate(
                     {ok, #{entries => [first, second, third]}},
                     #{offset => 1, limit => 1}),
    ?assertEqual([second], maps:get(entries, Result)).

worldstate_pagination_is_unlimited_by_default_test() ->
    {ok, Result} = wfcli_query_service:paginate_worldstate(
                     {ok, #{entries => [first, second, third]}}, #{}),
    ?assertEqual([first, second, third], maps:get(entries, Result)).

dataset_selector_defaults_to_official_test() ->
    {ok, ["braton"], Datasets, false} = wfcli_query_service:select_datasets(["braton"]),
    ?assertEqual([worldstate, mods, items, codex], Datasets).

dataset_selector_is_removed_from_quoted_query_test() ->
    {ok, ["serration"], Datasets, true} =
        wfcli_query_service:select_datasets(["dataset=codex|drops serration"]),
    ?assertEqual([codex, drops], Datasets).

dataset_selector_accepts_all_test() ->
    {ok, [], Datasets, true} = wfcli_query_service:select_datasets(["dataset:all"]),
    ?assertEqual([worldstate, mods, items, codex, enemies, drops, player, market], Datasets).

dataset_selector_accepts_player_test() ->
    {ok, [], [player], true} = wfcli_query_service:select_datasets(["dataset=player"]).

dataset_selector_accepts_market_test() ->
    {ok, [], [market], true} = wfcli_query_service:select_datasets(["dataset=market"]).

dataset_selector_accepts_default_plus_optional_test() ->
    {ok, [], Datasets, true} = wfcli_query_service:select_datasets(["dataset=default|drops"]),
    ?assertEqual([worldstate, mods, items, codex, drops], Datasets).

dataset_selector_rejects_unknown_test() ->
    ?assertMatch({error, _}, wfcli_query_service:select_datasets(["dataset=fish"])).

random_args() ->
    Known = wfcli_query_cli:known_args(),
    Tokens = ["void", "alerts", "foo", "bar", "baz"],
    lists:append([
        maybe_pick(Known),
        maybe_pick(Known),
        maybe_pick(Tokens),
        maybe_unknown_flag()
    ]).

maybe_pick(List) ->
    case rand:uniform(3) of
        1 -> [lists:nth(rand:uniform(length(List)), List)];
        _ -> []
    end.

maybe_unknown_flag() ->
    case rand:uniform(2) of
        1 -> ["--formatt"];
        _ -> []
    end.
