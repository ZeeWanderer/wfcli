%%%-------------------------------------------------------------------
%% Daemon diagnostics command.
%%%-------------------------------------------------------------------
-module(wfcli_diagnostics_cli).

-export([run/1, help/0]).

-doc "Show current metadata-resolution failures.".
-spec run([string()]) -> ok | no_return().
run(Args0) ->
    Args = wfcli_cli_args:expand_aliases(Args0, #{"-h" => "--help"}),
    case Args of
        ["--help" | _] -> help();
        ["unresolved"] -> show(table);
        ["unresolved", "--json"] -> show(json);
        ["unresolved", "json"] -> show(json);
        [] -> help();
        _ -> fail("usage: wfcli diagnostics unresolved [--json]")
    end.

-doc "Print diagnostics command help.".
-spec help() -> ok.
help() ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli diagnostics unresolved [--json]\n"
      "\n"
      "COMMANDS:\n"
      "  unresolved  show current friendly-name and asset resolution failures\n").

show(Format) ->
    case wfcli_client:call(resolution_issues) of
        {ok, Issues} when is_list(Issues) -> wfcli_diagnostics_format:print(Issues, Format);
        {ok, {error, Reason}} -> fail(wfcli_client:format_error(Reason));
        {error, Reason} -> fail(wfcli_client:format_error(Reason))
    end.

fail(Message) ->
    io:format("error: ~ts~n", [Message]),
    halt(1).
