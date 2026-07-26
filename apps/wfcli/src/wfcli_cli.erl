%%%-------------------------------------------------------------------
%% Entry point for wfcli escript. Dispatches subcommands.
%%%-------------------------------------------------------------------
-module(wfcli_cli).

-export([main/1]).

main(Args) ->
    ensure_started(),
    ok = application:set_env(wfcli, use_daemon, true),
    Prompt = wfcli_cli_args:prompt_enabled(Args),
    dispatch(Args, Prompt).

ensure_started() ->
    case application:ensure_all_started(wfcli) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            io:format("failed to start wfcli: ~p~n", [Reason]),
            halt(1)
    end.

dispatch(Args, Prompt) ->
    {Args1, _} = wfcli_cli_args:strip_prompt_flag(Args),
    dispatch_args(Args1, Prompt).

dispatch_args(["forma-plan" | Rest], _Prompt) ->
    wfcli_forma_plan:run(Rest);
dispatch_args(["visualize" | Rest], _Prompt) ->
    wfcli_visualize:run(Rest);
dispatch_args(["query" | Rest], _Prompt) ->
    wfcli_query_cli:run(Rest);
dispatch_args(["player" | Rest], _Prompt) ->
    wfcli_player_cli:run(Rest);
dispatch_args(["market" | Rest], _Prompt) ->
    wfcli_market_cli:run(Rest);
dispatch_args(["companion" | Rest], _Prompt) ->
    wfcli_companion_cli:run(Rest);
dispatch_args(["mcp" | Rest], _Prompt) ->
    wfcli_mcp_cli:main(Rest);
dispatch_args(["daemon" | Rest], _Prompt) ->
    wfcli_daemon_cli:run(Rest);
dispatch_args(["update" | Rest], _Prompt) ->
    wfcli_update_cli:run(Rest);
dispatch_args(["help" | Rest], _Prompt) ->
    wfcli_help:run(Rest);
dispatch_args(["-h" | _], _Prompt) ->
    usage(),
    halt(0);
dispatch_args(["--help" | _], _Prompt) ->
    usage(),
    halt(0);
dispatch_args([], _Prompt) ->
    usage(),
    halt(1);
dispatch_args([Cmd | Rest], Prompt) ->
    case command_handler(Cmd) of
        {ok, Module} -> Module:run_command(Cmd, Rest);
        error -> handle_unknown_command(Cmd, Rest, Prompt)
    end.

command_handler(Cmd) ->
    case is_worldstate_command(Cmd) of
        true -> {ok, wfcli_worldstate_cli};
        false ->
            case is_exports_command(Cmd) of
                true -> {ok, wfcli_exports_cli};
                false ->
                    case is_knowledge_command(Cmd) of
                        true -> {ok, wfcli_knowledge_cli};
                        false -> error
                    end
            end
    end.

handle_unknown_command(Cmd, Rest, Prompt) ->
    case maybe_prompt_command(Cmd, Rest, Prompt) of
        {ok, NewArgs} -> dispatch_args(NewArgs, Prompt);
        error ->
            Suggest = wfcli_cli_suggest:suggest(Cmd, command_names()),
            io:format("unknown command: ~s~s~n", [Cmd, Suggest]),
            usage(),
            halt(1)
    end.

maybe_prompt_command(Cmd, Rest, true) ->
    case wfcli_cli_suggest:suggest_match(Cmd, command_names()) of
        {ok, Suggestion} ->
            io:format("unknown command: ~s. use ~s? [enter to accept] ", [Cmd, Suggestion]),
            case safe_get_line() of
                accept -> {ok, [Suggestion | Rest]};
                _ -> error
            end;
        none -> error
    end;
maybe_prompt_command(_Cmd, _Rest, false) ->
    error.

safe_get_line() ->
    try io:get_line("") of
        eof -> decline;
        Line when is_list(Line) ->
            case string:lowercase(string:trim(Line)) of
                "" -> accept;
                "y" -> accept;
                _ -> decline
            end;
        _ -> decline
    catch _:_ ->
        decline
    end.

usage() ->
    Core = [
        {"forma-plan", "compute Forma/polarity plan across builds"},
        {"visualize", "render forma-plan outputs"},
        {"query", "search the indexed knowledge base"},
        {"player", "inspect or query local player data"},
        {"market", "look up Warframe Market top-order prices"},
        {"mods", "query mod exports"},
        {"items", "query export item names"},
        {"codex", "query official Codex knowledge"},
        {"enemies", "query optional WFCD enemy knowledge"},
        {"drops", "find WFCD enemy drops by item or enemy"},
        {"daemon", "control persistent wfdaemon process"}
    ],
    Data = [{Cmd, wfcli_worldstate_cli:command_description(Cmd)}
            || Cmd <- wfcli_worldstate_cli:command_help_names(), Cmd =/= "watch"],
    Utility = [
        {"update", "update cached knowledge base data"},
        {"companion", "inspect native game companion"},
        {"mcp", "serve MCP over standard input/output"},
        {"watch", "watch command specs (multi-source)"},
        {"help", "show help topics"},
        {"-h, --help", "show this help"}
    ],
    Rows = Core ++ Data ++ Utility,
    Width = max_cmd_width(Rows, 0),
    Lines =
        ["USAGE:",
         "  wfcli <command> [options]",
         "",
         "COMMANDS:",
         "  Core:"]
        ++ format_usage_rows(Core, Width, 4)
        ++ ["",
            "  Data:"]
        ++ format_usage_rows(Data, Width, 4)
        ++ ["",
            "  Utility:"]
        ++ format_usage_rows(Utility, Width, 4),
    io:format("~ts~n", [string:join(Lines, "\n")]).

max_cmd_width([], Width) -> Width;
max_cmd_width([{Cmd, _} | Rest], Width) ->
    max_cmd_width(Rest, max(Width, wfcli_tty:display_width(Cmd))).

format_usage_rows(Rows, Width, Indent) ->
    Prefix = lists:duplicate(Indent, $ ),
    [
        Prefix ++ wfcli_tty:pad_right(Cmd, Width) ++ "  " ++ Desc
        || {Cmd, Desc} <- Rows
    ].

is_worldstate_command(Cmd) ->
    lists:member(Cmd, wfcli_worldstate_cli:command_names()).

is_exports_command(Cmd) ->
    lists:member(Cmd, wfcli_exports_cli:command_names()).

is_knowledge_command(Cmd) ->
    lists:member(Cmd, wfcli_knowledge_cli:command_names()).

command_names() ->
    ["forma-plan", "visualize", "query", "player", "market", "companion", "mcp", "daemon", "update", "help"]
    ++ wfcli_exports_cli:command_names()
    ++ wfcli_knowledge_cli:command_names()
    ++ wfcli_worldstate_cli:command_names().
