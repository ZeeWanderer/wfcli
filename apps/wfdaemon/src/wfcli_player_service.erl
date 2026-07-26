%%%-------------------------------------------------------------------
%% Canonical daemon-owned player dataset.
%%%-------------------------------------------------------------------
-module(wfcli_player_service).

-behaviour(gen_server).

-export([start_link/0, snapshot/0, publish/2, subscribe/1, unsubscribe/1,
         clear/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CACHE_VERSION, 1).

-type snapshot() :: #{
    revision := non_neg_integer(),
    updated_at := integer() | undefined,
    data := map()
}.
-type state() :: #{
    cache_path := file:filename_all(),
    snapshot := snapshot(),
    subscribers := map(),
    monitors := map(),
    game_active := boolean()
}.

-doc "Start daemon-owned player dataset store.".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Return current canonical player snapshot.".
-spec snapshot() -> snapshot().
snapshot() ->
    gen_server:call(?SERVER, snapshot).

-doc "Replace one source-owned player namespace and notify subscribers.".
-spec publish(binary(), map()) -> {ok, snapshot()} | {error, term()}.
publish(Source, Data) ->
    gen_server:call(?SERVER, {publish, Source, Data}).

-doc "Subscribe a local process to player snapshot replacements.".
-spec subscribe(pid()) -> {ok, reference(), snapshot()} | {error, term()}.
subscribe(Client) ->
    gen_server:call(?SERVER, {subscribe, Client}).

-doc "Remove one player dataset subscription.".
-spec unsubscribe(reference()) -> ok.
unsubscribe(Ref) ->
    gen_server:call(?SERVER, {unsubscribe, Ref}).

-doc "Clear all persisted player data.".
-spec clear() -> ok | {error, term()}.
clear() ->
    gen_server:call(?SERVER, clear).

-doc "Return player store revision, source, subscriber, and persistence state.".
-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

-spec init([]) -> {ok, state()}.
init([]) ->
    CachePath = cache_path(),
    Snapshot = load_snapshot(CachePath),
    {ok, #{cache_path => CachePath,
           snapshot => reset_session_state(Snapshot),
           subscribers => #{},
           monitors => #{},
           game_active => false}}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(snapshot, _From, State) ->
    {reply, maps:get(snapshot, State), State};
handle_call({publish, Source, Data}, _From, State)
  when is_binary(Source), is_map(Data) ->
    case valid_source(Source) of
        true -> publish_source(Source, Data, State);
        false -> {reply, {error, {invalid_player_source, Source}}, State}
    end;
