%%%-------------------------------------------------------------------
%% Unified query across indexed knowledge sources.
%%%-------------------------------------------------------------------
-module(wfcli_query_cli).

-export([run/1, help/0]).
-ifdef(TEST).
-export([parse_args/2, known_args/0, default_opts/0]).
-endif.

-type cli_args() :: [string()].

-spec run(cli_args()) -> ok | no_return().
run(Args) ->
    Aliases = #{"-h" => "--help", "-f" => "--format"},
    Args1 = wfcli_cli_args:expand_aliases(Args, Aliases),
    Args2 = wfcli_cli_args:prompt_suggestions(Args1, known_args()),
    case wfcli_cli_args:has_help_flag(Args2) of
        true ->
            help(),
            halt(0);
        false ->
            Parsed = parse_args(Args2, default_opts()),
            case maps:get(errors, Parsed, []) of
                [] when map_get(query_tokens, Parsed) =:= [] ->
                    help(),
                    halt(1);
                [] -> run_query(Parsed);
                Errors ->
                    lists:foreach(fun(E) -> io:format("error: ~s~n", [E]) end, Errors),
                    help(),
                    halt(1)
            end
    end.

-spec help() -> ok.
help() ->
    io:put_chars(wfcli_help_text:query_command_help()).

-spec default_opts() -> map().
default_opts() ->
    #{refresh => false, ttl => 60, cache => undefined,
      event_lang => undefined, raw => false,
      output_format => table,
      exports_dir => undefined, knowledge_dir => undefined, offset => 0,
      query_tokens => [], errors => []}.

