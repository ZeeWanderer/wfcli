%%%-------------------------------------------------------------------
%% Daemon-owned catalog dependency validation and metadata updates.
%%%-------------------------------------------------------------------
-module(wfcli_source_manager).

-behaviour(gen_server).

-export([start_link/0, ensure_catalog/2, submit/2, status/0, requirements/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-type requirement() :: #{kind := export | wfcd,
                         id := string(),
                         path := file:filename_all(),
                         managed := boolean()}.

-doc "Start the serialized metadata/source job manager.".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Ensure every source required by a catalog request is valid and locally available.".
-spec ensure_catalog(string(), map()) -> ok | {error, term()}.
ensure_catalog(Command, Query) ->
    gen_server:call(?SERVER, {ensure_catalog, Command, Query}, infinity).

-doc "Queue a metadata refresh; result arrives as `{wfcli_daemon, Ref, Reply}`.".
-spec submit(pid(), map()) -> {ok, reference()} | {error, term()}.
submit(Client, Request) ->
    gen_server:call(?SERVER, {submit, Client, Request}).

-doc "Return source queue state.".
-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

-doc "Map one catalog command to concrete source artifacts.".
-spec requirements(string(), map()) -> [requirement()].
requirements("mods", Query) ->
    Dir = maps:get(exports_dir, Query, undefined),
    [export_requirement("ExportUpgrades_en.json", wfcli_exports:mod_source(Dir), Dir)];
requirements("items", Query) ->
    Dir = maps:get(exports_dir, Query, undefined),
    [export_requirement(File, Path, Dir)
     || {File, Path} <- wfcli_exports:item_sources(Dir, maps:get(files, Query, []))];
requirements("codex", Query) ->
    Dir = maps:get(exports_dir, Query, undefined),
    [export_requirement(File, Path, Dir)
     || {File, Path} <- wfcli_knowledge:codex_sources(Dir)];
requirements(Command, Query) when Command =:= "enemies"; Command =:= "drops" ->
    Dir = maps:get(knowledge_dir, Query, undefined),
    [#{kind => wfcd, id => "WFCDEnemy.json",
       path => wfcli_knowledge:wfcd_source(Dir), managed => Dir =:= undefined}];
requirements(_Command, _Query) ->
    [].

export_requirement(File, Path, Dir) ->
    #{kind => export, id => File, path => Path, managed => Dir =:= undefined}.

