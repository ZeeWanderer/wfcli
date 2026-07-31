%%%-------------------------------------------------------------------
%% Catalog joins for desktop inventory and mastery views.
%%%-------------------------------------------------------------------
-module(wfcli_player_views).

-export([inventory/0, mastery/0, inventory/2, mastery/2]).

-doc "Build inventory view from current daemon snapshot and managed item catalog.".
-spec inventory() -> {ok, map()} | {error, term()}.
inventory() -> with_catalog(fun inventory/2).

-doc "Build mastery view from current daemon snapshot and managed item catalog.".
-spec mastery() -> {ok, map()} | {error, term()}.
mastery() -> with_catalog(fun mastery/2).

-doc "Build inventory view from supplied data; exposed for deterministic tests.".
-spec inventory(map(), [map()]) -> {ok, map()}.
inventory(Snapshot, Catalog) ->
    Observation = inventory_observation(Snapshot),
    Index = maps:get(<<"index">>, Observation, #{}),
    CatalogIndex = catalog_index(Catalog),
    Mastery = mastery_index(maps:get(<<"mastery">>, Index, [])),
    Stacks = aggregate(maps:get(<<"stacks">>, Index, [])),
    StackItems = [inventory_item(Unique, Entry,
                                 maps:get(Unique, CatalogIndex, #{}), Mastery)
                  || {Unique, Entry} <- maps:to_list(Stacks),
                     maps:get(count, Entry, 0) > 0],
    SetItems = [Set || Item <- Catalog,
                       Set <- [inventory_set(Item, Stacks, Mastery)],
                       Set =/= undefined],
    Items = StackItems ++ SetItems,
    Sorted = lists:sort(fun name_before/2, Items),
    {ok, (base_response(Snapshot))#{
        <<"items">> => Sorted,
        <<"summary">> => inventory_summary(Sorted)
    }}.

-doc "Build mastery planner view from supplied data; exposed for deterministic tests.".
-spec mastery(map(), [map()]) -> {ok, map()}.
mastery(Snapshot, Catalog) ->
    Observation = inventory_observation(Snapshot),
    Index = maps:get(<<"index">>, Observation, #{}),
    Owned = aggregate(maps:get(<<"equipment">>, Index, []) ++
                      maps:get(<<"stacks">>, Index, [])),
    Mastery = mastery_index(maps:get(<<"mastery">>, Index, [])),
    Pending = pending_index(maps:get(<<"pending_recipes">>, Index, []), Catalog),
    Items = [mastery_item(Item, Owned, Mastery, Pending)
             || Item <- Catalog, mastery_item_supported(Item)],
    Sorted = lists:sort(fun mastery_before/2, Items),
    Profile = maps:get(<<"profile">>, Observation, #{}),
    {ok, (base_response(Snapshot))#{
        <<"items">> => Sorted,
        <<"summary">> => mastery_summary(Sorted, Profile)
    }}.

with_catalog(Build) ->
    case wfcli_item_catalog:load() of
        {ok, Catalog, _Meta} -> Build(wfcli_player_service:snapshot(), Catalog);
        {error, _Reason} ->
            case wfcli_source_manager:ensure_catalog("player_views", #{}) of
                ok ->
                    case wfcli_item_catalog:load() of
                        {ok, Catalog, _Meta} ->
                            Build(wfcli_player_service:snapshot(), Catalog);
                        {error, _LoadReason} = Error -> Error
                    end;
                {error, _EnsureReason} = Error -> Error
            end
    end.

inventory_observation(Snapshot) ->
    Data = maps:get(data, Snapshot, #{}),
    maps:get(<<"inventory">>, Data, #{}).

base_response(Snapshot) ->
    #{<<"revision">> => maps:get(revision, Snapshot, 0),
      <<"updated_at">> => nullable(maps:get(updated_at, Snapshot, undefined))}.

catalog_index(Catalog) ->
    lists:foldl(
      fun(Item, Acc) ->
          Acc1 = put_catalog(Item, Item, false, Acc),
          lists:foldl(fun(Component, A) -> put_catalog(Component, Item, true, A) end,
                      Acc1, maps:get(<<"components">>, Item, []))
      end, #{}, Catalog).

put_catalog(Item, Parent, Component, Acc) when is_map(Item) ->
    case maps:get(<<"uniqueName">>, Item, undefined) of
        Unique when is_binary(Unique) ->
            Candidate = Item#{<<"parentCategory">> => maps:get(<<"category">>, Parent, <<>>),
                              <<"parentName">> => maps:get(<<"name">>, Parent, <<>>),
                              <<"parentUniqueName">> => maps:get(<<"uniqueName">>, Parent,
                                                                  undefined),
                              <<"parentType">> => maps:get(<<"type">>, Parent, <<>>),
                              <<"component">> => Component},
            case maps:get(Unique, Acc, undefined) of
                undefined -> Acc#{Unique => Candidate};
                Existing -> Acc#{Unique => prefer_catalog(Existing, Candidate)}
            end;
        _ -> Acc
    end;
put_catalog(_Item, _Parent, _Component, Acc) -> Acc.

prefer_catalog(Existing, Candidate) ->
    case {present(maps:get(<<"imageName">>, Existing, undefined)),
          present(maps:get(<<"imageName">>, Candidate, undefined))} of
        {false, true} -> maps:merge(Existing, Candidate);
        _ -> maps:merge(Candidate, Existing)
    end.

aggregate(Entries) when is_list(Entries) ->
    lists:foldl(fun aggregate_entry/2, #{}, Entries);
aggregate(_Entries) -> #{}.

aggregate_entry(Entry, Acc) when is_map(Entry) ->
    case maps:get(<<"item_type">>, Entry, undefined) of
        Unique when is_binary(Unique) ->
            Current = maps:get(Unique, Acc, #{count => 0, xp => 0, name => undefined,
                                             collections => []}),
            Count = max(0, number(maps:get(<<"count">>, Entry, 0))),
            Xp = max(number(maps:get(<<"xp">>, Entry, 0)), maps:get(xp, Current)),
            Name = first_present([maps:get(<<"item_name">>, Entry, undefined),
                                  maps:get(name, Current)]),
            Collection = maps:get(<<"collection">>, Entry, <<>>),
            Collections = lists:usort([Collection | maps:get(collections, Current)]),
            Acc#{Unique => Current#{count => maps:get(count, Current) + Count,
                                    xp => Xp, name => Name,
                                    collections => Collections}};
        _ -> Acc
    end;
aggregate_entry(_Entry, Acc) -> Acc.

mastery_index(Entries) when is_list(Entries) ->
    maps:from_list([{maps:get(<<"item_type">>, Entry),
                     number(maps:get(<<"xp">>, Entry, 0))}
                    || Entry <- Entries, is_map(Entry),
                       is_binary(maps:get(<<"item_type">>, Entry, undefined))]);
mastery_index(_Entries) -> #{}.

pending_index(Pending, Catalog) ->
    RecipeParents = lists:foldl(
      fun(Item, Acc) ->
          Parent = maps:get(<<"uniqueName">>, Item, undefined),
          lists:foldl(
            fun(Component, A) ->
                case {maps:get(<<"name">>, Component, <<>>),
                      maps:get(<<"uniqueName">>, Component, undefined)} of
                    {<<"Blueprint">>, Recipe} when is_binary(Recipe), is_binary(Parent) ->
                        A#{Recipe => Parent};
                    _ -> A
                end
            end, Acc, maps:get(<<"components">>, Item, []))
      end, #{}, Catalog),
    maps:from_list(
      [{maps:get(maps:get(<<"item_type">>, Entry), RecipeParents,
                 maps:get(<<"item_type">>, Entry)), true}
       || Entry <- Pending, is_map(Entry),
          is_binary(maps:get(<<"item_type">>, Entry, undefined))]).

inventory_item(Unique, Entry, Catalog, Mastery) ->
    Name = item_name(Unique, Entry, Catalog),
    Category = maps:get(<<"category">>, Catalog,
                        maps:get(<<"parentCategory">>, Catalog, <<>>)),
    Collections = maps:get(collections, Entry, []),
    MasteryKey = case maps:get(<<"component">>, Catalog, false) of
                     true -> maps:get(<<"parentUniqueName">>, Catalog, Unique);
                     false -> Unique
                 end,
    #{<<"id">> => Unique,
      <<"name">> => Name,
      <<"group">> => inventory_group(Unique, Catalog, Category, Collections),
      <<"category">> => Category,
      <<"type">> => maps:get(<<"type">>, Catalog,
                              maps:get(<<"parentType">>, Catalog, <<>>)),
      <<"quantity">> => maps:get(count, Entry),
      <<"xp">> => maps:get(xp, Entry),
      <<"mastered">> => maps:get(MasteryKey, Mastery, 0) > 0,
      <<"tradable">> => maps:get(<<"tradable">>, Catalog, false) =:= true,
      <<"ducats">> => number(maps:get(<<"primeSellingPrice">>, Catalog, 0)),
      <<"asset">> => asset(Unique, maps:get(<<"imageName">>, Catalog, undefined))}.

inventory_group(Unique, Catalog, Category, Collections) ->
    Component = maps:get(<<"component">>, Catalog, false) =:= true,
    Tradable = maps:get(<<"tradable">>, Catalog, false) =:= true,
    EquipmentPart = Component andalso Tradable andalso
                    equipment_category(Category),
    Projection = binary:match(Unique, <<"/Projections/">>) =/= nomatch,
    Arcane = binary:match(Unique, <<"/Arcane">>) =/= nomatch,
    Upgrade = lists:member(<<"RawUpgrades">>, Collections) orelse
              lists:member(<<"Upgrades">>, Collections),
    case {Category, EquipmentPart, Projection, Arcane, Upgrade} of
        {<<"Relics">>, _, _, _, _} -> <<"relics">>;
        {<<"Mods">>, _, _, _, _} -> <<"mods">>;
        {<<"Arcanes">>, _, _, _, _} -> <<"arcanes">>;
        {_, true, _, _, _} -> <<"parts">>;
        {_, _, true, _, _} -> <<"relics">>;
        {_, _, _, true, _} -> <<"arcanes">>;
        {_, _, _, _, true} -> <<"mods">>;
        _ -> <<"misc">>
    end.

inventory_summary(Items) ->
    Counts = lists:foldl(
      fun(Item, Acc) ->
          Group = maps:get(<<"group">>, Item),
          Acc#{Group => maps:get(Group, Acc, 0) + 1}
      end, #{}, Items),
    Counts#{<<"total">> => length(Items)}.

inventory_set(Item, Stacks, Mastery) ->
    Category = maps:get(<<"category">>, Item, <<>>),
    Components = maps:get(<<"components">>, Item, []),
    Tradable = [Component || Component <- Components,
                             maps:get(<<"tradable">>, Component, false) =:= true],
    OwnedComponents = [inventory_set_component(Component, Stacks)
                       || Component <- Tradable],
    case equipment_category(Category) andalso length(Tradable) >= 2 andalso
         lists:any(fun(Component) -> maps:get(<<"owned">>, Component) > 0 end,
                   OwnedComponents) of
        false -> undefined;
        true ->
            Unique = maps:get(<<"uniqueName">>, Item),
            Quantity = lists:min(
                         [maps:get(<<"owned">>, Component) div
                          maps:get(<<"required">>, Component)
                          || Component <- OwnedComponents]),
            Ducats = lists:sum(
                       [maps:get(<<"required">>, Component) *
                        maps:get(<<"ducats">>, Component)
                        || Component <- OwnedComponents]),
            #{<<"id">> => <<"set:", Unique/binary>>,
              <<"name">> => <<(maps:get(<<"name">>, Item,
                                           fallback_name(Unique)))/binary,
                                " Set">>,
              <<"group">> => <<"sets">>,
              <<"category">> => Category,
              <<"type">> => <<"Set">>,
              <<"quantity">> => Quantity,
              <<"xp">> => maps:get(Unique, Mastery, 0),
              <<"mastered">> => maps:get(Unique, Mastery, 0) > 0,
              <<"tradable">> => true,
              <<"ducats">> => Ducats,
              <<"components">> => OwnedComponents,
              <<"asset">> => asset(Unique,
                                     maps:get(<<"imageName">>, Item, undefined))}
    end.

inventory_set_component(Component, Stacks) ->
    Unique = maps:get(<<"uniqueName">>, Component),
    #{<<"id">> => Unique,
      <<"name">> => maps:get(<<"name">>, Component, fallback_name(Unique)),
      <<"required">> => max(1, number(maps:get(<<"itemCount">>, Component, 1))),
      <<"owned">> => maps:get(count, maps:get(Unique, Stacks, #{}), 0),
      <<"ducats">> => number(maps:get(<<"primeSellingPrice">>, Component, 0)),
      <<"asset">> => asset(Unique, maps:get(<<"imageName">>, Component, undefined))}.

equipment_category(Category) ->
    lists:member(Category,
                 [<<"Warframes">>, <<"Archwing">>, <<"Primary">>,
                  <<"Secondary">>, <<"Melee">>, <<"Arch-Gun">>,
                  <<"Arch-Melee">>, <<"Sentinels">>]).

mastery_item_supported(Item) when is_map(Item) ->
    maps:get(<<"masterable">>, Item, false) =:= true andalso
    lists:member(maps:get(<<"category">>, Item, <<>>),
                 [<<"Warframes">>, <<"Archwing">>, <<"Primary">>, <<"Secondary">>,
                  <<"Melee">>, <<"Arch-Gun">>, <<"Arch-Melee">>, <<"Pets">>,
                  <<"Sentinels">>, <<"Misc">>]);
mastery_item_supported(_Item) -> false.

mastery_item(Item, Owned, Mastery, Pending) ->
    Unique = maps:get(<<"uniqueName">>, Item),
    Category = maps:get(<<"category">>, Item, <<>>),
    Type = maps:get(<<"type">>, Item, <<>>),
    Name = maps:get(<<"name">>, Item, fallback_name(Unique)),
    Xp = maps:get(Unique, Mastery, maps:get(xp, maps:get(Unique, Owned, #{}), 0)),
    MaxRank = max_rank(Name),
    Rank = mastery_rank(Xp, Category, Type, MaxRank),
    Components = mastery_components(maps:get(<<"components">>, Item, []), Owned),
    Missing = [Component || Component <- Components,
                            maps:get(<<"owned">>, Component) <
                            maps:get(<<"required">>, Component)],
    OwnedCount = maps:get(count, maps:get(Unique, Owned, #{}), 0),
    #{<<"id">> => Unique,
      <<"name">> => Name,
      <<"group">> => mastery_group(Category, Type),
      <<"category">> => Category,
      <<"type">> => Type,
      <<"mastery_requirement">> => number(maps:get(<<"masteryReq">>, Item, 0)),
      <<"owned">> => OwnedCount > 0,
      <<"pending">> => maps:get(Unique, Pending, false),
      <<"rank">> => Rank,
      <<"max_rank">> => MaxRank,
      <<"mastered">> => Rank >= MaxRank,
      <<"potential_xp">> => (MaxRank - Rank) * mastery_per_rank(Category, Type),
      <<"missing_parts">> => length(Missing),
      <<"from_relics">> => Missing =/= [] andalso
                            lists:all(fun from_owned_relic/1, Missing),
      <<"buyable">> => Missing =/= [] andalso
                        lists:all(fun(Component) ->
                            maps:get(<<"tradable">>, Component, false) =:= true
                        end, Missing),
      <<"components">> => Components,
      <<"asset">> => asset(Unique, maps:get(<<"imageName">>, Item, undefined))}.

mastery_components(Components, Owned) ->
    [begin
         Unique = maps:get(<<"uniqueName">>, Component),
         #{<<"id">> => Unique,
           <<"name">> => maps:get(<<"name">>, Component, fallback_name(Unique)),
           <<"required">> => max(1, number(maps:get(<<"itemCount">>, Component, 1))),
           <<"owned">> => maps:get(count, maps:get(Unique, Owned, #{}), 0),
           <<"tradable">> => maps:get(<<"tradable">>, Component, false) =:= true,
           <<"relic_drop">> => maps:get(<<"drops">>, Component, []) =/= [],
           <<"owned_relic">> => has_owned_relic(maps:get(<<"drops">>, Component, []), Owned),
           <<"asset">> => asset(Unique, maps:get(<<"imageName">>, Component, undefined))}
     end || Component <- Components, is_map(Component),
            is_binary(maps:get(<<"uniqueName">>, Component, undefined))].

from_owned_relic(Component) -> maps:get(<<"owned_relic">>, Component, false) =:= true.

has_owned_relic(Drops, Owned) ->
    lists:any(
      fun(Drop) ->
          Unique = maps:get(<<"uniqueName">>, Drop, undefined),
          maps:get(count, maps:get(Unique, Owned, #{}), 0) > 0
      end, Drops).

mastery_summary(Items, Profile) ->
    Groups = [<<"warframes">>, <<"weapons">>, <<"companions">>],
    GroupSummary = maps:from_list(
      [{Group, category_summary(Group, Items)} || Group <- Groups]),
    Total = length(Items),
    Mastered = length([ok || Item <- Items, maps:get(<<"mastered">>, Item)]),
    GroupSummary#{
        <<"total">> => Total,
        <<"mastered">> => Mastered,
        <<"percent">> => percent(Mastered, Total),
        <<"player_level">> => number(maps:get(<<"player_level">>, Profile, 0))
    }.

category_summary(Group, Items) ->
    Matching = [Item || Item <- Items, maps:get(<<"group">>, Item) =:= Group],
    #{<<"total">> => length(Matching),
      <<"mastered">> => length([ok || Item <- Matching,
                                      maps:get(<<"mastered">>, Item)])}.

mastery_group(Category, _Type) when Category =:= <<"Warframes">>;
                                    Category =:= <<"Archwing">> -> <<"warframes">>;
mastery_group(Category, _Type) when Category =:= <<"Pets">>;
                                    Category =:= <<"Sentinels">> -> <<"companions">>;
mastery_group(_Category, _Type) -> <<"weapons">>.

mastery_rank(Xp, Category, Type, MaxRank) ->
    Divisor = case mastery_per_rank(Category, Type) of 200 -> 1000; 100 -> 500 end,
    min(MaxRank, trunc(math:sqrt(max(0, Xp) / Divisor))).

mastery_per_rank(Category, Type) when Category =:= <<"Warframes">>;
                                      Category =:= <<"Archwing">>;
                                      Category =:= <<"Pets">>;
                                      Category =:= <<"Sentinels">>;
                                      Type =:= <<"K-Drive Component">> -> 200;
mastery_per_rank(_Category, _Type) -> 100.

max_rank(Name) ->
    case lists:any(fun(Prefix) -> binary:match(Name, Prefix) =/= nomatch end,
                   [<<"Kuva ">>, <<"Tenet ">>, <<"Coda ">>, <<"Paracesis">>]) of
        true -> 40;
        false -> 30
    end.

mastery_before(A, B) ->
    {maps:get(<<"mastered">>, A), acquisition_unknown(A),
     not maps:get(<<"owned">>, A),
     maps:get(<<"missing_parts">>, A), -maps:get(<<"potential_xp">>, A),
     string:lowercase(maps:get(<<"name">>, A))} <
    {maps:get(<<"mastered">>, B), acquisition_unknown(B),
     not maps:get(<<"owned">>, B),
     maps:get(<<"missing_parts">>, B), -maps:get(<<"potential_xp">>, B),
     string:lowercase(maps:get(<<"name">>, B))}.

acquisition_unknown(Item) ->
    not maps:get(<<"owned">>, Item) andalso
    not maps:get(<<"pending">>, Item) andalso
    maps:get(<<"components">>, Item) =:= [].

name_before(A, B) ->
    string:lowercase(maps:get(<<"name">>, A)) <
    string:lowercase(maps:get(<<"name">>, B)).

item_name(Unique, Entry, Catalog) ->
    case {maps:get(<<"component">>, Catalog, false),
          maps:get(<<"parentName">>, Catalog, undefined),
          maps:get(<<"name">>, Catalog, undefined)} of
        {true, Parent, Component} when is_binary(Parent), byte_size(Parent) > 0,
                                       is_binary(Component), byte_size(Component) > 0 ->
            <<Parent/binary, " ", Component/binary>>;
        _ ->
            first_present([maps:get(<<"name">>, Catalog, undefined),
                           maps:get(name, Entry, undefined), fallback_name(Unique)])
    end.

fallback_name(Unique) when is_binary(Unique) ->
    case binary:split(Unique, <<"/">>, [global, trim_all]) of
        [] -> Unique;
        Parts -> lists:last(Parts)
    end.

asset(_Unique, undefined) -> null;
asset(_Unique, null) -> null;
asset(Unique, ImageName) when is_binary(ImageName), byte_size(ImageName) > 0 ->
    #{<<"id">> => <<"wfcd-item:", Unique/binary>>,
      <<"source">> => <<"wfcd">>, <<"image_name">> => ImageName};
asset(_Unique, _ImageName) -> null.

first_present([]) -> undefined;
first_present([Value | Rest]) ->
    case present(Value) of true -> Value; false -> first_present(Rest) end.

present(undefined) -> false;
present(null) -> false;
present(<<>>) -> false;
present([]) -> false;
present(_) -> true.

number(Value) when is_integer(Value) -> Value;
number(Value) when is_float(Value) -> trunc(Value);
number(_) -> 0.

percent(_Current, 0) -> 0;
percent(Current, Total) -> round(Current * 100 / Total).

nullable(undefined) -> null;
nullable(Value) -> Value.
