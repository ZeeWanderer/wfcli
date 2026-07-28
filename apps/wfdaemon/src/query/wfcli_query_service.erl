%%%-------------------------------------------------------------------
%% Serialized daemon-owned unified query coordinator.
%%%-------------------------------------------------------------------
-module(wfcli_query_service).

-behaviour(gen_server).

-export([start_link/0, submit/2, status/0, execute/1, select_datasets/1]).
-ifdef(TEST).
-export([paginate_worldstate/2]).
-endif.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(WORKER_TIMEOUT_MS, 120000).

-doc "Start the unified query queue.".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Queue one unified query; result arrives as `{wfcli_daemon, Ref, Reply}`.".
-spec submit(pid(), map()) -> {ok, reference()} | {error, term()}.
submit(Client, Request) ->
    gen_server:call(?SERVER, {submit, Client, Request}).

-doc "Return unified query queue state.".
-spec status() -> map().
status() -> gen_server:call(?SERVER, status).

init([]) ->
    {ok, #{queue => queue:new(), current => undefined, client_monitors => #{}}}.

handle_call({submit, Client, Request}, _From, State) when is_pid(Client), is_map(Request) ->
    Ref = make_ref(),
    Monitor = erlang:monitor(process, Client),
    Job = #{client => Client, ref => Ref, monitor => Monitor, request => Request},
    Monitors = maps:get(client_monitors, State),
    wfcli_worldstate_service:activity_start(),
    self() ! process_queue,
    {reply, {ok, Ref}, State#{queue => queue:in(Job, maps:get(queue, State)),
                              client_monitors => Monitors#{Monitor => Ref}}};
handle_call(status, _From, State) ->
    {reply, #{queued => queue:len(maps:get(queue, State)),
              processing => maps:get(current, State) =/= undefined}, State};
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info(process_queue, State = #{current := Current}) when Current =/= undefined ->
    {noreply, State};
handle_info(process_queue, State) ->
    case queue:out(maps:get(queue, State)) of
        {empty, Queue} -> {noreply, State#{queue => Queue}};
        {{value, Job}, Queue} ->
            Parent = self(),
            Token = make_ref(),
            {Pid, WorkerMonitor} = spawn_monitor(fun() ->
                Result = try execute(maps:get(request, Job))
                         catch Class:Reason:Stack ->
                             {error, {query_crash, Class, Reason, Stack}}
                         end,
                Parent ! {query_result, Token, Result}
            end),
            Current = #{token => Token, worker_pid => Pid,
                        worker_monitor => WorkerMonitor, job => Job},
            {noreply, State#{queue => Queue, current => Current}}
    end;
handle_info({query_result, Token, Result},
            State = #{current := #{token := Token, worker_monitor := WorkerMonitor,
                                   job := Job}}) ->
    erlang:demonitor(WorkerMonitor, [flush]),
    State1 = complete_job(Job, Result, State#{current => undefined}),
    self() ! process_queue,
    {noreply, State1};
handle_info({'DOWN', Monitor, process, _Pid, Reason},
            State = #{current := #{worker_monitor := Monitor, job := Job}}) ->
    State1 = complete_job(Job, {error, {query_worker_down, Reason}},
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
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, State) ->
    stop_worker(maps:get(current, State, undefined)),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State#{queue => maps:get(queue, State, queue:new()),
                current => maps:get(current, State, undefined),
                client_monitors => maps:get(client_monitors, State, #{})}}.

-doc "Parse and execute one unified query entirely inside wfdaemon.".
-spec execute(map()) -> {ok, map()} | {error, term()}.
execute(Request) ->
    Tokens0 = maps:get(query_tokens, Request, []),
    case select_datasets(Tokens0) of
        {ok, Tokens, Datasets, Explicit} ->
            case wfcli_query_parse:parse_arguments(Tokens) of
                {ok, Ast} ->
                    Query = string:join(Tokens, " "),
                    Results = [execute_dataset(Dataset, Query, Ast, Request)
                               || Dataset <- Datasets],
                    {ok, #{query_tokens => Tokens, datasets => Results,
                           dataset_explicit => Explicit}};
                {error, Error} -> {error, {query_errors, [Error]}}
            end;
        {error, Error} -> {error, {query_errors, [Error]}}
    end.

execute_dataset(worldstate, Query, _Ast, Request) ->
    Opts = worldstate_opts(Request),
    WorkerRequest = #{source => worldstate, opts => Opts, query => Query,
                      type_filter => undefined, day_filter => undefined,
                      mode => list, inventory => false},
    Reply = submit_and_wait(wfcli_worldstate_service, WorkerRequest),
    #{dataset => worldstate, reply => paginate_worldstate(Reply, Request)};
execute_dataset(player, _Query, Ast, Request) ->
    Snapshot = wfcli_player_service:snapshot(),
    #{dataset => player, reply => wfcli_player_query:execute(Ast, Request, Snapshot)};
execute_dataset(market, _Query, Ast, Request) ->
    WorkerRequest = #{source => market, action => query, query_ast => Ast,
                      limit => maps:get(limit, Request, infinity),
                      offset => maps:get(offset, Request, 0),
                      raw => maps:get(raw, Request, false),
                      output_format => maps:get(output_format, Request, table)},
    #{dataset => market, reply => submit_and_wait(wfcli_market_service, WorkerRequest)};
execute_dataset(Dataset, _Query, Ast, Request) ->
    Command = atom_to_list(Dataset),
    QueryMap = catalog_query(Dataset, Ast, Request),
    WorkerRequest = #{source => exports, command => Command, query => QueryMap,
                      cwd => maps:get(cwd, Request, filename:absname("."))},
    #{dataset => Dataset, reply => submit_and_wait(wfcli_exports_store, WorkerRequest)}.

