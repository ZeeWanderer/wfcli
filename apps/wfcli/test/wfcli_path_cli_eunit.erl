%%%-------------------------------------------------------------------
%% EUnit coverage for per-application path reporting.
%%%-------------------------------------------------------------------
-module(wfcli_path_cli_eunit).

-include_lib("eunit/include/eunit.hrl").

application_paths_use_shared_xdg_roots_test() ->
    ?assertEqual(
       [{config, wfcli_paths:config_dir()},
        {cache, wfcli_paths:cache_dir()},
        {state, wfcli_paths:state_dir()}],
       wfcli_path_cli:app_paths(wfcli)),
    ?assert(lists:member(
              {runtime, wfcli_paths:runtime_dir()},
              wfcli_path_cli:app_paths(wfdaemon))).

symlink_target_is_reported_test() ->
    Base = filename:join(
             "/tmp",
             "wfcli-path-report-" ++
             integer_to_list(erlang:unique_integer([positive]))),
    Link = Base ++ "-link",
    ok = file:make_dir(Base),
    ok = file:make_symlink(filename:basename(Base), Link),
    try
        ?assertEqual({symlink, Base}, wfcli_path_cli:describe(Link))
    after
        file:delete(Link),
        file:del_dir(Base)
    end.
