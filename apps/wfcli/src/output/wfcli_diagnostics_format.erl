%%%-------------------------------------------------------------------
%% Terminal presentation for daemon resolution diagnostics.
%%%-------------------------------------------------------------------
-module(wfcli_diagnostics_format).

-export([print/2, print_query/2]).

-doc "Render current unresolved metadata in table or JSON form.".
-spec print([map()], table | json) -> ok.
print(Issues, json) ->
    io:format("~ts~n", [jsone:encode(#{<<"count">> => length(Issues),
                                      <<"issues">> => Issues})]);
print([], table) ->
    io:format("No unresolved metadata.~n");
print(Issues, table) ->
    io:format("Unresolved metadata: ~p~n~n", [length(Issues)]),
    print_table(Issues).

-doc "Render diagnostics returned through unified query.".
-spec print_query(map(), map()) -> ok.
print_query(Query, Results) ->
    Entries = maps:get(slice, Results, []),
    io:format("Matches: ~p (showing ~p)~n~n",
              [maps:get(total, Results, 0), maps:get(shown, Results, 0)]),
    case maps:get(output_format, Query, table) of
        block -> lists:foreach(fun print_block/1, Entries);
        table -> print_table([maps:get(data, Entry, #{}) || Entry <- Entries])
    end.

print_table([]) -> io:format("no entries~n");
print_table(Issues) ->
    Headers = ["Kind", "Name", "Identity", "Collection", "Reason"],
    Rows = [[text(maps:get(<<"kind">>, Issue, <<>>)),
             text(maps:get(<<"fallback">>, Issue, <<>>)),
             text(maps:get(<<"identity">>, Issue, <<>>)),
             text(maps:get(<<"collection">>, Issue, <<>>)),
             text(maps:get(<<"reason">>, Issue, <<>>))]
            || Issue <- Issues],
    lists:foreach(fun(Line) -> io:format("~ts~n", [Line]) end,
                  wfcli_table:render_lines(Headers, Rows, #{})).

print_block(Entry) ->
    Issue = maps:get(data, Entry, #{}),
    io:format("~ts: ~ts~n", [maps:get(<<"kind">>, Issue, <<>>),
                             maps:get(<<"fallback">>, Issue,
                                      maps:get(<<"identity">>, Issue, <<>>))]),
    io:format("  identity: ~ts~n", [maps:get(<<"identity">>, Issue, <<>>)]),
    io:format("  reason: ~ts~n~n", [maps:get(<<"reason">>, Issue, <<>>)]).

text(Value) -> wfcli_text:to_list(Value).
