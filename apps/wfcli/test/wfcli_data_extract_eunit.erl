%%%-------------------------------------------------------------------
%% EUnit tests for data extraction helpers.
%%%-------------------------------------------------------------------
-module(wfcli_data_extract_eunit).

-include_lib("eunit/include/eunit.hrl").

extract_by_key_and_index_test() ->
    Data = #{<<"Foo">> => #{<<"Bar">> => [1, 2, 3]}},
    ?assertEqual([2], wfcli_data_extract:extract_values(Data, "Foo.Bar.1")).

extract_wildcard_test() ->
    Data = #{<<"Map">> => #{<<"a">> => 1, <<"b">> => 2}},
    Values = wfcli_data_extract:extract_values(Data, "Map.*"),
    ?assertEqual([1, 2], lists:sort(Values)).

extract_list_maps_test() ->
    Data = #{<<"List">> => [#{<<"Val">> => "a"}, #{<<"Val">> => "b"}]},
    ?assertEqual(["a", "b"], wfcli_data_extract:extract_values(Data, "List.Val")).

extract_string_test() ->
    Data = #{<<"List">> => [#{<<"Val">> => "a"}, #{<<"Val">> => "b"}]},
    ?assertEqual("a, b", wfcli_data_extract:extract_string(Data, "List.Val")).

extract_missing_key_test() ->
    Data = #{<<"Foo">> => 1},
    ?assertEqual([], wfcli_data_extract:extract_values(Data, "Bar")).

extract_index_out_of_range_test() ->
    Data = #{<<"Foo">> => [1, 2]},
    ?assertEqual([], wfcli_data_extract:extract_values(Data, "Foo.9")).

parse_path_test() ->
    ?assertEqual([{key, "Foo"}, {index, 2}, wildcard], wfcli_data_extract:parse_path("Foo.2.*")).

parse_path_skips_empty_segments_test() ->
    ?assertEqual([{key, "Foo"}, {key, "Bar"}], wfcli_data_extract:parse_path("Foo..Bar")).
