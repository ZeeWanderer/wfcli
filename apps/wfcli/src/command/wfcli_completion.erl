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
    completion_dir/0,
    bashrc_path/0,
    help/0,
    help/1
]).

-ifdef(TEST).
-export([install/2, uninstall/2]).
-endif.

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
    edit_install(install, Args);
run(["uninstall" | Args]) ->
    edit_install(uninstall, Args);
run(["status" | Args]) ->
    with_directory(
      Args,
      fun(Dir) ->
          case installed(Dir) of
              {ok, Present} ->
                  io:format("Bash completion~n  directory: ~s~n  current: ~s~n",
                            [Dir, yes_no(Present)]);
              {error, Reason} -> fail(Reason)
          end
      end);
run(_) ->
    help(),
    halt(1).

edit_install(Action, Args) ->
    with_directory(
      Args,
      fun(Dir) ->
          Result = case Action of
              install -> install(Dir);
              uninstall -> uninstall(Dir)
          end,
          case Result of
              ok -> io:format("Bash completion ~s~n  directory: ~s~n",
                              [action_text(Action), Dir]);
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
    io:format("USAGE:~n  wfcli completion ~s [--dir PATH]~n", [Command]);
help(_) ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli completion bash\n"
      "  wfcli completion install [--dir PATH]\n"
      "  wfcli completion status [--dir PATH]\n"
      "  wfcli completion uninstall [--dir PATH]\n"
      "\n"
      "BASH:\n"
      "  Install writes lazy bash-completion files; no shell eval is needed.\n"
      "  Temporary session: source <(wfcli completion bash)\n").

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
        {["diagnostics"], ["unresolved" | help_flags()]},
        {["diagnostics", "unresolved"], ["--json" | help_flags()]},
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
        {["companion", "capture"], ["arm", "cancel" | help_flags()]},
        {["companion", "capture", "arm"], ["relic-reward" | help_flags()]},
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
        {["completion", "install"], ["--dir" | help_flags()]},
        {["completion", "status"], ["--dir" | help_flags()]},
        {["completion", "uninstall"], ["--dir" | help_flags()]},
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
        {{"completion", "--dir"}, []},
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
     "diagnostics",
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
        "  COMPREPLY=()\n",
        "  compgen -V COMPREPLY -W \"$choices\" -- \"$current\" || true\n",
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

-doc "Install current scripts in the user bash-completion directory.".
-spec install(file:filename_all()) -> ok | {error, term()}.
install(Dir) ->
    case bashrc_path() of
        {ok, Bashrc} -> install(Dir, Bashrc);
        {error, _Reason} = Error -> Error
    end.

install(Dir, Bashrc) ->
    case read_startup(Bashrc) of
        {ok, Content} ->
            case managed_span(Content) of
                {error, _Reason} = Error -> Error;
                Span ->
                    case write_completion_files(Dir) of
                        ok -> remove_managed_startup(Bashrc, Content, Span);
                        {error, _Reason} = Error -> Error
                    end
            end;
        {error, _Reason} = Error -> Error
    end.

-doc "Remove user-installed completion files and the obsolete startup block.".
-spec uninstall(file:filename_all()) -> ok | {error, term()}.
uninstall(Dir) ->
    case bashrc_path() of
        {ok, Bashrc} -> uninstall(Dir, Bashrc);
        {error, _Reason} = Error -> Error
    end.

uninstall(Dir, Bashrc) ->
    case read_startup(Bashrc) of
        {ok, Content} ->
            case managed_span(Content) of
                {error, _Reason} = Error -> Error;
                Span ->
                    case delete_completion_files(Dir) of
                        ok -> remove_managed_startup(Bashrc, Content, Span);
                        {error, _Reason} = Error -> Error
                    end
            end;
        {error, _Reason} = Error -> Error
    end.

-doc "Return whether both user completion files match this build.".
-spec installed(file:filename_all()) -> {ok, boolean()} | {error, term()}.
installed(Dir) ->
    completion_files_match(completion_files(Dir), iolist_to_binary(script())).

-doc "Return the default per-user bash-completion directory.".
-spec completion_dir() -> path_result().
completion_dir() ->
    case first_env_path("BASH_COMPLETION_USER_DIR") of
        {ok, Root} -> {ok, filename:join(Root, "completions")};
        not_set ->
            case data_home() of
                {ok, DataHome} ->
                    {ok, filename:join([DataHome, "bash-completion", "completions"])};
                {error, _Reason} = Error -> Error
            end
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

with_directory(Args, Fun) ->
    case parse_directory(Args) of
        {ok, Dir} -> Fun(Dir);
        {error, Reason} -> fail(Reason)
    end.

parse_directory([]) -> completion_dir();
parse_directory(["--dir", Dir]) -> {ok, filename:absname(Dir)};
parse_directory(["--dir"]) -> {error, completion_directory_missing};
parse_directory(Args) -> {error, {invalid_completion_args, Args}}.

first_env_path(Name) ->
    case os:getenv(Name) of
        false -> not_set;
        undefined -> not_set;
        "" -> not_set;
        Value ->
            case string:lexemes(Value, ":") of
                [Path | _] -> {ok, filename:absname(Path)};
                [] -> not_set
            end
    end.

data_home() ->
    case os:getenv("XDG_DATA_HOME") of
        Value when is_list(Value), Value =/= "" -> {ok, filename:absname(Value)};
        _ ->
            case os:getenv("HOME") of
                Home when is_list(Home), Home =/= "" ->
                    {ok, filename:join(Home, ".local/share")};
                _ -> {error, home_not_set}
            end
    end.

completion_files(Dir) ->
    [filename:join(Dir, "wfcli.bash"),
     filename:join(Dir, "wfclid.bash")].

write_completion_files(Dir) ->
    write_completion_files(completion_files(Dir), script()).

write_completion_files([], _Content) -> ok;
write_completion_files([Path | Rest], Content) ->
    case atomic_write(Path, Content) of
        ok -> write_completion_files(Rest, Content);
        {error, _Reason} = Error -> Error
    end.

delete_completion_files(Dir) ->
    delete_completion_paths(completion_files(Dir)).

delete_completion_paths([]) -> ok;
delete_completion_paths([Path | Rest]) ->
    case file:delete(Path) of
        ok -> delete_completion_paths(Rest);
        {error, enoent} -> delete_completion_paths(Rest);
        {error, Reason} -> {error, {completion_delete_failed, Path, Reason}}
    end.

completion_files_match([], _Expected) -> {ok, true};
completion_files_match([Path | Rest], Expected) ->
    case file:read_file(Path) of
        {ok, Expected} -> completion_files_match(Rest, Expected);
        {ok, _Stale} -> {ok, false};
        {error, enoent} -> {ok, false};
        {error, Reason} -> {error, {completion_read_failed, Path, Reason}}
    end.

remove_managed_startup(_Path, _Content, absent) -> ok;
remove_managed_startup(Path, Content, {present, Start, Finish}) ->
    Prefix = binary:part(Content, 0, Start),
    Suffix0 = binary:part(Content, Finish, byte_size(Content) - Finish),
    write_startup(Path, [Prefix, drop_leading_newline(Suffix0)]).

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
                ok -> replace_file(Path, Temp);
                {error, Reason} ->
                    _ = file:delete(Temp),
                    {error, {completion_write_failed, Path, Reason}}
            end;
        {error, Reason} ->
            {error, {completion_directory_failed, Path, Reason}}
    end.

replace_file(Path, Temp) ->
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
