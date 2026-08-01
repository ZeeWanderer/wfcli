%%%-------------------------------------------------------------------
%% EUnit coverage for daemon supervisor recovery.
%%%-------------------------------------------------------------------
-module(wfcli_supervision_eunit).

-include_lib("eunit/include/eunit.hrl").

registered_processes_are_declared_test() ->
    case application:load(wfdaemon) of
        ok -> ok;
        {error, {already_loaded, wfdaemon}} -> ok
    end,
    {ok, Registered} = application:get_key(wfdaemon, registered),
    ?assertEqual(
       [wfcli_sup, wfcli_daemon, wfcli_worldstate_service, wfcli_exports_store,
        wfcli_source_manager, wfcli_query_service, wfcli_forma_service,
        wfcli_player_service, wfcli_market_service, wfcli_asset_service,
        wfcli_notification_service, wfcli_local_api],
       Registered).

query_worker_is_restarted_test() ->
    Started = whereis(wfcli_sup) =:= undefined,
    case Started of true -> ok = wfcli_test_daemon:start(); false -> ok end,
    try
        Supervisor = whereis(wfcli_sup),
        Old = whereis(wfcli_query_service),
        ?assert(is_pid(Supervisor)),
        ?assert(is_pid(Old)),
        exit(Old, kill),
        New = await_replacement(wfcli_query_service, Old, 100),
        ?assert(is_pid(New)),
        ?assert(is_process_alive(Supervisor))
    after
        case Started of true -> wfcli_test_daemon:stop(); false -> ok end
    end.

await_replacement(_Name, _Old, 0) -> undefined;
await_replacement(Name, Old, Attempts) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Old -> Pid;
        _ -> timer:sleep(10), await_replacement(Name, Old, Attempts - 1)
    end.
