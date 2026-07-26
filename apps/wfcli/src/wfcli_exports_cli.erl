%%%-------------------------------------------------------------------
%% CLI argument and help adapter for official export catalog queries.
%%%-------------------------------------------------------------------
-module(wfcli_exports_cli).

-export([run/1, run_command/2, command_names/0, help/1]).

-ifdef(TEST).
-export([parse_request/2]).
-endif.

-type command() :: string().

run(Args0) ->
    Args = expand_args(Args0),
    case help_request(Args) of
        {help, Topic} -> help(Topic), halt(0);
        none ->
            case Args of
                ["mods" | Rest] -> run_query("mods", Rest);
                ["items" | Rest] -> run_query("items", Rest);
                _ -> help([]), halt(1)
            end
    end.

-spec run_command(command(), [string()]) -> ok | no_return().
run_command(Command, Args0) ->
    Args = expand_args(Args0),
    case wfcli_cli_args:has_help_flag(Args) of
        true -> help([Command]), halt(0);
        false -> run_query(Command, Args)
    end.

run_query(Command, Args) ->
    case parse_request(Command, Args) of
        {ok, Query} ->
            case wfcli_catalog_client:query(Command, Query) of
                {ok, Prepared, Results} -> wfcli_exports_format:print(Command, Prepared, Results);
                {error, Errors} -> fail(Errors)
            end;
        {error, Errors} -> fail_with_help(Errors)
    end.

fail(Errors) ->
    lists:foreach(fun(Error) -> io:format("error: ~s~n", [Error]) end, Errors),
    halt(1).

fail_with_help(Errors) ->
    lists:foreach(fun(Error) -> io:format("error: ~s~n", [Error]) end, Errors),
    help([]),
    halt(1).

expand_args(Args) ->
    Aliases = #{"-h" => "--help", "-f" => "--format", "-l" => "--limit", "-o" => "--offset"},
    Expanded = wfcli_cli_args:expand_aliases(Args, Aliases),
    wfcli_cli_args:prompt_suggestions(Expanded, known_args()).

-doc "Return focused official-export command names.".
-spec command_names() -> [command()].
command_names() -> ["mods", "items"].

-doc "Convert focused-command arguments into an uncompiled typed request.".
-spec parse_request(command(), [string()]) -> {ok, map()} | {error, [iodata()]}.
parse_request("mods", Args) ->
    Parsed = parse_mod_args(Args, request_defaults("mods")),
    parsed_request(Parsed);
parse_request("items", Args) ->
    Parsed = parse_item_args(Args, request_defaults("items")),
    parsed_request(Parsed);
parse_request(Command, _Args) ->
    {error, [io_lib:format("unknown export command: ~s", [Command])]}.

parsed_request(Parsed) ->
    case maps:get(errors, Parsed) of
        [] -> {ok, Parsed};
        Errors -> {error, Errors}
    end.

parse_mod_args([], Acc) -> Acc;
parse_mod_args(["--type", Value | Rest], Acc) ->
    parse_mod_args(Rest, add_filter(type, eq, Value, Acc));
parse_mod_args(["--polarity", Value | Rest], Acc) ->
    parse_mod_args(Rest, add_filter(polarity, eq, Value, Acc));
parse_mod_args(["--rarity", Value | Rest], Acc) ->
    parse_mod_args(Rest, add_filter(rarity, eq, Value, Acc));
parse_mod_args(["--compat", Value | Rest], Acc) ->
    parse_mod_args(Rest, add_filter(compat, contains, Value, Acc));
parse_mod_args(["--name", Value | Rest], Acc) ->
    parse_mod_args(Rest, add_filter(name, contains, Value, Acc));
parse_mod_args(["--text", Value | Rest], Acc) ->
    parse_mod_args(Rest, add_list(text, Value, Acc));
parse_mod_args(["--limit", Value | Rest], Acc) ->
    parse_mod_args(Rest, set_integer(limit, Value, Acc));
parse_mod_args(["--offset", Value | Rest], Acc) ->
    parse_mod_args(Rest, set_integer(offset, Value, Acc));
parse_mod_args(["--output-format", Value | Rest], Acc) ->
    parse_mod_args(Rest, set_output_format(Value, Acc));
parse_mod_args(["--format", Value | Rest], Acc) ->
    parse_mod_args(Rest, set_output_format(Value, Acc));
