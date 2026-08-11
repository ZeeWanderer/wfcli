%%%-------------------------------------------------------------------
%% EUnit integration coverage for owner-only Unix socket handshake.
%%%-------------------------------------------------------------------
-module(wfcli_local_api_eunit).

-include_lib("eunit/include/eunit.hrl").

unix_socket_lifecycle_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(State) -> fun() -> lifecycle(State) end end}.

setup() ->
    Root = filename:join(
             "/tmp", "wfcli-local-api-" ++ os:getpid() ++ "-" ++
                 integer_to_list(erlang:unique_integer([positive]))),
    SocketPath = filename:join(Root, "wfdaemon.sock"),
    CachePath = filename:join(Root, "player.term"),
    MarketCache = filename:join(Root, "market.term"),
    AssetCache = filename:join(Root, "assets"),
    NotificationSettings = filename:join(Root, "notifications.json"),
    MarketToken = filename:join(Root, "market-token"),
    MarketPresence = filename:join(Root, "market-presence.json"),
    application:set_env(wfdaemon, local_socket, SocketPath),
    application:set_env(wfdaemon, player_cache, CachePath),
    application:set_env(wfdaemon, market_cache, MarketCache),
    application:set_env(wfdaemon, market_request_interval_ms, 0),
    application:set_env(wfdaemon, market_http_fun, fun market_http/2),
    application:set_env(wfdaemon, asset_cache_dir, AssetCache),
    application:set_env(wfdaemon, notification_settings_file, NotificationSettings),
    application:set_env(wfdaemon, market_account_file, MarketToken),
    application:set_env(wfdaemon, market_presence_file, MarketPresence),
    application:set_env(wfdaemon, local_request_workers, 2),
    application:set_env(wfdaemon, local_request_global_workers, 2),
    application:set_env(wfdaemon, daemon_idle_shutdown, false),
    {ok, _Worldstate} = wfcli_worldstate_service:start_link(),
    {ok, _Player} = wfcli_player_service:start_link(),
    {ok, _MarketLimiter} = wfcli_market_limiter:start_link(),
    {ok, _Market} = wfcli_market_service:start_link(),
    {ok, _MarketAccount} = wfcli_market_account_service:start_link(),
    {ok, _MarketPresence} = wfcli_market_presence_service:start_link(),
    {ok, _Assets} = wfcli_asset_service:start_link(),
    {ok, _Notifications} = wfcli_notification_service:start_link(),
    {ok, _Api} = wfcli_local_api:start_link(),
    #{root => Root, socket => SocketPath, cache => CachePath,
      market_cache => MarketCache, market_token => MarketToken,
      market_presence => MarketPresence,
      notification_settings => NotificationSettings}.

cleanup(#{root := Root, socket := SocketPath, cache := CachePath,
          market_cache := MarketCache, market_token := MarketToken,
          market_presence := MarketPresence,
          notification_settings := NotificationSettings}) ->
    gen_server:stop(wfcli_local_api),
    gen_server:stop(wfcli_notification_service),
    gen_server:stop(wfcli_asset_service),
    gen_server:stop(wfcli_market_presence_service),
    gen_server:stop(wfcli_market_account_service),
    gen_server:stop(wfcli_market_service),
    gen_server:stop(wfcli_market_limiter),
    gen_server:stop(wfcli_player_service),
    gen_server:stop(wfcli_worldstate_service),
    application:unset_env(wfdaemon, local_socket),
    application:unset_env(wfdaemon, player_cache),
    application:unset_env(wfdaemon, market_cache),
    application:unset_env(wfdaemon, market_request_interval_ms),
    application:unset_env(wfdaemon, market_http_fun),
    application:unset_env(wfdaemon, asset_cache_dir),
    application:unset_env(wfdaemon, notification_settings_file),
    application:unset_env(wfdaemon, market_account_file),
    application:unset_env(wfdaemon, market_presence_file),
    application:unset_env(wfdaemon, local_request_workers),
    application:unset_env(wfdaemon, local_request_global_workers),
    application:unset_env(wfdaemon, asset_http_fun),
    application:unset_env(wfdaemon, daemon_idle_shutdown),
    _ = file:delete(SocketPath),
    _ = file:delete(CachePath),
    _ = file:delete(CachePath ++ ".tmp"),
    _ = file:delete(MarketCache),
    _ = file:delete(MarketCache ++ ".tmp"),
    _ = file:delete(NotificationSettings),
    _ = file:delete(NotificationSettings ++ ".tmp"),
    _ = file:delete(MarketToken),
    _ = file:delete(MarketToken ++ ".tmp"),
    _ = file:delete(MarketPresence),
    _ = file:delete(MarketPresence ++ ".tmp"),
    _ = file:del_dir_r(Root),
    ok.

