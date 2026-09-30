-module(wfcli_companion_format_eunit).

-include_lib("eunit/include/eunit.hrl").

collector_reports_receipts_errors_and_session_identity_test() ->
    Data = #{<<"companion_pid">> => 42, <<"game_pid">> => 60,
             <<"inventory_active">> => true, <<"inventory_updates_observed">> => 3,
             <<"inventory_received_at">> => 1000, <<"last_observed_at">> => 2000,
             <<"game_metadata_active">> => true,
             <<"game_metadata_error">> => <<"missing StoreManifest">>},
    Player = #{collector => Data, game_active => true},
    Local = #{companion_details => [#{os_pid => 42}]},
    Text = wfcli_output:with(#{utc => true}, fun() ->
        bin(wfcli_companion_format:collectors(Player, Local))
    end),
    contains(Text, <<"current session">>),
    contains(Text, <<"inventory: running (3 receipts)">>),
    contains(Text, <<"last inventory received: 1970-01-01T00:00:01.000Z">>),
    contains(Text, <<"error: missing StoreManifest">>),
    contains(bin(wfcli_companion_format:collectors(Player, #{})), <<"last reported">>),
    contains(bin(wfcli_companion_format:collectors(Player#{game_active => false}, Local)), <<"last reported">>).

old_armed_request_is_not_reported_as_current_test() ->
    Request = #{<<"state">> => <<"armed">>, <<"companion_pid">> => 42,
                <<"directory">> => <<"/capture/next">>, <<"expires_at">> => 3000},
    Result = #{<<"state">> => <<"partial">>, <<"directory">> => <<"/capture/previous">>,
               <<"error">> => <<"UI unavailable">>, <<"updated_at">> => 1000},
    Player = #{capture => Request, capture_result => Result},
    Local = #{companions => 1, companion_details => [#{os_pid => 42}]},
    Text = bin(wfcli_companion_format:captures(Player, Local)),
    contains(Text, <<"armed: yes">>),
    contains(Text, <<"output: /capture/next">>),
    contains(Text, <<"last result: partial">>),
    contains(Text, <<"result output: /capture/previous">>),
    contains(Text, <<"error: UI unavailable">>),
    Disconnected = bin(wfcli_companion_format:captures(Player, #{companions => 0})),
    contains(Disconnected, <<"armed: no companion connected">>),
    ?assertEqual(nomatch, binary:match(Disconnected, <<"armed: yes">>)),
    contains(bin(wfcli_companion_format:captures(Player, Local#{companion_details => [#{os_pid => 43}]})),
             <<"unknown (no current report)">>).

metadata_status_exposes_cache_and_warning_test() ->
    Text = bin(wfcli_companion_format:metadata(#{
        available => true, revision => 13, executable_sha256 => <<"abc">>,
        pools => #{<<"suits">> => 119, <<"primaries">> => 84,
                   <<"secondaries">> => 72, <<"melees">> => 112},
        capture_error => #{<<"reason">> => <<"unsupported_executable">>}})),
    contains(Text, <<"available (revision 13)">>),
    contains(Text, <<"119 Warframes, 84 primaries, 72 secondaries, 112 melees">>),
    contains(Text, <<"capture warning: unsupported_executable">>).

bin(Text) -> unicode:characters_to_binary(Text).
contains(Text, Part) -> ?assertNotEqual(nomatch, binary:match(Text, Part)).
