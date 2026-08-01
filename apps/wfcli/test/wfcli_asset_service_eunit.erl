%%%-------------------------------------------------------------------
%% EUnit coverage for daemon-owned catalog image caching.
%%%-------------------------------------------------------------------
-module(wfcli_asset_service_eunit).

-include_lib("eunit/include/eunit.hrl").

asset_service_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(_Root) -> [
         fun fetches_valid_asset_once/0,
         fun fetches_batch_concurrently/0,
         fun bounds_parallel_fetches/0,
         fun deduplicates_inflight_fetches/0,
         fun drops_dead_resolve_waiters/0,
         fun prewarms_without_refetching/0,
         fun accepts_market_sub_icon/0,
         fun accepts_mastery_rank_icon/0,
         fun rejects_untrusted_image_name/0,
         fun reloads_persisted_descriptor/0,
         fun removes_orphan_cache_objects/0
     ] end}.

setup() ->
    Root = filename:join(
             "/tmp", "wfcli-assets-" ++
             integer_to_list(erlang:unique_integer([positive]))),
    Counter = atomics:new(1, []),
    application:set_env(wfdaemon, asset_cache_dir, Root),
    application:set_env(wfdaemon, asset_workers, 2),
    application:set_env(wfdaemon, asset_test_counter, Counter),
    application:set_env(
      wfdaemon, asset_http_fun,
      fun(_Url, _Headers) ->
          atomics:add(Counter, 1, 1),
          {ok, 200, [{"etag", "\"fixture\""}], fixture_png()}
      end),
    {ok, _Pid} = wfcli_asset_service:start_link(),
    Root.

cleanup(Root) ->
    case whereis(wfcli_asset_service) of
        undefined -> ok;
        _Pid -> gen_server:stop(wfcli_asset_service)
    end,
    application:unset_env(wfdaemon, asset_cache_dir),
    application:unset_env(wfdaemon, asset_workers),
    application:unset_env(wfdaemon, asset_test_counter),
    application:unset_env(wfdaemon, asset_http_fun),
    _ = file:del_dir_r(Root),
    ok.

fetches_valid_asset_once() ->
    Request = [#{<<"id">> => <<"forma">>,
                 <<"image_name">> => <<"Forma2.png">>}],
    {ok, [First]} = wfcli_asset_service:resolve(Request),
    ?assertEqual(true, maps:get(<<"ok">>, First)),
    ?assert(filelib:is_file(binary_to_list(maps:get(<<"path">>, First)))),
    {ok, Counter} = application:get_env(wfdaemon, asset_test_counter),
    ?assertEqual(1, atomics:get(Counter, 1)),
    {ok, [Second]} = wfcli_asset_service:resolve(Request),
    ?assertEqual(maps:get(<<"digest">>, First), maps:get(<<"digest">>, Second)),
    ?assertEqual(1, atomics:get(Counter, 1)).

fetches_batch_concurrently() ->
    Test = self(),
    application:set_env(
      wfdaemon, asset_http_fun,
      fun(_Url, _Headers) ->
          Test ! {asset_fetch_started, self()},
          receive continue ->
              {ok, 200, [{"etag", "\"fixture\""}], fixture_png()}
          end
      end),
    Resolver = spawn(fun() ->
        Test ! {asset_batch_result, wfcli_asset_service:resolve([
            #{<<"id">> => <<"parallel-a">>, <<"image_name">> => <<"a.png">>},
            #{<<"id">> => <<"parallel-b">>, <<"image_name">> => <<"b.png">>}
        ])}
    end),
    First = receive {asset_fetch_started, Pid1} -> Pid1 after 1000 -> timeout end,
    Second = receive {asset_fetch_started, Pid2} -> Pid2 after 1000 -> timeout end,
    ?assert(is_pid(First)),
    ?assert(is_pid(Second)),
    First ! continue,
    Second ! continue,
    receive
        {asset_batch_result, {ok, Results}} -> ?assertEqual(2, length(Results))
    after 1000 ->
        error({asset_batch_timeout, Resolver})
    end,
    {ok, Counter} = application:get_env(wfdaemon, asset_test_counter),
    application:set_env(
      wfdaemon, asset_http_fun,
      fun(_Url, _Headers) ->
          atomics:add(Counter, 1, 1),
          {ok, 200, [{"etag", "\"fixture\""}], fixture_png()}
      end).