lifecycle(#{socket := SocketPath}) ->
    request_player_metadata_subscription(SocketPath),
    TestSocket = connect_client(SocketPath, <<"test">>, #{}),
    ?assertMatch(#{external_activity := 0}, wfcli_worldstate_service:status()),
    request_market_resolve(TestSocket),
    request_market_describe(TestSocket),
    reject_invalid_market_resolve(TestSocket),
    request_market_account(TestSocket),
    request_market_presence(TestSocket),
    reject_invalid_market_order(TestSocket),
    route_market_order_mutations(TestSocket),
    reject_invalid_relic_limit(TestSocket),
    request_market_quote(TestSocket),
    request_market_variant_quote(TestSocket),
    request_cached_market_quote(TestSocket),
    request_notification_settings(TestSocket),
    slow_asset_does_not_block_dataset(TestSocket),
    local_request_limit_queues_excess_work(TestSocket),
    global_local_request_limit_queues_other_clients(TestSocket, SocketPath),
    request_asset_cache_controls(TestSocket),
    ok = socket:close(TestSocket),

    GuiSocket = connect_client(
                  SocketPath, <<"wfgui">>,
                  #{<<"pid">> => 1000, <<"mode">> => <<"desktop">>}),
    await_external_activity(1, 20),
    ok = socket:close(GuiSocket),
    await_external_activity(0, 20),

    CompanionSocket1 = connect_client(
                         SocketPath, <<"wfcompanion">>,
                         #{<<"pid">> => 1001, <<"mode">> => <<"standalone">>}),
    await_external_activity(1, 20),
    publish_game_running(CompanionSocket1),
    ?assertMatch(#{game_active := true}, wfcli_player_service:status()),
    ?assertMatch(#{external_activity := 1}, wfcli_worldstate_service:status()),
    CompanionSocket2 = connect_client(
                         SocketPath, <<"wfcompanion">>,
                         #{<<"pid">> => 1002, <<"mode">> => <<"launch">>}),
    await_external_activity(2, 20),
    #{companions := 2, companion_details := Details} = wfcli_local_api:status(),
    ?assertEqual([<<"launch">>, <<"standalone">>],
                 lists:sort([maps:get(mode, Detail) || Detail <- Details])),
    ?assertEqual([1001, 1002], lists:sort([maps:get(os_pid, Detail) || Detail <- Details])),
    ok = socket:close(CompanionSocket1),
    await_external_activity(1, 20),
    ok = socket:close(CompanionSocket2),
    await_external_activity(0, 20).

request_asset_cache_controls(Socket) ->
    Status = #{<<"op">> => <<"asset_cache_status">>, <<"id">> => 40},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Status)),
    {ok, StatusLine} = socket:recv(Socket, 0, 1000),
    {ok, StatusReply} = wfcli_local_protocol:decode(string:trim(StatusLine)),
    ?assertEqual(true, maps:get(<<"ok">>, StatusReply)),
    StatusData = maps:get(<<"data">>, StatusReply),
    ?assert(is_integer(maps:get(<<"bytes">>, StatusData))),
    ?assert(is_binary(maps:get(<<"cache_root">>, StatusData))),

    Clear = #{<<"op">> => <<"asset_cache_clear">>, <<"id">> => 41},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Clear)),
    {ok, ClearLine} = socket:recv(Socket, 0, 1000),
    {ok, ClearReply} = wfcli_local_protocol:decode(string:trim(ClearLine)),
    ?assertEqual(true, maps:get(<<"ok">>, ClearReply)),
    ClearData = maps:get(<<"data">>, ClearReply),
    ?assertEqual(0, maps:get(<<"objects">>, ClearData)),
    ?assertEqual(0, maps:get(<<"bytes">>, ClearData)).

slow_asset_does_not_block_dataset(Socket) ->
    Test = self(),
    application:set_env(
      wfdaemon, asset_http_fun,
      fun(_Url, _Headers) ->
          Test ! {asset_fetch_started, self()},
          receive continue ->
              {ok, 200, [{"content-type", "image/png"}],
               <<16#89, "PNG", 13, 10, 26, 10, 0>>}
          end
      end),
    AssetRequest = #{<<"op">> => <<"asset_resolve">>, <<"id">> => 10,
                     <<"assets">> => [#{<<"id">> => <<"test">>,
                                         <<"image_name">> => <<"test.png">>}]},
    ok = socket:send(Socket, wfcli_local_protocol:encode(AssetRequest)),
    AssetWorker = receive
        {asset_fetch_started, Pid} -> Pid
    after 1000 ->
        error(asset_fetch_not_started)
    end,
    GetRequest = #{<<"op">> => <<"get">>, <<"id">> => 11,
                   <<"dataset">> => <<"daemon">>},
    ok = socket:send(Socket, wfcli_local_protocol:encode(GetRequest)),
    {ok, GetLine} = socket:recv(Socket, 0, 1000),
    {ok, GetReply} = wfcli_local_protocol:decode(string:trim(GetLine)),
    ?assertEqual(11, maps:get(<<"id">>, GetReply)),
    ?assertEqual(true, maps:get(<<"ok">>, GetReply)),
    AssetWorker ! continue,
    {ok, AssetLine} = socket:recv(Socket, 0, 1000),
    {ok, AssetReply} = wfcli_local_protocol:decode(string:trim(AssetLine)),
    ?assertEqual(10, maps:get(<<"id">>, AssetReply)),
    ?assertEqual(true, maps:get(<<"ok">>, AssetReply)),
    application:unset_env(wfdaemon, asset_http_fun).

local_request_limit_queues_excess_work(Socket) ->
    Test = self(),
    application:set_env(
      wfdaemon, asset_http_fun,
      fun(_Url, _Headers) ->
          Test ! {local_asset_started, self()},
          receive continue ->
              {ok, 200, [{"content-type", "image/png"}],
               <<16#89, "PNG", 13, 10, 26, 10, 0>>}
          end
      end),
    lists:foreach(
      fun(Id) ->
          Name = <<"local-", (integer_to_binary(Id))/binary, ".png">>,
          Request = #{<<"op">> => <<"asset_resolve">>, <<"id">> => Id,
                      <<"assets">> => [#{<<"id">> => integer_to_binary(Id),
                                          <<"image_name">> => Name}]},
          ok = socket:send(Socket, wfcli_local_protocol:encode(Request))
      end,
      [20, 21, 22]),
    First = receive {local_asset_started, Pid1} -> Pid1 after 1000 -> timeout end,
    Second = receive {local_asset_started, Pid2} -> Pid2 after 1000 -> timeout end,
    ?assert(is_pid(First)),
    ?assert(is_pid(Second)),
    receive {local_asset_started, _Pid} -> error(local_request_limit_exceeded)
    after 100 -> ok
    end,
    First ! continue,
    Third = receive {local_asset_started, Pid3} -> Pid3 after 1000 -> timeout end,
    ?assert(is_pid(Third)),
    Second ! continue,
    Third ! continue,
    ?assertEqual([20, 21, 22], lists:sort(recv_reply_ids(Socket, 3, <<>>, []))),
    application:unset_env(wfdaemon, asset_http_fun).

global_local_request_limit_queues_other_clients(Socket, SocketPath) ->
    Other = connect_client(SocketPath, <<"test">>, #{}),
    Test = self(),
    application:set_env(
      wfdaemon, asset_http_fun,
      fun(_Url, _Headers) ->
          Test ! {global_asset_started, self()},
          receive continue ->
              {ok, 200, [{"content-type", "image/png"}],
               <<16#89, "PNG", 13, 10, 26, 10, 0>>}
          end
      end),
    send_asset_request(Socket, 30, <<"global-30.png">>),
    send_asset_request(Socket, 31, <<"global-31.png">>),
    First = receive {global_asset_started, Pid1} -> Pid1 after 1000 -> timeout end,
    Second = receive {global_asset_started, Pid2} -> Pid2 after 1000 -> timeout end,
    ?assert(is_pid(First)),
    ?assert(is_pid(Second)),
    send_asset_request(Other, 32, <<"global-32.png">>),
    receive {global_asset_started, _Pid} -> error(global_local_request_limit_exceeded)
    after 100 -> ok
    end,
    First ! continue,
    Third = receive {global_asset_started, Pid3} -> Pid3 after 1000 -> timeout end,
    ?assert(is_pid(Third)),
    Second ! continue,
    Third ! continue,
    ?assertEqual([30, 31], lists:sort(recv_reply_ids(Socket, 2, <<>>, []))),
    ?assertEqual([32], recv_reply_ids(Other, 1, <<>>, [])),
    ok = socket:close(Other),
    application:unset_env(wfdaemon, asset_http_fun).

send_asset_request(Socket, Id, Name) ->
    Request = #{<<"op">> => <<"asset_resolve">>, <<"id">> => Id,
                <<"assets">> => [#{<<"id">> => integer_to_binary(Id),
                                    <<"image_name">> => Name}]},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request)).

recv_reply_ids(_Socket, Count, _Buffer, Ids) when length(Ids) >= Count -> Ids;
recv_reply_ids(Socket, Count, Buffer, Ids) ->
    {ok, Data} = socket:recv(Socket, 0, 1000),
    Parts = binary:split(<<Buffer/binary, Data/binary>>, <<"\n">>, [global]),
    [Rest | ReversedLines] = lists:reverse(Parts),
    Lines = lists:reverse(ReversedLines),
    NewIds = [maps:get(<<"id">>, Reply)
              || Line <- Lines, Line =/= <<>>,
                 {ok, Reply} <- [wfcli_local_protocol:decode(Line)]],
    recv_reply_ids(Socket, Count, Rest, NewIds ++ Ids).

connect_client(SocketPath, Client, Extra) ->
    {ok, Socket} = socket:open(local, stream, default),
    ok = socket:connect(Socket, #{family => local, path => SocketPath}),
    Hello = maps:merge(
              #{<<"op">> => <<"hello">>, <<"id">> => 1,
                <<"protocol">> => wfcli_local_protocol:protocol_version(),
                <<"client">> => Client, <<"version">> => <<"test">>},
              Extra),
    ok = socket:send(Socket, wfcli_local_protocol:encode(Hello)),
    {ok, ReplyLine} = socket:recv(Socket, 0, 5000),
    {ok, Reply} = wfcli_local_protocol:decode(string:trim(ReplyLine)),
    ?assertEqual(true, maps:get(<<"ok">>, Reply)),
    ?assertEqual(1, maps:get(<<"id">>, Reply)),
    ?assert(lists:member(<<"market.resolve">>, maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"market.describe">>, maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"market.account">>, maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"market.orders">>, maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"market.presence">>, maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"market.quote.variant">>,
                         maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"dataset.subscribe.metadata">>,
                         maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"relic.recommendations">>,
                         maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"relic.planner">>, maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"worldstate.activity">>, maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"player.foundry">>, maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"player.inventory">>, maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"player.mastery">>, maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"asset.cache">>, maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"notifications.fissures">>,
                         maps:get(<<"capabilities">>, Reply))),
    ?assert(lists:member(<<"asset.resolve">>, maps:get(<<"capabilities">>, Reply))),
    Socket.

request_player_metadata_subscription(SocketPath) ->
    Socket = connect_client(SocketPath, <<"test">>, #{}),
    Request = #{<<"op">> => <<"subscribe">>, <<"id">> => 2,
                <<"dataset">> => <<"player">>, <<"include_data">> => false},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
    {ok, InitialLine} = socket:recv(Socket, 0, 5000),
    {ok, Initial} = wfcli_local_protocol:decode(string:trim(InitialLine)),
    InitialData = maps:get(<<"data">>, Initial),
    ?assertEqual(true, maps:get(<<"ok">>, Initial)),
    ?assert(maps:is_key(<<"revision">>, InitialData)),
    ?assertNot(maps:is_key(<<"data">>, InitialData)),

    {ok, _} = wfcli_player_service:publish(
                <<"collector">>, #{<<"inventory_active">> => true}),
    {ok, CollectorLine} = socket:recv(Socket, 0, 5000),
    {ok, CollectorEvent} = wfcli_local_protocol:decode(string:trim(CollectorLine)),
    ?assertEqual(<<"collector">>, maps:get(<<"source">>, CollectorEvent)),
    {ok, Snapshot} = wfcli_player_service:publish(
                       <<"inventory">>, #{<<"schema">> => 1}),
    {ok, EventLine} = socket:recv(Socket, 0, 5000),
    {ok, Event} = wfcli_local_protocol:decode(string:trim(EventLine)),
    EventData = maps:get(<<"data">>, Event),
    ?assertEqual(<<"dataset">>, maps:get(<<"event">>, Event)),
    ?assertEqual(<<"inventory">>, maps:get(<<"source">>, Event)),
    ?assertEqual(maps:get(revision, Snapshot), maps:get(<<"revision">>, EventData)),
    ?assertNot(maps:is_key(<<"data">>, EventData)),
    ok = socket:close(Socket),
    ok = wfcli_player_service:clear().

request_notification_settings(Socket) ->
    Get = #{<<"op">> => <<"notification_settings">>, <<"id">> => 15},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Get)),
    {ok, GetLine} = socket:recv(Socket, 0, 5000),
    {ok, GetReply} = wfcli_local_protocol:decode(string:trim(GetLine)),
    ?assertEqual(<<"off">>, maps:get(
                              <<"mode">>,
                              maps:get(<<"fissures">>, maps:get(<<"data">>, GetReply)))),
    Set = #{<<"op">> => <<"notification_settings_set">>, <<"id">> => 16,
            <<"fissures">> => #{<<"mode">> => <<"session">>}},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Set)),
    {ok, SetLine} = socket:recv(Socket, 0, 5000),
    {ok, SetReply} = wfcli_local_protocol:decode(string:trim(SetLine)),
    ?assertEqual(true, maps:get(<<"ok">>, SetReply)),
    ?assertEqual(<<"session">>, maps:get(
                                  <<"mode">>,
                                  maps:get(<<"fissures">>, maps:get(<<"data">>, SetReply)))).

publish_game_running(Socket) ->
    Request = #{<<"op">> => <<"publish">>, <<"id">> => 2,
                <<"dataset">> => <<"player">>, <<"source">> => <<"game">>,
                <<"data">> => #{<<"running">> => true}},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
    {ok, ReplyLine} = socket:recv(Socket, 0, 5000),
    {ok, Reply} = wfcli_local_protocol:decode(string:trim(ReplyLine)),
    ?assertEqual(true, maps:get(<<"ok">>, Reply)),
    ?assertEqual(2, maps:get(<<"id">>, Reply)).

request_market_quote(Socket) ->
    Request = #{<<"op">> => <<"market_quote">>, <<"id">> => 9,
                <<"items">> => [<<"saryn_prime_set">>]},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
    {ok, ReplyLine} = socket:recv(Socket, 0, 5000),
    {ok, Reply} = wfcli_local_protocol:decode(string:trim(ReplyLine)),
    ?assertEqual(true, maps:get(<<"ok">>, Reply)),
    ?assertEqual(9, maps:get(<<"id">>, Reply)),
    ?assertEqual(<<"market">>, maps:get(<<"dataset">>, Reply)),
    Data = maps:get(<<"data">>, Reply),
    [QuoteRow] = maps:get(<<"quotes">>, Data),
    ?assertEqual(<<"saryn_prime_set">>, maps:get(<<"item">>, QuoteRow)),
    Quote = maps:get(<<"quote">>, QuoteRow),
    ?assertEqual(42, maps:get(<<"lowest_sell">>, Quote)).

request_market_variant_quote(Socket) ->
    Request = #{<<"op">> => <<"market_quote_variant">>, <<"id">> => 21,
                <<"item">> => <<"saryn_prime_set">>,
                <<"filters">> => #{<<"rank">> => 5,
                                     <<"subtype">> => <<"blueprint">>}},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
    {ok, ReplyLine} = socket:recv(Socket, 0, 5000),
    {ok, Reply} = wfcli_local_protocol:decode(string:trim(ReplyLine)),
    ?assertEqual(true, maps:get(<<"ok">>, Reply)),
    ?assertEqual(21, maps:get(<<"id">>, Reply)),
    Data = maps:get(<<"data">>, Reply),
    ?assertEqual(<<"saryn_prime_set">>, maps:get(<<"slug">>, Data)),
    ?assertEqual(42, maps:get(<<"lowest_sell">>, maps:get(<<"quote">>, Data))).

request_cached_market_quote(Socket) ->
    Request = #{<<"op">> => <<"market_quote">>, <<"id">> => 14,
                <<"items">> => [<<"saryn_prime_set">>],
                <<"cache_only">> => true},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
    {ok, ReplyLine} = socket:recv(Socket, 0, 5000),
    {ok, Reply} = wfcli_local_protocol:decode(string:trim(ReplyLine)),
    ?assertEqual(true, maps:get(<<"ok">>, Reply)),
    ?assertEqual(14, maps:get(<<"id">>, Reply)),
    [QuoteRow] = maps:get(<<"quotes">>, maps:get(<<"data">>, Reply)),
    ?assertEqual(<<"saryn_prime_set">>, maps:get(<<"item">>, QuoteRow)).

request_market_resolve(Socket) ->
    Request = #{<<"op">> => <<"market_resolve">>, <<"id">> => 8,
                <<"labels">> => [<<"Saryn Prme Set">>], <<"limit">> => 1},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
    {ok, ReplyLine} = socket:recv(Socket, 0, 5000),
    {ok, Reply} = wfcli_local_protocol:decode(string:trim(ReplyLine)),
    ?assertEqual(true, maps:get(<<"ok">>, Reply)),
    ?assertEqual(8, maps:get(<<"id">>, Reply)),
    ?assertEqual(<<"market">>, maps:get(<<"dataset">>, Reply)),
    [Resolution] = maps:get(<<"resolutions">>, maps:get(<<"data">>, Reply)),
    ?assertEqual(<<"Saryn Prme Set">>, maps:get(<<"label">>, Resolution)),
    [Best] = maps:get(<<"matches">>, Resolution),
    ?assertEqual(<<"Saryn Prime Set">>, maps:get(<<"name">>, Best)),
    ?assertEqual(<<"saryn_prime_set">>, maps:get(<<"slug">>, Best)),
    ?assertEqual(1, maps:get(<<"distance">>, Best)).

