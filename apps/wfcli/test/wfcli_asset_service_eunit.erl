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
         fun accepts_market_sub_icon/0,
         fun rejects_untrusted_image_name/0,
         fun reloads_persisted_descriptor/0
     ] end}.

setup() ->
    Root = filename:join(
             "/tmp", "wfcli-assets-" ++
             integer_to_list(erlang:unique_integer([positive]))),
    Counter = atomics:new(1, []),
    application:set_env(wfdaemon, asset_cache_dir, Root),
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

accepts_market_sub_icon() ->
    {ok, [Result]} = wfcli_asset_service:resolve(
                       [#{<<"id">> => <<"prime-barrel">>,
                          <<"source">> => <<"market">>,
                          <<"image_name">> =>
                              <<"sub_icons/weapon/prime_barrel_128x128.png">>}]),
    ?assertEqual(true, maps:get(<<"ok">>, Result)).

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

fixture_png() ->
    base64:decode(
      <<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
        "YAAAAAYAAjCB0C8AAAAASUVORK5CYII=">>).
