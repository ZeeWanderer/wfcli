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

cleanup(#{root := Root, pid := Pid, calls := Calls,
          forma_pid := FormaPid, own_forma := OwnForma}) ->
    gen_server:stop(Pid),
    case OwnForma of true -> gen_server:stop(FormaPid); false -> ok end,
    ets:delete(Calls),
    application:unset_env(wfdaemon, build_store_file),
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
    receive
        {wfcli_build_group, Subscription, created, #{<<"id">> := GroupId}} -> ok
    after 1000 -> error(group_create_event_timeout)
    end,
    {ok, Group1} = wfcli_build_service:add_source_member(
                     GroupId, 1, <<"overframe">>, 300, latest),
    ?assertEqual(2, maps:get(<<"revision">>, Group1)),
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

source_reply(#{action := detail, id := Id}) ->
    {ok, #{<<"schema">> => 1,
           <<"identity">> => #{<<"source">> => <<"overframe">>,
                                <<"external_id">> => Id},
           <<"fingerprint">> => <<"fingerprint">>,
           <<"content">> => #{<<"item">> => <<"/item">>, <<"slots">> => []},
           <<"metadata">> => #{}, <<"raw">> => #{<<"id">> => Id},
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
