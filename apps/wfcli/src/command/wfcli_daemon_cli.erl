-module(wfcli_daemon_cli).

-export([command/0]).
-import(wfcli_cli_args, [option/4, flag/3]).

command() ->
    #{help => "control persistent wfdaemon process",
      commands => #{
        "status" => #{help => "show daemon state without starting it",
                      handler => fun(_) -> status() end},
        "ensure" => #{help => "start if absent; preserve a running idle policy",
                      handler => fun(_) -> ensure() end},
        "paths" => #{help => "show daemon XDG directories",
                     handler => fun(_) -> wfcli_path_cli:run(#{owner => wfdaemon}) end},
        "start" => #{help => "start or pin daemon until explicit stop",
                     handler => fun start/1, arguments => idle_arguments()},
        "stop" => #{help => "stop daemon", handler => fun(_) -> stop() end},
        "restart" => #{help => "restart daemon; persistent by default",
                       handler => fun restart/1, arguments => idle_arguments()},
        "autostart" => #{help => "manage login startup", handler => fun(_) -> autostart_status() end,
                          commands => #{
                            "status" => #{help => "show user-service state",
                                          handler => fun(_) -> autostart_status() end},
                            "enable" => #{help => "start now and at login",
                                          handler => fun(_) -> autostart_enable() end},
                            "disable" => #{help => "disable login startup; leave daemon running",
                                           handler => fun(_) -> autostart_disable() end}}},
        "update" => #{help => "hot-load current installation or apply an OTP release",
                      handler => fun update/1,
                      arguments => [option(beam_dir, "beam-dir", string, "explicit ebin directory"),
                                    option(release, "release", string, "OTP release package")]}}}.

idle_arguments() ->
    [flag(idle_shutdown, "idle-shutdown", "enable idle shutdown"),
     option(idle_timeout, "idle-timeout", {integer, [{min, 1}]}, "idle timeout in seconds")].

