%%%-------------------------------------------------------------------
%% wfcli top level supervisor.
%%%-------------------------------------------------------------------

-module(wfcli_sup).

-behaviour(supervisor).

-export([start_link/0, ensure_children/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-doc "Start any daemon children added by a hot update without restarting existing workers.".
-spec ensure_children() -> ok | {error, term()}.
ensure_children() ->
    ensure_children(daemon_children()).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 1,
        period => 5
    },
    ChildSpecs = daemon_children(),
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions

daemon_children() ->
    case daemon_env(daemon_enabled, false) of
        true ->
            [#{
                id => wfcli_worldstate_service,
                start => {wfcli_worldstate_service, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [wfcli_worldstate_service]
            }, #{
                id => wfcli_exports_store,
                start => {wfcli_exports_store, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [wfcli_exports_store]
            }, #{
                id => wfcli_source_manager,
                start => {wfcli_source_manager, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [wfcli_source_manager]
            }, #{
                id => wfcli_query_service,
                start => {wfcli_query_service, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [wfcli_query_service]
            }, #{
                id => wfcli_forma_service,
                start => {wfcli_forma_service, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [wfcli_forma_service]
            }, #{
                id => wfcli_player_service,
                start => {wfcli_player_service, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [wfcli_player_service]
            }, #{
                id => wfcli_market_service,
                start => {wfcli_market_service, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [wfcli_market_service]
            }, #{
                id => wfcli_asset_service,
                start => {wfcli_asset_service, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [wfcli_asset_service]
            }, #{
                id => wfcli_local_api,
                start => {wfcli_local_api, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [wfcli_local_api]
            }, #{
                id => wfcli_daemon,
                start => {wfcli_daemon, start_link, []},
                restart => permanent,
                shutdown => 5000,
                type => worker,
                modules => [wfcli_daemon]
            }];
        _ ->
            []
    end.

ensure_children([]) -> ok;
ensure_children([Spec | Rest]) ->
    case supervisor:start_child(?SERVER, Spec) of
        {ok, _Pid} -> ensure_children(Rest);
        {ok, _Pid, _Info} -> ensure_children(Rest);
        {error, {already_started, _Pid}} -> ensure_children(Rest);
        {error, already_present} -> ensure_children(Rest);
        {error, Reason} -> {error, {maps:get(id, Spec), Reason}}
    end.

daemon_env(Key, Default) ->
    application:get_env(wfdaemon, Key, Default).
