%%%-------------------------------------------------------------------
%% EUnit coverage for build-group to Forma conversion.
%%%-------------------------------------------------------------------
-module(wfcli_build_plan_eunit).

-include_lib("eunit/include/eunit.hrl").

group_conversion_keeps_config_and_instance_state_separate_test() ->
    Group = group(),
    {ok, Request} = wfcli_build_plan:request(Group),
    [Raw] = maps:get(config_data, Request),
    ?assertNot(maps:is_key(<<"shard_slots">>, maps:get(item, Raw))),
    [Player, Source] = maps:get(builds, Raw),
    ?assertEqual([<<"/ability/roar">>],
                 maps:get(<<"ability_override">>, Player)),
    ?assertEqual([#{<<"name">> => <<"Arcane Energize">>, <<"rank">> => 5}],
                 maps:get(<<"arcanes">>, Player)),
    [SourceMod] = maps:get(<<"mods">>, Source),
    ?assertEqual(<<"vazarin">>, maps:get(<<"polarity">>, SourceMod)),
    ?assertEqual(8, maps:get(<<"cost">>, SourceMod)),
    {ok, FormaReply} = wfcli_forma_service:plan_request(Request),
    {ok, Result} = wfcli_build_plan:result(Group, {ok, FormaReply}),
    ?assertEqual(<<"ready">>, maps:get(<<"status">>, Result)),
    ?assertEqual(maps:get(<<"shard_slots">>, maps:get(<<"baseline">>, Group)),
                 maps:get(<<"shard_slots">>, Result)),
    [PlayerResult, _SourceResult] = maps:get(<<"builds">>, Result),
    ?assertEqual([<<"/ability/roar">>],
                 maps:get(<<"ability_override">>, PlayerResult)).

planning_requires_concrete_instance_and_members_test() ->
    ?assertEqual({error, build_group_instance_required},
                 wfcli_build_plan:request((group())#{<<"baseline">> => null})),
    ?assertEqual({error, build_group_members_required},
                 wfcli_build_plan:request((group())#{<<"members">> => []})).

group() ->
    #{<<"id">> => <<"group-1">>, <<"revision">> => 4,
      <<"options">> => #{<<"preserve_source_slots">> => true,
                           <<"allow_omni">> => false,
                           <<"allow_umbral_forma">> => false},
      <<"baseline">> => baseline(),
      <<"members">> => [player_member(), source_member()]}.

baseline() ->
    #{<<"instance_id">> => <<"copy-1">>,
      <<"definition_id">> => <<"/warframe">>,
      <<"class">> => <<"warframe">>, <<"capacity">> => 30,
      <<"features">> => #{<<"double_capacity">> => true},
      <<"effective_polarities">> =>
          [#{<<"slot_id">> => <<"mod-1">>, <<"player_index">> => 7,
             <<"polarity">> => <<"madurai">>},
           #{<<"slot_id">> => <<"mod-2">>, <<"player_index">> => 6,
             <<"polarity">> => <<"none">>},
           #{<<"slot_id">> => <<"aura">>, <<"player_index">> => 8,
             <<"polarity">> => <<"madurai">>}],
      <<"shard_slots">> =>
          [#{<<"slot_id">> => <<"shard-1">>,
             <<"upgrade">> => #{<<"upgrade_type">> => <<"crimson">>}}],
      <<"topology">> =>
          #{<<"regions">> =>
                [#{<<"slots">> =>
                       [slot(<<"aura">>, 8, 9, <<"aura">>, true),
                        slot(<<"exilus">>, 9, 10, <<"exilus">>, true)]},
                 #{<<"slots">> =>
                       [slot(<<"mod-1">>, 7, 1, <<"mod">>, true),
                        slot(<<"mod-2">>, 6, 2, <<"mod">>, true)]},
                 #{<<"slots">> =>
                       [slot(<<"arcane-1">>, 10, 11, <<"arcane">>, false)]}]}}.

slot(Id, Index, External, Role, Planner) ->
    #{<<"id">> => Id, <<"player_index">> => Index,
      <<"build_slot">> => External, <<"role">> => Role,
      <<"label">> => Id, <<"planner">> => Planner}.

player_member() ->
    #{<<"id">> => <<"config:1">>, <<"kind">> => <<"player_config">>,
      <<"name">> => <<"Roar config">>,
      <<"snapshot">> =>
          #{<<"config">> =>
                #{<<"ability_override">> => [<<"/ability/roar">>],
                  <<"upgrade_slots">> =>
                      [#{<<"slot">> => 7, <<"name">> => <<"Vitality">>,
                         <<"polarity">> => <<"vazarin">>, <<"base_drain">> => 2,
                         <<"rank">> => 6},
                       #{<<"slot">> => 10, <<"name">> => <<"Arcane Energize">>,
                         <<"role">> => <<"arcane">>, <<"rank">> => 5}]}}}.

source_member() ->
    #{<<"id">> => <<"source:1">>, <<"kind">> => <<"source_revision">>,
      <<"name">> => <<"Source build">>,
      <<"snapshot">> =>
          #{<<"content">> =>
                #{<<"slots">> =>
                      [#{<<"source_slot">> => 2, <<"name">> => <<"Redirection">>,
                         <<"kind">> => <<"mod">>,
                         <<"mod_polarity">> => <<"vazarin">>,
                         <<"cost">> => 8, <<"rank">> => 5}]}}}.
