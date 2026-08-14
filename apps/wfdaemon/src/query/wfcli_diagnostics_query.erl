%%%-------------------------------------------------------------------
%% Unified-query adapter for daemon diagnostics.
%%%-------------------------------------------------------------------
-module(wfcli_diagnostics_query).

-export([execute/3, query_field/2, query_sort_field/2, default_sort/1]).

-doc "Compile and execute the query AST against current resolution issues.".
-spec execute(term(), map(), [map()]) -> {ok, map()} | {error, term()}.
execute(Ast0, Request, Issues) ->
    case wfcli_query_parse:extract_control(Ast0, sort) of
        {ok, Ast, SortControls} -> execute_sorted(Ast, SortControls, Request, Issues);
        {error, Error} -> {error, {query_errors, [Error]}}
    end.

execute_sorted(Ast, SortControls, Request, Issues) ->
    case compile_sorts(SortControls) of
        {ok, []} -> run(Ast, default_sort(diagnostics), Request, Issues);
        {ok, Sorts} -> run(Ast, Sorts, Request, Issues);
        {error, Error} -> {error, {query_errors, [Error]}}
    end.

run(Ast, Sorts, Request, Issues) ->
    case {wfcli_entity_query:compile(Ast, ?MODULE, diagnostics),
          wfcli_entity_query:compile_sorts(Sorts, ?MODULE, diagnostics)} of
        {{ok, Compiled}, {ok, CompiledSorts}} ->
            Entries = [entry(Issue) || Issue <- Issues],
            Results = wfcli_entity_query:execute(
                        Entries, Compiled, CompiledSorts, ?MODULE, diagnostics,
                        maps:get(offset, Request, 0),
                        maps:get(limit, Request, infinity)),
            {ok, #{query => #{query => Compiled, compiled_sort => CompiledSorts,
                              output_format => maps:get(output_format, Request, table),
                              raw => maps:get(raw, Request, false)},
                   results => Results}};
        {{error, Errors}, _} -> {error, {query_errors, Errors}};
        {_, {error, Errors}} -> {error, {query_errors, Errors}}
    end.

compile_sorts(Controls) -> compile_sorts(Controls, []).

compile_sorts([], Acc) -> {ok, lists:reverse(Acc)};
compile_sorts([#{op := Op, vals := Values} | Rest], Acc)
  when Op =:= eq; Op =:= default ->
    Parsed = [wfcli_query_sort:parse(Value) || Value <- Values],
    compile_sorts(Rest, lists:reverse(Parsed) ++ Acc);
compile_sorts([_ | _], _Acc) ->
    {error, "sort supports only '=' or ':'"}.

entry(Issue) ->
    Identity = maps:get(<<"identity">>, Issue),
    Name = maps:get(<<"fallback">>, Issue, Identity),
    Kind = maps:get(<<"kind">>, Issue),
    Spec = #{row_map_fun => fun(_Entry) ->
        #{kind => Kind, identity => Identity, name => Name,
          scope => maps:get(<<"scope">>, Issue, <<>>),
          reason => maps:get(<<"reason">>, Issue, <<>>),
          count => maps:get(<<"count">>, Issue, 0),
          last_seen => maps:get(<<"last_seen">>, Issue, 0)}
    end},
    Base = wfcli_entity:build(resolution_issue, Identity, Name, Issue,
                              #{search_raw => true}, Spec),
    Base#{kind => Kind, identity => Identity,
          scope => maps:get(<<"scope">>, Issue, <<>>),
          reason => maps:get(<<"reason">>, Issue, <<>>),
          fallback => Name,
          class => maps:get(<<"class">>, Issue, <<>>),
          collection => maps:get(<<"collection">>, Issue, <<>>),
          attempts => maps:get(<<"attempts">>, Issue, []),
          catalog_revision => maps:get(<<"catalog_revision">>, Issue, <<>>),
          count => maps:get(<<"count">>, Issue, 0),
          first_seen => maps:get(<<"first_seen">>, Issue, 0),
          last_seen => maps:get(<<"last_seen">>, Issue, 0)}.

-doc "Resolve diagnostics filter fields.".
-spec query_field(term(), string() | atom()) -> {ok, map()} | error.
query_field(_Kind, Key0) ->
    case string:lowercase(wfcli_text:to_list(Key0)) of
        "name" -> field(name, {entry, name}, string, contains);
        "kind" -> field(kind, {entry, kind}, string, eq);
        "identity" -> field(identity, {entry, identity}, string, contains);
        "scope" -> field(scope, {entry, scope}, string, eq);
        "reason" -> field(reason, {entry, reason}, string, contains);
        "fallback" -> field(fallback, {entry, fallback}, string, contains);
        "class" -> field(class, {entry, class}, string, eq);
        "collection" -> field(collection, {entry, collection}, string, eq);
        "attempts" -> field(attempts, {entry_values, attempts}, string, eq);
        "catalog_revision" -> field(catalog_revision, {entry, catalog_revision}, string, eq);
        "count" -> field(count, {entry, count}, number, eq);
        "first_seen" -> field(first_seen, {entry, first_seen}, number, eq);
        "last_seen" -> field(last_seen, {entry, last_seen}, number, eq);
        _ -> error
    end.

-doc "Diagnostics sort fields use the filter-field contract.".
-spec query_sort_field(term(), string() | atom()) -> {ok, map()} | error.
query_sort_field(Kind, Key) -> query_field(Kind, Key).

-doc "Keep diagnostics stable by issue kind and identity.".
-spec default_sort(term()) -> [map()].
default_sort(_Kind) -> [#{key => kind, dir => asc}, #{key => identity, dir => asc}].

field(Key, Source, Kind, DefaultOp) ->
    {ok, #{key => Key, source => Source, kind => Kind, default_op => DefaultOp}}.
