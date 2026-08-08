%%%-------------------------------------------------------------------
%% Bash completion generation and managed shell startup integration.
%%%-------------------------------------------------------------------
-module(wfcli_completion).

-include_lib("kernel/include/file.hrl").

-export([
    run/1,
    candidates/1,
    script/0,
    install/1,
    uninstall/1,
    installed/1,
    bashrc_path/0,
    help/0,
    help/1
]).

-define(START_MARKER, <<"# >>> wfcli completion >>>">>).
-define(END_MARKER, <<"# <<< wfcli completion <<<">>).

-type path_result() :: {ok, file:filename_all()} | {error, term()}.

-spec run([string()]) -> ok | no_return().
run(["bash"]) ->
    io:put_chars(script());
run(["candidates", "--" | Args]) ->
    lists:foreach(fun(Candidate) -> io:format("~s~n", [Candidate]) end,
                  candidates(Args));
run(["install" | Args]) ->
    edit_startup(install, Args);
run(["uninstall" | Args]) ->
    edit_startup(uninstall, Args);
run(["status" | Args]) ->
    with_path(
      Args,
      fun(Path) ->
          case installed(Path) of
              {ok, Present} ->
                  io:format("Bash completion~n  file: ~s~n  installed: ~s~n",
                            [Path, yes_no(Present)]);
              {error, Reason} -> fail(Reason)
          end
      end);
run(_) ->
    help(),
    halt(1).

edit_startup(Action, Args) ->
    with_path(
      Args,
      fun(Path) ->
          Result = case Action of
              install -> install(Path);
              uninstall -> uninstall(Path)
          end,
          case Result of
              ok -> io:format("Bash completion ~s~n  file: ~s~n",
                              [action_text(Action), Path]);
              {error, Reason} -> fail(Reason)
          end
      end).

action_text(install) -> "installed";
action_text(uninstall) -> "uninstalled".

-spec help() -> ok.
help() ->
    help([]).

-spec help([string()]) -> ok.
help([Command | _]) when Command =:= "install";
                         Command =:= "uninstall";
                         Command =:= "status" ->
    io:format("USAGE:~n  wfcli completion ~s [--file PATH]~n", [Command]);
help(_) ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli completion bash\n"
      "  wfcli completion install [--file PATH]\n"
      "  wfcli completion status [--file PATH]\n"
      "  wfcli completion uninstall [--file PATH]\n"
      "\n"
      "BASH:\n"
      "  source <(wfcli completion bash)\n").

-doc "Return context-sensitive command and option candidates for one shell word.".
-spec candidates([string()]) -> [string()].
candidates(Args) ->
    {Before, Current} = split_current(Args),
    Choices = completion_choices(Before),
    lists:usort([Choice || Choice <- Choices, lists:prefix(Current, Choice)]).

split_current([]) -> {[], ""};
split_current(Args) ->
    {lists:droplast(Args), lists:last(Args)}.

completion_choices([]) ->
    context_choices(root);
completion_choices([Command | _] = Before) ->
    case value_choices(Command, lists:last(Before)) of
        {ok, Choices} -> Choices;
        not_found -> closest_context(Before)
    end.

closest_context([]) -> [];
closest_context(Context) ->
    case context_choices(Context) of
        not_found when length(Context) > 1 ->
            closest_context(lists:droplast(Context));
        not_found -> [];
        Choices -> Choices
    end.

context_choices(Context) ->
    case lists:keyfind(Context, 1, contexts()) of
        {Context, Choices} -> Choices;
        false -> not_found
    end.

value_choices(Command, Option) ->
    Values = values(),
    case lists:keyfind({Command, Option}, 1, Values) of
        {{Command, Option}, Choices} -> {ok, Choices};
        false ->
            case lists:keyfind({"*", Option}, 1, Values) of
                {{"*", Option}, Choices} -> {ok, Choices};
                false -> not_found
            end
    end.

