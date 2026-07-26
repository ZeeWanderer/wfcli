%%%-------------------------------------------------------------------
%% Owned relic recommendations from WFCD rewards, player data, and Market quotes.
%%%-------------------------------------------------------------------
-module(wfcli_relic_recommendations).

-export([fetch/0, parse/1, build/5, price_slugs/5]).

-define(URL,
        "https://raw.githubusercontent.com/WFCD/warframe-items/master/data/json/Relics.json").
-define(VOID_TRACES, <<"/Lotus/Types/Items/MiscItems/VoidTearDrop">>).

-doc "Fetch and compact the WFCD relic catalog.".
-spec fetch() -> {ok, map()} | {error, term()}.
fetch() ->
    Headers = [{"user-agent", "wfcli/0.1 (+https://github.com/ZeeWanderer/wfcli)"},
               {"accept", "application/json"}],
    Result = try
        case application:get_env(wfdaemon, relic_catalog_http_fun) of
            {ok, Fun} when is_function(Fun, 2) -> Fun(?URL, Headers);
            _ -> real_http_get(?URL, Headers)
        end
    catch HttpClass:HttpReason ->
        {error, {relic_catalog_http_crash, HttpClass, HttpReason}}
    end,
    case Result of
        {ok, 200, Body} -> parse(iolist_to_binary(Body));
        {ok, Status, _Body} -> {error, {relic_catalog_http_status, Status}};
        {error, Reason} -> {error, {relic_catalog_http_failed, Reason}};
        Other -> {error, {invalid_relic_catalog_http_result, Other}}
    end.

-doc "Parse WFCD Relics.json into the fields needed by recommendation scoring.".
-spec parse(binary()) -> {ok, map()} | {error, term()}.
parse(Body) ->
    try jsone:decode(Body, [{object_format, map}]) of
        Values when is_list(Values) ->
            Relics = lists:filtermap(fun compact/1, Values),
            case Relics of
                [] -> {error, empty_relic_catalog};
                _ -> {ok, maps:from_list(Relics)}
            end;
        Other -> {error, {invalid_relic_catalog_root, Other}}
    catch error:Reason -> {error, {invalid_relic_catalog_json, Reason}}
    end.

-doc "Rank owned relics in one era using four-player expected best reward.".
-spec build(binary(), map(), [map()], map(), map()) -> map().
build(Era, Catalog, Items, Quotes, PlayerSnapshot) ->
    Owned = owned_counts(PlayerSnapshot),
    ItemBySlug = maps:from_list(
                   [{maps:get(<<"slug">>, Item), Item}
                    || Item <- Items, maps:is_key(<<"slug">>, Item)]),
    Suggestions = ranked(Era, Catalog, Owned, ItemBySlug, Quotes),
    #{<<"trace_count">> => maps:get(?VOID_TRACES, Owned, 0),
      <<"items">> => lists:sublist(Suggestions, 4)}.

-doc "Return reward slugs worth warming for the highest-ducat owned relics.".
-spec price_slugs(binary(), map(), [map()], map(), non_neg_integer()) -> [binary()].
price_slugs(Era, Catalog, Items, PlayerSnapshot, CandidateLimit) ->
    Owned = owned_counts(PlayerSnapshot),
    ItemBySlug = maps:from_list(
                   [{maps:get(<<"slug">>, Item), Item}
                    || Item <- Items, maps:is_key(<<"slug">>, Item)]),
    Candidates = ranked_candidates(Era, Catalog, Owned, ItemBySlug, #{}),
    Selected = lists:sublist(Candidates, CandidateLimit),
    unique(lists:append(
             [maps:get(price_slugs, Suggestion, []) || Suggestion <- Selected]), []).

real_http_get(Url, Headers) ->
    case httpc:request(get, {Url, Headers}, [{timeout, 30000}],
                       [{body_format, binary}]) of
        {ok, {{_Version, Status, _Reason}, _ResponseHeaders, Body}} ->
            {ok, Status, Body};
        {error, Reason} -> {error, Reason}
    end.

compact(#{<<"uniqueName">> := Unique, <<"name">> := Name,
          <<"rewards">> := Rewards} = Relic)
  when is_binary(Unique), is_binary(Name), is_list(Rewards) ->
    case era(Name) of
        undefined -> false;
        Era ->
            CompactRewards = lists:filtermap(fun compact_reward/1, Rewards),
            {true, {Unique, #{name => Name, era => Era,
                              vaulted => maps:get(<<"vaulted">>, Relic, false) =:= true,
                              rewards => CompactRewards}}}
    end;
compact(_Relic) -> false.

