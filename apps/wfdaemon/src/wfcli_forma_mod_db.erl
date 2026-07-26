%%%-------------------------------------------------------------------
%% Mod lookup from ExportUpgrades metadata for missing polarity/cost.
%%%-------------------------------------------------------------------
-module(wfcli_forma_mod_db).

-export([lookup/1]).

lookup(Name) ->
    wfcli_worldstate_projector:mod_lookup_by_name(Name).
