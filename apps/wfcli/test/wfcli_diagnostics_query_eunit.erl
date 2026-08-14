-module(wfcli_diagnostics_query_eunit).

-include_lib("eunit/include/eunit.hrl").

filters_and_sorts_resolution_issues_test() ->
    Issues = [issue(<<"asset">>, <<"/Lotus/B">>, 2),
              issue(<<"asset">>, <<"/Lotus/A">>, 7),
              issue(<<"friendly_name">>, <<"/Lotus/C">>, 9)],
    {ok, Ast} = wfcli_query_parse:parse("kind=asset sort=-count"),
    {ok, #{results := #{slice := Rows, total := 2}}} =
        wfcli_diagnostics_query:execute(Ast, #{}, Issues),
    ?assertEqual([<<"/Lotus/A">>, <<"/Lotus/B">>],
                 [maps:get(<<"identity">>, maps:get(data, Row)) || Row <- Rows]).

rejects_invalid_sort_operator_test() ->
    {ok, Ast} = wfcli_query_parse:parse("sort>count"),
    ?assertMatch({error, {query_errors, [_]}},
                 wfcli_diagnostics_query:execute(Ast, #{}, [])).

issue(Kind, Identity, Count) ->
    #{<<"kind">> => Kind, <<"identity">> => Identity,
      <<"fallback">> => Identity, <<"scope">> => <<"build_equipment">>,
      <<"reason">> => <<"missing">>, <<"count">> => Count,
      <<"first_seen">> => 1, <<"last_seen">> => Count}.
