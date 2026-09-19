-module(wfcli_visualize).

-export([command/0, arguments/0, run/1]).
-import(wfcli_cli_args, [option/4, flag/3]).

-ifdef(TEST).
-export([load_plan/1]).
-endif.

command() ->
    #{help => "render forma-plan outputs", handler => {?MODULE, run},
      arguments => [#{name => plan, required => true, help => "plan YAML file"},
                    option(plan, "plan", string, "plan YAML file"),
                    option(config, "config", string, "override source config")] ++ arguments()}.

arguments() ->
    [option(viz_mode, "viz", {atom, [html, image]}, "visualization format"),
     option(viz_output, "viz-output", string, "visualization output file"),
     flag(viz_config, "viz-config", "also visualize source configuration")].

run(#{plan := File} = Parsed) ->
    case file:read_file(File) of
        {ok, Bin} ->
             case load_plan(Bin) of
                 {ok, Entries} ->
                     VizMode = resolve_mode(maps:get(viz_mode, Parsed, none)),
                     VizOut = maps:get(viz_output, Parsed, undefined),
                     VizCfg = maps:get(viz_config, Parsed, false),
                     ConfigOverride = maps:get(config, Parsed, undefined),
                     lists:foreach(fun(E) -> show_entry(E, VizMode, VizOut, VizCfg, ConfigOverride) end, Entries);
                 {error, Reason} ->
                     io:format(standard_error, "error: ~p~n", [Reason]),
                     halt(1)
             end;
         {error, Reason} ->
             io:format(standard_error, "error: cannot read ~s: ~p~n", [File, Reason]),
             halt(1)
     end.

 resolve_mode(none) -> html;
 resolve_mode(M) -> M.

show_entry(#{config := File, plan := Plan, slot_mods := SlotMods, build_arcanes := BuildArcanes},
           VizMode, VizOut, VizCfg, ConfigOverride) ->
    do_viz(File, Plan, SlotMods, BuildArcanes, VizMode, VizOut),
    case VizCfg of
        false -> ok;
        true ->
            ConfPath = case ConfigOverride of undefined -> File; Other -> Other end,
            Request = #{source => forma, action => config_layout,
                        configs => [filename:absname(ConfPath)], flags => #{}},
            case wfcli_client:one_shot(Request) of
                {ok, #{results := [{ok, Config, PlanCfg, _Cost}]}} ->
                    SlotMods2 = maps:get(computed_current_slot_mods, Config, []),
                    BuildArcanes2 = maps:get(computed_build_arcanes, Config, []),
                    do_config_viz(ConfPath, PlanCfg, SlotMods2, BuildArcanes2, VizMode, VizOut);
                {error, Reason} ->
                    io:format("config visualization skipped (~s): ~p~n", [ConfPath, Reason])
            end
    end;
show_entry(_, _, _, _, _) -> ok.

do_viz(File, Plan, SlotMods, BuildArcanes, html, Out) ->
    case wfcli_forma_visualizer:render_html(File, Plan, SlotMods, BuildArcanes, Out) of
        {ok, Path} ->
            io:format("visualization (html): ~s~n", [Path]),
            wfcli_forma_visualizer:open_file(Path);
        {error, Reason} ->
            io:format("visualization html failed: ~p~n", [Reason])
    end;
do_viz(File, Plan, SlotMods, BuildArcanes, image, Out) ->
    case wfcli_forma_visualizer:render_svg(File, Plan, SlotMods, BuildArcanes, Out) of
        {ok, Path} ->
            io:format("visualization (svg): ~s~n", [Path]),
            wfcli_forma_visualizer:open_file(Path);
        {error, Reason} ->
            io:format("visualization svg failed: ~p~n", [Reason])
    end;
do_viz(_, _, _, _, _, _) -> ok.

do_config_viz(File, Plan, SlotMods, BuildArcanes, html, Out) ->
    case wfcli_forma_visualizer:render_config_html(File, Plan, SlotMods, BuildArcanes, Out) of
        {ok, Path} ->
            io:format("config visualization (html): ~s~n", [Path]),
            wfcli_forma_visualizer:open_file(Path);
        {error, Reason} ->
            io:format("config visualization html failed: ~p~n", [Reason])
    end;
do_config_viz(File, Plan, SlotMods, BuildArcanes, image, Out) ->
    case wfcli_forma_visualizer:render_config_svg(File, Plan, SlotMods, BuildArcanes, Out) of
        {ok, Path} ->
            io:format("config visualization (svg): ~s~n", [Path]),
            wfcli_forma_visualizer:open_file(Path);
        {error, Reason} ->
            io:format("config visualization svg failed: ~p~n", [Reason])
    end;
do_config_viz(_, _, _, _, _, _) -> ok.

load_plan(Bin) ->
    try yamerl_constr:string(Bin, [{map_node_format, map}, {str_node_as_binary, true}]) of
        Docs when is_list(Docs) ->
            Parsed = [decode_plan(D) || D <- Docs],
            {ok, Parsed}
    catch
        Class:Reason ->
            {error, {parse_failed, Class, Reason}}
    end.

decode_plan(Doc) when is_map(Doc) ->
    File = maps:get(<<"config">>, Doc, <<"unknown">>),
    PlanList = maps:get(<<"plan">>, Doc, []),
    Plan = plan_map(PlanList),
    SlotMods = slot_mods(maps:get(<<"slot_mods">>, Doc, [])),
    BuildArcanes = build_arcanes(maps:get(<<"build_arcanes">>, Doc, [])),
    #{config => wfcli_forma_plan:to_list(File), plan => Plan, slot_mods => SlotMods, build_arcanes => BuildArcanes};
decode_plan(_Other) ->
    #{config => "unknown", plan => #{}, slot_mods => [], build_arcanes => []}.

plan_map(List) ->
    lists:foldl(
      fun(#{<<"slot">> := Slot, <<"polarity">> := Pol}, Acc) ->
          maps:put(normalize_slot(Slot), wfcli_polarity:normalize(Pol), Acc)
      end,
      #{},
      List).

normalize_slot(<<"aura">>) -> aura;
normalize_slot(<<"exilus">>) -> exilus;
normalize_slot("aura") -> aura;
normalize_slot("exilus") -> exilus;
normalize_slot(Bin) when is_binary(Bin) ->
    normalize_slot(binary_to_list(Bin));
normalize_slot(Str) when is_list(Str) ->
    case string:to_integer(Str) of
        {Int, _} when Int > 0 -> Int;
        _ -> Str
    end;
normalize_slot(Int) when is_integer(Int) -> Int;
normalize_slot(Other) -> Other.

slot_mods(List) ->
    [slot_mod_entry(E) || E <- List, is_map(E)].

slot_mod_entry(#{<<"slot">> := Slot, <<"mods">> := Mods}) ->
    {normalize_slot(Slot), mod_pairs(Mods)};
slot_mod_entry(_) -> {none, []}.

mod_pairs(List) ->
    [{wfcli_forma_plan:to_list(maps:get(<<"build">>, M, <<"">>)),
      wfcli_forma_plan:to_list(maps:get(<<"mod">>, M, <<"">>))}
     || M <- List, is_map(M)].

build_arcanes(List) ->
    [build_arcane_entry(E) || E <- List, is_map(E)].

build_arcane_entry(#{<<"build">> := Build, <<"arcanes">> := Arcanes}) ->
    {wfcli_forma_plan:to_list(Build), arcane_entries(Arcanes)};
build_arcane_entry(_) ->
    {"", []}.

arcane_entries(List) when is_list(List) ->
    [arcane_entry(E) || E <- List];
arcane_entries(_) ->
    [].

arcane_entry(#{<<"name">> := Name} = Map) ->
    RankRaw = maps:get(<<"rank">>, Map, undefined),
    Rank = case RankRaw of
               Bin when is_binary(Bin) ->
                   case string:to_integer(binary_to_list(Bin)) of
                       {Int, _} -> Int;
                       _ -> undefined
                   end;
               Int when is_integer(Int) -> Int;
               _ -> undefined
           end,
    case Rank of
        undefined -> #{name => wfcli_forma_plan:to_list(Name)};
        _ -> #{name => wfcli_forma_plan:to_list(Name), rank => Rank}
    end;
arcane_entry(Arcane) when is_binary(Arcane); is_list(Arcane); is_atom(Arcane) ->
    #{name => wfcli_forma_plan:to_list(Arcane)};
arcane_entry(_) ->
    #{}.
