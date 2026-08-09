%%%-------------------------------------------------------------------
%% EUnit tests for daemon process API.
%%%-------------------------------------------------------------------
-module(wfcli_daemon_eunit).

-include_lib("eunit/include/eunit.hrl").

status_request_returns_running_map_test() ->
    Started = setup_daemon(),
    try
        Status = wfcli_daemon:request(status),
        ?assertMatch(#{status := running,
                       node := _,
                       pid := _,
                       uptime_ms := _,
                       version := _,
                       otp_release := _,
                       flavor := _,
                       build := _}, Status),
        ?assert(is_pid(maps:get(pid, Status))),
        ?assert(is_integer(maps:get(uptime_ms, Status))),
        Paths = maps:get(paths, Status),
        ?assert(lists:keymember(assets, 1, Paths)),
        case maps:get(assets, Status) of
            #{cache_root := AssetRoot} ->
                ?assertEqual({assets, AssetRoot}, lists:keyfind(assets, 1, Paths));
            unavailable ->
                ?assertEqual({assets, wfcli_paths:cache_file("assets")},
                             lists:keyfind(assets, 1, Paths))
        end
    after
        cleanup_daemon(Started)
    end.

unknown_request_is_data_error_test() ->
    Started = setup_daemon(),
    try
        ?assertEqual({error, {unknown_request, bogus}}, wfcli_daemon:request(bogus))
    after
        cleanup_daemon(Started)
    end.

release_update_requires_name_test() ->
    Started = setup_daemon(),
    try
        ?assertEqual({error, release_name_required}, wfcli_daemon:request({update_release, []}))
    after
        cleanup_daemon(Started)
    end.

protocol_handshake_test() ->
    Started = setup_daemon(),
    try
        Reply = wfcli_daemon:request({hello, wfcli_daemon:protocol_version()}),
        ?assertEqual(true, maps:get(compatible, Reply)),
        ?assertEqual(wfcli_daemon:protocol_version(), maps:get(protocol, Reply)),
        ?assertEqual(wfcli_build:version(), maps:get(version, Reply)),
        ?assertEqual(wfcli_build:flavor(), maps:get(flavor, Reply)),
        ?assertEqual(64, byte_size(maps:get(build, Reply)))
    after
        cleanup_daemon(Started)
    end.

typed_hot_update_request_test() ->
    Started = setup_daemon(),
    try
        {ok, Bundles} = wfcli_hot_update:read_applications([wfcore, wfdaemon]),
        ?assertMatch({ok, #{loaded := _, unchanged := _, migrated := _}},
                     wfcli_daemon:request({hot_update, Bundles})),
        ?assert(is_pid(whereis(wfcli_daemon)))
    after
        cleanup_daemon(Started)
    end.

concurrent_hot_updates_are_rejected_test() ->
    Started = setup_daemon(),
    Test = self(),
    application:set_env(
      wfdaemon, daemon_hot_update_fun,
      fun(_Bundles) ->
          Test ! {hot_update_started, self()},
          receive continue ->
              {ok, #{loaded => [], unchanged => [], migrated => []}}
          end
      end),
    try
        Caller = spawn(fun() -> Test ! {hot_update_reply,
                                       wfcli_daemon:request({hot_update, []})} end),
        Worker = receive {hot_update_started, Pid} -> Pid after 1000 -> timeout end,
        ?assert(is_pid(Worker)),
        ?assertEqual({error, update_in_progress},
                     wfcli_daemon:request({hot_update, []})),
        Worker ! continue,
        receive
            {hot_update_reply, Reply} ->
                ?assertMatch({ok, #{loaded := [], unchanged := [], migrated := []}}, Reply)
        after 1000 ->
            exit(Caller, kill),
            error(hot_update_reply_timeout)
        end
    after
        application:unset_env(wfdaemon, daemon_hot_update_fun),
        cleanup_daemon(Started)
    end.

artifact_worker_down_clears_update_state_test() ->
    Monitor = make_ref(),
    State = #{started_at => 0, artifact_id => <<"old">>,
              artifact_update => #{artifact_id => <<"new">>, monitor => Monitor,
                                   pid => self()}},
    {noreply, Updated} =
        wfcli_daemon:handle_info({'DOWN', Monitor, process, self(), test_crash}, State),
    ?assertEqual(false, maps:get(artifact_update, Updated)).

legacy_artifact_update_state_is_cleared_test() ->
    State = #{started_at => 0, artifact_id => <<"old">>, artifact_update => true},
    {ok, Updated} = wfcli_daemon:code_change(undefined, State, undefined),
    ?assertEqual(false, maps:get(artifact_update, Updated)).

setup_daemon() ->
    case whereis(wfcli_daemon) of
        undefined ->
            {ok, _Pid} = wfcli_daemon:start_link(),
            started;
        _Pid ->
            already_running
    end.

cleanup_daemon(started) ->
    gen_server:stop(wfcli_daemon);
cleanup_daemon(already_running) ->
    ok.
