-module(wfcli_companion_format).

-export([collectors/2, metadata/1, captures/2]).

collectors(#{collector := Collector} = Player, Local) when map_size(Collector) > 0 ->
    Current = current(Collector, Local) andalso maps:get(game_active, Player, false),
    [io_lib:format("Collectors (~s)~n", [case Current of true -> "current session"; false -> "last reported" end]),
     field("game pid", maps:get(<<"game_pid">>, Collector, undefined)),
     collector("debug output", Collector, <<"debug_output_active">>, <<"debug_output_lines_observed">>, "lines"),
     error_line(Collector, <<"debug_output_error">>),
     collector("inventory", Collector, <<"inventory_active">>, <<"inventory_updates_observed">>, "receipts"),
     time("last inventory received", maps:get(<<"inventory_received_at">>, Collector, undefined)),
     error_line(Collector, <<"inventory_error">>),
     collector("game metadata", Collector, <<"game_metadata_active">>, <<"game_metadata_updates_observed">>, "receipts"),
     field("metadata source", maps:get(<<"game_metadata_source">>, Collector, undefined)),
     time("last metadata received", maps:get(<<"game_metadata_received_at">>, Collector, undefined)),
     error_line(Collector, <<"game_metadata_error">>),
     time("report updated", maps:get(<<"last_observed_at">>, Collector, undefined))];
collectors(_, _) -> "Collectors: no report\n".

collector(Label, Data, Active, Count, Unit) ->
    State = case maps:get(Active, Data, false) of true -> "running"; false -> "stopped" end,
    io_lib:format("  ~s: ~s (~p ~s)~n", [Label, State, maps:get(Count, Data, 0), Unit]).

metadata(#{available := Available} = Metadata) ->
    [io_lib:format("Game metadata cache: ~s (revision ~p)~n",
                   [case Available of true -> "available"; false -> "empty" end,
                    maps:get(revision, Metadata, 0)]),
     time("updated", maps:get(updated_at, Metadata, undefined)),
     field("executable SHA256", maps:get(executable_sha256, Metadata, undefined)),
     [io_lib:format("  pools: ~p Warframes, ~p primaries, ~p secondaries, ~p melees~n",
                    [maps:get(Key, Pools, 0) || Key <- [<<"suits">>, <<"primaries">>, <<"secondaries">>, <<"melees">>]])
      || Pools <- [maps:get(pools, Metadata, #{})], map_size(Pools) > 0],
     case maps:get(capture_error, Metadata, undefined) of
         #{<<"reason">> := Reason} -> field("capture warning", Reason);
         _ -> []
     end];
metadata(_) -> "Game metadata cache: unavailable\n".

captures(Player, Local) when is_map(Player) ->
    Request = maps:get(capture, Player, #{}),
    Armed = current(Request, Local) andalso maps:get(<<"state">>, Request, undefined) =:= <<"armed">>,
    ArmedLabel = case {current(Request, Local), Local} of
        {true, _} -> case Armed of true -> "yes"; false -> "no" end;
        {false, #{companions := 0}} -> "no companion connected";
        _ -> "unknown (no current report)"
    end,
    ["Relic-reward evidence capture\n",
     io_lib:format("  armed: ~s~n", [ArmedLabel]),
     case map_size(Request) of
         0 -> "  no request reported\n";
         _ -> [field("last request", maps:get(<<"state">>, Request, undefined)),
               field("output", maps:get(<<"directory">>, Request, undefined)),
               time("request updated", maps:get(<<"updated_at">>, Request, undefined)),
               case Armed of true -> time("expires", maps:get(<<"expires_at">>, Request, undefined)); false -> [] end]
     end,
     case maps:get(capture_result, Player, #{}) of
         Result when map_size(Result) > 0 ->
             [field("last result", maps:get(<<"state">>, Result, undefined)),
              field("result output", maps:get(<<"directory">>, Result, undefined)),
              time("result recorded", maps:get(<<"updated_at">>, Result, undefined)),
              error_line(Result, <<"error">>)];
         _ -> []
     end];
captures(_, _) -> "Relic-reward evidence capture: unavailable\n".

current(#{<<"companion_pid">> := Pid}, #{companion_details := Details}) ->
    lists:any(fun(Detail) -> maps:get(os_pid, Detail, undefined) =:= Pid end, Details);
current(_, _) -> false.

error_line(Data, Key) -> field("error", maps:get(Key, Data, undefined)).

field(_Label, Value) when Value =:= undefined; Value =:= null -> [];
field(Label, Value) -> io_lib:format("  ~s: ~ts~n", [Label, wfcli_text:to_list(Value)]).

time(_Label, Value) when Value =:= undefined; Value =:= null -> [];
time(Label, Value) -> field(Label, wfcli_diagnostics_format:timestamp(Value)).
