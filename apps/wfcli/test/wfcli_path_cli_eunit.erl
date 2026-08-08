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
              wfcli_path_cli:app_paths(wfdaemon))),
    ?assert(lists:member(
              {assets, wfcli_paths:cache_file("assets")},
              wfcli_path_cli:app_paths(wfdaemon))),
    GuiCache = filename:join(wfcli_paths:cache_dir(), "wfgui"),
    ?assertEqual(
       [{config, wfcli_paths:config_dir()},
        {cache, GuiCache},
        {derivatives, filename:join([GuiCache, "derivatives", "v1"])},
        {runtime, wfcli_paths:runtime_dir()}],
       wfcli_path_cli:app_paths(wfgui)).

owner_json_decodes_to_unformatted_paths_test() ->
    Json = jsone:encode(
             #{<<"app">> => <<"wfcompanion">>,
               <<"paths">> => [#{<<"kind">> => <<"cache">>,
                                  <<"path">> => <<"/tmp/wfcli">>}]}),
    ?assertEqual(
       {ok, [{<<"cache">>, "/tmp/wfcli"}]},
       wfcli_path_cli:decode_owner_report(<<"wfcompanion">>, Json)).

tree_renderer_handles_nested_nodes_test() ->
    ?assertEqual(
       <<"root\n├─ first\n└─ second\n   └─ leaf\n"/utf8>>,
       iolist_to_binary(
         wfcli_tree:format(
           {<<"root">>, [{<<"first">>, []},
                          {<<"second">>, [{<<"leaf">>, []}]}]}))).

tree_renderer_handles_more_than_ten_labels_test() ->
    Children = [{["node-", integer_to_list(Index)], []}
                || Index <- lists:seq(1, 12)],
    Output = iolist_to_binary(wfcli_tree:format({<<"root">>, Children})),
    ?assertMatch({_, _}, binary:match(Output, <<"node-10\n">>)),
    ?assertMatch({_, _}, binary:match(Output, <<"node-12\n">>)).

merged_tree_nests_logical_children_below_symlink_test() ->
    Link = "/home/test/.cache/wfcli",
    Target = "/mnt/cache/wfcli",
    Descriptions =
        [#{path => Link, status => directory, links => [{Link, Target}]},
         #{path => filename:join(Link, "captures"), status => directory,
           links => [{Link, Target}]},
         #{path => filename:join([Link, "wfgui", "derivatives", "v1"]),
           status => missing, links => [{Link, Target}]}],
    ?assertEqual(
       <<"/\n"
         "└─ home\n"
         "   └─ test\n"
         "      └─ .cache\n"
         "         └─ wfcli -> /mnt/cache/wfcli\n"
         "            ├─ captures\n"
         "            └─ wfgui\n"
         "               └─ derivatives\n"
         "                  └─ v1 (missing)\n"/utf8>>,
       iolist_to_binary(
         wfcli_tree:format(wfcli_path_cli:filesystem_tree(Descriptions)))).

symlink_target_is_reported_test() ->
    Base = filename:join(
             "/tmp",
             "wfcli-path-report-" ++
             integer_to_list(erlang:unique_integer([positive]))),
    Link = Base ++ "-link",
    ok = file:make_dir(Base),
    ok = file:make_symlink(filename:basename(Base), Link),
    try
        ?assertEqual({directory, [{Link, Base}]}, wfcli_path_cli:describe(Link))
    after
        file:delete(Link),
        file:del_dir(Base)
    end.

linked_parent_is_resolved_through_missing_tail_test() ->
    Root = temporary_path("wfcli-path-parent"),
    Real = filename:join(Root, "real"),
    Link = filename:join(Root, "linked"),
    Logical = filename:join([Link, "nested", "cache"]),
    ok = file:make_dir(Root),
    ok = file:make_dir(Real),
    ok = file:make_symlink("real", Link),
    try
        ?assertEqual({missing, [{Link, Real}]}, wfcli_path_cli:describe(Logical))
    after
        file:delete(Link),
        file:del_dir(Real),
        file:del_dir(Root)
    end.

missing_path_without_link_stays_missing_test() ->
    ?assertEqual({missing, []},
                 wfcli_path_cli:describe(temporary_path("wfcli-path-missing"))).

system_ancestors_are_hidden_but_user_chain_is_kept_test() ->
    Home = "/home/tester",
    ?assertEqual(
       [{"/home/tester/.cache/wfcli", "/mnt/cache"},
        {"/mnt/cache", "/data/cache"}],
       wfcli_path_cli:links_in_scope(
         "/home/tester/.cache/wfcli/data",
         [{"/home", "/var/home"},
          {"/home/tester/.cache/wfcli", "/mnt/cache"},
          {"/mnt/cache", "/data/cache"}],
         Home)).

temporary_path(Prefix) ->
    filename:join(
      "/tmp",
      Prefix ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))).
