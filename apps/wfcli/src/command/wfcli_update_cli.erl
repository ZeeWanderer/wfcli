%%%-------------------------------------------------------------------
%% Centralized update command for cached knowledge base data.
%%%-------------------------------------------------------------------
-module(wfcli_update_cli).

-export([run/1, help/0, known_args/0, refresh_metadata/1]).
-ifdef(TEST).
-export([default_opts/0, parse_args/2, has_update_flags/1]).
-endif.

-type cli_args() :: [string()].

-spec run(cli_args()) -> ok | no_return().
run(Args) ->
    Aliases = #{"-h" => "--help"},
    Args1 = wfcli_cli_args:expand_aliases(Args, Aliases),
    Args2 = wfcli_cli_args:prompt_suggestions(Args1, known_args()),
    case wfcli_cli_args:has_help_flag(Args2) of
        true ->
            help(),
            halt(0);
        false ->
            Parsed = parse_args(Args2, default_opts()),
            case maps:get(errors, Parsed, []) of
                [] ->
                    case run_updates(Parsed) of
                        ok -> ok;
                        {error, _Reason} -> halt(1)
                    end;
                Errors ->
                    lists:foreach(fun(E) -> io:format("error: ~s~n", [E]) end, Errors),
                    help(),
                    halt(1)
            end
    end.

-spec help() -> ok.
help() ->
    io:put_chars(wfcli_help_text:update_help()).

-spec default_opts() -> map().
default_opts() ->
    #{update_all => false, update_default => false,
      update_nodes => false, update_languages => false, update_manifest => false,
      update_exports => false, update_recipes => false, update_upgrades => false,
      update_weapons => false, update_warframes => false, update_resources => false,
      update_wfcd => false,
      worldstate => false, trader => false,
      cache => undefined, trader_cache => undefined,
      errors => []}.

parse_args([], Acc) -> Acc;
parse_args(["--all" | Rest], Acc) -> parse_args(Rest, Acc#{update_all := true});
parse_args(["--default" | Rest], Acc) -> parse_args(Rest, Acc#{update_default := true});
parse_args(["--nodes" | Rest], Acc) -> parse_args(Rest, Acc#{update_nodes := true});
parse_args(["--languages" | Rest], Acc) -> parse_args(Rest, Acc#{update_languages := true});
parse_args(["--manifest" | Rest], Acc) -> parse_args(Rest, Acc#{update_manifest := true});
parse_args(["--exports" | Rest], Acc) -> parse_args(Rest, Acc#{update_exports := true});
parse_args(["--recipes" | Rest], Acc) -> parse_args(Rest, Acc#{update_recipes := true});
parse_args(["--upgrades" | Rest], Acc) -> parse_args(Rest, Acc#{update_upgrades := true});
parse_args(["--weapons" | Rest], Acc) -> parse_args(Rest, Acc#{update_weapons := true});
parse_args(["--warframes" | Rest], Acc) -> parse_args(Rest, Acc#{update_warframes := true});
parse_args(["--resources" | Rest], Acc) -> parse_args(Rest, Acc#{update_resources := true});
parse_args(["--wfcd" | Rest], Acc) -> parse_args(Rest, Acc#{update_wfcd := true});
parse_args(["--worldstate" | Rest], Acc) -> parse_args(Rest, Acc#{worldstate := true});
parse_args(["--trader" | Rest], Acc) -> parse_args(Rest, Acc#{trader := true});
parse_args(["--cache"], Acc) -> parse_args([], add_error(Acc, "--cache requires a value"));
parse_args(["--cache", Val | Rest], Acc) -> parse_args(Rest, Acc#{cache := Val});
parse_args(["--trader-cache"], Acc) -> parse_args([], add_error(Acc, "--trader-cache requires a value"));
parse_args(["--trader-cache", Val | Rest], Acc) -> parse_args(Rest, Acc#{trader_cache := Val});
parse_args([Arg | Rest], Acc) ->
    case is_unknown_flag(Arg) of
        true ->
            Suggest = wfcli_cli_suggest:suggest(Arg, known_args()),
            parse_args(Rest, add_error(Acc, io_lib:format("unknown arg: ~s~s", [Arg, Suggest])));
        false ->
            parse_args(Rest, Acc)
    end.

is_unknown_flag([$- | _]) -> true;
is_unknown_flag(_) -> false.

-doc "Return argv tokens accepted by parser suggestions and shell completion.".
-spec known_args() -> [string()].
known_args() ->
    [
        "--all", "--default", "--nodes", "--languages", "--manifest", "--exports", "--recipes",
        "--upgrades", "--weapons", "--warframes", "--resources", "--wfcd",
        "--worldstate", "--trader", "--cache", "--trader-cache", "--help", "-h",
        "--no-suggest-prompt"
    ].

run_updates(Parsed) ->
    Results = [refresh_metadata(metadata_selections(Parsed)),
               maybe_refresh_worldstate(Parsed),
               maybe_refresh_trader(Parsed)],
    case lists:any(fun(Result) -> element(1, Result) =:= error end,
                   [Result || Result <- Results, Result =/= ok]) of
        true -> {error, update_failed};
        false -> ok
    end.

has_update_flags(Parsed) ->
    lists:any(fun(K) -> maps:get(K, Parsed, false) end,
              [update_all, update_default, update_nodes, update_languages, update_manifest, update_exports,
               update_recipes, update_upgrades, update_weapons, update_warframes,
               update_resources, update_wfcd, worldstate, trader]).

metadata_selections(Parsed) ->
    Any = has_update_flags(Parsed),
    case maps:get(update_all, Parsed, false) of
        true -> [all];
        false ->
            Base = case maps:get(update_default, Parsed, false) orelse not Any of
                true -> [default];
                false -> []
            end,
            Base ++ selected_metadata(Parsed)
    end.

selected_metadata(Parsed) ->
    Pairs = [{update_nodes, nodes}, {update_languages, languages},
             {update_manifest, manifest}, {update_exports, exports},
             {update_recipes, recipes}, {update_upgrades, upgrades},
             {update_weapons, weapons}, {update_warframes, warframes},
             {update_resources, resources}, {update_wfcd, wfcd}],
    [Source || {Flag, Source} <- Pairs, maps:get(Flag, Parsed, false)].

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
            io:format("metadata update failed: ~ts~n", [wfcli_client:format_error(Reason)]),
            {error, Reason}
    end.

print_source_result(#{source := Source, result := ok}) ->
    io:format("updated ~s~n", [source_label(Source)]);
print_source_result(#{source := Source, result := {error, Reason}}) ->
    io:format("failed: ~s -> ~p~n", [source_label(Source), Reason]).

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
                    io:format("failed: refresh worldstate cache -> ~p~n", [Reason]),
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
                    io:format("failed: refresh trader inventory cache -> ~p~n", [Reason]),
                    {error, Reason}
            end;
        false -> ok
    end.

refresh_opts(undefined) -> #{refresh => true};
refresh_opts(Cache) -> #{refresh => true, cache => filename:absname(Cache)}.

add_error(Acc, Msg) ->
    Acc#{errors := [lists:flatten(Msg) | maps:get(errors, Acc, [])]}.
