%%%-------------------------------------------------------------------
%% CLI front-end for worldstate fetch/cache/search.
%%%-------------------------------------------------------------------
-module(wfcli_worldstate_cli).

-export([run/1, run_command/2, help/1, command_names/0, command_help_names/0,
         command_description/1]).
-ifdef(TEST).
-export([parse_args/2, default_acc/0, known_args/0]).
-endif.

-type cli_args() :: [string()].

-spec run(cli_args()) -> ok | no_return().
run(Args) ->
    Aliases = #{"-h" => "--help", "-f" => "--format", "-q" => "--search",
                "-w" => "--watch", "-d" => "--diff", "-a" => "--always"},
    Args1 = wfcli_cli_args:expand_aliases(Args, Aliases),
    Args2 = wfcli_cli_args:prompt_suggestions(Args1, known_args()),
    case help_request(Args2) of
        {help, Topic} ->
            help(Topic),
            halt(0);
        none ->
            case parse_args(Args2, default_acc()) of
                #{errors := []} = Parsed ->
                    do_run(Parsed);
                #{errors := Errors} ->
                    lists:foreach(fun(E) -> io:format("error: ~ts~n", [E]) end, Errors),
                    help([]),
                    halt(1)
            end
    end.

-spec run_command(string(), cli_args()) -> ok | no_return().
run_command(Command, Args) ->
    Aliases = #{"-h" => "--help", "-f" => "--format", "-q" => "--search",
                "-w" => "--watch", "-d" => "--diff", "-a" => "--always"},
    Args1 = wfcli_cli_args:expand_aliases(Args, Aliases),
    Args2 = wfcli_cli_args:prompt_suggestions(Args1, known_args()),
    DefaultCache = wfcli_paths:cache_file("worldstate.json"),
    case Args2 of
        ["help" | _] ->
            help_for_command(Command, DefaultCache),
            halt(0);
        _ ->
            case wfcli_cli_args:has_help_flag(Args2) of
                true ->
                    help_for_command(Command, DefaultCache),
                    halt(0);
                false ->
                    case command_defaults(Command) of
                        undefined ->
                            help_summary(DefaultCache),
                            halt(1);
                        Defaults ->
                            Acc0 = maps:merge(default_acc(), Defaults),
                            case parse_args(Args2, Acc0) of
                                #{errors := []} = Parsed ->
                                    do_run(Parsed);
                                #{errors := Errors} ->
                                    lists:foreach(fun(E) -> io:format("error: ~ts~n", [E]) end, Errors),
                                    help_for_command(Command, DefaultCache),
                                    halt(1)
                            end
                    end
            end
    end.

-spec help(cli_args()) -> ok.
help(Args) ->
    DefaultCache = wfcli_paths:cache_file("worldstate.json"),
    case Args of
        [] -> help_summary(DefaultCache);
        ["watch"] -> help_watch(DefaultCache);
        ["query"] -> help_query();
        [Sub] -> help_subcommand(Sub, DefaultCache);
        _ -> help_summary(DefaultCache)
    end.

help_summary(DefaultCache) ->
    io:put_chars(
      wfcli_help_text:worldstate_summary(command_help_names(), DefaultCache)).

help_watch(DefaultCache) ->
    io:put_chars(
      wfcli_help_text:worldstate_watch(DefaultCache)).

help_query() ->
    io:put_chars(
      [
          "QUERY SYNTAX:\n",
          wfcli_help_text:query_guide(),
          "  Data keys: name, id, type, data.<path>.\n",
          "  Watch extracts: extract=data.<path>.\n",
          "\n",
          "EXAMPLES:\n",
          wfcli_help_text:query_examples()
      ]).

help_subcommand(Sub0, DefaultCache) ->
    Sub = string:lowercase(Sub0),
    case watch_type_filter(Sub) of
        {ok, Type} ->
            io:put_chars(
              wfcli_help_text:worldstate_subcommand(
                Sub, Type, command_description(Sub), DefaultCache));
        _ ->
            help_summary(DefaultCache)
    end.

help_request(Args) ->
    case Args of
        ["help" | Rest] -> {help, Rest};
        _ ->
            case wfcli_cli_args:has_help_flag(Args) of
                true ->
                    Args1 = wfcli_cli_args:strip_help_flags(Args),
                    {help, help_topic_from_args(Args1)};
                false -> none
            end
    end.

