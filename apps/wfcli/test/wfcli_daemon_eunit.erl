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
        ?assert(is_integer(maps:get(uptime_ms, Status)))
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
