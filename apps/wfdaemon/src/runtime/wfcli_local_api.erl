%%%-------------------------------------------------------------------
%% User-local Unix socket API for native companions.
%%%-------------------------------------------------------------------
-module(wfcli_local_api).

-behaviour(gen_server).

-export([start_link/0, status/0, socket_path/0, companion_command/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(MAX_BUFFER_BYTES, 8388608).
-define(MAX_MARKET_RESOLVE_LABELS, 20).
-define(MAX_MARKET_RESOLVE_LIMIT, 5).

-type state() :: #{
    listen := socket:socket(),
    path := file:filename_all(),
    acceptor := pid(),
    connections := map(),
    monitors := map()
}.

-doc "Start owner-only Unix socket endpoint used by native companion processes.".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Return local API socket and connected-client state.".
-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

-doc "Return configured native companion Unix socket path.".
-spec socket_path() -> file:filename_all().
socket_path() ->
    case application:get_env(wfdaemon, local_socket) of
        {ok, Path} -> Path;
        undefined ->
            case os:getenv("WFCLI_DAEMON_SOCKET") of
                false -> wfcli_paths:runtime_file("wfdaemon.sock");
                "" -> wfcli_paths:runtime_file("wfdaemon.sock");
                Path -> Path
            end
    end.

-doc "Send an optional diagnostic command to every connected companion.".
-spec companion_command(map()) -> {ok, non_neg_integer()}.
companion_command(Command) when is_map(Command) ->
    gen_server:call(?SERVER, {companion_command, Command}).

-spec init([]) -> {ok, state()} | {stop, term()}.
init([]) ->
    process_flag(trap_exit, true),
    Path = socket_path(),
    case open_listener(Path) of
        {ok, Listen} ->
            Parent = self(),
            Acceptor = spawn_link(fun() -> accept_loop(Listen, Parent) end),
            {ok, #{listen => Listen, path => Path, acceptor => Acceptor,
                   connections => #{}, monitors => #{}}};
        {error, Reason} ->
            {stop, {local_api_listen_failed, Path, Reason}}
    end.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call(status, _From, State) ->
    Connections = maps:get(connections, State),
    CompanionDetails =
        [maps:without([monitor], Info)
         || {_Pid, Info} <- maps:to_list(Connections),
            maps:get(client, Info, undefined) =:= <<"wfcompanion">>],
    {reply, #{socket => maps:get(path, State),
              connections => map_size(Connections),
              companions => length(CompanionDetails),
              companion_details => CompanionDetails,
              protocol => wfcli_local_protocol:protocol_version()}, State};
handle_call({companion_command, Command}, _From, State) ->
    Count = maps:fold(
      fun(Pid, Info, Acc) ->
          case maps:get(client, Info, undefined) of
              <<"wfcompanion">> -> Pid ! {daemon_command, Command}, Acc + 1;
              _ -> Acc
          end
      end,
      0,
      maps:get(connections, State)),
    {reply, {ok, Count}, State};
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Message, State) ->
    {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({connection_started, Pid}, State) ->
    Monitor = erlang:monitor(process, Pid),
    Connections = maps:get(connections, State),
    Monitors = maps:get(monitors, State),
    {noreply, State#{connections => Connections#{Pid => #{monitor => Monitor}},
                     monitors => Monitors#{Monitor => Pid}}};
handle_info({client_identified, Pid, ClientInfo}, State) ->
    Connections = maps:get(connections, State),
    case maps:get(Pid, Connections, undefined) of
        undefined -> {noreply, State};
        Info ->
            Client = maps:get(client, ClientInfo),
            update_client_activity(maps:get(client, Info, undefined), Client),
            {noreply, State#{connections => Connections#{Pid => maps:merge(Info, ClientInfo)}}}
    end;
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    case maps:take(Monitor, maps:get(monitors, State)) of
        error -> {noreply, State};
        {Connection, Monitors} ->
            Connections0 = maps:get(connections, State),
            case maps:take(Connection, Connections0) of
                error ->
                    {noreply, State#{monitors => Monitors}};
                {Info, Connections} ->
                    release_client_activity(Info),
                    {noreply, State#{connections => Connections, monitors => Monitors}}
            end
    end;
handle_info({'EXIT', Acceptor, Reason}, State = #{acceptor := Acceptor}) ->
    case Reason of
        normal -> {noreply, State};
        _ ->
            Listen = maps:get(listen, State),
            Parent = self(),
            NewAcceptor = spawn_link(fun() -> accept_loop(Listen, Parent) end),
            {noreply, State#{acceptor => NewAcceptor}}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, State) ->
    maps:foreach(fun(Pid, _Info) -> Pid ! shutdown end,
                 maps:get(connections, State, #{})),
    _ = socket:close(maps:get(listen, State)),
    _ = file:delete(maps:get(path, State)),
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

open_listener(Path) ->
    ok = filelib:ensure_dir(Path),
    _ = file:make_dir(filename:dirname(Path)),
    _ = file:change_mode(filename:dirname(Path), 8#700),
    _ = file:delete(Path),
    case socket:open(local, stream, default) of
        {ok, Listen} ->
            case socket:bind(Listen, #{family => local, path => Path}) of
                ok ->
                    case socket:listen(Listen) of
                        ok ->
                            _ = file:change_mode(Path, 8#600),
                            {ok, Listen};
                        {error, Reason} ->
                            _ = socket:close(Listen),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    _ = socket:close(Listen),
                    {error, Reason}
            end;
        {error, _Reason} = Error -> Error
    end.

accept_loop(Listen, Parent) ->
    case socket:accept(Listen) of
        {ok, Socket} ->
            Handler = spawn(fun() -> await_socket(Parent) end),
            case socket:setopt(Socket, otp, controlling_process, Handler) of
                ok ->
                    Handler ! {accepted_socket, Socket},
                    Parent ! {connection_started, Handler};
                {error, Reason} ->
                    exit(Handler, {socket_transfer_failed, Reason}),
                    _ = socket:close(Socket)
            end,
            accept_loop(Listen, Parent);
        {error, closed} -> ok;
        {error, Reason} -> exit({accept_failed, Reason})
    end.

await_socket(Parent) ->
    receive
        {accepted_socket, Socket} -> connection(Socket, Parent)
    after 5000 ->
        exit(socket_transfer_timeout)
    end.

connection(Socket, Parent) ->
    Handler = self(),
    {Reader, ReaderMonitor} = spawn_monitor(fun() -> socket_reader(Socket, Handler) end),
    State = #{socket => Socket, parent => Parent, reader => Reader,
              reader_monitor => ReaderMonitor, buffer => <<>>,
              hello => false, subscriptions => #{}, refs => #{}, market_refs => #{},
              workers => #{}},
    try connection_loop(State)
    after
        cleanup_connection(State),
        _ = socket:close(Socket)
    end.

connection_loop(State = #{reader_monitor := ReaderMonitor}) ->
    receive
        {socket_data, Data} ->
            case consume_data(Data, State) of
                {ok, State1} -> connection_loop(State1);
                {stop, _Reason, _State1} -> ok
            end;
        {socket_closed, _Reason} -> ok;
        {wfcli_player, Ref, Snapshot} ->
            State1 = send_subscription_update(Ref, Snapshot, State),
            connection_loop(State1);
        {wfcli_daemon, Ref, Reply} ->
            State1 = send_market_reply(Ref, Reply, State),
            connection_loop(State1);
        {local_request_result, Token, Id, Dataset, Reply} ->
            State1 = send_local_request_result(Token, Id, Dataset, Reply, State),
            connection_loop(State1);
        {daemon_command, Command} ->
            send_json(maps:get(socket, State),
                      #{<<"event">> => <<"command">>, <<"data">> => Command}),
            connection_loop(State);
        {'DOWN', ReaderMonitor, process, _Reader, Reason} ->
            case Reason of
                normal -> ok;
                _ -> exit({socket_reader_failed, Reason})
            end;
        {'DOWN', Monitor, process, _Worker, Reason} ->
            State1 = local_request_down(Monitor, Reason, State),
            connection_loop(State1);
        shutdown -> ok;
        _Message -> connection_loop(State)
    end.

socket_reader(Socket, Handler) ->
    case socket:recv(Socket, 0) of
        {ok, <<>>} -> Handler ! {socket_closed, closed};
        {ok, Data} -> Handler ! {socket_data, Data}, socket_reader(Socket, Handler);
        {error, Reason} -> Handler ! {socket_closed, Reason}
    end.

consume_data(Data, State) ->
    Buffer = <<(maps:get(buffer, State))/binary, Data/binary>>,
    case byte_size(Buffer) > ?MAX_BUFFER_BYTES of
        true -> {stop, message_too_large, State};
        false ->
            Parts = binary:split(Buffer, <<"\n">>, [global]),
            {Lines, Rest} = split_last(Parts),
            case consume_lines(Lines, State#{buffer => Rest}) of
                {ok, State1} -> {ok, State1};
                Stop -> Stop
            end
    end.

split_last(Parts) ->
    [Rest | Reversed] = lists:reverse(Parts),
    {lists:reverse(Reversed), Rest}.

consume_lines([], State) -> {ok, State};
consume_lines([<<>> | Rest], State) -> consume_lines(Rest, State);
consume_lines([Line | Rest], State) ->
    case wfcli_local_protocol:decode(Line) of
        {ok, Request} ->
            case handle_request(Request, State) of
                {ok, State1} -> consume_lines(Rest, State1);
                Stop -> Stop
            end;
        {error, Reason} ->
            send_error(maps:get(socket, State), 0, Reason),
            consume_lines(Rest, State)
    end.

handle_request(#{<<"op">> := <<"hello">>} = Request, State) ->
    Id = request_id(Request),
    Protocol = maps:get(<<"protocol">>, Request, undefined),
    Compatible = Protocol =:= wfcli_local_protocol:protocol_version(),
    Client = maps:get(<<"client">>, Request, <<"unknown">>),
    ClientInfo = #{client => Client,
                   version => maps:get(<<"version">>, Request, undefined),
                   os_pid => valid_os_pid(maps:get(<<"pid">>, Request, undefined)),
                   mode => valid_client_mode(maps:get(<<"mode">>, Request, undefined))},
    Reply = (daemon_identity())#{
        <<"id">> => Id,
        <<"ok">> => Compatible,
        <<"compatible">> => Compatible,
        <<"protocol">> => wfcli_local_protocol:protocol_version(),
        <<"capabilities">> => [<<"dataset.get">>, <<"dataset.subscribe">>,
                               <<"player.publish">>, <<"market.quote">>,
                               <<"market.resolve">>,
                               <<"relic.context">>,
                               <<"relic.planner">>,
                               <<"relic.recommendations">>,
                               <<"player.inventory">>,
                               <<"player.mastery">>,
                               <<"asset.resolve">>,
                               <<"companion.command">>]
    },
    send_json(maps:get(socket, State), Reply),
    case Compatible of
        true -> maps:get(parent, State) ! {client_identified, self(), ClientInfo};
        false -> ok
    end,
    {ok, State#{hello => Compatible}};
handle_request(Request, State = #{hello := false}) ->
    send_error(maps:get(socket, State), request_id(Request), hello_required),
    {ok, State};
handle_request(#{<<"op">> := <<"get">>, <<"dataset">> := Dataset} = Request, State) ->
    Id = request_id(Request),
    {ok, start_local_request(Id, Dataset, fun() -> dataset_snapshot(Dataset) end, State)};
handle_request(#{<<"op">> := <<"inventory_view">>} = Request, State) ->
    Id = request_id(Request),
    {ok, start_local_request(Id, <<"inventory">>,
                             fun wfcli_player_views:inventory/0, State)};
handle_request(#{<<"op">> := <<"mastery_view">>} = Request, State) ->
    Id = request_id(Request),
    {ok, start_local_request(Id, <<"mastery">>,
                             fun wfcli_player_views:mastery/0, State)};
handle_request(#{<<"op">> := <<"subscribe">>, <<"dataset">> := <<"player">>} = Request,
               State) ->
    subscribe_player(request_id(Request), State);
handle_request(#{<<"op">> := <<"unsubscribe">>, <<"subscription">> := Id} = Request,
               State) when is_integer(Id) ->
    State1 = unsubscribe_player(Id, State),
    send_json(maps:get(socket, State),
              #{<<"id">> => request_id(Request), <<"ok">> => true}),
    {ok, State1};
handle_request(#{<<"op">> := <<"publish">>, <<"dataset">> := <<"player">>,
                 <<"source">> := Source, <<"data">> := Data} = Request, State)
  when is_binary(Source), is_map(Data) ->
    case wfcli_player_service:publish(Source, Data) of
        {ok, Snapshot} ->
            send_json(maps:get(socket, State),
                      #{<<"id">> => request_id(Request), <<"ok">> => true,
                        <<"revision">> => maps:get(revision, Snapshot)});
        {error, Reason} -> send_error(maps:get(socket, State), request_id(Request), Reason)
    end,
    {ok, State};
handle_request(#{<<"op">> := <<"market_resolve">>} = Request, State) ->
    Id = request_id(Request),
    Labels = maps:get(<<"labels">>, Request, undefined),
    Limit = maps:get(<<"limit">>, Request, undefined),
    case {valid_market_labels(Labels), valid_market_limit(Limit)} of
        {false, _} ->
            send_error(maps:get(socket, State), Id, invalid_market_labels),
            {ok, State};
        {true, false} ->
            send_error(maps:get(socket, State), Id, invalid_market_limit),
            {ok, State};
        {true, true} ->
            MarketRequest = #{source => market, action => resolve_labels,
                              labels => Labels, limit => Limit},
            case wfcli_market_service:submit(self(), MarketRequest) of
                {ok, Ref} ->
                    Refs = maps:get(market_refs, State),
                    {ok, State#{market_refs => Refs#{Ref => Id}}};
                {error, Reason} ->
                    send_error(maps:get(socket, State), Id, Reason),
                    {ok, State}
            end
    end;
handle_request(#{<<"op">> := <<"market_quote">>, <<"items">> := Items} = Request, State)
  when is_list(Items), length(Items) =< 100 ->
    Id = request_id(Request),
    Ttl = maps:get(<<"ttl">>, Request, 60),
    case is_integer(Ttl) andalso Ttl >= 60 of
        true ->
            MarketRequest = #{source => market, action => quote_items, items => Items,
                              ttl => Ttl,
                              cache_only =>
                                  maps:get(<<"cache_only">>, Request, false) =:= true,
                              refresh => maps:get(<<"refresh">>, Request, false) =:= true},
            case wfcli_market_service:submit(self(), MarketRequest) of
                {ok, Ref} ->
                    Refs = maps:get(market_refs, State),
                    {ok, State#{market_refs => Refs#{Ref => Id}}};
                {error, Reason} ->
                    send_error(maps:get(socket, State), Id, Reason),
                    {ok, State}
            end;
        false ->
            send_error(maps:get(socket, State), Id, invalid_market_ttl),
            {ok, State}
    end;
handle_request(#{<<"op">> := <<"market_quote">>} = Request, State) ->
    send_error(maps:get(socket, State), request_id(Request), invalid_market_items),
    {ok, State};
handle_request(#{<<"op">> := <<"relic_context">>,
                 <<"items">> := Items} = Request, State)
  when is_list(Items), length(Items) =< 8 ->
    Id = request_id(Request),
    MarketRequest = #{source => market, action => relic_context, items => Items,
                      ttl => 60, refresh => false},
    case wfcli_market_service:submit(self(), MarketRequest) of
        {ok, Ref} ->
            Refs = maps:get(market_refs, State),
            {ok, State#{market_refs => Refs#{Ref => Id}}};
        {error, Reason} ->
            send_error(maps:get(socket, State), Id, Reason),
            {ok, State}
    end;
handle_request(#{<<"op">> := <<"relic_context">>} = Request, State) ->
    send_error(maps:get(socket, State), request_id(Request), invalid_relic_items),
    {ok, State};
handle_request(#{<<"op">> := <<"relic_recommendations">>,
                 <<"era">> := Era} = Request, State) when is_binary(Era) ->
    Id = request_id(Request),
    case relic_limit(Request, 32) of
        {ok, Limit} ->
            MarketRequest = #{source => market, action => relic_recommendations,
                              era => Era, view => recommendations, limit => Limit,
                              only_owned => true,
                              fetch_prices =>
                                  maps:get(<<"fetch_prices">>, Request, false) =:= true},
            case wfcli_market_service:submit(self(), MarketRequest) of
                {ok, Ref} ->
                    Refs = maps:get(market_refs, State),
                    {ok, State#{market_refs => Refs#{Ref => Id}}};
                {error, Reason} ->
                    send_error(maps:get(socket, State), Id, Reason),
                    {ok, State}
            end;
        error ->
            send_error(maps:get(socket, State), Id, invalid_relic_limit),
            {ok, State}
    end;
handle_request(#{<<"op">> := <<"relic_recommendations">>} = Request, State) ->
    send_error(maps:get(socket, State), request_id(Request), invalid_relic_era),
    {ok, State};
handle_request(#{<<"op">> := <<"relic_planner">>,
                 <<"era">> := Era} = Request, State) when is_binary(Era) ->
    Id = request_id(Request),
    case relic_limit(Request, all) of
        {ok, Limit} ->
            MarketRequest = #{source => market, action => relic_recommendations,
                              era => Era, view => planner, limit => Limit,
                              only_owned =>
                                  maps:get(<<"only_owned">>, Request, true) =:= true,
                              fetch_prices =>
                                  maps:get(<<"fetch_prices">>, Request, false) =:= true},
            case wfcli_market_service:submit(self(), MarketRequest) of
                {ok, Ref} ->
                    Refs = maps:get(market_refs, State),
                    {ok, State#{market_refs => Refs#{Ref => Id}}};
                {error, Reason} ->
                    send_error(maps:get(socket, State), Id, Reason),
                    {ok, State}
            end;
        error ->
            send_error(maps:get(socket, State), Id, invalid_relic_limit),
            {ok, State}
    end;
handle_request(#{<<"op">> := <<"relic_planner">>} = Request, State) ->
    send_error(maps:get(socket, State), request_id(Request), invalid_relic_era),
    {ok, State};
handle_request(#{<<"op">> := <<"asset_resolve">>,
                 <<"assets">> := Assets} = Request, State)
  when is_list(Assets), length(Assets) =< 64 ->
    Id = request_id(Request),
    Work = fun() ->
        case wfcli_asset_service:resolve(Assets) of
            {ok, Results} -> {ok, #{<<"assets">> => Results}};
            {error, _Reason} = Error -> Error
        end
    end,
    {ok, start_local_request(Id, <<"assets">>, Work, State)};
handle_request(#{<<"op">> := <<"asset_resolve">>} = Request, State) ->
    send_error(maps:get(socket, State), request_id(Request), invalid_assets),
    {ok, State};
handle_request(Request, State) ->
    send_error(maps:get(socket, State), request_id(Request), unsupported_request),
    {ok, State}.

valid_market_labels(Labels)
  when is_list(Labels), length(Labels) =< ?MAX_MARKET_RESOLVE_LABELS ->
    lists:all(fun(Label) -> is_binary(Label) andalso byte_size(Label) > 0 end, Labels);
valid_market_labels(_Labels) -> false.

valid_market_limit(Limit) ->
    is_integer(Limit) andalso Limit >= 1 andalso Limit =< ?MAX_MARKET_RESOLVE_LIMIT.

relic_limit(Request, Default) ->
    case maps:get(<<"limit">>, Request, Default) of
        <<"all">> -> {ok, all};
        Limit when is_integer(Limit), Limit >= 1, Limit =< 1000 -> {ok, Limit};
        _ -> error
    end.

subscribe_player(Id, State) when is_integer(Id) ->
    State1 = unsubscribe_player(Id, State),
    case wfcli_player_service:subscribe(self()) of
        {ok, Ref, Snapshot} ->
            send_ok(maps:get(socket, State1), Id, <<"player">>, Snapshot),
            Subscriptions = maps:get(subscriptions, State1),
            Refs = maps:get(refs, State1),
            {ok, State1#{subscriptions => Subscriptions#{Id => Ref}, refs => Refs#{Ref => Id}}};
        {error, Reason} ->
            send_error(maps:get(socket, State1), Id, Reason),
            {ok, State1}
    end;
subscribe_player(_Id, State) ->
    send_error(maps:get(socket, State), 0, invalid_request_id),
    {ok, State}.

unsubscribe_player(Id, State) ->
    case maps:take(Id, maps:get(subscriptions, State)) of
        error -> State;
        {Ref, Subscriptions} ->
            _ = wfcli_player_service:unsubscribe(Ref),
            Refs = maps:remove(Ref, maps:get(refs, State)),
            State#{subscriptions => Subscriptions, refs => Refs}
    end.

send_subscription_update(Ref, Snapshot, State) ->
    case maps:get(Ref, maps:get(refs, State), undefined) of
        undefined -> State;
        Id ->
            send_json(maps:get(socket, State),
                      #{<<"event">> => <<"dataset">>,
                        <<"subscription">> => Id,
                        <<"dataset">> => <<"player">>,
                        <<"data">> => json_snapshot(Snapshot)}),
            State
    end.

send_market_reply(Ref, Reply, State) ->
    case maps:take(Ref, maps:get(market_refs, State, #{})) of
        error -> State;
        {Id, MarketRefs} ->
            case Reply of
                {ok, Data} -> send_ok(maps:get(socket, State), Id, <<"market">>, Data);
                {error, Reason} -> send_error(maps:get(socket, State), Id, Reason)
            end,
            State#{market_refs => MarketRefs}
    end.

start_local_request(Id, Dataset, Work, State) ->
    Parent = self(),
    Token = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Reply = try Work()
                catch Class:Reason:Stack ->
                    logger:error("local API request failed: ~p:~p~n~p",
                                 [Class, Reason, Stack]),
                    {error, {local_request_failed, Class, Reason}}
                end,
        Parent ! {local_request_result, Token, Id, Dataset, Reply}
    end),
    Worker = #{pid => Pid, monitor => Monitor, id => Id},
    Workers = maps:get(workers, State, #{}),
    State#{workers => Workers#{Token => Worker}}.

send_local_request_result(Token, Id, Dataset, Reply, State) ->
    case maps:take(Token, maps:get(workers, State, #{})) of
        error -> State;
        {#{monitor := Monitor}, Workers} ->
            erlang:demonitor(Monitor, [flush]),
            case Reply of
                {ok, Data} -> send_ok(maps:get(socket, State), Id, Dataset, Data);
                {error, Reason} -> send_error(maps:get(socket, State), Id, Reason)
            end,
            State#{workers => Workers}
    end.

local_request_down(Monitor, Reason, State) ->
    case [{Token, Worker} ||
             {Token, Worker = #{monitor := WorkerMonitor}} <-
                 maps:to_list(maps:get(workers, State, #{})),
             WorkerMonitor =:= Monitor] of
        [{Token, #{id := Id}}] ->
            send_error(maps:get(socket, State), Id, {local_request_down, Reason}),
            State#{workers => maps:remove(Token, maps:get(workers, State))};
        [] -> State
    end.

dataset_snapshot(<<"player">>) ->
    {ok, json_snapshot(wfcli_player_service:snapshot())};
dataset_snapshot(<<"daemon">>) ->
    {ok, daemon_identity()};
dataset_snapshot(Dataset) ->
    {error, {unsupported_dataset, Dataset}}.

json_snapshot(Snapshot) ->
    #{<<"revision">> => maps:get(revision, Snapshot),
      <<"updated_at">> => nullable(maps:get(updated_at, Snapshot)),
      <<"data">> => maps:get(data, Snapshot)}.

daemon_identity() ->
    Build = case wfcli_hot_update:current_build_identity() of
        {ok, Identity} -> Identity;
        {error, _Reason} -> null
    end,
    Version = case application:get_key(wfdaemon, vsn) of
        {ok, Vsn} -> list_to_binary(Vsn);
        undefined -> <<"unknown">>
    end,
    #{<<"status">> => <<"running">>,
      <<"node">> => atom_to_binary(node()),
      <<"version">> => Version,
      <<"otp">> => list_to_binary(erlang:system_info(otp_release)),
      <<"build">> => Build}.

request_id(Request) ->
    case maps:get(<<"id">>, Request, 0) of
        Id when is_integer(Id), Id >= 0 -> Id;
        _ -> 0
    end.

send_ok(Socket, Id, Dataset, Snapshot) ->
    send_json(Socket, #{<<"id">> => Id, <<"ok">> => true,
                        <<"dataset">> => Dataset, <<"data">> => Snapshot}).

send_error(Socket, Id, Reason) ->
    send_json(Socket, #{<<"id">> => Id, <<"ok">> => false,
                        <<"error">> => format_reason(Reason)}).

send_json(Socket, Map) ->
    case socket:send(Socket, wfcli_local_protocol:encode(Map)) of
        ok -> ok;
        {error, closed} -> ok;
        {error, Reason} -> exit({socket_send_failed, Reason})
    end.

format_reason(Reason) when is_binary(Reason) -> Reason;
format_reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason);
format_reason(Reason) -> iolist_to_binary(io_lib:format("~p", [Reason])).

nullable(undefined) -> null;
nullable(Value) -> Value.

cleanup_connection(State) ->
    maps:foreach(fun(_Id, Ref) -> wfcli_player_service:unsubscribe(Ref) end,
                 maps:get(subscriptions, State, #{})),
    maps:foreach(
      fun(_Token, #{pid := Pid, monitor := Monitor}) ->
          exit(Pid, shutdown),
          erlang:demonitor(Monitor, [flush])
      end,
      maps:get(workers, State, #{})),
    exit(maps:get(reader, State), shutdown),
    erlang:demonitor(maps:get(reader_monitor, State), [flush]),
    ok.

update_client_activity(Previous, Client) when Previous =:= Client -> ok;
update_client_activity(Previous, Client) ->
    set_client_activity(is_active_client(Previous), is_active_client(Client)).

set_client_activity(true, false) ->
    wfcli_worldstate_service:activity_end();
set_client_activity(false, true) ->
    wfcli_worldstate_service:activity_start();
set_client_activity(_Previous, _Client) -> ok.

release_client_activity(#{client := Client}) ->
    release_activity(is_active_client(Client));
release_client_activity(_Info) -> ok.

release_activity(true) ->
    wfcli_worldstate_service:activity_end();
release_activity(false) -> ok.

is_active_client(<<"wfcompanion">>) -> true;
is_active_client(<<"wfgui">>) -> true;
is_active_client(_Client) -> false.

valid_os_pid(Pid) when is_integer(Pid), Pid > 0 -> Pid;
valid_os_pid(_Pid) -> undefined.

valid_client_mode(<<"standalone">>) -> <<"standalone">>;
valid_client_mode(<<"launch">>) -> <<"launch">>;
valid_client_mode(<<"desktop">>) -> <<"desktop">>;
valid_client_mode(_Mode) -> <<"unknown">>.
