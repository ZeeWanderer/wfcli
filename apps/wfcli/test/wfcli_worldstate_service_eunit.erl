%%%-------------------------------------------------------------------
%% EUnit tests for persistent worldstate service.
%%%-------------------------------------------------------------------
-module(wfcli_worldstate_service_eunit).

-include_lib("eunit/include/eunit.hrl").

autostart_environment_disables_idle_shutdown_test() ->
    ?assertEqual(false, wfcli_worldstate_service:initial_idle_shutdown("persistent", true)),
    ?assertEqual(true, wfcli_worldstate_service:initial_idle_shutdown(false, true)).

queued_one_shot_test() ->
    Started = setup_service(),
    try
        Request = (base_request())#{type_filter => fissure, query => undefined},
        {ok, Ref} = wfcli_worldstate_service:submit(self(), Request),
        receive
            {wfcli_daemon, Ref, {ok, Result}} ->
                ?assertEqual(entries, maps:get(kind, Result)),
                ?assert(length(maps:get(entries, Result)) > 0)
        after 5000 ->
            ?assert(false)
        end
    after
        cleanup_service(Started)
    end.

invalid_query_is_rejected_by_daemon_test() ->
    Started = setup_service(),
    try
        Request = (base_request())#{type_filter => alert, query => "foo OR"},
        ?assertMatch({error, {query_errors, [_ | _]}},
                     wfcli_worldstate_service:submit(self(), Request))
    after
        cleanup_service(Started)
    end.

unknown_query_field_is_rejected_by_daemon_test() ->
    Started = setup_service(),
    try
        Request = (base_request())#{type_filter => alert, query => "no_such_field=Corpus"},
        ?assertMatch({error, {query_errors, [_ | _]}},
                     wfcli_worldstate_service:submit(self(), Request))
    after
        cleanup_service(Started)
    end.

invalid_watch_query_is_rejected_by_daemon_test() ->
    Started = setup_service(),
    try
        Request = (base_request())#{
            specs => [#{label => "alerts", type_filter => alert, query => "foo OR"}],
            interval => 60},
        ?assertMatch({error, {query_errors, [_ | _]}},
                     wfcli_worldstate_service:subscribe(self(), Request))
    after
        cleanup_service(Started)
    end.

memory_reuse_reports_delivery_and_origin_test() ->
    Started = setup_service(),
    try
        Request = (base_request())#{type_filter => alert, query => undefined},
        First = submit_result(Request),
        ?assertEqual(cached, maps:get(source, First)),
        ?assertEqual(cached, maps:get(snapshot_origin, First)),
        Second = submit_result(Request),
        ?assertEqual(memory, maps:get(source, Second)),
        ?assertEqual(cached, maps:get(snapshot_origin, Second)),
        ?assert(maps:get(snapshot_age_ms, Second) >= 0)
    after
        cleanup_service(Started)
    end.

one_cycle_watch_subscription_test() ->
    Started = setup_service(),
    try
        Request = (base_request())#{
            specs => [#{label => "fissures", type_filter => fissure, query => undefined}],
            interval => 60,
            once => true,
            always => false
        },
        {ok, Ref} = wfcli_worldstate_service:subscribe(self(), Request),
        receive
            {wfcli_daemon, Ref, {ok, Update}} ->
                ?assertEqual(watch, maps:get(kind, Update)),
                [Spec] = maps:get(specs, Update),
                ?assertEqual("fissures", maps:get(label, Spec)),
                ?assert(length(maps:get(entries, Spec)) > 0)
        after 5000 ->
            ?assert(false)
        end
    after
        cleanup_service(Started)
    end.

concurrent_one_shots_share_fetch_test() ->
    ensure_service_stopped(),
    TestPid = self(),
    FetchFun = fun() ->
        TestPid ! {fetch_started, self()},
        receive continue -> file:read_file(fixture("worldstate_sample.json")) end
    end,
    application:set_env(wfdaemon, daemon_idle_shutdown, false),
    application:set_env(wfdaemon, daemon_worldstate_fetch_fun, FetchFun),
    {ok, _Pid} = wfcli_worldstate_service:start_link(),
    Cache = filename:join("/tmp", "wfcli-service-singleflight.json"),
    _ = file:delete(Cache),
    try
        Request = #{source => worldstate,
                    opts => #{cache => Cache, ttl => 60, refresh => true,
                              resolve_items => false, raw => true, search_raw => true},
                    type_filter => alert, query => undefined, mode => list},
        {ok, Ref1} = wfcli_worldstate_service:submit(self(), Request),
        Worker = receive {fetch_started, FetchPid} -> FetchPid after 1000 -> ?assert(false) end,
        {ok, Ref2} = wfcli_worldstate_service:submit(self(), Request),
        Worker ! continue,
        receive {wfcli_daemon, Ref1, {ok, _}} -> ok after 5000 -> ?assert(false) end,
        receive {wfcli_daemon, Ref2, {ok, _}} -> ok after 5000 -> ?assert(false) end,
        receive {fetch_started, _Other} -> ?assert(false) after 100 -> ok end
    after
        gen_server:stop(wfcli_worldstate_service),
        application:unset_env(wfdaemon, daemon_worldstate_fetch_fun),
        _ = file:delete(Cache)
    end.