handle_call({subscribe, Client}, _From, State) when is_pid(Client) ->
    Ref = make_ref(),
    Monitor = erlang:monitor(process, Client),
    Subscriber = #{client => Client, monitor => Monitor},
    Subscribers = maps:get(subscribers, State),
    Monitors = maps:get(monitors, State),
    {reply, {ok, Ref, maps:get(snapshot, State)},
     State#{subscribers => Subscribers#{Ref => Subscriber},
            monitors => Monitors#{Monitor => Ref}}};
handle_call({unsubscribe, Ref}, _From, State) ->
    {reply, ok, remove_subscriber(Ref, State)};
handle_call(clear, _From, State) ->
    Snapshot = empty_snapshot(),
    case persist_snapshot(maps:get(cache_path, State), Snapshot) of
        ok ->
            State1 = set_game_active(false, State#{snapshot => Snapshot}),
            notify_subscribers(Snapshot, State1),
            {reply, ok, State1};
        {error, Reason} ->
            {reply, {error, {player_cache_write_failed, Reason}}, State}
    end;
handle_call(status, _From, State) ->
    Snapshot = maps:get(snapshot, State),
    Data = maps:get(data, Snapshot),
    {reply, #{revision => maps:get(revision, Snapshot),
              updated_at => maps:get(updated_at, Snapshot),
              sources => lists:sort(maps:keys(Data)),
              subscribers => map_size(maps:get(subscribers, State)),
              cache_path => maps:get(cache_path, State),
              game_active => maps:get(game_active, State)}, State};
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Message, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    case maps:take(Monitor, maps:get(monitors, State)) of
        error -> {noreply, State};
        {Ref, Monitors} ->
            Subscribers = maps:remove(Ref, maps:get(subscribers, State)),
            {noreply, State#{subscribers => Subscribers, monitors => Monitors}}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) -> ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, hot_update) ->
    release_legacy_game_hold(State),
    {ok, State#{game_active => maps:get(game_active, State, false)}};
code_change(_OldVsn, State, _Extra) ->
    {ok, State#{game_active => maps:get(game_active, State, false)}}.

publish_source(Source, Data, State) ->
    OldSnapshot = maps:get(snapshot, State),
    OldData = maps:get(data, OldSnapshot),
    Now = erlang:system_time(millisecond),
    Snapshot = #{revision => maps:get(revision, OldSnapshot) + 1,
                 updated_at => Now,
                 data => OldData#{Source => Data}},
    case persist_snapshot(maps:get(cache_path, State), Snapshot) of
        ok ->
            State1 = maybe_update_game_status(Source, Data,
                                              State#{snapshot => Snapshot}),
            notify_subscribers(Snapshot, State1),
            {reply, {ok, Snapshot}, State1};
        {error, Reason} ->
            {reply, {error, {player_cache_write_failed, Reason}}, State}
    end.

valid_source(Source) when byte_size(Source) > 0, byte_size(Source) =< 64 ->
    lists:all(
      fun(Char) ->
          is_integer(Char, $a, $z) orelse is_integer(Char, $0, $9)
          orelse Char =:= $_ orelse Char =:= $-
      end,
      binary_to_list(Source));
valid_source(_Source) -> false.

maybe_update_game_status(<<"game">>, Data, State) ->
    set_game_active(maps:get(<<"running">>, Data, false) =:= true, State);
maybe_update_game_status(_Source, _Data, State) -> State.

set_game_active(Active, State) -> State#{game_active => Active}.

release_legacy_game_hold(State) ->
    case maps:get(game_active, State, false) of
        true -> wfcli_worldstate_service:activity_end();
        false -> ok
    end.

notify_subscribers(Snapshot, State) ->
    maps:foreach(
      fun(Ref, #{client := Client}) -> Client ! {wfcli_player, Ref, Snapshot} end,
      maps:get(subscribers, State)).

remove_subscriber(Ref, State) ->
    case maps:take(Ref, maps:get(subscribers, State)) of
        error -> State;
        {#{monitor := Monitor}, Subscribers} ->
            erlang:demonitor(Monitor, [flush]),
            Monitors = maps:remove(Monitor, maps:get(monitors, State)),
            State#{subscribers => Subscribers, monitors => Monitors}
    end.

cache_path() ->
    case application:get_env(wfdaemon, player_cache) of
        {ok, Path} -> Path;
        undefined -> wfcli_paths:cache_file("player.term")
    end.

empty_snapshot() ->
    #{revision => 0, updated_at => undefined, data => #{}}.

load_snapshot(Path) ->
    case file:read_file(Path) of
        {ok, Binary} ->
            try binary_to_term(Binary, [safe]) of
                #{version := ?CACHE_VERSION, snapshot := Snapshot}
                  when is_map(Snapshot) -> normalize_snapshot(Snapshot);
                _ -> empty_snapshot()
            catch _:_ -> empty_snapshot()
            end;
        {error, _Reason} -> empty_snapshot()
    end.

normalize_snapshot(Snapshot) ->
    #{revision => maps:get(revision, Snapshot, 0),
      updated_at => maps:get(updated_at, Snapshot, undefined),
      data => maps:get(data, Snapshot, #{})}.

reset_session_state(Snapshot) ->
    Data = maps:get(data, Snapshot),
    case maps:get(<<"game">>, Data, undefined) of
        Game when is_map(Game) ->
            Snapshot#{data => Data#{<<"game">> => Game#{<<"running">> => false}}};
        _ -> Snapshot
    end.

persist_snapshot(Path, Snapshot) ->
    ok = filelib:ensure_dir(Path),
    Temp = Path ++ ".tmp",
    Binary = term_to_binary(#{version => ?CACHE_VERSION, snapshot => Snapshot},
                            [compressed]),
    case file:write_file(Temp, Binary) of
        ok ->
            _ = file:change_mode(Temp, 8#600),
            file:rename(Temp, Path);
        {error, _Reason} = Error -> Error
    end.
