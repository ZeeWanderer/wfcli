%%%-------------------------------------------------------------------
%% Common Test for unified query command.
%%%-------------------------------------------------------------------
-module(wfcli_query_SUITE).

-export([all/0,
         init_per_suite/1,
         end_per_suite/1,
         query_combines_sources/1,
         query_selects_drops/1,
         query_format_alias/1,
         query_archimedea_semantic_fields/1,
         query_raw_worldstate_paths/1]).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [query_combines_sources,
     query_selects_drops,
     query_format_alias,
     query_archimedea_semantic_fields,
     query_raw_worldstate_paths].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(wfcli),
    ok = wfcli_test_daemon:start(),
    Config.

end_per_suite(_Config) ->
    wfcli_test_daemon:stop(),
    ok.

query_combines_sources(_Config) ->
    {Cache, Bin} = sample_cache(),
    ok = file:write_file(Cache, Bin),
    Dir = fixture_dir(),
    Output = capture_output(fun() ->
        wfcli_query_cli:run([
            "--cache", Cache,
            "--ttl", "999999999",
            "--exports-dir", Dir,
            "--knowledge-dir", fixture_knowledge_dir(),
            "test"
        ])
    end),
    ?assert(string:find(Output, "== Worldstate ==") =/= nomatch),
    ?assert(string:find(Output, "== Items ==") =/= nomatch),
    ?assert(string:find(Output, "== Drops ==") =:= nomatch),
    ?assert(string:find(Output, "Test Gun") =/= nomatch).

query_selects_drops(_Config) ->
    Output = capture_output(fun() ->
        wfcli_query_cli:run([
            "--knowledge-dir", fixture_knowledge_dir(),
            "dataset=drops|codex test mod"
        ])
    end),
    ?assert(string:find(Output, "== Drops ==") =/= nomatch),
    ?assert(string:find(Output, "Test Mod") =/= nomatch),
    ?assert(string:find(Output, "== Codex ==") =/= nomatch),
    ?assert(string:find(Output, "== Worldstate ==") =:= nomatch),
    ?assert(string:find(Output, "== Items ==") =:= nomatch).

query_format_alias(_Config) ->
    {Cache, Bin} = sample_cache(),
    ok = file:write_file(Cache, Bin),
    Dir = fixture_dir(),
    Output = capture_output(fun() ->
        wfcli_query_cli:run([
            "--cache", Cache,
            "--ttl", "999999999",
            "--exports-dir", Dir,
            "--format", "table",
            "test"
        ])
    end),
    ?assert(string:find(Output, "== Worldstate ==") =/= nomatch),
    ?assert(string:find(Output, "== Mods ==") =/= nomatch).

query_archimedea_semantic_fields(_Config) ->
    {Cache, Bin} = sample_cache(),
    ok = file:write_file(Cache, Bin),
    Output = capture_output(fun() ->
        wfcli_query_cli:run([
            "--cache", Cache,
            "--ttl", "999999999",
            "--format", "block",
            "dataset=worldstate type=archimedea archimedea=deep deviation~sealed"
        ])
    end),
    ?assert(string:find(Output, "Deep Archimedea") =/= nomatch),
    ?assert(string:find(Output, "Sealed Armor") =/= nomatch),
    ?assert(string:find(Output, "Commanding Culverins") =/= nomatch),
    ?assertEqual(nomatch, string:find(Output, "Temporal Archimedea")).

query_raw_worldstate_paths(_Config) ->
    {Cache, Bin} = sample_cache(),
    ok = file:write_file(Cache, Bin),
    Output = capture_output(fun() ->
        wfcli_query_cli:run([
            "--cache", Cache,
            "--ttl", "999999999",
            "dataset=worldstate type=raw_worldstate data.Conquests.1.Type=CT_HEX "
            "extract=data.Conquests.1.Missions.*.missionType "
            "extract=data.Conquests.1.Variables.*"
        ])
    end),
    ?assert(string:find(Output, "Raw worldstate") =/= nomatch),
    ?assert(string:find(Output, "MT_ENDLESS_CAPTURE") =/= nomatch),
    ?assert(string:find(Output, "Exhaustion") =/= nomatch).

fixture_dir() ->
    filename:join([code:lib_dir(wfcli), "test", "fixtures", "exports"]).

fixture_knowledge_dir() ->
    filename:join([code:lib_dir(wfcli), "test", "fixtures", "knowledge"]).

sample_cache() ->
    File = filename:join([code:lib_dir(wfcli), "test", "fixtures", "worldstate_sample.json"]),
    {ok, Bin} = file:read_file(File),
    BaseTmp = case os:getenv("TMPDIR") of false -> "/tmp"; undefined -> "/tmp"; V -> V end,
    Tmp = filename:join([BaseTmp, "wfcli_worldstate_cache.json"]),
    {Tmp, Bin}.

capture_output(Fun) ->
    Capturer = spawn(fun() -> io_capture_loop([]) end),
    Old = group_leader(),
    group_leader(Capturer, self()),
    try
        _ = Fun()
    after
        group_leader(Old, self())
    end,
    Capturer ! {get, self()},
    receive
        {captured, Output} -> to_list(Output)
    after 1000 ->
        ""
    end.

io_capture_loop(Acc) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {NewAcc, Reply} = handle_io_request(Request, Acc),
            From ! {io_reply, ReplyAs, Reply},
            io_capture_loop(NewAcc);
        {get, Requestor} ->
            Requestor ! {captured, lists:flatten(lists:reverse(Acc))},
            io_capture_loop(Acc)
    end.

handle_io_request({put_chars, Chars}, Acc) ->
    {[Chars | Acc], ok};
handle_io_request({put_chars, _Enc, Chars}, Acc) ->
    {[Chars | Acc], ok};
handle_io_request({put_chars, Enc, Mod, Fun, Args}, Acc) ->
    handle_io_request({put_chars, Enc, apply(Mod, Fun, Args)}, Acc);
handle_io_request({put_chars, Mod, Fun, Args}, Acc) ->
    handle_io_request({put_chars, apply(Mod, Fun, Args)}, Acc);
handle_io_request({format, Format, Args}, Acc) ->
    {[io_lib:format(Format, Args) | Acc], ok};
handle_io_request({fwrite, Format, Args}, Acc) ->
    {[io_lib:format(Format, Args) | Acc], ok};
handle_io_request({requests, Reqs}, Acc) when is_list(Reqs) ->
    lists:foldl(
      fun(Req, {Acc0, _Reply0}) -> handle_io_request(Req, Acc0) end,
      {Acc, ok},
      Reqs);
handle_io_request(_Req, Acc) ->
    {Acc, ok}.

to_list(V) when is_binary(V) -> binary_to_list(V);
to_list(V) when is_atom(V) -> atom_to_list(V);
to_list(V) when is_list(V) -> V;
to_list(V) -> io_lib:format("~p", [V]).