compact_reward(#{<<"chance">> := Chance, <<"item">> := Item})
  when (is_integer(Chance) orelse is_float(Chance)), is_map(Item) ->
    Market = maps:get(<<"warframeMarket">>, Item, #{}),
    Slug = maps:get(<<"urlName">>, Market, undefined),
    {true, #{chance => Chance, slug => Slug}};
compact_reward(_Reward) -> false.

era(Name) ->
    case binary:split(Name, <<" ">>, [global, trim_all]) of
        [Era | _] when Era =:= <<"Lith">>; Era =:= <<"Meso">>;
                       Era =:= <<"Neo">>; Era =:= <<"Axi">>;
                       Era =:= <<"Requiem">> ->
            string:lowercase(Era);
        _ -> undefined
    end.

ranked(Era, Catalog, Owned, ItemBySlug, Quotes) ->
    Candidates = ranked_candidates(Era, Catalog, Owned, ItemBySlug, Quotes),
    [maps:without([price_slugs, price_ready, sort_platinum, sort_ducats], Candidate)
     || Candidate <- Candidates].

ranked_candidates(Era, Catalog, Owned, ItemBySlug, Quotes) ->
    Candidates = lists:filtermap(
      fun({Unique, Relic}) ->
          Count = maps:get(Unique, Owned, 0),
          case Count > 0 andalso era_matches(Era, maps:get(era, Relic)) of
              true ->
                  Rewards = maps:get(rewards, Relic),
                  PriceReady = prices_ready(Rewards, Quotes),
                  Platinum = expected_max(
                               Rewards,
                               fun(Reward) -> reward_platinum(Reward, Quotes) end),
                  Ducats = expected_max(
                             Rewards,
                             fun(Reward) -> reward_ducats(Reward, ItemBySlug) end),
                  Public = #{<<"name">> => maps:get(name, Relic),
                             <<"amount_owned">> => Count,
                             <<"vaulted">> => maps:get(vaulted, Relic),
                             <<"favorite">> => false,
                             <<"expected_platinum">> =>
                                 case PriceReady of true -> Platinum; false -> null end,
                             <<"expected_ducats">> => Ducats},
                  Slugs = [Slug || #{slug := Slug} <- Rewards, is_binary(Slug)],
                  {true, Public#{price_slugs => Slugs,
                                 price_ready => PriceReady,
                                 sort_platinum => Platinum,
                                 sort_ducats => Ducats}};
              false -> false
          end
      end,
      maps:to_list(Catalog)),
    lists:sort(fun recommendation_before/2, Candidates).

recommendation_before(A, B) ->
    KeyA = {maps:get(price_ready, A), maps:get(sort_platinum, A),
            maps:get(sort_ducats, A), maps:get(<<"name">>, A)},
    KeyB = {maps:get(price_ready, B), maps:get(sort_platinum, B),
            maps:get(sort_ducats, B), maps:get(<<"name">>, B)},
    KeyA > KeyB.

era_matches(<<"all">>, Era) ->
    lists:member(Era, [<<"lith">>, <<"meso">>, <<"neo">>, <<"axi">>]);
era_matches(Era, Era) -> true;
era_matches(_Wanted, _Actual) -> false.

prices_ready(Rewards, Quotes) ->
    lists:all(
      fun(#{slug := undefined}) -> true;
         (#{slug := Slug}) ->
              Quote = maps:get(Slug, Quotes, #{}),
              is_number(maps:get(lowest_sell, Quote, undefined))
      end,
      Rewards).

reward_platinum(#{slug := undefined}, _Quotes) -> 0;
reward_platinum(#{slug := Slug}, Quotes) ->
    value(maps:get(lowest_sell, maps:get(Slug, Quotes, #{}), 0)).

reward_ducats(#{slug := undefined}, _Items) -> 0;
reward_ducats(#{slug := Slug}, Items) ->
    value(maps:get(<<"ducats">>, maps:get(Slug, Items, #{}), 0)).

value(Number) when is_integer(Number); is_float(Number) -> Number;
value(_Other) -> 0.

expected_max([], _ValueFun) -> 0;
expected_max(Rewards, ValueFun) ->
    Distribution = lists:foldl(
      fun(#{chance := Chance} = Reward, Acc) ->
          Value = ValueFun(Reward),
          Acc#{Value => maps:get(Value, Acc, 0.0) + Chance}
      end,
      #{},
      Rewards),
    Total = lists:sum(maps:values(Distribution)),
    case Total > 0 of
        false -> 0;
        true ->
            {_Cumulative, Expected} = lists:foldl(
              fun({Value, Chance}, {Cumulative, Acc}) ->
                  Next = Cumulative + Chance / Total,
                  Probability = math:pow(Next, 4) - math:pow(Cumulative, 4),
                  {Next, Acc + Value * Probability}
              end,
              {0.0, 0.0},
              lists:sort(maps:to_list(Distribution))),
            round(Expected)
    end.

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

unique([], Acc) -> lists:reverse(Acc);
unique([Value | Rest], Acc) ->
    case lists:member(Value, Acc) of
        true -> unique(Rest, Acc);
        false -> unique(Rest, [Value | Acc])
    end.
