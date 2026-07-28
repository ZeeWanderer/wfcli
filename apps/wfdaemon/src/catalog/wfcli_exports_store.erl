%%%-------------------------------------------------------------------
%% Persistent searchable export/knowledge catalog and queued query worker.
%%%-------------------------------------------------------------------
-module(wfcli_exports_store).

-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").

-export([start_link/0, submit/2, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CACHE_VERSION, 4).

-type state() :: map().

-doc "Start daemon-owned searchable export and knowledge cache.".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Queue one export query; reply arrives as `{wfcli_daemon, Ref, Reply}`.".
-spec submit(pid(), map()) -> {ok, reference()} | {error, term()}.
submit(Client, Request) ->
    gen_server:call(?SERVER, {submit, Client, Request}).

-doc "Return export queue and searchable catalog cache counts.".
-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

-spec init([]) -> {ok, state()}.
init([]) ->
    {ok, #{queue => queue:new(), current => undefined, monitors => #{}, cache => #{}}}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call({submit, Client, Request}, _From, State) when is_pid(Client), is_map(Request) ->
    Ref = make_ref(),
    Monitor = erlang:monitor(process, Client),
    Item = #{ref => Ref, client => Client, monitor => Monitor, request => Request},
    Queue = queue:in(Item, maps:get(queue, State)),
    Monitors = maps:get(monitors, State),
    wfcli_worldstate_service:activity_start(),
    self() ! process_queue,
    {reply, {ok, Ref}, State#{queue => Queue, monitors => Monitors#{Monitor => Ref}}};
handle_call(status, _From, State) ->
    {reply, #{queued => queue:len(maps:get(queue, State)),
              processing => maps:get(current, State, undefined) =/= undefined,
              cached_datasets => map_size(maps:get(cache, State)),
              cached_catalogs => map_size(maps:get(cache, State))}, State};
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Message, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(process_queue, State) ->
    case maps:get(current, State, undefined) of
        Current when Current =/= undefined ->
            {noreply, State};
        undefined ->
            start_next_item(State)
    end;
handle_info({catalog_result, Token, Reply, Cache},
            State = #{current := #{token := Token, worker_monitor := WorkerMonitor,
                                   item := Item}}) ->
    erlang:demonitor(WorkerMonitor, [flush]),
    State1 = complete_item(Item, Reply, State#{current => undefined, cache => Cache}),
    self() ! process_queue,
    {noreply, State1};
handle_info({'DOWN', Monitor, process, _Pid, Reason},
            State = #{current := #{worker_monitor := Monitor, item := Item}}) ->
    State1 = complete_item(Item, {error, {catalog_worker_down, Reason}},
                           State#{current => undefined}),
    self() ! process_queue,
    {noreply, State1};
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    case cancel_client(Monitor, State) of
        {not_found, State1} -> {noreply, State1};
        {canceled, State1} ->
            self() ! process_queue,
            {noreply, State1}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, State) ->
    stop_worker(maps:get(current, State, undefined)),
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    Cache = maps:get(cache, State, #{}),
    Current = maps:filter(fun(Key, _Value) -> current_cache_key(Key) end, Cache),
    State1 = maps:remove(processing, State),
    {ok, State1#{cache => Current,
                 current => maps:get(current, State1, undefined)}}.

current_cache_key(Key) when is_tuple(Key) ->
    case tuple_to_list(Key) of
        [?CACHE_VERSION, entities | _] -> true;
        _ -> false
    end;
current_cache_key(_Key) -> false.

start_next_item(State) ->
    case queue:out(maps:get(queue, State)) of
        {empty, Queue} ->
            {noreply, State#{queue => Queue}};
        {{value, Item}, Queue} ->
            Parent = self(),
            Token = make_ref(),
            Cache = maps:get(cache, State),
            {Pid, WorkerMonitor} = spawn_monitor(fun() ->
                {Reply, ExecuteState} = safe_execute(maps:get(request, Item),
                                                     #{cache => Cache}),
                Parent ! {catalog_result, Token, Reply, maps:get(cache, ExecuteState)}
            end),
            Current = #{token => Token, worker_pid => Pid,
                        worker_monitor => WorkerMonitor, item => Item},
            {noreply, State#{queue => Queue, current => Current}}
    end.

complete_item(Item, Reply, State) ->
    Ref = maps:get(ref, Item),
    Monitor = maps:get(monitor, Item),
    case maps:is_key(Monitor, maps:get(monitors, State)) of
        false -> State;
        true ->
            maps:get(client, Item) ! {wfcli_daemon, Ref, Reply},
            erlang:demonitor(Monitor, [flush]),
            Monitors = maps:remove(Monitor, maps:get(monitors, State)),
            wfcli_worldstate_service:activity_end(),
            State#{monitors => Monitors}
    end.

cancel_client(Monitor, State) ->
    case maps:take(Monitor, maps:get(monitors, State)) of
        error ->
            {not_found, State};
        {Ref, Monitors} ->
            Queue = queue:filter(fun(Item) -> maps:get(ref, Item) =/= Ref end,
                                 maps:get(queue, State)),
            Current = maps:get(current, State, undefined),
            Current1 = case Current of
                #{item := #{ref := Ref}} ->
                    stop_worker(Current),
                    undefined;
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

safe_execute(Request, State) ->
    safe_execute_hook(Request, State).

-ifdef(TEST).
safe_execute_hook(Request, State) ->
    case application:get_env(wfdaemon, daemon_catalog_execute_fun, undefined) of
        Fun when is_function(Fun, 2) -> Fun(Request, State);
        undefined -> safe_execute_default(Request, State)
    end.
-else.
safe_execute_hook(Request, State) ->
    safe_execute_default(Request, State).
-endif.

safe_execute_default(Request, State) ->
    try execute(Request, State) of
        Result -> Result
    catch
        Class:Reason:Stacktrace ->
            logger:error("catalog query failed: ~p:~p~n~p", [Class, Reason, Stacktrace]),
            {{error, {catalog_query_failed, Class, Reason}}, State}
    end.

execute(Request, State) ->
    Command = maps:get(command, Request),
    Cwd = maps:get(cwd, Request, filename:absname(".")),
    case {query_service(Command), maps:find(query, Request)} of
        {{ok, Service}, {ok, Query0}} ->
            RequestQuery = normalize_query_paths(Query0, Cwd),
            case prepare_query(Service, Command, RequestQuery) of
                {ok, Query} ->
                    case ensure_sources(Command, Query) of
                        ok ->
                            case cached_entries(Command, Query, State) of
                                {ok, Cached, State1} ->
                                    case execute_entries(Service, Command, Query, Cached) of
                                        {ok, Query1, Results} ->
                                            {{ok, #{command => Command, query => Query1,
                                                    results => Results}}, State1};
                                        {error, Errors} -> {{error, {query_errors, Errors}}, State1}
                                    end;
                                {error, Reason, State1} ->
                                    {{error, Reason}, State1}
                            end;
                        {error, Reason} ->
                            {{error, Reason}, State}
                    end;
                {error, Errors} ->
                    {{error, {query_errors, Errors}}, State}
            end;
        {error, _} ->
            {{error, {unsupported_catalog_command, Command}}, State};
        {_, error} ->
            {{error, missing_typed_query}, State}
    end.

query_service(Command) when Command =:= "mods"; Command =:= "items" ->
    {ok, wfcli_exports_query};
query_service(Command) when Command =:= "codex"; Command =:= "enemies"; Command =:= "drops" ->
    {ok, wfcli_knowledge_query};
query_service(_Command) -> error.

prepare_query(wfcli_exports_query, Command, Query) ->
    wfcli_exports_query:prepare(Command, Query);
prepare_query(wfcli_knowledge_query, Command, Query) ->
    wfcli_knowledge_query:prepare(Command, Query).

ensure_sources(Command, Query) ->
    try wfcli_source_manager:ensure_catalog(Command, Query)
    catch
        exit:{noproc, _} -> {error, source_manager_unavailable};
        exit:Reason -> {error, {source_manager_failed, Reason}}
    end.

execute_entries(wfcli_exports_query, Command, Query, #{entries := Entries}) ->
    wfcli_exports_query:execute_entries(Command, Query, Entries);
execute_entries(wfcli_knowledge_query, Command, Query,
                #{entries := Entries, source_meta := Meta}) ->
    wfcli_knowledge_query:execute_entries(Command, Query, Entries, Meta).

cached_entries("mods", Parsed, State) ->
    Dir = maps:get(exports_dir, Parsed, undefined),
    Raw = maps:get(raw, Parsed, false),
    Paths = [wfcli_exports:mod_source(Dir)],
    cached({?CACHE_VERSION, entities, mods, Dir, Raw}, Paths,
           fun() ->
               case wfcli_exports:load_mods(Dir) of
                   {ok, Data} ->
                       {ok, #{entries => wfcli_exports_query:build_entries("mods", Parsed, Data)}};
                   {error, Reason} -> {error, Reason}
               end
           end, State);
cached_entries("items", Parsed, State) ->
    Dir = maps:get(exports_dir, Parsed, undefined),
    Raw = maps:get(raw, Parsed, false),
    Files = maps:get(files, Parsed, []),
    Sources = wfcli_exports:item_sources(Dir, Files),
    Paths = [Path || {_File, Path} <- Sources],
    Key = {?CACHE_VERSION, entities, items, Dir, [File || {File, _Path} <- Sources], Raw},
    cached(Key, Paths,
           fun() ->
               case wfcli_exports:load_items(Dir, Files) of
                   {ok, Data} ->
                       {ok, #{entries => wfcli_exports_query:build_entries("items", Parsed, Data)}};
                   {error, Reason} -> {error, Reason}
               end
           end, State);
cached_entries("codex", Parsed, State) ->
    Dir = maps:get(exports_dir, Parsed, undefined),
    Sources = wfcli_knowledge:codex_sources(Dir),
    Paths = [Path || {_File, Path} <- Sources],
    cached({?CACHE_VERSION, entities, codex, Dir}, Paths,
           fun() -> build_knowledge_cache("codex", Parsed) end, State);
cached_entries(Command, Parsed, State) when Command =:= "enemies"; Command =:= "drops" ->
    Dir = maps:get(knowledge_dir, Parsed, undefined),
    Path = wfcli_knowledge:wfcd_source(Dir),
    cached({?CACHE_VERSION, entities, Command, Path}, [Path],
           fun() -> build_knowledge_cache(Command, Parsed) end, State).

build_knowledge_cache(Command, Parsed) ->
    case wfcli_knowledge_query:load_data(Command, Parsed) of
        {ok, Data, Meta} ->
            Entries = wfcli_knowledge_query:build_entries(Command, Parsed, Data),
            {ok, #{entries => Entries, source_meta => Meta}};
        {error, Reason} -> {error, Reason}
    end.

cached(Key, Paths, Loader, State) ->
    Signature = signature(Paths),
    Cache = maps:get(cache, State),
    case maps:get(Key, Cache, undefined) of
        #{signature := Signature, data := Data} ->
            {ok, Data, State};
        _ ->
            case Loader() of
                {ok, Data} ->
                    Entry = #{signature => Signature, data => Data},
                    {ok, Data, State#{cache => Cache#{Key => Entry}}};
                {error, Reason} ->
                    {error, Reason, State}
            end
    end.

signature(Paths) ->
    [{Path, file_signature(Path)} || Path <- Paths].

file_signature(Path) ->
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, Info} -> {Info#file_info.mtime, Info#file_info.size};
        {error, Reason} -> {missing, Reason}
    end.

normalize_query_paths(Query, Cwd) ->
    normalize_query_path(knowledge_dir, normalize_query_path(exports_dir, Query, Cwd), Cwd).

normalize_query_path(Key, Query, Cwd) ->
    case maps:get(Key, Query, undefined) of
        undefined -> Query;
        Path -> Query#{Key => absolute_path(Path, Cwd)}
    end.

absolute_path(Path, Cwd) ->
    case filename:pathtype(Path) of
        absolute -> Path;
        _ -> filename:absname(Path, Cwd)
    end.