contexts() ->
    [
        {root, wfcli_cli:public_command_names()},
        {["forma-plan"], options(wfcli_forma_plan:known_args())},
        {["visualize"], options(wfcli_visualize:known_args())},
        {["query"], options(wfcli_query_cli:known_args())},
        {["player"], options(wfcli_query_cli:known_args())},
        {["market"], options(wfcli_market_cli:known_args())},
        {["notifications"], ["status", "off", "on", "persistent" | help_flags()]},
        {["mods"], options(wfcli_exports_cli:known_args())},
        {["items"], options(wfcli_exports_cli:known_args())},
        {["codex"], options(wfcli_knowledge_cli:known_args())},
        {["enemies"], options(wfcli_knowledge_cli:known_args())},
        {["drops"], options(wfcli_knowledge_cli:known_args())},
        {["update"], options(wfcli_update_cli:known_args())},
        {["daemon"], wfcli_daemon_cli:known_commands()},
        {["daemon", "autostart"], ["status", "enable", "disable" | help_flags()]},
        {["daemon", "start"], ["--idle-shutdown", "--idle-timeout" | help_flags()]},
        {["daemon", "restart"], ["--idle-shutdown", "--idle-timeout" | help_flags()]},
        {["daemon", "update"], ["--beam-dir", "--release" | help_flags()]},
        {["companion"], wfcli_companion_cli:known_commands()},
        {["companion", "hud"], ["show", "hide" | help_flags()]},
        {["companion", "preview"], ["list", "image", "video" | help_flags()]},
        {["companion", "preview", "list"], ["--animated" | help_flags()]},
        {["companion", "preview", "image"], ["all" | help_flags()]},
        {["companion", "preview", "video"], ["all" | help_flags()]},
        {["companion", "screenshot"], help_flags()},
        {["companion", "relic-ocr"], help_flags()},
        {["companion", "install"], ["--dry-run" | help_flags()]},
        {["companion", "uninstall"], ["--dry-run" | help_flags()]},
        {["gui"], wfcli_gui_cli:known_commands()},
        {["completion"], ["bash", "install", "status", "uninstall" | help_flags()]},
        {["completion", "install"], ["--file" | help_flags()]},
        {["completion", "status"], ["--file" | help_flags()]},
        {["completion", "uninstall"], ["--file" | help_flags()]},
        {["paths"], ["--apps", "wfcli", "wfdaemon", "wfcompanion", "wfgui"
                     | help_flags()]},
        {["help"], help_choices()}
    ] ++ worldstate_contexts().

worldstate_contexts() ->
    [
        {[Command], worldstate_scoped_choices(Command) ++
                    options(wfcli_worldstate_cli:known_args())}
        || Command <- wfcli_worldstate_cli:command_names()
    ].

worldstate_scoped_choices("baro") -> ["inventory"];
worldstate_scoped_choices("prime-vault") -> ["inventory"];
worldstate_scoped_choices("archimedea") -> ["deep", "temporal"];
worldstate_scoped_choices(_) -> [].

values() ->
    format_values(["forma-plan", "visualize"], ["html", "image"]) ++
    format_values(["query", "player", "market" | wfcli_worldstate_cli:command_names()],
                  ["table", "block"]) ++
    format_values(["mods", "items", "codex", "enemies", "drops"],
                  ["table", "block", "json"]) ++
    [
        {{"*", "--diff-style"}, ["inline", "list", "diff", "none"]},
        {{"*", "--viz"}, ["html", "image"]},
        {{"completion", "--file"}, []},
        {{"daemon", "--beam-dir"}, []}
    ].

format_values(Commands, Choices) ->
    [
        {{Command, Option}, Choices}
        || Command <- Commands,
           Option <- ["--output-format", "--format"]
    ].

options(Args) ->
    ["help" | [Arg || [$- | _] = Arg <- Args]].

help_choices() ->
    ["commands", "data", "query", "player", "market", "notifications",
     "companion", "gui", "mcp",
     "watch", "format", "update", "daemon" | wfcli_cli:public_command_names()].

help_flags() -> ["help", "--help", "-h"].

