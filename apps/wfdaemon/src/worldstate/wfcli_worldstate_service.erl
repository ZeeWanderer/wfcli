%%%-------------------------------------------------------------------
%% Persistent worldstate fetch, query, and subscription service.
%%%-------------------------------------------------------------------
-module(wfcli_worldstate_service).

-behaviour(gen_server).

-include_lib("wfdaemon/include/wfcli_worldstate.hrl").

-export([start_link/0, submit/2, subscribe/2, unsubscribe/1, status/0,
         set_idle_policy/1,
         activity_start/0, activity_end/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-ifdef(TEST).
-export([initial_idle_shutdown/2]).
-endif.

-define(SERVER, ?MODULE).
-define(DEFAULT_POLL_INTERVAL_MS, 60000).
-define(DEFAULT_IDLE_TIMEOUT_MS, 600000).

-type request() :: map().
-type state() :: map().

-doc "Start daemon-owned worldstate store and scheduler.".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Queue a one-shot request; result arrives as `{wfcli_daemon, Ref, Reply}`.".
-spec submit(pid(), request()) -> {ok, reference()} | {error, term()}.
submit(Client, Request) ->
    gen_server:call(?SERVER, {submit, Client, Request}).

-doc "Register persistent watch; updates arrive as `{wfcli_daemon, Ref, Reply}`.".
-spec subscribe(pid(), request()) -> {ok, reference()} | {error, term()}.
subscribe(Client, Request) ->
    gen_server:call(?SERVER, {subscribe, Client, Request}).

-doc "Remove one watch or queued request by reference.".
-spec unsubscribe(reference()) -> ok.
unsubscribe(Ref) ->
    gen_server:call(?SERVER, {unsubscribe, Ref}).

-doc "Return queue, watch, and snapshot counts for daemon status.".
-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

-doc "Set runtime shutdown policy without disturbing queued work or subscriptions.".
-spec set_idle_policy(persistent | idle | {idle, pos_integer()}) -> ok | {error, term()}.
set_idle_policy(Policy) ->
    gen_server:call(?SERVER, {set_idle_policy, Policy}).

-doc "Keep daemon alive while another persistent service has queued or active work.".
-spec activity_start() -> ok.
activity_start() ->
    gen_server:cast(?SERVER, {activity_start, self()}).

-doc "Release one external activity hold and re-arm idle shutdown when fully idle.".
-spec activity_end() -> ok.
activity_end() ->
    gen_server:cast(?SERVER, {activity_end, self()}).

-spec init([]) -> {ok, state()}.
init([]) ->
    PollMs = daemon_env(daemon_poll_interval_ms, ?DEFAULT_POLL_INTERVAL_MS),
    IdleMs = daemon_env(daemon_idle_timeout_ms, ?DEFAULT_IDLE_TIMEOUT_MS),
    ConfiguredIdle = daemon_env(daemon_idle_shutdown, false),
    IdleEnabled = initial_idle_shutdown(os:getenv("WFCLI_DAEMON_IDLE_POLICY"), ConfiguredIdle),
    IdleNotify = daemon_env(daemon_idle_notify_pid, undefined),
    State0 = #{datasets => #{}, one_shots => #{}, watches => #{}, monitors => #{},
               external_activity => #{}, activity_monitors => #{},
               poll_timer => undefined, idle_timer => undefined,
               poll_interval_ms => PollMs, idle_timeout_ms => IdleMs,
               default_idle_timeout_ms => IdleMs,
               idle_shutdown => IdleEnabled, idle_notify => IdleNotify},
    {ok, maybe_arm_idle(State0)}.

initial_idle_shutdown("persistent", _Configured) -> false;
initial_idle_shutdown(_Environment, Configured) -> Configured.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call({submit, Client, Request}, _From, State) when is_pid(Client), is_map(Request) ->
    case maps:get(source, Request, worldstate) of
        Source when Source =:= worldstate; Source =:= trader; Source =:= teshin ->
            case prepare_submission(Source, Request) of
                {ok, Prepared} ->
                    Ref = make_ref(),
                    Monitor = erlang:monitor(process, Client),
                    Key = dataset_key(Prepared),
                    Sub = #{kind => one_shot, ref => Ref, client => Client, monitor => Monitor,
                            request => Prepared, dataset => Key},
                    State1 = cancel_idle(State),
                    State2 = put_subscription(one_shots, Ref, Sub, State1),
                    State3 = put_monitor(Monitor, {one_shot, Ref}, State2),
                    State4 = ensure_request_ready(Key, Ref, Prepared, State3),
                    {reply, {ok, Ref}, State4};
                {error, _Reason} = Error -> {reply, Error, State}
            end;
        Source ->
            {reply, {error, {unsupported_source, Source}}, State}
    end;
