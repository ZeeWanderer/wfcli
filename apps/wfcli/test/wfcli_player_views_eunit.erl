-module(wfcli_player_views_eunit).

-include_lib("eunit/include/eunit.hrl").

inventory_and_mastery_join_test() ->
    Relic = <<"/Lotus/Types/Game/Projections/T1Test">>,
    Chassis = <<"/Lotus/Types/Recipes/TestPrimeChassis">>,
    Systems = <<"/Lotus/Types/Recipes/TestPrimeSystems">>,
    Frame = <<"/Lotus/Powersuits/TestPrime/TestPrime">>,
    Snapshot = #{revision => 7, updated_at => 100,
                 data => #{<<"inventory">> => #{
                     <<"profile">> => #{<<"player_name">> => <<"TestTenno">>,
                                        <<"player_level">> => 4},
                     <<"raw">> => #{<<"InfestedFoundry">> => #{
                         <<"ConsumedSuits">> => [#{<<"s">> => Frame}]
                     }},
                     <<"index">> => #{
                         <<"equipment">> => [entry(Frame, 1, 100000)],
                         <<"stacks">> => [entry(Relic, 2, 0), entry(Chassis, 1, 0)],
                         <<"mastery">> => [entry(Frame, 1, 100000)],
                         <<"pending_recipes">> => [],
                         <<"missions">> => [
                             #{<<"Tag">> => <<"EarthNode">>,
                               <<"Completes">> => 1, <<"Tier">> => 1},
                             #{<<"Tag">> => <<"EventNode">>,
                               <<"Completes">> => 1, <<"Tier">> => 1},
                             #{<<"Tag">> => <<"EarthToVenusJunction">>,
                               <<"Completes">> => 2, <<"Tier">> => 1}],
                         <<"player_skills">> => #{
                             <<"LPS_PILOTING">> => 7,
                             <<"LPS_GUNNERY">> => 8,
                             <<"LPS_DRIFT_RIDING">> => 9}
                     }}}},
    Drop = #{<<"location">> => <<"Lith T1 Relic (Intact)">>,
             <<"uniqueName">> => Relic, <<"chance">> => 25},
    Catalog = [
        #{<<"uniqueName">> => Frame, <<"name">> => <<"Test Prime">>,
          <<"category">> => <<"Warframes">>, <<"masterable">> => true,
          <<"isPrime">> => true, <<"vaulted">> => true,
          <<"imageName">> => <<"test.png">>,
          <<"components">> => [
              #{<<"uniqueName">> => Chassis, <<"name">> => <<"Chassis">>,
                <<"itemCount">> => 1, <<"tradable">> => true,
                <<"drops">> => [Drop]},
              #{<<"uniqueName">> => Systems, <<"name">> => <<"Systems">>,
                <<"itemCount">> => 1, <<"tradable">> => true,
                <<"drops">> => [Drop]}
          ]},
        #{<<"uniqueName">> => Relic, <<"name">> => <<"Lith T1 Intact">>,
          <<"category">> => <<"Relics">>, <<"masterable">> => false,
          <<"tradable">> => true,
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
    ?assertEqual(<<"Test Prime Chassis Blueprint">>,
                 maps:get(<<"market_name">>, Part)),
    ?assertEqual(true, maps:get(<<"is_prime">>, Part)),
    ?assertEqual(true, maps:get(<<"vaulted">>, Part)),
    [Set] = [Item || Item <- InventoryItems,
                    maps:get(<<"group">>, Item) =:= <<"sets">>],
    ?assertEqual(true, maps:get(<<"is_prime">>, Set)),
    ?assertEqual(true, maps:get(<<"vaulted">>, Set)),
    ?assertEqual(0, maps:get(<<"quantity">>, Set)),
    ?assertEqual(<<"Test Prime Set">>, maps:get(<<"market_name">>, Set)),
    [RelicItem] = [Item || Item <- InventoryItems,
                           maps:get(<<"group">>, Item) =:= <<"relics">>],
    ?assertEqual(<<"Lith T1 Intact">>, maps:get(<<"name">>, RelicItem)),
    ?assertEqual(<<"Lith T1 Relic">>, maps:get(<<"market_name">>, RelicItem)),

    {ok, Foundry} = wfcli_player_views:foundry(Snapshot, Catalog),
    [FoundryItem] = maps:get(<<"items">>, Foundry),
    ?assertEqual(<<"warframe">>, maps:get(<<"group">>, FoundryItem)),
    ?assertEqual(true, maps:get(<<"vaulted">>, FoundryItem)),
    ?assertEqual(true, maps:get(<<"subsumed">>, FoundryItem)),
    ?assertEqual(false, maps:get(<<"ready_to_build">>, FoundryItem)),
    ?assertEqual(1, maps:get(<<"components_owned">>, FoundryItem)),
    [ChassisComponent] =
        [Component || Component <- maps:get(<<"components">>, FoundryItem),
                      maps:get(<<"id">>, Component) =:= Chassis],
    ?assertEqual(true, maps:get(<<"owned_relic">>, ChassisComponent)),
    ?assertEqual(<<"Test Prime Chassis Blueprint">>,
                 maps:get(<<"market_name">>, ChassisComponent)),
    ?assertEqual(true, maps:get(<<"market_required">>, ChassisComponent)),

    StarChartMetadata = #{nodes => #{<<"EarthNode">> => 51},
                          junctions => #{<<"EarthToVenusJunction">> => true}},
    {ok, Mastery} = wfcli_player_views:mastery(
                      Snapshot, Catalog, StarChartMetadata),
    [MasteryItem] = maps:get(<<"items">>, Mastery),
    ?assertEqual(10, maps:get(<<"rank">>, MasteryItem)),
    ?assertEqual(4000, maps:get(<<"potential_xp">>, MasteryItem)),
    ?assert(abs(maps:get(<<"relic_probability">>, MasteryItem) - 0.4375) < 0.0001),
    ?assert(maps:get(<<"from_relics">>, MasteryItem)),
    ?assert(maps:get(<<"buyable">>, MasteryItem)),
    ?assert(maps:get(<<"has_recipe">>, MasteryItem)),
    Summary = maps:get(<<"summary">>, Mastery),
    Profile = maps:get(<<"profile">>, Mastery),
    ?assertEqual(<<"TestTenno">>,
                 maps:get(<<"player_name">>, Profile)),
    ?assertEqual(
       #{<<"id">> => <<"mastery-rank:4">>,
         <<"source">> => <<"mastery">>,
         <<"image_name">> => <<"4.webp">>},
       maps:get(<<"rank_asset">>, Profile)),
    ?assertEqual(<<"TestTenno">>, maps:get(<<"player_name">>, Summary)),
    ?assertEqual(4, maps:get(<<"player_level">>, Summary)),
    RankProgress = maps:get(<<"rank_progress">>, Summary),
    ?assertEqual(true, maps:get(<<"available">>, RankProgress)),
    ?assertEqual(102, maps:get(<<"current">>, RankProgress)),
    ?assertEqual(22500, maps:get(<<"total">>, RankProgress)),
    ?assertEqual(0, maps:get(<<"percent">>, maps:get(<<"warframes">>, Summary))),
    Intrinsics = maps:get(<<"intrinsics">>, Summary),
    ?assertEqual(15, maps:get(<<"current">>, maps:get(<<"railjack">>, Intrinsics))),
    ?assertEqual(9, maps:get(<<"current">>, maps:get(<<"duviri">>, Intrinsics))),
    StarChart = maps:get(<<"star_chart">>, Summary),
    ?assertEqual(1, maps:get(<<"current">>, maps:get(<<"normal">>, StarChart))),
    ?assertEqual(1, maps:get(<<"total">>, maps:get(<<"normal">>, StarChart))),
    ?assertEqual(1, maps:get(<<"current">>, maps:get(<<"junctions">>, StarChart))),
    ?assertEqual(1, maps:get(<<"total">>, maps:get(<<"junctions">>, StarChart))),
    ?assertEqual(100, maps:get(<<"percent">>, StarChart)).

