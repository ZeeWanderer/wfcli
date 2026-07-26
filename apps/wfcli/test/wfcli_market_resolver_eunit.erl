%%%-------------------------------------------------------------------
%% EUnit coverage for OCR-oriented Market label resolution.
%%%-------------------------------------------------------------------
-module(wfcli_market_resolver_eunit).

-include_lib("eunit/include/eunit.hrl").

ranked_fuzzy_matches_test() ->
    Items = [item(<<"saryn_prime_set">>, <<"Saryn Prime Set">>, 100),
             item(<<"saryn_prime_chassis_blueprint">>,
                  <<"Saryn Prime Chassis Blueprint">>, 100),
             item(<<"soma_prime_set">>, <<"Soma Prime Set">>, 100)],
    [Resolution] = wfcli_market_resolver:resolve(
                     [<<"Saryn Prme Set">>], Items, 2),
    ?assertEqual(<<"Saryn Prme Set">>, maps:get(label, Resolution)),
    [Best, Second] = maps:get(matches, Resolution),
    ?assertEqual(#{name => <<"Saryn Prime Set">>, slug => <<"saryn_prime_set">>,
                   ducats => 100, distance => 1, confidence => 0.9333}, Best),
    ?assertEqual(<<"Soma Prime Set">>, maps:get(name, Second)),
    ?assert(maps:get(confidence, Best) > maps:get(confidence, Second)).

normalization_and_label_order_test() ->
    Items = [item(<<"braton_prime_barrel">>, <<"Braton Prime Barrel">>, 15),
             item(<<"braton_prime_blueprint">>, <<"Braton Prime Blueprint">>, 25)],
    Resolutions = wfcli_market_resolver:resolve(
                    [<<"BRATON--PRIME barrel">>, <<"Braton Prime Blueprnt">>], Items, 1),
    [Barrel, Blueprint] = Resolutions,
    [BarrelMatch] = maps:get(matches, Barrel),
    [BlueprintMatch] = maps:get(matches, Blueprint),
    ?assertEqual(0, maps:get(distance, BarrelMatch)),
    ?assertEqual(1.0, maps:get(confidence, BarrelMatch)),
    ?assertEqual(15, maps:get(ducats, BarrelMatch)),
    ?assertEqual(<<"braton_prime_blueprint">>, maps:get(slug, BlueprintMatch)),
    ?assertEqual(1, maps:get(distance, BlueprintMatch)).

item(Slug, Name, Ducats) ->
    #{<<"slug">> => Slug,
      <<"ducats">> => Ducats,
      <<"i18n">> => #{<<"en">> => #{<<"name">> => Name}}}.