update(#{beam_dir := _, release := _}) -> fail("--beam-dir and --release are mutually exclusive");
update(#{beam_dir := Dir}) -> hot_update(Dir);
update(#{release := Name}) -> release_update(Name);
update(_) -> hot_update(auto).

status() ->
    case wfcli_client:status() of
        {running, _Node, Info} ->
            io:format("wfdaemon running~n"),
            io:format("  node: ~s~n", [atom_to_list(maps:get(node, Info))]),
            io:format("  pid: ~p~n", [maps:get(pid, Info)]),
            io:format("  uptime_ms: ~p~n", [maps:get(uptime_ms, Info)]),
            io:format("  version: ~s~n", [format_value(maps:get(version, Info, undefined))]),
            io:format("  OTP release: ~s~n", [format_value(maps:get(otp_release, Info, undefined))]),
            io:format("  installation: ~s~n",
                      [format_value(maps:get(installation, Info, undefined))]),
            io:format("  install root: ~s~n",
                      [format_value(maps:get(install_root, Info, undefined))]),
            io:format("  build flavor: ~s~n",
                      [format_value(maps:get(flavor, Info, undefined))]),
            io:format("  artifact ID: ~s~n", [format_value(maps:get(build, Info, undefined))]),
            print_protocols(Info),
            print_runtime_status(maps:get(service, Info, unavailable),
                                 maps:get(exports, Info, unavailable),
                                 maps:get(market, Info, unavailable));
        {stopped, Node} ->
            io:format("wfdaemon stopped~n  node: ~s~n", [atom_to_list(Node)]);
        {error, Reason} ->
            fail(io_lib:format("daemon status failed: ~p", [Reason]))
    end.

ensure() ->
    case wfcli_client:ensure_running() of
        {ok, already_running, Node} ->
            io:format("wfdaemon already running~n  node: ~s~n", [atom_to_list(Node)]);
        {ok, started, Node} ->
            io:format("wfdaemon started~n  node: ~s~n", [atom_to_list(Node)]);
        {error, Reason} ->
            fail(io_lib:format("daemon ensure failed: ~p", [Reason]))
    end.

start(Args) ->
    Policy = idle_policy(Args),
    case wfcli_client:start(Policy) of
        {ok, already_running, Node} ->
            io:format("wfdaemon already running~n  node: ~s~n", [atom_to_list(Node)]),
            print_idle_policy(Policy);
        {ok, started, Node} ->
            io:format("wfdaemon started~n  node: ~s~n", [atom_to_list(Node)]),
            print_idle_policy(Policy);
        {error, Reason} ->
            fail(io_lib:format("daemon start failed: ~p", [Reason]))
    end.

stop() ->
    case wfcli_client:stop() of
        {ok, stopped, Node} ->
            io:format("wfdaemon stopped~n  node: ~s~n", [atom_to_list(Node)]);
        {error, Reason} ->
            fail(io_lib:format("daemon stop failed: ~p", [Reason]))
    end.

restart(Args) ->
    Policy = idle_policy(Args),
    case wfcli_client:restart(Policy) of
        {ok, restarted, Node} ->
            io:format("wfdaemon restarted~n  node: ~s~n", [atom_to_list(Node)]),
            print_idle_policy(Policy);
        {error, Reason} ->
            fail(io_lib:format("daemon restart failed: ~p", [Reason]))
    end.

autostart_status() ->
    case wfcli_autostart:status() of
        {ok, Status} -> print_autostart(Status);
        {error, Reason} -> fail(io_lib:format("daemon autostart status failed: ~p", [Reason]))
    end.

autostart_enable() ->
    case wfcli_autostart:enable() of
        {ok, Status} ->
            io:format("wfdaemon autostart enabled~n"),
            print_autostart_details(Status);
        {error, Reason} -> fail(io_lib:format("daemon autostart enable failed: ~p", [Reason]))
    end.

autostart_disable() ->
    case wfcli_autostart:disable() of
        {ok, Status} ->
            io:format("wfdaemon autostart disabled~n"),
            print_autostart_details(Status);
        {error, Reason} -> fail(io_lib:format("daemon autostart disable failed: ~p", [Reason]))
    end.

print_autostart(Status) ->
    io:format("wfdaemon autostart~n"),
    print_autostart_details(Status).

print_autostart_details(Status) ->
    io:format("  manager: ~s~n", [atom_to_list(maps:get(manager, Status, systemd))]),
    io:format("  unit: ~s~n", [maps:get(path, Status)]),
    io:format("  installed: ~s~n", [yes_no(maps:get(installed, Status))]),
    io:format("  enabled: ~s~n", [yes_no(maps:get(enabled, Status))]),
    io:format("  active: ~s~n", [yes_no(maps:get(active, Status))]).

yes_no(true) -> "yes";
yes_no(false) -> "no".

hot_update(BeamDir) ->
    case wfcli_client:hot_update(BeamDir) of
        {ok, Result} ->
            Loaded = maps:get(loaded, Result, []),
            Migrated = maps:get(migrated, Result, []),
            Unchanged = maps:get(unchanged, Result, []),
            io:format("wfdaemon hot updated~n"),
            io:format("  loaded: ~p~n", [length(Loaded)]),
            io:format("  state migrations: ~p~n", [length(Migrated)]),
            io:format("  unchanged: ~p~n", [length(Unchanged)]),
            print_loaded_modules(Loaded);
        {error, Reason} ->
            fail(io_lib:format("daemon hot update failed: ~p", [Reason]))
    end.

release_update(ReleaseName) ->
    case wfcli_client:update(ReleaseName) of
        {ok, ok} ->
            io:format("wfdaemon updated~n");
        {ok, Reply} ->
            io:format("wfdaemon update reply: ~p~n", [Reply]);
        {error, Reason} ->
            fail(io_lib:format("daemon update failed: ~p", [Reason]))
    end.

format_value(undefined) -> "unknown";
format_value(Value) when is_binary(Value) -> binary_to_list(Value);
format_value(Value) when is_list(Value) -> Value;
format_value(Value) when is_atom(Value) -> atom_to_list(Value);
format_value(Value) -> lists:flatten(io_lib:format("~p", [Value])).

print_protocols(Info) ->
    Protocols = maps:get(protocols, Info, #{}),
    io:format("  protocol contracts:~n"),
    print_contract("CLI/MCP Erlang RPC",
                   maps:get(erlang_distribution_rpc, Protocols, #{})),
    print_contract("GUI/companion JSON-lines Unix socket",
                   maps:get(native_socket_api, Protocols, #{})).

print_contract(Label, Contract) when is_map(Contract) ->
    Handshake = maps:get(handshake, Contract,
                         maps:get(<<"envelope">>, Contract, undefined)),
    Interfaces = maps:get(interfaces, Contract,
                          maps:get(<<"interfaces">>, Contract, #{})),
    Features = maps:get(features, Contract,
                        maps:get(<<"features">>, Contract, [])),
    io:format("    ~s:~n", [Label]),
    io:format("      handshake envelope: ~s~n", [format_value(Handshake)]),
    io:format("      interfaces: ~s~n", [format_interfaces(Interfaces)]),
    case Features of
        [] -> ok;
        _ -> io:format("      optional features: ~s~n",
                       [string:join([format_value(Feature) || Feature <- Features], ", ")])
    end;
print_contract(Label, _Contract) ->
    io:format("    ~s: unavailable~n", [Label]).

format_interfaces(Interfaces) when is_map(Interfaces) ->
    string:join(
      [format_value(Name) ++ "=" ++ format_value(Version)
       || {Name, Version} <- lists:sort(maps:to_list(Interfaces))],
      ", ");
format_interfaces(_Interfaces) -> "unknown".

print_runtime_status(Service, Exports, Market) when is_map(Service), is_map(Exports) ->
    io:format("  worldstate: ~p snapshot(s), ~p watch(es), ~p queued, ~p fetching~n",
              [maps:get(snapshots, Service, 0), maps:get(watches, Service, 0),
               maps:get(one_shots, Service, 0), maps:get(fetching, Service, 0)]),
    io:format("  catalogs: ~p cached, ~p queued~n",
              [maps:get(cached_catalogs, Exports, maps:get(cached_datasets, Exports, 0)),
               maps:get(queued, Exports, 0)]),
    print_market_status(Market),
    print_idle_status(Service);
print_runtime_status(_Service, _Exports, _Market) -> ok.

print_market_status(Market) when is_map(Market) ->
    io:format("  market: ~p items, ~p quotes, ~p queued~n",
              [maps:get(items, Market, 0), maps:get(cached_quotes, Market, 0),
               maps:get(queued, Market, 0)]),
    case maps:get(cache_error, Market, undefined) of
        undefined -> ok;
        Error -> io:format("  market cache error: ~p~n", [Error])
    end;
print_market_status(_Market) -> ok.

idle_policy(#{idle_timeout := Seconds}) -> {idle, Seconds * 1000};
idle_policy(#{idle_shutdown := true}) -> idle;
idle_policy(_) -> persistent.

print_idle_policy(persistent) ->
    io:format("  idle shutdown: disabled~n");
print_idle_policy(idle) ->
    io:format("  idle shutdown: enabled (configured timeout)~n");
print_idle_policy({idle, TimeoutMs}) ->
    io:format("  idle shutdown: ~p seconds~n", [TimeoutMs div 1000]).

print_idle_status(#{idle_policy := persistent}) ->
    io:format("  idle shutdown: disabled~n");
print_idle_status(#{idle_policy := idle, idle_timeout_ms := TimeoutMs}) ->
    io:format("  idle shutdown: ~p seconds~n", [TimeoutMs div 1000]);
print_idle_status(_Service) -> ok.

print_loaded_modules([]) -> ok;
print_loaded_modules(Modules) ->
    Names = [atom_to_list(Module) || Module <- Modules],
    io:format("  modules: ~s~n", [string:join(Names, ", ")]).

fail(IoData) ->
    io:format(standard_error, "error: ~s~n", [lists:flatten(IoData)]),
    halt(1).
