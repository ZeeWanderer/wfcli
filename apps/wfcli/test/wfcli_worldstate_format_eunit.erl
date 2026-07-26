%%%-------------------------------------------------------------------
%% EUnit tests for worldstate formatting helpers.
%%%-------------------------------------------------------------------
-module(wfcli_worldstate_format_eunit).

-include_lib("eunit/include/eunit.hrl").

mission_type_map_test() ->
    Entry = #{type => fissure,
              data => #{<<"Modifier">> => <<"VoidT1">>,
                       <<"MissionType">> => <<"MT_EXCAVATE">>,
                       <<"Node">> => <<"SolNode144">>}},
    Row = wfcli_worldstate_projector:table_row_map(Entry, #{resolve_items => true}),
    ?assertEqual("Excavation", maps:get(mission, Row)).

sortie_resolution_test() ->
    Entry = #{type => sortie,
              name => <<"Sortie">>,
              data => #{<<"Boss">> => <<"SORTIE_BOSS_PHORID">>,
                        <<"Variants">> => [#{<<"missionType">> => <<"MT_EXCAVATE">>,
                                            <<"node">> => <<"SolNode144">>,
                                            <<"modifierType">> => <<"SORTIE_MODIFIER_EXIMUS">>}]}},
    Row = wfcli_worldstate_projector:table_row_map(Entry, #{resolve_items => true}),
    ?assertEqual("Phorid", maps:get(boss, Row)),
    ?assert(string:find(maps:get(modifiers, Row), "Eximus") =/= nomatch),
    ?assert(string:find(maps:get(stages, Row), "Excavation") =/= nomatch).

sortie_modifier_fallback_test() ->
    Entry = #{type => sortie,
              name => <<"Sortie">>,
              data => #{<<"Boss">> => <<"SORTIE_BOSS_PHORID">>,
                        <<"Variants">> => [#{<<"modifierType">> => <<"SORTIE_MODIFIER_UNKNOWN">>}]}},
    Row = wfcli_worldstate_projector:table_row_map(Entry, #{resolve_items => true}),
    ?assert(string:find(maps:get(modifiers, Row), "SORTIE_MODIFIER_UNKNOWN") =/= nomatch).

archimedea_projection_and_semantic_query_test() ->
    Data = #{
        <<"Type">> => <<"CT_LAB">>,
        <<"RandomSeed">> => 157125,
        <<"Missions">> => [#{
            <<"faction">> => <<"FC_MITW">>,
            <<"missionType">> => <<"MT_EXTERMINATION">>,
            <<"difficulties">> => [
                #{<<"type">> => <<"CD_NORMAL">>, <<"deviation">> => <<"FortifiedFoes">>,
                  <<"risks">> => [<<"ShieldedFoes">>]},
                #{<<"type">> => <<"CD_HARD">>, <<"deviation">> => <<"FortifiedFoes">>,
                  <<"risks">> => [<<"ShieldedFoes">>, <<"AntiMaterialWeapons">>]}
            ]
        }],
        <<"Variables">> => [<<"Knifestep">>]
    },
    Entry = wfcli_entity_worldstate:build(
              archimedea, "deep", "Deep Archimedea", Data, #{resolve_items => true}),
    Row = maps:get(row_map, Entry),
    ?assertEqual("Deep", maps:get(archimedea, Row)),
    ?assertEqual(157125, maps:get(seed, Row)),
    ?assert(string:find(maps:get(deviations, Row), "Sealed Armor") =/= nomatch),
    ?assert(string:find(maps:get(elite_risks, Row), "Commanding Culverins") =/= nomatch),
    ?assert(string:find(maps:get(modifier_details, Row), "Lose 2 Health") =/= nomatch),
    Parsed = wfcli_worldstate_query:parse(
               "archimedea=deep deviation~sealed elite-risk~culverin seed=157125"),
    ?assertEqual([], maps:get(errors, Parsed)),
    ?assert(wfcli_worldstate_query:match(Entry, Parsed)).