fetch_worker_crash_is_reported_without_killing_service_test() ->
    ensure_service_stopped(),
    Cache = filename:join(
              "/tmp", "wfcli-fetch-crash-" ++
                      integer_to_list(erlang:unique_integer([positive])) ++ ".json"),
    TestPid = self(),
    FetchFun = fun() ->
        TestPid ! {fetch_worker_started, self()},
        receive stop -> {error, stopped} end
    end,
    application:set_env(wfdaemon, daemon_idle_shutdown, false),
    application:set_env(wfdaemon, daemon_worldstate_fetch_fun, FetchFun),
    {ok, Pid} = wfcli_worldstate_service:start_link(),
    try
        Request = #{source => worldstate,
                    opts => #{cache => Cache, ttl => 60, refresh => true,
                              resolve_items => false, raw => true, search_raw => true},
                    type_filter => alert, query => undefined, mode => list},
        {ok, Ref} = wfcli_worldstate_service:submit(self(), Request),
        Worker = receive {fetch_worker_started, FetchPid} -> FetchPid
                 after 1000 -> ?assert(false)
                 end,
        exit(Worker, kill),
        receive
            {wfcli_daemon, Ref, {error, {fetch_worker_down, killed}}} -> ok
        after 1000 ->
            ?assert(false)
        end,
        ?assert(is_process_alive(Pid))
    after
        gen_server:stop(Pid),
        application:unset_env(wfdaemon, daemon_worldstate_fetch_fun),
        _ = file:delete(Cache),
        _ = file:delete(Cache ++ ".lock")
    end.

teshin_one_shot_is_calculated_without_worldstate_test() ->
    Started = setup_service(),
    try
        Request = #{source => teshin, opts => #{}, type_filter => teshin,
                    inventory => teshin, query => undefined, mode => list},
        Result = submit_result(Request),
        ?assertEqual(inventory, maps:get(kind, Result)),
        ?assertEqual(teshin, maps:get(inventory, Result)),
        ?assertEqual(calculated, maps:get(source, Result)),
        ?assertEqual(20, length(maps:get(entries, Result)))
    after
        cleanup_service(Started)
    end.

refreshing_watch_waits_for_fetch_test() ->
    ensure_service_stopped(),
    TestPid = self(),
    FetchFun = fun() ->
        TestPid ! {fetch_started, self()},
        receive continue -> file:read_file(fixture("worldstate_sample.json")) end
    end,
    Cache = filename:join(
              "/tmp", "wfcli-watch-refresh-" ++
                      integer_to_list(erlang:unique_integer([positive])) ++ ".json"),
    {ok, FixtureBin} = file:read_file(fixture("worldstate_sample.json")),
    ok = file:write_file(Cache, FixtureBin),
    application:set_env(wfdaemon, daemon_idle_shutdown, false),
    application:unset_env(wfdaemon, daemon_worldstate_fetch_fun),
    {ok, _Pid} = wfcli_worldstate_service:start_link(),
    try
        Opts = #{cache => Cache, ttl => 999999999,
                 resolve_items => false, raw => true, search_raw => true},
        Request = #{source => worldstate, opts => Opts,
                    type_filter => alert, query => undefined, mode => list},
        ?assertEqual(cached, maps:get(source, submit_result(Request))),
        application:set_env(wfdaemon, daemon_worldstate_fetch_fun, FetchFun),
        Watch = Request#{opts := Opts#{refresh => true},
                         specs => [#{label => "alerts", type_filter => alert,
                                     query => undefined}],
                         interval => 60, once => true, always => false},
        {ok, Ref} = wfcli_worldstate_service:subscribe(self(), Watch),
        Worker = receive {fetch_started, FetchPid} -> FetchPid
                 after 1000 -> ?assert(false)
                 end,
        receive
            {wfcli_daemon, Ref, _Early} -> ?assert(false)
        after 50 -> ok
        end,
        Worker ! continue,
        receive
            {wfcli_daemon, Ref, {ok, Update}} ->
                ?assertEqual(fetched, maps:get(source, Update)),
                ?assertEqual(fetched, maps:get(snapshot_origin, Update))
        after 5000 ->
            ?assert(false)
        end
    after
        gen_server:stop(wfcli_worldstate_service),
        application:unset_env(wfdaemon, daemon_worldstate_fetch_fun),
        _ = file:delete(Cache),
        _ = file:delete(Cache ++ ".lock")
    end.

idle_timeout_notifies_test() ->
    ensure_service_stopped(),
    application:set_env(wfdaemon, daemon_idle_shutdown, true),
    application:set_env(wfdaemon, daemon_idle_timeout_ms, 20),
    application:set_env(wfdaemon, daemon_idle_notify_pid, self()),
    {ok, Pid} = wfcli_worldstate_service:start_link(),
    try
        receive
            {wfcli_daemon_idle, Pid} -> ok
        after 1000 ->
            ?assert(false)
        end
    after
        gen_server:stop(Pid),
        application:unset_env(wfdaemon, daemon_idle_notify_pid),
        application:set_env(wfdaemon, daemon_idle_shutdown, false),
        application:set_env(wfdaemon, daemon_idle_timeout_ms, 600000)
    end.

