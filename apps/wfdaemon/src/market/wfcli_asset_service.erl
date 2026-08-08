%%%-------------------------------------------------------------------
%% Daemon-owned cache for catalog image assets.
%%%-------------------------------------------------------------------
-module(wfcli_asset_service).

-behaviour(gen_server).

-export([start_link/0, resolve/1, prewarm/1, status/0, clear/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CACHE_VERSION, 1).
-define(DEFAULT_BASE_URL, "https://cdn.warframestat.us/img/").
-define(DEFAULT_MARKET_BASE_URL, "https://warframe.market/static/assets/").
-define(DEFAULT_MASTERY_BASE_URL,
        "https://cdn.alecaframe.com/warframeData/custom/imgRemote/levelIcons/").
-define(MAX_ASSETS, 64).
-define(MAX_ASSET_BYTES, 8388608).
-define(FRESH_MS, 604800000).
-define(DEFAULT_WORKERS, 8).
-define(PERSIST_DELAY_MS, 250).
-define(PERSIST_RETRY_MS, 5000).
-define(MAINTENANCE_INTERVAL_MS, 3600000).
-define(MAINTENANCE_RETRY_MS, 1000).
-define(MAINTENANCE_BATCH, 128).

-type state() :: #{
    root := file:filename_all(),
    index_path := file:filename_all(),
    entries := map(),
    foreground := queue:queue(),
    background := queue:queue(),
    pending := map(),
    workers := map(),
    calls := map(),
    call_monitors := map(),
    max_workers := pos_integer(),
    dirty := boolean(),
    persist_timer := reference() | undefined,
    maintenance_timer := reference() | undefined
}.

-doc "Start the persistent catalog asset cache.".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Resolve catalog image names to validated local cache files.".
-spec resolve([map()]) -> {ok, [map()]} | {error, term()}.
resolve(Assets) ->
    gen_server:call(?SERVER, {resolve, Assets}, 120000).

-doc "Queue low-priority assets for cache prewarming.".
-spec prewarm([map()]) -> ok.
prewarm(Assets) ->
    gen_server:cast(?SERVER, {prewarm, Assets}).

-doc "Return cache location and object count.".
-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

-doc "Remove cached source assets when no fetch or resolve call is active.".
-spec clear() -> {ok, map()} | {error, term()}.
clear() ->
    gen_server:call(?SERVER, clear, 120000).

-spec init([]) -> {ok, state()}.
init([]) ->
    Root = cache_root(),
    IndexPath = filename:join(Root, "index.term"),
    {ok, schedule_maintenance(new_state(Root, IndexPath, load_index(IndexPath)), 0)}.

-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, term(), state()} | {noreply, state()}.
handle_call({resolve, Assets}, From, State)
  when is_list(Assets), length(Assets) =< ?MAX_ASSETS ->
    start_resolve(Assets, From, State);
handle_call({resolve, _Assets}, _From, State) ->
    {reply, {error, invalid_assets}, State};
handle_call(status, _From, State) ->
    {reply, cache_status(State), State};
handle_call(clear, _From, State) ->
    case cache_idle(State) of
        false -> {reply, {error, asset_cache_busy}, State};
        true ->
            case clear_cache(State) of
                {ok, State1} -> {reply, {ok, cache_status(State1)}, State1};
                {error, Reason} -> {reply, {error, Reason}, State}
            end
    end;
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast({prewarm, Assets}, State)
  when is_list(Assets), length(Assets) =< ?MAX_ASSETS ->
    {noreply, dispatch(prepare_prewarm(Assets, State))};
