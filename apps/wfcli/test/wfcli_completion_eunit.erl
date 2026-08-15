%%%-------------------------------------------------------------------
%% EUnit coverage for generated shell completion.
%%%-------------------------------------------------------------------
-module(wfcli_completion_eunit).

-include_lib("eunit/include/eunit.hrl").

top_level_completion_test() ->
    ?assert(lists:member("daemon", wfcli_completion:candidates(["da"]))),
    ?assert(lists:member("gui", wfcli_completion:candidates(["gu"]))),
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
    ?assertEqual(["wfgui"], wfcli_completion:candidates(["paths", "wfg"])),
    ?assertEqual(["--apps"], wfcli_completion:candidates(["paths", "--a"])),
    ?assertEqual(["inventory"], wfcli_completion:candidates(["baro", "i"])),
    ?assertEqual(["video"], wfcli_completion:candidates(["companion", "preview", "v"])),
    ?assertEqual(["install"], wfcli_completion:candidates(["completion", "i"])),
    ?assertEqual(["install"], wfcli_completion:candidates(["gui", "i"])),
    ?assertEqual(["unresolved"],
                 wfcli_completion:candidates(["diagnostics", "u"])),
    ?assertEqual(["--json"],
                 wfcli_completion:candidates(["diagnostics", "unresolved", "--j"])),
    ?assertEqual(["--dir"],
                 wfcli_completion:candidates(["completion", "install", "--d"])).

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
       wfcli_completion:candidates(["forma-plan", "--viz", "h"])),
    ?assertNot(
       lists:member(
         "--target",
         wfcli_completion:candidates(["companion", "screenshot", ""]))).

generated_bash_completes_without_wfcli_process_test() ->
    Script = iolist_to_binary(wfcli_completion:script()),
    ?assertEqual(nomatch, binary:match(Script, <<"completion candidates">>)),
    ?assertNotEqual(nomatch, binary:match(Script, <<"compgen -V COMPREPLY">>)),
    ?assertEqual(nomatch, binary:match(Script, <<"mapfile">>)),
    ?assertNotEqual(nomatch, binary:match(Script, <<"complete -F _wfcli_complete wfcli wfclid">>)).

managed_completion_lifecycle_test() ->
    Dir = temp_path("lifecycle_dir"),
    Bashrc = temp_path("lifecycle_bashrc"),
    Clean = <<"export WFCLI_TEST=1\n">>,
    Original = legacy_startup(Clean),
    try
        ok = file:make_dir(Dir),
        ok = file:write_file(Bashrc, Original),
        ?assertEqual({ok, false}, wfcli_completion:installed(Dir)),
        ok = wfcli_completion:install(Dir, Bashrc),
        ?assertEqual({ok, true}, wfcli_completion:installed(Dir)),
        Expected = iolist_to_binary(wfcli_completion:script()),
        ?assertEqual({ok, Expected}, file:read_file(filename:join(Dir, "wfcli.bash"))),
        ?assertEqual({ok, Expected}, file:read_file(filename:join(Dir, "wfclid.bash"))),
        ?assertEqual({ok, Clean}, file:read_file(Bashrc)),
        ok = file:write_file(filename:join(Dir, "wfcli.bash"), <<"stale">>),
        ?assertEqual({ok, false}, wfcli_completion:installed(Dir)),
        ok = wfcli_completion:install(Dir, Bashrc),
        ?assertEqual({ok, true}, wfcli_completion:installed(Dir)),
        ok = wfcli_completion:uninstall(Dir, Bashrc),
        ?assertEqual({ok, false}, wfcli_completion:installed(Dir)),
        ?assertEqual({ok, Clean}, file:read_file(Bashrc))
    after
        cleanup_completion_dir(Dir),
        _ = file:delete(Bashrc)
    end.

malformed_completion_block_is_not_modified_test() ->
    Dir = temp_path("malformed_dir"),
    Bashrc = temp_path("malformed_bashrc"),
    Content = <<"# >>> wfcli completion >>>\n">>,
    try
        ok = file:make_dir(Dir),
        ok = file:write_file(Bashrc, Content),
        ?assertEqual({error, malformed_completion_block},
                     wfcli_completion:install(Dir, Bashrc)),
        ?assertEqual({ok, Content}, file:read_file(Bashrc)),
        ?assertEqual({ok, false}, wfcli_completion:installed(Dir))
    after
        cleanup_completion_dir(Dir),
        _ = file:delete(Bashrc)
    end.

symlinked_startup_file_is_preserved_test() ->
    Dir = temp_path("symlink_dir"),
    Target = temp_path("target"),
    Link = temp_path("link"),
    Clean = <<"export WFCLI_TEST=1\n">>,
    try
        ok = file:make_dir(Dir),
        ok = file:write_file(Target, legacy_startup(Clean)),
        ok = file:make_symlink(Target, Link),
        ok = wfcli_completion:install(Dir, Link),
        ?assertEqual({ok, Target}, file:read_link(Link)),
        ?assertEqual({ok, true}, wfcli_completion:installed(Dir)),
        ?assertEqual({ok, Clean}, file:read_file(Target)),
        ok = wfcli_completion:uninstall(Dir, Link),
        ?assertEqual({ok, Target}, file:read_link(Link)),
        ?assertEqual({ok, Clean}, file:read_file(Target))
    after
        cleanup_completion_dir(Dir),
        _ = file:delete(Link),
        _ = file:delete(Target)
    end.

legacy_startup(Prefix) ->
    <<Prefix/binary,
      "# >>> wfcli completion >>>\n"
      "if command -v wfcli >/dev/null 2>&1; then\n"
      "  eval \"$(wfcli completion bash)\"\n"
      "fi\n"
      "# <<< wfcli completion <<<\n">>.

cleanup_completion_dir(Dir) ->
    _ = file:delete(filename:join(Dir, "wfcli.bash")),
    _ = file:delete(filename:join(Dir, "wfclid.bash")),
    _ = file:del_dir(Dir),
    ok.

temp_path(Name) ->
    filename:join(
      "/tmp",
      "wfcli_completion_" ++ Name ++ "_" ++
      integer_to_list(erlang:unique_integer([positive]))).