-doc "Generate Bash completion that performs no wfcli process launch while completing.".
-spec script() -> iodata().
script() ->
    [
        bash_map("_WFCLI_COMPLETION_CONTEXTS", context_entries()),
        bash_map("_WFCLI_COMPLETION_VALUES", value_entries()),
        "_wfcli_complete() {\n",
        "  local current=\"${COMP_WORDS[COMP_CWORD]}\"\n",
        "  local command=\"${COMP_WORDS[1]-}\"\n",
        "  local previous=\"${COMP_WORDS[COMP_CWORD-1]-}\"\n",
        "  local value_key=\"$command $previous\"\n",
        "  local generic_key=\"* $previous\"\n",
        "  local key='__root__'\n",
        "  local choices=''\n",
        "  if [[ ${_WFCLI_COMPLETION_VALUES[$value_key]+set} ]]; then\n",
        "    choices=\"${_WFCLI_COMPLETION_VALUES[$value_key]}\"\n",
        "  elif [[ ${_WFCLI_COMPLETION_VALUES[$generic_key]+set} ]]; then\n",
        "    choices=\"${_WFCLI_COMPLETION_VALUES[$generic_key]}\"\n",
        "  else\n",
        "    if (( COMP_CWORD > 1 )); then\n",
        "      local before=(\"${COMP_WORDS[@]:1:COMP_CWORD-1}\")\n",
        "      key=\"${before[*]}\"\n",
        "    fi\n",
        "    while [[ -n \"$key\" ]]; do\n",
        "      if [[ ${_WFCLI_COMPLETION_CONTEXTS[$key]+set} ]]; then\n",
        "        choices=\"${_WFCLI_COMPLETION_CONTEXTS[$key]}\"\n",
        "        break\n",
        "      elif [[ \"$key\" == *' '* ]]; then\n",
        "        key=\"${key% *}\"\n",
        "      else\n",
        "        key=''\n",
        "      fi\n",
        "    done\n",
        "  fi\n",
        "  mapfile -t COMPREPLY < <(compgen -W \"$choices\" -- \"$current\")\n",
        "  if ((${#COMPREPLY[@]} == 0)); then\n",
        "    compopt -o default\n",
        "  fi\n",
        "}\n",
        "complete -F _wfcli_complete wfcli wfclid\n"
    ].

context_entries() ->
    [{context_key(Context), Choices} || {Context, Choices} <- contexts()].

context_key(root) -> "__root__";
context_key(Context) -> string:join(Context, " ").

value_entries() ->
    [{Command ++ " " ++ Option, Choices}
     || {{Command, Option}, Choices} <- values()].

bash_map(Name, Entries) ->
    [
        "declare -gA ", Name, "=(\n",
        [["  [", shell_quote(Key), "]=", shell_quote(string:join(lists:usort(Choices), " ")),
          "\n"] || {Key, Choices} <- Entries],
        ")\n"
    ].

shell_quote(Text) ->
    [$', string:replace(Text, "'", "'\"'\"'", all), $'].

-doc "Install the managed completion block in a Bash startup file.".
-spec install(file:filename_all()) -> ok | {error, term()}.
install(Path) ->
    case read_startup(Path) of
        {ok, Content} ->
            case managed_span(Content) of
                absent -> write_startup(Path, append_block(Content));
                {present, Start, Finish} ->
                    Prefix = binary:part(Content, 0, Start),
                    Suffix = binary:part(Content, Finish, byte_size(Content) - Finish),
                    write_startup(Path, [Prefix, managed_block(), Suffix]);
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

-doc "Remove the managed completion block from a Bash startup file.".
-spec uninstall(file:filename_all()) -> ok | {error, term()}.
uninstall(Path) ->
    case read_startup(Path) of
        {ok, Content} ->
            case managed_span(Content) of
                absent -> ok;
                {present, Start, Finish} ->
                    Prefix = binary:part(Content, 0, Start),
                    Suffix0 = binary:part(Content, Finish, byte_size(Content) - Finish),
                    write_startup(Path, [Prefix, drop_leading_newline(Suffix0)]);
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

