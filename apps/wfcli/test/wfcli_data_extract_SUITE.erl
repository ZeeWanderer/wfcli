%%%-------------------------------------------------------------------
%% Common Test for data extraction helpers.
%%%-------------------------------------------------------------------
-module(wfcli_data_extract_SUITE).

-export([all/0,
         extract_values_path/1,
         extract_values_missing_key/1,
         extract_values_wildcard_list/1]).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [extract_values_path,
     extract_values_missing_key,
     extract_values_wildcard_list].

extract_values_path(_Config) ->
    Data = #{
        <<"Foo">> => #{<<"Bar">> => [1, 2, 3]},
        <<"List">> => [#{<<"Val">> => "a"}, #{<<"Val">> => "b"}]
    },
    ?assertEqual([2], wfcli_data_extract:extract_values(Data, "Foo.Bar.1")),
    ?assertEqual(["a", "b"], wfcli_data_extract:extract_values(Data, "List.Val")).

extract_values_missing_key(_Config) ->
    Data = #{<<"Foo">> => 1},
    ?assertEqual([], wfcli_data_extract:extract_values(Data, "Bar.Baz")).

extract_values_wildcard_list(_Config) ->
    Data = #{<<"List">> => [#{<<"Val">> => "a"}, #{<<"Val">> => "b"}]},
    ?assertEqual(["a", "b"], lists:sort(wfcli_data_extract:extract_values(Data, "List.*.Val"))).