init([]) ->
    {ok, #{queue => queue:new(), current => undefined, client_monitors => #{}}}.

handle_call({ensure_catalog, Command, Query}, From, State) ->
    Job = #{kind => ensure, command => Command, query => Query, reply => {call, From}},
    {noreply, enqueue(Job, State)};
handle_call({submit, Client, Request}, _From, State) when is_pid(Client), is_map(Request) ->
    case maps:get(action, Request, undefined) of
        refresh ->
            Ref = make_ref(),
            Monitor = erlang:monitor(process, Client),
            Job = #{kind => refresh, request => Request,
                    reply => {client, Client, Ref, Monitor}},
            wfcli_worldstate_service:activity_start(),
            Monitors = maps:get(client_monitors, State),
            {reply, {ok, Ref}, enqueue(Job, State#{client_monitors => Monitors#{Monitor => Ref}})};
        Action ->
            {reply, {error, {unsupported_source_action, Action}}, State}
    end;
handle_call(status, _From, State) ->
    {reply, #{queued => queue:len(maps:get(queue, State)),
              processing => maps:get(current, State) =/= undefined}, State};
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(process_queue, State = #{current := Current}) when Current =/= undefined ->
    {noreply, State};
handle_info(process_queue, State) ->
    case queue:out(maps:get(queue, State)) of
        {empty, Queue} ->
            {noreply, State#{queue => Queue}};
        {{value, Job}, Queue} ->
            Parent = self(),
            Token = make_ref(),
            {_Pid, WorkerMonitor} = spawn_monitor(
              fun() ->
                  Result = try execute_job(Job)
                           catch Class:Reason:Stack ->
                               {error, {source_job_crash, Class, Reason, Stack}}
                           end,
                  Parent ! {source_job_result, Token, Result}
              end),
            Current = #{token => Token, worker_monitor => WorkerMonitor, job => Job},
            {noreply, State#{queue => Queue, current => Current}}
    end;
handle_info({source_job_result, Token, Result},
            State = #{current := #{token := Token, worker_monitor := WorkerMonitor, job := Job}}) ->
    erlang:demonitor(WorkerMonitor, [flush]),
    State1 = complete_job(Job, Result, State#{current => undefined}),
    self() ! process_queue,
    {noreply, State1};
handle_info({'DOWN', Monitor, process, _Pid, Reason},
            State = #{current := #{worker_monitor := Monitor, job := Job}}) ->
    State1 = complete_job(Job, {error, {source_worker_down, Reason}},
                          State#{current => undefined}),
    self() ! process_queue,
    {noreply, State1};
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    case maps:take(Monitor, maps:get(client_monitors, State)) of
        error -> {noreply, State};
        {Ref, Monitors} ->
            Queue = queue:filter(fun(Job) -> not job_ref(Job, Ref) end, maps:get(queue, State)),
            wfcli_worldstate_service:activity_end(),
            {noreply, State#{queue => Queue, client_monitors => Monitors}}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State#{queue => maps:get(queue, State, queue:new()),
                current => maps:get(current, State, undefined),
                client_monitors => maps:get(client_monitors, State, #{})}}.

enqueue(Job, State) ->
    self() ! process_queue,
    State#{queue => queue:in(Job, maps:get(queue, State))}.

complete_job(#{reply := {call, From}}, Result, State) ->
    gen_server:reply(From, Result),
    State;
complete_job(#{reply := {client, Client, Ref, Monitor}}, Result, State) ->
    case maps:is_key(Monitor, maps:get(client_monitors, State)) of
        true -> Client ! {wfcli_daemon, Ref, Result};
        false -> ok
    end,
    erlang:demonitor(Monitor, [flush]),
    wfcli_worldstate_service:activity_end(),
    State#{client_monitors => maps:remove(Monitor, maps:get(client_monitors, State))}.

job_ref(#{reply := {client, _Client, Ref, _Monitor}}, Ref) -> true;
job_ref(_Job, _Ref) -> false.

execute_job(#{kind := ensure, command := Command, query := Query}) ->
    ensure_requirements(Command, Query);
execute_job(#{kind := refresh, request := Request}) ->
    refresh_sources(maps:get(selections, Request, [default])).

ensure_requirements(Command, Query) ->
    Requirements = requirements(Command, Query),
    Failures = lists:filtermap(
      fun(Requirement) ->
          case validate_requirement(Requirement) of
              ok -> false;
              Error -> {true, {Requirement, Error}}
          end
      end, Requirements),
    case [Failure || {#{managed := false}, _} = Failure <- Failures] of
        [{Requirement, {error, Reason}} | _] ->
            source_error(Requirement, Reason, custom);
        [] ->
            Managed = [Requirement || {Requirement, _} <- Failures],
            case refresh_requirements(Managed) of
                ok -> validate_requirements(requirements(Command, Query));
                {error, _Reason} = Error -> Error
            end
    end.

validate_requirements([]) -> ok;
validate_requirements([Requirement | Rest]) ->
    case validate_requirement(Requirement) of
        ok -> validate_requirements(Rest);
        {error, Reason} -> source_error(Requirement, Reason, managed)
    end.

validate_requirement(#{kind := export, path := Path}) ->
    validate_json(Path, fun(Map) -> is_map(Map) end);
validate_requirement(#{kind := wfcd, path := Path}) ->
    validate_json(Path,
                  fun(#{<<"entries">> := Entries}) -> is_list(Entries);
                     (_) -> false
                  end).

validate_json(Path, Valid) ->
    case file:read_file(Path) of
        {ok, Body} ->
            try jsone:decode(Body, [{object_format, map}]) of
                Value -> case Valid(Value) of true -> ok; false -> {error, invalid_payload} end
            catch _:_ -> {error, invalid_json}
            end;
        {error, Reason} -> {error, Reason}
    end.

source_error(Requirement, Reason, Policy) ->
    {error, {source_unavailable, maps:get(kind, Requirement), maps:get(id, Requirement),
             maps:get(path, Requirement), Reason, Policy}}.

refresh_requirements([]) -> ok;
refresh_requirements(Requirements) ->
    ExportFiles = lists:usort([maps:get(id, R) || R <- Requirements,
                                                   maps:get(kind, R) =:= export]),
    NeedWfcd = lists:any(fun(R) -> maps:get(kind, R) =:= wfcd end, Requirements),
    case maybe_update_exports(ExportFiles) of
        ok -> case NeedWfcd of true -> run_update(wfcd); false -> ok end;
        {error, _Reason} = Error -> Error
    end.

maybe_update_exports([]) -> ok;
maybe_update_exports(Files) -> run_update({exports, Files}).

refresh_sources(Selections0) ->
    Selections = expand_selections(Selections0),
    Results = [#{source => Selection, result => run_update(Selection)}
               || Selection <- Selections],
    {ok, #{results => Results,
           success => lists:all(fun(#{result := Result}) -> Result =:= ok end, Results)}}.

expand_selections(Selections) ->
    Expanded = lists:flatten([expand_selection(Selection) || Selection <- Selections]),
    unique(Expanded, []).

expand_selection(default) -> [nodes, languages, exports];
expand_selection(all) -> [nodes, languages, exports, wfcd];
expand_selection(Selection) -> [Selection].

unique([], Acc) -> lists:reverse(Acc);
unique([Value | Rest], Acc) ->
    case lists:member(Value, Acc) of
        true -> unique(Rest, Acc);
        false -> unique(Rest, [Value | Acc])
    end.

run_update(Action) ->
    case daemon_env(source_update_fun, undefined) of
        Fun when is_function(Fun, 1) -> Fun(Action);
        _ -> run_real_update(Action)
    end.

run_real_update(nodes) -> wfcli_worldstate:update_nodes();
run_real_update(languages) -> wfcli_worldstate:update_languages();
run_real_update(manifest) -> wfcli_worldstate:update_manifest();
run_real_update(exports) -> wfcli_worldstate:update_all_exports();
run_real_update({exports, Files}) -> wfcli_worldstate:update_exports(Files);
run_real_update(recipes) -> wfcli_worldstate:update_export("ExportRecipes_en.json");
run_real_update(upgrades) -> wfcli_worldstate:update_export("ExportUpgrades_en.json");
run_real_update(weapons) -> wfcli_worldstate:update_export("ExportWeapons_en.json");
run_real_update(warframes) -> wfcli_worldstate:update_export("ExportWarframes_en.json");
run_real_update(resources) -> wfcli_worldstate:update_export("ExportResources_en.json");
run_real_update(wfcd) -> wfcli_knowledge:update_wfcd();
run_real_update(Action) -> {error, {unknown_source_update, Action}}.

daemon_env(Key, Default) ->
    application:get_env(wfdaemon, Key, Default).
