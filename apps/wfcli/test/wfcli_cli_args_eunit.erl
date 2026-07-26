%%%-------------------------------------------------------------------
%% EUnit tests for CLI argument helpers.
%%%-------------------------------------------------------------------
-module(wfcli_cli_args_eunit).

-include_lib("eunit/include/eunit.hrl").

expand_aliases_test() ->
    Aliases = #{"-h" => "--help", "-f" => "--format"},
    ?assertEqual(["--help", "mods", "--format"], wfcli_cli_args:expand_aliases(["-h", "mods", "-f"], Aliases)).

has_help_flag_test() ->
    ?assertEqual(true, wfcli_cli_args:has_help_flag(["--help"])),
    ?assertEqual(true, wfcli_cli_args:has_help_flag(["-h", "mods"])),
    ?assertEqual(false, wfcli_cli_args:has_help_flag(["mods", "alerts"])).

strip_help_flags_test() ->
    ?assertEqual(["mods"], wfcli_cli_args:strip_help_flags(["-h", "mods"])),
    ?assertEqual(["alerts"], wfcli_cli_args:strip_help_flags(["alerts", "--help"])).

prompt_enabled_test() ->
    ?assertEqual(true, wfcli_cli_args:prompt_enabled(["--format", "table"])),
    ?assertEqual(false, wfcli_cli_args:prompt_enabled(["--no-suggest-prompt", "--format", "table"])).

strip_prompt_flag_test() ->
    {Args, Enabled} = wfcli_cli_args:strip_prompt_flag(["--no-suggest-prompt", "--format", "table"]),
    ?assertEqual(["--format", "table"], Args),
    ?assertEqual(false, Enabled).

prompt_suggestions_disabled_test() ->
    Args = wfcli_cli_args:prompt_suggestions(["--no-suggest-prompt", "--formatt", "table"], ["--format"]),
    ?assertEqual(["--formatt", "table"], Args).