run_query(Parsed) ->
    Request = maps:remove(errors, Parsed#{source => query, cwd => filename:absname(".")}),
    case wfcli_client:one_shot(Request) of
        {ok, #{datasets := Datasets, query_tokens := Tokens}} ->
            Query = string:join(Tokens, " "),
            Success = lists:all(fun(Result) -> print_dataset(Result, Query, Parsed) end,
                                Datasets),
            case Success of true -> ok; false -> halt(1) end;
        {error, {query_errors, Errors}} -> fail(Errors);
        {error, Reason} -> fail([wfcli_client:format_error(Reason)])
    end.

print_dataset(#{dataset := Dataset, reply := {error, Reason}}, _Query, _Parsed) ->
    io:format("== ~s ==~nerror: ~ts~n", [dataset_title(Dataset),
                                          wfcli_client:format_error(Reason)]),
    false;
print_dataset(#{dataset := worldstate, reply := {ok, Result}}, Query, Parsed) ->
    io:format("== Worldstate ==~n"),
    print_worldstate_result(Result, Query, Parsed),
    true;
print_dataset(#{dataset := player, reply := {ok, Result}}, _Query, _Parsed) ->
    io:format("== Player ==~n"),
    wfcli_player_format:print_query(maps:get(query, Result), maps:get(results, Result)),
    true;
print_dataset(#{dataset := market, reply := {ok, Result}}, _Query, _Parsed) ->
    io:format("== Market ==~n"),
    wfcli_market_format:print(maps:get(query, Result), maps:get(results, Result), #{}, #{}),
    true;
print_dataset(#{dataset := Dataset, reply := {ok, Result}}, _Query, _Parsed) ->
    io:format("== ~s ==~n", [dataset_title(Dataset)]),
    Prepared = maps:get(query, Result),
    Results = maps:get(results, Result),
    case Dataset of
        mods -> wfcli_exports_format:print("mods", Prepared, Results);
        items -> wfcli_exports_format:print("items", Prepared, Results);
        _ -> wfcli_knowledge_format:print(Prepared, Results)
    end,
    true.

print_worldstate_result(Result, Query, Parsed) ->
    case print_worldstate_query_errors(maps:get(parsed_query, Result, #{})) of
        error -> ok;
        ok ->
            wfcli_worldstate_output:print_daemon_source(Result),
            Matches = maps:get(entries, Result, []),
            case Matches of
                [] -> io:format("no matches for ~ts~n", [Query]);
                _ ->
                    io:format("Matches for ~ts: ~p~n~n", [Query, length(Matches)]),
                    Extracts = maps:get(extracts, maps:get(parsed_query, Result, #{}), []),
                    case Extracts of
                        [] ->
                            Format = maps:get(output_format, Parsed, table),
                            wfcli_worldstate_output:print_entries(
                              Matches, maps:get(opts, Result, worldstate_opts(Parsed)),
                              Format, worldstate_columns(Format));
                        _ ->
                            wfcli_worldstate_output:print_query_extracts(Matches, Extracts)
                    end
            end
    end.

dataset_title(worldstate) -> "Worldstate";
dataset_title(mods) -> "Mods";
dataset_title(items) -> "Items";
dataset_title(codex) -> "Codex";
dataset_title(enemies) -> "Enemies";
dataset_title(drops) -> "Drops";
dataset_title(player) -> "Player";
dataset_title(market) -> "Market".

fail(Errors) ->
    lists:foreach(fun(Error) -> io:format("error: ~ts~n", [Error]) end, Errors),
    halt(1).

print_worldstate_query_errors(ParsedQuery) ->
    case maps:get(errors, ParsedQuery, []) of
        [] -> ok;
        Errors ->
            lists:foreach(fun(Error) -> io:format("error: ~ts~n", [Error]) end, Errors),
            error
    end.

worldstate_opts(Parsed) ->
    Raw = maps:get(raw, Parsed, false),
    Opts0 = #{refresh => maps:get(refresh, Parsed, false),
              ttl => maps:get(ttl, Parsed, 60),
              resolve_items => not Raw,
              raw => Raw,
              search_raw => Raw,
              event_lang => maps:get(event_lang, Parsed, undefined)},
    case maps:get(cache, Parsed, undefined) of
        undefined -> Opts0;
        C -> Opts0#{cache => filename:absname(C)}
    end.

worldstate_columns(table) ->
    wfcli_worldstate_schema:default_table_columns();
worldstate_columns(_Format) ->
    [].

parse_args([], Acc) -> Acc;
parse_args(["--" | Rest], Acc) ->
    Tokens = maps:get(query_tokens, Acc, []),
    Acc#{query_tokens := Tokens ++ Rest};
parse_args(["--refresh" | Rest], Acc) ->
    parse_args(Rest, Acc#{refresh := true});
parse_args(["--ttl"], Acc) ->
    parse_args([], add_error(Acc, "--ttl requires a value"));
parse_args(["--ttl", Val | Rest], Acc) ->
    parse_args(Rest, set_ttl(Val, Acc));
parse_args(["--cache"], Acc) ->
    parse_args([], add_error(Acc, "--cache requires a value"));
parse_args(["--cache", Val | Rest], Acc) ->
    parse_args(Rest, Acc#{cache := Val});
parse_args(["--lang"], Acc) ->
    parse_args([], add_error(Acc, "--lang requires a code"));
parse_args(["--lang", Val | Rest], Acc) ->
    parse_args(Rest, Acc#{event_lang := Val});
parse_args(["--exports-dir"], Acc) ->
    parse_args([], add_error(Acc, "--exports-dir requires a value"));
parse_args(["--exports-dir", Val | Rest], Acc) ->
    parse_args(Rest, Acc#{exports_dir := Val});
parse_args(["--knowledge-dir"], Acc) ->
    parse_args([], add_error(Acc, "--knowledge-dir requires a value"));
parse_args(["--knowledge-dir", Val | Rest], Acc) ->
    parse_args(Rest, Acc#{knowledge_dir := Val});
parse_args(["--limit"], Acc) ->
    parse_args([], add_error(Acc, "--limit requires a value"));
parse_args(["--limit", Val | Rest], Acc) ->
    parse_args(Rest, set_int(limit, Val, Acc));
parse_args(["--offset"], Acc) ->
    parse_args([], add_error(Acc, "--offset requires a value"));
parse_args(["--offset", Val | Rest], Acc) ->
    parse_args(Rest, set_int(offset, Val, Acc));
parse_args(["--output-format"], Acc) ->
    parse_args([], add_error(Acc, "--output-format requires a value"));
parse_args(["--format"], Acc) ->
    parse_args([], add_error(Acc, "--format requires a value"));
parse_args(["--output-format", Val | Rest], Acc) ->
    parse_args(Rest, set_output_format(Val, Acc));
parse_args(["--format", Val | Rest], Acc) ->
    parse_args(Rest, set_output_format(Val, Acc));
parse_args(["--raw" | Rest], Acc) ->
    parse_args(Rest, Acc#{raw := true});
parse_args(["--search"], Acc) ->
    parse_args([], add_error(Acc, "--search requires a query"));
parse_args(["--search", Val | Rest], Acc) ->
    Tokens = maps:get(query_tokens, Acc, []),
    parse_args(Rest, Acc#{query_tokens := Tokens ++ string:tokens(Val, " ")});
parse_args([Arg | Rest], Acc) ->
    case is_unknown_flag(Arg) of
        true ->
            Suggest = wfcli_cli_suggest:suggest(Arg, known_args()),
            parse_args(Rest, add_error(Acc, io_lib:format("unknown arg: ~s~s", [Arg, Suggest])));
        false ->
            Tokens = maps:get(query_tokens, Acc, []),
            parse_args(Rest, Acc#{query_tokens := Tokens ++ [Arg]})
    end.

is_unknown_flag([$- | _]) -> true;
is_unknown_flag(_) -> false.

known_args() ->
    [
        "--refresh", "--ttl", "--cache", "--lang", "--raw", "--output-format", "--format",
        "--exports-dir", "--knowledge-dir", "--limit", "--offset", "--search", "--help", "-h",
        "--no-suggest-prompt"
    ].

set_int(Key, Val, Acc) ->
    case string:to_integer(Val) of
        {Int, ""} when Int >= 0 -> Acc#{Key => Int};
        _ -> add_error(Acc, io_lib:format("invalid ~s", [to_list(Key)]))
    end.

set_ttl(Val, Acc) ->
    case string:to_integer(Val) of
        {Int, _} when Int >= 60 -> Acc#{ttl := Int};
        {Int, _} when Int >= 0 -> add_error(Acc, "--ttl must be >= 60");
        _ -> add_error(Acc, "invalid --ttl")
    end.

set_output_format(Val0, Acc) ->
    Val = string:lowercase(to_list(Val0)),
    case Val of
        "table" -> Acc#{output_format := table};
        "block" -> Acc#{output_format := block};
        _ -> add_error(Acc, "invalid --output-format (use block or table)")
    end.

add_error(Acc, Msg) ->
    Acc#{errors := [lists:flatten(Msg) | maps:get(errors, Acc, [])]}.

to_list(Key) when is_atom(Key) -> atom_to_list(Key);
to_list(Val) -> wfcli_text:to_list(Val).