bounds_parallel_fetches() ->
    Test = self(),
    application:set_env(
      wfdaemon, asset_http_fun,
      fun(_Url, _Headers) ->
          Test ! {bounded_fetch_started, self()},
          receive continue -> {ok, 200, [], fixture_png()} end
      end),
    Resolver = spawn(fun() ->
        Test ! {bounded_result, wfcli_asset_service:resolve([
            #{<<"id">> => <<"bounded-a">>, <<"image_name">> => <<"bounded-a.png">>},
            #{<<"id">> => <<"bounded-b">>, <<"image_name">> => <<"bounded-b.png">>},
            #{<<"id">> => <<"bounded-c">>, <<"image_name">> => <<"bounded-c.png">>}
        ])}
    end),
    First = receive {bounded_fetch_started, Pid1} -> Pid1 after 1000 -> timeout end,
    Second = receive {bounded_fetch_started, Pid2} -> Pid2 after 1000 -> timeout end,
    ?assert(is_pid(First)),
    ?assert(is_pid(Second)),
    receive {bounded_fetch_started, _Pid} -> error(worker_limit_exceeded)
    after 100 -> ok
    end,
    First ! continue,
    Third = receive {bounded_fetch_started, Pid3} -> Pid3 after 1000 -> timeout end,
    ?assert(is_pid(Third)),
    Second ! continue,
    Third ! continue,
    receive
        {bounded_result, {ok, Results}} -> ?assertEqual(3, length(Results))
    after 1000 -> error({bounded_batch_timeout, Resolver})
    end,
    restore_http_fun().

