%%%-------------------------------------------------------------------
%% EUnit coverage for daemon-owned player persistence and subscriptions.
%%%-------------------------------------------------------------------
-module(wfcli_player_service_eunit).

-include_lib("eunit/include/eunit.hrl").

player_service_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Path) -> [
         fun merges_source_owned_namespaces/0,
         fun notifies_and_releases_dead_subscribers/0,
         fun reloads_persisted_snapshot/0,
         fun game_stop_does_not_erase_cached_inventory/0
     ] end}.

setup() ->
    Path = filename:join(
             "/tmp", "wfcli-player-" ++ integer_to_list(erlang:unique_integer([positive]))),
    application:set_env(wfdaemon, player_cache, Path),
    {ok, _Pid} = wfcli_player_service:start_link(),
    Path.

cleanup(Path) ->
    case whereis(wfcli_player_service) of
        undefined -> ok;
        _Pid -> gen_server:stop(wfcli_player_service)
    end,
    application:unset_env(wfdaemon, player_cache),
    _ = file:delete(Path ++ ".tmp"),
    _ = file:delete(Path),
    ok.

merges_source_owned_namespaces() ->
    {ok, _} = wfcli_player_service:publish(
                <<"inventory">>, #{<<"weapons">> => [<<"Braton">>]}),
    {ok, _} = wfcli_player_service:publish(
                <<"profile">>, #{<<"rank">> => 12}),
    Data = maps:get(data, wfcli_player_service:snapshot()),
    ?assert(maps:is_key(<<"inventory">>, Data)),
    ?assert(maps:is_key(<<"profile">>, Data)).

notifies_and_releases_dead_subscribers() ->
    Parent = self(),
    Client = spawn(fun() -> receive stop -> Parent ! stopped end end),
    {ok, _Ref, _} = wfcli_player_service:subscribe(Client),
    ?assertEqual(1, maps:get(subscribers, wfcli_player_service:status())),
    exit(Client, kill),
    await_subscribers(0, 50).

reloads_persisted_snapshot() ->
    Before = wfcli_player_service:snapshot(),
    ok = gen_server:stop(wfcli_player_service),
    {ok, _Pid} = wfcli_player_service:start_link(),
    After = wfcli_player_service:snapshot(),
    ?assertEqual(maps:get(data, Before), maps:get(data, After)).

game_stop_does_not_erase_cached_inventory() ->
    Inventory = #{<<"schema">> => 1, <<"sync">> => <<"abc">>},
    {ok, _} = wfcli_player_service:publish(<<"inventory">>, Inventory),
    {ok, _} = wfcli_player_service:publish(<<"game">>, #{<<"running">> => false}),
    Data = maps:get(data, wfcli_player_service:snapshot()),
    ?assertEqual(Inventory, maps:get(<<"inventory">>, Data)).

await_subscribers(Expected, 0) ->
    ?assertEqual(Expected, maps:get(subscribers, wfcli_player_service:status()));
await_subscribers(Expected, Attempts) ->
    case maps:get(subscribers, wfcli_player_service:status()) of
        Expected -> ok;
        _ -> timer:sleep(10), await_subscribers(Expected, Attempts - 1)
    end.