request_market_describe(Socket) ->
    Request = #{<<"op">> => <<"market_describe">>, <<"id">> => 17,
                <<"items">> => [<<"saryn">>, <<"Saryn Prime Set">>]},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
    {ok, ReplyLine} = socket:recv(Socket, 0, 5000),
    {ok, Reply} = wfcli_local_protocol:decode(string:trim(ReplyLine)),
    ?assertEqual(true, maps:get(<<"ok">>, Reply)),
    [ById, ByName] = maps:get(<<"items">>, maps:get(<<"data">>, Reply)),
    ?assertEqual(ById, ByName),
    ?assertEqual(<<"saryn">>, maps:get(<<"id">>, ById)).

request_market_account(Socket) ->
    Request = #{<<"op">> => <<"market_account">>, <<"id">> => 18},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
    {ok, ReplyLine} = socket:recv(Socket, 0, 5000),
    {ok, Reply} = wfcli_local_protocol:decode(string:trim(ReplyLine)),
    ?assertEqual(true, maps:get(<<"ok">>, Reply)),
    Data = maps:get(<<"data">>, Reply),
    ?assertEqual(false, maps:get(<<"authenticated">>, Data)),
    ?assertMatch(#{<<"mode">> := <<"invisible">>}, maps:get(<<"presence">>, Data)).

request_market_presence(Socket) ->
    Request = #{<<"op">> => <<"market_presence_set">>, <<"id">> => 20,
                <<"mode">> => <<"auto">>},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
    Reply = receive_market_presence(Socket, undefined, false),
    ?assertEqual(true, maps:get(<<"ok">>, Reply)),
    ?assertEqual(<<"auto">>,
                 maps:get(<<"mode">>, maps:get(<<"data">>, Reply))).

