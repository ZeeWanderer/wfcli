-module(wfcli_diagnostics_cli).

-export([command/0]).

command() ->
    #{help => "inspect daemon resolution failures",
      commands => #{"unresolved" => #{
          help => "show current identity, metadata and asset failures",
          handler => fun(Args) -> show(maps:get(output_format, Args, table)) end,
          arguments => [(wfcli_cli_args:flag(output_format, "json", "print JSON"))#{
              action => {store, json}}]}}}.

show(Format) ->
    case wfcli_client:call(resolution_issues) of
        {ok, Issues} when is_list(Issues) -> wfcli_diagnostics_format:print(Issues, Format);
        {ok, {error, Reason}} -> fail(wfcli_client:format_error(Reason));
        {error, Reason} -> fail(wfcli_client:format_error(Reason))
    end.

fail(Message) ->
    io:format(standard_error, "error: ~ts~n", [Message]),
    halt(1).
