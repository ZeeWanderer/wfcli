-module(wfcli_player_views_eunit).

-include_lib("eunit/include/eunit.hrl").

inventory_and_mastery_join_test() ->
    Relic = <<"/Lotus/Types/Game/Projections/T1Test">>,
    Chassis = <<"/Lotus/Types/Recipes/TestPrimeChassis">>,
    Systems = <<"/Lotus/Types/Recipes/TestPrimeSystems">>,
    Frame = <<"/Lotus/Powersuits/TestPrime/TestPrime">>,
    Snapshot = #{revision => 7, updated_at => 100,
                 data => #{<<"inventory">> => #{
                     <<"profile">> => #{<<"player_level">> => 18},
                     <<"index">> => #{
                         <<"equipment">> => [entry(Frame, 1, 100000)],
                         <<"stacks">> => [entry(Relic, 2, 0), entry(Chassis, 1, 0)],
                         <<"mastery">> => [entry(Frame, 1, 100000)],
                         <<"pending_recipes">> => [],
                         <<"missions">> => [
                             #{<<"Tag">> => <<"EarthNode">>,
                               <<"Completes">> => 1, <<"Tier">> => 1},
                             #{<<"Tag">> => <<"EarthToVenusJunction">>,
                               <<"Completes">> => 2, <<"Tier">> => 1}],
                         <<"player_skills">> => #{
                             <<"LPS_PILOTING">> => 7,
                             <<"LPS_GUNNERY">> => 8,
                             <<"LPS_DRIFT_RIDING">> => 9}
                     }}}},
    Drop = #{<<"location">> => <<"Lith T1 Relic (Intact)">>,
             <<"uniqueName">> => Relic},
    Catalog = [
        #{<<"uniqueName">> => Frame, <<"name">> => <<"Test Prime">>,
          <<"category">> => <<"Warframes">>, <<"masterable">> => true,
          <<"imageName">> => <<"test.png">>,
          <<"components">> => [
              #{<<"uniqueName">> => Chassis, <<"name">> => <<"Chassis">>,
                <<"itemCount">> => 1, <<"tradable">> => true,
                <<"drops">> => [Drop]},
              #{<<"uniqueName">> => Systems, <<"name">> => <<"Systems">>,
                <<"itemCount">> => 1, <<"tradable">> => true,
                <<"drops">> => [Drop]}
          ]},
        #{<<"uniqueName">> => Relic, <<"name">> => <<"Lith T1 Relic">>,
          <<"category">> => <<"Relics">>, <<"masterable">> => false,
          <<"components">> => []}
    ],

    {ok, Inventory} = wfcli_player_views:inventory(Snapshot, Catalog),
    InventoryItems = maps:get(<<"items">>, Inventory),
    ?assertEqual(3, length(InventoryItems)),
    ?assertEqual([<<"parts">>, <<"relics">>, <<"sets">>],
                 lists:sort([maps:get(<<"group">>, Item) || Item <- InventoryItems])),
    [Part] = [Item || Item <- InventoryItems,
                     maps:get(<<"group">>, Item) =:= <<"parts">>],
    ?assertEqual(<<"Test Prime Chassis">>, maps:get(<<"name">>, Part)),

    {ok, Foundry} = wfcli_player_views:foundry(Snapshot, Catalog),
    [FoundryItem] = maps:get(<<"items">>, Foundry),
    ?assertEqual(<<"warframe">>, maps:get(<<"group">>, FoundryItem)),
    ?assertEqual(false, maps:get(<<"ready_to_build">>, FoundryItem)),
    ?assertEqual(1, maps:get(<<"components_owned">>, FoundryItem)),

    {ok, Mastery} = wfcli_player_views:mastery(Snapshot, Catalog),
    [MasteryItem] = maps:get(<<"items">>, Mastery),
    ?assertEqual(10, maps:get(<<"rank">>, MasteryItem)),
    ?assertEqual(4000, maps:get(<<"potential_xp">>, MasteryItem)),
    ?assert(maps:get(<<"from_relics">>, MasteryItem)),
    ?assert(maps:get(<<"buyable">>, MasteryItem)),
    Summary = maps:get(<<"summary">>, Mastery),
    ?assertEqual(18, maps:get(<<"player_level">>, Summary)),
    Intrinsics = maps:get(<<"intrinsics">>, Summary),
    ?assertEqual(15, maps:get(<<"current">>, maps:get(<<"railjack">>, Intrinsics))),
    ?assertEqual(9, maps:get(<<"current">>, maps:get(<<"duviri">>, Intrinsics))),
    StarChart = maps:get(<<"star_chart">>, Summary),
    ?assertEqual(1, maps:get(<<"current">>, maps:get(<<"normal">>, StarChart))),
    ?assertEqual(1, maps:get(<<"current">>, maps:get(<<"junctions">>, StarChart))).

item_catalog_compaction_test() ->
    Item = #{<<"uniqueName">> => <<"/Lotus/Test">>,
             <<"name">> => <<"Test">>, <<"noise">> => true,
             <<"components">> => [
                 #{<<"uniqueName">> => <<"/Lotus/TestPart">>,
                   <<"name">> => <<"Part">>,
                   <<"drops">> => [
                       #{<<"location">> => <<"Lith T1 Relic (Radiant)">>,
                         <<"uniqueName">> => <<"/Lotus/Relic">>,
                         <<"chance">> => 10, <<"noise">> => true},
                       #{<<"location">> => <<"Enemy Drop">>,
                         <<"uniqueName">> => <<"/Lotus/Enemy">>}
                   ]}
             ]},
    Compact = wfcli_item_catalog:compact(Item),
    ?assertNot(maps:is_key(<<"noise">>, Compact)),
    [Component] = maps:get(<<"components">>, Compact),
    [Drop] = maps:get(<<"drops">>, Component),
    ?assertEqual(<<"/Lotus/Relic">>, maps:get(<<"uniqueName">>, Drop)).

entry(Type, Count, Xp) ->
    #{<<"item_type">> => Type, <<"count">> => Count, <<"xp">> => Xp}.
