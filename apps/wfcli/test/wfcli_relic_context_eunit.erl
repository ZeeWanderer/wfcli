%%%-------------------------------------------------------------------
%% EUnit coverage for reward, set, asset, and player ownership joins.
%%%-------------------------------------------------------------------
-module(wfcli_relic_context_eunit).

-include_lib("eunit/include/eunit.hrl").

joins_market_set_to_player_inventory_test() ->
    Items = [
        item(<<"set">>, <<"saryn_prime_set">>, <<"Saryn Prime Set">>,
             <<"/Lotus/Powersuits/Saryn/SarynPrime">>, true, 1),
        item(<<"chassis">>, <<"saryn_prime_chassis_blueprint">>,
             <<"Saryn Prime Chassis Blueprint">>,
             <<"/Lotus/Types/Recipes/WarframeRecipes/SarynPrimeChassisBlueprint">>,
             false, 1),
        item(<<"systems">>, <<"saryn_prime_systems_blueprint">>,
             <<"Saryn Prime Systems Blueprint">>,
             <<"/Lotus/Types/Recipes/WarframeRecipes/SarynPrimeSystemsBlueprint">>,
             false, 1)
    ],
    Details = #{
        <<"saryn_prime_chassis_blueprint">> => #{
            data => #{<<"setParts">> => [<<"set">>, <<"chassis">>, <<"systems">>]}
        }
    },
    Quotes = #{
        <<"saryn_prime_chassis_blueprint">> => #{lowest_sell => 18, highest_buy => 15},
        <<"saryn_prime_set">> => #{lowest_sell => 75}
    },
    Player = player_snapshot(),
    Relics = #{<<"active">> => #{
        vaulted => false,
        rewards => [#{slug => <<"saryn_prime_chassis_blueprint">>}]
    }},
    Result = wfcli_relic_context:build(
               [<<"saryn_prime_chassis_blueprint">>],
               Items, Details, Quotes, Player, Relics),
    [Context] = maps:get(<<"items">>, Result),
    ?assertEqual(2, maps:get(<<"count_owned">>, Context)),
    ?assertEqual(true, maps:get(<<"crafted">>, Context)),
    ?assertEqual(false, maps:get(<<"set_complete">>, Context)),
    ?assertEqual(false, maps:get(<<"vaulted">>, Context)),
    ?assertEqual(18, maps:get(<<"lowest_sell">>, Context)),
    ?assertEqual(75, maps:get(<<"set_price">>, Context)),
    ?assertEqual(3, length(maps:get(<<"parts">>, Context))),
    ?assertEqual(#{<<"platinum">> => 124, <<"ducats">> => 915},
                 maps:get(<<"account">>, Result)),
    Asset = maps:get(<<"asset">>, Context),
    ?assertEqual(<<"market:saryn_prime_chassis_blueprint">>,
                 maps:get(<<"id">>, Asset)),
    ?assertEqual(<<"sub_icons/warframe/prime_chassis_128x128.png">>,
                 maps:get(<<"image_name">>, Asset)),
    VaultedResult = wfcli_relic_context:build(
                      [<<"saryn_prime_chassis_blueprint">>],
                      Items, Details, Quotes, Player,
                      #{<<"inactive">> => #{
                          vaulted => true,
                          rewards => [#{slug => <<"saryn_prime_chassis_blueprint">>}]
                      }}),
    [VaultedContext] = maps:get(<<"items">>, VaultedResult),
    ?assertEqual(true, maps:get(<<"vaulted">>, VaultedContext)).

item(Id, Slug, Name, GameRef, SetRoot, Quantity) ->
    #{<<"id">> => Id, <<"slug">> => Slug, <<"gameRef">> => GameRef,
      <<"setRoot">> => SetRoot, <<"quantityInSet">> => Quantity,
      <<"ducats">> => 100, <<"tags">> => [<<"prime">>],
      <<"i18n">> => #{<<"en">> => #{
          <<"name">> => Name,
          <<"subIcon">> => <<"sub_icons/warframe/prime_chassis_128x128.png">>,
          <<"thumb">> => <<"items/images/en/thumbs/", Slug/binary, ".png">>
      }}}.

player_snapshot() ->
    #{data => #{<<"inventory">> => #{
        <<"profile">> => #{<<"premium_credits">> => 124},
        <<"index">> => #{
            <<"equipment">> => [
                #{<<"item_type">> => <<"/Lotus/Powersuits/Saryn/SarynPrime">>,
                  <<"count">> => 1}
            ],
            <<"stacks">> => [
                #{<<"item_type">> =>
                      <<"/Lotus/Types/Recipes/WarframeRecipes/SarynPrimeChassisBlueprint">>,
                  <<"count">> => 2},
                #{<<"item_type">> =>
                      <<"/Lotus/Types/Items/MiscItems/PrimeBucks">>,
                  <<"count">> => 915},
                #{<<"item_type">> => <<"malformed">>, <<"count">> => <<"many">>}
            ]
        }
    }}}.
