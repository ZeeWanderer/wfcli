%%%-------------------------------------------------------------------
%% stdio entry point for the wfdaemon MCP adapter.
%%%-------------------------------------------------------------------
-module(wfcli_mcp_cli).

-export([main/1]).

-spec main([string()]) -> ok | no_return().
main(["--help"]) ->
    wfcli_help:run(["mcp"]);
main(["-h"]) ->
    wfcli_help:run(["mcp"]);
main([]) ->
    ok = io:setopts(standard_io, [binary, {encoding, unicode}]),
    ok = io:setopts(standard_error, [{encoding, unicode}]),
    case wfcli_mcp_server:run() of
        ok -> ok;
        {error, Reason} ->
            io:format(standard_error, "wfcli mcp failed: ~p~n", [Reason]),
            halt(1)
    end;
main(_Args) ->
    io:format(standard_error, "wfcli mcp accepts no arguments~n", []),
    halt(2).
