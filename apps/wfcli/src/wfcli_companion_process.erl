%%%-------------------------------------------------------------------
%% Native companion process discovery and transient systemd lifecycle.
%%%-------------------------------------------------------------------
-module(wfcli_companion_process).

-export([binary/0, run/1, start/0, stop/0, unit_active/0]).

-ifdef(TEST).
-export([binary_candidates/2, start_arguments/3]).
-endif.

-define(UNIT, "wfcompanion.service").
-define(COMMAND_TIMEOUT, 120000).

-doc "Find local release-built wfcompanion binary.".
-spec binary() -> {ok, file:filename_all()} | {error, term()}.
binary() ->
    Script = resolve_script_path(filename:absname(escript_name()), 8),
    Candidates = binary_candidates(Script, os:getenv("WFCOMPANION_BIN")),
    case [Path || Path <- Candidates, filelib:is_regular(Path)] of
        [Path | _] -> {ok, Path};
        [] -> {error, {companion_binary_not_found, Candidates}}
    end.

-doc "Run wfcompanion diagnostic command and collect output.".
-spec run([string()]) -> {ok, binary()} | {error, term()}.
run(Args) ->
    case binary() of
        {ok, Path} -> run_command(Path, Args, []);
        {error, _Reason} = Error -> Error
    end.

-doc "Start detached companion in transient user service.".
-spec start() -> {ok, started | already_running, binary()} | {error, term()}.
start() ->
    case unit_active() of
        true -> {ok, already_running, <<>>};
        false ->
            case {os:find_executable("systemd-run"), binary()} of
                {false, _} -> {error, systemd_run_not_found};
                {_, {error, _Reason} = Error} -> Error;
                {SystemdRun, {ok, Companion}} ->
                    _ = reset_failed(),
                    Environment = session_environment(),
                    Args = start_arguments(Companion, wfcli_command(), Environment),
                    case run_command(SystemdRun, Args, []) of
                        {ok, Output} -> {ok, started, Output};
                        {error, Reason} -> {error, {companion_start_failed, Reason}}
                    end
            end
    end.

-doc "Stop detached companion transient user service.".
-spec stop() -> {ok, binary()} | {error, term()}.
stop() ->
    case os:find_executable("systemctl") of
        false -> {error, systemctl_not_found};
        Systemctl -> run_command(Systemctl, ["--user", "stop", ?UNIT], [])
    end.

-doc "Return whether wfcli-managed transient companion service is active.".
-spec unit_active() -> boolean().
unit_active() ->
    case os:find_executable("systemctl") of
        false -> false;
        Systemctl ->
            case run_command_raw(Systemctl, ["--user", "is-active", "--quiet", ?UNIT], []) of
                {0, _Output} -> true;
                {error, _Reason} -> false;
                {_Status, _Output} -> false
            end
    end.

binary_candidates(Script, Environment) ->
    ScriptDir = filename:dirname(Script),
    Env = case Environment of false -> []; "" -> []; Value -> [filename:absname(Value)] end,
    unique(Env ++ [
        filename:absname(filename:join(ScriptDir, "wfcompanion")),
        filename:join([wfcli_build:install_root(), "bin", "wfcompanion"]),
        filename:join([wfcli_build:update_root(), "bin", "wfcompanion"])
    ] ++ path_candidate()).

start_arguments(Companion, Wfcli, Environment) ->
    ["--user",
     "--unit=" ++ filename:rootname(?UNIT),
     "--collect",
     "--service-type=exec",
     "--property=KillMode=mixed"]
    ++ ["--setenv=" ++ Name ++ "=" ++ Value || {Name, Value} <- Environment]
    ++ ["--setenv=WFCLI_COMMAND=" ++ Wfcli,
        "--",
        Companion].

session_environment() ->
    Names = ["PATH", "DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_CURRENT_DESKTOP",
             "DBUS_SESSION_BUS_ADDRESS"],
    [{Name, Value} || Name <- Names,
                      Value <- [os:getenv(Name)],
                      Value =/= false,
                      Value =/= ""].

reset_failed() ->
    case os:find_executable("systemctl") of
        false -> ok;
        Systemctl ->
            _ = run_command_raw(Systemctl, ["--user", "reset-failed", ?UNIT], []),
            ok
    end.

wfcli_command() -> resolve_script_path(filename:absname(escript_name()), 8).

escript_name() ->
    try escript:script_name() of
        undefined -> filename:absname("wfcli");
        Name -> Name
    catch
        _:_ -> filename:absname("wfcli")
    end.

resolve_script_path(Path, 0) -> Path;
resolve_script_path(Path, Remaining) ->
    case file:read_link(Path) of
        {ok, Target} ->
            Next = case filename:pathtype(Target) of
                absolute -> Target;
                _ -> filename:join(filename:dirname(Path), Target)
            end,
            resolve_script_path(filename:absname(Next), Remaining - 1);
        {error, _Reason} -> Path
    end.

path_candidate() ->
    case os:find_executable("wfcompanion") of
        false -> [];
        Path -> [Path]
    end.

unique(Paths) ->
    lists:reverse(
      element(1,
              lists:foldl(
                fun(Path, {Acc, Seen}) ->
                    case sets:is_element(Path, Seen) of
                        true -> {Acc, Seen};
                        false -> {[Path | Acc], sets:add_element(Path, Seen)}
                    end
                end,
                {[], sets:new()},
                Paths))).

run_command(Executable, Args, Environment) ->
    case run_command_raw(Executable, Args, Environment) of
        {0, Output} -> {ok, Output};
        {error, _Reason} = Error -> Error;
        {Status, Output} -> {error, {exit_status, Status, Output}}
    end.

run_command_raw(Executable, Args, Environment) ->
    try
        Port = open_port(
                 {spawn_executable, Executable},
                 [binary, exit_status, stderr_to_stdout, {args, Args}, {env, Environment}]),
        collect_port(Port, [])
    catch
        Class:Reason -> {error, {command_start_failed, Executable, Class, Reason}}
    end.

collect_port(Port, Acc) ->
    receive
        {Port, {data, Data}} -> collect_port(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    after ?COMMAND_TIMEOUT ->
        erlang:port_close(Port),
        {error, command_timeout}
    end.
