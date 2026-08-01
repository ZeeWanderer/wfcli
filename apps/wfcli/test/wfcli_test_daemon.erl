%%%-------------------------------------------------------------------
%% Local supervised daemon harness for CLI integration suites.
%%%-------------------------------------------------------------------
-module(wfcli_test_daemon).

-export([start/0, stop/0]).

start() ->
    {ok, CallerCwd} = file:get_cwd(),
    TestRoot = filename:join(
                 "/tmp", "wfcli-test-" ++ os:getpid() ++ "-" ++
                     integer_to_list(erlang:unique_integer([positive]))),
    application:set_env(wfdaemon, player_cache, filename:join(TestRoot, "player.term")),
    application:set_env(wfdaemon, local_socket, filename:join(TestRoot, "wfdaemon.sock")),
    application:set_env(wfdaemon, notification_settings_file,
                        filename:join(TestRoot, "notifications.json")),
    persistent_term:put({?MODULE, test_root}, TestRoot),
    application:set_env(wfcli, test_local_daemon, true),
    application:set_env(wfdaemon, daemon_enabled, true),
    application:set_env(wfdaemon, daemon_idle_shutdown, false),
    try
        case application:ensure_all_started(wfdaemon) of
            {ok, _} -> ok;
            {error, Reason} -> {error, Reason}
        end
    after
        _ = file:set_cwd(CallerCwd)
    end.

stop() ->
    application:unset_env(wfcli, test_local_daemon),
    _ = application:stop(wfdaemon),
    cleanup_test_root(persistent_term:get({?MODULE, test_root}, undefined)),
    persistent_term:erase({?MODULE, test_root}),
    application:unset_env(wfdaemon, player_cache),
    application:unset_env(wfdaemon, local_socket),
    application:unset_env(wfdaemon, notification_settings_file),
    ok.

cleanup_test_root(undefined) -> ok;
cleanup_test_root(TestRoot) ->
    _ = file:delete(filename:join(TestRoot, "player.term.tmp")),
    _ = file:delete(filename:join(TestRoot, "player.term")),
    _ = file:delete(filename:join(TestRoot, "notifications.json.tmp")),
    _ = file:delete(filename:join(TestRoot, "notifications.json")),
    _ = file:delete(filename:join(TestRoot, "wfdaemon.sock")),
    _ = file:del_dir(TestRoot),
    ok.
