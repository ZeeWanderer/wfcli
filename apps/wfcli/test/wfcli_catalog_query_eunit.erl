%%%-------------------------------------------------------------------
%% EUnit tests for typed catalog daemon replies.
%%%-------------------------------------------------------------------
-module(wfcli_catalog_query_eunit).

-include_lib("eunit/include/eunit.hrl").

export_reply_returns_daemon_prepared_query_test() ->
    Prepared = #{query => {term, "toxin"}, compiled_sort => []},
    Results = #{total => 1},
    ?assertEqual({ok, Prepared, Results},
      wfcli_exports_query:decode_daemon_reply(
        {ok, #{command => "mods", query => Prepared, results => Results}})).

knowledge_reply_returns_daemon_prepared_query_test() ->
    Prepared = #{query => {term, "toxin"}, compiled_sort => []},
    Results = #{total => 1},
    ?assertEqual({ok, Prepared, Results},
      wfcli_knowledge_query:decode_daemon_reply(
        {ok, #{command => "codex", query => Prepared, results => Results}})).
