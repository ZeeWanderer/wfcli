%%%-------------------------------------------------------------------
%% Local supervised daemon harness for CLI integration suites.
%%%-------------------------------------------------------------------
-module(wfcli_test_daemon).

-export([start/0, start/1, stop/0]).

start() ->
    TestRoot = filename:join(
                 "/tmp", "wfcli-test-" ++ os:getpid() ++ "-" ++
                     integer_to_list(erlang:unique_integer([positive]))),
    start(TestRoot).

start(TestRoot) ->
    {ok, CallerCwd} = file:get_cwd(),
    application:set_env(wfdaemon, player_cache, filename:join(TestRoot, "player.term")),
    application:set_env(wfdaemon, game_metadata_cache,
                        filename:join(TestRoot, "game-metadata.term")),
    application:set_env(wfdaemon, resolution_issues_file,
                        filename:join(TestRoot, "resolution-issues.json")),
    application:set_env(wfdaemon, local_socket, filename:join(TestRoot, "wfdaemon.sock")),
    application:set_env(wfdaemon, notification_settings_file,
                        filename:join(TestRoot, "notifications.json")),
    application:set_env(wfdaemon, market_account_file,
                        filename:join(TestRoot, "market-token")),
    application:set_env(wfdaemon, market_presence_file,
                        filename:join(TestRoot, "market-presence.json")),
    application:set_env(wfdaemon, build_store_file, filename:join(TestRoot, "builds.term")),
    application:set_env(wfdaemon, build_cache_file, filename:join(TestRoot, "builds.cache")),
    application:set_env(wfdaemon, incident_log_file, filename:join(TestRoot, "wfdaemon.log")),
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
    application:unset_env(wfdaemon, game_metadata_cache),
    application:unset_env(wfdaemon, resolution_issues_file),
    application:unset_env(wfdaemon, local_socket),
    application:unset_env(wfdaemon, notification_settings_file),
    application:unset_env(wfdaemon, market_account_file),
    application:unset_env(wfdaemon, market_presence_file),
    application:unset_env(wfdaemon, build_store_file),
    application:unset_env(wfdaemon, build_cache_file),
    application:unset_env(wfdaemon, incident_log_file),
    ok.

cleanup_test_root(undefined) -> ok;
cleanup_test_root(TestRoot) ->
    _ = file:delete(filename:join(TestRoot, "player.term.tmp")),
    _ = file:delete(filename:join(TestRoot, "player.term")),
    _ = file:delete(filename:join(TestRoot, "game-metadata.term.tmp")),
    _ = file:delete(filename:join(TestRoot, "game-metadata.term")),
    _ = file:delete(filename:join(TestRoot, "resolution-issues.json.tmp")),
    _ = file:delete(filename:join(TestRoot, "resolution-issues.json")),
    _ = file:delete(filename:join(TestRoot, "notifications.json.tmp")),
    _ = file:delete(filename:join(TestRoot, "notifications.json")),
    _ = file:delete(filename:join(TestRoot, "market-token.tmp")),
    _ = file:delete(filename:join(TestRoot, "market-token")),
    _ = file:delete(filename:join(TestRoot, "market-presence.json.tmp")),
    _ = file:delete(filename:join(TestRoot, "market-presence.json")),
    _ = file:delete(filename:join(TestRoot, "wfdaemon.sock")),
    _ = file:del_dir_r(TestRoot),
    ok.