-doc "Return whether a Bash startup file contains the complete managed block.".
-spec installed(file:filename_all()) -> {ok, boolean()} | {error, term()}.
installed(Path) ->
    case read_startup(Path) of
        {ok, Content} ->
            case managed_span(Content) of
                absent -> {ok, false};
                {present, _Start, _Finish} -> {ok, true};
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

-doc "Return the default Bash startup file.".
-spec bashrc_path() -> path_result().
bashrc_path() ->
    case os:getenv("HOME") of
        false -> {error, home_not_set};
        undefined -> {error, home_not_set};
        "" -> {error, home_not_set};
        Home -> {ok, filename:join(Home, ".bashrc")}
    end.

with_path(Args, Fun) ->
    case parse_path(Args) of
        {ok, Path} -> Fun(Path);
        {error, Reason} -> fail(Reason)
    end.

parse_path([]) -> bashrc_path();
parse_path(["--file", Path]) -> {ok, filename:absname(Path)};
parse_path(["--file"]) -> {error, completion_file_missing};
parse_path(Args) -> {error, {invalid_completion_args, Args}}.

read_startup(Path) ->
    case file:read_file(Path) of
        {ok, Content} -> {ok, Content};
        {error, enoent} -> {ok, <<>>};
        {error, Reason} -> {error, {completion_read_failed, Path, Reason}}
    end.

write_startup(Path, Content) ->
    write_startup(Path, Content, 16).

write_startup(_Path, _Content, 0) ->
    {error, completion_symlink_depth};
write_startup(Path, Content, Depth) ->
    case file:read_link(Path) of
        {ok, Target} ->
            write_startup(filename:absname(Target, filename:dirname(Path)),
                          Content, Depth - 1);
        {error, einval} -> atomic_write(Path, Content);
        {error, enoent} -> atomic_write(Path, Content);
        {error, Reason} -> {error, {completion_link_failed, Path, Reason}}
    end.

atomic_write(Path, Content) ->
    Temp = Path ++ ".tmp." ++ integer_to_list(erlang:unique_integer([positive])),
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Temp, Content) of
                ok -> replace_startup(Path, Temp);
                {error, Reason} ->
                    {error, {completion_write_failed, Path, Reason}}
            end;
        {error, Reason} ->
            {error, {completion_directory_failed, Path, Reason}}
    end.

replace_startup(Path, Temp) ->
    case file:read_file_info(Path) of
        {ok, #file_info{mode = Mode}} -> _ = file:change_mode(Temp, Mode);
        {error, _Reason} -> ok
    end,
    case file:rename(Temp, Path) of
        ok -> ok;
        {error, Reason} ->
            _ = file:delete(Temp),
            {error, {completion_install_failed, Path, Reason}}
    end.

append_block(<<>>) ->
    [managed_block(), "\n"];
append_block(Content) ->
    Separator = case binary:last(Content) of $\n -> <<>>; _ -> <<"\n">> end,
    [Content, Separator, managed_block(), "\n"].

managed_block() ->
    [
        ?START_MARKER, "\n",
        "if command -v wfcli >/dev/null 2>&1; then\n",
        "  eval \"$(wfcli completion bash)\"\n",
        "elif command -v wfclid >/dev/null 2>&1; then\n",
        "  eval \"$(wfclid completion bash)\"\n",
        "fi\n",
        ?END_MARKER
    ].

managed_span(Content) ->
    Starts = binary:matches(Content, ?START_MARKER),
    Ends = binary:matches(Content, ?END_MARKER),
    case {Starts, Ends} of
        {[], []} -> absent;
        {[{Start, _}], [{End, EndLength}]} when End > Start ->
            {present, Start, End + EndLength};
        _ -> {error, malformed_completion_block}
    end.

drop_leading_newline(<<"\r\n", Rest/binary>>) -> Rest;
drop_leading_newline(<<"\n", Rest/binary>>) -> Rest;
drop_leading_newline(Content) -> Content.

yes_no(true) -> "yes";
yes_no(false) -> "no".

fail(Reason) ->
    io:format("error: completion: ~p~n", [Reason]),
    halt(1).
