%%%-------------------------------------------------------------------
%% CLI argument and help adapter for Codex and WFCD knowledge queries.
%%%-------------------------------------------------------------------
-module(wfcli_knowledge_cli).

-export([run_command/2, command_names/0, help/1]).

-ifdef(TEST).
-export([parse_request/2]).
-endif.

-type command() :: string().

-doc "Return focused knowledge command names.".
-spec command_names() -> [command()].
command_names() -> ["codex", "enemies", "drops"].

-doc "Parse CLI arguments, run the knowledge service, and render its result.".
-spec run_command(command(), [string()]) -> ok | no_return().
run_command(Command, Args0) ->
    Args = expand_args(Args0),
    case wfcli_cli_args:has_help_flag(Args) of
        true -> help(Command), halt(0);
        false ->
            case parse_request(Command, Args) of
                {ok, Query} -> run_query(Command, Query);
                {error, Errors} -> fail(Errors)
            end
    end.

run_query(Command, Query) ->
    case wfcli_catalog_client:query(Command, Query) of
        {ok, Prepared, Results} -> wfcli_knowledge_format:print(Prepared, Results);
        {error, Errors} -> fail(Errors)
    end.

fail(Errors) ->
    lists:foreach(fun(Error) -> io:format("error: ~ts~n", [Error]) end, Errors),
    halt(1).

expand_args(Args) ->
    Aliases = #{"-h" => "--help", "-f" => "--format", "-l" => "--limit", "-o" => "--offset"},
    Expanded = wfcli_cli_args:expand_aliases(Args, Aliases),
    wfcli_cli_args:prompt_suggestions(Expanded, known_args()).

known_args() ->
    ["--name", "--text", "--category", "--faction", "--enemy", "--rarity", "--file",
     "--include-excluded", "--raw", "--exports-dir", "--knowledge-dir", "--limit",
     "--offset", "--output-format", "--format", "--help", "-h", "-f", "-l", "-o",
     "--no-suggest-prompt"].

-doc "Convert focused-command arguments into an uncompiled typed request.".
-spec parse_request(command(), [string()]) -> {ok, map()} | {error, [iodata()]}.
parse_request(Command, Args) ->
    case lists:member(Command, command_names()) of
        true ->
            Parsed = parse_args(Args, request_defaults()),
            parsed_request(Parsed);
        false -> {error, [io_lib:format("unknown knowledge command: ~s", [Command])]}
    end.

parsed_request(Parsed) ->
    case maps:get(errors, Parsed) of
        [] -> {ok, Parsed};
        Errors -> {error, Errors}
    end.

parse_args([], Acc) -> Acc;
parse_args(["--name", Value | Rest], Acc) ->
    parse_args(Rest, add_filter(name, contains, Value, Acc));
parse_args(["--text", Value | Rest], Acc) ->
    parse_args(Rest, add_text(Value, Acc));
parse_args(["--category", Value | Rest], Acc) ->
    parse_args(Rest, add_filter(category, eq, Value, Acc));
parse_args(["--faction", Value | Rest], Acc) ->
    parse_args(Rest, add_filter(faction, eq, Value, Acc));
parse_args(["--enemy", Value | Rest], Acc) ->
    parse_args(Rest, add_filter(enemy, contains, Value, Acc));
parse_args(["--rarity", Value | Rest], Acc) ->
    parse_args(Rest, add_filter(rarity, eq, Value, Acc));
parse_args(["--file", Value | Rest], Acc) ->
    parse_args(Rest, add_filter(file, eq, Value, Acc));
