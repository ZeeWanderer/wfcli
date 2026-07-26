%%%-------------------------------------------------------------------
%% EUnit tests for update action selection.
%%%-------------------------------------------------------------------
-module(wfcli_update_cli_eunit).

-include_lib("eunit/include/eunit.hrl").

no_flags_selects_default_official_update_test() ->
    ?assertNot(wfcli_update_cli:has_update_flags(wfcli_update_cli:default_opts())).

default_is_explicit_official_set_test() ->
    Parsed = wfcli_update_cli:parse_args(["--default"], wfcli_update_cli:default_opts()),
    ?assertEqual(true, maps:get(update_default, Parsed)),
    ?assertEqual(false, maps:get(update_all, Parsed)),
    ?assert(wfcli_update_cli:has_update_flags(Parsed)).

all_includes_optional_sources_test() ->
    Parsed = wfcli_update_cli:parse_args(["--all"], wfcli_update_cli:default_opts()),
    ?assertEqual(true, maps:get(update_all, Parsed)),
    ?assert(wfcli_update_cli:has_update_flags(Parsed)).

cache_only_flags_do_not_select_full_metadata_update_test() ->
    Worldstate = wfcli_update_cli:parse_args(["--worldstate"], wfcli_update_cli:default_opts()),
    Trader = wfcli_update_cli:parse_args(["--trader"], wfcli_update_cli:default_opts()),
    ?assert(wfcli_update_cli:has_update_flags(Worldstate)),
    ?assert(wfcli_update_cli:has_update_flags(Trader)).

wfcd_is_explicit_but_not_default_test() ->
    Parsed = wfcli_update_cli:parse_args(["--wfcd"], wfcli_update_cli:default_opts()),
    ?assertEqual(true, maps:get(update_wfcd, Parsed)),
    ?assert(wfcli_update_cli:has_update_flags(Parsed)).
