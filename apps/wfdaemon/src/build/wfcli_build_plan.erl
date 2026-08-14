%%%-------------------------------------------------------------------
%% Build-group adapter for the existing Forma planner.
%%%-------------------------------------------------------------------
-module(wfcli_build_plan).

-export([request/1, result/2]).

-define(SCHEMA, 1).

-doc "Convert one saved build group into an in-memory Forma request.".
-spec request(map()) -> {ok, map()} | {error, term()}.
request(#{<<"baseline">> := Baseline, <<"members">> := Members} = Group)
  when is_map(Baseline), is_list(Members), Members =/= [] ->
    Slots = planner_slots(maps:get(<<"topology">>, Baseline, #{})),
    case convert_members(Members, Slots,
                         maps:get(<<"options">>, Group, #{}), []) of
        {ok, Builds} ->
            Raw = #{file => <<"build-group:",
                                (maps:get(<<"id">>, Group, <<"unknown">>))/binary>>,
                    item => item(Baseline, Slots),
                    builds => Builds,
                    constraints => constraints(Group)},
            {ok, #{action => plan, config_data => [Raw], flags => #{}}};
        {error, _Reason} = Error -> Error
    end;
request(#{<<"baseline">> := Baseline}) when Baseline =:= null;
                                             Baseline =:= undefined ->
    {error, build_group_instance_required};
request(#{<<"members">> := []}) -> {error, build_group_members_required};
request(_Group) -> {error, invalid_build_group}.

-doc "Convert a Forma-service reply into a persisted protocol-safe group result.".
-spec result(map(), term()) -> {ok, map()} | {error, term()}.
result(Group, {ok, #{results := [{ok, Config, Plan, Cost}]}})
  when is_map(Config), is_map(Plan), is_integer(Cost) ->
    Baseline = maps:get(<<"baseline">>, Group),
    Slots = planner_slots(maps:get(<<"topology">>, Baseline, #{})),
    Final = final_layout(Slots, Baseline, Plan),
    {ok, (result_base(Group))#{
           <<"status">> => <<"ready">>,
           <<"forma_cost">> => Cost,
           <<"change_count">> => length(changes(Final)),
           <<"changes">> => changes(Final),
           <<"final_polarities">> => Final,
           <<"builds">> => result_builds(Config),
           <<"shard_slots">> => maps:get(<<"shard_slots">>, Baseline, [])}};
result(Group, {ok, #{results := [{error, _Config, Reason}]}}) ->
    {ok, (result_base(Group))#{<<"status">> => <<"blocked">>,
                              <<"reason">> => error_value(Reason)}};
result(_Group, {error, _Reason} = Error) -> Error;
result(_Group, Other) -> {error, {invalid_forma_reply, Other}}.

item(Baseline, Slots) ->
    Polarities = polarity_index(Baseline),
    Normal = [maps:get(maps:get(<<"id">>, Slot), Polarities, <<"none">>)
              || Slot <- maps:get(normal, Slots)],
    Topology = maps:get(<<"topology">>, Baseline, #{}),
    LayoutClass = maps:get(<<"layout_class">>, Topology,
                           maps:get(<<"class">>, Baseline, <<"other">>)),
    #{<<"type">> => planner_type(LayoutClass),
      <<"capacity">> => maps:get(<<"capacity">>, Baseline, 30),
      <<"reactor">> => maps:get(<<"double_capacity">>,
                                 maps:get(<<"features">>, Baseline, #{}), false),
      <<"aura_slot">> => special_polarity(aura, Slots, Polarities),
      <<"exilus_slot">> => special_polarity(exilus, Slots, Polarities),
      <<"slots">> => Normal}.

constraints(Group) ->
    Options = maps:get(<<"options">>, Group, #{}),
    maps:with([<<"allow_omni">>, <<"allow_umbral_forma">>,
               <<"prefer_omni">>, <<"max_forma">>], Options).

planner_slots(#{<<"regions">> := Regions}) when is_list(Regions) ->
    TopologySlots = [Slot || Region <- Regions,
                             Slot <- maps:get(<<"slots">>, Region, [])],
    All = [Slot || Slot <- TopologySlots,
                   maps:get(<<"planner">>, Slot, false) =:= true],
    Normal = [Slot || Slot <- All,
                      maps:get(<<"role">>, Slot, <<>>) =:= <<"mod">>],
    ByPlayer = maps:from_list(
                 [{maps:get(<<"player_index">>, Slot), Slot}
                  || Slot <- TopologySlots,
                     is_integer(maps:get(<<"player_index">>, Slot, undefined))]),
    ByBuild = maps:from_list(
                   [{build_slot(Slot), Slot}
                    || Slot <- TopologySlots,
                       is_integer(build_slot(Slot))]),
    NormalPosition = maps:from_list(
                       [{maps:get(<<"id">>, Slot), Position}
                        || {Position, Slot} <- lists:enumerate(1, Normal)]),
    #{all => All, normal => Normal, by_player => ByPlayer,
      by_build => ByBuild,
      normal_position => NormalPosition,
      aura => find_role([<<"aura">>, <<"stance">>], All),
      exilus => find_role([<<"exilus">>], All)};
planner_slots(_Topology) ->
    #{all => [], normal => [], by_player => #{}, by_build => #{},
      normal_position => #{},
      aura => undefined, exilus => undefined}.

build_slot(Slot) ->
    case maps:get(<<"build_slot">>, Slot, undefined) of
        Value when is_integer(Value) -> Value;
        _ -> case maps:get(<<"player_index">>, Slot, undefined) of
            Index when is_integer(Index) -> Index + 1;
            _ -> undefined
        end
    end.

find_role(Roles, Slots) ->
    case [Slot || Slot <- Slots,
                  lists:member(maps:get(<<"role">>, Slot, <<>>), Roles)] of
        [Slot | _] -> Slot;
        [] -> undefined
    end.

convert_members([], _Slots, _Options, Acc) -> {ok, lists:reverse(Acc)};
convert_members([Member | Rest], Slots, Options, Acc) ->
    case member_build(Member, Slots, Options) of
        {ok, Build} -> convert_members(Rest, Slots, Options, [Build | Acc]);
        {error, Reason} ->
            {error, {invalid_build_group_member,
                     maps:get(<<"id">>, Member, null), Reason}}
    end.

member_build(#{<<"kind">> := <<"player_config">>,
               <<"snapshot">> := #{<<"config">> := Config}} = Member,
             Slots, Options) ->
    build_from_slots(Member, maps:get(<<"upgrade_slots">>, Config, []),
                     maps:get(<<"ability_override">>, Config, []),
                     Slots, Options, player);
member_build(#{<<"kind">> := <<"source_revision">>,
               <<"snapshot">> := Revision} = Member, Slots, Options) ->
    Content = maps:get(<<"content">>, Revision, #{}),
    build_from_slots(Member, maps:get(<<"slots">>, Content, []),
                     maps:get(<<"ability_override">>, Content, []),
                     Slots, Options, source);
member_build(_Member, _Slots, _Options) -> {error, unsupported_member_kind}.

build_from_slots(Member, Upgrades, AbilityOverride, Slots, Options, Origin)
  when is_list(Upgrades) ->
    case convert_upgrades(Upgrades, Slots, Options, Origin, [], []) of
        {ok, Mods, Arcanes} ->
            {ok, #{<<"member_id">> => maps:get(<<"id">>, Member),
                   <<"name">> => maps:get(<<"name">>, Member, <<"Build">>),
                   <<"mods">> => Mods,
                   <<"arcanes">> => Arcanes,
                   <<"ability_override">> => AbilityOverride}};
        {error, _Reason} = Error -> Error
    end;
build_from_slots(_Member, _Upgrades, _AbilityOverride, _Slots, _Options, _Origin) ->
    {error, invalid_upgrade_slots}.

convert_upgrades([], _Slots, _Options, _Origin, Mods, Arcanes) ->
    {ok, lists:reverse(Mods), lists:reverse(Arcanes)};
convert_upgrades([Upgrade | Rest], Slots, Options, Origin, Mods, Arcanes)
  when is_map(Upgrade) ->
    case convert_upgrade(Upgrade, Slots, Options, Origin) of
        skip -> convert_upgrades(Rest, Slots, Options, Origin, Mods, Arcanes);
        {arcane, Arcane} ->
            convert_upgrades(Rest, Slots, Options, Origin, Mods,
                             [Arcane | Arcanes]);
        {mod, Mod} ->
            convert_upgrades(Rest, Slots, Options, Origin, [Mod | Mods],
                             Arcanes);
        {error, _Reason} = Error -> Error
    end;
convert_upgrades([_Upgrade | _Rest], _Slots, _Options, _Origin, _Mods, _Arcanes) ->
    {error, invalid_upgrade}.

convert_upgrade(Upgrade, Slots, Options, Origin) ->
    case upgrade_slot(Upgrade, Slots, Origin) of
        undefined -> {error, {unknown_source_slot, upgrade_binding(Upgrade, Origin)}};
        Slot ->
            Role = maps:get(<<"role">>, Slot, <<"unknown">>),
            Kind = maps:get(<<"kind">>, Upgrade, <<"mod">>),
            classify_upgrade(Role, Kind, Upgrade, Slot, Slots, Options, Origin)
    end.

classify_upgrade(<<"arcane">>, <<"arcane">>, Upgrade, _Slot, _Slots,
                 _Options, _Origin) -> arcane(Upgrade);
classify_upgrade(<<"arcane">>, _Kind, Upgrade, _Slot, _Slots,
                 _Options, player) -> arcane(Upgrade);
classify_upgrade(Role, <<"arcane">>, _Upgrade, Slot, _Slots, _Options, source) ->
    {error, {slot_role_conflict, maps:get(<<"id">>, Slot), Role, <<"arcane">>}};
classify_upgrade(<<"arcane">>, Kind, _Upgrade, Slot, _Slots, _Options, source) ->
    {error, {slot_role_conflict, maps:get(<<"id">>, Slot), <<"arcane">>, Kind}};
classify_upgrade(_Role, _Kind, Upgrade, Slot, Slots, Options, Origin) ->
    mod(Upgrade, Slot, Slots, Options, Origin).

upgrade_slot(Upgrade, Slots, player) ->
    maps:get(upgrade_binding(Upgrade, player), maps:get(by_player, Slots), undefined);
upgrade_slot(Upgrade, Slots, source) ->
    maps:get(upgrade_binding(Upgrade, source), maps:get(by_build, Slots), undefined).

upgrade_binding(Upgrade, player) -> maps:get(<<"slot">>, Upgrade, undefined);
upgrade_binding(Upgrade, source) -> maps:get(<<"source_slot">>, Upgrade, undefined).

arcane(Upgrade) ->
    case upgrade_name(Upgrade) of
        undefined -> {error, missing_arcane_name};
        Name ->
            Base = #{<<"name">> => Name},
            {arcane, optional(<<"rank">>, maps:get(<<"rank">>, Upgrade, undefined),
                              Base)}
    end.

mod(Upgrade, Slot, Slots, Options, Origin) ->
    Metadata = mod_metadata(Upgrade, Origin),
    Name = maps:get(name, Metadata, undefined),
    Polarity = maps:get(polarity, Metadata, undefined),
    Cost = maps:get(cost, Metadata, undefined),
    case {Name, Polarity, Cost} of
        {undefined, _, _} -> {error, missing_mod_name};
        {_, undefined, _} -> {error, {missing_mod_polarity, Name}};
        {_, _, undefined} -> {error, {missing_mod_cost, Name}};
        _ ->
            Base = #{<<"name">> => Name, <<"polarity">> => Polarity,
                     <<"cost">> => Cost},
            Preserve = maps:get(<<"preserve_source_slots">>, Options, true),
            {mod, case planner_slot(Slot, Slots, Preserve) of
                      undefined -> Base;
                      Target -> Base#{<<"slot">> => Target}
                  end}
    end.

mod_metadata(Upgrade, source) ->
    #{name => upgrade_name(Upgrade),
      polarity => non_null(maps:get(<<"mod_polarity">>, Upgrade, undefined)),
      cost => integer_or_undefined(maps:get(<<"cost">>, Upgrade, undefined))};
mod_metadata(Upgrade, player) ->
    Details = case wfcli_mod_catalog:details(
                     maps:get(<<"item_type">>, Upgrade, undefined)) of
        Value when is_map(Value) -> Value;
        _ -> #{}
    end,
    Rank = maps:get(<<"rank">>, Upgrade, 0),
    BaseDrain = first([maps:get(<<"base_drain">>, Upgrade, undefined),
                       maps:get(base_drain, Details, undefined)]),
    Polarity = first([maps:get(<<"polarity">>, Upgrade, undefined),
                      maps:get(polarity, Details, undefined)]),
    #{name => first([upgrade_name(Upgrade), maps:get(name, Details, undefined)]),
      polarity => non_null(Polarity),
      cost => ranked_cost(BaseDrain, Rank)}.

upgrade_name(Upgrade) -> non_null(maps:get(<<"name">>, Upgrade, undefined)).

ranked_cost(Base, Rank) when is_integer(Base), is_integer(Rank), Rank >= 0 ->
    abs(Base) + Rank;
ranked_cost(_Base, _Rank) -> undefined.

planner_slot(Slot, Slots, Preserve) ->
    case maps:get(<<"role">>, Slot, <<>>) of
        <<"aura">> -> <<"aura">>;
        <<"stance">> -> <<"stance">>;
        <<"exilus">> -> <<"exilus">>;
        <<"mod">> when Preserve ->
            maps:get(maps:get(<<"id">>, Slot), maps:get(normal_position, Slots));
        <<"mod">> -> undefined;
        _ -> undefined
    end.

polarity_index(Baseline) ->
    maps:from_list(
      [{maps:get(<<"slot_id">>, Entry), maps:get(<<"polarity">>, Entry, <<"none">>)}
       || Entry <- maps:get(<<"effective_polarities">>, Baseline, []),
          is_map(Entry), maps:is_key(<<"slot_id">>, Entry)]).

special_polarity(Key, Slots, Polarities) ->
    case maps:get(Key, Slots, undefined) of
        undefined -> <<"none">>;
        Slot -> maps:get(maps:get(<<"id">>, Slot), Polarities, <<"none">>)
    end.

planner_type(<<"warframe">>) -> <<"warframe">>;
planner_type(Class) when Class =:= <<"melee">>; Class =:= <<"archmelee">>;
                         Class =:= <<"exalted">> -> <<"melee">>;
planner_type(<<"companion">>) -> <<"companion">>;
planner_type(<<"necramech">>) -> <<"necramech">>;
planner_type(_Class) -> <<"weapon">>.

final_layout(Slots, Baseline, Plan) ->
    Current = polarity_index(Baseline),
    [begin
         Id = maps:get(<<"id">>, Slot),
         Before = maps:get(Id, Current, <<"none">>),
         Key = plan_key(Slot, Slots),
         After = polarity_binary(maps:get(Key, Plan, Before)),
         #{<<"slot_id">> => Id,
           <<"label">> => maps:get(<<"label">>, Slot, Id),
           <<"role">> => maps:get(<<"role">>, Slot, <<"unknown">>),
           <<"player_index">> => maps:get(<<"player_index">>, Slot, null),
           <<"before">> => Before, <<"polarity">> => After,
           <<"changed">> => Before =/= After}
     end || Slot <- maps:get(all, Slots)].

plan_key(Slot, Slots) ->
    case maps:get(<<"role">>, Slot, <<>>) of
        <<"aura">> -> aura;
        <<"stance">> -> aura;
        <<"exilus">> -> exilus;
        <<"mod">> -> maps:get(maps:get(<<"id">>, Slot),
                             maps:get(normal_position, Slots))
    end.

changes(Final) ->
    [maps:remove(<<"changed">>, Entry)
     || Entry <- Final, maps:get(<<"changed">>, Entry) =:= true].

result_builds(#{builds := Builds}) ->
    [#{<<"name">> => text(maps:get(name, Build, <<"Build">>)),
       <<"ability_override">> => [text(Value)
                                    || Value <- maps:get(ability_override, Build, [])],
       <<"arcanes">> => [arcane_result(Arcane)
                           || Arcane <- maps:get(arcanes, Build, [])]}
     || Build <- Builds].

arcane_result(Arcane) ->
    Base = #{<<"name">> => text(maps:get(name, Arcane, <<>>))},
    optional(<<"rank">>, maps:get(rank, Arcane, undefined), Base).

result_base(Group) ->
    #{<<"schema">> => ?SCHEMA,
      <<"group_id">> => maps:get(<<"id">>, Group),
      <<"group_revision">> => maps:get(<<"revision">>, Group),
      <<"generated_at">> => erlang:system_time(millisecond)}.

polarity_binary(Value) when is_atom(Value) -> atom_to_binary(Value);
polarity_binary(Value) when is_binary(Value) -> Value;
polarity_binary(Value) -> atom_to_binary(wfcli_polarity:normalize(Value)).

error_value(Value) when is_atom(Value) -> atom_to_binary(Value);
error_value(Value) when is_binary(Value) -> Value;
error_value(Value) -> text(Value).

integer_or_undefined(Value) when is_integer(Value) -> Value;
integer_or_undefined(_Value) -> undefined.

non_null(undefined) -> undefined;
non_null(null) -> undefined;
non_null(Value) -> Value.

first([undefined | Rest]) -> first(Rest);
first([null | Rest]) -> first(Rest);
first([Value | _Rest]) -> Value;
first([]) -> undefined.

optional(_Key, undefined, Map) -> Map;
optional(_Key, null, Map) -> Map;
optional(Key, Value, Map) -> Map#{Key => Value}.

text(Value) when is_binary(Value) -> Value;
text(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
text(Value) when is_atom(Value) -> atom_to_binary(Value);
text(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).
