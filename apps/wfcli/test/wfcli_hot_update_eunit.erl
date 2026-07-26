%%%-------------------------------------------------------------------
%% EUnit tests for coordinated daemon hot loading.
%%%-------------------------------------------------------------------
-module(wfcli_hot_update_eunit).

-include_lib("eunit/include/eunit.hrl").

read_build_directory_test() ->
    Dir = filename:join(code:lib_dir(wfdaemon), "ebin"),
    {ok, Bundles} = wfcli_hot_update:read_directory(Dir),
    ?assert(lists:any(
              fun(#{module := Module}) -> Module =:= wfcli_hot_update end,
              Bundles)).

read_embedded_daemon_applications_test() ->
    {ok, Bundles} = wfcli_hot_update:read_applications([wfcore, wfdaemon]),
    Modules = [Module || #{module := Module, binary := Binary} <- Bundles,
                         is_binary(Binary)],
    ?assert(lists:member(wfcli_protocol, Modules)),
    ?assert(lists:member(wfcli_hot_update, Modules)),
    ?assertEqual(length(Modules), length(lists:usort(Modules))).

build_identity_is_order_independent_and_tracks_modules_test() ->
    {ok, One, BeamOne} = compile_fixture(wfcli_hot_update_fixture_one, 1),
    {ok, Two, BeamTwo} = compile_fixture(wfcli_hot_update_fixture_two, 2),
    BundleOne = #{module => One, filename => "one.beam", binary => BeamOne},
    BundleTwo = #{module => Two, filename => "two.beam", binary => BeamTwo},
    {ok, Both} = wfcli_hot_update:build_identity([BundleOne, BundleTwo]),
    {ok, Reversed} = wfcli_hot_update:build_identity([BundleTwo, BundleOne]),
    {ok, OnlyOne} = wfcli_hot_update:build_identity([BundleOne]),
    ?assertEqual(Both, Reversed),
    ?assertNotEqual(Both, OnlyOne),
    ?assertEqual(64, byte_size(Both)).

loads_changed_beam_and_skips_identical_beam_test() ->
    Module = wfcli_hot_update_fixture,
    cleanup_module(Module),
    {ok, Module, V1} = compile_fixture(Module, 1),
    {module, Module} = code:load_binary(Module, "wfcli_hot_update_fixture.beam", V1),
    try
        ?assertEqual(1, Module:value()),
        {ok, Module, V2} = compile_fixture(Module, 2),
        Bundle = #{module => Module,
                   filename => "wfcli_hot_update_fixture.beam",
                   binary => V2},
        {ok, Changed} = wfcli_hot_update:apply([Bundle]),
        ?assertEqual([Module], maps:get(loaded, Changed)),
        ?assertEqual(2, Module:value()),
        {ok, Unchanged} = wfcli_hot_update:apply([Bundle]),
        ?assertEqual([], maps:get(loaded, Unchanged)),
        ?assertEqual([Module], maps:get(unchanged, Unchanged))
    after
        cleanup_module(Module)
    end.

stateful_service_runs_code_change_test() ->
    Module = wfcli_worldstate_service,
    ensure_service_stopped(),
    {Module, Original, Filename} = code:get_object_code(Module),
    {ok, Module, Changed} = recompile_with_test_vsn(Module, Original),
    application:set_env(wfdaemon, daemon_idle_shutdown, false),
    {ok, Pid} = Module:start_link(),
    try
        Bundle = #{module => Module,
                   filename => "wfcli_worldstate_service.beam",
                   binary => Changed},
        {ok, Result} = wfcli_hot_update:apply([Bundle]),
        ?assertEqual([Module], maps:get(loaded, Result)),
        ?assertEqual([Module], maps:get(migrated, Result)),
        ?assert(is_process_alive(Pid)),
        ?assertMatch(#{idle_policy := persistent}, Module:status())
    after
        gen_server:stop(Pid),
        restore_module(Module, Filename, Original)
    end.

all_supervised_stateful_services_are_migrated_test() ->
    ?assertEqual(
       [wfcli_worldstate_service, wfcli_exports_store, wfcli_source_manager,
        wfcli_query_service, wfcli_forma_service, wfcli_player_service,
        wfcli_market_service, wfcli_local_api, wfcli_daemon],
       [Module || {_Name, Module} <- wfcli_hot_update:stateful_candidates()]).

local_api_can_be_restarted_for_code_purge_test() ->
    Started = whereis(wfcli_sup) =:= undefined,
    case Started of true -> ok = wfcli_test_daemon:start(); false -> ok end,
    try
        Old = whereis(wfcli_local_api),
        ?assert(is_pid(Old)),
        ok = wfcli_hot_update:restart_supervised_child(wfcli_local_api),
        New = whereis(wfcli_local_api),
        ?assert(is_pid(New)),
        ?assertNotEqual(Old, New),
        ?assert(is_process_alive(New))
    after
        case Started of true -> wfcli_test_daemon:stop(); false -> ok end
    end.

compile_fixture(Module, Value) ->
    Forms = [
        {attribute, 1, module, Module},
        {attribute, 2, export, [{value, 0}]},
        {function, 3, value, 0,
         [{clause, 3, [], [], [{integer, 3, Value}]}]}
    ],
    case compile:forms(Forms, [binary]) of
        {ok, Module, Binary} -> {ok, Module, Binary};
        {ok, Module, Binary, _Warnings} -> {ok, Module, Binary}
    end.

recompile_with_test_vsn(Module, Binary) ->
    {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} =
        beam_lib:chunks(Binary, [abstract_code]),
    WithoutVsn = [Form || Form <- Forms, not is_vsn_attribute(Form)],
    WithVsn = insert_vsn(WithoutVsn, []),
    case compile:forms(WithVsn, [binary, debug_info]) of
        {ok, Module, Changed} -> {ok, Module, Changed};
        {ok, Module, Changed, _Warnings} -> {ok, Module, Changed}
    end.

is_vsn_attribute({attribute, _Line, vsn, _Value}) -> true;
is_vsn_attribute(_Form) -> false.

insert_vsn([{attribute, Line, module, _Module} = Form | Rest], Acc) ->
    lists:reverse(Acc) ++ [Form, {attribute, Line, vsn, hot_update_test} | Rest];
insert_vsn([Form | Rest], Acc) ->
    insert_vsn(Rest, [Form | Acc]).

restore_module(Module, Filename, Original) ->
    true = code:soft_purge(Module),
    {module, Module} = code:load_binary(Module, Filename, Original),
    _ = code:purge(Module),
    ok.

ensure_service_stopped() ->
    case whereis(wfcli_worldstate_service) of
        undefined -> ok;
        _Pid -> gen_server:stop(wfcli_worldstate_service)
    end.

cleanup_module(Module) ->
    _ = code:purge(Module),
    _ = code:delete(Module),
    _ = code:purge(Module),
    ok.
