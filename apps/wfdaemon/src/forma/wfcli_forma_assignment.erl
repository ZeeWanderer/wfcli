%%%-------------------------------------------------------------------
%% Capacity checks and deterministic mod-to-slot assignment.
%%%-------------------------------------------------------------------
-module(wfcli_forma_assignment).

-export([fits_all/3, for_plan/2]).

-type config() :: map().
-type plan() :: map().
-type slot_assignments() :: #{term() => [{term(), term()}]}.

-doc "Return whether every build fits under a concrete polarity plan.".
-spec fits_all(plan(), map(), [map()]) -> boolean().
fits_all(Plan, Item, Builds) ->
    {NormalPols, AuraPol, ExilusPol} = plan_polarities(Plan, Item),
    BaseCap = wfcli_forma_model:apply_reactor(
        maps:get(capacity, Item, 0), maps:get(reactor, Item, false)),
    lists:all(
      fun(Build) ->
          case build_fits(Build, NormalPols, AuraPol, ExilusPol, BaseCap) of
              {ok, _Used, _Assignments} -> true;
              _ -> false
          end
      end,
      Builds).

-doc "Map a valid plan to build/mod labels assigned to each slot.".
-spec for_plan(config(), plan()) -> {ok, slot_assignments()} | {error, term()}.
for_plan(#{item := Item, builds := Builds}, Plan) ->
    {NormalPols, AuraPol, ExilusPol} = plan_polarities(Plan, Item),
    BaseCap = wfcli_forma_model:apply_reactor(
        maps:get(capacity, Item, 0), maps:get(reactor, Item, false)),
    lists:foldl(
      fun(Build, {ok, MapAcc}) ->
              case build_fits(Build, NormalPols, AuraPol, ExilusPol, BaseCap) of
                  {ok, _Used, Assignments} ->
                      {ok, add_assignments(Assignments, MapAcc)};
                  {error, Reason} ->
                      {error, Reason}
              end;
         (_Build, {error, _} = Error) ->
              Error
      end,
      {ok, #{}},
      Builds);
for_plan(_, _) ->
    {error, invalid_config}.

plan_polarities(Plan, Item) ->
    ItemSlots = maps:get(slots, Item, []),
    AuraPol = maps:get(aura, Plan, maps:get(aura_slot, Item, none)),
    ExilusPol = maps:get(exilus, Plan, maps:get(exilus_slot, Item, none)),
    NormalPols =
        [maps:get(I, Plan, safe_nth(I, ItemSlots, none))
         || I <- lists:seq(1, length(ItemSlots))],
    {NormalPols, AuraPol, ExilusPol}.

build_fits(#{mods := Mods, name := BuildName}, NormalPols, AuraPol, ExilusPol, BaseCap) ->
    AuraMods = [M || M = #{slot := aura} <- Mods],
    AuraGain = lists:sum(
        [wfcli_forma_model:aura_value(
             maps:get(polarity, M), AuraPol, maps:get(cost, M))
         || M <- AuraMods]),
    Cap = BaseCap + AuraGain,
    ExilusMods = [M || M = #{slot := exilus} <- Mods],
    ExilusCost = lists:sum(
        [wfcli_forma_model:mod_cost(
             maps:get(polarity, M), ExilusPol, maps:get(cost, M))
         || M <- ExilusMods]),
    NormalMods = [M || M <- Mods, allow_normal_slot(M)],
    NormalCostEntries = [normal_slot_costs(BuildName, M, NormalPols) || M <- NormalMods],
    case lists:any(fun(Entry) -> Entry =:= {error, invalid_slot} end, NormalCostEntries) of
        true ->
            {error, invalid_slot};
        false ->
            SlotCosts = [Entry || {ok, Entry} <- NormalCostEntries],
            case assign_mods(prepare_entries(SlotCosts), lists:seq(1, length(NormalPols))) of
                {ok, UsedCost, Assignments} ->
                    TotalCost = UsedCost + ExilusCost,
                    case TotalCost =< Cap of
                        true ->
                            {ok, TotalCost,
                             append_special_assignments(
                                 BuildName, AuraMods, ExilusMods, Assignments)};
                        false ->
                            {error, capacity}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end
    end.

allow_normal_slot(#{slot := Slot}) when is_integer(Slot), Slot > 0 -> true;
allow_normal_slot(#{slot := Slot}) when Slot =:= undefined; Slot =:= none; Slot =:= normal -> true;
allow_normal_slot(_) -> false.

normal_slot_costs(BuildName,
                  #{slot := Slot, polarity := Polarity, cost := Cost, name := ModName},
                  NormalPols)
  when is_integer(Slot), Slot > 0 ->
    case Slot > length(NormalPols) of
        true ->
            {error, invalid_slot};
        false ->
            SlotPolarity = safe_nth(Slot, NormalPols, none),
            {ok, #{label => {BuildName, ModName},
                   slot_costs =>
                       [{Slot, wfcli_forma_model:mod_cost(
                                   Polarity, SlotPolarity, Cost)}]}}
    end;
normal_slot_costs(BuildName, #{polarity := Polarity, cost := Cost, name := ModName},
                  NormalPols) ->
    SlotCosts =
        [{Index, wfcli_forma_model:mod_cost(Polarity, SlotPolarity, Cost)}
         || {Index, SlotPolarity} <-
                lists:zip(lists:seq(1, length(NormalPols)), NormalPols)],
    {ok, #{label => {BuildName, ModName}, slot_costs => SlotCosts}}.

prepare_entries(SlotCosts) ->
    Entries =
        [#{id => Id,
           label => maps:get(label, Entry),
           slot_costs => sort_slot_costs(maps:get(slot_costs, Entry, []))}
         || {Id, Entry} <- lists:zip(lists:seq(1, length(SlotCosts)), SlotCosts)],
    lists:sort(fun entry_order/2, Entries).

entry_order(A, B) ->
    ACosts = maps:get(slot_costs, A, []),
    BCosts = maps:get(slot_costs, B, []),
    case length(ACosts) =/= length(BCosts) of
        true -> length(ACosts) < length(BCosts);
        false -> min_cost(ACosts) > min_cost(BCosts)
    end.

min_cost([]) -> 0;
min_cost(SlotCosts) ->
    lists:min([Cost || {_Slot, Cost} <- SlotCosts]).

sort_slot_costs(SlotCosts) ->
    lists:sort(fun({_, CostA}, {_, CostB}) -> CostA =< CostB end, SlotCosts).

assign_mods(Entries, SlotsAvail) ->
    {Result, _Memo} = assign_mods(Entries, SlotsAvail, #{}),
    Result.

assign_mods([], _SlotsAvail, Memo) ->
    {{ok, 0, []}, Memo};
assign_mods(Entries, SlotsAvail, Memo) ->
    Key = {entry_ids(Entries), SlotsAvail},
    case maps:get(Key, Memo, undefined) of
        undefined ->
            {Result, Memo1} = assign_mods_uncached(Entries, SlotsAvail, Memo),
            {Result, maps:put(Key, Result, Memo1)};
        Cached ->
            {Cached, Memo}
    end.

assign_mods_uncached([Entry | Rest], SlotsAvail, Memo) ->
    SlotCosts = maps:get(slot_costs, Entry, []),
    Label = maps:get(label, Entry),
    Allowed = [SlotCost || SlotCost = {Slot, _} <- SlotCosts,
                           lists:member(Slot, SlotsAvail)],
    case Allowed of
        [] ->
            {{error, no_slot}, Memo};
        _ ->
            {Best, MemoOut} =
                lists:foldl(
                  fun({Slot, Cost}, {BestAcc, MemoAcc}) ->
                      {Child, MemoNext} =
                          assign_mods(Rest, lists:delete(Slot, SlotsAvail), MemoAcc),
                      Next =
                          case Child of
                              {ok, ChildCost, Assignments} ->
                                  update_best(
                                      {ChildCost + Cost,
                                       [{Slot, Label} | Assignments]},
                                      BestAcc);
                              {error, _} ->
                                  BestAcc
                          end,
                      {Next, MemoNext}
                  end,
                  {undefined, Memo},
                  Allowed),
            case Best of
                undefined -> {{error, no_slot}, MemoOut};
                {BestCost, Assignments} ->
                    {{ok, BestCost, Assignments}, MemoOut}
            end
    end.

entry_ids(Entries) ->
    [maps:get(id, Entry, 0) || Entry <- Entries].

update_best({Cost, Assignments}, undefined) ->
    {Cost, Assignments};
update_best({Cost, _Assignments}, {BestCost, _} = Best) when Cost >= BestCost ->
    Best;
update_best({Cost, Assignments}, _Best) ->
    {Cost, Assignments}.

append_special_assignments(BuildName, AuraMods, ExilusMods, Assignments) ->
    Aura = [{aura, {BuildName, maps:get(name, Mod)}} || Mod <- AuraMods],
    Exilus = [{exilus, {BuildName, maps:get(name, Mod)}} || Mod <- ExilusMods],
    Assignments ++ Aura ++ Exilus.

add_assignments([], Map) ->
    Map;
add_assignments([{Slot, Label} | Rest], Map) ->
    Updated = maps:update_with(Slot, fun(List) -> [Label | List] end, [Label], Map),
    add_assignments(Rest, Updated).

safe_nth(N, List, Default) when is_integer(N), N > 0 ->
    case lists:nthtail(N - 1, List) of
        [Value | _] -> Value;
        [] -> Default;
        _ -> Default
    end;
safe_nth(_, _, Default) ->
    Default.
