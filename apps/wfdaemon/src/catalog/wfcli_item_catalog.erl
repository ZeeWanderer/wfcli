%%%-------------------------------------------------------------------
%% Compact WFCD item graph used by player inventory and mastery views.
%%%-------------------------------------------------------------------
-module(wfcli_item_catalog).

-include_lib("kernel/include/file.hrl").

-export([load/0, source/0, update/0, index/1, lookup/2]).
-ifdef(TEST).
-export([compact/1]).
-endif.

-define(ITEM_FILE, "WFCDItems.json").
-define(URL,
        "https://raw.githubusercontent.com/WFCD/warframe-items/master/data/json/All.json").
-define(CACHE_KEY, {?MODULE, cache}).

-doc "Load compact item records, caching by file signature until next update.".
-spec load() -> {ok, [map()], map()} | {error, term()}.
load() ->
    Path = source(),
    case file:read_file_info(Path, [{time, posix}]) of
        {ok, #file_info{mtime = Modified, size = Size}} ->
            Signature = {Path, Modified, Size},
            case persistent_term:get(?CACHE_KEY, undefined) of
                #{signature := Signature, entries := Entries, meta := Meta} ->
                    {ok, Entries, Meta};
                _ -> load_file(Path, Signature)
            end;
        {error, Reason} -> {error, {item_catalog_missing, Path, Reason}}
    end.

-doc "Return preferred managed item-catalog path.".
-spec source() -> file:filename_all().
source() ->
    case application:get_env(wfdaemon, item_catalog_file) of
        {ok, Path} when is_list(Path); is_binary(Path) -> Path;
        _ -> default_source()
    end.

default_source() ->
    Paths = wfcli_worldstate:metadata_paths(?ITEM_FILE),
    case [Path || Path <- Paths, filelib:is_file(Path)] of
        [Path | _] -> Path;
        [] -> case Paths of
                  [Path | _] -> Path;
                  [] -> wfcli_paths:cache_file(?ITEM_FILE)
              end
    end.

-doc "Refresh and compact WFCD All.json for local player-data joins.".
-spec update() -> ok | {error, term()}.
update() ->
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    Headers = [{"user-agent", "wfcli/0.1 (+https://github.com/ZeeWanderer/wfcli)"},
               {"accept", "application/json"}],
    case httpc:request(get, {?URL, Headers}, [{timeout, 120000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _ResponseHeaders, Body}} -> persist(Body);
        {ok, {{_, Code, _}, _ResponseHeaders, _Body}} ->
            {error, {item_catalog_http_status, Code}};
        {error, Reason} -> {error, {item_catalog_http_failed, Reason}}
    end.

-doc "Index canonical items and nested components by game identity.".
-spec index([map()]) -> map().
index(Items) when is_list(Items) ->
    lists:foldl(
      fun(Item, Acc) when is_map(Item) ->
          Acc1 = put_index_entry(Item, Item, false, Acc),
          lists:foldl(
            fun(Component, Inner) -> put_index_entry(Component, Item, true, Inner) end,
            Acc1, maps:get(<<"components">>, Item, []));
         (_Item, Acc) -> Acc
      end, #{}, Items);
index(_Items) -> #{}.

-doc "Look up one canonical item or component in an indexed catalog.".
-spec lookup(binary(), map()) -> map() | undefined.
lookup(Identity, Index) when is_binary(Identity), is_map(Index) ->
    maps:get(Identity, Index, undefined);
lookup(_Identity, _Index) -> undefined.

load_file(Path, Signature) ->
    case file:read_file(Path) of
        {ok, Body} ->
            try jsone:decode(Body, [{object_format, map}]) of
                #{<<"entries">> := Entries} = Wrapper when is_list(Entries) ->
                    Meta = #{source => maps:get(<<"source">>, Wrapper, <<"WFCD">>),
                             version => maps:get(<<"version">>, Wrapper, <<"unknown">>),
                             fetched_at => maps:get(<<"fetchedAt">>, Wrapper, 0)},
                    persistent_term:put(
                      ?CACHE_KEY,
                      #{signature => Signature, entries => Entries, meta => Meta}),
                    {ok, Entries, Meta};
                _ -> {error, {bad_item_catalog, Path}}
            catch error:Reason -> {error, {bad_item_catalog_json, Path, Reason}}
            end;
        {error, Reason} -> {error, {item_catalog_read_failed, Path, Reason}}
    end.

persist(Body) ->
    try jsone:decode(Body, [{object_format, map}]) of
        Values when is_list(Values) ->
            Entries = [Item || Value <- Values,
                                Item <- [compact(Value)], Item =/= undefined],
            Wrapper = #{<<"source">> => list_to_binary(?URL),
                        <<"version">> => content_version(Body),
                        <<"fetchedAt">> => erlang:system_time(second),
                        <<"entries">> => Entries},
            case wfcli_worldstate:write_metadata_file(?ITEM_FILE, jsone:encode(Wrapper)) of
                ok -> persistent_term:erase(?CACHE_KEY), ok;
                Error -> Error
            end;
        _ -> {error, bad_item_catalog_payload}
    catch error:Reason -> {error, {bad_item_catalog_json, Reason}}
    end.

compact(Item) when is_map(Item) ->
    case maps:get(<<"uniqueName">>, Item, undefined) of
        Unique when is_binary(Unique), byte_size(Unique) > 0 ->
            (copy(Item,
                  [<<"uniqueName">>, <<"name">>, <<"imageName">>, <<"category">>,
                   <<"type">>, <<"masteryReq">>, <<"masterable">>, <<"tradable">>,
                   <<"isPrime">>, <<"vaulted">>, <<"primeSellingPrice">>,
                   <<"polarities">>, <<"aura">>, <<"exilusPolarity">>,
                   <<"stancePolarity">>, <<"polarity">>, <<"baseDrain">>,
                   <<"fusionLimit">>, <<"rarity">>, <<"compatName">>,
                   <<"productCategory">>, <<"exaltedSlot">>,
                   <<"isGalvanized">>, <<"isAmalgam">>, <<"isRiven">>]))#{
                <<"components">> => compact_components(maps:get(<<"components">>, Item, []))
            };
        _ -> undefined
    end;
compact(_Item) -> undefined.

compact_components(Values) when is_list(Values) ->
    [Component || Value <- Values,
                  Component <- [compact_component(Value)], Component =/= undefined];
compact_components(_Values) -> [].

compact_component(Component) when is_map(Component) ->
    case maps:get(<<"uniqueName">>, Component, undefined) of
        Unique when is_binary(Unique), byte_size(Unique) > 0 ->
            (copy(Component,
                  [<<"uniqueName">>, <<"name">>, <<"imageName">>, <<"type">>,
                   <<"itemCount">>, <<"tradable">>, <<"primeSellingPrice">>]))#{
                <<"drops">> => compact_drops(maps:get(<<"drops">>, Component, []))
            };
        _ -> undefined
    end;