submit_and_wait(Service, Request) ->
    case Service:submit(self(), Request) of
        {ok, Ref} ->
            receive
                {wfcli_daemon, Ref, Reply} -> Reply
            after ?WORKER_TIMEOUT_MS -> {error, {worker_timeout, Service}}
            end;
        {error, Reason} -> {error, Reason}
    end.

worldstate_opts(Request) ->
    Raw = maps:get(raw, Request, false),
    Opts0 = #{refresh => maps:get(refresh, Request, false),
              ttl => maps:get(ttl, Request, 60), resolve_items => not Raw,
              raw => Raw, search_raw => Raw,
              event_lang => maps:get(event_lang, Request, undefined)},
    maybe_path(cache, Request, Opts0).

catalog_query(codex, Ast, Request) ->
    (base_catalog_query(Ast, Request))#{exports_dir => path(exports_dir, Request)};
catalog_query(Dataset, Ast, Request) when Dataset =:= enemies; Dataset =:= drops ->
    (base_catalog_query(Ast, Request))#{knowledge_dir => path(knowledge_dir, Request)};
catalog_query(_Dataset, Ast, Request) ->
    (base_catalog_query(Ast, Request))#{exports_dir => path(exports_dir, Request)}.

base_catalog_query(Ast, Request) ->
    #{query_ast => Ast, limit => maps:get(limit, Request, infinity),
      offset => maps:get(offset, Request, 0), raw => maps:get(raw, Request, false),
      output_format => maps:get(output_format, Request, table)}.

