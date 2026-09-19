-module(wfcli_mcp_cli).

-export([command/0, main/1]).

command() ->
    #{help => "serve MCP over standard input and output", handler => {?MODULE, main},
      notes => "\nNewline-delimited JSON-RPC. Diagnostics use standard error.\n"
               "Closing the connection cancels its outstanding daemon requests.\n"}.

main(_Args) ->
    ok = io:setopts(standard_io, [binary, {encoding, unicode}]),
    ok = io:setopts(standard_error, [{encoding, unicode}]),
    case wfcli_mcp_server:run() of
        ok -> ok;
        {error, Reason} ->
            io:format(standard_error, "wfcli mcp failed: ~p~n", [Reason]),
            halt(1)
    end.
