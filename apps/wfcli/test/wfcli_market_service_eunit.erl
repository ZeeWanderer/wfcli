%%%-------------------------------------------------------------------
%% EUnit coverage for daemon-owned market fetch, cache, and query behavior.
%%%-------------------------------------------------------------------
-module(wfcli_market_service_eunit).

-include_lib("eunit/include/eunit.hrl").

market_cache_tracks_relic_schema_test() ->
    ?assertEqual(wfcli_relic_recommendations:catalog_version(),
                 maps:get(relics_version, wfcli_market_cache:empty())).

market_cache_reports_unusable_parent_test() ->
    Blocker = filename:join("/tmp", "wfcli-market-blocker-" ++
                                     integer_to_list(erlang:unique_integer([positive]))),
    ok = file:write_file(Blocker, <<>>),
    try
        ?assertMatch({error, _},
                     wfcli_market_cache:persist(filename:join(Blocker, "market.term"), #{}))
    after
        _ = file:delete(Blocker)
    end.

market_worker_snapshots_are_action_scoped_test() ->
    Snapshot = #{items => [item], quotes => #{quote => cached},
                 details => #{detail => cached}, relics => #{relic => cached},
                 relics_version => 1, relics_fetched_at => 2,
                 relics_attempted_at => 3, updated_at => 4,
                 unrelated => large_value},
    Quote = wfcli_market_service:worker_snapshot(#{action => quote_items}, Snapshot),
    ?assert(maps:is_key(items, Quote)),
    ?assert(maps:is_key(quotes, Quote)),
    ?assertNot(maps:is_key(details, Quote)),
    ?assertNot(maps:is_key(relics, Quote)),
    ?assertNot(maps:is_key(unrelated, Quote)),
    Relic = wfcli_market_service:worker_snapshot(#{action => relic_context}, Snapshot),
    ?assert(maps:is_key(details, Relic)),
    ?assert(maps:is_key(relics, Relic)),
    ?assertNot(maps:is_key(unrelated, Relic)).

market_service_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(State) -> fun() -> exercise(State) end end}.

setup() ->
    Root = filename:join("/tmp", "wfcli-market-" ++
                                  integer_to_list(erlang:unique_integer([positive]))),
    Cache = filename:join(Root, "market.term"),
    Counters = ets:new(market_test_counters, [set, public]),
    ets:insert(Counters, [{items, 0}, {quotes, 0}]),
    application:set_env(wfdaemon, market_cache, Cache),
    application:set_env(wfdaemon, market_request_interval_ms, 0),
    application:set_env(wfdaemon, market_read_workers, 2),
    application:set_env(wfdaemon, market_http_fun, success_http_fun(Counters)),
    application:set_env(wfdaemon, daemon_idle_shutdown, false),
    {ok, _Worldstate} = wfcli_worldstate_service:start_link(),
    {ok, _Market} = wfcli_market_service:start_link(),
    #{root => Root, cache => Cache, counters => Counters}.

cleanup(#{root := Root, cache := Cache, counters := Counters}) ->
    stop(wfcli_market_service),
    stop(wfcli_worldstate_service),
    application:unset_env(wfdaemon, market_cache),
    application:unset_env(wfdaemon, market_request_interval_ms),
    application:unset_env(wfdaemon, market_read_workers),
    application:unset_env(wfdaemon, market_read_execute_fun),
    application:unset_env(wfdaemon, market_http_fun),
    application:unset_env(wfdaemon, daemon_idle_shutdown),
    ets:delete(Counters),
    _ = file:delete(Cache),
    _ = file:delete(Cache ++ ".tmp"),
    _ = file:del_dir(Root),
    ok.

exercise(#{cache := Cache, counters := Counters}) ->
    {ok, ResolveResult} = request(#{action => resolve_labels,
                                    labels => [<<"Saryn Prme Set">>], limit => 2}),
    [Resolution] = maps:get(resolutions, ResolveResult),
    [Best | _] = maps:get(matches, Resolution),
    ?assertEqual(<<"Saryn Prime Set">>, maps:get(name, Best)),
    ?assertEqual(<<"saryn_prime_set">>, maps:get(slug, Best)),
    ?assertEqual(100, maps:get(ducats, Best)),
    ?assertEqual(1, maps:get(distance, Best)),
    ?assertEqual(1, count(Counters, items)),
    ?assertEqual(0, count(Counters, quotes)),

    {ok, Catalog} = request(#{action => query, query_ast => match_all, limit => infinity}),
    ?assertEqual(23, maps:get(total, maps:get(results, Catalog))),
    [Saryn] = [Entry || Entry <- maps:get(slice, maps:get(results, Catalog)),
                        maps:get(slug, Entry) =:= <<"saryn_prime_set">>],
    ?assertEqual(100, maps:get(ducats, maps:get(row_map, Saryn))),
    ?assertEqual(1, count(Counters, items)),
    ?assertEqual(0, count(Counters, quotes)),

    ?assertEqual({error, invalid_market_labels},
                 request(#{action => resolve_labels, labels => [invalid], limit => 1})),
    ?assertEqual({error, invalid_market_limit},
                 request(#{action => resolve_labels, labels => [<<"Saryn">>], limit => 6})),

    ?assertMatch({error, {market_query_too_broad, 23, 20}},
                 request(#{action => quote_query, query_tokens => ["prime"]})),
    ?assertEqual(0, count(Counters, quotes)),

    {ok, HeatResult} = request(#{action => quote_query,
                                 query_tokens => ["tag=prime heat"], limit => 1}),
    [HeatEntry] = maps:get(slice, maps:get(results, HeatResult)),
    ?assertEqual(<<"Heat Mod">>, maps:get(name, HeatEntry)),
    ?assertEqual(1, count(Counters, quotes)),

    QuoteRequest = #{action => quote_query,
                     query_tokens => ["name=\"Saryn Prime Set\""],
                     refresh => true, ttl => 60},
    {ok, Ref1} = wfcli_market_service:submit(self(), QuoteRequest),
    {ok, Ref2} = wfcli_market_service:submit(self(), QuoteRequest),
    {ok, First} = await(Ref1),
    {ok, Second} = await(Ref2),
    ?assertEqual(2, count(Counters, quotes)),
    assert_quote(First),
    assert_quote(Second),
    [SecondEntry] = maps:get(slice, maps:get(results, Second)),
    ?assertEqual(coalesced, maps:get(source, maps:get(quote, SecondEntry))),

    {ok, NamedQuotes} = request(#{action => quote_items,
                                  items => [<<"Saryn Prime Set">>],
                                  refresh => false, ttl => 60}),
    [NamedQuote] = maps:get(quotes, NamedQuotes),
    ?assertEqual(<<"Saryn Prime Set">>, maps:get(item, NamedQuote)),
    ?assertEqual(<<"saryn_prime_set">>, maps:get(slug, NamedQuote)),
    ?assertEqual(42, maps:get(lowest_sell, maps:get(quote, NamedQuote))),

    QuoteCallsBeforeCacheRead = count(Counters, quotes),
    {ok, CachedQuotes} = request(#{action => quote_items,
                                   items => [<<"Saryn Prime Set">>,
                                             <<"prime_item_2">>],
                                   cache_only => true}),
    [CachedQuote] = maps:get(quotes, CachedQuotes),
    ?assertEqual(<<"Saryn Prime Set">>, maps:get(item, CachedQuote)),
    ?assertEqual([], maps:get(missing, CachedQuotes)),
    ?assertEqual(QuoteCallsBeforeCacheRead, count(Counters, quotes)),

    application:set_env(wfdaemon, market_http_fun, stale_http_fun(Counters)),
    timer:sleep(2),
    {ok, StaleResult} = request(QuoteRequest),
    [StaleEntry] = maps:get(slice, maps:get(results, StaleResult)),
    ?assertEqual(true, maps:get(stale, maps:get(quote, StaleEntry))),
    ?assertEqual(stale, maps:get(source, maps:get(quote, StaleEntry))),
    QuoteCallsAfterFailure = count(Counters, quotes),
    {ok, StaleAgain} = request(QuoteRequest#{refresh => false}),
    [StaleAgainEntry] = maps:get(slice, maps:get(results, StaleAgain)),
    ?assertEqual(stale, maps:get(source, maps:get(quote, StaleAgainEntry))),
    ?assertEqual(QuoteCallsAfterFailure, count(Counters, quotes)),

    read_workers_are_bounded(),

    application:set_env(wfdaemon, market_http_fun,
                        fun(_Url, _Headers) -> timer:sleep(5000), {error, too_late} end),
    Parent = self(),
    Client = spawn(fun() ->
        {ok, _Ref} = wfcli_market_service:submit(
                       self(), #{action => quote_items, items => [<<"prime_item_1">>],
                                 refresh => true}),
        Parent ! market_request_submitted,
        receive stop -> ok end
    end),
    receive market_request_submitted -> ok after 1000 -> error(submit_timeout) end,
    await_processing(20),
    ReadStarted = erlang:monotonic_time(millisecond),
    {ok, ConcurrentCatalog} = request(
                                #{action => query, query_ast => match_all,
                                  limit => infinity}),
    ?assertEqual(23, maps:get(total, maps:get(results, ConcurrentCatalog))),
    ?assert(erlang:monotonic_time(millisecond) - ReadStarted < 500),
    CachedReadStarted = erlang:monotonic_time(millisecond),
    {ok, CachedDuringFetch} = request(#{action => quote_items,
                                       items => [<<"Saryn Prime Set">>],
                                       cache_only => true}),
    ?assertEqual(1, length(maps:get(quotes, CachedDuringFetch))),
    ?assert(erlang:monotonic_time(millisecond) - CachedReadStarted < 500),
    exit(Client, kill),
    await_idle(50),
    ?assertMatch(#{external_activity := 0}, wfcli_worldstate_service:status()),

    await_cache(Cache, 100),
    stop(wfcli_market_service),
    application:set_env(wfdaemon, market_http_fun,
                        fun(_Url, _Headers) -> {error, unexpected_network} end),
    {ok, _Market} = wfcli_market_service:start_link(),
    {ok, Restored} = request(#{action => query, query_ast => match_all, limit => infinity}),
    ?assertEqual(23, maps:get(total, maps:get(results, Restored))).

read_workers_are_bounded() ->
    Test = self(),
    application:set_env(
      wfdaemon, market_read_execute_fun,
      fun(_Request, _Snapshot) ->
          Test ! {market_read_started, self()},
          receive continue -> {ok, bounded} end
      end),
    Request = #{action => query, query_ast => match_all, limit => infinity},
    {ok, Ref1} = wfcli_market_service:submit(self(), Request),
    {ok, Ref2} = wfcli_market_service:submit(self(), Request),
    {ok, Ref3} = wfcli_market_service:submit(self(), Request),
    First = receive {market_read_started, Pid1} -> Pid1 after 1000 -> timeout end,
    Second = receive {market_read_started, Pid2} -> Pid2 after 1000 -> timeout end,
    ?assert(is_pid(First)),
    ?assert(is_pid(Second)),
    receive {market_read_started, _Pid} -> error(market_read_limit_exceeded)
    after 100 -> ok
    end,
    First ! continue,
    Completed = receive
        {wfcli_daemon, CompletedRef, {ok, bounded}} -> CompletedRef
    after 1000 -> timeout
    end,
    ?assert(lists:member(Completed, [Ref1, Ref2])),
    Third = receive {market_read_started, Pid3} -> Pid3 after 1000 -> timeout end,
    ?assert(is_pid(Third)),
    Second ! continue,
    Third ! continue,
    Remaining = [receive
                     {wfcli_daemon, ReplyRef, {ok, bounded}} -> ReplyRef
                 after 1000 -> timeout
                 end || _ <- [1, 2]],
    ?assertEqual(lists:sort([Ref1, Ref2, Ref3]), lists:sort([Completed | Remaining])),
    application:unset_env(wfdaemon, market_read_execute_fun).

assert_quote(Result) ->
    [Entry] = maps:get(slice, maps:get(results, Result)),
    Quote = maps:get(quote, Entry),
    ?assertEqual(42, maps:get(lowest_sell, Quote)),
    ?assertEqual(35, maps:get(highest_buy, Quote)),
    ?assertEqual(2, length(maps:get(sell_orders, Quote))),
    ?assertEqual(2, length(maps:get(buy_orders, Quote))).

request(Request) ->
    {ok, Ref} = wfcli_market_service:submit(self(), Request),
    await(Ref).

await(Ref) ->
    receive {wfcli_daemon, Ref, Reply} -> Reply
    after 5000 -> error({market_reply_timeout, Ref})
    end.

success_http_fun(Counters) ->
    fun(Url, _Headers) ->
        case lists:suffix("/v2/items", Url) of
            true ->
                ets:update_counter(Counters, items, 1),
                {ok, 200, jsone:encode(items_envelope())};
            false ->
                ets:update_counter(Counters, quotes, 1),
                timer:sleep(30),
                {ok, 200, jsone:encode(quote_envelope())}
        end
    end.

stale_http_fun(Counters) ->
    fun(Url, _Headers) ->
        case lists:suffix("/v2/items", Url) of
            true ->
                ets:update_counter(Counters, items, 1),
                {ok, 200, jsone:encode(items_envelope())};
            false ->
                ets:update_counter(Counters, quotes, 1),
                {error, market_offline}
        end
    end.

items_envelope() ->
    #{<<"apiVersion">> => <<"0.25.0">>, <<"error">> => null,
      <<"data">> => [item(<<"saryn">>, <<"saryn_prime_set">>, <<"Saryn Prime Set">>),
                     item(<<"heat">>, <<"heat_mod">>, <<"Heat Mod">>)] ++ extra_items()}.

extra_items() ->
    [item(integer_to_binary(N), <<"prime_item_", (integer_to_binary(N))/binary>>,
          <<"Prime Item ", (integer_to_binary(N))/binary>>)
     || N <- lists:seq(1, 21)].

item(Id, Slug, Name) ->
    #{<<"id">> => Id, <<"slug">> => Slug, <<"tags">> => [<<"prime">>],
      <<"ducats">> => 100,
      <<"i18n">> => #{<<"en">> => #{<<"name">> => Name}}}.

quote_envelope() ->
    #{<<"apiVersion">> => <<"0.25.0">>, <<"error">> => null,
      <<"data">> =>
          #{<<"sell">> => [order(50, <<"sell">>), order(42, <<"sell">>)],
            <<"buy">> => [order(30, <<"buy">>), order(35, <<"buy">>)]}}.

order(Price, Type) ->
    #{<<"id">> => integer_to_binary(Price), <<"type">> => Type,
      <<"platinum">> => Price, <<"quantity">> => 1,
      <<"user">> => #{<<"ingameName">> => <<"Trader">>, <<"status">> => <<"ingame">>}}.

count(Counters, Key) -> ets:lookup_element(Counters, Key, 2).

await_processing(0) -> error(market_never_started);
await_processing(Attempts) ->
    case maps:get(processing, wfcli_market_service:status()) of
        true -> ok;
        false -> timer:sleep(10), await_processing(Attempts - 1)
    end.

await_idle(0) -> error(market_never_canceled);
await_idle(Attempts) ->
    Status = wfcli_market_service:status(),
    case maps:get(processing, Status) =:= false andalso maps:get(queued, Status) =:= 0 of
        true -> ok;
        false -> timer:sleep(10), await_idle(Attempts - 1)
    end.

await_cache(_Path, 0) -> error(market_cache_not_persisted);
await_cache(Path, Attempts) ->
    case filelib:is_file(Path) of
        true -> ok;
        false -> timer:sleep(10), await_cache(Path, Attempts - 1)
    end.

stop(Name) ->
    case whereis(Name) of
        undefined -> ok;
        _Pid -> gen_server:stop(Name)
    end.