deduplicates_inflight_fetches() ->
    Test = self(),
    application:set_env(
      wfdaemon, asset_http_fun,
      fun(_Url, _Headers) ->
          Test ! {dedupe_fetch_started, self()},
          receive continue -> {ok, 200, [], fixture_png()} end
      end),
    Request = [#{<<"id">> => <<"dedupe">>, <<"image_name">> => <<"dedupe.png">>}],
    _FirstResolver = spawn(fun() ->
        Test ! {dedupe_result, first, wfcli_asset_service:resolve(Request)}
    end),
    Worker = receive {dedupe_fetch_started, Pid} -> Pid after 1000 -> timeout end,
    ?assert(is_pid(Worker)),
    _SecondResolver = spawn(fun() ->
        Test ! {dedupe_result, second, wfcli_asset_service:resolve(Request)}
    end),
    receive {dedupe_fetch_started, _Pid} -> error(duplicate_fetch_started)
    after 100 -> ok
    end,
    Worker ! continue,
    receive {dedupe_result, first, {ok, [_]}} -> ok after 1000 -> error(first_timeout) end,
    receive {dedupe_result, second, {ok, [_]}} -> ok after 1000 -> error(second_timeout) end,
    restore_http_fun().

drops_dead_resolve_waiters() ->
    Test = self(),
    application:set_env(
      wfdaemon, asset_http_fun,
      fun(_Url, _Headers) ->
          Test ! {abandoned_fetch_started, self()},
          receive continue -> {ok, 200, [], fixture_png()} end
      end),
    Resolver = spawn(fun() ->
        wfcli_asset_service:resolve(
          [#{<<"id">> => <<"abandoned">>, <<"image_name">> => <<"abandoned.png">>}])
    end),
    Worker = receive {abandoned_fetch_started, Pid} -> Pid after 1000 -> timeout end,
    ?assert(is_pid(Worker)),
    exit(Resolver, kill),
    wait_for_status(waiting_calls, 0, 100),
    Worker ! continue,
    wait_until_idle(100),
    restore_http_fun().

prewarms_without_refetching() ->
    {ok, Counter} = application:get_env(wfdaemon, asset_test_counter),
    Before = atomics:get(Counter, 1),
    Request = [#{<<"id">> => <<"prewarm">>, <<"image_name">> => <<"prewarm.png">>}],
    ok = wfcli_asset_service:prewarm(Request),
    wait_until_idle(100),
    ?assertEqual(Before + 1, atomics:get(Counter, 1)),
    {ok, [Result]} = wfcli_asset_service:resolve(Request),
    ?assertEqual(true, maps:get(<<"ok">>, Result)),
    ?assertEqual(Before + 1, atomics:get(Counter, 1)).

accepts_market_sub_icon() ->
    {ok, [Result]} = wfcli_asset_service:resolve(
                       [#{<<"id">> => <<"prime-barrel">>,
                          <<"source">> => <<"market">>,
                          <<"image_name">> =>
                              <<"sub_icons/weapon/prime_barrel_128x128.png">>}]),
    ?assertEqual(true, maps:get(<<"ok">>, Result)).

accepts_mastery_rank_icon() ->
    application:set_env(
      wfdaemon, asset_http_fun,
      fun(_Url, _Headers) ->
          {ok, 200, [], <<"RIFF", 4:32/little, "WEBP", 0:32>>}
      end),
    {ok, [Result]} = wfcli_asset_service:resolve(
                       [#{<<"id">> => <<"mastery-rank:18">>,
                          <<"source">> => <<"mastery">>,
                          <<"image_name">> => <<"18.webp">>}]),
    ?assertEqual(true, maps:get(<<"ok">>, Result)),
    ?assertEqual(<<"image/webp">>, maps:get(<<"media_type">>, Result)),
    ?assertEqual(<<".webp">>,
                 filename:extension(maps:get(<<"path">>, Result))),
    restore_http_fun().

rejects_untrusted_image_name() ->
    {ok, [Result]} = wfcli_asset_service:resolve(
                       [#{<<"id">> => <<"bad">>,
                          <<"image_name">> => <<"../secret.png">>}]),
    ?assertEqual(false, maps:get(<<"ok">>, Result)).

reloads_persisted_descriptor() ->
    Before = wfcli_asset_service:status(),
    ok = gen_server:stop(wfcli_asset_service),
    {ok, _Pid} = wfcli_asset_service:start_link(),
    After = wfcli_asset_service:status(),
    ?assertEqual(maps:get(objects, Before), maps:get(objects, After)).

removes_orphan_cache_objects() ->
    {ok, Root} = application:get_env(wfdaemon, asset_cache_dir),
    Orphan = filename:join([Root, "objects", "orphan.png"]),
    ok = filelib:ensure_dir(Orphan),
    ok = file:write_file(Orphan, fixture_png()),
    wfcli_asset_service ! maintain_cache,
    wait_for_file_removal(Orphan, 100).

restore_http_fun() ->
    {ok, Counter} = application:get_env(wfdaemon, asset_test_counter),
    application:set_env(
      wfdaemon, asset_http_fun,
      fun(_Url, _Headers) ->
          atomics:add(Counter, 1, 1),
          {ok, 200, [{"etag", "\"fixture\""}], fixture_png()}
      end).

wait_until_idle(0) -> error(asset_service_busy);
wait_until_idle(Attempts) ->
    case wfcli_asset_service:status() of
        #{pending := 0, fetching := 0} -> ok;
        _ -> timer:sleep(10), wait_until_idle(Attempts - 1)
    end.

wait_for_status(Key, Expected, 0) ->
    ?assertEqual(Expected, maps:get(Key, wfcli_asset_service:status()));
wait_for_status(Key, Expected, Attempts) ->
    case maps:get(Key, wfcli_asset_service:status()) of
        Expected -> ok;
        _ -> timer:sleep(10), wait_for_status(Key, Expected, Attempts - 1)
    end.

wait_for_file_removal(Path, 0) -> ?assertNot(filelib:is_file(Path));
wait_for_file_removal(Path, Attempts) ->
    case filelib:is_file(Path) of
        false -> ok;
        true -> timer:sleep(10), wait_for_file_removal(Path, Attempts - 1)
    end.

fixture_png() ->
    base64:decode(
      <<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
        "YAAAAAYAAjCB0C8AAAAASUVORK5CYII=">>).
