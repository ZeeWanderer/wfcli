%%%-------------------------------------------------------------------
%% EUnit coverage for companion CLI command surface.
%%%-------------------------------------------------------------------
-module(wfcli_companion_cli_eunit).

-include_lib("eunit/include/eunit.hrl").

companion_commands_include_lifecycle_setup_and_diagnostics_test() ->
    Commands = wfcli_companion_cli:known_commands(),
    ?assert(lists:all(
              fun(Command) -> lists:member(Command, Commands) end,
              ["start", "stop", "restart", "status", "install", "uninstall",
               "probe", "screenshot", "relic-ocr", "preview", "logs", "show", "hide", "hud"])).

companion_help_explains_global_overlay_visibility_test() ->
    Help = unicode:characters_to_binary(wfcli_help_text:companion_help()),
    ?assertNotEqual(nomatch, binary:match(Help, <<"hide               disable the entire overlay">>)),
    ?assertNotEqual(nomatch, binary:match(Help, <<"hud show|hide">>)),
    ?assertNotEqual(nomatch, binary:match(Help, <<"suppresses automatic contextual overlays">>)).

companion_status_formats_negotiated_socket_contract_test() ->
    Status = iolist_to_binary(
               wfcli_companion_cli:format_local(
                 #{socket => "/tmp/wfdaemon.sock",
                   contract => #{<<"envelope">> => 1,
                                 <<"interfaces">> =>
                                     #{<<"assets">> => 2, <<"player">> => 3}},
                   connections => 2,
                   companions => 1})),
    ?assertNotEqual(nomatch,
                    binary:match(Status, <<"handshake envelope: 1">>)),
    ?assertNotEqual(nomatch,
                    binary:match(Status, <<"interfaces: assets=2, player=3">>)),
    ?assertEqual(nomatch, binary:match(Status, <<"companion protocol">>)).

preview_directory_tracks_repository_or_portable_root_test() ->
    ?assertEqual("/repo/previews",
                 wfcli_companion_cli:preview_directory("/repo/dev/bin/wfcompanion")),
    ?assertEqual("/opt/wfcli/previews",
                 wfcli_companion_cli:preview_directory("/opt/wfcli/bin/wfcompanion")).
