%%%-------------------------------------------------------------------
%% Dedicated Warframe Market quote command.
%%%-------------------------------------------------------------------
-module(wfcli_market_cli).

-export([run/1, help/0]).
-ifdef(TEST).
-export([parse_args/2, default_opts/0]).
-endif.

-doc "Resolve a query against market catalog, then fetch bounded top-order quotes.".
-spec run([string()]) -> ok | no_return().
run(Args) ->
    Aliases = #{"-h" => "--help", "-f" => "--format"},
    Args1 = wfcli_cli_args:expand_aliases(Args, Aliases),
    case wfcli_cli_args:has_help_flag(Args1) of
        true -> help(), halt(0);
        false ->
            Parsed = parse_args(Args1, default_opts()),
            case {maps:get(errors, Parsed), maps:get(query_tokens, Parsed)} of
                {[], []} -> help(), halt(1);
                {[], _} -> run_quote(Parsed);
                {Errors, _} -> fail(Errors)
            end
    end.

-doc "Print market command help.".
-spec help() -> ok.
help() -> io:put_chars(wfcli_help_text:market_help()).

default_opts() ->
    #{refresh => false, ttl => 60, output_format => table,
      query_tokens => [], errors => []}.

run_quote(Parsed) ->
    Request0 = maps:remove(errors, Parsed#{source => market, action => quote_query}),
    case wfcli_client:one_shot(Request0) of
        {ok, Result} ->
            wfcli_market_format:print(maps:get(query, Result), maps:get(results, Result),
                                      maps:get(context, Result, #{}),
                                      maps:get(quote_errors, Result, #{}));
        {error, {query_errors, Errors}} -> fail(Errors);
        {error, {market_query_too_broad, Count, Max}} ->
            fail([io_lib:format("market query matched ~p items; refine it or pass --limit N (automatic quote cap: ~p)",
                                [Count, Max])]);
        {error, {market_quote_limit_exceeded, Count, Max}} ->
            fail([io_lib:format("market quote request selected ~p items; maximum is ~p", [Count, Max])]);
        {error, Reason} -> fail([wfcli_client:format_error(Reason)])
    end.

parse_args([], Acc) -> Acc;
parse_args(["--" | Rest], Acc) -> add_tokens(Rest, Acc);
parse_args(["--refresh" | Rest], Acc) -> parse_args(Rest, Acc#{refresh => true});
parse_args(["--ttl"], Acc) -> add_error(Acc, "--ttl requires a value");
parse_args(["--ttl", Value | Rest], Acc) -> parse_args(Rest, set_ttl(Value, Acc));
parse_args(["--limit"], Acc) -> add_error(Acc, "--limit requires a value");
parse_args(["--limit", Value | Rest], Acc) -> parse_args(Rest, set_limit(Value, Acc));
parse_args(["--output-format"], Acc) -> add_error(Acc, "--output-format requires a value");
parse_args(["--format"], Acc) -> add_error(Acc, "--format requires a value");
parse_args(["--output-format", Value | Rest], Acc) ->
    parse_args(Rest, set_format(Value, Acc));
parse_args(["--format", Value | Rest], Acc) -> parse_args(Rest, set_format(Value, Acc));
parse_args(["--search"], Acc) -> add_error(Acc, "--search requires a query");
parse_args(["--search", Value | Rest], Acc) ->
    parse_args(Rest, add_tokens(string:lexemes(Value, " \t"), Acc));
parse_args([[ $- | _ ] = Flag | Rest], Acc) ->
    parse_args(Rest, add_error(Acc, io_lib:format("unknown arg: ~s", [Flag])));
parse_args([Token | Rest], Acc) -> parse_args(Rest, add_tokens([Token], Acc)).

add_tokens(Tokens, Acc) ->
    Acc#{query_tokens => maps:get(query_tokens, Acc) ++ Tokens}.

set_ttl(Value, Acc) ->
    case string:to_integer(Value) of
        {Seconds, ""} when Seconds >= 60 -> Acc#{ttl => Seconds};
        _ -> add_error(Acc, "--ttl must be an integer >= 60")
    end.

set_limit(Value, Acc) ->
    case string:to_integer(Value) of
        {Limit, ""} when Limit >= 0, Limit =< 100 -> Acc#{limit => Limit};
        _ -> add_error(Acc, "--limit must be between 0 and 100")
    end.

set_format(Value0, Acc) ->
    case string:lowercase(Value0) of
        "table" -> Acc#{output_format => table};
        "block" -> Acc#{output_format => block};
        _ -> add_error(Acc, "--output-format must be table or block")
    end.

add_error(Acc, Error) ->
    Acc#{errors => maps:get(errors, Acc) ++ [lists:flatten(Error)]}.

fail(Errors) ->
    lists:foreach(fun(Error) -> io:format("error: ~ts~n", [Error]) end, Errors),
    halt(1).
