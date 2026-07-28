%%%-------------------------------------------------------------------
%% Searchable entities projected from canonical player data.
%%%-------------------------------------------------------------------
-module(wfcli_entity_player).

-export([build_entries/2, query_field/2, query_sort_field/2, default_sort/1]).

-doc "Build raw source entries and typed projections from the inventory observation.".
-spec build_entries(map(), map()) -> [map()].
build_entries(Snapshot, Opts) ->
    Data = maps:get(data, Snapshot, #{}),
    Root = build(player, <<"player">>, <<"Player">>, <<"all">>, Data, Opts),
    Sources = [
        build(player_source, Source, Source, Source, SourceData, Opts)
        || {Source, SourceData} <- lists:sort(maps:to_list(Data))
    ],
    [Root | Sources] ++ inventory_entries(maps:get(<<"inventory">>, Data, #{}), Opts).

build(Type, Id, Name, Source, Data, Opts) ->
    Spec = #{
        row_map_fun => fun(Entry) ->
            #{type => maps:get(type, Entry), id => maps:get(id, Entry),
              name => maps:get(name, Entry), source => Source}
        end
    },
    (wfcli_entity:build(Type, Id, Name, Data,
                        Opts#{search_raw => true}, Spec))#{source => Source}.

inventory_entries(Observation, Opts) when is_map(Observation) ->
    Profile = maps:get(<<"profile">>, Observation, #{}),
    Index = maps:get(<<"index">>, Observation, #{}),
    profile_entries(Profile, Opts)
    ++ indexed_entries(player_equipment, maps:get(<<"equipment">>, Index, []), Opts)
    ++ indexed_entries(player_stack, maps:get(<<"stacks">>, Index, []), Opts)
    ++ indexed_entries(player_mastery, maps:get(<<"mastery">>, Index, []), Opts)
    ++ indexed_entries(player_recipe, maps:get(<<"pending_recipes">>, Index, []), Opts)
    ++ mission_entries(maps:get(<<"missions">>, Index, []), Opts)
    ++ skill_entries(maps:get(<<"player_skills">>, Index, #{}), Opts);
inventory_entries(_Observation, _Opts) -> [].

profile_entries(Profile, Opts) when is_map(Profile), map_size(Profile) > 0 ->
    [typed_build(player_profile, <<"profile">>, <<"Profile">>, Profile, Opts)];
profile_entries(_Profile, _Opts) -> [].

indexed_entries(Type, Values, Opts) when is_list(Values) ->
    indexed_entries(Type, Values, Opts, 1, []);
indexed_entries(_Type, _Values, _Opts) -> [].

indexed_entries(_Type, [], _Opts, _Position, Acc) -> lists:reverse(Acc);
indexed_entries(Type, [Data | Rest], Opts, Position, Acc) when is_map(Data) ->
    Id = entry_id(Data, Position),
    Name = entry_name(Data, Id, Opts),
    Entry = typed_build(Type, Id, Name, Data, Opts),
    indexed_entries(Type, Rest, Opts, Position + 1, [Entry | Acc]);
indexed_entries(Type, [_ | Rest], Opts, Position, Acc) ->
    indexed_entries(Type, Rest, Opts, Position + 1, Acc).

mission_entries(Missions, Opts) when is_list(Missions) ->
    [typed_build(player_mission, Tag, resolved_name(node, Tag, Opts), Mission, Opts)
     || Mission <- Missions,
        is_map(Mission),
        Tag <- [maps:get(<<"Tag">>, Mission, undefined)],
        Tag =/= undefined];
mission_entries(_Missions, _Opts) -> [].

skill_entries(Skills, Opts) when is_map(Skills) ->
    [typed_build(player_skill, Skill, Skill,
                 #{<<"skill">> => Skill, <<"rank">> => Rank}, Opts)
     || {Skill, Rank} <- lists:sort(maps:to_list(Skills)),
        is_integer(Rank)];
skill_entries(_Skills, _Opts) -> [].

typed_build(Type, Id, Name, Data, Opts) ->
    Source = <<"inventory">>,
    Spec = #{
        row_map_fun => fun(Entry) ->
            maps:merge(
              #{type => maps:get(type, Entry), id => maps:get(id, Entry),
                name => maps:get(name, Entry), source => Source},
              scalar_fields(maps:get(data, Entry)))
        end
    },
    Entry = wfcli_entity:build(Type, Id, Name, Data,
                               Opts#{search_raw => true}, Spec),
    maps:merge(Entry#{source => Source}, scalar_fields(Data)).

scalar_fields(Data) ->
    maps:fold(
      fun(Key, Value, Acc) when is_binary(Key),
                                (is_binary(Value) orelse is_integer(Value)
                                 orelse is_float(Value) orelse is_boolean(Value)) ->
              case field_atom(Key) of
                  undefined -> Acc;
                  Field -> Acc#{Field => Value}
              end;
         (_Key, _Value, Acc) -> Acc
      end,
      #{},
      Data).

field_atom(<<"item_type">>) -> item_type;
field_atom(<<"instance_id">>) -> instance_id;
field_atom(<<"collection">>) -> collection;
field_atom(<<"count">>) -> count;
field_atom(<<"xp">>) -> xp;
field_atom(<<"item_name">>) -> item_name;
field_atom(<<"rank">>) -> rank;
field_atom(<<"skill">>) -> skill;
field_atom(<<"Completes">>) -> completes;
field_atom(<<"Tier">>) -> tier;
field_atom(<<"Tag">>) -> tag;
field_atom(<<"player_level">>) -> player_level;
field_atom(<<"regular_credits">>) -> regular_credits;
field_atom(<<"premium_credits">>) -> premium_credits;
field_atom(<<"premium_credits_free">>) -> premium_credits_free;
field_atom(<<"fusion_points">>) -> fusion_points;
field_atom(<<"trades_remaining">>) -> trades_remaining;
field_atom(<<"daily_focus">>) -> daily_focus;
field_atom(<<"focus_capacity">>) -> focus_capacity;
field_atom(<<"last_region_played">>) -> last_region_played;
field_atom(_Key) -> undefined.

entry_id(Data, Position) ->
    case maps:get(<<"instance_id">>, Data, undefined) of
        Id when is_binary(Id), byte_size(Id) > 0 -> Id;
        _ ->
            ItemType = maps:get(<<"item_type">>, Data, <<"entry">>),
            <<(wfcli_text:to_binary(ItemType))/binary, "#",
              (integer_to_binary(Position))/binary>>
    end.

entry_name(Data, Id, Opts) ->
    case maps:get(<<"item_name">>, Data, undefined) of
        Name when is_binary(Name), byte_size(Name) > 0 -> Name;
        _ ->
            ItemType = maps:get(<<"item_type">>, Data, Id),
            resolved_name(item, ItemType, Opts)
    end.

resolved_name(Kind, Value, Opts) ->
    wfcli_resolve:resolve(Kind, Value, Opts#{resolve_items => true}).

-doc "Resolve player query fields; arbitrary source data remains available through data.<path>.".
-spec query_field(term(), string() | atom()) -> {ok, map()} | error.
query_field(_Kind, Key0) ->
    KeyText = wfcli_text:to_list(Key0),
    Key = string:lowercase(KeyText),
    case Key of
        "name" -> field(name, {entry, name}, string, contains);
        "id" -> field(id, {entry, id}, string, contains);
        "type" -> field(type, {entry, type}, string, eq);
        "source" -> field(source, {entry, source}, string, eq);
        "item_type" -> field(item_type, {entry, item_type}, string, contains);
        "collection" -> field(collection, {entry, collection}, string, eq);
        "count" -> field(count, {entry, count}, number, eq);
        "xp" -> field(xp, {entry, xp}, number, eq);
        "rank" -> field(rank, {entry, rank}, number, eq);
        "skill" -> field(skill, {entry, skill}, string, contains);
        "completes" -> field(completes, {entry, completes}, number, eq);
        "tier" -> field(tier, {entry, tier}, number, eq);
        _ ->
            case lists:prefix("data.", Key) of
                true -> field({data, string:slice(KeyText, 5)},
                              {data_path, string:slice(KeyText, 5)}, dynamic, contains);
                false -> error
            end
    end.

-doc "Player sort fields use the same field contract as filters.".
-spec query_sort_field(term(), string() | atom()) -> {ok, map()} | error.
query_sort_field(Kind, Key) -> query_field(Kind, Key).

-doc "Keep typed player entries stable and group them by type and name.".
-spec default_sort(term()) -> [map()].
default_sort(_Kind) ->
    [#{key => type, dir => asc}, #{key => name, dir => asc}].

field(Key, Source, Kind, DefaultOp) ->
    {ok, #{key => Key, source => Source, kind => Kind, default_op => DefaultOp}}.
