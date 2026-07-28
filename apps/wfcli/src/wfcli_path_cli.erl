%%%-------------------------------------------------------------------
%% Read-only report of per-application XDG directories.
%%%-------------------------------------------------------------------
-module(wfcli_path_cli).

-include_lib("kernel/include/file.hrl").

-export([run/1, help/0]).
-ifdef(TEST).
-export([describe/1, app_paths/1]).
-endif.

-spec run([string()]) -> ok | no_return().
run([]) ->
    print_app(wfcli),
    print_app(wfdaemon),
    print_companion();
run(["wfcli"]) ->
    print_app(wfcli);
run(["wfdaemon"]) ->
    print_app(wfdaemon);
run(["wfcompanion"]) ->
    print_companion();
run(["-h"]) ->
    help();
run(["--help"]) ->
    help();
run(["help"]) ->
    help();
run([App | _]) ->
    io:format("error: unknown application: ~s~n", [App]),
    help(),
    halt(1).

-spec help() -> ok.
help() ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli paths [wfcli|wfdaemon|wfcompanion]\n"
      "\n"
      "DESCRIPTION:\n"
      "  List per-user directories without creating them. Symlink destinations\n"
      "  are shown when the directory itself is a symbolic link.\n").

print_app(App) ->
    io:format("~s~n", [atom_to_list(App)]),
    lists:foreach(fun print_path/1, app_paths(App)).

print_companion() ->
    case wfcli_companion_process:run(["paths"]) of
        {ok, Output} -> io:put_chars(Output);
        {error, Reason} ->
            io:format("wfcompanion~n  unavailable: ~ts~n",
                      [wfcli_client:format_error(Reason)])
    end.

print_path({Kind, Path}) ->
    io:format("  ~-8s ~ts~ts~n", [atom_to_list(Kind), Path, suffix(describe(Path))]).

app_paths(wfcli) ->
    [{config, wfcli_paths:config_dir()},
     {cache, wfcli_paths:cache_dir()},
     {state, wfcli_paths:state_dir()}];
app_paths(wfdaemon) ->
    [{cache, wfcli_paths:cache_dir()},
     {state, wfcli_paths:state_dir()},
     {runtime, wfcli_paths:runtime_dir()}].

describe(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} ->
            case file:read_link(Path) of
                {ok, Target} -> {symlink, absolute_target(Path, Target)};
                {error, Reason} -> {error, Reason}
            end;
        {ok, #file_info{type = directory}} -> directory;
        {ok, #file_info{type = Type}} -> Type;
        {error, enoent} -> missing;
        {error, Reason} -> {error, Reason}
    end.

absolute_target(Path, Target) ->
    case filename:pathtype(Target) of
        absolute -> Target;
        _ -> filename:absname(Target, filename:dirname(Path))
    end.

suffix(directory) -> "";
suffix(missing) -> " (missing)";
suffix({symlink, Target}) -> " -> " ++ Target;
suffix(Type) when is_atom(Type) -> " (" ++ atom_to_list(Type) ++ ")";
suffix({error, Reason}) ->
    lists:flatten(io_lib:format(" (error: ~p)", [Reason])).
