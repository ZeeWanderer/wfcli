%%%-------------------------------------------------------------------
%% EUnit tests for daemon control helpers that do not start distribution.
%%%-------------------------------------------------------------------
-module(wfcli_client_eunit).

-include_lib("eunit/include/eunit.hrl").

default_daemon_node_uses_wfdaemon_name_test() ->
    Node = atom_to_list(wfcli_client:daemon_node()),
    ?assertMatch("wfdaemon@" ++ _, Node).

compiled_version_matches_application_version_test() ->
    _ = application:load(wfcore),
    {ok, Version} = application:get_key(wfcore, vsn),
    ?assertEqual(Version, wfcli_build:version()).

release_script_candidates_include_rebar_outputs_test() ->
    Candidates = wfcli_client:release_script_candidates(),
    ?assert(lists:any(fun(Path) ->
                          string:find(Path, "_build/default/rel/wfdaemon/bin/wfdaemon") =/= nomatch
                      end, Candidates)),
    ?assert(lists:any(fun(Path) ->
                          string:find(
                            Path,
                            "_build/prod/rel/wfdaemon/bin/wfdaemon") =/= nomatch
                      end, Candidates)).

build_flavor_follows_staged_path_test() ->
    ?assertEqual(dev, wfcli_build:flavor_from_path("/repo/dev/bin/wfcli")),
    ?assertEqual(prod, wfcli_build:flavor_from_path("/repo/prod/bin/wfcli")).

brew_update_root_uses_stable_opt_prefix_test() ->
    ?assertEqual("/home/linuxbrew/.linuxbrew/opt/wfcli",
                 wfcli_build:brew_update_root(
                   "/home/linuxbrew/.linuxbrew/Cellar/wfcli/0.1.0")).

homebrew_install_follows_resolved_cellar_path_test() ->
    ?assert(wfcli_build:homebrew_install_from_path(
              "/home/linuxbrew/.linuxbrew/Cellar/wfcli/0.1.1/libexec/bin/wfcli")),
    ?assert(wfcli_build:homebrew_install_from_path(
              "/home/linuxbrew/.linuxbrew/opt/wfcli/bin/wfcli")),
    ?assertNot(wfcli_build:homebrew_install_from_path("/repo/prod/bin/wfcli")),
    ?assertNot(wfcli_build:homebrew_install_from_path(
                 "/home/linuxbrew/.linuxbrew/Cellar/other/0.1.1/bin/wfcli")).

release_environment_keeps_logs_out_of_release_test() ->
    Env = wfcli_client:release_environment(),
    ?assertEqual(
       filename:join(wfcli_paths:cache_dir(), "daemon-log"),
       proplists:get_value("RUNNER_LOG_DIR", Env)),
    ?assertEqual(wfcli_paths:state_file("erl_crash.dump"),
                 proplists:get_value("ERL_CRASH_DUMP", Env)),
    ?assertEqual(atom_to_list(wfcli_build:flavor()),
                 proplists:get_value("WFCLI_BUILD_FLAVOR", Env)),
    ?assertEqual(false, proplists:get_value("LD_PRELOAD", Env)),
    ?assertEqual(false, proplists:get_value("LD_LIBRARY_PATH", Env)),
    ?assertEqual(false, proplists:get_value("STEAM_RUNTIME", Env)),
    ?assertEqual(false, proplists:get_value("STEAM_RUNTIME_LIBRARY_PATH", Env)).

daemon_cli_known_commands_test() ->
    Known = wfcli_daemon_cli:known_commands(),
    ?assert(lists:member("status", Known)),
    ?assert(lists:member("start", Known)),
    ?assert(lists:member("stop", Known)),
    ?assert(lists:member("restart", Known)),
    ?assert(lists:member("autostart", Known)),
    ?assert(lists:member("update", Known)).

