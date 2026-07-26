%%%-------------------------------------------------------------------
%% Data-only client/daemon protocol contract.
%%%-------------------------------------------------------------------
-module(wfcli_protocol).

-export([version/0, default_datasets/0, all_datasets/0, owner/1]).

-doc "Current client/daemon wire protocol version.".
-spec version() -> pos_integer().
version() -> 5.

-doc "Official datasets searched by a query with no dataset selector.".
-spec default_datasets() -> [atom()].
default_datasets() -> [worldstate, mods, items, codex].

-doc "Every supported query dataset, including optional community data.".
-spec all_datasets() -> [atom()].
all_datasets() -> default_datasets() ++ [enemies, drops, player, market].

-doc "Return daemon process that owns one request source.".
-spec owner(map()) -> atom() | undefined.
owner(#{source := Source}) when Source =:= worldstate; Source =:= trader; Source =:= teshin ->
    wfcli_worldstate_service;
owner(#{source := exports}) -> wfcli_exports_store;
owner(#{source := query}) -> wfcli_query_service;
owner(#{source := metadata}) -> wfcli_source_manager;
owner(#{source := forma}) -> wfcli_forma_service;
owner(#{source := market}) -> wfcli_market_service;
owner(_) -> undefined.