receive_market_presence(_Socket, Reply, true) when Reply =/= undefined ->
    Reply;
receive_market_presence(Socket, Reply, SawEvent) ->
    {ok, Chunk} = socket:recv(Socket, 0, 5000),
    {NextReply, NextSawEvent} = lists:foldl(
      fun(Line, Acc) ->
          {ok, Message} = wfcli_local_protocol:decode(Line),
          classify_market_presence(Message, Acc)
      end,
      {Reply, SawEvent},
      binary:split(Chunk, <<"\n">>, [global, trim_all])),
    receive_market_presence(Socket, NextReply, NextSawEvent).

classify_market_presence(#{<<"id">> := 20} = Reply, {_OldReply, SawEvent}) ->
    {Reply, SawEvent};
classify_market_presence(#{<<"event">> := <<"market_presence">>}, {Reply, _}) ->
    {Reply, true}.

reject_invalid_market_order(Socket) ->
    Request = #{<<"op">> => <<"market_order_create">>, <<"id">> => 19,
                <<"order">> => #{<<"type">> => <<"sell">>}},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
    {ok, ReplyLine} = socket:recv(Socket, 0, 5000),
    {ok, Reply} = wfcli_local_protocol:decode(string:trim(ReplyLine)),
    ?assertEqual(false, maps:get(<<"ok">>, Reply)),
    ?assertEqual(<<"invalid_market_order">>, maps:get(<<"error">>, Reply)).

route_market_order_mutations(Socket) ->
    Requests = [
        #{<<"op">> => <<"market_order_update">>, <<"id">> => 22,
          <<"order_id">> => <<"order-1">>,
          <<"patch">> => #{<<"visible">> => true}},
        #{<<"op">> => <<"market_order_delete">>, <<"id">> => 23,
          <<"order_id">> => <<"order-1">>},
        #{<<"op">> => <<"market_order_close">>, <<"id">> => 24,
          <<"order_id">> => <<"order-1">>, <<"quantity">> => 1}
    ],
    lists:foreach(
      fun(Request) ->
          ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
          {ok, ReplyLine} = socket:recv(Socket, 0, 5000),
          {ok, Reply} = wfcli_local_protocol:decode(string:trim(ReplyLine)),
          ?assertEqual(maps:get(<<"id">>, Request), maps:get(<<"id">>, Reply)),
          ?assertEqual(false, maps:get(<<"ok">>, Reply)),
          ?assertEqual(<<"Sign in to Warframe.market first">>,
                       maps:get(<<"error">>, Reply))
      end,
      Requests).

