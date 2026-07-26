%%%-------------------------------------------------------------------
%% Relic reward metadata joined from Market and the local player snapshot.
%%%-------------------------------------------------------------------
-module(wfcli_relic_context).

-export([build/6]).

-spec build([binary()], [map()], map(), map(), map(), map()) -> map().
build(Slugs, Items, Details, Quotes, PlayerSnapshot, Relics) ->
    ById = maps:from_list([{maps:get(<<"id">>, Item), Item}
                           || Item <- Items, maps:is_key(<<"id">>, Item)]),
    BySlug = maps:from_list([{maps:get(<<"slug">>, Item), Item}
                             || Item <- Items, maps:is_key(<<"slug">>, Item)]),
    Owned = owned_counts(PlayerSnapshot),
    Available = available_reward_slugs(Relics),
    Contexts = [context(Slug, BySlug, ById, Details, Quotes, Owned, Available)
                || Slug <- Slugs],
    Account = maps:filter(fun(_Key, Value) -> Value =/= undefined end, #{
          <<"platinum">> => profile_value(PlayerSnapshot, <<"premium_credits">>),
          <<"ducats">> => maps:get(
              <<"/Lotus/Types/Items/MiscItems/PrimeBucks">>, Owned, 0)
      }),
    #{<<"items">> => Contexts, <<"account">> => Account}.

context(Slug, BySlug, ById, Details, Quotes, Owned, Available) ->
    Item = maps:get(Slug, BySlug, #{}),
    Detail = maps:get(data, maps:get(Slug, Details, #{}), #{}),
    PartIds = maps:get(<<"setParts">>, Detail, []),
    Parts0 = [maps:get(Id, ById) || Id <- PartIds, maps:is_key(Id, ById)],
    Parts = [part(Part, Owned) || Part <- Parts0],
    Root = first_root(Parts),
    GameRef = maps:get(<<"game_ref">>, part(Item, Owned), undefined),
    Required = positive(maps:get(<<"quantityInSet">>, Item, 1), 1),
    Count = maps:get(GameRef, Owned, 0),
    RootRef = maps:get(<<"game_ref">>, Root, undefined),
    Quote = maps:get(Slug, Quotes, #{}),
    RootSlug = maps:get(<<"slug">>, Root, undefined),
    SetQuote = maps:get(RootSlug, Quotes, #{}),
    Base = (part(Item, Owned))#{
        <<"count_owned">> => Count,
        <<"total_to_own">> => Required,
        <<"crafted">> => maps:get(RootRef, Owned, 0) > 0,
        <<"set_complete">> => set_complete(Parts),
        <<"vaulted">> => vaulted(Item, Parts, Available),
        <<"parts">> => Parts,
        <<"lowest_sell">> => maps:get(lowest_sell, Quote, undefined),
        <<"highest_buy">> => maps:get(highest_buy, Quote, undefined),
        <<"set_slug">> => RootSlug,
        <<"set_price">> => maps:get(lowest_sell, SetQuote, undefined)
    },
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Base).

part(Item, Owned) when is_map(Item) ->
    Slug = maps:get(<<"slug">>, Item, undefined),
    GameRef = maps:get(<<"gameRef">>, Item, undefined),
    Required = positive(maps:get(<<"quantityInSet">>, Item, 1), 1),
    Base = #{
        <<"id">> => maps:get(<<"id">>, Item, undefined),
        <<"slug">> => Slug,
        <<"name">> => item_name(Item),
        <<"game_ref">> => GameRef,
        <<"ducats">> => maps:get(<<"ducats">>, Item, undefined),
        <<"set_root">> => maps:get(<<"setRoot">>, Item, false),
        <<"required">> => Required,
        <<"owned">> => maps:get(GameRef, Owned, 0),
        <<"asset">> => asset(Slug, Item)
    },
    maps:filter(fun(_Key, Value) -> Value =/= undefined end, Base).

asset(undefined, _Item) -> undefined;
asset(Slug, Item) ->
    English = maps:get(<<"en">>, maps:get(<<"i18n">>, Item, #{}), #{}),
    case maps:get(<<"subIcon">>, English,
                  maps:get(<<"thumb">>, English, maps:get(<<"icon">>, English, undefined))) of
        Path when is_binary(Path) ->
            #{<<"id">> => <<"market:", Slug/binary>>,
              <<"source">> => <<"market">>, <<"image_name">> => Path};
        _ -> undefined
    end.

available_reward_slugs(Relics) when map_size(Relics) =:= 0 -> undefined;
available_reward_slugs(Relics) ->
    maps:fold(
      fun(_Id, #{vaulted := false, rewards := Rewards}, Available) ->
              lists:foldl(
                fun(#{slug := Slug}, Acc) when is_binary(Slug) -> Acc#{Slug => true};
                   (_Reward, Acc) -> Acc
                end,
                Available,
                Rewards);
         (_Id, _Relic, Available) -> Available
      end,
      #{},
      Relics).

vaulted(_Item, _Parts, undefined) -> false;
vaulted(Item, Parts, Available) ->
    Prime = lists:member(<<"prime">>, maps:get(<<"tags">>, Item, [])),
    CraftParts = [Part || Part <- Parts, not maps:get(<<"set_root">>, Part, false)],
    Prime andalso CraftParts =/= [] andalso
    lists:all(
      fun(Part) ->
          case maps:get(<<"slug">>, Part, undefined) of
              Slug when is_binary(Slug) -> not maps:is_key(Slug, Available);
              _ -> false
          end
      end,
      CraftParts).

first_root(Parts) ->
    case [Part || Part <- Parts, maps:get(<<"set_root">>, Part, false)] of
        [Root | _] -> Root;
        [] -> #{}
    end.

set_complete([]) -> false;
set_complete(Parts) ->
    CraftParts = [Part || Part <- Parts, not maps:get(<<"set_root">>, Part, false)],
    CraftParts =/= [] andalso
    lists:all(fun(Part) ->
        maps:get(<<"owned">>, Part, 0) >= maps:get(<<"required">>, Part, 1)
    end, CraftParts).

owned_counts(PlayerSnapshot) ->
    Data = maps:get(data, PlayerSnapshot, #{}),
    Observation = maps:get(<<"inventory">>, Data, #{}),
    Index = maps:get(<<"index">>, Observation, #{}),
    Entries = maps:get(<<"equipment">>, Index, []) ++ maps:get(<<"stacks">>, Index, []),
    lists:foldl(fun owned_entry/2, #{}, Entries).

owned_entry(#{<<"item_type">> := ItemType, <<"count">> := Count}, Acc)
  when is_binary(ItemType), is_integer(Count), Count > 0 ->
    Acc#{ItemType => maps:get(ItemType, Acc, 0) + Count};
owned_entry(_Entry, Acc) -> Acc.

profile_value(PlayerSnapshot, Key) ->
    Data = maps:get(data, PlayerSnapshot, #{}),
    Observation = maps:get(<<"inventory">>, Data, #{}),
    maps:get(Key, maps:get(<<"profile">>, Observation, #{}), undefined).

item_name(Item) ->
    English = maps:get(<<"en">>, maps:get(<<"i18n">>, Item, #{}), #{}),
    maps:get(<<"name">>, English, maps:get(<<"slug">>, Item, undefined)).

positive(Value, _Default) when is_integer(Value), Value > 0 -> Value;
positive(_Value, Default) -> Default.
