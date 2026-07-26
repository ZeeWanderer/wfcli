%%%-------------------------------------------------------------------
%% EUnit coverage for player dataset query projection.
%%%-------------------------------------------------------------------
-module(wfcli_player_query_eunit).

-include_lib("eunit/include/eunit.hrl").

source_filter_uses_shared_query_engine_test() ->
    {ok, Ast} = wfcli_query_parse:parse("source=game data.phase=launcher"),
    {ok, #{results := Results}} = wfcli_player_query:execute(Ast, #{}, snapshot()),
    [Entry] = maps:get(slice, Results),
    ?assertEqual(<<"game">>, maps:get(source, Entry)).

raw_root_supports_nested_data_path_test() ->
    {ok, Ast} = wfcli_query_parse:parse("data.inventory.weapons.0=Braton"),
    {ok, #{results := Results}} = wfcli_player_query:execute(Ast, #{}, snapshot()),
    [Entry] = maps:get(slice, Results),
    ?assertEqual(player, maps:get(type, Entry)).

boolean_terms_search_raw_player_data_test() ->
    {ok, Ast} = wfcli_query_parse:parse("braton OR launcher"),
    {ok, #{results := Results}} = wfcli_player_query:execute(Ast, #{}, snapshot()),
    ?assert(maps:get(total, Results) >= 2).

typed_inventory_entities_use_normal_query_fields_test() ->
    {ok, Ast} = wfcli_query_parse:parse("type=player_stack count>=2"),
    {ok, #{results := Results}} =
        wfcli_player_query:execute(Ast, #{}, typed_snapshot()),
    [Entry] = maps:get(slice, Results),
    ?assertEqual(<<"/Lotus/Types/Items/MiscItems/ArgonCrystal">>,
                 maps:get(item_type, Entry)),
    ?assertEqual(3, maps:get(count, Entry)).

typed_mastery_and_recipe_entities_are_distinct_test() ->
    {ok, Ast} = wfcli_query_parse:parse(
                  "type=player_mastery OR type=player_recipe"),
    {ok, #{results := Results}} =
        wfcli_player_query:execute(Ast, #{}, typed_snapshot()),
    ?assertEqual([player_mastery, player_recipe],
                 lists:sort([maps:get(type, Entry)
                             || Entry <- maps:get(slice, Results)])).

snapshot() ->
    #{revision => 4, updated_at => 1234,
      data => #{
          <<"game">> => #{<<"phase">> => <<"launcher">>, <<"running">> => false},
          <<"inventory">> => #{<<"weapons">> => [<<"Braton">>, <<"Paris">>]}
      }}.

typed_snapshot() ->
    #{revision => 8, updated_at => 5678,
      data => #{
          <<"inventory">> => #{
              <<"schema">> => 1,
              <<"profile">> => #{<<"player_level">> => 18},
              <<"index">> => #{
                  <<"equipment">> => [
                      #{<<"collection">> => <<"Suits">>,
                        <<"item_type">> => <<"/Lotus/Powersuits/Excalibur">>,
                        <<"instance_id">> => <<"suit-1">>,
                        <<"count">> => 1, <<"xp">> => 9000}
                  ],
                  <<"stacks">> => [
                      #{<<"collection">> => <<"MiscItems">>,
                        <<"item_type">> =>
                            <<"/Lotus/Types/Items/MiscItems/ArgonCrystal">>,
                        <<"count">> => 3}
                  ],
                  <<"mastery">> => [
                      #{<<"item_type">> => <<"/Lotus/Weapons/Tenno/Rifle/Braton">>,
                        <<"xp">> => 450000}
                  ],
                  <<"pending_recipes">> => [
                      #{<<"item_type">> => <<"/Lotus/Weapons/Tenno/Rifle/Braton">>,
                        <<"instance_id">> => <<"recipe-1">>,
                        <<"completion_date">> => null}
                  ],
                  <<"missions">> => [],
                  <<"player_skills">> => #{<<"LPS_PILOTING">> => 7}
              },
              <<"raw">> => #{<<"UnknownFutureField">> => true}
          }
      }}.
