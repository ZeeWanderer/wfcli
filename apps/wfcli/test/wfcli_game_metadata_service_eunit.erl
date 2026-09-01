%%%-------------------------------------------------------------------
%% EUnit coverage for daemon-owned game metadata persistence.
%%%-------------------------------------------------------------------
-module(wfcli_game_metadata_service_eunit).

-include_lib("eunit/include/eunit.hrl").

game_metadata_service_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun(_Path) -> [
         fun persists_valid_metadata/0,
         fun unchanged_publish_keeps_revision/0,
         fun rejects_obsolete_schema/0,
         fun rejects_invalid_executable_identity/0,
         fun unsupported_executable_replaces_stale_metadata/0,
         fun clear_removes_metadata/0
     ] end}.

setup() ->
    Path = filename:join(
             "/tmp", "wfcli-game-metadata-" ++
                 integer_to_list(erlang:unique_integer([positive]))),
    application:set_env(wfdaemon, game_metadata_cache, Path),
    {ok, _Pid} = wfcli_game_metadata_service:start_link(),
    Path.

cleanup(Path) ->
    case whereis(wfcli_game_metadata_service) of
        undefined -> ok;
        _Pid -> gen_server:stop(wfcli_game_metadata_service)
    end,
    application:unset_env(wfdaemon, game_metadata_cache),
    _ = file:delete(Path ++ ".tmp"),
    _ = file:delete(Path),
    ok.

persists_valid_metadata() ->
    Data = metadata(),
    {ok, First} = wfcli_game_metadata_service:publish(Data),
    ok = gen_server:stop(wfcli_game_metadata_service),
    {ok, _Pid} = wfcli_game_metadata_service:start_link(),
    Reloaded = wfcli_game_metadata_service:snapshot(),
    ?assertEqual(maps:get(revision, First), maps:get(revision, Reloaded)),
    ?assertEqual(Data, maps:get(data, Reloaded)).

unchanged_publish_keeps_revision() ->
    {ok, First} = wfcli_game_metadata_service:publish(metadata()),
    {ok, Second} = wfcli_game_metadata_service:publish(metadata()),
    ?assertEqual(maps:get(revision, First), maps:get(revision, Second)).

rejects_obsolete_schema() ->
    ?assertEqual({error, invalid_game_metadata},
                 wfcli_game_metadata_service:publish(
                   (metadata())#{<<"schema">> => 1})).

rejects_invalid_executable_identity() ->
    Invalid = (metadata())#{<<"executable">> => #{<<"sha256">> => <<"no">>}},
    ?assertEqual({error, invalid_game_metadata_executable},
                 wfcli_game_metadata_service:publish(Invalid)).

unsupported_executable_replaces_stale_metadata() ->
    Hash = <<"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef">>,
    Unavailable = #{<<"schema">> => 2,
                    <<"executable">> => #{<<"sha256">> => Hash},
                    <<"unavailable">> => #{<<"reason">> => <<"unsupported_executable">>}},
    {ok, Snapshot} = wfcli_game_metadata_service:publish(Unavailable),
    ?assertEqual(Unavailable, maps:get(data, Snapshot)).

clear_removes_metadata() ->
    ok = wfcli_game_metadata_service:clear(),
    ?assertEqual(#{}, maps:get(data, wfcli_game_metadata_service:snapshot())).

metadata() ->
    #{<<"schema">> => 2,
      <<"executable">> => #{<<"sha256">> => binary:copy(<<"a">>, 64)},
      <<"archimedea">> => #{<<"catalog">> => #{}}}.
