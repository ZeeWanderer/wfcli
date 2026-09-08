%%%-------------------------------------------------------------------
%% EUnit coverage for build request coordination and revision storage.
%%%-------------------------------------------------------------------
-module(wfcli_build_service_eunit).

-include_lib("eunit/include/eunit.hrl").

hot_update_clears_derived_cache_test() ->
    Cached = #{request => #{expires => 1, data => stale}},
    {ok, State} = wfcli_build_service:code_change(
                    old, #{cache => Cached, pending => #{}}, []),
    ?assertEqual(#{}, maps:get(cache, State)).

coalesces_requests_and_stores_revision_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(State) -> fun() -> exercise(State) end end}.

persists_group_members_and_publishes_changes_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(_State) -> fun group_exercise/0 end}.

group_write_failure_is_not_acknowledged_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(_State) -> fun group_write_failure/0 end}.

failed_load_preserves_user_file_test_() ->
    [{setup, fun setup/0, fun cleanup/1,
      fun(_State) -> fun() -> failed_load(Binary) end end}
     || Binary <- [<<"damaged">>,
                   term_to_binary(#{schema => 999, goals => #{saved => user_data}}),
                   term_to_binary(#{schema => 3, goals => invalid})]].

planning_refreshes_physical_target_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(_) -> fun planning_refreshes_physical_target/0 end}.

interrupted_plan_releases_waiters_test_() ->
    [{setup, fun setup/0, fun cleanup/1,
      fun(_) -> fun() -> interrupted_plan(Interruption) end end}
     || Interruption <- [target_changed, service_restarted]].

setup() ->
    Root = filename:join("/tmp", "wfcli-build-service-" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    Store = filename:join(Root, "builds.term"),
    Calls = ets:new(wfcli_build_service_calls, [set, public]),
    true = ets:insert(Calls, {count, 0}),
    Catalog = #{schema => wfcli_overframe_source:catalog_schema(),
                fetched_at => erlang:system_time(millisecond),
                items_by_path => #{}, items_by_id => #{},
                mods_by_id => #{}, rivens_by_id => #{}},
    application:set_env(wfdaemon, build_store_file, Store),
    application:set_env(wfdaemon, build_cache_file, Store ++ ".cache"),
    application:set_env(wfdaemon, build_equipment_fun, fun equipment/0),
    application:set_env(wfdaemon, build_catalog_fun, fun() -> {ok, Catalog} end),
    application:set_env(wfdaemon, build_source_fun,
                        fun(Request, _SourceCatalog) ->
                            _ = ets:update_counter(Calls, count, 1),
                            timer:sleep(100),
                            source_reply(Request)
                        end),
    {ok, Pid} = wfcli_build_service:start_link(),
    {FormaPid, OwnForma} = case whereis(wfcli_forma_service) of
        undefined ->
            {ok, Started} = wfcli_forma_service:start_link(),
            {Started, true};
        Existing -> {Existing, false}
    end,
    #{root => Root, pid => Pid, calls => Calls,
      forma_pid => FormaPid, own_forma => OwnForma}.

cleanup(#{root := Root, calls := Calls, own_forma := OwnForma}) ->
    case whereis(wfcli_build_service) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end,
    case {OwnForma, whereis(wfcli_forma_service)} of
        {true, FormaPid} when is_pid(FormaPid) -> gen_server:stop(FormaPid);
        _ -> ok
    end,
    ets:delete(Calls),
    application:unset_env(wfdaemon, build_store_file),
    application:unset_env(wfdaemon, build_cache_file),
    application:unset_env(wfdaemon, build_equipment_fun),
    application:unset_env(wfdaemon, build_catalog_fun),
    application:unset_env(wfdaemon, build_source_fun),
    _ = file:del_dir_r(Root),
    ok.

exercise(#{calls := Calls}) ->
    Request = #{source => overframe, action => detail, id => 300},
    Expires = erlang:monotonic_time(millisecond) + 60000,
    _ = sys:replace_state(
          wfcli_build_service,
          fun(State) ->
              State#{cache => #{Request => #{expires => Expires,
                                             data => stale_pre_update_reply}}}
          end),
    {ok, FirstRef} = wfcli_build_service:submit(self(), Request),
    {ok, SecondRef} = wfcli_build_service:submit(self(), Request),
    First = receive {wfcli_build, FirstRef, Reply1} -> Reply1 after 2000 -> timeout end,
    Second = receive {wfcli_build, SecondRef, Reply2} -> Reply2 after 2000 -> timeout end,
    ?assertEqual(1, ets:lookup_element(Calls, count, 2)),
    ?assertMatch({ok, #{<<"fingerprint">> := <<"fingerprint">>}}, First),
    ?assertEqual(First, Second),
    {ok, CachedRef} = wfcli_build_service:submit(self(), Request),
    Cached = receive
                 {wfcli_build, CachedRef, CachedReply} -> CachedReply
             after 2000 -> timeout
             end,
    ?assertEqual(First, Cached),
    ?assertEqual(1, ets:lookup_element(Calls, count, 2)),
    {ok, Stored} = wfcli_build_service:revision(<<"overframe">>, 300),
    ?assertEqual(<<"fingerprint">>, maps:get(<<"fingerprint">>, Stored)),
    ?assertEqual(false, maps:is_key(<<"raw">>, Stored)),
    ?assertEqual(<<"Stored notes">>,
                 maps:get(<<"description">>, maps:get(<<"metadata">>, Stored))),
    ?assertEqual(1, maps:get(revisions, wfcli_build_service:status())).

group_exercise() ->
    {ok, Ref} = wfcli_build_service:submit(
                  self(), #{source => overframe, action => detail, id => 300}),
    receive {wfcli_build, Ref, {ok, _Revision}} -> ok after 2000 -> timeout end,
    {ok, Subscription} = wfcli_build_service:subscribe(self()),
    {ok, Group0} = wfcli_build_service:create_group(
                     #{<<"definition_id">> => <<"/item">>,
                       <<"instance_id">> => <<"copy-1">>}, equipment()),
    GroupId = maps:get(<<"id">>, Group0),
    {ok, Durable} = wfcli_build_store:load(),
    ?assert(maps:is_key(GroupId, maps:get(goals, Durable))),
    receive
        {wfcli_build_group, Subscription, created, #{<<"id">> := GroupId}} -> ok
    after 1000 -> error(group_create_event_timeout)
    end,
    {ok, Group1} = wfcli_build_service:add_source_member(
                     GroupId, 1, <<"overframe">>, 300, latest),
    ?assertEqual(2, maps:get(<<"revision">>, Group1)),
    [SourceMember] = maps:get(<<"members">>, Group1),
    ?assertEqual(<<"Stored notes">>,
                 maps:get(<<"description">>,
                          maps:get(<<"metadata">>,
                                   maps:get(<<"snapshot">>, SourceMember)))),
    {ok, Group2} = wfcli_build_service:add_config_member(
                     GroupId, 2, <<"copy-1">>, 0, equipment()),
    ?assertEqual(2, maps:get(<<"member_count">>, Group2)),
    ?assertEqual([<<"/ability/roar">>],
                 maps:get(<<"ability_override">>,
                          maps:get(<<"config">>,
                                   maps:get(<<"snapshot">>,
                                            lists:last(maps:get(<<"members">>, Group2)))))),
    {ok, PlanRef} = wfcli_build_service:plan_group(self(), GroupId, 3),
    Plan = receive
               {wfcli_build, PlanRef, {ok, PlanResult}} -> PlanResult
           after 5000 -> timeout
           end,
    ?assertEqual(<<"ready">>, maps:get(<<"status">>, Plan)),
    {ok, PlannedGroup} = wfcli_build_service:group(GroupId),
    ?assertEqual(Plan, maps:get(<<"plan_result">>, PlannedGroup)),
    ?assertMatch({error, {build_group_conflict, 3}},
                 wfcli_build_service:update_group(
                   GroupId, 1, #{<<"name">> => <<"Stale">>}, equipment())),
    {ok, #{<<"groups">> := [Summary]}} = wfcli_build_service:groups(),
    ?assertEqual(2, maps:get(<<"member_count">>, Summary)),
    ?assertEqual(ok, wfcli_build_service:unsubscribe(Subscription)).

group_write_failure() ->
    Input = #{<<"definition_id">> => <<"/item">>,
              <<"instance_id">> => <<"copy-1">>},
    {ok, Group} = wfcli_build_service:create_group(Input, equipment()),
    Id = maps:get(<<"id">>, Group),
    {ok, Subscription} = wfcli_build_service:subscribe(self()),
    {ok, Before} = file:read_file(wfcli_build_store:path()),
    ok = file:make_dir(wfcli_build_store:path() ++ ".tmp"),
    ?assertMatch({error, {build_store_save_failed, _}},
                 wfcli_build_service:create_group(Input, equipment())),
    ?assertMatch({error, {build_store_save_failed, _}},
                 wfcli_build_service:update_group(
                   Id, 1, #{<<"name">> => <<"Unsaved">>}, equipment())),
    ?assertMatch({error, {build_store_save_failed, _}},
                 wfcli_build_service:delete_group(Id, 1)),
    ?assertEqual({ok, Group}, wfcli_build_service:group(Id)),
    ?assertEqual({ok, Before}, file:read_file(wfcli_build_store:path())),
    receive
        {wfcli_build_group, Subscription, _, _} -> error(uncommitted_group_event)
    after 50 -> ok
    end.

failed_load(Binary) ->
    ok = gen_server:stop(wfcli_build_service),
    Path = wfcli_build_store:path(),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Binary),
    {ok, _} = wfcli_build_service:start_link(),
    {ok, Ref} = wfcli_build_service:submit(
                  self(), #{source => overframe, action => detail, id => 300}),
    receive {wfcli_build, Ref, {ok, _}} -> ok after 2000 -> error(build_timeout) end,
    wfcli_build_service ! persist_store,
    ?assertMatch({error, {build_store_unavailable, _}}, wfcli_build_service:groups()),
    ?assertMatch({error, {build_store_unavailable, _}},
                 wfcli_build_service:create_group(
                   #{<<"definition_id">> => <<"/item">>}, equipment())),
    ?assertNotEqual(undefined, maps:get(store_error, wfcli_build_service:status())),
    ok = gen_server:stop(wfcli_build_service),
    ?assertEqual({ok, Binary}, file:read_file(Path)).

planning_refreshes_physical_target() ->
    Equipment = equipment(),
    {ok, Group0} = wfcli_build_service:create_group(
                     #{<<"definition_id">> => <<"/item">>,
                       <<"instance_id">> => <<"copy-1">>}, Equipment),
    Id = maps:get(<<"id">>, Group0),
    {ok, Group} = wfcli_build_service:add_config_member(Id, 1, <<"copy-1">>, 0,
                                                       Equipment),
    Revision = maps:get(<<"revision">>, Group),
    First = calculate(Id, Revision),
    [Instance] = maps:get(<<"instances">>, Equipment),
    Updated = Equipment#{<<"instances">> => [Instance#{<<"forma_count">> => 1,
                               <<"features">> => #{<<"double_capacity">> => true}}]},
    application:set_env(wfdaemon, build_equipment_fun, fun() -> Updated end),
    {ok, Current} = wfcli_build_service:group(Id),
    ?assertEqual(null, maps:get(<<"plan_result">>, Current)),
    ?assertEqual(1, maps:get(<<"forma_count">>, maps:get(<<"baseline">>, Current))),
    ?assertEqual(maps:get(<<"members">>, Group), maps:get(<<"members">>, Current)),
    Second = calculate(Id, Revision),
    ?assertNotEqual(maps:get(<<"target_fingerprint">>, First),
                    maps:get(<<"target_fingerprint">>, Second)),
    {ok, Planned} = wfcli_build_service:group(Id),
    ?assertEqual(Second, maps:get(<<"plan_result">>, Planned)),
    application:set_env(wfdaemon, build_equipment_fun,
                        fun() -> Equipment#{<<"instances">> => []} end),
    {ok, Missing} = wfcli_build_service:group(Id),
    ?assertEqual(<<"missing">>, maps:get(<<"target_status">>, Missing)),
    ?assertEqual(null, maps:get(<<"plan_result">>, Missing)),
    ?assertEqual({error, build_instance_not_found},
                  wfcli_build_service:plan_group(self(), Id, Revision)).

calculate(Id, Revision) ->
    {ok, Ref} = wfcli_build_service:plan_group(self(), Id, Revision),
    receive {wfcli_build, Ref, {ok, Result}} -> Result
    after 2000 -> error(plan_timeout)
    end.

interrupted_plan(Interruption) ->
    Parent = self(),
    {ok, BusyRef} = wfcli_forma_service:submit(self(), #{test_fun => fun() ->
        Parent ! {busy_worker, self()},
        receive finish -> {ok, done} end
    end}),
    Worker = receive {busy_worker, Pid} -> Pid after 1000 -> error(worker_timeout) end,
    {ok, Group0} = wfcli_build_service:create_group(
                     #{<<"definition_id">> => <<"/item">>,
                       <<"instance_id">> => <<"copy-1">>}, equipment()),
    Id = maps:get(<<"id">>, Group0),
    {ok, Group} = wfcli_build_service:add_config_member(Id, 1, <<"copy-1">>, 0,
                                                       equipment()),
    Revision = maps:get(<<"revision">>, Group),
    {ok, Ref} = wfcli_build_service:plan_group(self(), Id, Revision),
    Expected = case Interruption of
        target_changed ->
            application:set_env(wfdaemon, build_equipment_fun,
                                fun() -> (equipment())#{<<"instances">> => []} end),
            Worker ! finish,
            receive {wfcli_daemon, BusyRef, _} -> ok after 1000 -> error(busy_timeout) end,
            build_target_changed;
        service_restarted ->
            gen_server:stop(wfcli_forma_service),
            {ok, _} = wfcli_forma_service:start_link(),
            {forma_service_unavailable, normal}
    end,
    receive
        {wfcli_build, Ref, Reply} -> ?assertEqual({error, Expected}, Reply)
    after 2000 -> error(plan_waiter_stuck)
    end,
    ?assertEqual(0, maps:get(planning, wfcli_build_service:status())),
    application:set_env(wfdaemon, build_equipment_fun, fun equipment/0),
    ?assertMatch(#{<<"status">> := <<"ready">>}, calculate(Id, Revision)).

source_reply(#{action := detail, id := Id}) ->
    {ok, #{<<"schema">> => 1,
           <<"identity">> => #{<<"source">> => <<"overframe">>,
                                <<"external_id">> => Id},
           <<"fingerprint">> => <<"fingerprint">>,
           <<"content">> => #{<<"item">> => <<"/item">>, <<"slots">> => []},
           <<"metadata">> => #{},
           <<"raw">> => #{<<"id">> => Id,
                            <<"description">> => <<"Stored notes">>},
           <<"fetched_at">> => 1}}.

equipment() ->
    #{<<"definitions">> => [#{<<"id">> => <<"/item">>,
                               <<"name">> => <<"Test Item">>}],
      <<"instances">> =>
          [#{<<"instance_id">> => <<"copy-1">>,
             <<"definition_id">> => <<"/item">>,
             <<"class">> => <<"warframe">>,
             <<"capacity">> => 30,
             <<"forma_count">> => 0,
             <<"topology">> => #{<<"schema">> => 1, <<"regions">> => []},
             <<"effective_polarities">> => [], <<"shard_slots">> => [],
             <<"configs">> => [#{<<"config_index">> => 0,
                                   <<"name">> => <<"Roar">>,
                                   <<"ability_override">> => [<<"/ability/roar">>],
                                   <<"upgrade_slots">> => []}]}]}.