inventory_preserves_unknown_vault_state_test() ->
    Parent = <<"/Lotus/Weapons/Test/TestPrime">>,
    Part = <<"/Lotus/Weapons/Test/TestPrimeBarrel">>,
    Snapshot = #{data => #{<<"inventory">> => #{<<"index">> => #{
        <<"stacks">> => [entry(Part, 1, 0)], <<"mastery">> => []}}}},
    Catalog = [#{<<"uniqueName">> => Parent, <<"name">> => <<"Test Prime">>,
                 <<"category">> => <<"Primary">>, <<"isPrime">> => true,
                 <<"components">> => [
                     #{<<"uniqueName">> => Part, <<"name">> => <<"Barrel">>,
                       <<"tradable">> => true}]}],
    {ok, Inventory} = wfcli_player_views:inventory(Snapshot, Catalog),
    [Item] = maps:get(<<"items">>, Inventory),
    ?assertEqual(true, maps:get(<<"is_prime">>, Item)),
    ?assertEqual(null, maps:get(<<"vaulted">>, Item)).

star_chart_compaction_test() ->
    Regions = #{
        <<"SolNode1">> => #{<<"masteryExp">> => 51},
        <<"EventNode">> => #{<<"masteryExp">> => 0},
        <<"EarthToVenusJunction">> => #{<<"masteryExp">> => 0},
        <<"NotAJunction">> => #{<<"masteryExp">> => 0}},
    Chart = wfcli_star_chart:compact(Regions),
    ?assertEqual(#{<<"SolNode1">> => 51}, maps:get(nodes, Chart)),
    ?assertEqual(#{<<"EarthToVenusJunction">> => true},
                 maps:get(junctions, Chart)).

mastery_market_names_test() ->
    Parent = <<"/Lotus/Weapons/Test/AklexPrime">>,
    Weapon = <<"/Lotus/Weapons/Test/LexPrime">>,
    Cell = <<"/Lotus/Types/Items/MiscItems/OrokinCell">>,
    Forma = <<"/Lotus/Types/Items/MiscItems/Forma">>,
    Snapshot = #{data => #{<<"inventory">> => #{<<"index">> => #{}}}},
    Catalog = [
        #{<<"uniqueName">> => Parent, <<"name">> => <<"Aklex Prime">>,
          <<"category">> => <<"Secondary">>, <<"masterable">> => true,
          <<"components">> => [
              #{<<"uniqueName">> => Weapon, <<"name">> => <<"Lex Prime">>,
                <<"tradable">> => true},
              #{<<"uniqueName">> => Cell, <<"name">> => <<"Orokin Cell">>,
                <<"tradable">> => false, <<"itemCount">> => 10},
              #{<<"uniqueName">> => Forma, <<"name">> => <<"Forma">>,
                <<"tradable">> => false}
          ]},
        #{<<"uniqueName">> => Weapon, <<"name">> => <<"Lex Prime">>,
          <<"category">> => <<"Secondary">>, <<"masterable">> => true,
          <<"components">> => []}
    ],
    {ok, Mastery} = wfcli_player_views:mastery(Snapshot, Catalog),
    [Item] = [Value || Value <- maps:get(<<"items">>, Mastery),
                       maps:get(<<"id">>, Value) =:= Parent],
    [Lex, OrokinCell, FormaBlueprint] = maps:get(<<"components">>, Item),
    ?assertEqual(<<"Lex Prime Set">>, maps:get(<<"market_name">>, Lex)),
    ?assertEqual(null, maps:get(<<"market_name">>, OrokinCell)),
    ?assertEqual(<<"Forma">>, maps:get(<<"name">>, FormaBlueprint)),
    ?assertEqual(null, maps:get(<<"market_name">>, FormaBlueprint)),
    ?assertEqual(false, maps:get(<<"market_required">>, FormaBlueprint)),
    ?assertEqual(true, maps:get(<<"buyable">>, Item)).

