%%%-------------------------------------------------------------------
%% EUnit coverage for native companion JSON protocol.
%%%-------------------------------------------------------------------
-module(wfcli_local_protocol_eunit).

-include_lib("eunit/include/eunit.hrl").

round_trip_binary_keyed_message_test() ->
    Message = #{<<"op">> => <<"publish">>, <<"id">> => 7,
                <<"dataset">> => <<"player">>,
                <<"data">> => #{<<"phase">> => <<"launcher">>}},
    Encoded = iolist_to_binary(wfcli_local_protocol:encode(Message)),
    {ok, Decoded} = wfcli_local_protocol:decode(string:trim(Encoded)),
    ?assertEqual(Message, Decoded).

invalid_json_is_data_error_test() ->
    ?assertMatch({error, {invalid_json, _}}, wfcli_local_protocol:decode(<<"{">>)).

protocol_version_tracks_companion_command_contract_test() ->
    ?assertEqual(8, wfcli_local_protocol:protocol_version()).