reject_invalid_market_resolve(Socket) ->
    TooMany = [<<"label">> || _ <- lists:seq(1, 21)],
    Request1 = #{<<"op">> => <<"market_resolve">>, <<"id">> => 7,
                 <<"labels">> => TooMany, <<"limit">> => 1},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request1)),
    {ok, ReplyLine1} = socket:recv(Socket, 0, 5000),
    {ok, Reply1} = wfcli_local_protocol:decode(string:trim(ReplyLine1)),
    ?assertEqual(false, maps:get(<<"ok">>, Reply1)),
    ?assertEqual(<<"invalid_market_labels">>, maps:get(<<"error">>, Reply1)),

    Request2 = #{<<"op">> => <<"market_resolve">>, <<"id">> => 6,
                 <<"labels">> => [<<"Saryn">>], <<"limit">> => 0},
    ok = socket:send(Socket, wfcli_local_protocol:encode(Request2)),
    {ok, ReplyLine2} = socket:recv(Socket, 0, 5000),
    {ok, Reply2} = wfcli_local_protocol:decode(string:trim(ReplyLine2)),
    ?assertEqual(false, maps:get(<<"ok">>, Reply2)),
    ?assertEqual(<<"invalid_market_limit">>, maps:get(<<"error">>, Reply2)).

