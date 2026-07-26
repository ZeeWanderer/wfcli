%%%-------------------------------------------------------------------
%% EUnit tests for worldstate CLI watch helpers.
%%%-------------------------------------------------------------------
-module(wfcli_worldstate_cli_eunit).

-include_lib("eunit/include/eunit.hrl").

split_signature_merge_tail_test() ->
    Parts = wfcli_worldstate_output:split_signature("A | B | C", 2),
    ?assertEqual(["A", "B | C"], Parts).

removed_entries_table_builds_row_map_test() ->
    Diff = #{removed => [{"id1", #{name => "Name", value => "X | Y"}}]},
    Columns = [one, two],
    [Entry] = wfcli_worldstate_output:removed_entries_table(Diff, Columns),
    RowMap = maps:get(row_map, Entry, #{}),
    ?assertEqual("X", maps:get(one, RowMap)),
    ?assertEqual("Y", maps:get(two, RowMap)),
    ?assertEqual("id1", maps:get(id, Entry)).

removed_extract_rows_test() ->
    Diff = #{removed => [{"id1", #{name => "Name", value => "X | Y"}}]},
    Rows = wfcli_worldstate_output:removed_extract_rows(Diff, ["one", "two"]),
    ?assertEqual([["Name", "X", "Y"]], Rows).

merge_inline_entries_keeps_removed_order_test() ->
    PrevSnap = #{},
    Opts = #{raw => true},
    ExpB = wfcli_time:format_millis(2000, Opts),
    Entries = [
        #{id => "A", name => "A", type => alert, row_map => #{expiry => wfcli_time:format_millis(1000, Opts)}, data => #{
            <<"Expiry">> => 1000,
            <<"MissionInfo">> => #{<<"missionType">> => <<"MT_CAPTURE">>}
        }},
        #{id => "C", name => "C", type => alert, row_map => #{expiry => wfcli_time:format_millis(3000, Opts)}, data => #{
            <<"Expiry">> => 3000,
            <<"MissionInfo">> => #{<<"missionType">> => <<"MT_CAPTURE">>}
        }}
    ],
    Diff = #{removed => [{"B", #{name => "B", row_map => #{expiry => ExpB}}}]},
    Columns = [expiry, mission, node, reward],
    Merged = wfcli_worldstate_output:merge_inline_entries(Entries, Columns, Diff, PrevSnap, Opts),
    Names = [maps:get(name, E, "") || E <- Merged],
    ?assertEqual(["A", "B", "C"], Names).

parse_args_fuzz_test() ->
    _ = rand:seed(exsplus, {12, 13, 14}),
    lists:foreach(
      fun(_Idx) ->
          Args = random_args(),
          Parsed = wfcli_worldstate_cli:parse_args(Args, wfcli_worldstate_cli:default_acc()),
          ?assert(is_map(Parsed)),
          ?assert(is_list(maps:get(errors, Parsed, [])))
      end,
      lists:seq(1, 50)).

parse_args_near_miss_suggests_test() ->
    Parsed = wfcli_worldstate_cli:parse_args(["--formatt", "table"], wfcli_worldstate_cli:default_acc()),
    Errors = maps:get(errors, Parsed, []),
    ?assert(lists:any(fun(E) -> string:find(E, "did you mean") =/= nomatch end, Errors)).

parse_args_defers_bad_query_syntax_test() ->
    Parsed = wfcli_worldstate_cli:parse_args(
      ["alerts", "--search", "foo OR"], wfcli_worldstate_cli:default_acc()),
    ?assertEqual([], maps:get(errors, Parsed, [])),
    ?assertEqual("foo OR", maps:get(search, Parsed)).

parse_args_defers_unknown_worldstate_field_test() ->
    Parsed = wfcli_worldstate_cli:parse_args(
      ["alerts", "--search", "faction=Corpus"], wfcli_worldstate_cli:default_acc()),
    ?assertEqual([], maps:get(errors, Parsed, [])),
    ?assertEqual("faction=Corpus", maps:get(search, Parsed)).

parse_args_accepts_boolean_query_test() ->
    Parsed = wfcli_worldstate_cli:parse_args(
      ["alerts", "--search", "foo OR bar"], wfcli_worldstate_cli:default_acc()),
    ?assertEqual([], maps:get(errors, Parsed, [])).

archimedea_selector_adds_semantic_filter_test() ->
    Parsed = wfcli_worldstate_cli:parse_args(
      ["archimedea", "--deep", "--search", "risk~shielded"],
      wfcli_worldstate_cli:default_acc()),
    ?assertEqual(archimedea, maps:get(type_filter, Parsed)),
    ?assertEqual("(risk~shielded) archimedea=deep", maps:get(search, Parsed)),
    ?assertEqual([], maps:get(errors, Parsed, [])).

archimedea_selectors_are_exclusive_test() ->
    Parsed = wfcli_worldstate_cli:parse_args(
      ["archimedea", "--deep", "--temporal"], wfcli_worldstate_cli:default_acc()),
    ?assert(lists:member("--deep and --temporal are mutually exclusive",
                         maps:get(errors, Parsed, []))).

