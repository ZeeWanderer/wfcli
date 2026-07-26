%%%-------------------------------------------------------------------
%% EUnit coverage for owned relic catalog parsing and recommendation scoring.
%%%-------------------------------------------------------------------
-module(wfcli_relic_recommendations_eunit).

-include_lib("eunit/include/eunit.hrl").

parses_and_ranks_owned_relics_test() ->
    {ok, Catalog} = wfcli_relic_recommendations:parse(fixture()),
    Result = wfcli_relic_recommendations:build(
               <<"axi">>, Catalog, items(), quotes(), player()),
    [First, Second] = maps:get(<<"items">>, Result),
    ?assertEqual(<<"Axi A1 Intact">>, maps:get(<<"name">>, First)),
    ?assertEqual(19, maps:get(<<"expected_platinum">>, First)),
    ?assertEqual(95, maps:get(<<"expected_ducats">>, First)),
    ?assertEqual(2, maps:get(<<"amount_owned">>, First)),
    ?assertEqual(<<"Axi B1 Intact">>, maps:get(<<"name">>, Second)),
    ?assertEqual(1842, maps:get(<<"trace_count">>, Result)).

missing_quotes_keep_ducat_ranking_and_null_price_test() ->
    {ok, Catalog} = wfcli_relic_recommendations:parse(fixture()),
    Result = wfcli_relic_recommendations:build(
               <<"axi">>, Catalog, items(), #{}, player()),
    [First | _] = maps:get(<<"items">>, Result),
    ?assertEqual(<<"Axi A1 Intact">>, maps:get(<<"name">>, First)),
    ?assertEqual(null, maps:get(<<"expected_platinum">>, First)).

selects_visible_candidate_reward_slugs_test() ->
    {ok, Catalog} = wfcli_relic_recommendations:parse(fixture()),
    ?assertEqual(
       [<<"cheap_prime_part">>, <<"expensive_prime_part">>],
       wfcli_relic_recommendations:price_slugs(
         <<"axi">>, Catalog, items(), player(), 1)).

all_excludes_requiem_relics_test() ->
    {ok, Catalog} = wfcli_relic_recommendations:parse(fixture()),
    Result = wfcli_relic_recommendations:build(
               <<"all">>, Catalog, items(), quotes(), player()),
    Names = [maps:get(<<"name">>, Item)
             || Item <- maps:get(<<"items">>, Result)],
    ?assertEqual(false, lists:member(<<"Requiem I1 Intact">>, Names)).

fixture() ->
    jsone:encode([
        #{<<"uniqueName">> => <<"relic-a">>,
          <<"name">> => <<"Axi A1 Intact">>, <<"vaulted">> => false,
          <<"rewards">> => [
              reward(50, <<"cheap_prime_part">>),
              reward(50, <<"expensive_prime_part">>)
          ]},
        #{<<"uniqueName">> => <<"relic-b">>,
          <<"name">> => <<"Axi B1 Intact">>, <<"vaulted">> => true,
          <<"rewards">> => [reward(100, <<"medium_prime_part">>)]},
        #{<<"uniqueName">> => <<"relic-r">>,
          <<"name">> => <<"Requiem I1 Intact">>, <<"vaulted">> => false,
          <<"rewards">> => [reward(100, <<"medium_prime_part">>)]},
        #{<<"uniqueName">> => <<"void">>, <<"name">> => <<"Void Relic">>,
          <<"rewards">> => []}
    ]).

reward(Chance, Slug) ->
    #{<<"chance">> => Chance,
      <<"item">> => #{<<"warframeMarket">> => #{<<"urlName">> => Slug}}}.

items() ->
    [item(<<"cheap_prime_part">>, 15),
     item(<<"expensive_prime_part">>, 100),
     item(<<"medium_prime_part">>, 45)].

item(Slug, Ducats) -> #{<<"slug">> => Slug, <<"ducats">> => Ducats}.

quotes() ->
    #{<<"cheap_prime_part">> => #{lowest_sell => 10},
      <<"expensive_prime_part">> => #{lowest_sell => 20},
      <<"medium_prime_part">> => #{lowest_sell => 12}}.

player() ->
    #{data => #{<<"inventory">> => #{<<"index">> => #{<<"stacks">> => [
        #{<<"item_type">> => <<"relic-a">>, <<"count">> => 2},
        #{<<"item_type">> => <<"relic-b">>, <<"count">> => 1},
        #{<<"item_type">> => <<"relic-r">>, <<"count">> => 1},
        #{<<"item_type">> =>
              <<"/Lotus/Types/Items/MiscItems/VoidTearDrop">>,
          <<"count">> => 1842}
    ]}}}}.
