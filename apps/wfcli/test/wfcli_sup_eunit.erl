-module(wfcli_sup_eunit).

-include_lib("eunit/include/eunit.hrl").

restart_policy_tolerates_short_bursts_test() ->
    {ok, {Flags, _Children}} = wfcli_sup:init([]),
    ?assertEqual(one_for_one, maps:get(strategy, Flags)),
    ?assertEqual(3, maps:get(intensity, Flags)),
    ?assertEqual(10, maps:get(period, Flags)).