parse_args(["--include-excluded" | Rest], Acc) ->
    parse_args(Rest, Acc#{include_excluded => true});
parse_args(["--raw" | Rest], Acc) ->
    parse_args(Rest, Acc#{raw => true});
parse_args(["--exports-dir", Value | Rest], Acc) ->
    parse_args(Rest, Acc#{exports_dir => Value});
parse_args(["--knowledge-dir", Value | Rest], Acc) ->
    parse_args(Rest, Acc#{knowledge_dir => Value});
parse_args(["--limit", Value | Rest], Acc) ->
    parse_args(Rest, set_integer(limit, Value, Acc));
parse_args(["--offset", Value | Rest], Acc) ->
    parse_args(Rest, set_integer(offset, Value, Acc));
parse_args(["--output-format", Value | Rest], Acc) ->
    parse_args(Rest, set_format(Value, Acc));
parse_args(["--format", Value | Rest], Acc) ->
    parse_args(Rest, set_format(Value, Acc));
parse_args([Flag], Acc) when Flag =:= "--name"; Flag =:= "--text";
                              Flag =:= "--category"; Flag =:= "--faction";
                              Flag =:= "--enemy"; Flag =:= "--rarity";
                              Flag =:= "--file"; Flag =:= "--exports-dir";
                              Flag =:= "--knowledge-dir"; Flag =:= "--limit";
                              Flag =:= "--offset"; Flag =:= "--format";
                              Flag =:= "--output-format" ->
    add_error(Acc, Flag ++ " requires a value");
parse_args([Arg | Rest], Acc) ->
    case lists:prefix("-", Arg) of
        true -> parse_args(Rest, add_error(Acc, "unknown arg: " ++ Arg));
        false -> parse_args(Rest, add_query_token(Arg, Acc))
    end.

add_filter(Key, Op, Value, Acc) ->
    Filter = #{key => Key, op => Op, vals => split_values(Value)},
    Acc#{filters => maps:get(filters, Acc) ++ [Filter]}.

add_text(Value, Acc) -> Acc#{text => maps:get(text, Acc) ++ [Value]}.
add_query_token(Value, Acc) -> Acc#{query_tokens => maps:get(query_tokens, Acc) ++ [Value]}.

request_defaults() ->
    #{filters => [], text => [], query_tokens => [], limit => 50, offset => 0,
      output_format => table, raw => false, sort => [], exports_dir => undefined,
      knowledge_dir => undefined, include_excluded => false, errors => []}.

split_values(Value) ->
    [string:trim(Part) || Part <- string:split(wfcli_text:to_list(Value), "|", all),
                          Part =/= ""].

set_integer(Key, Value, Acc) ->
    case string:to_integer(Value) of
        {N, ""} when N >= 0 -> Acc#{Key => N};
        _ -> add_error(Acc, "invalid integer for " ++ atom_to_list(Key))
    end.

set_format("table", Acc) -> Acc#{output_format => table};
set_format("block", Acc) -> Acc#{output_format => block};
set_format("json", Acc) -> Acc#{output_format => json};
set_format(_, Acc) -> add_error(Acc, "invalid output format (use table, block, or json)").

add_error(Acc, Error) -> Acc#{errors => maps:get(errors, Acc) ++ [Error]}.

-doc "Print focused help for a knowledge command.".
-spec help(command()) -> ok.
help(Command) ->
    Extra = case Command of
        "codex" -> ["  --category NAME     Codex category\n",
                     "  --file FILE         filter by official export file\n",
                     "  --include-excluded include records hidden from the in-game Codex\n",
                     "  --exports-dir DIR   override official export location\n"];
        "enemies" -> ["  --faction NAME      enemy faction\n",
                       "  --knowledge-dir DIR override optional WFCD cache location\n"];
        "drops" -> ["  --enemy NAME        enemy name substring\n",
                     "  --rarity NAME       drop rarity\n",
                     "  --knowledge-dir DIR override optional WFCD cache location\n"]
    end,
    io:put_chars(["USAGE:\n  wfcli ", Command, " [options] [query]\n\nOPTIONS:\n",
                  "  --name TEXT        name substring\n",
                  "  --text TEXT        searchable text (repeatable)\n",
                  Extra,
                  "  --limit N          limit output (default 50) [-l]\n",
                  "  --offset N         skip results (default 0) [-o]\n",
                  "  --output-format F  table | block | json (default table) [-f]\n",
                  "\nQUERY SYNTAX:\n", wfcli_help_text:query_guide()]).
