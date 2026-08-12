-module(wfcli_player_projection_eunit).

-include_lib("eunit/include/eunit.hrl").

projects_items_upgrades_and_configs_test() ->
    Projection = projection(),
    [Suit] = [Item || Item <- maps:get(<<"equipment">>, Projection),
                     maps:get(<<"instance_id">>, Item) =:= <<"suit-1">>],
    ?assertEqual(2, maps:get(<<"forma_count">>, Suit)),
    ?assertEqual([#{<<"Slot">> => 0, <<"Value">> => <<"AP_ATTACK">>}],
                 maps:get(<<"polarity_overrides">>, Suit)),

    [Config] = [Item || Item <- maps:get(<<"configs">>, Projection),
                       maps:get(<<"equipment_id">>, Item) =:= <<"suit-1">>],
    [Slot] = maps:get(<<"upgrade_slots">>, Config),
    ?assertEqual(<<"mod-1">>, maps:get(<<"instance_id">>, Slot)),
    ?assertEqual(8, maps:get(<<"rank">>, Slot)),
    ?assertEqual(<<"/Lotus/Upgrades/Mods/TestMod">>,
                 maps:get(<<"item_type">>, Slot)),

    [Ranked] = [Upgrade || Upgrade <- maps:get(<<"upgrades">>, Projection),
                           maps:get(<<"instance_id">>, Upgrade, null) =:= <<"mod-1">>],
    ?assertEqual(<<"ranked">>, maps:get(<<"kind">>, Ranked)),
    ?assertEqual(8, maps:get(<<"rank">>, Ranked)),
    ?assertEqual(true, maps:get(<<"equipped">>, Ranked)),
    [Usage] = maps:get(<<"equipped_in">>, Ranked),
    ?assertEqual(<<"suit-1">>, maps:get(<<"equipment_id">>, Usage)),

    [Stack] = [Upgrade || Upgrade <- maps:get(<<"upgrades">>, Projection),
                          maps:get(<<"kind">>, Upgrade) =:= <<"stack">>],
    ?assertEqual(4, maps:get(<<"count">>, Stack)).

projects_loadout_links_and_progression_test() ->
    Projection = projection(),
    [Loadout] = maps:get(<<"loadouts">>, Projection),
    ?assertEqual(<<"Default">>, maps:get(<<"name">>, Loadout)),
    ?assertEqual(true, maps:get(<<"active">>, Loadout)),
    ?assertEqual(true, maps:get(<<"favorite">>, Loadout)),
    [Slot] = maps:get(<<"loadout_slots">>, Projection),
    ?assertEqual(<<"s">>, maps:get(<<"slot">>, Slot)),
    ?assertEqual(<<"suit-1">>, maps:get(<<"instance_id">>, Slot)),
    ?assertEqual(<<"Suits">>, maps:get(<<"collection">>, Slot)),
    ?assertEqual(0, maps:get(<<"config_index">>, Slot)),
    ?assertEqual(1, length(maps:get(<<"affiliations">>, Projection))),
    ?assertEqual(1, length(maps:get(<<"focus_upgrades">>, Projection))),
    ?assertEqual(1, length(maps:get(<<"focus_pools">>, Projection))),
    ?assertEqual(1, length(maps:get(<<"boosters">>, Projection))),
    ?assertEqual(1, length(maps:get(<<"challenges">>, Projection))).

projection_keeps_raw_and_reports_understood_shape_test() ->
    Projection = projection(),
    Raw = maps:get(<<"raw">>, Projection),
    ?assertEqual(true, maps:get(<<"kept">>, maps:get(<<"UnknownFutureSection">>, Raw))),
    ?assertEqual([], maps:get(schema_issues, Projection)),
    Profile = maps:get(<<"profile">>, Projection),
    ?assertEqual(<<"TestTenno">>, maps:get(<<"player_name">>, Profile)),
    ?assertEqual(18, maps:get(<<"player_level">>, Profile)).

every_typed_origin_has_raw_identity_test() ->
    Projection = projection(),
    TypedOrigins = lists:usort(lists:append(
                     [maps:get(origins, Record)
                      || Record <- maps:get(entities, Projection)])),
    RawOrigins = maps:from_keys(
                   [maps:get(origin, Record)
                    || Record <- maps:get(raw_entities, Projection)], true),
    ?assertEqual([], [Origin || Origin <- TypedOrigins,
                               not maps:is_key(Origin, RawOrigins)]).

unknown_item_field_is_nonfatal_but_audited_test() ->
    Raw0 = fixture_raw(),
    [Suit0] = maps:get(<<"Suits">>, Raw0),
    Raw = Raw0#{<<"Suits">> => [Suit0#{<<"FutureStat">> => 17}]},
    Projection = wfcli_player_projection:from_observation(observation(Raw)),
    [Suit] = [Item || Item <- maps:get(<<"equipment">>, Projection),
                     maps:get(<<"instance_id">>, Item) =:= <<"suit-1">>],
    ?assertEqual(17, maps:get(<<"FutureStat">>, maps:get(raw, Suit))),
    ?assert(lists:any(
      fun(#{kind := unknown_fields, fields := Fields}) ->
              lists:member(<<"FutureStat">>, Fields);
         (_) -> false
      end,
      maps:get(schema_issues, Projection))).

shape_change_is_audited_without_crashing_projection_test() ->
    Raw = (fixture_raw())#{<<"Suits">> => #{<<"unexpected">> => true}},
    Projection = wfcli_player_projection:from_observation(observation(Raw)),
    ?assertEqual([], [Item || Item <- maps:get(<<"equipment">>, Projection),
                              maps:get(<<"collection">>, Item) =:= <<"Suits">>]),
    ?assert(lists:any(
      fun(#{kind := wrong_type, path := [<<"Suits">>]}) -> true;
         (_) -> false
      end,
      maps:get(schema_issues, Projection))).

projection() ->
    wfcli_player_projection:from_observation(observation(fixture_raw())).

observation(Raw) ->
    #{<<"schema">> => 2,
      <<"collector">> => <<"test">>,
      <<"profile">> => #{<<"player_name">> => <<"TestTenno">>},
      <<"raw">> => Raw}.

fixture_raw() ->
    {ok, Body} = file:read_file(
                   "apps/wfcli/test/fixtures/player_inventory_sample.json"),
    jsone:decode(Body, [{object_format, map}]).
