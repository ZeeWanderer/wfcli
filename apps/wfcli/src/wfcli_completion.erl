%%%-------------------------------------------------------------------
%% Generated shell completion backed by the live CLI command registry.
%%%-------------------------------------------------------------------
-module(wfcli_completion).

-export([run/1, candidates/1, help/0]).

-spec run([string()]) -> ok | no_return().
run(["bash"]) ->
    io:put_chars(bash_script());
run(["candidates", "--" | Args]) ->
    lists:foreach(fun(Candidate) -> io:format("~s~n", [Candidate]) end,
                  candidates(Args));
run(_) ->
    help(),
    halt(1).

-spec help() -> ok.
help() ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli completion bash\n"
      "\n"
      "BASH:\n"
      "  source <(wfcli completion bash)\n").

-doc "Return context-sensitive command and option candidates for one shell word.".
-spec candidates([string()]) -> [string()].
candidates(Args) ->
    {Before, Current} = split_current(Args),
    Choices = case Before of
        [] -> wfcli_cli:public_command_names();
        [Command | Rest] -> command_candidates(Command, Rest)
    end,
    lists:usort([Choice || Choice <- Choices, lists:prefix(Current, Choice)]).

split_current([]) -> {[], ""};
split_current(Args) ->
    {lists:droplast(Args), lists:last(Args)}.

command_candidates("forma-plan", _Rest) ->
    options(wfcli_forma_plan:known_args());
command_candidates("visualize", _Rest) ->
    options(wfcli_visualize:known_args());
command_candidates(Command, Rest) when Command =:= "query"; Command =:= "player" ->
    option_values(Rest, ["table", "block"], options(wfcli_query_cli:known_args()));
command_candidates("market", Rest) ->
    option_values(Rest, ["table", "block"], options(wfcli_market_cli:known_args()));
command_candidates(Command, Rest) when Command =:= "mods"; Command =:= "items" ->
    option_values(Rest, ["table", "block", "json"],
                  options(wfcli_exports_cli:known_args()));
command_candidates(Command, Rest)
  when Command =:= "codex"; Command =:= "enemies"; Command =:= "drops" ->
    option_values(Rest, ["table", "block", "json"],
                  options(wfcli_knowledge_cli:known_args()));
command_candidates("update", _Rest) ->
    options(wfcli_update_cli:known_args());
command_candidates("daemon", Rest) ->
    daemon_candidates(Rest);
command_candidates("companion", Rest) ->
    companion_candidates(Rest);
command_candidates("completion", []) ->
    ["bash", "help", "--help", "-h"];
command_candidates("paths", _Rest) ->
    ["wfcli", "wfdaemon", "wfcompanion", "help", "--help", "-h"];
command_candidates("help", []) ->
    ["commands", "data", "query", "player", "market", "companion", "mcp",
     "watch", "format", "update", "daemon" | wfcli_cli:public_command_names()];
command_candidates(Command, Rest) ->
    case lists:member(Command, wfcli_worldstate_cli:command_names()) of
        true -> worldstate_candidates(Command, Rest);
        false -> []
    end.

worldstate_candidates(Command, Rest) ->
    Scoped = case Command of
        "baro" -> ["inventory"];
        "prime-vault" -> ["inventory"];
        "archimedea" -> ["deep", "temporal"];
        _ -> []
    end,
    option_values(Rest, ["table", "block"],
                  Scoped ++ options(wfcli_worldstate_cli:known_args())).

daemon_candidates([]) ->
    wfcli_daemon_cli:known_commands();
daemon_candidates(["autostart" | _]) ->
    ["status", "enable", "disable", "help", "--help", "-h"];
daemon_candidates([Command | _])
  when Command =:= "start"; Command =:= "restart" ->
    ["--idle-shutdown", "--idle-timeout", "help", "--help", "-h"];
daemon_candidates(["update" | _]) ->
    ["--beam-dir", "--release", "help", "--help", "-h"];
daemon_candidates(_) ->
    ["help", "--help", "-h"].

companion_candidates([]) ->
    wfcli_companion_cli:known_commands();
companion_candidates(["hud" | _]) ->
    ["show", "hide", "help", "--help", "-h"];
companion_candidates(["preview"]) ->
    ["list", "image", "video", "help", "--help", "-h"];
companion_candidates(["preview", "list" | _]) ->
    ["--animated", "help", "--help", "-h"];
companion_candidates(["preview", Kind | _])
  when Kind =:= "image"; Kind =:= "video" ->
    ["all", "help", "--help", "-h"];
companion_candidates([Command | _])
  when Command =:= "screenshot"; Command =:= "relic-ocr" ->
    ["--target", "help", "--help", "-h"];
companion_candidates([Command | _])
  when Command =:= "install"; Command =:= "uninstall" ->
    ["--dry-run", "help", "--help", "-h"];
companion_candidates(_) ->
    ["help", "--help", "-h"].

option_values(Rest, Formats, Default) ->
    case last(Rest) of
        "--output-format" -> Formats;
        "--format" -> Formats;
        "--diff-style" -> ["inline", "list", "diff", "none"];
        "--viz" -> ["html", "image", "wx"];
        "--target" -> ["active", "screen"];
        _ -> Default
    end.

last([]) -> undefined;
last(List) -> lists:last(List).

options(Args) ->
    ["help" | [Arg || [$- | _] = Arg <- Args]].

bash_script() ->
    [
        "_wfcli_complete() {\n",
        "  local executable=\"${COMP_WORDS[0]}\"\n",
        "  mapfile -t COMPREPLY < <(\"$executable\" completion candidates -- \"${COMP_WORDS[@]:1}\")\n",
        "  if ((${#COMPREPLY[@]} == 0)); then\n",
        "    compopt -o default\n",
        "  fi\n",
        "}\n",
        "complete -F _wfcli_complete wfcli wfclid\n"
    ].
