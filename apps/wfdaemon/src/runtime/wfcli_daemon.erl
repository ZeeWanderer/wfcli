%%%-------------------------------------------------------------------
%% Persistent wfcli service process.
%%%-------------------------------------------------------------------
-module(wfcli_daemon).

-behaviour(gen_server).

-export([start_link/0, request/1, submit/2, subscribe/2, unsubscribe/1,
         protocol_version/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CALL_TIMEOUT_MS, 120000).
-define(ARTIFACT_CHECK_MS, 5000).

-type request() ::
    status |
    stop |
    player_snapshot |
    player_clear |
    notification_settings |
    {notification_settings, map()} |
    {companion_command, map()} |
    {hello, non_neg_integer()} |
    {set_idle_policy, persistent | idle | {idle, pos_integer()}} |
    {hot_update, [map()]} |
    {update_release, string()}.
-type status() :: #{
    status := running,
    node := node(),
    pid := pid(),
    uptime_ms := non_neg_integer(),
    version := string() | undefined,
    otp_release := string(),
    build := binary() | undefined
}.
-type reply() ::
    status() |
    ok |
    {ok, term()} |
    {ok, term(), term()} |
    {error, term()}.
-type state() :: #{
    started_at := integer(),
    artifact_id := binary() | undefined,
    artifact_update := false | #{artifact_id := binary(), monitor := reference(), pid := pid()},
    manual_update := false | #{token := reference(), monitor := reference(), pid := pid(),
                               from := gen_server:from()}
}.

-doc "Start persistent service registered as `wfcli_daemon`; supervisor owns this in release mode.".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Synchronous daemon API; keep requests data-only so remote CLI calls stay upgrade-safe.".
-spec request(request()) -> reply().
request(Request) ->
    gen_server:call(?SERVER, Request, ?CALL_TIMEOUT_MS).

-doc "Queue one immediate request and return its asynchronous reply reference.".
-spec submit(pid(), map()) -> {ok, reference()} | {error, term()}.
submit(Client, Request) ->
    gen_server:call(?SERVER, {submit, Client, Request}, ?CALL_TIMEOUT_MS).

-doc "Register one persistent subscription and return its update reference.".
-spec subscribe(pid(), map()) -> {ok, reference()} | {error, term()}.
subscribe(Client, Request) ->
    gen_server:call(?SERVER, {subscribe, Client, Request}, ?CALL_TIMEOUT_MS).

-doc "Cancel a queued request or persistent subscription.".
-spec unsubscribe(reference()) -> ok | {error, term()}.
unsubscribe(Ref) ->
    gen_server:call(?SERVER, {unsubscribe, Ref}, ?CALL_TIMEOUT_MS).

-doc "Wire protocol version shared by daemon and escript client.".
-spec protocol_version() -> non_neg_integer().
protocol_version() -> wfcli_protocol:version().

-doc "Initialize daemon state. Future watch registrations should live under this process tree.".
-spec init([]) -> {ok, state()}.
init([]) ->
    schedule_artifact_check(),
    {ok, #{started_at => erlang:monotonic_time(millisecond),
           artifact_id => current_artifact_id(), artifact_update => false,
           manual_update => false}}.

-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, term(), state()} | {noreply, state()}.
handle_call(status, _From, State) ->
    {reply, status(State), State};
handle_call({hello, ClientVersion}, _From, State) ->
    Protocol = protocol_version(),
    Reply0 = #{protocol => Protocol,
               compatible => ClientVersion =:= Protocol,
               version => app_version(),
               flavor => wfcli_build:flavor(),
               node => node()},
    Reply = with_build_identity(Reply0),
    {reply, Reply, State};
handle_call({submit, Client, Request}, _From, State) ->
    Reply = safe_submit(Client, Request),
    {reply, Reply, State};
handle_call({subscribe, Client, Request}, _From, State) ->
    {reply, safe_worker_call(wfcli_worldstate_service,
                             fun() -> wfcli_worldstate_service:subscribe(Client, Request) end), State};
handle_call({unsubscribe, Ref}, _From, State) ->
    {reply, wfcli_worldstate_service:unsubscribe(Ref), State};
handle_call({set_idle_policy, Policy}, _From, State) ->
    {reply, wfcli_worldstate_service:set_idle_policy(Policy), State};
handle_call(player_snapshot, _From, State) ->
    {reply, wfcli_player_service:snapshot(), State};
handle_call(player_clear, _From, State) ->
    {reply, wfcli_player_service:clear(), State};
handle_call(notification_settings, _From, State) ->
    {reply, safe_worker_call(wfcli_notification_service,
                             fun wfcli_notification_service:settings/0), State};
