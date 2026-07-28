%%%-------------------------------------------------------------------
%% Forma plan validity, cost, and current-polarity accounting.
%%%-------------------------------------------------------------------
-module(wfcli_forma_rules).

-export([validate/2, cost/3, current_plan/1, current_polarity/2,
         slot_change_count/2, reuse_count/2, removal_cost/2]).

-type plan() :: map().

-doc "Validate capacity and Forma budget for a concrete plan.".
-spec validate(plan(), map()) -> {ok, non_neg_integer()} | {error, term()}.
validate(Plan, #{item := Item, builds := Builds, flags := Flags}) ->
    Cost = cost(Plan, Item, Flags),
    case maps:get(max_forma, Flags, undefined) of
        Max when is_integer(Max), Max >= 0, Cost > Max ->
            {error, over_budget};
        _ ->
            case wfcli_forma_assignment:fits_all(Plan, Item, Builds) of
                true -> {ok, Cost};
                false -> {error, capacity}
            end
    end.

-doc "Return Forma cost for changing current item polarities to target plan.".
-spec cost(plan(), map(), map()) -> non_neg_integer().
cost(Plan, Item, Flags) ->
    AllowUmbral = maps:get(allow_umbral_forma, Flags, false),
    Targets = maps:to_list(Plan),
    {AppliedCost, _Remaining} = cost_from_targets(Targets, AllowUmbral, current_pool(Item)),
    AppliedCost + removal_cost(Targets, Item).

-doc "Return current item polarities as a complete plan map.".
-spec current_plan(map()) -> plan().
current_plan(Item) ->
    Slots = maps:get(slots, Item, []),
    Normal =
        maps:from_list(lists:zip(lists:seq(1, length(Slots)), Slots)),
    Normal#{aura => maps:get(aura_slot, Item, none),
            exilus => maps:get(exilus_slot, Item, none)}.

-doc "Return current polarity for one item slot.".
-spec current_polarity(term(), map()) -> term().
current_polarity(aura, Item) ->
    maps:get(aura_slot, Item, none);
current_polarity(exilus, Item) ->
    maps:get(exilus_slot, Item, none);
current_polarity(Index, Item) when is_integer(Index), Index > 0 ->
    safe_nth(Index, maps:get(slots, Item, []), none);
current_polarity(_, _) ->
    none.

-doc "Count plan slots whose target differs from current polarity.".
-spec slot_change_count(plan(), map()) -> non_neg_integer().
slot_change_count(Plan, Item) ->
    length(
      [changed || {Slot, Polarity} <- maps:to_list(Plan),
                  Polarity =/= current_polarity(Slot, Item)]).

-doc "Count target polarities reusable from existing slots.".
-spec reuse_count(plan(), map()) -> non_neg_integer().
reuse_count(Plan, Item) ->
    Targets = [Polarity || {_Slot, Polarity} <- maps:to_list(Plan),
                           Polarity =/= none],
    reuse_count(Targets, current_pool(Item), 0).

-doc "Count Forma needed to remove existing polarities targeted as none.".
-spec removal_cost([{term(), term()}] | plan(), map()) -> non_neg_integer().
removal_cost(Plan, Item) when is_map(Plan) ->
    removal_cost(maps:to_list(Plan), Item);
removal_cost(Targets, Item) ->
    lists:sum(
      [wfcli_forma_model:forma_cost(Current)
       || {Slot, none} <- Targets,
          Current <- [current_polarity(Slot, Item)],
          Current =/= none]).

cost_from_targets([], _AllowUmbral, Current) ->
    {0, Current};
cost_from_targets([{_Slot, none} | Rest], AllowUmbral, Current) ->
    cost_from_targets(Rest, AllowUmbral, Current);
cost_from_targets([{_Slot, Target} | Rest], AllowUmbral, Current) ->
    case take_polarity(Target, Current, AllowUmbral) of
        {ok, Remaining} ->
            cost_from_targets(Rest, AllowUmbral, Remaining);
        {apply, Cost, Remaining} ->
            {RestCost, Final} = cost_from_targets(Rest, AllowUmbral, Remaining),
            {Cost + RestCost, Final};
        {error, Cost} ->
            {Cost, Current}
    end.

take_polarity(umbral, Current, false) ->
    case consume(umbral, Current) of
        {ok, Remaining} -> {ok, Remaining};
        error -> {error, 99999}
    end;
take_polarity(Target, Current, _AllowUmbral) ->
    case consume(Target, Current) of
        {ok, Remaining} ->
            {ok, Remaining};
        error ->
            {apply, wfcli_forma_model:forma_cost(Target), Current}
    end.

reuse_count([], _Current, Count) ->
    Count;
reuse_count([Target | Rest], Current, Count) ->
    case consume(Target, Current) of
        {ok, Remaining} -> reuse_count(Rest, Remaining, Count + 1);
        error -> reuse_count(Rest, Current, Count)
    end.

consume(_Polarity, []) ->
    error;
consume(Polarity, [Polarity | Rest]) ->
    {ok, Rest};
consume(Polarity, [Head | Rest]) ->
    case consume(Polarity, Rest) of
        {ok, Remaining} -> {ok, [Head | Remaining]};
        error -> error
    end.

current_pool(Item) ->
    Current = [maps:get(aura_slot, Item, none),
               maps:get(exilus_slot, Item, none)
               | maps:get(slots, Item, [])],
    [Polarity || Polarity <- Current, Polarity =/= none].

safe_nth(N, List, Default) when is_integer(N), N > 0 ->
    case lists:nthtail(N - 1, List) of
        [Value | _] -> Value;
        [] -> Default;
        _ -> Default
    end;
safe_nth(_, _, Default) ->
    Default.
