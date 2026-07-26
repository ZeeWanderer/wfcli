%%%-------------------------------------------------------------------
%% EUnit coverage for detached companion command construction.
%%%-------------------------------------------------------------------
-module(wfcli_companion_process_eunit).

-include_lib("eunit/include/eunit.hrl").

staged_binary_is_preferred_beside_escript_test() ->
    Candidates = wfcli_companion_process:binary_candidates(
                   "/repo/dev/bin/wfcli", false),
    ?assertEqual("/repo/dev/bin/wfcompanion", hd(Candidates)).

systemd_start_preserves_session_environment_test() ->
    Args = wfcli_companion_process:start_arguments(
             "/repo/dev/bin/wfcompanion",
             "/repo/dev/bin/wfcli",
             [{"WAYLAND_DISPLAY", "wayland-0"}]),
    ?assert(lists:member("--setenv=WAYLAND_DISPLAY=wayland-0", Args)),
    ?assert(lists:member("--setenv=WFCLI_COMMAND=/repo/dev/bin/wfcli", Args)),
    ?assertEqual(["--", "/repo/dev/bin/wfcompanion"], lists:nthtail(length(Args) - 2, Args)).