runtime_idle_policy_test() ->
    ensure_service_stopped(),
    application:set_env(wfdaemon, daemon_idle_shutdown, true),
    application:set_env(wfdaemon, daemon_idle_timeout_ms, 200),
    application:set_env(wfdaemon, daemon_idle_notify_pid, self()),
    {ok, Pid} = wfcli_worldstate_service:start_link(),
    try
        ok = wfcli_worldstate_service:set_idle_policy(persistent),
        ?assertMatch(#{idle_policy := persistent}, wfcli_worldstate_service:status()),
        receive
            {wfcli_daemon_idle, Pid} -> ?assert(false)
        after 60 ->
            ok
        end,
        ok = wfcli_worldstate_service:set_idle_policy(idle),
        ?assertMatch(#{idle_policy := idle, idle_timeout_ms := 200},
                     wfcli_worldstate_service:status()),
        ok = wfcli_worldstate_service:set_idle_policy(persistent),
        ok = wfcli_worldstate_service:set_idle_policy({idle, 20}),
        ?assertMatch(#{idle_policy := idle, idle_timeout_ms := 20},
                     wfcli_worldstate_service:status()),
        receive
            {wfcli_daemon_idle, Pid} -> ok
        after 1000 ->
            ?assert(false)
        end
    after
        gen_server:stop(Pid),
        application:unset_env(wfdaemon, daemon_idle_notify_pid),
        application:set_env(wfdaemon, daemon_idle_shutdown, false),
        application:set_env(wfdaemon, daemon_idle_timeout_ms, 600000)
    end.

external_activity_is_counted_per_owner_test() ->
    Started = setup_service(),
    try
        ok = wfcli_worldstate_service:activity_start(),
        ok = wfcli_worldstate_service:activity_start(),
        ?assertMatch(#{external_activity := 2}, wfcli_worldstate_service:status()),
        ok = wfcli_worldstate_service:activity_end(),
        ?assertMatch(#{external_activity := 1}, wfcli_worldstate_service:status()),
        ok = wfcli_worldstate_service:activity_end(),
        ?assertMatch(#{external_activity := 0}, wfcli_worldstate_service:status())
    after
        cleanup_service(Started)
    end.

external_activity_is_released_when_owner_dies_test() ->
    Started = setup_service(),
    try
        Parent = self(),
        Owner = spawn(fun() ->
            ok = wfcli_worldstate_service:activity_start(),
            #{external_activity := 1} = wfcli_worldstate_service:status(),
            Parent ! activity_held,
            receive stop -> ok end
        end),
        receive activity_held -> ok after 1000 -> ?assert(false) end,
        exit(Owner, kill),
        await_external_activity(0, 20)
    after
        cleanup_service(Started)
    end.

code_change_clears_unowned_legacy_activity_test() ->
    Legacy = #{external_activity => 2},
    {ok, State} = wfcli_worldstate_service:code_change(old, Legacy, undefined),
    ?assertEqual(#{}, maps:get(external_activity, State)),
    ?assertEqual(#{}, maps:get(activity_monitors, State)).

base_request() ->
    #{source => worldstate,
      opts => #{cache => fixture("worldstate_sample.json"),
                ttl => 999999999,
                resolve_items => false,
                raw => true,
                search_raw => true},
      mode => list}.

submit_result(Request) ->
    {ok, Ref} = wfcli_worldstate_service:submit(self(), Request),
    receive
        {wfcli_daemon, Ref, {ok, Result}} -> Result
    after 5000 ->
        ?assert(false)
    end.

await_external_activity(Expected, Attempts) ->
    case maps:get(external_activity, wfcli_worldstate_service:status()) of
        Expected -> ok;
        _ when Attempts > 0 ->
            timer:sleep(10),
            await_external_activity(Expected, Attempts - 1);
        Actual ->
            ?assertEqual(Expected, Actual)
    end.

fixture(Name) ->
    filename:join(["apps", "wfcli", "test", "fixtures", Name]).

setup_service() ->
    application:set_env(wfdaemon, daemon_idle_shutdown, false),
    application:unset_env(wfdaemon, daemon_idle_notify_pid),
    application:unset_env(wfdaemon, daemon_worldstate_fetch_fun),
    case whereis(wfcli_worldstate_service) of
        undefined ->
            {ok, _Pid} = wfcli_worldstate_service:start_link(),
            started;
        _Pid -> already_running
    end.

cleanup_service(started) ->
    gen_server:stop(wfcli_worldstate_service);
cleanup_service(already_running) ->
    ok.

ensure_service_stopped() ->
    case whereis(wfcli_worldstate_service) of
        undefined -> ok;
        _Pid -> gen_server:stop(wfcli_worldstate_service)
    end.
