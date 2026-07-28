%%%-------------------------------------------------------------------
%% CLI surface for persistent daemon control.
%%%-------------------------------------------------------------------
-module(wfcli_daemon_cli).

-export([run/1, help/0, help/1, known_commands/0]).

-type cli_args() :: [string()].

-doc "Run `wfcli daemon ...` control command.".
-spec run(cli_args()) -> ok | no_return().
run(Args) ->
    Aliases = #{"-h" => "--help"},
    Args1 = wfcli_cli_args:expand_aliases(Args, Aliases),
    case Args1 of
        ["--help" | _] ->
            help(),
            halt(0);
        ["status"] ->
            status();
        ["ensure"] ->
            ensure();
        ["paths"] ->
            wfcli_path_cli:run(["wfdaemon"]);
        ["start" | StartArgs] ->
            start(StartArgs);
        ["stop"] ->
            stop();
        ["restart" | RestartArgs] ->
            restart(RestartArgs);
        ["autostart"] ->
            autostart_status();
        ["autostart", "status"] ->
            autostart_status();
        ["autostart", "enable"] ->
            autostart_enable();
        ["autostart", "disable"] ->
            autostart_disable();
        ["autostart" | _] ->
            fail("daemon autostart accepts enable, disable, or status");
        ["update"] ->
            hot_update(auto);
        ["update", "--beam-dir", BeamDir] ->
            hot_update(BeamDir);
        ["update", "--release", ReleaseName] ->
            release_update(ReleaseName);
        ["update", ReleaseName] ->
            release_update(ReleaseName);
        ["update" | _] ->
            fail("daemon update accepts [--beam-dir DIR] or --release RELEASE_NAME");
        [] ->
            help(),
            halt(1);
        [Cmd | _] ->
            Suggest = wfcli_cli_suggest:suggest(Cmd, known_commands()),
            fail(io_lib:format("unknown daemon command: ~s~s", [Cmd, Suggest]))
    end.

-doc "Print daemon command help.".
-spec help() -> ok.
help() ->
    io:put_chars(wfcli_help_text:daemon_help()).

-spec help([string()]) -> ok.
help([]) -> help();
help(["start" | _]) ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli daemon start [--idle-shutdown] [--idle-timeout SECONDS]\n");
help(["restart" | _]) ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli daemon restart [--idle-shutdown] [--idle-timeout SECONDS]\n");
help(["autostart" | _]) ->
    io:put_chars("USAGE:\n  wfcli daemon autostart status|enable|disable\n");
help(["update" | _]) ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli daemon update [--beam-dir DIR]\n"
      "  wfcli daemon update --release RELEASE\n");
help([Command | _]) ->
    case lists:member(Command, known_commands()) of
        true -> io:format("USAGE:~n  wfcli daemon ~s~n", [Command]);
        false -> help()
    end.

-doc "Known daemon subcommands for suggestions and tests.".
-spec known_commands() -> [string()].
known_commands() ->
    ["status", "ensure", "start", "stop", "restart", "autostart", "update", "paths",
     "help", "--help", "-h"].

status() ->
    case wfcli_client:status() of
        {running, _Node, Info} ->
            io:format("wfdaemon running~n"),
            io:format("  node: ~s~n", [atom_to_list(maps:get(node, Info))]),
            io:format("  pid: ~p~n", [maps:get(pid, Info)]),
            io:format("  uptime_ms: ~p~n", [maps:get(uptime_ms, Info)]),
            io:format("  wfcli: ~s~n", [format_value(maps:get(version, Info, undefined))]),
            io:format("  otp: ~s~n", [format_value(maps:get(otp_release, Info, undefined))]),
            io:format("  flavor: ~s~n", [format_value(maps:get(flavor, Info, undefined))]),
            io:format("  request protocol: ~p~n", [maps:get(protocol, Info, undefined)]),
            io:format("  build: ~s~n", [format_value(maps:get(build, Info, undefined))]),
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
    Policy = parse_idle_policy(Args),
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
    Policy = parse_idle_policy(Args),
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

parse_idle_policy(Args) ->
    parse_idle_policy(Args, false, undefined).

parse_idle_policy([], false, _TimeoutMs) -> persistent;
parse_idle_policy([], true, undefined) -> idle;
parse_idle_policy([], true, TimeoutMs) -> {idle, TimeoutMs};
parse_idle_policy(["--idle-shutdown" | Rest], _Enabled, TimeoutMs) ->
    parse_idle_policy(Rest, true, TimeoutMs);
parse_idle_policy(["--idle-timeout", Seconds | Rest], _Enabled, _TimeoutMs) ->
    case string:to_integer(Seconds) of
        {Value, ""} when Value > 0 -> parse_idle_policy(Rest, true, Value * 1000);
        _ -> fail("--idle-timeout needs positive integer SECONDS")
    end;
parse_idle_policy(["--idle-timeout"], _Enabled, _TimeoutMs) ->
    fail("--idle-timeout needs positive integer SECONDS");
parse_idle_policy([Arg | _Rest], _Enabled, _TimeoutMs) ->
    fail(io_lib:format("unknown daemon start option: ~s", [Arg])).

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
    io:format("error: ~s~n", [lists:flatten(IoData)]),
    halt(1).