watch_spec_defers_bad_query_syntax_test() ->
    Parsed = wfcli_worldstate_cli:parse_args(
      ["watch", "--spec", "alerts:foo OR"], wfcli_worldstate_cli:default_acc()),
    ?assertEqual([], maps:get(errors, Parsed, [])),
    [Spec] = maps:get(watch_specs, Parsed),
    ?assertEqual("foo OR", maps:get(query, Spec)).

watch_table_includes_extra_columns_test() ->
    RowMaps = [#{mission => "Capture", extra_fields => #{"Icon" => "icon.png"}}],
    Cols = [mission],
    Opts = #{watch_table => true},
    ?assertEqual([{extra, "Icon"}], wfcli_worldstate_output:maybe_extra_columns(RowMaps, Cols, Opts)).

removed_entry_preserves_extra_fields_test() ->
    Prev = #{row_map => #{mission => "Capture"}, extra_fields => #{"Icon" => "icon.png"}},
    Columns = [mission, {extra, "Icon"}],
    Diff = #{removed => [{"k1", Prev}]},
    [Entry] = wfcli_worldstate_output:removed_entries_table(Diff, Columns),
    ?assertEqual(#{"Icon" => "icon.png"}, maps:get(extra_fields, Entry)),
    RowMap = maps:get(row_map, Entry),
    ?assertEqual("Capture", maps:get(mission, RowMap)).

regular_table_includes_extra_columns_test() ->
    RowMaps = [#{mission => "Capture", extra_fields => #{"Icon" => "icon.png"}}],
    Cols = [mission],
    ?assertEqual([{extra, "Icon"}], wfcli_worldstate_output:maybe_extra_columns(RowMaps, Cols, #{})).

daemon_memory_source_text_test() ->
    Result = #{source => memory, snapshot_origin => fetched, snapshot_age_ms => 24500},
    ?assertEqual("source: memory, origin: fetched, age: 24s",
                 wfcli_worldstate_output:daemon_source_text(Result)).

daemon_fetched_source_text_avoids_duplicate_origin_test() ->
    Result = #{source => fetched, snapshot_origin => fetched, snapshot_age_ms => 12},
    ?assertEqual("source: fetched, age: 0s",
                 wfcli_worldstate_output:daemon_source_text(Result)).

baro_help_documents_inventory_workflow_test() ->
    Text = lists:flatten(
             wfcli_help_text:worldstate_subcommand(
               "baro", baro, wfcli_worldstate_cli:command_description("baro"),
               "/tmp/worldstate.json")),
    ?assert(string:find(Text, "wfcli baro --inventory") =/= nomatch),
    ?assert(string:find(Text, "published Baro manifest") =/= nomatch),
    ?assert(string:find(Text, "--inventory cannot be combined with --watch") =/= nomatch).

teshin_help_documents_calculated_inventory_test() ->
    Text = lists:flatten(
             wfcli_help_text:worldstate_subcommand(
               "teshin", teshin, wfcli_worldstate_cli:command_description("teshin"),
               "/tmp/worldstate.json")),
    ?assert(string:find(Text, "wfcli teshin riven") =/= nomatch),
    ?assert(string:find(Text, "eight-week Steel Path rotation") =/= nomatch),
    ?assertEqual(nomatch, string:find(Text, "--refresh")),
    ?assertEqual(nomatch, string:find(Text, "--watch")),
    ?assertEqual(nomatch, string:find(Text, "--inventory")),
    ?assert(string:find(Text, "watch mode is not supported") =/= nomatch).

archimedea_help_documents_scope_test() ->
    Text = lists:flatten(
             wfcli_help_text:worldstate_subcommand(
               "archimedea", archimedea, wfcli_worldstate_cli:command_description("archimedea"),
               "/tmp/worldstate.json")),
    ?assert(string:find(Text, "default: block") =/= nomatch),
    ?assert(string:find(Text, "--deep") =/= nomatch),
    ?assert(string:find(Text, "additional Elite risks") =/= nomatch),
    ?assert(string:find(Text, "account-specific") =/= nomatch).

generic_data_help_hides_inventory_option_test() ->
    Text = lists:flatten(
             wfcli_help_text:worldstate_subcommand(
               "alerts", alert, wfcli_worldstate_cli:command_description("alerts"),
               "/tmp/worldstate.json")),
    ?assertEqual(nomatch, string:find(Text, "--inventory")),
    ?assert(string:find(Text, "--watch") =/= nomatch),
    ?assert(string:find(Text, "--refresh") =/= nomatch).

random_args() ->
    Known = wfcli_worldstate_cli:known_args(),
    Tokens = ["alerts", "lith", "foo", "bar"],
    lists:append([
        maybe_pick(Known),
        maybe_pick(Known),
        maybe_pick(Tokens),
        maybe_unknown_flag()
    ]).

maybe_pick(List) ->
    case rand:uniform(3) of
        1 -> [lists:nth(rand:uniform(length(List)), List)];
        _ -> []
    end.

maybe_unknown_flag() ->
    case rand:uniform(2) of
        1 -> ["--formatt"];
        _ -> []
    end.
