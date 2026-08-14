%%%-------------------------------------------------------------------
%% Packaged MCP resources describing the daemon's structured surface.
%%%-------------------------------------------------------------------
-module(wfcli_mcp_resources).

-export([list/0, read/1]).

-spec list() -> [map()].
list() ->
    [resource(<<"wfcli://datasets">>, <<"Warframe datasets">>,
              <<"Dataset names, defaults, and ownership.">>, <<"application/json">>),
     resource(<<"wfcli://query-language">>, <<"wfcli query language">>,
              <<"Compact grammar and query examples.">>, <<"text/markdown">>),
     resource(<<"wfcli://schema/worldstate">>, <<"Worldstate schema">>,
              <<"Normalized worldstate columns and type-specific views.">>, <<"application/json">>),
     resource(<<"wfcli://daemon/status">>, <<"wfdaemon status">>,
              <<"Live daemon queues, caches, protocol, and uptime.">>, <<"application/json">>)].

-spec read(binary()) -> {ok, binary(), binary()} | {error, term()}.
read(<<"wfcli://datasets">>) ->
    Data = #{default => wfcli_protocol:default_datasets(),
             all => wfcli_protocol:all_datasets(),
             descriptions => dataset_descriptions()},
    {ok, <<"application/json">>, wfcli_mcp_json:encode(Data)};
read(<<"wfcli://query-language">>) ->
    {ok, <<"text/markdown">>, query_language()};
read(<<"wfcli://schema/worldstate">>) ->
    Data = #{columns => wfcli_worldstate_schema:columns_spec(),
             default_columns => wfcli_worldstate_schema:default_table_columns(),
             types => type_columns()},
    {ok, <<"application/json">>, wfcli_mcp_json:encode(Data)};
read(<<"wfcli://daemon/status">>) ->
    case wfcli_client:call(status) of
        {ok, Status} -> {ok, <<"application/json">>, wfcli_mcp_json:encode(Status)};
        {error, Reason} -> {error, Reason}
    end;
read(Uri) ->
    {error, {resource_not_found, Uri}}.

resource(Uri, Name, Description, MimeType) ->
    #{<<"uri">> => Uri, <<"name">> => Name, <<"description">> => Description,
      <<"mimeType">> => MimeType}.

dataset_descriptions() ->
    #{worldstate => <<"Live official worldstate.">>,
      mods => <<"Official PublicExport mod records.">>,
      items => <<"Official PublicExport item records.">>,
      codex => <<"Official PublicExport Codex-like records.">>,
      enemies => <<"WFCD enemy knowledge.">>,
      drops => <<"WFCD drop knowledge.">>,
      player => <<"Local companion-published player observations.">>,
      market => <<"Warframe Market item catalog plus already-cached quotes.">>,
      diagnostics => <<"Current daemon metadata-resolution failures.">>}.

type_columns() ->
    Types = [alert, fissure, sortie, invasion, void_storm, event, calendar,
             global_upgrade, syndicate_mission, daily_deal, prime_vault, baro,
             arbitration, meta],
    maps:from_list([{Type, wfcli_worldstate_schema:columns_for_type(Type)} || Type <- Types]).

query_language() ->
    <<"# wfcli query language\n\n"
      "Adjacent expressions are implicitly ANDed. Boolean operators are uppercase "
      "`NOT`, `AND`, and `OR`; precedence is NOT, AND, OR. Parentheses override it.\n\n"
      "Filters use `key=value`, `key!=value`, `key~value`, `key>=value`, `key<=value`, "
      "`key>value`, `key<value`, or `key:value`. `a|b` means either value inside one "
      "filter. `sort=field` and `sort=-field` control ordering.\n\n"
      "Datasets: `dataset=default|worldstate|mods|items|codex|enemies|drops|player|market|diagnostics|all`. "
      "Default includes public datasets; all also includes local player, market, and diagnostic data.\n\n"
      "Examples: `type=Fissure void`, `(fissure OR alert) NOT expired`, "
      "`enemy~corrupted rarity=Rare`.\n">>.
