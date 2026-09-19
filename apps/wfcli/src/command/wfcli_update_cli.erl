-module(wfcli_update_cli).

-export([command/0, run/1, metadata_selections/1]).
-import(wfcli_cli_args, [option/4, flag/3]).

command() ->
    Sources = [default, all, nodes, languages, manifest, exports, recipes,
               upgrades, weapons, warframes, resources, wfcd],
    #{help => "update cached knowledge base data", handler => {?MODULE, run},
      defaults => #{selections => []},
      arguments => [(flag(selections, atom_to_list(Source),
                          "refresh " ++ atom_to_list(Source)))#{action => {append, Source}}
                    || Source <- Sources] ++
                   [flag(worldstate, "worldstate", "refresh worldstate"),
                    flag(trader, "trader", "refresh trader inventory"),
                    option(cache, "cache", string, "worldstate cache file"),
                    option(trader_cache, "trader-cache", string, "trader cache file")]}.

run(Parsed) ->
    Results = [refresh_metadata(metadata_selections(Parsed)),
               maybe_refresh_worldstate(Parsed), maybe_refresh_trader(Parsed)],
    case lists:all(fun(Result) -> Result =:= ok end, Results) of
        true -> ok;
        false -> halt(1)
    end.

metadata_selections(#{selections := []} = Args) ->
    case maps:get(worldstate, Args, false) orelse maps:get(trader, Args, false) of
        true -> [];
        false -> [default]
    end;
metadata_selections(#{selections := Sources}) ->
    case lists:member(all, Sources) of true -> [all]; false -> lists:usort(Sources) end.

-doc "Ask the daemon to refresh selected managed metadata sources.".
-spec refresh_metadata([atom()]) -> ok | {error, term()}.
refresh_metadata([]) -> ok;
refresh_metadata(Selections) ->
    Request = #{source => metadata, action => refresh, selections => Selections},
    case wfcli_client:one_shot(Request) of
        {ok, #{results := Results, success := Success}} ->
            lists:foreach(fun print_source_result/1, Results),
            case Success of true -> ok; false -> {error, metadata_update_failed} end;
        {error, Reason} ->
            io:format(standard_error, "metadata update failed: ~ts~n", [wfcli_client:format_error(Reason)]),
            {error, Reason}
    end.

print_source_result(#{source := Source, result := ok}) ->
    io:format("updated ~s~n", [source_label(Source)]);
print_source_result(#{source := Source, result := {error, Reason}}) ->
    io:format(standard_error, "failed: ~s -> ~p~n", [source_label(Source), Reason]).

source_label(nodes) -> "solNodes.json";
source_label(languages) -> "languages.json";
source_label(manifest) -> "ExportManifest.json";
source_label(exports) -> "all PublicExport metadata";
source_label(recipes) -> "ExportRecipes_en.json";
source_label(upgrades) -> "ExportUpgrades_en.json";
source_label(weapons) -> "ExportWeapons_en.json";
source_label(warframes) -> "ExportWarframes_en.json";
source_label(resources) -> "ExportResources_en.json";
source_label(wfcd) -> "WFCD enemy knowledge";
source_label(star_chart) -> "Star Chart mastery metadata";
source_label(Source) -> atom_to_list(Source).

maybe_refresh_worldstate(Parsed) ->
    case maps:get(worldstate, Parsed, false) of
        true ->
            Opts = refresh_opts(maps:get(cache, Parsed, undefined)),
            Result = wfcli_client:one_shot(#{source => worldstate, opts => Opts,
                                                    query => undefined, type_filter => undefined,
                                                    day_filter => undefined, mode => list,
                                                    inventory => false}),
            case Result of
                {ok, _} -> io:format("refreshed worldstate cache~n", []);
                {ok, _Ws, _Source} -> io:format("refreshed worldstate cache~n", []);
                {error, Reason} ->
                    io:format(standard_error, "failed: refresh worldstate cache -> ~p~n", [Reason]),
                    {error, Reason}
            end;
        false -> ok
    end.

maybe_refresh_trader(Parsed) ->
    case maps:get(trader, Parsed, false) of
        true ->
            Opts = refresh_opts(maps:get(trader_cache, Parsed, undefined)),
            Result = wfcli_client:one_shot(#{source => trader, opts => Opts}),
            case Result of
                {ok, _} -> io:format("refreshed trader inventory cache~n", []);
                {ok, _Entries, _Source} -> io:format("refreshed trader inventory cache~n", []);
                {error, Reason} ->
                    io:format(standard_error, "failed: refresh trader inventory cache -> ~p~n", [Reason]),
                    {error, Reason}
            end;
        false -> ok
    end.

refresh_opts(undefined) -> #{refresh => true};
refresh_opts(Cache) -> #{refresh => true, cache => filename:absname(Cache)}.