duplicate_recipe_slots_share_owned_count_test() ->
    Twin = <<"/Lotus/Weapons/Test/TwinKrohkur">>,
    Krohkur = <<"/Lotus/Weapons/Test/Krohkur">>,
    Snapshot = #{data => #{<<"inventory">> => #{<<"index">> => #{
        <<"equipment">> => [entry(Krohkur, 1, 0)]}}}},
    Catalog = [#{<<"uniqueName">> => Twin, <<"name">> => <<"Twin Krohkur">>,
                 <<"category">> => <<"Melee">>, <<"masterable">> => true,
                 <<"components">> => [
                     #{<<"uniqueName">> => Krohkur, <<"name">> => <<"Krohkur">>,
                       <<"itemCount">> => 1},
                     #{<<"uniqueName">> => Krohkur, <<"name">> => <<"Krohkur">>,
                       <<"itemCount">> => 1}]}],

    {ok, Foundry} = wfcli_player_views:foundry(Snapshot, Catalog),
    [Item] = maps:get(<<"items">>, Foundry),
    ?assertEqual([1, 0], [maps:get(<<"owned">>, Component)
                          || Component <- maps:get(<<"components">>, Item)]),
    ?assertEqual(1, maps:get(<<"components_owned">>, Item)),
    ?assertEqual(2, maps:get(<<"components_required">>, Item)),
    ?assertEqual(1, maps:get(<<"missing_parts">>, Item)),
    ?assertEqual(false, maps:get(<<"ready_to_build">>, Item)).

item_catalog_compaction_test() ->
    Item = #{<<"uniqueName">> => <<"/Lotus/Test">>,
             <<"name">> => <<"Test">>, <<"vaulted">> => true,
             <<"noise">> => true,
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
    ?assertEqual(true, maps:get(<<"vaulted">>, Compact)),
    [Component] = maps:get(<<"components">>, Compact),
    [Drop] = maps:get(<<"drops">>, Component),
    ?assertEqual(<<"/Lotus/Relic">>, maps:get(<<"uniqueName">>, Drop)).

entry(Type, Count, Xp) ->
    #{<<"item_type">> => Type, <<"count">> => Count, <<"xp">> => Xp}.
