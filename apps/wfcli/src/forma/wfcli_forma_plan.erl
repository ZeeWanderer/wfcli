%%%-------------------------------------------------------------------
%% Placeholder for Forma plan calculator CLI.
%%%-------------------------------------------------------------------
-module(wfcli_forma_plan).

-export([run/1, plans_to_yaml/1, to_list/1, slot_mod_labels/1, slot_mod_labels/2,
         build_arcane_entries/1, known_args/0]).

-type cli_args() :: [string()].
-type config() :: map().
-type plan() :: map().
-type planner_result() :: {ok, config(), plan(), non_neg_integer()}.
-type slot_mod_labels() :: [{term(), [{term(), term()}]}].
-type build_arcanes() :: [{term(), [term()]}].

-doc "Run the `forma-plan` CLI command with already-tokenized arguments.".
-spec run(cli_args()) -> ok | no_return().
run(Args) ->
    Args1 = wfcli_cli_args:prompt_suggestions(Args, known_args()),
    case lists:member("--help", Args1) orelse lists:member("-h", Args1) of
        true ->
            help();
        false ->
            dispatch_args(Args1)
    end.

help() ->
    io:put_chars(wfcli_help_text:forma_plan_help()).

dispatch_args(Args) ->
    case parse_args(Args, #{configs => [], flags => #{}, errors => [], viz_mode => none, viz_output => undefined, viz_config => false, visualize => false}) of
        #{errors := []} = Parsed ->
            maybe_run(Parsed);
        #{errors := Errors} ->
            lists:foreach(fun(E) -> io:format("error: ~s~n", [E]) end, Errors),
            help(),
            halt(1)
    end.

-doc "Return argv tokens accepted by parser suggestions and shell completion.".
-spec known_args() -> [string()].
known_args() ->
    [
        "--config", "--allow-omni", "--allow-umbral-forma", "--prefer-omni", "--max-forma",
        "--show-alt", "--output", "--visualize", "--viz", "--viz-output", "--viz-config",
        "--help", "-h", "--no-suggest-prompt"
    ].

maybe_run(#{configs := []}) ->
    io:format("error: at least one --config FILE.yml is required~n"),
    help(),
    halt(1);
maybe_run(#{configs := Files, flags := Flags} = Parsed) ->
    Output = maps:get(output, Parsed, undefined),
    Visualize = maps:get(visualize, Flags, false),
    VizOut = maps:get(viz_output, Parsed, undefined),
    VizCfg = maps:get(viz_config, Parsed, false),
    VizMode0 = maps:get(viz_mode, Parsed, none),
    VizMode = case VizMode0 of
                  none -> case (Visualize orelse VizCfg) of true -> html; false -> none end;
                  Other -> Other
              end,
    Request = #{source => forma,
                configs => [filename:absname(File) || File <- lists:reverse(Files)],
                flags => Flags},
    case wfcli_client:one_shot(Request) of
        {ok, #{results := Results}} ->
            render_results(Results, Output, VizMode, VizOut, VizCfg);
        {error, {config_errors, Errors}} ->
            lists:foreach(fun(Error) -> io:format("error: ~ts~n", [Error]) end, Errors),
            halt(1);
        {error, Reason} ->
            io:format("planner daemon error: ~ts~n", [wfcli_client:format_error(Reason)]),
            halt(1)
    end.

render_results(Results, Output0, VizMode, VizOut, VizCfg) ->
    Configs = [Config || Result <- Results,
                         Config <- [result_config(Result)],
                         Config =/= undefined],
    Output = ensure_output_path(Output0, Configs),
    lists:foreach(fun print_result/1, Results),
    case write_output(Output, Results) of
        {ok, Path} ->
            io:format("plan output: ~s~n", [to_list(Path)]),
            maybe_visualize_config(VizCfg, VizMode, VizOut, Configs),
            maybe_visualize(VizMode, VizOut, Results),
            case lists:any(fun({error, _}) -> true; (_) -> false end, Results) of
                true -> halt(1);
                false -> ok
            end;
        {error, Reason} ->
            io:format("failed to write output: ~p~n", [Reason]),
            halt(1)
    end.

result_config({ok, Config, _Plan, _Cost}) -> Config;
result_config({error, Config, _Reason}) -> Config;
result_config(_) -> undefined.

print_result({ok, Config = #{file := File}, Plan, Cost}) ->
    io:format("Config: ~s~n", [File]),
    io:format("  Forma cost: ~p~n", [Cost]),
    Sorted = sort_plan(Plan),
    print_plan_table(Sorted),
    SlotMods = slot_mod_labels(Config, Plan),
    print_slot_mods(SlotMods),
    BuildArcanes = build_arcane_entries(Config),
    print_build_arcanes(BuildArcanes),
    io:format("~n", []);
print_result({error, #{file := File}, Reason}) ->
    io:format("Config: ~s~n  Error: ~p~n~n", [File, Reason]).

print_plan_table(Sorted) ->
    io:format("  Plan:~n", []),
    Slots = [slot_label(Slot) || {Slot, _} <- Sorted],
    Width = max_label_width(["Slot" | Slots], 0),
    io:format("    ~s  Polarity~n", [wfcli_tty:pad_right("Slot", Width)]),
    lists:foreach(
      fun({Slot, Pol}) ->
          io:format("    ~s  ~s~n", [wfcli_tty:pad_right(slot_label(Slot), Width), polarity_label(Pol)])
      end,
      Sorted).

print_slot_mods([]) ->
    io:format("  Slot mods: none~n", []);
print_slot_mods(SlotMods) ->
    io:format("  Slot mods:~n", []),
    lists:foreach(
      fun({Slot, Mods}) ->
          io:format("    ~s:~n", [slot_label(Slot)]),
          lists:foreach(
            fun({Build, Mod}) ->
                io:format("      ~s: ~s~n", [to_list(Build), to_list(Mod)])
            end,
            Mods)
      end,
      SlotMods).

print_build_arcanes([]) ->
    ok;
print_build_arcanes(BuildArcanes) ->
    io:format("  Build arcanes:~n", []),
    lists:foreach(
      fun({Build, Arcanes}) ->
          io:format("    ~s:~n", [to_list(Build)]),
          lists:foreach(fun(Arcane) -> print_arcane(Arcane) end, Arcanes)
      end,
      BuildArcanes).

print_arcane(#{name := Name} = Arcane) ->
    Rank = maps:get(rank, Arcane, undefined),
    case Rank of
        undefined -> io:format("      - ~s~n", [to_list(Name)]);
        _ -> io:format("      - ~s (rank ~p)~n", [to_list(Name), Rank])
    end;
print_arcane(Arcane) ->
    io:format("      - ~s~n", [to_list(Arcane)]).

slot_label(Slot) -> to_list(Slot).

polarity_label(Pol) ->
    case wfcli_polarity:symbol(Pol) of
        null -> "none";
        Sym when is_list(Sym) -> Sym;
        Other -> to_list(Other)
    end.

max_label_width([], Width) -> Width;
max_label_width([Label | Rest], Width) ->
    max_label_width(Rest, max(Width, length(Label))).


parse_args([], Acc) ->
    Acc;
parse_args(["--config", File | Rest], Acc) ->
    Updated = Acc#{configs := [File | maps:get(configs, Acc)]},
    parse_args(Rest, Updated);
parse_args(["-h" | Rest], Acc) ->
    parse_args(Rest, add_error(Acc#{help => true}, "help requested"));
parse_args(["--help" | Rest], Acc) ->
    parse_args(Rest, add_error(Acc#{help => true}, "help requested"));
parse_args(["--output", File | Rest], Acc) ->
    parse_args(Rest, Acc#{output => File});
parse_args(["--allow-omni" | Rest], Acc) ->
    parse_args(Rest, put_flag(Acc, allow_omni, true));
parse_args(["--prefer-omni" | Rest], Acc) ->
    parse_args(Rest, put_flag(Acc, prefer_omni, true));
parse_args(["--allow-umbral-forma" | Rest], Acc) ->
    parse_args(Rest, put_flag(Acc, allow_umbral_forma, true));
parse_args(["--max-forma", N | Rest], Acc) ->
    case string:to_integer(N) of
        {Int, _} when Int >= 0 ->
            parse_args(Rest, put_flag(Acc, max_forma, Int));
        _ ->
            parse_args(Rest, add_error(Acc, io_lib:format("invalid --max-forma: ~s", [N])))
    end;
parse_args(["--visualize" | Rest], Acc) ->
    parse_args(Rest, put_flag(Acc, visualize, true));
parse_args(["--viz-config" | Rest], Acc) ->
    parse_args(Rest, Acc#{viz_config := true});
parse_args(["--viz", Mode | Rest], Acc) ->
    case string:lowercase(Mode) of
        "html" -> parse_args(Rest, Acc#{viz_mode := html});
        "image" -> parse_args(Rest, Acc#{viz_mode := image});
        Other -> parse_args(Rest, add_error(Acc, io_lib:format("invalid --viz: ~s", [Other])))
    end;
parse_args(["--viz-output", File | Rest], Acc) ->
    parse_args(Rest, Acc#{viz_output := File});
parse_args([Unknown | Rest], Acc) ->
    parse_args(Rest, add_error(Acc, io_lib:format("unknown option: ~s", [Unknown]))).

put_flag(Acc, Key, Value) ->
    Acc#{flags := maps:put(Key, Value, maps:get(flags, Acc))}.

add_error(Acc, MsgIOList) ->
    Msg = lists:flatten(MsgIOList),
    Acc#{errors := [Msg | maps:get(errors, Acc)]}.

ensure_output_path(undefined, Configs) ->
    default_output_path(Configs);
ensure_output_path(File, _Configs) ->
    File.

default_output_path(Configs) ->
    filename:absname(default_output_file(Configs)).

default_output_file([#{file := File} | _]) ->
    ConfigPath = to_list(File),
    Base = filename:rootname(filename:basename(ConfigPath)),
    filename:join(filename:dirname(ConfigPath), Base ++ ".plan.yml");
default_output_file(_) ->
    "wfcli.plan.yml".

write_output(File, Results) ->
    Good = [R || {ok, _, _, _} = R <- Results],
    Content = plans_to_yaml(Good),
    case file:write_file(File, Content) of
        ok -> {ok, File};
        {error, Reason} -> {error, Reason}
    end.

-doc "Serialize successful planner results to the YAML shape written by `--output`.".
-spec plans_to_yaml([planner_result()]) -> iodata().
plans_to_yaml(Results) ->
    Lines = [plan_to_yaml(R) || R <- Results],
    lists:flatten(Lines).

plan_to_yaml({ok, Config = #{file := File}, Plan, Cost}) ->
    SortedPlan = sort_plan(Plan),
    SlotMods = slot_mod_labels(Config, Plan),
    BuildArcanes = build_arcane_entries(Config),
    [
      "config: ", File, "\n",
      "forma_cost: ", integer_to_list(Cost), "\n",
      "plan:\n",
      [iolist_to_binary(io_lib:format("  - slot: ~p~n    polarity: ~s~n",
          [Slot, polarity_yaml(Pol)]))
       || {Slot, Pol} <- SortedPlan],
      "slot_mods:\n",
      [slot_mod_entry(Slot, Mods) || {Slot, Mods} <- SlotMods],
      build_arcane_yaml(BuildArcanes),
      "\n"
    ].

polarity_yaml(Pol) ->
    case wfcli_polarity:symbol(Pol) of
        null -> "null";
        Symbol -> [$", Symbol, $"]
    end.

sort_plan(Plan) ->
    lists:sort(fun slot_order/2, maps:to_list(Plan)).

slot_order(aura, aura) -> true;
slot_order(aura, _) -> true;
slot_order(_, aura) -> false;
slot_order(exilus, exilus) -> true;
slot_order(exilus, _) -> true;
slot_order(_, exilus) -> false;
slot_order(A, B) when is_integer(A), is_integer(B) -> A =< B;
slot_order(A, _B) when is_integer(A) -> true;
slot_order(_, _) -> true.

-doc "Return per-slot build/mod labels for the config's current polarities.".
-spec slot_mod_labels(config()) -> slot_mod_labels().
slot_mod_labels(Config) ->
    slot_mod_labels(Config, undefined).

-doc "Return per-slot build/mod labels for an explicit planned polarity map.".
-spec slot_mod_labels(config(), plan() | undefined) -> slot_mod_labels().
slot_mod_labels(Config, _Plan) when is_map(Config) ->
    maps:get(computed_slot_mods, Config, []);
slot_mod_labels(_Other, _Plan) -> [].

-doc "Return arcane labels grouped by build for visualization and YAML output.".
-spec build_arcane_entries(config()) -> build_arcanes().
build_arcane_entries(#{computed_build_arcanes := BuildArcanes}) -> BuildArcanes;
build_arcane_entries(_Other) -> [].

-doc "Convert atoms, binaries, and other values to printable lists.".
-spec to_list(term()) -> string().
to_list(V) -> wfcli_text:to_list(V).

slot_mod_entry(Slot, Mods) ->
    [
      "  - slot: ", io_lib:format("~p", [Slot]), "\n",
      "    mods:\n",
      [[ "      - build: ", to_list(Build), "\n",
         "        mod: ", to_list(Mod), "\n"]
       || {Build, Mod} <- Mods]
    ].

build_arcane_yaml([]) ->
    "build_arcanes: []\n";
build_arcane_yaml(BuildArcanes) ->
    ["build_arcanes:\n",
     [build_arcane_entry(Build, Arcanes) || {Build, Arcanes} <- BuildArcanes]].

build_arcane_entry(Build, Arcanes) ->
    [
      "  - build: ", to_list(Build), "\n",
      "    arcanes:\n",
      [arcane_yaml(Arcane) || Arcane <- Arcanes]
    ].

arcane_yaml(#{name := Name} = Arcane) ->
    Rank = maps:get(rank, Arcane, undefined),
    case Rank of
        undefined ->
            ["      - name: ", to_list(Name), "\n"];
        _ ->
            ["      - name: ", to_list(Name), "\n",
             "        rank: ", io_lib:format("~p", [Rank]), "\n"]
    end;
arcane_yaml(Arcane) ->
    ["      - name: ", to_list(Arcane), "\n"].

maybe_visualize(none, _Out, _Results) -> ok;
maybe_visualize(VizMode, VizOut, Results) ->
    lists:foreach(
      fun
          ({ok, Config = #{file := File}, Plan, _Cost}) ->
              SlotMods = slot_mod_labels(Config, Plan),
              BuildArcanes = build_arcane_entries(Config),
              case VizMode of
                  html ->
                      case wfcli_forma_visualizer:render_html(File, Plan, SlotMods, BuildArcanes, VizOut) of
                          {ok, Path} ->
                              io:format("visualization (html): ~s~n", [Path]),
                              wfcli_forma_visualizer:open_file(Path);
                          {error, Reason} ->
                              io:format("visualization html failed: ~p~n", [Reason])
                      end;
                  image ->
                      case wfcli_forma_visualizer:render_svg(File, Plan, SlotMods, BuildArcanes, VizOut) of
                          {ok, Path} ->
                              io:format("visualization (svg): ~s~n", [Path]),
                              wfcli_forma_visualizer:open_file(Path);
                          {error, Reason} ->
                              io:format("visualization svg failed: ~p~n", [Reason])
                      end;
                  _ -> ok
              end;
          (_) -> ok
      end,
      Results).

maybe_visualize_config(false, _Mode, _Out, _Configs) -> ok;
maybe_visualize_config(true, VizMode, VizOut, Configs) ->
    lists:foreach(
      fun(#{file := File} = Config) ->
          Plan = maps:get(computed_current_plan, Config, #{}),
          SlotMods = maps:get(computed_current_slot_mods, Config, []),
          BuildArcanes = build_arcane_entries(Config),
          case VizMode of
              html ->
                  case wfcli_forma_visualizer:render_config_html(File, Plan, SlotMods, BuildArcanes, VizOut) of
                      {ok, Path} ->
                          io:format("config visualization (html): ~s~n", [Path]),
                          wfcli_forma_visualizer:open_file(Path);
                      {error, Reason} ->
                          io:format("config visualization html failed: ~p~n", [Reason])
                  end;
              image ->
                  case wfcli_forma_visualizer:render_config_svg(File, Plan, SlotMods, BuildArcanes, VizOut) of
                      {ok, Path} ->
                          io:format("config visualization (svg): ~s~n", [Path]),
                          wfcli_forma_visualizer:open_file(Path);
                      {error, Reason} ->
                          io:format("config visualization svg failed: ~p~n", [Reason])
                  end;
              _ -> ok
          end
      end,
      Configs).