help_topic_from_args([First | _]) ->
    case First of
        "watch" -> ["watch"];
        "query" -> ["query"];
        _ -> [First]
    end;
help_topic_from_args([]) ->
    [].

help_for_command("watch", DefaultCache) ->
    help_watch(DefaultCache);
help_for_command(Command, DefaultCache) ->
    case watch_type_filter(Command) of
        {ok, _} -> help_subcommand(Command, DefaultCache);
        _ -> help_summary(DefaultCache)
    end.

calendar_help() ->
    help_subcommand("calendar", wfcli_paths:cache_file("worldstate.json")).

do_run(Parsed) ->
    case maps:get(help, Parsed, false) of
        true ->
            case maps:get(type_filter, Parsed, undefined) of
                calendar -> calendar_help(), halt(0);
                _ -> help([]), halt(0)
            end;
        false -> ok
    end,
    case run_updates(Parsed) of
        continue -> ok;
        {halt, Code} -> halt(Code)
    end,
    case validate_calendar_day(Parsed) of
        ok -> ok;
        {error, Msg} ->
            io:format("error: ~ts~n", [Msg]),
            halt(1)
    end,
    case validate_inventory_watch(Parsed) of
        ok -> ok;
        {error, InventoryMsg} ->
            io:format("error: ~ts~n", [InventoryMsg]),
            halt(1)
    end,
    case maps:get(watch, Parsed, false) of
        true ->
            wfcli_worldstate_watch_cli:run(Parsed);
        false ->
            run_once(Parsed)
    end.

run_once(Parsed) ->
    run_daemon_once(Parsed).

run_daemon_once(Parsed) ->
    case inventory_type(Parsed) of
        {error, Msg} ->
            io:format("error: ~s~n", [Msg]),
            halt(1);
        Inventory ->
            Request = #{source => request_source(Inventory),
                        opts => wfcli_worldstate_output:load_opts(Parsed),
                        query => maps:get(search, Parsed, undefined),
                        type_filter => maps:get(type_filter, Parsed, undefined),
                        day_filter => maps:get(calendar_day, Parsed, undefined),
                        mode => maps:get(mode, Parsed, list),
                        inventory => Inventory},
            case wfcli_client:one_shot(Request) of
                {ok, Result} -> wfcli_worldstate_output:print_daemon_result(Result, Parsed);
                {error, Reason} ->
                    io:format("worldstate daemon error: ~ts~n",
                              [wfcli_client:format_error(Reason)]),
                    halt(1)
            end
    end.

inventory_type(Parsed) ->
    case maps:get(inventory, Parsed, false) of
        false -> false;
        true ->
            case maps:get(type_filter, Parsed, undefined) of
                baro -> baro;
                prime_vault -> prime_vault;
                teshin -> teshin;
                _ -> {error, "--inventory only applies to baro, prime-vault, or teshin"}
            end
    end.

request_source(teshin) -> teshin;
request_source(_) -> worldstate.

default_acc() ->
    #{refresh => false, ttl => 60, cache => undefined,
      search => undefined, errors => [], help => false,
      update_nodes => false, update_languages => false,
      update_manifest => false, update_exports => false,
      update_recipes => false,
      update_upgrades => false, update_weapons => false,
      update_warframes => false, update_resources => false,
      update_all => false, resolve_items => true, raw => false,
      type_filter => undefined, mode => list,
      event_lang => undefined, inventory => false,
      output_format => table,
      watch => false, diff_style => inline, watch_always => false,
      interval => 60, clear => false, once => false,
      calendar_day => undefined,
      archimedea_selection => all,
      watch_specs => []}.

-spec command_names() -> [string()].
command_names() ->
    command_aliases() ++ ["watch"].

-spec command_help_names() -> [string()].
command_help_names() ->
    [Name || {Name, _Type, true} <- command_specs()] ++ ["watch"].

-doc "Return the user-facing summary used by top-level and command-specific help.".
-spec command_description(string()) -> string().
command_description("baro") -> "show Baro schedule, relay, or current inventory";
command_description("teshin") -> "show current Teshin Steel Path inventory";
command_description("prime-vault") -> "show Prime Vault schedule or inventory";
command_description("calendar") -> "show calendar season schedule";
command_description("arbitration") -> "show current Arbitration";
command_description("archimedea") -> "show current Deep and Temporal Archimedea rotations";
command_description("sorties") -> "show current Sortie";
command_description("watch") -> "watch one or more data commands";
command_description(Name) ->
    "list " ++ lists:flatten(string:replace(Name, "-", " ", all)).