parse_mod_args(["--raw" | Rest], Acc) ->
    parse_mod_args(Rest, Acc#{raw => true});
parse_mod_args(["--exports-dir", Value | Rest], Acc) ->
    parse_mod_args(Rest, Acc#{exports_dir => Value});
parse_mod_args(["--help" | _], Acc) -> Acc#{errors => ["help requested"]};
parse_mod_args([Arg | Rest], Acc) ->
    parse_arg(Arg, Rest, Acc, fun parse_mod_args/2).

parse_item_args([], Acc) -> Acc;
parse_item_args(["--file", Value | Rest], Acc) ->
    parse_item_args(Rest, add_file_filter(eq, Value, Acc));
parse_item_args(["--name", Value | Rest], Acc) ->
    parse_item_args(Rest, add_filter(name, contains, Value, Acc));
parse_item_args(["--text", Value | Rest], Acc) ->
    parse_item_args(Rest, add_list(text, Value, Acc));
parse_item_args(["--limit", Value | Rest], Acc) ->
    parse_item_args(Rest, set_integer(limit, Value, Acc));
parse_item_args(["--offset", Value | Rest], Acc) ->
    parse_item_args(Rest, set_integer(offset, Value, Acc));
parse_item_args(["--output-format", Value | Rest], Acc) ->
    parse_item_args(Rest, set_output_format(Value, Acc));
parse_item_args(["--format", Value | Rest], Acc) ->
    parse_item_args(Rest, set_output_format(Value, Acc));
parse_item_args(["--raw" | Rest], Acc) ->
    parse_item_args(Rest, Acc#{raw => true});
parse_item_args(["--exports-dir", Value | Rest], Acc) ->
    parse_item_args(Rest, Acc#{exports_dir => Value});
parse_item_args(["--help" | _], Acc) -> Acc#{errors => ["help requested"]};
parse_item_args([Arg | Rest], Acc) ->
    parse_arg(Arg, Rest, Acc, fun parse_item_args/2).

parse_arg(Arg, Rest, Acc, Continue) ->
    case lists:prefix("-", wfcli_text:to_list(Arg)) of
        true -> Continue(Rest, add_error(Acc, unknown_arg(Arg)));
        false -> Continue(Rest, add_list(query_tokens, Arg, Acc))
    end.

add_filter(Key, Op, Value, Acc) ->
    Filter = #{key => Key, op => Op, vals => split_values(Value)},
    Acc#{filters => maps:get(filters, Acc) ++ [Filter]}.

add_file_filter(Op, Value, Acc) ->
    Acc1 = add_filter(file, Op, Value, Acc),
    lists:foldl(fun(File, A) -> add_list(files, File, A) end,
                Acc1, split_values(Value)).

request_defaults("mods") ->
    #{filters => [], text => [], query_tokens => [], limit => 50, offset => 0,
      output_format => table, raw => false, exports_dir => undefined, sort => [], errors => []};
request_defaults("items") ->
    (request_defaults("mods"))#{files => []}.

split_values(Value) ->
    [string:trim(Part) || Part <- string:split(wfcli_text:to_list(Value), "|", all),
                          Part =/= ""].

add_list(Key, Value, Acc) -> Acc#{Key => maps:get(Key, Acc, []) ++ [Value]}.

set_integer(Key, Value, Acc) ->
    case string:to_integer(Value) of
        {N, ""} when N >= 0 -> Acc#{Key => N};
        _ -> add_error(Acc, lists:flatten(io_lib:format("invalid integer for ~p", [Key])))
    end.

set_output_format("block", Acc) -> Acc#{output_format => block};
set_output_format("table", Acc) -> Acc#{output_format => table};
set_output_format("json", Acc) -> Acc#{output_format => json};
set_output_format(_, Acc) -> add_error(Acc, "invalid output format").

add_error(Acc, Error) -> Acc#{errors => maps:get(errors, Acc, []) ++ [Error]}.

unknown_arg(Arg) ->
    Suggest = wfcli_cli_suggest:suggest(Arg, known_args()),
    lists:flatten(io_lib:format("unknown arg: ~s~s", [Arg, Suggest])).

known_args() ->
    ["--type", "--polarity", "--rarity", "--compat", "--name", "--text", "--limit",
     "--offset", "--output-format", "--format", "--raw", "--exports-dir", "--file",
     "--help", "-h", "-f", "-l", "-o", "--no-suggest-prompt", "mods", "items",
     "help", "query"].

help_request(["help" | Rest]) -> {help, Rest};
help_request(Args) ->
    case wfcli_cli_args:has_help_flag(Args) of
        true -> {help, help_topic_from_args(wfcli_cli_args:strip_help_flags(Args))};
        false -> none
    end.

help_topic_from_args([First | _]) -> [First];
help_topic_from_args([]) -> [].

-spec help([string()]) -> ok.
help([]) -> io:put_chars(wfcli_help_text:exports_summary());
help(["query"]) ->
    io:put_chars(["QUERY SYNTAX:\n", wfcli_help_text:query_guide(), "\nEXAMPLES:\n",
                  wfcli_help_text:mods_examples(), wfcli_help_text:items_examples()]);
help(["mods"]) -> help_mods();
help(["items"]) -> help_items();
help(_) -> help([]).

help_mods() ->
    io:put_chars(["USAGE:\n  wfcli mods [options] [query]\n\nOPTIONS:\n",
                  "  --type TYPE        mod type (e.g., WARFRAME, PRIMARY)\n",
                  "  --polarity POL     polarity symbol (V/D/-/=...) or AP_*\n",
                  "  --rarity RARITY    rarity label\n",
                  "  --compat NAME      compatibility name substring\n",
                  "  --name TEXT        name substring\n",
                  "  --text TEXT        text substring (repeatable)\n",
                  "  --limit N          limit output (default 50) [-l]\n",
                  "  --offset N         skip N results (default 0) [-o]\n",
                  "  --output-format F  block | table | json (default: table) [-f]\n",
                  "  --raw              include raw identifiers in output\n",
                  "  --exports-dir DIR  override export file location\n\nQUERY SYNTAX:\n",
                  wfcli_help_text:query_guide(), "\nEXAMPLES:\n", wfcli_help_text:mods_examples()]).

help_items() ->
    io:put_chars(["USAGE:\n  wfcli items [options] [query]\n\nOPTIONS:\n",
                  "  --file FILE        load and filter one export file (repeatable)\n",
                  "  --name TEXT        name substring\n",
                  "  --text TEXT        text substring (repeatable)\n",
                  "  --limit N          limit output (default 50) [-l]\n",
                  "  --offset N         skip N results (default 0) [-o]\n",
                  "  --output-format F  block | table | json (default: table) [-f]\n",
                  "  --raw              include raw identifiers in output\n",
                  "  --exports-dir DIR  override export file location\n\nQUERY SYNTAX:\n",
                  wfcli_help_text:query_guide(), "\nEXAMPLES:\n", wfcli_help_text:items_examples()]).