compact_component(_Component) -> undefined.

compact_drops(Values) when is_list(Values) ->
    [copy(Drop, [<<"location">>, <<"chance">>, <<"uniqueName">>])
     || Drop <- Values, is_map(Drop), relic_drop(Drop)];
compact_drops(_Values) -> [].

put_index_entry(Item, Parent, IsComponent, Acc) when is_map(Item) ->
    case maps:get(<<"uniqueName">>, Item, undefined) of
        Identity when is_binary(Identity) ->
            Candidate = Item#{
                <<"parentCategory">> => maps:get(<<"category">>, Parent, <<>>),
                <<"parentName">> => maps:get(<<"name">>, Parent, <<>>),
                <<"parentUniqueName">> => maps:get(<<"uniqueName">>, Parent, undefined),
                <<"parentType">> => maps:get(<<"type">>, Parent, <<>>),
                <<"parentIsPrime">> => maps:get(<<"isPrime">>, Parent, false),
                <<"parentVaulted">> => maps:get(<<"vaulted">>, Parent, undefined),
                <<"component">> => IsComponent
            },
            maps:update_with(
              Identity, fun(Existing) -> prefer_index_entry(Existing, Candidate) end,
              Candidate, Acc);
        _ -> Acc
    end;
put_index_entry(_Item, _Parent, _IsComponent, Acc) -> Acc.

prefer_index_entry(#{<<"component">> := true} = Component,
                   #{<<"component">> := false} = Item) ->
    maps:merge(Component, Item);
prefer_index_entry(#{<<"component">> := false} = Item,
                   #{<<"component">> := true} = Component) ->
    maps:merge(Component, Item);
prefer_index_entry(Existing, Candidate) ->
    case {present(maps:get(<<"imageName">>, Existing, undefined)),
          present(maps:get(<<"imageName">>, Candidate, undefined))} of
        {false, true} -> maps:merge(Existing, Candidate);
        _ -> maps:merge(Candidate, Existing)
    end.

relic_drop(Drop) ->
    case maps:get(<<"location">>, Drop, <<>>) of
        Location when is_binary(Location) ->
            binary:match(Location, <<" Relic">>) =/= nomatch;
        _ -> false
    end.

copy(Map, Keys) ->
    maps:with([Key || Key <- Keys, maps:is_key(Key, Map)], Map).

present(undefined) -> false;
present(null) -> false;
present(<<>>) -> false;
present([]) -> false;
present(_) -> true.

content_version(Body) ->
    application:ensure_all_started(crypto),
    binary:encode_hex(crypto:hash(sha256, Body), lowercase).