command_aliases() ->
    [Name || {Name, _Type, _Show} <- command_specs()].

command_specs() ->
    [
        {"invasions", invasion, true},
        {"invasion", invasion, false},
        {"fissures", fissure, true},
        {"sorties", sortie, true},
        {"alerts", alert, true},
        {"alert", alert, false},
        {"baro", baro, true},
        {"teshin", teshin, true},
        {"arbitration", arbitration, true},
        {"arbitrations", arbitration, false},
        {"voidstorms", void_storm, true},
        {"events", event, true},
        {"calendar", calendar, true},
        {"global-upgrades", global_upgrade, true},
        {"syndicate-missions", syndicate_mission, true},
        {"daily-deals", daily_deal, true},
        {"prime-vault", prime_vault, true},
        {"flash-sales", flash_sale, true},
        {"goals", goal, true},
        {"archimedea", archimedea, true},
        {"conquests", archimedea, false},
        {"construction-projects", construction_project, true},
        {"descents", descent, true},
        {"endless-xp", endless_xp, true},
        {"experiment-recommended", experiment_recommended, true},
        {"featured-guilds", featured_guild, true},
        {"hub-events", hub_event, true},
        {"market", in_game_market, true},
        {"library", library_info, true},
        {"lite-sorties", lite_sortie, true},
        {"node-overrides", node_override, true},
        {"pvp-active-tournaments", pvp_active_tournament, true},
        {"pvp-alternative-modes", pvp_alternative_mode, true},
        {"pvp-challenges", pvp_challenge, true},
        {"persistent-enemies", persistent_enemy, true},
        {"prime-access", prime_access, true},
        {"prime-token", prime_token, true},
        {"prime-vault-availabilities", prime_vault_availability, true},
        {"project-pct", project_pct, true},
        {"season-info", season_info, true},
        {"sku-sales", sku_sale, true},
        {"twitch-promos", twitch_promo, true},
        {"meta", meta, true}
    ].

command_type(Name) ->
    case lists:keyfind(Name, 1, command_specs()) of
        {Name, Type, _Show} -> {ok, Type};
        false -> error
    end.

command_defaults("watch") ->
    #{watch => true};
command_defaults("teshin") ->
    #{type_filter => teshin, mode => list, resolve_items => true, inventory => true};
command_defaults(Command) when Command =:= "archimedea"; Command =:= "conquests" ->
    #{type_filter => archimedea, mode => list, resolve_items => true, output_format => block};
command_defaults(Command) ->
    case watch_type_filter(Command) of
        {ok, Type} -> #{type_filter => Type, mode => list, resolve_items => true};
        _ -> undefined
    end.

run_updates(Parsed) ->
    Selections = legacy_update_selections(Parsed),
    case Selections of
        [] -> continue;
        _ ->
            case wfcli_update_cli:refresh_metadata(Selections) of
                ok -> {halt, 0};
                {error, _Reason} -> {halt, 1}
            end
    end.

