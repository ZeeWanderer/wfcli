-module(wfcli_gui_desktop_eunit).

-include_lib("eunit/include/eunit.hrl").

desktop_entry_uses_stable_identity_and_quoted_executable_test() ->
    Entry = wfcli_gui_desktop:desktop_entry("/opt/wf cli/bin/wfgui"),
    ?assertNotEqual(nomatch,
                    binary:match(Entry, <<"Exec=\"/opt/wf cli/bin/wfgui\"">>)),
    ?assertNotEqual(nomatch, binary:match(Entry, <<"Icon=wfgui\n">>)),
    ?assertNotEqual(nomatch, binary:match(Entry, <<"StartupWMClass=wfgui\n">>)).
