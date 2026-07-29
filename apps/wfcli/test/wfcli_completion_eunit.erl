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
    ?assertEqual(["video"], wfcli_completion:candidates(["companion", "preview", "v"])),
    ?assertEqual(["install"], wfcli_completion:candidates(["completion", "i"])),
    ?assertEqual(["--file"],
                 wfcli_completion:candidates(["completion", "install", "--f"])).

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

generated_bash_completes_without_wfcli_process_test() ->
    Script = iolist_to_binary(wfcli_completion:script()),
    ?assertEqual(nomatch, binary:match(Script, <<"completion candidates">>)),
    ?assertNotEqual(nomatch, binary:match(Script, <<"compgen -W">>)),
    ?assertNotEqual(nomatch, binary:match(Script, <<"complete -F _wfcli_complete wfcli wfclid">>)).

managed_completion_lifecycle_test() ->
    Path = temp_path("lifecycle"),
    Original = <<"export WFCLI_TEST=1\n">>,
    try
        ok = file:write_file(Path, Original),
        ?assertEqual({ok, false}, wfcli_completion:installed(Path)),
        ok = wfcli_completion:install(Path),
        ?assertEqual({ok, true}, wfcli_completion:installed(Path)),
        {ok, Installed} = file:read_file(Path),
        ?assertEqual(1, length(binary:matches(
                                 Installed, <<"# >>> wfcli completion >>>">>))),
        ok = wfcli_completion:install(Path),
        {ok, Reinstalled} = file:read_file(Path),
        ?assertEqual(Installed, Reinstalled),
        ok = wfcli_completion:uninstall(Path),
        ?assertEqual({ok, false}, wfcli_completion:installed(Path)),
        ?assertEqual({ok, Original}, file:read_file(Path))
    after
        _ = file:delete(Path)
    end.

malformed_completion_block_is_not_modified_test() ->
    Path = temp_path("malformed"),
    Content = <<"# >>> wfcli completion >>>\n">>,
    try
        ok = file:write_file(Path, Content),
        ?assertEqual({error, malformed_completion_block},
                     wfcli_completion:install(Path)),
        ?assertEqual({ok, Content}, file:read_file(Path))
    after
        _ = file:delete(Path)
    end.

symlinked_startup_file_is_preserved_test() ->
    Target = temp_path("target"),
    Link = temp_path("link"),
    Original = <<"export WFCLI_TEST=1\n">>,
    try
        ok = file:write_file(Target, Original),
        ok = file:make_symlink(Target, Link),
        ok = wfcli_completion:install(Link),
        ?assertEqual({ok, Target}, file:read_link(Link)),
        ?assertEqual({ok, true}, wfcli_completion:installed(Link)),
        ok = wfcli_completion:uninstall(Link),
        ?assertEqual({ok, Target}, file:read_link(Link)),
        ?assertEqual({ok, Original}, file:read_file(Target))
    after
        _ = file:delete(Link),
        _ = file:delete(Target)
    end.

temp_path(Name) ->
    filename:join(
      "/tmp",
      "wfcli_completion_" ++ Name ++ "_" ++
      integer_to_list(erlang:unique_integer([positive]))).