handle_call({subscribe, Client, Request0}, _From, State) when is_pid(Client), is_map(Request0) ->
    case maps:get(source, Request0, worldstate) of
        worldstate ->
            case wfcli_worldstate_ops:prepare_watch(Request0) of
                {ok, Request} ->
                    Ref = make_ref(),
                    Monitor = erlang:monitor(process, Client),
                    Key = dataset_key(Request),
                    IntervalMs = max(1000, maps:get(interval, Request, 60) * 1000),
                    Sub = #{kind => watch, ref => Ref, client => Client, monitor => Monitor,
                            request => Request, dataset => Key, previous => #{},
                            next_due => erlang:monotonic_time(millisecond), interval_ms => IntervalMs},
                    State1 = cancel_idle(State),
                    State2 = put_subscription(watches, Ref, Sub, State1),
                    State3 = put_monitor(Monitor, {watch, Ref}, State2),
                    State4 = ensure_watch_ready(Key, Ref, Request, State3),
                    State5 = ensure_poll_timer(State4),
                    {reply, {ok, Ref}, State5};
                {error, _Reason} = Error -> {reply, Error, State}
            end;
        Source ->
            {reply, {error, {unsupported_source, Source}}, State}
    end;
handle_call({unsubscribe, Ref}, _From, State) ->
    {reply, ok, maybe_idle(remove_subscription(Ref, State))};