handle_call({notification_settings, Patch}, _From, State) when is_map(Patch) ->
    Reply = case safe_worker_call(
                   wfcli_notification_service,
                   fun() -> wfcli_notification_service:update(Patch) end) of
        {ok, Settings} -> Settings;
        {error, _Reason} = Error -> Error
    end,
    {reply, Reply, State};
handle_call({companion_command, Command}, _From, State) when is_map(Command) ->
    {reply, wfcli_local_api:companion_command(Command), State};
handle_call({hot_update, Bundles}, From, State) when is_list(Bundles) ->
    case update_in_progress(State) of
        true -> {reply, {error, update_in_progress}, State};
        false -> {noreply, start_manual_update(Bundles, From, State)}
    end;
handle_call(stop, _From, State) ->
    _ = spawn(fun stop_node_after_reply/0),
    {reply, ok, State};
handle_call({update_release, ReleaseName}, _From, State) when is_list(ReleaseName) ->
    case update_in_progress(State) of
        true -> {reply, {error, update_in_progress}, State};
        false -> {reply, update_release(ReleaseName), State}
    end;
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(artifact_check, State) ->
    schedule_artifact_check(),
    {noreply, check_artifact_update(State)};
handle_info({artifact_update, ArtifactId, Result},
            State = #{artifact_update := #{artifact_id := ArtifactId, monitor := Monitor}}) ->
    erlang:demonitor(Monitor, [flush]),
    case Result of
        {ok, _Info} -> {noreply, State#{artifact_id => ArtifactId, artifact_update => false}};
        {error, Reason} ->
            logger:warning("wfdaemon artifact update failed: ~p", [Reason]),
            {noreply, State#{artifact_update => false}}
    end;
handle_info({artifact_update, _ArtifactId, _Result}, State) ->
    {noreply, State};
handle_info({manual_update, Token, Result},
            State = #{manual_update := #{token := Token, monitor := Monitor,
                                         from := From}}) ->
    erlang:demonitor(Monitor, [flush]),
    gen_server:reply(From, Result),
    {noreply, State#{manual_update => false}};
handle_info({manual_update, _Token, _Result}, State) ->
    {noreply, State};
handle_info({'DOWN', Monitor, process, _Pid, Reason},
            State = #{artifact_update := #{monitor := Monitor}}) ->
    logger:warning("wfdaemon artifact updater stopped: ~p", [Reason]),
    {noreply, State#{artifact_update => false}};
handle_info({'DOWN', Monitor, process, _Pid, Reason},
            State = #{manual_update := #{monitor := Monitor, from := From}}) ->
    gen_server:reply(From, {error, {hot_update_worker_down, Reason}}),
    {noreply, State#{manual_update => false}};
handle_info(_Msg, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    ok.

-doc "OTP hot-upgrade hook. Real state migration belongs here once appup/relup exists.".
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    Update = case maps:get(artifact_update, State, false) of
        #{artifact_id := _, monitor := _, pid := _} = Active -> Active;
        _ -> false
    end,
    Manual = case maps:get(manual_update, State, false) of
        #{token := _, monitor := _, pid := _, from := _} = ActiveManual -> ActiveManual;
        _ -> false
    end,
    {ok, State#{artifact_update => Update, manual_update => Manual}}.

status(State = #{started_at := StartedAt}) ->
    Now = erlang:monotonic_time(millisecond),
    ServiceStatus = try wfcli_worldstate_service:status()
                    catch _:_ -> unavailable
                    end,
    ExportStatus = try wfcli_exports_store:status()
                   catch _:_ -> unavailable
                   end,
    SourceStatus = try wfcli_source_manager:status()
                   catch _:_ -> unavailable
                   end,
    FormaStatus = try wfcli_forma_service:status()
                  catch _:_ -> unavailable
                  end,
    with_build_identity(#{
        status => running,
        node => node(),
        pid => self(),
        uptime_ms => max(0, Now - StartedAt),
        version => app_version(),
        otp_release => erlang:system_info(otp_release),
        protocol => protocol_version(),
        flavor => wfcli_build:flavor(),
        service => ServiceStatus,
        exports => ExportStatus,
        sources => SourceStatus,
        forma => FormaStatus,
        query => safe_status(wfcli_query_service),
        player => safe_status(wfcli_player_service),
        market => safe_status(wfcli_market_service),
        market_account => safe_status(wfcli_market_account_service),
        market_presence => safe_status(wfcli_market_presence_service),
        local_api => safe_status(wfcli_local_api),
        update => update_status(State)
    }).

update_status(#{manual_update := Manual, artifact_update := Artifact}) ->
    case {Manual, Artifact} of
        {false, false} -> idle;
        {#{}, false} -> manual;
        {false, #{}} -> artifact;
        {#{}, #{}} -> both
    end.

with_build_identity(Map) ->
    case wfcli_hot_update:current_build_identity() of
        {ok, Identity} -> Map#{build => Identity};
        {error, Reason} -> Map#{build => undefined, build_error => Reason}
    end.

app_version() ->
    case application:get_key(wfdaemon, vsn) of
        {ok, Vsn} -> Vsn;
        undefined ->
            case application:get_key(wfcli, vsn) of
                {ok, Vsn} -> Vsn;
                undefined -> undefined
            end
    end.

safe_status(Module) ->
    try Module:status() catch _:_ -> unavailable end.

safe_submit(Client, Request) ->
    case maps:get(source, Request, worldstate) of
        Source when Source =:= worldstate; Source =:= trader; Source =:= teshin ->
            safe_worker_call(wfcli_worldstate_service,
                             fun() -> wfcli_worldstate_service:submit(Client, Request) end);
        exports -> safe_worker_call(wfcli_exports_store,
                                    fun() -> wfcli_exports_store:submit(Client, Request) end);
        query -> safe_worker_call(wfcli_query_service,
                                  fun() -> wfcli_query_service:submit(Client, Request) end);
        metadata -> safe_worker_call(wfcli_source_manager,
                                     fun() -> wfcli_source_manager:submit(Client, Request) end);
        forma -> safe_worker_call(wfcli_forma_service,
                                  fun() -> wfcli_forma_service:submit(Client, Request) end);
        market -> safe_worker_call(wfcli_market_service,
                                   fun() -> wfcli_market_service:submit(Client, Request) end);
        Source -> {error, {unsupported_source, Source}}
    end.

safe_worker_call(Worker, Fun) ->
    try Fun()
    catch exit:Reason -> {error, {worker_unavailable, Worker, Reason}}
    end.

stop_node_after_reply() ->
    timer:sleep(100),
    init:stop().

update_release([]) ->
    {error, release_name_required};
update_release(ReleaseName) ->
    case release_handler:unpack_release(ReleaseName) of
        {ok, Vsn} ->
            install_release(Vsn);
        {error, {existing_release, Vsn}} ->
            install_release(Vsn);
        Error ->
            Error
    end.

install_release(Vsn) ->
    case release_handler:install_release(Vsn) of
        {ok, _OldVsn, _Descr} ->
            release_handler:make_permanent(Vsn);
        {ok, _OldVsn, _Descr, _Warnings} ->
            release_handler:make_permanent(Vsn);
        Error ->
            Error
    end.

schedule_artifact_check() ->
    erlang:send_after(?ARTIFACT_CHECK_MS, self(), artifact_check).

check_artifact_update(State) ->
    try maybe_start_artifact_update(State)
    catch
        Class:Reason:Stacktrace ->
            logger:error("wfdaemon artifact check failed: ~p", [{Class, Reason, Stacktrace}]),
            State
    end.

current_artifact_id() ->
    case wfcli_build:artifact_id() of
        {ok, ArtifactId} -> ArtifactId;
        {error, _Reason} -> undefined
    end.

update_in_progress(State) ->
    maps:get(artifact_update, State, false) =/= false orelse
        maps:get(manual_update, State, false) =/= false.

start_manual_update(Bundles, From, State) ->
    Daemon = self(),
    Token = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Daemon ! {manual_update, Token, safe_hot_update(Bundles)}
    end),
    State#{manual_update => #{token => Token, monitor => Monitor,
                              pid => Pid, from => From}}.

maybe_start_artifact_update(
  State = #{artifact_id := Current, artifact_update := false, manual_update := false}) ->
    case wfcli_build:artifact_id() of
        {ok, Current} -> State;
        {ok, ArtifactId} ->
            Daemon = self(),
            {Pid, Monitor} = spawn_monitor(fun() ->
                Result = case wfcli_build:hot_ebin_dirs() of
                    {ok, Dirs} ->
                        case wfcli_hot_update:read_directories(Dirs) of
                            {ok, Bundles} -> wfcli_hot_update:apply(Bundles);
                            {error, _Reason} = Error -> Error
                        end;
                    {error, _Reason} = Error -> Error
                end,
                Daemon ! {artifact_update, ArtifactId, Result}
            end),
            State#{artifact_update => #{artifact_id => ArtifactId,
                                        monitor => Monitor, pid => Pid}};
        {error, _Reason} -> State
    end;
maybe_start_artifact_update(State) -> State.

safe_hot_update(Bundles) ->
    try execute_hot_update(Bundles)
    catch
        Class:Reason:Stacktrace -> {error, {hot_update_crash, Class, Reason, Stacktrace}}
    end.

-ifdef(TEST).
execute_hot_update(Bundles) ->
    case application:get_env(wfdaemon, daemon_hot_update_fun, undefined) of
        Fun when is_function(Fun, 1) -> Fun(Bundles);
        undefined -> wfcli_hot_update:apply(Bundles)
    end.
-else.
execute_hot_update(Bundles) -> wfcli_hot_update:apply(Bundles).
-endif.
