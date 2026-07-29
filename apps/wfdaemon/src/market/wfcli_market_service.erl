%%%-------------------------------------------------------------------
%% Daemon-owned Warframe Market manifest, quote cache, and request queue.
%%%-------------------------------------------------------------------
-module(wfcli_market_service).

-behaviour(gen_server).

-export([start_link/0, submit/2, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_QUOTE_TTL, 60).
-define(MANIFEST_TTL, 86400).
-define(FAILURE_RETRY_TTL, 60).
-define(MAX_QUOTES, 20).
-define(HARD_MAX_QUOTES, 100).
-define(MAX_RESOLVE_LABELS, 20).
-define(MAX_RESOLVE_LIMIT, 5).
-define(MAX_RELIC_ITEMS, 8).
-define(DETAIL_TTL, 86400).
-define(RELIC_CATALOG_TTL, 86400).
-define(RELIC_CATALOG_RETRY_TTL, 60).
-define(RECOMMENDATION_PRICE_CANDIDATES, 4).

-type state() :: map().

-doc "Start serialized market catalog and quote owner.".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Queue market query or quote work; result arrives as `{wfcli_daemon, Ref, Reply}`.".
-spec submit(pid(), map()) -> {ok, reference()} | {error, term()}.
submit(Client, Request) ->
    gen_server:call(?SERVER, {submit, Client, Request}).

-doc "Return queue, manifest, quote-cache, and rate-limit state.".
-spec status() -> map().
status() -> gen_server:call(?SERVER, status).

-spec init([]) -> {ok, state()}.
init([]) ->
    Path = wfcli_market_cache:path(),
    {ok, #{queue => queue:new(), current => undefined, monitors => #{},
           cache_path => Path, snapshot => wfcli_market_cache:load(Path),
           next_request_at => 0, cache_error => undefined}}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call({submit, Client, Request}, _From, State) when is_pid(Client), is_map(Request) ->
    Ref = make_ref(),
    Monitor = erlang:monitor(process, Client),
    Job = #{ref => Ref, client => Client, monitor => Monitor,
            submitted_at => erlang:system_time(millisecond), request => Request},
    wfcli_worldstate_service:activity_start(),
    self() ! process_queue,
    {reply, {ok, Ref},
     State#{queue => queue:in(Job, maps:get(queue, State)),
            monitors => (maps:get(monitors, State))#{Monitor => Ref}}};
handle_call(status, _From, State) ->
    Snapshot = maps:get(snapshot, State),
    {reply, #{queued => queue:len(maps:get(queue, State)),
              processing => maps:get(current, State) =/= undefined,
              items => length(maps:get(items, Snapshot, [])),
              cached_quotes => map_size(maps:get(quotes, Snapshot, #{})),
              cached_details => map_size(maps:get(details, Snapshot, #{})),
              cached_relics => map_size(maps:get(relics, Snapshot, #{})),
              manifest_fetched_at => maps:get(manifest_fetched_at, Snapshot, undefined),
              relics_fetched_at => maps:get(relics_fetched_at, Snapshot, undefined),
              cache_path => maps:get(cache_path, State),
              cache_error => maps:get(cache_error, State, undefined)}, State};
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Message, State) -> {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(process_queue, State = #{current := Current}) when Current =/= undefined ->
    {noreply, State};
handle_info(process_queue, State) ->
    case queue:out(maps:get(queue, State)) of
        {empty, Queue} -> {noreply, State#{queue => Queue}};
        {{value, Job}, Queue} ->
            Parent = self(),
            Token = make_ref(),
            Snapshot = maps:get(snapshot, State),
            NextRequestAt = maps:get(next_request_at, State),
            {Pid, WorkerMonitor} = spawn_monitor(fun() ->
                Result = safe_execute(Job, Snapshot, NextRequestAt),
                Parent ! {market_result, Token, Result}
            end),
            Current = #{token => Token, worker_pid => Pid,
                        worker_monitor => WorkerMonitor, job => Job},
            {noreply, State#{queue => Queue, current => Current}}
    end;
handle_info({market_result, Token, {Reply, Snapshot, NextRequestAt}},
            State = #{current := #{token := Token, worker_monitor := WorkerMonitor,
                                   job := Job}}) ->
    erlang:demonitor(WorkerMonitor, [flush]),
    CacheError = persist_if_changed(State, Snapshot),
    State1 = complete_job(Job, Reply,
                          State#{current => undefined, snapshot => Snapshot,
                                 next_request_at => NextRequestAt}),
    State2 = State1#{cache_error => CacheError},
    self() ! process_queue,
    {noreply, State2};
handle_info({'DOWN', Monitor, process, _Pid, Reason},
            State = #{current := #{worker_monitor := Monitor, job := Job}}) ->
    State1 = complete_job(Job, {error, {market_worker_down, Reason}},
                          State#{current => undefined}),
    self() ! process_queue,
    {noreply, State1};
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    case cancel_client(Monitor, State) of
        {not_found, State1} -> {noreply, State1};
        {canceled, State1} -> self() ! process_queue, {noreply, State1}
    end;
handle_info(_Message, State) -> {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, State) ->
    stop_worker(maps:get(current, State, undefined)),
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    Path = maps:get(cache_path, State, wfcli_market_cache:path()),
    {ok, State#{queue => maps:get(queue, State, queue:new()),
                current => maps:get(current, State, undefined),
                monitors => maps:get(monitors, State, #{}),
                cache_path => Path,
                snapshot => maps:get(snapshot, State, wfcli_market_cache:load(Path)),
                next_request_at => maps:get(next_request_at, State, 0),
                cache_error => maps:get(cache_error, State, undefined)}}.

safe_execute(Job, Snapshot, NextRequestAt) ->
    try execute(Job, Snapshot, NextRequestAt)
    catch Class:Reason:Stack ->
        logger:error("market request failed: ~p:~p~n~p", [Class, Reason, Stack]),
        {{error, {market_request_failed, Class, Reason}}, Snapshot, NextRequestAt}
    end.

execute(Job, Snapshot0, Next0) ->
    Request = maps:get(request, Job),
    SubmittedAt = maps:get(submitted_at, Job),
    case ensure_manifest(Request, SubmittedAt, Snapshot0, Next0) of
        {ok, Snapshot, Next} -> execute_action(Request, SubmittedAt, Snapshot, Next);
        {error, Reason, Snapshot, Next} -> {{error, Reason}, Snapshot, Next}
    end.

execute_action(#{action := query, query_ast := Ast} = Request, _SubmittedAt,
               Snapshot, Next) ->
    {wfcli_market_query:execute(Ast, Request, Snapshot), Snapshot, Next};
execute_action(#{action := quote_query, query_tokens := Tokens} = Request, SubmittedAt,
               Snapshot, Next) ->
    NormalizedTokens = lists:append([string:lexemes(Token, " \t") || Token <- Tokens]),
    case wfcli_query_parse:parse_arguments(NormalizedTokens) of
        {ok, Ast} -> quote_query(Ast, Request, SubmittedAt, Snapshot, Next);
        {error, Error} -> {{error, {query_errors, [Error]}}, Snapshot, Next}
    end;
execute_action(#{action := quote_items, items := Items} = Request, SubmittedAt,
               Snapshot, Next) when is_list(Items) ->
    quote_items(Items, Request, SubmittedAt, Snapshot, Next);
execute_action(#{action := resolve_labels} = Request, _SubmittedAt, Snapshot, Next) ->
    resolve_labels(Request, Snapshot, Next);
execute_action(#{action := relic_context} = Request, SubmittedAt, Snapshot, Next) ->
    relic_context(Request, SubmittedAt, Snapshot, Next);
execute_action(#{action := relic_recommendations} = Request, SubmittedAt, Snapshot, Next) ->
    relic_recommendations(Request, SubmittedAt, Snapshot, Next);
execute_action(Request, _SubmittedAt, Snapshot, Next) ->
    {{error, {unsupported_market_action, maps:get(action, Request, undefined)}}, Snapshot, Next}.

resolve_labels(Request, Snapshot, Next) ->
    Labels = maps:get(labels, Request, undefined),
    Limit = maps:get(limit, Request, undefined),
    case valid_resolve_labels(Labels) of
        false -> {{error, invalid_market_labels}, Snapshot, Next};
        true when not is_integer(Limit); Limit < 1; Limit > ?MAX_RESOLVE_LIMIT ->
            {{error, invalid_market_limit}, Snapshot, Next};
        true ->
            Resolutions = wfcli_market_resolver:resolve(
                            Labels, maps:get(items, Snapshot, []), Limit),
            Reply = #{context => wfcli_market_api:context(), resolutions => Resolutions},
            {{ok, Reply}, Snapshot, Next}
    end.

valid_resolve_labels(Labels) when is_list(Labels), length(Labels) =< ?MAX_RESOLVE_LABELS ->
    lists:all(fun(Label) -> is_binary(Label) andalso byte_size(Label) > 0 end, Labels);
valid_resolve_labels(_Labels) -> false.

relic_context(Request, SubmittedAt, Snapshot0, Next0) ->
    Slugs = maps:get(items, Request, undefined),
    case valid_relic_items(Slugs) of
        false -> {{error, invalid_relic_items}, Snapshot0, Next0};
        true ->
            {Snapshot1, Next1, DetailErrors} =
                fetch_details(Slugs, Snapshot0, Next0, #{}),
            Snapshot2 = case ensure_relic_catalog(Snapshot1) of
                {ok, CatalogSnapshot} -> CatalogSnapshot;
                {error, _Reason, CatalogSnapshot} -> CatalogSnapshot
            end,
            QuoteItems = unique(Slugs ++ root_slugs(Slugs, Snapshot2), []),
            {Snapshot3, Next2, QuoteErrors} = fetch_quotes(
                QuoteItems, Request, SubmittedAt, Snapshot2, Next1, #{}),
            Reply = wfcli_relic_context:build(
                Slugs,
                maps:get(items, Snapshot3, []),
                maps:get(details, Snapshot3, #{}),
                maps:get(quotes, Snapshot3, #{}),
                player_snapshot(),
                maps:get(relics, Snapshot3, #{})),
            {{ok, Reply#{<<"detail_errors">> => DetailErrors,
                         <<"quote_errors">> => QuoteErrors}},
             Snapshot3, Next2}
    end.

valid_relic_items(Items) when is_list(Items), length(Items) =< ?MAX_RELIC_ITEMS ->
    lists:all(fun(Item) -> is_binary(Item) andalso byte_size(Item) > 0 end, Items);
valid_relic_items(_Items) -> false.

relic_recommendations(Request, SubmittedAt, Snapshot0, Next0) ->
    Era = maps:get(era, Request, undefined),
    case valid_relic_era(Era) of
        false -> {{error, invalid_relic_era}, Snapshot0, Next0};
        true ->
            case ensure_relic_catalog(Snapshot0) of
                {error, Reason, Snapshot1} ->
                    {{error, Reason}, Snapshot1, Next0};
                {ok, Snapshot1} ->
                    Player = player_snapshot(),
                    {Snapshot2, Next1, QuoteErrors} =
                        maybe_fetch_recommendation_prices(
                          Request, Era, Player, SubmittedAt, Snapshot1, Next0),
                    Reply = wfcli_relic_recommendations:build(
                              Era,
                              maps:get(relics, Snapshot2, #{}),
                              maps:get(items, Snapshot2, []),
                              maps:get(quotes, Snapshot2, #{}),
                              Player),
                    {{ok, Reply#{<<"quote_errors">> => QuoteErrors}}, Snapshot2, Next1}
            end
    end.

valid_relic_era(Era) ->
    lists:member(Era, [<<"lith">>, <<"meso">>, <<"neo">>, <<"axi">>, <<"all">>]).

maybe_fetch_recommendation_prices(Request, Era, Player, SubmittedAt, Snapshot, Next) ->
    case maps:get(fetch_prices, Request, false) of
        true ->
            Slugs = wfcli_relic_recommendations:price_slugs(
                      Era,
                      maps:get(relics, Snapshot, #{}),
                      maps:get(items, Snapshot, []),
                      Player,
                      ?RECOMMENDATION_PRICE_CANDIDATES),
            PriceRequest = Request#{ttl => 900, refresh => false},
            fetch_quotes(Slugs, PriceRequest, SubmittedAt, Snapshot, Next, #{});
        false -> {Snapshot, Next, #{}}
    end.

ensure_relic_catalog(Snapshot) ->
    Relics = maps:get(relics, Snapshot, #{}),
    FetchedAt = maps:get(relics_fetched_at, Snapshot, 0),
    AttemptedAt = maps:get(relics_attempted_at, Snapshot, 0),
    Now = erlang:system_time(millisecond),
    Fresh = map_size(Relics) > 0 andalso
            ((is_integer(FetchedAt) andalso
              Now - FetchedAt =< ?RELIC_CATALOG_TTL * 1000) orelse
             (is_integer(AttemptedAt) andalso
              Now - AttemptedAt =< ?RELIC_CATALOG_RETRY_TTL * 1000)),
    case Fresh of
        true -> {ok, Snapshot};
        false ->
            case wfcli_relic_recommendations:fetch() of
                {ok, NewRelics} ->
                    {ok, Snapshot#{relics => NewRelics,
                                  relics_fetched_at => Now,
                                  relics_attempted_at => Now,
                                  updated_at => Now}};
                {error, Reason} when map_size(Relics) > 0 ->
                    {ok, Snapshot#{relics_attempted_at => Now,
                                  relics_stale_reason => wfcli_text:to_list(Reason)}};
                {error, Reason} ->
                    {error, Reason, Snapshot#{relics_attempted_at => Now}}
            end
    end.

quote_query(Ast, Request, SubmittedAt, Snapshot0, Next0) ->
    QueryRequest = query_request(Request),
    case wfcli_market_query:execute(Ast, QueryRequest, Snapshot0) of
        {ok, Initial} ->
            Results = maps:get(results, Initial),
            Total = maps:get(total, Results),
            ExplicitLimit = maps:is_key(limit, Request),
            case not ExplicitLimit andalso Total > ?MAX_QUOTES of
                true ->
                    {{error, {market_query_too_broad, Total, ?MAX_QUOTES}}, Snapshot0, Next0};
                false ->
                    Entries = maps:get(slice, Results),
                    case length(Entries) > ?HARD_MAX_QUOTES of
                        true ->
                            {{error, {market_quote_limit_exceeded, length(Entries),
                                      ?HARD_MAX_QUOTES}}, Snapshot0, Next0};
                        false ->
                            Slugs = [maps:get(slug, Entry) || Entry <- Entries],
                            {Snapshot, Next, Errors} = fetch_quotes(
                                Slugs, Request, SubmittedAt, Snapshot0, Next0, #{}),
                            {ok, Result} = wfcli_market_query:execute(Ast, QueryRequest, Snapshot),
                            Reply = Result#{context => wfcli_market_api:context(),
                                            quote_errors => Errors},
                            {{ok, Reply}, Snapshot, Next}
                    end
            end;
        {error, _Reason} = Error -> {Error, Snapshot0, Next0}
    end.

query_request(Request) ->
    Base = #{offset => maps:get(offset, Request, 0),
             output_format => maps:get(output_format, Request, table),
             raw => maps:get(raw, Request, false)},
    case maps:find(limit, Request) of
        {ok, Limit} -> Base#{limit => Limit};
        error -> Base#{limit => infinity}
    end.

quote_items(Items, Request, SubmittedAt, Snapshot0, Next0) ->
    {Resolved, Missing} = resolve_items(Items, maps:get(items, Snapshot0, [])),
    case length(Items) > ?HARD_MAX_QUOTES orelse length(Resolved) > ?HARD_MAX_QUOTES of
        true ->
            {{error, {market_quote_limit_exceeded, length(Items), ?HARD_MAX_QUOTES}},
             Snapshot0, Next0};
        false ->
            {Snapshot, Next, Errors} = fetch_quotes(
                Resolved, Request, SubmittedAt, Snapshot0, Next0, #{}),
            Quotes = maps:get(quotes, Snapshot),
            Rows = [#{slug => Slug, quote => maps:get(Slug, Quotes, undefined),
                      error => maps:get(Slug, Errors, undefined)} || Slug <- Resolved],
            Reply = #{context => wfcli_market_api:context(), quotes => Rows, missing => Missing},
            {{ok, Reply}, Snapshot, Next}
    end.

resolve_items(Values, Items) ->
    BySlug = maps:from_list([{string:lowercase(wfcli_text:to_list(
                                 maps:get(<<"slug">>, Item))),
                              maps:get(<<"slug">>, Item)} || Item <- Items]),
    ByName = maps:from_list([{string:lowercase(wfcli_text:to_list(item_name(Item))),
                              maps:get(<<"slug">>, Item)} || Item <- Items]),
    {Found0, Missing0} = lists:foldl(fun(Value, {Found, Missing}) ->
        Key = string:lowercase(string:trim(wfcli_text:to_list(Value))),
        case maps:get(Key, BySlug, maps:get(Key, ByName, undefined)) of
            undefined -> {Found, [Value | Missing]};
            Slug -> {[Slug | Found], Missing}
        end
    end, {[], []}, Values),
    {unique(lists:reverse(Found0), []), lists:reverse(Missing0)}.

fetch_quotes([], _Request, _SubmittedAt, Snapshot, Next, Errors) ->
    {Snapshot, Next, Errors};
fetch_quotes([Slug | Rest], Request, SubmittedAt, Snapshot0, Next0, Errors0) ->
    Quotes0 = maps:get(quotes, Snapshot0, #{}),
    Cached = maps:get(Slug, Quotes0, undefined),
    case quote_cache_state(Cached, Request, SubmittedAt) of
        fresh ->
            Source = case maps:get(quoted_at, Cached, 0) >= SubmittedAt of
                true -> coalesced;
                false -> cached
            end,
            Quote = Cached#{source => Source, stale => false},
            Snapshot = Snapshot0#{quotes => Quotes0#{Slug => Quote}},
            fetch_quotes(Rest, Request, SubmittedAt, Snapshot, Next0, Errors0);
        stale ->
            fetch_quotes(Rest, Request, SubmittedAt, Snapshot0, Next0, Errors0);
        fetch ->
            case wfcli_market_api:fetch_quote(Slug, Next0) of
                {ok, Quote, Next} ->
                    Snapshot = Snapshot0#{quotes => Quotes0#{Slug => Quote},
                                          updated_at => erlang:system_time(millisecond)},
                    fetch_quotes(Rest, Request, SubmittedAt, Snapshot, Next, Errors0);
                {error, Reason, Next} ->
                    quote_failure(Rest, Slug, Reason, Cached, Request, SubmittedAt,
                                  Snapshot0, Next, Errors0)
            end
    end.

fetch_details([], Snapshot, Next, Errors) ->
    {Snapshot, Next, Errors};
fetch_details([Slug | Rest], Snapshot0, Next0, Errors0) ->
    Details0 = maps:get(details, Snapshot0, #{}),
    Cached = maps:get(Slug, Details0, undefined),
    case detail_fresh(Cached) of
        true -> fetch_details(Rest, Snapshot0, Next0, Errors0);
        false ->
            case wfcli_market_api:fetch_item(Slug, Next0) of
                {ok, Data, Next} ->
                    Entry = #{data => Data,
                              fetched_at => erlang:system_time(millisecond)},
                    Snapshot = Snapshot0#{details => Details0#{Slug => Entry},
                                          updated_at => erlang:system_time(millisecond)},
                    fetch_details(Rest, Snapshot, Next, Errors0);
                {error, Reason, Next} when is_map(Cached) ->
                    fetch_details(Rest, Snapshot0, Next,
                                  Errors0#{Slug => Reason});
                {error, Reason, Next} ->
                    fetch_details(Rest, Snapshot0, Next,
                                  Errors0#{Slug => Reason})
            end
    end.

detail_fresh(#{fetched_at := FetchedAt}) when is_integer(FetchedAt) ->
    erlang:system_time(millisecond) - FetchedAt =< ?DETAIL_TTL * 1000;
detail_fresh(_Cached) -> false.

root_slugs(Slugs, Snapshot) ->
    Items = maps:get(items, Snapshot, []),
    ById = maps:from_list([{maps:get(<<"id">>, Item), Item}
                           || Item <- Items, maps:is_key(<<"id">>, Item)]),
    Details = maps:get(details, Snapshot, #{}),
    lists:filtermap(
      fun(Slug) ->
          Data = maps:get(data, maps:get(Slug, Details, #{}), #{}),
          PartIds = maps:get(<<"setParts">>, Data, []),
          Roots = [maps:get(<<"slug">>, Item)
                   || Id <- PartIds,
                      Item <- [maps:get(Id, ById, #{})],
                      maps:get(<<"setRoot">>, Item, false),
                      maps:is_key(<<"slug">>, Item)],
          case Roots of [Root | _] -> {true, Root}; [] -> false end
      end,
      Slugs).

player_snapshot() ->
    case whereis(wfcli_player_service) of
        undefined -> #{data => #{}};
        _Pid -> wfcli_player_service:snapshot()
    end.

quote_failure(Rest, Slug, Reason, Cached, Request, SubmittedAt, Snapshot0, Next, Errors0) ->
    case Cached of
        undefined ->
            fetch_quotes(Rest, Request, SubmittedAt, Snapshot0, Next,
                         Errors0#{Slug => Reason});
        _ ->
            Stale = Cached#{stale => true, source => stale,
                            stale_reason => wfcli_text:to_list(Reason),
                            last_attempt_at => erlang:system_time(millisecond)},
            Quotes = maps:get(quotes, Snapshot0, #{}),
            Snapshot = Snapshot0#{quotes => Quotes#{Slug => Stale}},
            fetch_quotes(Rest, Request, SubmittedAt, Snapshot, Next, Errors0)
    end.

quote_cache_state(undefined, _Request, _SubmittedAt) -> fetch;
quote_cache_state(Quote, Request, SubmittedAt) ->
    QuotedAt = maps:get(quoted_at, Quote, 0),
    case maps:get(stale, Quote, false) of
        true ->
            LastAttempt = maps:get(last_attempt_at, Quote, 0),
            case is_integer(LastAttempt) andalso
                 erlang:system_time(millisecond) - LastAttempt =< ?FAILURE_RETRY_TTL * 1000 of
                true -> stale;
                false -> fetch
            end;
        false ->
            case is_integer(QuotedAt) of
                false -> fetch;
                true ->
                    case maps:get(refresh, Request, false) of
                        true -> case QuotedAt >= SubmittedAt of true -> fresh; false -> fetch end;
                        false ->
                            Ttl0 = maps:get(ttl, Request, ?DEFAULT_QUOTE_TTL),
                            Ttl = case Ttl0 of
                                Value when is_integer(Value), Value >= 0 -> Value;
                                _ -> ?DEFAULT_QUOTE_TTL
                            end,
                            case erlang:system_time(millisecond) - QuotedAt =< Ttl * 1000 of
                                true -> fresh;
                                false -> fetch
                            end
                    end
            end
    end.

ensure_manifest(_Request, _SubmittedAt, Snapshot, Next0) ->
    FetchedAt = maps:get(manifest_fetched_at, Snapshot, 0),
    AttemptedAt = maps:get(manifest_attempted_at, Snapshot, 0),
    Items = maps:get(items, Snapshot, []),
    Now = erlang:system_time(millisecond),
    Fresh = Items =/= [] andalso
            ((is_integer(FetchedAt) andalso Now - FetchedAt =< ?MANIFEST_TTL * 1000) orelse
             (is_integer(AttemptedAt) andalso
              Now - AttemptedAt =< ?FAILURE_RETRY_TTL * 1000)),
    case Fresh of
        true -> {ok, Snapshot, Next0};
        false ->
            case wfcli_market_api:fetch_items(Next0) of
                {ok, NewItems, Next} ->
                    {ok, Snapshot#{items => NewItems, manifest_fetched_at => Now,
                                  manifest_attempted_at => Now, updated_at => Now}, Next};
                {error, Reason, Next} when Items =/= [] ->
                    {ok, Snapshot#{manifest_stale_reason => wfcli_text:to_list(Reason),
                                  manifest_attempted_at => Now}, Next};
                {error, Reason, Next} -> {error, Reason, Snapshot, Next}
            end
    end.

item_name(Item) ->
    maps:get(<<"name">>, maps:get(<<"en">>, maps:get(<<"i18n">>, Item, #{}), #{}),
             maps:get(<<"slug">>, Item, <<>>)).

unique([], Acc) -> lists:reverse(Acc);
unique([Value | Rest], Acc) ->
    case lists:member(Value, Acc) of
        true -> unique(Rest, Acc);
        false -> unique(Rest, [Value | Acc])
    end.

persist_if_changed(State, Snapshot) ->
    case Snapshot =:= maps:get(snapshot, State) of
        true -> maps:get(cache_error, State, undefined);
        false ->
            case wfcli_market_cache:persist(maps:get(cache_path, State), Snapshot) of
                ok -> undefined;
                {error, Reason} ->
                    logger:warning("market cache write failed: ~p", [Reason]),
                    Reason
            end
    end.

complete_job(#{client := Client, ref := Ref, monitor := Monitor}, Reply, State) ->
    case maps:is_key(Monitor, maps:get(monitors, State)) of
        true -> Client ! {wfcli_daemon, Ref, Reply};
        false -> ok
    end,
    erlang:demonitor(Monitor, [flush]),
    wfcli_worldstate_service:activity_end(),
    State#{monitors => maps:remove(Monitor, maps:get(monitors, State))}.

cancel_client(Monitor, State) ->
    case maps:take(Monitor, maps:get(monitors, State)) of
        error -> {not_found, State};
        {Ref, Monitors} ->
            Queue = queue:filter(fun(Job) -> maps:get(ref, Job) =/= Ref end,
                                 maps:get(queue, State)),
            Current = maps:get(current, State, undefined),
            Current1 = case Current of
                #{job := #{ref := Ref}} -> stop_worker(Current), undefined;
                _ -> Current
            end,
            wfcli_worldstate_service:activity_end(),
            {canceled, State#{queue => Queue, current => Current1, monitors => Monitors}}
    end.

stop_worker(undefined) -> ok;
stop_worker(Current) ->
    case maps:get(worker_pid, Current, undefined) of
        Pid when is_pid(Pid) -> exit(Pid, kill);
        undefined -> ok
    end,
    erlang:demonitor(maps:get(worker_monitor, Current), [flush]),
    ok.
