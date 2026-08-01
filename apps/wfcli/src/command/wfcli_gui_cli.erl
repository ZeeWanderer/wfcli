%%%-------------------------------------------------------------------
%% Desktop GUI setup command.
%%%-------------------------------------------------------------------
-module(wfcli_gui_cli).

-export([run/1, help/0, known_commands/0]).

-doc "Install, inspect, or remove the wfgui desktop launcher.".
-spec run([string()]) -> ok | no_return().
run([Command]) when Command =:= "help"; Command =:= "--help"; Command =:= "-h" ->
    help();
run(["install"]) -> print_result(install, wfcli_gui_desktop:install());
run(["status"]) -> print_result(status, wfcli_gui_desktop:status());
run(["uninstall"]) -> print_result(uninstall, wfcli_gui_desktop:uninstall());
run([]) -> help(), halt(1);
run([Command | _]) ->
    Suggest = wfcli_cli_suggest:suggest(Command, known_commands()),
    fail(io_lib:format("unknown gui command: ~s~s", [Command, Suggest])).

-doc "Print GUI setup help.".
-spec help() -> ok.
help() ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli gui install\n"
      "  wfcli gui status\n"
      "  wfcli gui uninstall\n").

-spec known_commands() -> [string()].
known_commands() -> ["install", "status", "uninstall", "help", "--help", "-h"].

print_result(Action, {ok, Result}) ->
    Installed = maps:get(installed, Result),
    State = case {Action, Installed} of
        {install, true} -> "installed";
        {uninstall, false} -> "uninstalled";
        {status, true} -> "installed";
        {status, false} -> "not installed"
    end,
    io:format("wfgui desktop launcher ~s~n", [State]),
    io:format("  desktop: ~ts~n", [maps:get(desktop, Result)]),
    io:format("  icon: ~ts~n", [maps:get(icon, Result)]),
    case maps:find(executable, Result) of
        {ok, Executable} -> io:format("  executable: ~ts~n", [Executable]);
        error -> ok
    end;
print_result(_Action, {error, Reason}) -> fail(io_lib:format("~p", [Reason])).

fail(Message) ->
    io:format("error: ~ts~n", [Message]),
    halt(1).