handle_call({set_idle_policy, persistent}, _From, State) ->
    State1 = cancel_idle(State#{idle_shutdown => false}),
    {reply, ok, State1};
handle_call({set_idle_policy, idle}, _From, State) ->
    DefaultMs = maps:get(default_idle_timeout_ms, State, ?DEFAULT_IDLE_TIMEOUT_MS),
    State1 = cancel_idle(State#{idle_shutdown => true, idle_timeout_ms => DefaultMs}),
    {reply, ok, maybe_idle(State1)};
handle_call({set_idle_policy, {idle, TimeoutMs}}, _From, State)
  when is_integer(TimeoutMs), TimeoutMs > 0 ->
    State1 = cancel_idle(State#{idle_shutdown => true, idle_timeout_ms => TimeoutMs}),
    {reply, ok, maybe_idle(State1)};
handle_call({set_idle_policy, Policy}, _From, State) ->
    {reply, {error, {invalid_idle_policy, Policy}}, State};
handle_call(status, _From, State) ->
    Datasets = maps:get(datasets, State),
    Reply = #{datasets => map_size(Datasets),
              snapshots => length([ok || {_Key, Dataset} <- maps:to_list(Datasets),
                                          maps:get(snapshot, Dataset, undefined) =/= undefined]),
              one_shots => map_size(maps:get(one_shots, State)),
              watches => map_size(maps:get(watches, State)),
              fetching => length([ok || {_Key, Dataset} <- maps:to_list(Datasets),
                                        maps:get(fetch, Dataset, undefined) =/= undefined]),
              external_activity => external_activity_count(State),
              idle_policy => idle_policy(State),
              idle_timeout_ms => maps:get(idle_timeout_ms, State)},
    {reply, Reply, State};
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast({activity_start, Owner}, State) when is_pid(Owner) ->
    {noreply, cancel_idle(add_external_activity(Owner, State))};
handle_cast({activity_end, Owner}, State) when is_pid(Owner) ->
    {noreply, maybe_idle(remove_external_activity(Owner, State))};
handle_cast(_Message, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({dispatch_one_shots, Key}, State) ->
    {noreply, maybe_idle(dispatch_one_shots(Key, memory, State))};
handle_info({dispatch_one_shot, Ref, Delivery}, State) ->
    {noreply, maybe_idle(dispatch_one_shot(Ref, Delivery, State))};
handle_info({evaluate_watch, Ref}, State) ->
    {noreply, maybe_idle(evaluate_watch(Ref, memory, State))};
handle_info({evaluate_watch, Ref, Delivery}, State) ->
    {noreply, maybe_idle(evaluate_watch(Ref, Delivery, State))};
handle_info({worldstate_fetch_result, Key, Token, Result}, State) ->
    {noreply, maybe_idle(handle_fetch_result(Key, Token, Result, State))};
handle_info({'DOWN', Monitor, process, _Pid, Reason}, State) ->
    case find_fetch_monitor(Monitor, State) of
        {ok, Key, Token} ->
            {noreply, maybe_idle(handle_fetch_result(
                                   Key, Token, {error, {fetch_worker_down, Reason}}, State))};
        error ->
            case maps:get(Monitor, maps:get(activity_monitors, State, #{}), undefined) of
                undefined -> handle_client_down(Monitor, State);
                Owner -> {noreply, maybe_idle(drop_external_activity(Owner, Monitor, State))}
            end
    end;
handle_info(poll, State) ->
    State1 = State#{poll_timer => undefined},
    Keys = watch_dataset_keys(State1),
    State2 = lists:foldl(fun poll_dataset/2, State1, Keys),
    {noreply, ensure_poll_timer(State2)};
handle_info(idle_timeout, State) ->
    case idle(State) andalso maps:get(idle_shutdown, State, false) of
        true ->
            perform_idle_action(State),
            {noreply, State#{idle_timer => undefined}};
        false ->
            {noreply, maybe_arm_idle(State#{idle_timer => undefined})}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

handle_client_down(Monitor, State) ->
    case maps:get(Monitor, maps:get(monitors, State), undefined) of
        undefined -> {noreply, State};
        {_Kind, Ref} -> {noreply, maybe_idle(remove_subscription(Ref, State))}
    end.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, State) ->
    cancel_timer(maps:get(poll_timer, State, undefined)),
    cancel_timer(maps:get(idle_timer, State, undefined)),
    [erlang:demonitor(Monitor, [flush])
     || Monitor <- maps:keys(maps:get(activity_monitors, State, #{}))],
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    DefaultMs = maps:get(
                  default_idle_timeout_ms,
                  State,
                  daemon_env(daemon_idle_timeout_ms, ?DEFAULT_IDLE_TIMEOUT_MS)),
    Activity = case maps:get(external_activity, State, #{}) of
        Owners when is_map(Owners) -> Owners;
        _LegacyCount -> #{}
    end,
    ActivityMonitors = case maps:get(activity_monitors, State, #{}) of
        Monitors when is_map(Monitors) -> Monitors;
        _ -> #{}
    end,
    {ok, State#{default_idle_timeout_ms => DefaultMs,
                external_activity => Activity,
                activity_monitors => ActivityMonitors}}.

dataset_key(Request) ->
    Source = maps:get(source, Request, worldstate),
    Opts = maps:get(opts, Request, #{}),
    Default = case Source of
        trader -> wfcli_worldstate:default_trader_cache();
        teshin -> calculated;
        _ -> wfcli_worldstate:default_cache()
    end,
    {Source, maps:get(cache, Opts, Default)}.

new_dataset() ->
    #{snapshot => undefined, variants => #{}, fetched_at => 0,
      source => undefined, fetch => undefined, last_error => undefined}.

get_dataset(Key, State) ->
    maps:get(Key, maps:get(datasets, State), new_dataset()).

put_dataset(Key, Dataset, State) ->
    Datasets = maps:get(datasets, State),
    State#{datasets => Datasets#{Key => Dataset}}.

put_subscription(Bucket, Ref, Sub, State) ->
    Subs = maps:get(Bucket, State),
    State#{Bucket => Subs#{Ref => Sub}}.

put_monitor(Monitor, Value, State) ->
    Monitors = maps:get(monitors, State),
    State#{monitors => Monitors#{Monitor => Value}}.

ensure_request_ready(Key, Ref, Request, State) ->
    Dataset = get_dataset(Key, State),
    case snapshot_fresh(Request, Dataset) of
        true ->
            self() ! {dispatch_one_shot, Ref, memory},
            State;
        false ->
            start_fetch(Key, Request, State)
    end.

ensure_watch_ready(Key, Ref, Request, State) ->
    Dataset = get_dataset(Key, State),
    case snapshot_fresh(Request, Dataset) of
        true ->
            self() ! {evaluate_watch, Ref, memory},
            State;
        false ->
            start_fetch(Key, Request, State)
    end.

snapshot_fresh(Request, Dataset) ->
    case {maps:get(snapshot, Dataset, undefined), maps:get(refresh, maps:get(opts, Request, #{}), false)} of
        {undefined, _} -> false;
        {_, true} -> false;
        {_, false} ->
            TtlMs = maps:get(ttl, maps:get(opts, Request, #{}), 60) * 1000,
            age_ms(Dataset) =< TtlMs
    end.

age_ms(Dataset) ->
    max(0, erlang:monotonic_time(millisecond) - maps:get(fetched_at, Dataset, 0)).

start_fetch(Key, Request, State) ->
    Dataset = get_dataset(Key, State),
    case maps:get(fetch, Dataset, undefined) of
        undefined ->
            Token = make_ref(),
            Parent = self(),
            LoadOpts = fetch_opts(Key, Request, Dataset),
            Source = maps:get(source, Request, worldstate),
            {_Pid, Monitor} = spawn_monitor(fun() ->
                Result = try fetch_source(Source, LoadOpts)
                         catch Class:Reason:Stack -> {error, {fetch_crash, Class, Reason, Stack}}
                         end,
                Parent ! {worldstate_fetch_result, Key, Token, Result}
            end),
            put_dataset(Key, Dataset#{fetch => #{token => Token, monitor => Monitor}}, State);
        _ ->
            State
    end.

fetch_opts({_Source, Cache}, Request, Dataset) ->
    RequestOpts = maps:get(opts, Request, #{}),
    Force = maps:get(refresh, RequestOpts, false) orelse
            maps:get(snapshot, Dataset, undefined) =/= undefined,
    Base = #{cache => Cache,
             ttl => maps:get(ttl, RequestOpts, 60),
             refresh => Force,
             resolve_items => true,
             raw => false,
             search_raw => false},
    case daemon_env(daemon_worldstate_fetch_fun, undefined) of
        Fun when is_function(Fun, 0) -> Base#{fetch_fun => Fun};
        _ -> Base
    end.

handle_fetch_result(Key, Token, Result, State) ->
    Dataset = get_dataset(Key, State),
    case maps:get(fetch, Dataset, undefined) of
        #{token := Token, monitor := Monitor} ->
            erlang:demonitor(Monitor, [flush]),
            {State1, Delivery} = case Result of
                {ok, Ws, Source} ->
                    DefaultVariant = {true, false, false, undefined},
                    Dataset1 = Dataset#{snapshot => Ws, variants => #{DefaultVariant => Ws},
                                        fetched_at => erlang:monotonic_time(millisecond),
                                        source => Source, fetch => undefined,
                                        last_error => undefined},
                    {put_dataset(Key, Dataset1, State), Source};
                {error, FetchReason} ->
                    {put_dataset(Key, Dataset#{fetch => undefined, last_error => FetchReason}, State),
                     memory}
            end,
            State2 = dispatch_one_shots(Key, Delivery, State1),
            case {Result, maps:get(snapshot, get_dataset(Key, State2), undefined)} of
                {{error, NotifyReason}, undefined} -> notify_watch_errors(Key, NotifyReason, State2);
                _ -> evaluate_due_watches(Key, Delivery, State2)
            end;
        _ ->
            State
    end.

find_fetch_monitor(Monitor, State) ->
    case [{Key, maps:get(token, Fetch)}
          || {Key, Dataset} <- maps:to_list(maps:get(datasets, State)),
             Fetch <- [maps:get(fetch, Dataset, undefined)],
             is_map(Fetch), maps:get(monitor, Fetch, undefined) =:= Monitor] of
        [{Key, Token} | _] -> {ok, Key, Token};
        [] -> error
    end.

notify_watch_errors(Key, Reason, State) ->
    Refs = [Ref || {Ref, Sub} <- maps:to_list(maps:get(watches, State)),
                   maps:get(dataset, Sub) =:= Key],
    lists:foreach(
      fun(Ref) ->
          Sub = maps:get(Ref, maps:get(watches, State)),
          maps:get(client, Sub) ! {wfcli_daemon, Ref, {error, Reason}}
      end,
      Refs),
    State.

dispatch_one_shots(Key, Delivery, State) ->
    Refs = [Ref || {Ref, Sub} <- maps:to_list(maps:get(one_shots, State)),
                   maps:get(dataset, Sub) =:= Key],
    lists:foldl(fun(Ref, Acc) -> dispatch_one_shot(Ref, Delivery, Acc) end, State, Refs).

dispatch_one_shot(Ref, Delivery, State) ->
    case maps:get(Ref, maps:get(one_shots, State), undefined) of
        undefined -> State;
        Sub ->
            Key = maps:get(dataset, Sub),
            Dataset = get_dataset(Key, State),
            Reply = case maps:get(snapshot, Dataset, undefined) of
                undefined -> {error, maps:get(last_error, Dataset, no_worldstate)};
                _ -> execute_request(maps:get(request, Sub), Dataset, Delivery)
            end,
            case Reply of
                {ok, Result1, Dataset2} ->
                    maps:get(client, Sub) ! {wfcli_daemon, Ref, {ok, Result1}},
                    remove_subscription(Ref, put_dataset(Key, Dataset2, State));
                {error, Reason, Dataset2} ->
                    maps:get(client, Sub) ! {wfcli_daemon, Ref, {error, Reason}},
                    remove_subscription(Ref, put_dataset(Key, Dataset2, State));
                Error ->
                    maps:get(client, Sub) ! {wfcli_daemon, Ref, Error},
                    remove_subscription(Ref, State)
            end
    end.

execute_request(Request, Dataset, Delivery) ->
    case maps:get(source, Request, worldstate) of
        trader ->
            Result = maps:merge(
                       #{kind => trader, entries => maps:get(snapshot, Dataset)},
                       snapshot_metadata(Dataset, Delivery)),
            {ok, Result, Dataset};
        worldstate -> execute_worldstate_request(Request, Dataset, Delivery);
        teshin -> execute_worldstate_request(Request, Dataset, Delivery)
    end.

execute_worldstate_request(Request, Dataset, Delivery) ->
    {Ws, Dataset1} = ensure_variant(maps:get(opts, Request, #{}), Dataset),
    case wfcli_worldstate_ops:execute(Ws, Request) of
        {error, Reason} -> {error, Reason, Dataset1};
        Result0 ->
            Result = maps:merge(Result0, snapshot_metadata(Dataset1, Delivery)),
            {ok, Result, Dataset1}
    end.

prepare_submission(worldstate, Request) -> wfcli_worldstate_ops:prepare_request(Request);
prepare_submission(_Source, Request) -> {ok, Request}.

snapshot_metadata(Dataset, Delivery) ->
    AgeMs = age_ms(Dataset),
    Origin = maps:get(source, Dataset, undefined),
    #{source => Delivery,
      snapshot_origin => Origin,
      snapshot_age_ms => AgeMs,
      fetched_age_ms => AgeMs,
      stale => Origin =:= cached_stale orelse
               maps:get(last_error, Dataset, undefined) =/= undefined,
      fetch_error => maps:get(last_error, Dataset, undefined)}.

fetch_source(worldstate, Opts) -> wfcli_worldstate:load(Opts);
fetch_source(trader, Opts) -> wfcli_worldstate:load_trader_inventory(Opts);
fetch_source(teshin, Opts) -> wfcli_teshin:load(Opts).

ensure_variant(Opts, Dataset) ->
    Key = variant_key(Opts),
    Variants = maps:get(variants, Dataset, #{}),
    case maps:get(Key, Variants, undefined) of
        undefined ->
            Base = maps:get(snapshot, Dataset),
            VariantOpts = variant_opts(Opts),
            Ws = wfcli_worldstate:reindex(Base, VariantOpts),
            {Ws, Dataset#{variants => Variants#{Key => Ws}}};
        Ws ->
            {Ws, Dataset}
    end.

variant_key(Opts) ->
    {maps:get(resolve_items, Opts, true),
     maps:get(raw, Opts, false),
     maps:get(search_raw, Opts, maps:get(raw, Opts, false)),
     maps:get(event_lang, Opts, undefined)}.

variant_opts(Opts) ->
    #{resolve_items => maps:get(resolve_items, Opts, true),
      raw => maps:get(raw, Opts, false),
      search_raw => maps:get(search_raw, Opts, maps:get(raw, Opts, false)),
      event_lang => maps:get(event_lang, Opts, undefined)}.

evaluate_due_watches(Key, Delivery, State) ->
    Now = erlang:monotonic_time(millisecond),
    Refs = [Ref || {Ref, Sub} <- maps:to_list(maps:get(watches, State)),
                   maps:get(dataset, Sub) =:= Key,
                   maps:get(next_due, Sub, 0) =< Now],
    lists:foldl(fun(Ref, Acc) -> evaluate_watch(Ref, Delivery, Acc) end, State, Refs).

evaluate_watch(Ref, Delivery, State) ->
    case maps:get(Ref, maps:get(watches, State), undefined) of
        undefined -> State;
        Sub ->
            Key = maps:get(dataset, Sub),
            Dataset = get_dataset(Key, State),
            case maps:get(snapshot, Dataset, undefined) of
                undefined -> State;
                _ ->
                    Request = maps:get(request, Sub),
                    {Ws, Dataset1} = ensure_variant(maps:get(opts, Request, #{}), Dataset),
                    {Update0, Previous} = wfcli_worldstate_ops:evaluate_watch(
                                           Ws, Request, maps:get(previous, Sub, #{})),
                    Update = maps:merge(Update0, snapshot_metadata(Dataset1, Delivery)),
                    Initial = maps:get(previous, Sub, #{}) =:= #{},
                    Always = maps:get(always, Request, false),
                    ShouldSend = Initial orelse Always orelse maps:get(changed, Update, false),
                    case ShouldSend of
                        true -> maps:get(client, Sub) ! {wfcli_daemon, Ref, {ok, Update}};
                        false -> ok
                    end,
                    State1 = put_dataset(Key, Dataset1, State),
                    case maps:get(once, Request, false) of
                        true -> remove_subscription(Ref, State1);
                        false ->
                            NextDue = erlang:monotonic_time(millisecond) + maps:get(interval_ms, Sub),
                            Sub1 = Sub#{previous => Previous, next_due => NextDue},
                            Watches = maps:get(watches, State1),
                            State1#{watches => Watches#{Ref => Sub1}}
                    end
            end
    end.

poll_dataset(Key, State) ->
    case first_watch_request(Key, State) of
        undefined -> State;
        Request ->
            Opts = maps:get(opts, Request, #{}),
            start_fetch(Key, Request#{opts => Opts#{refresh => true}}, State)
    end.

first_watch_request(Key, State) ->
    case [maps:get(request, Sub) || {_Ref, Sub} <- maps:to_list(maps:get(watches, State)),
                                    maps:get(dataset, Sub) =:= Key] of
        [Request | _] -> Request;
        [] -> undefined
    end.

watch_dataset_keys(State) ->
    lists:usort([maps:get(dataset, Sub) || {_Ref, Sub} <- maps:to_list(maps:get(watches, State))]).

ensure_poll_timer(State) ->
    case {map_size(maps:get(watches, State)), maps:get(poll_timer, State, undefined)} of
        {0, Timer} ->
            cancel_timer(Timer),
            State#{poll_timer => undefined};
        {_, undefined} ->
            Timer = erlang:send_after(maps:get(poll_interval_ms, State), self(), poll),
            State#{poll_timer => Timer};
        _ -> State
    end.

remove_subscription(Ref, State) ->
    case find_subscription(Ref, State) of
        undefined -> State;
        {Bucket, Sub} ->
            Monitor = maps:get(monitor, Sub),
            erlang:demonitor(Monitor, [flush]),
            Subs = maps:remove(Ref, maps:get(Bucket, State)),
            Monitors = maps:remove(Monitor, maps:get(monitors, State)),
            ensure_poll_timer(State#{Bucket => Subs, monitors => Monitors})
    end.

find_subscription(Ref, State) ->
    case maps:get(Ref, maps:get(one_shots, State), undefined) of
        undefined ->
            case maps:get(Ref, maps:get(watches, State), undefined) of
                undefined -> undefined;
                Sub -> {watches, Sub}
            end;
        Sub -> {one_shots, Sub}
    end.

add_external_activity(Owner, State) ->
    Owners = maps:get(external_activity, State, #{}),
    case maps:get(Owner, Owners, 0) of
        0 ->
            Monitor = erlang:monitor(process, Owner),
            Monitors = maps:get(activity_monitors, State, #{}),
            State#{external_activity => Owners#{Owner => 1},
                   activity_monitors => Monitors#{Monitor => Owner}};
        Count ->
            State#{external_activity => Owners#{Owner := Count + 1}}
    end.

remove_external_activity(Owner, State) ->
    Owners = maps:get(external_activity, State, #{}),
    case maps:get(Owner, Owners, 0) of
        0 -> State;
        1 ->
            Monitors = maps:get(activity_monitors, State, #{}),
            case [Monitor || {Monitor, MonitoredOwner} <- maps:to_list(Monitors),
                             MonitoredOwner =:= Owner] of
                [Monitor] ->
                    erlang:demonitor(Monitor, [flush]),
                    State#{external_activity => maps:remove(Owner, Owners),
                           activity_monitors => maps:remove(Monitor, Monitors)};
                [] ->
                    State#{external_activity => maps:remove(Owner, Owners)}
            end;
        Count ->
            State#{external_activity => Owners#{Owner := Count - 1}}
    end.

drop_external_activity(Owner, Monitor, State) ->
    Owners = maps:get(external_activity, State, #{}),
    Monitors = maps:get(activity_monitors, State, #{}),
    State#{external_activity => maps:remove(Owner, Owners),
           activity_monitors => maps:remove(Monitor, Monitors)}.

external_activity_count(State) ->
    lists:sum(maps:values(maps:get(external_activity, State, #{}))).

idle(State) ->
    map_size(maps:get(one_shots, State)) =:= 0 andalso
    map_size(maps:get(watches, State)) =:= 0 andalso
    map_size(maps:get(external_activity, State, #{})) =:= 0 andalso
    lists:all(fun({_Key, Dataset}) -> maps:get(fetch, Dataset, undefined) =:= undefined end,
              maps:to_list(maps:get(datasets, State))).

idle_policy(#{idle_shutdown := true}) -> idle;
idle_policy(_State) -> persistent.

maybe_idle(State) ->
    case idle(State) of
        true -> maybe_arm_idle(State);
        false -> cancel_idle(State)
    end.

maybe_arm_idle(State = #{idle_shutdown := false}) -> State;
maybe_arm_idle(State) ->
    case maps:get(idle_timer, State, undefined) of
        undefined ->
            Timer = erlang:send_after(maps:get(idle_timeout_ms, State), self(), idle_timeout),
            State#{idle_timer => Timer};
        _ -> State
    end.

cancel_idle(State) ->
    cancel_timer(maps:get(idle_timer, State, undefined)),
    State#{idle_timer => undefined}.

cancel_timer(undefined) -> ok;
cancel_timer(Timer) ->
    _ = erlang:cancel_timer(Timer),
    ok.

perform_idle_action(#{idle_notify := Pid}) when is_pid(Pid) ->
    Pid ! {wfcli_daemon_idle, self()},
    ok;
perform_idle_action(_State) ->
    _ = spawn(fun() -> timer:sleep(20), init:stop() end),
    ok.

daemon_env(Key, Default) ->
    application:get_env(wfdaemon, Key, Default).
