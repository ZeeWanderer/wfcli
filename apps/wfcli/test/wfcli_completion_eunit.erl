%%%-------------------------------------------------------------------
%% EUnit coverage for generated shell completion.
%%%-------------------------------------------------------------------
-module(wfcli_completion_eunit).

-include_lib("eunit/include/eunit.hrl").

top_level_completion_test() ->
    ?assert(lists:member("daemon", wfcli_completion:candidates(["da"]))),
    ?assert(lists:member("completion", wfcli_completion:candidates([""]))),
    ?assert(lists:member("paths", wfcli_completion:candidates(["pa"]))).

public_commands_are_unique_test() ->
    Commands = wfcli_cli:public_command_names(),
    ?assertEqual(length(Commands), length(lists:usort(Commands))).

nested_command_completion_test() ->
    ?assert(lists:member("status", wfcli_completion:candidates(["daemon", ""]))),
    ?assertEqual(
       ["enable"],
       wfcli_completion:candidates(["daemon", "autostart", "en"])),
    ?assertEqual(["wfdaemon"], wfcli_completion:candidates(["paths", "wfd"])),
    ?assertEqual(["inventory"], wfcli_completion:candidates(["baro", "i"])),
    ?assertEqual(["video"], wfcli_completion:candidates(["companion", "preview", "v"])).

option_value_completion_test() ->
    Values = wfcli_completion:candidates(["query", "--format", ""]),
    ?assert(lists:member("table", Values)),
    ?assert(lists:member("block", Values)),
    ?assertNot(lists:member("json", Values)),
    ?assert(lists:member(
              "json",
              wfcli_completion:candidates(["codex", "--format", ""]))),
    ?assertEqual(
       ["html", "image"],
       wfcli_completion:candidates(["visualize", "--viz", ""])),
    ?assertEqual(
       ["html"],
       wfcli_completion:candidates(["forma-plan", "--viz", "h"])).