reject_invalid_relic_limit(Socket) ->
    lists:foreach(
      fun({Id, Operation}) ->
          Request = #{<<"op">> => Operation, <<"id">> => Id,
                      <<"era">> => <<"axi">>, <<"limit">> => 0},
          ok = socket:send(Socket, wfcli_local_protocol:encode(Request)),
          {ok, ReplyLine} = socket:recv(Socket, 0, 5000),
          {ok, Reply} = wfcli_local_protocol:decode(string:trim(ReplyLine)),
          ?assertEqual(false, maps:get(<<"ok">>, Reply)),
          ?assertEqual(<<"invalid_relic_limit">>, maps:get(<<"error">>, Reply))
      end,
      [{12, <<"relic_recommendations">>}, {13, <<"relic_planner">>}]).

market_http(Url, _Headers) ->
    Body = case lists:suffix("/v2/items", Url) of
        true ->
            #{<<"error">> => null,
              <<"data">> => [#{<<"id">> => <<"saryn">>,
                               <<"slug">> => <<"saryn_prime_set">>,
                               <<"i18n">> => #{<<"en">> =>
                                                   #{<<"name">> => <<"Saryn Prime Set">>}}},
                             #{<<"id">> => <<"soma">>,
                               <<"slug">> => <<"soma_prime_set">>,
                               <<"i18n">> => #{<<"en">> =>
                                                   #{<<"name">> => <<"Soma Prime Set">>}}}]};
        false ->
            #{<<"error">> => null,
              <<"data">> => #{<<"sell">> => [#{<<"platinum">> => 42}],
                                <<"buy">> => [#{<<"platinum">> => 35}]}}
    end,
    {ok, 200, jsone:encode(Body)}.

await_external_activity(_Expected, 0) ->
    ?assert(false);
await_external_activity(Expected, Attempts) ->
    case maps:get(external_activity, wfcli_worldstate_service:status()) of
        Expected -> ok;
        _ ->
            timer:sleep(10),
            await_external_activity(Expected, Attempts - 1)
    end.
