-module(wfcli_test_cli).

-export([parse/1, catalog/2, worldstate/1, options/1]).

parse(Args) ->
    {ok, Parsed, _Path, _Command} = wfcli_cli_args:parse(Args),
    Parsed.

catalog(Command, Args) -> wfcli_catalog_cli:request(parse([Command | Args])).

worldstate(Args) -> wfcli_worldstate_cli:prepare(parse(Args)).

options(Path) ->
    wfcli_cli_args:options(wfcli_cli_args:node(Path, wfcli_cli:command())).