daemon_readiness_requires_registered_server_test() ->
    ?assertEqual(
       retry,
       wfcli_client:readiness_result(
         pong, {error, {daemon_call_failed, noproc}})),
    ?assertEqual(retry, wfcli_client:readiness_result(pang, not_called)),
    ?assertEqual(ready, wfcli_client:readiness_result(pong, {ok, #{status => running}})).

autostart_unit_runs_supervised_persistent_release_test() ->
    Unit = wfcli_autostart:unit_file(
             "/tmp/wf daemon/bin/wfdaemon", "/opt/erlang/bin:/usr/bin"),
    ?assertNotEqual(nomatch, binary:match(Unit, <<"Type=simple">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Unit, <<"WFCLI_DAEMON_IDLE_POLICY=persistent">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Unit, <<"ExecStart=\"/tmp/wf daemon/bin/wfdaemon\" foreground">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Unit, <<"Environment=\"PATH=/opt/erlang/bin:/usr/bin\"">>)),
    ?assertNotEqual(nomatch, binary:match(Unit, <<"WorkingDirectory=">>)),
    ?assertEqual(nomatch, binary:match(Unit, <<"WorkingDirectory=\"">>)),
    ?assertNotEqual(nomatch, binary:match(Unit, <<"ERL_CRASH_DUMP=">>)),
    ?assertNotEqual(nomatch, binary:match(Unit, <<"Restart=on-failure">>)).

protocol_mismatch_error_requests_matching_builds_test() ->
    Error = wfcli_client:format_error({protocol_mismatch, 3, 2}),
    ?assert(string:find(Error, "matching wfcli and wfdaemon builds") =/= nomatch).

matching_build_handshake_is_compatible_test() ->
    {ok, Build} = current_build_identity(),
    Reply = #{compatible => true, protocol => wfcli_protocol:version(), build => Build},
    ?assertEqual(ok, wfcli_client:handshake_compatibility(Reply, wfcli_protocol:version())).

legacy_handshake_requires_daemon_update_test() ->
    {ok, Build} = current_build_identity(),
    Reply = #{compatible => true, protocol => wfcli_protocol:version()},
    ?assertEqual({error, {daemon_build_mismatch, Build, undefined}},
                 wfcli_client:handshake_compatibility(Reply, wfcli_protocol:version())).

different_build_handshake_requires_daemon_update_test() ->
    {ok, Build} = current_build_identity(),
    Other = <<"different">>,
    Reply = #{compatible => true, protocol => wfcli_protocol:version(), build => Other},
    ?assertEqual({error, {daemon_build_mismatch, Build, Other}},
                 wfcli_client:handshake_compatibility(Reply, wfcli_protocol:version())).

different_flavor_handshake_requires_daemon_restart_test() ->
    OtherFlavor = case wfcli_build:flavor() of dev -> prod; prod -> dev end,
    Reply = #{compatible => true, protocol => wfcli_protocol:version(),
              flavor => OtherFlavor, build => <<"irrelevant">>},
    ?assertEqual({error, {daemon_flavor_mismatch, wfcli_build:flavor(), OtherFlavor}},
                 wfcli_client:handshake_compatibility(Reply, wfcli_protocol:version())).

query_errors_are_readable_test() ->
    ?assertEqual("bad syntax; unknown field",
                 wfcli_client:format_error(
                   {query_errors, ["bad syntax", "unknown field"]})).

timed_out_launcher_process_is_terminated_test() ->
    case os:find_executable("sleep") of
        false -> ok;
        Sleep ->
            Port = open_port(
                     {spawn_executable, Sleep},
                     [binary, exit_status, {args, ["60"]}]),
            ok = wfcli_client:terminate_port_process(Port),
            ?assertEqual(undefined, erlang:port_info(Port))
    end.

current_build_identity() ->
    {ok, Bundles} = wfcli_hot_update:read_applications([wfcore, wfdaemon]),
    wfcli_hot_update:build_identity(Bundles).