legacy_update_selections(#{update_all := true}) -> [default];
legacy_update_selections(Parsed) ->
    Pairs = [{update_nodes, nodes}, {update_languages, languages},
             {update_manifest, manifest}, {update_exports, exports},
             {update_recipes, recipes}, {update_upgrades, upgrades},
             {update_weapons, weapons}, {update_warframes, warframes},
             {update_resources, resources}],
    [Source || {Flag, Source} <- Pairs, maps:get(Flag, Parsed, false)].

parse_args([], Acc) -> validate_search_query(Acc);
parse_args(["watch" | Rest], Acc) ->
    parse_args(Rest, Acc#{watch := true});
parse_args(["--refresh" | Rest], Acc) ->
    parse_args(Rest, Acc#{refresh := true});
parse_args(["-h" | Rest], Acc) ->
    parse_args(Rest, Acc#{help := true});
parse_args(["--help" | Rest], Acc) ->
    parse_args(Rest, Acc#{help := true});
parse_args(["--ttl", Val | Rest], Acc) ->
    case string:to_integer(Val) of
        {Int, _} when Int >= 60 -> parse_args(Rest, Acc#{ttl := Int});
        {Int, _} when Int >= 0 ->
            parse_args(Rest, Acc#{errors := ["--ttl must be >= 60" | maps:get(errors, Acc, [])]});
        _ -> parse_args(Rest, Acc#{errors := ["invalid --ttl" | maps:get(errors, Acc, [])]})
    end;
parse_args(["--cache", Path | Rest], Acc) ->
    parse_args(Rest, Acc#{cache := Path});
parse_args(["--interval", Val | Rest], Acc) ->
    case string:to_integer(Val) of
        {Int, _} when Int >= 0 -> parse_args(Rest, Acc#{interval := Int});
        _ -> parse_args(Rest, Acc#{errors := ["invalid --interval" | maps:get(errors, Acc, [])]})
    end;
parse_args(["--day"], Acc) ->
    parse_args([], Acc#{errors := ["--day requires a value" | maps:get(errors, Acc, [])]});
parse_args(["--day", Val | Rest], Acc) ->
    case string:to_integer(Val) of
        {Int, _} when Int >= 0 -> parse_args(Rest, Acc#{calendar_day := Int});
        _ -> parse_args(Rest, Acc#{errors := ["invalid --day" | maps:get(errors, Acc, [])]})
    end;
parse_args(["--deep" | Rest], Acc = #{type_filter := archimedea}) ->
    parse_args(Rest, set_archimedea_selection(deep, Acc));
parse_args(["--temporal" | Rest], Acc = #{type_filter := archimedea}) ->
    parse_args(Rest, set_archimedea_selection(temporal, Acc));
parse_args([Flag | Rest], Acc) when Flag =:= "--deep"; Flag =:= "--temporal" ->
    parse_args(Rest, Acc#{errors := [Flag ++ " only applies to archimedea" |
                                     maps:get(errors, Acc, [])]});
parse_args(["--spec"], Acc) ->
    parse_args([], Acc#{errors := ["--spec requires a value" | maps:get(errors, Acc, [])]});
parse_args(["--spec", Spec | Rest], Acc) ->
    parse_args(Rest, add_watch_spec(Spec, Acc));
parse_args(["--"], Acc = #{watch := true}) ->
    parse_watch_specs([], Acc);
parse_args(["--" | Rest], Acc = #{watch := true}) ->
    parse_watch_specs(Rest, Acc);
parse_args(["--"], Acc) ->
    parse_args([], Acc#{errors := ["-- requires watch mode" | maps:get(errors, Acc, [])]});
parse_args(["--search"], Acc) ->
    parse_args([], Acc#{errors := ["--search requires a query" | maps:get(errors, Acc, [])]});
parse_args(["--search", Q | Rest], Acc) ->
    parse_args(Rest, Acc#{search := Q});
parse_args(["--lang"], Acc) ->
    parse_args([], Acc#{errors := ["--lang requires a code" | maps:get(errors, Acc, [])]});
parse_args(["--lang", Code | Rest], Acc) ->
    parse_args(Rest, Acc#{event_lang := Code});
parse_args(["--inventory" | Rest], Acc = #{watch := true}) ->
    parse_args(Rest, Acc#{errors := ["--inventory is not supported with watch" | maps:get(errors, Acc, [])]});
parse_args(["--inventory" | Rest], Acc) ->
    parse_args(Rest, Acc#{inventory := true});
parse_args(["--watch" | Rest], Acc) ->
    parse_args(Rest, Acc#{watch := true});
parse_args(["--diff" | Rest], Acc) ->
    parse_args(Rest, Acc#{watch := true, diff_style := list});
parse_args(["--diff-style"], Acc) ->
    parse_args([], Acc#{errors := ["--diff-style requires a value" | maps:get(errors, Acc, [])]});
parse_args(["--diff-style", Style0 | Rest], Acc) ->
    Style = string:lowercase(Style0),
    case Style of
        "inline" -> parse_args(Rest, Acc#{watch := true, diff_style := inline});
        "list" -> parse_args(Rest, Acc#{watch := true, diff_style := list});
        "diff" -> parse_args(Rest, Acc#{watch := true, diff_style := diff});
        "none" -> parse_args(Rest, Acc#{watch := true, diff_style := none});
        _ -> parse_args(Rest, Acc#{errors := ["invalid --diff-style (use inline|list|diff|none)" | maps:get(errors, Acc, [])]})
    end;
parse_args(["--always" | Rest], Acc) ->
    parse_args(Rest, Acc#{watch := true, watch_always := true});
parse_args(["--clear" | Rest], Acc) ->
    parse_args(Rest, Acc#{clear := true});
parse_args(["--no-clear" | Rest], Acc) ->
    parse_args(Rest, Acc#{clear := false});
parse_args(["--once" | Rest], Acc) ->
    parse_args(Rest, Acc#{once := true});
parse_args(["--update-nodes" | Rest], Acc) ->
    parse_args(Rest, Acc#{update_nodes := true});
parse_args(["--update-languages" | Rest], Acc) ->
    parse_args(Rest, Acc#{update_languages := true});
parse_args(["--update-manifest" | Rest], Acc) ->
    parse_args(Rest, Acc#{update_manifest := true});
parse_args(["--update-exports" | Rest], Acc) ->
    parse_args(Rest, Acc#{update_exports := true});
parse_args(["--update-recipes" | Rest], Acc) ->
    parse_args(Rest, Acc#{update_recipes := true});
parse_args(["--update-upgrades" | Rest], Acc) ->
    parse_args(Rest, Acc#{update_upgrades := true});
parse_args(["--update-weapons" | Rest], Acc) ->
    parse_args(Rest, Acc#{update_weapons := true});
parse_args(["--update-warframes" | Rest], Acc) ->
    parse_args(Rest, Acc#{update_warframes := true});
parse_args(["--update-resources" | Rest], Acc) ->
    parse_args(Rest, Acc#{update_resources := true});
parse_args(["--update-all" | Rest], Acc) ->
    parse_args(Rest, Acc#{update_all := true});
parse_args(["--output-format"], Acc) ->
    parse_args([], Acc#{errors := ["--output-format requires a value" | maps:get(errors, Acc, [])]});
parse_args(["--format"], Acc) ->
    parse_args([], Acc#{errors := ["--format requires a value" | maps:get(errors, Acc, [])]});
parse_args(["--output-format", Format | Rest], Acc) ->
    parse_args(Rest, parse_output_format(Format, Acc));
parse_args(["--format", Format | Rest], Acc) ->
    parse_args(Rest, parse_output_format(Format, Acc));
parse_args(["--raw" | Rest], Acc) ->
    parse_args(Rest, Acc#{resolve_items := false, raw := true});
parse_args([Command | Rest], Acc = #{watch := false}) ->
    case command_type(Command) of
        {ok, Type} ->
            parse_args(Rest, Acc#{type_filter := Type, mode := list, resolve_items := true});
        error ->
            case maps:get(search, Acc, undefined) of
                undefined ->
                    parse_args(Rest, Acc#{search := Command});
                _ ->
                    Suggest = wfcli_cli_suggest:suggest(Command, known_args()),
                    parse_args(Rest, Acc#{errors := [io_lib:format("unknown arg: ~s~s", [Command, Suggest])
                                                    | maps:get(errors, Acc, [])]})
            end
    end;
parse_args([Unknown | Rest], Acc = #{watch := true, type_filter := Type, search := undefined}) when Type =/= undefined ->
    parse_args(Rest, Acc#{search := Unknown});
parse_args([Unknown | Rest], Acc = #{watch := true}) ->
    parse_args(Rest, add_watch_spec(Unknown, Acc));
parse_args([Unknown | Rest], Acc) ->
    Suggest = wfcli_cli_suggest:suggest(Unknown, known_args()),
    parse_args(Rest, Acc#{errors := [io_lib:format("unknown arg: ~s~s", [Unknown, Suggest])
                                    | maps:get(errors, Acc, [])]}).

known_args() ->
    Flags = [
        "--refresh", "--ttl", "--cache", "--search", "--lang", "--interval", "--spec", "--watch",
        "--diff", "--diff-style", "--always", "--clear", "--no-clear", "--once", "--help", "-h",
        "--update-nodes", "--update-languages", "--update-manifest", "--update-exports",
        "--update-recipes", "--update-upgrades", "--update-weapons", "--update-warframes",
        "--update-resources", "--update-all", "--raw", "--inventory", "--output-format", "--format",
        "--day", "--deep", "--temporal", "--no-suggest-prompt", "help", "query"
    ],
    Flags ++ command_names().

parse_watch_specs([], Acc) -> Acc;
parse_watch_specs([Spec | Rest], Acc) ->
    parse_watch_specs(Rest, add_watch_spec(Spec, Acc)).

add_watch_spec(Spec, Acc) ->
    case maps:get(watch, Acc, false) of
        false ->
            Acc#{errors := ["--spec requires watch mode" | maps:get(errors, Acc, [])]};
        true ->
            case parse_watch_spec(Spec) of
                {ok, SpecMaps} ->
                    Specs = maps:get(watch_specs, Acc, []),
                    Acc#{watch_specs := SpecMaps ++ Specs};
                {error, Msg} ->
                    Acc#{errors := [Msg | maps:get(errors, Acc, [])]}
            end
    end.

parse_watch_spec(Spec) ->
    Spec1 = string:trim(Spec),
    case Spec1 of
        "" -> {error, "watch spec cannot be empty"};
        _ ->
            Specs = split_watch_group(Spec1),
            parse_watch_specs_list(Specs, [])
    end.

parse_watch_specs_list([], Acc) ->
    {ok, lists:reverse(Acc)};
parse_watch_specs_list([Spec | Rest], Acc) ->
    {Name0, Query0} = split_watch_spec(Spec),
    Name = string:lowercase(string:trim(Name0)),
    Query1 = string:trim(Query0),
    Query = case Query1 of "" -> undefined; _ -> Query1 end,
      case watch_type_filter(Name) of
          {ok, Type} ->
              Label = case Query of
                  undefined -> Name;
                  _ -> Name ++ " (" ++ Query ++ ")"
              end,
              parse_watch_specs_list(
                Rest, [#{label => Label, type_filter => Type, query => Query} | Acc]);
          {error, Msg} -> {error, Msg}
      end.

validate_search_query(Acc) ->
    case maps:get(archimedea_selection, Acc, all) of
        all -> Acc;
        deep -> add_search_clause("archimedea=deep", Acc);
        temporal -> add_search_clause("archimedea=temporal", Acc)
    end.

set_archimedea_selection(Selection, Acc) ->
    case maps:get(archimedea_selection, Acc, all) of
        all -> Acc#{archimedea_selection := Selection};
        Selection -> Acc;
        _ -> Acc#{errors := ["--deep and --temporal are mutually exclusive" |
                              maps:get(errors, Acc, [])]}
    end.

add_search_clause(Clause, Acc) ->
    case maps:get(search, Acc, undefined) of
        undefined -> Acc#{search := Clause};
        Existing -> Acc#{search := "(" ++ Existing ++ ") " ++ Clause}
    end.

split_watch_group(Spec) ->
    case has_query_operators(Spec) of
        true -> [Spec];
        false -> string:split(Spec, "|", all)
    end.

has_query_operators(Spec) ->
    lists:any(fun(S) -> string:find(Spec, S) =/= nomatch end, [":", "=", "~", ">", "<"]).

split_watch_spec(Spec) ->
    case string:split(Spec, ":", leading) of
        [Name, Query] -> {Name, Query};
        [_] ->
            case string:split(Spec, "=", leading) of
                [Name1, Query1] -> {Name1, Query1};
                [_] -> {Spec, ""}
            end
    end.

watch_type_filter(Name) ->
    case command_type(Name) of
        {ok, Type} -> {ok, Type};
        error -> {error, io_lib:format("unknown watch spec: ~s", [Name])}
    end.

validate_calendar_day(Parsed) ->
    Day = maps:get(calendar_day, Parsed, undefined),
    case {Day, maps:get(watch, Parsed, false), maps:get(type_filter, Parsed, undefined)} of
        {undefined, _, _} -> ok;
        {_, true, _} -> ok;
        {_, false, calendar} -> ok;
        _ -> {error, "--day requires the calendar subcommand (or use calendar in watch mode)"}
    end.

validate_inventory_watch(Parsed) ->
    case {maps:get(inventory, Parsed, false), maps:get(watch, Parsed, false)} of
        {true, true} -> {error, "--watch is not supported for inventory commands"};
        _ -> ok
    end.

parse_output_format(Format, Acc) ->
    case string:lowercase(Format) of
        "block" -> Acc#{output_format := block};
        "table" -> Acc#{output_format := table};
        Other ->
            Acc#{errors := [io_lib:format("invalid --output-format: ~s", [Other]) | maps:get(errors, Acc, [])]}
    end.