handle_cast(_Message, State) -> {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({asset_fetch_result, Pid, Key, Result}, State) ->
    {noreply, finish_fetch(Pid, Key, Result, State)};
handle_info({'DOWN', Monitor, process, Pid, Reason}, State) ->
    case maps:get(Pid, maps:get(workers, State), undefined) of
        #{monitor := Monitor, key := Key} ->
            {noreply, finish_fetch(Pid, Key, {error, {asset_worker_down, Reason}}, State)};
        _ -> {noreply, cancel_call(Monitor, State)}
    end;
handle_info(persist_index, State) ->
    {noreply, flush_index(State#{persist_timer => undefined})};
handle_info(maintain_cache, State) ->
    State1 = State#{maintenance_timer => undefined},
    {State2, More} = maintain_cache(State1),
    Delay = case More of
        true -> ?MAINTENANCE_RETRY_MS;
        false -> ?MAINTENANCE_INTERVAL_MS
    end,
    {noreply, schedule_maintenance(State2, Delay)};
handle_info(_Message, State) -> {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, State) ->
    cancel_timer(maps:get(persist_timer, State, undefined)),
    cancel_timer(maps:get(maintenance_timer, State, undefined)),
    case maps:get(dirty, State, false) of
        true -> _ = persist_index(maps:get(index_path, State), maps:get(entries, State));
        false -> ok
    end,
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    Root = maps:get(root, State),
    IndexPath = maps:get(index_path, State),
    Base = new_state(Root, IndexPath, maps:get(entries, State, #{})),
    {ok, schedule_maintenance(maps:merge(Base, State), 0)}.

new_state(Root, IndexPath, Entries) ->
    #{root => Root, index_path => IndexPath, entries => Entries,
      foreground => queue:new(), background => queue:new(), pending => #{},
      workers => #{}, calls => #{}, call_monitors => #{},
      max_workers => worker_limit(), dirty => false, persist_timer => undefined,
      maintenance_timer => undefined}.

cache_status(State) ->
    Entries = maps:get(entries, State),
    {Objects, Bytes} = cache_usage(Entries),
    #{cache_root => maps:get(root, State), entries => map_size(Entries),
      objects => Objects, bytes => Bytes,
      queued => queue:len(maps:get(foreground, State)) +
                queue:len(maps:get(background, State)),
      pending => map_size(maps:get(pending, State)),
      fetching => map_size(maps:get(workers, State)),
      waiting_calls => map_size(maps:get(calls, State))}.

cache_usage(Entries) ->
    Objects = maps:fold(
                fun(_Key, Entry, Acc) ->
                    case maps:get(path, Entry, undefined) of
                        Path when is_binary(Path) ->
                            Acc#{Path => maps:get(size, Entry, 0)};
                        _ -> Acc
                    end
                end,
                #{}, Entries),
    {map_size(Objects), lists:sum(maps:values(Objects))}.

cache_idle(State) ->
    map_size(maps:get(pending, State)) =:= 0
    andalso map_size(maps:get(workers, State)) =:= 0
    andalso map_size(maps:get(calls, State)) =:= 0.

clear_cache(State) ->
    Root = maps:get(root, State),
    Objects = filename:join(Root, "objects"),
    Trash = Objects ++ ".clear-" ++
            integer_to_list(erlang:unique_integer([positive])),
    case move_objects(Objects, Trash) of
        {error, Reason} -> {error, {asset_cache_clear_failed, Reason}};
        Moved ->
            case Moved of
                true -> spawn(fun() -> _ = file:del_dir_r(Trash) end);
                false -> ok
            end,
            cancel_timer(maps:get(persist_timer, State, undefined)),
            State1 = State#{entries => #{}, dirty => true,
                            persist_timer => undefined},
            {ok, flush_index(State1)}
    end.

move_objects(Objects, Trash) ->
    case file:rename(Objects, Trash) of
        ok -> true;
        {error, enoent} -> false;
        {error, Reason} -> {error, Reason}
    end.

start_resolve(Assets, From, State) ->
    CallRef = make_ref(),
    Prepared = prepare_assets(Assets, State, 0, []),
    {Results, Waiting, State1} =
        lists:foldl(
          fun({Position, {ready, Result}}, {ResultAcc, Count, Acc}) ->
                  {ResultAcc#{Position => Result}, Count, Acc};
             ({Position, {fetch, {Id, Source, Name, Cached}}},
              {ResultAcc, Count, Acc}) ->
                  Waiter = {CallRef, Position, Id},
                  {ResultAcc, Count + 1,
                   enqueue_asset({Source, Name}, {Source, Name, Cached}, Waiter,
                                 foreground, Acc)}
          end,
          {#{}, 0, State}, Prepared),
    case Waiting of
        0 -> {reply, {ok, ordered_results(Results, length(Assets))}, State1};
        _ ->
            Monitor = erlang:monitor(process, element(1, From)),
            Call = #{from => From, remaining => Waiting, results => Results,
                     count => length(Assets), monitor => Monitor},
            Calls = (maps:get(calls, State1))#{CallRef => Call},
            CallMonitors = (maps:get(call_monitors, State1))#{Monitor => CallRef},
            {noreply, dispatch(State1#{calls => Calls, call_monitors => CallMonitors})}
    end.

prepare_prewarm(Assets, State) ->
    lists:foldl(
      fun(Spec, Acc) ->
          case prepare_asset(Spec, Acc) of
              {fetch, {_Id, Source, Name, Cached}} ->
                  enqueue_asset({Source, Name}, {Source, Name, Cached}, none,
                                background, Acc);
              {ready, _Result} -> Acc
          end
      end,
      State, Assets).

prepare_assets([], _State, _Position, Acc) -> lists:reverse(Acc);
prepare_assets([Spec | Rest], State, Position, Acc) ->
    Prepared = prepare_asset(Spec, State),
    prepare_assets(Rest, State, Position + 1, [{Position, Prepared} | Acc]).

prepare_asset(#{<<"id">> := Id, <<"image_name">> := Name} = Spec, State)
  when is_binary(Id), is_binary(Name) ->
    Source = maps:get(<<"source">>, Spec, <<"wfcd">>),
    case valid_asset_name(Source, Name) of
        true -> prepare_valid(Id, Source, Name, State);
        false -> {ready, unavailable(Id, invalid_image_name)}
    end;
prepare_asset(Spec, _State) ->
    Id = case Spec of
        #{<<"id">> := Value} when is_binary(Value) -> Value;
        _ -> <<>>
    end,
    {ready, unavailable(Id, invalid_asset)}.

prepare_valid(Id, Source, Name, State) ->
    Entries = maps:get(entries, State),
    Key = {Source, Name},
    Cached = maps:get(Key, Entries, undefined),
    case usable_cached(Cached) andalso fresh(Cached) of
        true -> {ready, descriptor(Id, Source, Name, Cached, false)};
        false -> {fetch, {Id, Source, Name, Cached}}
    end.

enqueue_asset(Key, Request, Waiter, Priority, State) ->
    Pending = maps:get(pending, State),
    case maps:get(Key, Pending, undefined) of
        undefined ->
            Waiters = case Waiter of none -> []; _ -> [Waiter] end,
            Task = #{request => Request, waiters => Waiters,
                     priority => Priority, status => queued},
            enqueue_key(Priority, Key, State#{pending => Pending#{Key => Task}});
        Task ->
            Waiters = case Waiter of
                none -> maps:get(waiters, Task);
                _ -> [Waiter | maps:get(waiters, Task)]
            end,
            promote_asset(Key, Priority, Task#{waiters => Waiters}, State)
    end.

promote_asset(Key, foreground, Task = #{priority := background, status := queued}, State) ->
    Pending = maps:get(pending, State),
    enqueue_key(foreground, Key,
                State#{pending => Pending#{Key => Task#{priority => foreground}}});
promote_asset(Key, _Priority, Task, State) ->
    Pending = maps:get(pending, State),
    State#{pending => Pending#{Key => Task}}.

enqueue_key(foreground, Key, State) ->
    State#{foreground => queue:in(Key, maps:get(foreground, State))};
enqueue_key(background, Key, State) ->
    State#{background => queue:in(Key, maps:get(background, State))}.

dispatch(State) ->
    case map_size(maps:get(workers, State)) < maps:get(max_workers, State) of
        false -> State;
        true ->
            case next_task(State) of
                {empty, State1} -> State1;
                {Key, Request, State1} -> dispatch(start_fetch(Key, Request, State1))
            end
    end.

next_task(State) ->
    case take_task(foreground, State) of
        {empty, State1} -> take_task(background, State1);
        Found -> Found
    end.

take_task(Priority, State) ->
    Queue = maps:get(Priority, State),
    case queue:out(Queue) of
        {empty, Queue1} -> {empty, State#{Priority => Queue1}};
        {{value, Key}, Queue1} ->
            State1 = State#{Priority => Queue1},
            case maps:get(Key, maps:get(pending, State1), undefined) of
                #{status := queued, priority := Priority, request := Request} ->
                    {Key, Request, State1};
                _ -> take_task(Priority, State1)
            end
    end.

start_fetch(Key, Request, State) ->
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Parent ! {asset_fetch_result, self(), Key, safe_fetch_asset(Request)}
    end),
    Pending = maps:get(pending, State),
    Task = maps:get(Key, Pending),
    Workers = (maps:get(workers, State))#{Pid => #{monitor => Monitor, key => Key}},
    State#{pending => Pending#{Key => Task#{status => active}}, workers => Workers}.

finish_fetch(Pid, Key, Result, State) ->
    case maps:take(Pid, maps:get(workers, State)) of
        error -> State;
        {#{monitor := Monitor, key := Key}, Workers} ->
            erlang:demonitor(Monitor, [flush]),
            case maps:take(Key, maps:get(pending, State)) of
                error -> dispatch(State#{workers => Workers});
                {Task, Pending} ->
                    {Source, Name, Cached} = maps:get(request, Task),
                    {Resolved, State1} = commit_fetch(Source, Name, Cached, Result,
                                                      State#{workers => Workers,
                                                             pending => Pending}),
                    State2 = complete_waiters(maps:get(waiters, Task), Source, Name,
                                              Resolved, State1),
                    dispatch(State2)
            end;
        {_Other, Workers} -> dispatch(State#{workers => Workers})
    end.

safe_fetch_asset(Request) ->
    try fetch_asset(Request)
    catch Class:Reason -> {error, {asset_fetch_crash, Class, Reason}}
    end.

fetch_asset({Source, Name, Cached}) ->
    Url = asset_url(Source, Name),
    Headers = request_headers(Cached),
    case http_get(Url, Headers) of
        {ok, 304, _ResponseHeaders, _Body} when is_map(Cached) ->
            {entry, Cached#{fetched_at => erlang:system_time(millisecond)}};
        {ok, 200, ResponseHeaders, Body0} ->
            Body = iolist_to_binary(Body0),
            case validate_body(Body, ResponseHeaders) of
                {ok, MediaType, Extension} ->
                    {body, Url, Body, MediaType, Extension, ResponseHeaders};
                {error, Reason} -> {error, Reason}
            end;
        {ok, Status, _ResponseHeaders, _Body} ->
            {error, {asset_http_status, Status}};
        {error, Reason} -> {error, {asset_http_failed, Reason}};
        Other -> {error, {invalid_asset_http_result, Other}}
    end.

commit_fetch(Source, Name, _Cached, {entry, Entry}, State) ->
    save_entry({Source, Name}, Entry, State);
commit_fetch(Source, Name, _Cached,
             {body, Url, Body, MediaType, Extension, Headers}, State) ->
    store_body(Source, Name, Url, Body, MediaType, Extension, Headers, State);
commit_fetch(_Source, _Name, Cached, {error, Reason}, State) ->
    stale_or_error(Cached, Reason, State).

store_body(Source, Name, Url, Body, MediaType, Extension, Headers, State) ->
    Digest = hex(crypto:hash(sha256, Body)),
    Objects = filename:join(maps:get(root, State), "objects"),
    Path = filename:join(Objects, binary_to_list(<<Digest/binary, Extension/binary>>)),
    case filelib:ensure_dir(Path) of
        ok ->
            case write_object(Path, Body) of
                ok ->
                    Entry = #{url => list_to_binary(Url), path => list_to_binary(Path),
                              digest => Digest, media_type => MediaType,
                              size => byte_size(Body),
                              etag => response_header(<<"etag">>, Headers),
                              last_modified => response_header(<<"last-modified">>, Headers),
                              fetched_at => erlang:system_time(millisecond)},
                    save_entry({Source, Name}, Entry, State);
                {error, Reason} ->
                    {{error, {asset_cache_write_failed, Reason}}, State}
            end;
        {error, Reason} ->
            {{error, {asset_cache_write_failed, Reason}}, State}
    end.

save_entry(Key, Entry, State) ->
    Entries = (maps:get(entries, State))#{Key => Entry},
    {{ok, Entry, false}, mark_dirty(State#{entries => Entries})}.

stale_or_error(Cached, _Reason, State) when is_map(Cached) ->
    case usable_cached(Cached) of
        true -> {{ok, Cached, true}, State};
        false -> {{error, asset_unavailable}, State}
    end;
stale_or_error(_Cached, Reason, State) ->
    {{error, Reason}, State}.

complete_waiters([], _Source, _Name, _Resolved, State) -> State;
complete_waiters([{CallRef, Position, Id} | Rest], Source, Name, Resolved, State) ->
    Calls = maps:get(calls, State),
    State1 = case maps:take(CallRef, Calls) of
        error -> State;
        {Call, RemainingCalls} ->
            Result = resolved_descriptor(Id, Source, Name, Resolved),
            Results = (maps:get(results, Call))#{Position => Result},
            Remaining = maps:get(remaining, Call) - 1,
            case Remaining of
                0 ->
                    Monitor = maps:get(monitor, Call, undefined),
                    cancel_monitor(Monitor),
                    gen_server:reply(maps:get(from, Call),
                                     {ok, ordered_results(Results, maps:get(count, Call))}),
                    State#{calls => RemainingCalls,
                           call_monitors => remove_monitor(
                                              Monitor, maps:get(call_monitors, State))};
                _ ->
                    Updated = Call#{remaining => Remaining, results => Results},
                    State#{calls => RemainingCalls#{CallRef => Updated}}
            end
    end,
    complete_waiters(Rest, Source, Name, Resolved, State1).

cancel_call(Monitor, State) ->
    case maps:take(Monitor, maps:get(call_monitors, State)) of
        error -> State;
        {CallRef, CallMonitors} ->
            Calls = maps:remove(CallRef, maps:get(calls, State)),
            Pending = maps:map(
                        fun(_Key, Task) ->
                            Waiters = [Waiter || Waiter = {Ref, _Position, _Id}
                                                    <- maps:get(waiters, Task),
                                                Ref =/= CallRef],
                            Task#{waiters => Waiters}
                        end,
                        maps:get(pending, State)),
            State#{calls => Calls, call_monitors => CallMonitors, pending => Pending}
    end.

resolved_descriptor(Id, Source, Name, {ok, Entry, Stale}) ->
    descriptor(Id, Source, Name, Entry, Stale);
resolved_descriptor(Id, _Source, _Name, {error, Reason}) ->
    unavailable(Id, Reason).

ordered_results(_Results, 0) -> [];
ordered_results(Results, Count) ->
    [maps:get(Position, Results) || Position <- lists:seq(0, Count - 1)].

descriptor(Id, Source, Name, Entry, Stale) ->
    #{<<"id">> => Id, <<"ok">> => true, <<"image_name">> => Name,
      <<"source">> => Source,
      <<"path">> => maps:get(path, Entry),
      <<"digest">> => maps:get(digest, Entry),
      <<"media_type">> => maps:get(media_type, Entry),
      <<"size">> => maps:get(size, Entry),
      <<"stale">> => Stale}.

unavailable(Id, Reason) ->
    #{<<"id">> => Id, <<"ok">> => false,
      <<"error">> => iolist_to_binary(io_lib:format("~p", [Reason]))}.

valid_asset_name(<<"wfcd">>, Name) -> valid_image_name(Name);
valid_asset_name(<<"market">>, Name) -> valid_market_path(Name);
valid_asset_name(<<"mastery">>, Name) -> valid_mastery_rank_name(Name);
valid_asset_name(_Source, _Name) -> false.

valid_image_name(Name) when byte_size(Name) > 0, byte_size(Name) =< 255 ->
    binary:match(Name, <<"/">>) =:= nomatch
    andalso binary:match(Name, <<"\\">>) =:= nomatch
    andalso binary:match(Name, <<"..">>) =:= nomatch
    andalso binary:match(Name, <<":">>) =:= nomatch
    andalso binary:match(Name, <<0>>) =:= nomatch;
valid_image_name(_Name) -> false.

valid_market_path(Name) when byte_size(Name) > 0, byte_size(Name) =< 512 ->
    (binary:match(Name, <<"items/images/">>) =:= {0, 13}
     orelse binary:match(Name, <<"sub_icons/">>) =:= {0, 10})
    andalso binary:match(Name, <<"..">>) =:= nomatch
    andalso binary:match(Name, <<"\\">>) =:= nomatch
    andalso binary:match(Name, <<":">>) =:= nomatch
    andalso binary:match(Name, <<0>>) =:= nomatch;
valid_market_path(_Name) -> false.

valid_mastery_rank_name(Name) ->
    case re:run(Name, <<"^(0|[1-9][0-9]?)\\.webp$">>, [{capture, none}]) of
        match -> true;
        nomatch -> false
    end.

asset_url(<<"wfcd">>, Name) ->
    Base = application:get_env(wfdaemon, asset_base_url, ?DEFAULT_BASE_URL),
    Base ++ uri_string:quote(binary_to_list(Name));
asset_url(<<"market">>, Name) ->
    Base = application:get_env(wfdaemon, market_asset_base_url,
                               ?DEFAULT_MARKET_BASE_URL),
    Base ++ binary_to_list(Name);
asset_url(<<"mastery">>, Name) ->
    Base = application:get_env(wfdaemon, mastery_asset_base_url,
                               ?DEFAULT_MASTERY_BASE_URL),
    Base ++ binary_to_list(Name).

request_headers(Cached) ->
    Base = [{"user-agent", "wfcli/0.1 (+https://github.com/ZeeWanderer/wfcli)"},
            {"accept", "image/png,image/jpeg,image/webp"}],
    conditional_header("if-none-match", etag, Cached,
      conditional_header("if-modified-since", last_modified, Cached, Base)).

conditional_header(_Name, _Key, Cached, Headers) when not is_map(Cached) -> Headers;
conditional_header(Name, Key, Cached, Headers) ->
    case maps:get(Key, Cached, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0 ->
            [{Name, binary_to_list(Value)} | Headers];
        _ -> Headers
    end.

http_get(Url, Headers) ->
    try
        case application:get_env(wfdaemon, asset_http_fun) of
            {ok, Fun} when is_function(Fun, 2) -> Fun(Url, Headers);
            _ -> real_http_get(Url, Headers)
        end
    catch Class:Reason -> {error, {asset_http_crash, Class, Reason}}
    end.

real_http_get(Url, Headers) ->
    case httpc:request(get, {Url, Headers}, [{timeout, 15000}],
                       [{body_format, binary}]) of
        {ok, {{_Version, Status, _Reason}, ResponseHeaders, Body}} ->
            {ok, Status, ResponseHeaders, Body};
        {error, Reason} -> {error, Reason}
    end.

validate_body(Body, _Headers) when byte_size(Body) > ?MAX_ASSET_BYTES ->
    {error, asset_too_large};
validate_body(<<16#89, "PNG", 13, 10, 26, 10, _/binary>>, _Headers) ->
    {ok, <<"image/png">>, <<".png">>};
validate_body(<<16#ff, 16#d8, 16#ff, _/binary>>, _Headers) ->
    {ok, <<"image/jpeg">>, <<".jpg">>};
validate_body(<<"RIFF", _Size:32/little, "WEBP", _/binary>>, _Headers) ->
    {ok, <<"image/webp">>, <<".webp">>};
validate_body(_Body, _Headers) ->
    {error, invalid_asset_body}.

response_header(Name, Headers) ->
    Lower = binary_to_list(Name),
    case lists:dropwhile(
           fun({Key, _Value}) ->
               string:lowercase(wfcli_text:to_list(Key)) =/= Lower
           end,
           Headers) of
        [{_Key, Value} | _] -> wfcli_text:to_binary(Value);
        [] -> undefined
    end.

usable_cached(Entry) when is_map(Entry) ->
    case maps:get(path, Entry, undefined) of
        Path when is_binary(Path) -> filelib:is_file(binary_to_list(Path));
        _ -> false
    end;
usable_cached(_Entry) -> false.

fresh(Entry) ->
    Now = erlang:system_time(millisecond),
    Now - maps:get(fetched_at, Entry, 0) < ?FRESH_MS.

write_object(Path, Body) ->
    case filelib:is_file(Path) of
        true -> ok;
        false ->
            Temp = Path ++ ".tmp",
            case file:write_file(Temp, Body) of
                ok -> file:rename(Temp, Path);
                {error, _Reason} = Error -> Error
            end
    end.

worker_limit() ->
    case application:get_env(wfdaemon, asset_workers, ?DEFAULT_WORKERS) of
        Count when is_integer(Count), Count > 0 -> Count;
        _ -> ?DEFAULT_WORKERS
    end.

mark_dirty(State = #{persist_timer := undefined}) ->
    Timer = erlang:send_after(?PERSIST_DELAY_MS, self(), persist_index),
    State#{dirty => true, persist_timer => Timer};
mark_dirty(State) -> State#{dirty => true}.

flush_index(State = #{dirty := false}) -> State;
flush_index(State) ->
    case persist_index(maps:get(index_path, State), maps:get(entries, State)) of
        ok -> State#{dirty => false};
        {error, Reason} ->
            logger:warning("asset index persistence failed: ~p", [Reason]),
            Timer = erlang:send_after(?PERSIST_RETRY_MS, self(), persist_index),
            State#{persist_timer => Timer}
    end.

schedule_maintenance(State = #{maintenance_timer := undefined}, Delay) ->
    Timer = erlang:send_after(Delay, self(), maintain_cache),
    State#{maintenance_timer => Timer};
schedule_maintenance(State, _Delay) -> State.

maintain_cache(State) ->
    Entries0 = maps:get(entries, State),
    Entries = maps:filter(fun(_Key, Entry) -> usable_cached(Entry) end, Entries0),
    Referenced = sets:from_list(
                   [filename:absname(binary_to_list(maps:get(path, Entry)))
                    || Entry <- maps:values(Entries)]),
    Objects = filename:join(maps:get(root, State), "objects"),
    {More, _Deleted} = delete_orphans(Objects, Referenced),
    State1 = State#{entries => Entries},
    State2 = case map_size(Entries) =:= map_size(Entries0) of
        true -> State1;
        false -> mark_dirty(State1)
    end,
    {State2, More}.

delete_orphans(Objects, Referenced) ->
    case file:list_dir(Objects) of
        {ok, Names} ->
            Orphans = [filename:join(Objects, Name)
                       || Name <- Names,
                          filelib:is_regular(filename:join(Objects, Name)),
                          not sets:is_element(
                                filename:absname(filename:join(Objects, Name)), Referenced)],
            Batch = lists:sublist(Orphans, ?MAINTENANCE_BATCH),
            lists:foreach(fun(Path) -> _ = file:delete(Path) end, Batch),
            {length(Orphans) > length(Batch), length(Batch)};
        {error, _Reason} -> {false, 0}
    end.

cancel_timer(undefined) -> ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

cancel_monitor(undefined) -> ok;
cancel_monitor(Monitor) -> erlang:demonitor(Monitor, [flush]), ok.

remove_monitor(undefined, Monitors) -> Monitors;
remove_monitor(Monitor, Monitors) -> maps:remove(Monitor, Monitors).

cache_root() ->
    case application:get_env(wfdaemon, asset_cache_dir) of
        {ok, Path} -> Path;
        undefined -> wfcli_paths:cache_file("assets")
    end.

load_index(Path) ->
    case file:read_file(Path) of
        {ok, Binary} ->
            try binary_to_term(Binary, [safe]) of
                #{version := ?CACHE_VERSION, entries := Entries} when is_map(Entries) -> Entries;
                _ -> #{}
            catch _:_ -> #{}
            end;
        {error, _Reason} -> #{}
    end.

persist_index(Path, Entries) ->
    case filelib:ensure_dir(Path) of
        ok ->
            Temp = Path ++ ".tmp",
            Binary = term_to_binary(#{version => ?CACHE_VERSION, entries => Entries},
                                    [compressed]),
            case file:write_file(Temp, Binary) of
                ok -> file:rename(Temp, Path);
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#f))>> || <<Byte>> <= Binary >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.
