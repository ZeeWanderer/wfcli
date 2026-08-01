%%%-------------------------------------------------------------------
%% Help topics for wfcli.
%%%-------------------------------------------------------------------
-module(wfcli_help).

-export([run/1]).

run([]) ->
    wfcli_cli:usage();
run(["commands"]) ->
    Data = wfcli_worldstate_cli:command_help_names(),
    Exports = wfcli_exports_cli:command_names() ++ wfcli_knowledge_cli:command_names(),
    Base = ["forma-plan", "visualize", "query", "player", "market", "notifications",
            "companion", "mcp",
            "daemon", "update", "completion", "paths", "help"],
    List = Base ++ Exports ++ Data,
    io:format(
      "Top-level commands:~n~s~n",
      [format_columns(List)]
    );
run(["data"]) ->
    wfcli_worldstate_cli:help([]);
run(["worldstate"]) ->
    run(["data"]);
run(["mods" | Rest]) ->
    wfcli_exports_cli:help(["mods" | Rest]);
run(["items" | Rest]) ->
    wfcli_exports_cli:help(["items" | Rest]);
run([Topic | _]) when Topic =:= "codex"; Topic =:= "enemies"; Topic =:= "drops" ->
    wfcli_knowledge_cli:help(Topic);
run(["exports"]) ->
    wfcli_exports_cli:help([]);
run(["query" | _]) ->
    wfcli_query_cli:help();
run(["player" | _]) ->
    wfcli_player_cli:help();
run(["market" | _]) ->
    wfcli_market_cli:help();
run(["notifications" | _]) ->
    wfcli_notification_cli:help();
run(["companion" | Rest]) ->
    wfcli_companion_cli:help(Rest);
run(["mcp" | _]) ->
    io:put_chars(wfcli_help_text:mcp_help());
run(["watch" | _]) ->
    wfcli_worldstate_cli:help(["watch"]);
run(["update" | _]) ->
    wfcli_update_cli:help();
run(["daemon" | Rest]) ->
    wfcli_daemon_cli:help(Rest);
run(["completion" | Rest]) ->
    wfcli_completion:help(Rest);
run(["paths" | _]) ->
    wfcli_path_cli:help();
run(["format" | _]) ->
    io:format(
      "Output format: table|block for data/query; table|block|json for catalog commands.~n"
      "--format is an alias for --output-format where supported.~n"
    );
run(["forma-plan" | _]) ->
    io:put_chars(wfcli_help_text:forma_plan_help());
run(["visualize" | _]) ->
    io:put_chars(wfcli_help_text:visualize_help());
run(["help"]) ->
    run([]);
run([Topic | Rest]) ->
    case lists:member(Topic, wfcli_worldstate_cli:command_help_names()) of
        true -> wfcli_worldstate_cli:help([Topic | Rest]);
        false ->
            io:format("unknown help topic: ~s~n", [Topic]),
            run([])
    end.

format_columns([]) -> "";
format_columns(Items) ->
    Width = max_item_width(Items, 0) + 2,
    TermWidth = wfcli_tty:terminal_width(),
    Cols0 = case Width of
        0 -> 1;
        _ -> max(1, TermWidth div Width)
    end,
    Cols = min(3, Cols0),
    Rows = (length(Items) + Cols - 1) div Cols,
    Lines = [
        format_row(Items, Row, Rows, Cols, Width)
        || Row <- lists:seq(1, Rows)
    ],
    string:join(Lines, "\n").

format_row(Items, Row, Rows, Cols, Width) ->
    Cells = [
        nth_or_empty(Items, Row + (Col - 1) * Rows)
        || Col <- lists:seq(1, Cols)
    ],
    Line = string:join([wfcli_tty:pad_right(Cell, Width) || Cell <- Cells], ""),
    lists:flatten(trim_right(Line)).

nth_or_empty(List, N) ->
    case N =< length(List) of
        true -> lists:nth(N, List);
        false -> ""
    end.

max_item_width([], Width) -> Width;
max_item_width([Item | Rest], Width) ->
    max_item_width(Rest, max(Width, wfcli_tty:display_width(Item))).

trim_right(Str) ->
    lists:reverse(trim_left(lists:reverse(Str))).

trim_left([$\s | Rest]) -> trim_left(Rest);
trim_left(List) -> List.