paginate_worldstate({ok, Result = #{entries := Entries}}, Request) ->
    Offset = maps:get(offset, Request, 0),
    Limit = maps:get(limit, Request, infinity),
    {ok, Result#{entries => take(Limit, drop(Offset, Entries))}};
paginate_worldstate(Reply, _Request) ->
    Reply.

drop(N, List) when N =< 0 -> List;
drop(_N, []) -> [];
drop(N, [_ | Rest]) -> drop(N - 1, Rest).

take(infinity, List) -> List;
take(Limit, List) -> lists:sublist(List, Limit).

maybe_path(Key, Request, Acc) ->
    case path(Key, Request) of undefined -> Acc; Value -> Acc#{Key => Value} end.

path(Key, Request) ->
    case maps:get(Key, Request, undefined) of
        undefined -> undefined;
        Value -> absolute_path(Value, maps:get(cwd, Request, filename:absname(".")))
    end.

absolute_path(Path, Cwd) ->
    case filename:pathtype(Path) of absolute -> Path; _ -> filename:absname(Path, Cwd) end.

-doc "Extract and validate the query-level dataset selector.".
-spec select_datasets([string()]) ->
    {ok, [string()], [atom()], boolean()} | {error, string()}.
select_datasets(Tokens0) ->
    Tokens = lists:append([string:lexemes(Token, " \t") || Token <- Tokens0]),
    select_datasets(Tokens, undefined, []).

select_datasets([], undefined, QueryAcc) ->
    {ok, lists:reverse(QueryAcc), wfcli_protocol:default_datasets(), false};
select_datasets([], Datasets, QueryAcc) ->
    {ok, lists:reverse(QueryAcc), Datasets, true};
select_datasets([Token | Rest], Selected, QueryAcc) ->
    case dataset_token(Token) of
        no -> select_datasets(Rest, Selected, [Token | QueryAcc]);
        {ok, Datasets} when Selected =:= undefined -> select_datasets(Rest, Datasets, QueryAcc);
        {ok, _Datasets} -> {error, "dataset selector may appear only once"};
        {error, Reason} -> {error, Reason}
    end.

dataset_token(Token) ->
    case wfcli_query_parse:parse_op(Token) of
        {ok, Key0, Op, Value} ->
            case string:lowercase(string:trim(Key0)) of
                "dataset" when Op =:= eq; Op =:= default -> parse_datasets(Value);
                "dataset" -> {error, "dataset supports only '=' or ':'"};
                _ -> no
            end;
        error -> no
    end.

parse_datasets(Value) ->
    Names = [string:lowercase(Name) || Name <- wfcli_query_parse:split_vals(Value)],
    case [Name || Name <- Names, dataset_name(Name) =:= undefined] of
        [] when Names =:= [] -> {error, "dataset requires at least one value"};
        [] ->
            case lists:member("all", Names) of
                true -> {ok, wfcli_protocol:all_datasets()};
                false ->
                    {ok, unique_datasets(lists:flatten(
                           [dataset_values(Name) || Name <- Names]))}
            end;
        [Unknown | _] ->
            {error, lists:flatten(io_lib:format(
              "unknown dataset: ~s (use default, worldstate, mods, items, codex, enemies, drops, player, market, or all)",
              [Unknown]))}
    end.

dataset_name("worldstate") -> worldstate;
dataset_name("mods") -> mods;
dataset_name("items") -> items;
dataset_name("codex") -> codex;
dataset_name("enemies") -> enemies;
dataset_name("drops") -> drops;
dataset_name("player") -> player;
dataset_name("market") -> market;
dataset_name("default") -> default;
dataset_name("all") -> all;
dataset_name(_) -> undefined.

dataset_values("default") -> wfcli_protocol:default_datasets();
dataset_values(Name) -> [dataset_name(Name)].

unique_datasets(Datasets) ->
    lists:reverse(lists:foldl(fun(Dataset, Acc) ->
        case lists:member(Dataset, Acc) of true -> Acc; false -> [Dataset | Acc] end
    end, [], Datasets)).

complete_job(#{client := Client, ref := Ref, monitor := Monitor}, Result, State) ->
    case maps:is_key(Monitor, maps:get(client_monitors, State)) of
        true -> Client ! {wfcli_daemon, Ref, Result};
        false -> ok
    end,
    erlang:demonitor(Monitor, [flush]),
    wfcli_worldstate_service:activity_end(),
    State#{client_monitors => maps:remove(Monitor, maps:get(client_monitors, State))}.

cancel_client(Monitor, State) ->
    case maps:take(Monitor, maps:get(client_monitors, State)) of
        error ->
            {not_found, State};
        {Ref, Monitors} ->
            Queue = queue:filter(fun(Job) -> maps:get(ref, Job) =/= Ref end,
                                 maps:get(queue, State)),
            Current = maps:get(current, State, undefined),
            Current1 = case Current of
                #{job := #{ref := Ref}} ->
                    stop_worker(Current),
                    undefined;
                _ -> Current
            end,
            wfcli_worldstate_service:activity_end(),
            {canceled, State#{queue => Queue, current => Current1,
                              client_monitors => Monitors}}
    end.

stop_worker(undefined) -> ok;
stop_worker(Current) ->
    case maps:get(worker_pid, Current, undefined) of
        Pid when is_pid(Pid) -> exit(Pid, kill);
        undefined -> ok
    end,
    erlang:demonitor(maps:get(worker_monitor, Current), [flush]),
    ok.
