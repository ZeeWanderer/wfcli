%%%-------------------------------------------------------------------
%% Dedicated player dataset command; filtering delegates to unified query.
%%%-------------------------------------------------------------------
-module(wfcli_player_cli).

-export([run/1, help/0]).

-doc "Show player snapshot or run existing query DSL against dataset=player.".
-spec run([string()]) -> ok | no_return().
run(Args) ->
    Aliases = #{"-h" => "--help"},
    Args1 = wfcli_cli_args:expand_aliases(Args, Aliases),
    case Args1 of
        ["--help" | _] -> help(), halt(0);
        [] -> show_snapshot();
        _ -> wfcli_query_cli:run(["dataset=player" | Args1])
    end.

-doc "Print player command help.".
-spec help() -> ok.
help() -> io:put_chars(wfcli_help_text:player_help()).

show_snapshot() ->
    case wfcli_client:call(player_snapshot) of
        {ok, Snapshot} when is_map(Snapshot) -> wfcli_player_format:print_snapshot(Snapshot);
        {error, Reason} ->
            io:format("error: player dataset failed: ~ts~n", [wfcli_client:format_error(Reason)]),
            halt(1)
    end.
