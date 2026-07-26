%%%-------------------------------------------------------------------
%% Shared time formatting helpers.
%%%-------------------------------------------------------------------
-module(wfcli_time).

-export([format_millis/1, format_millis/2]).

format_millis(Ms) ->
    format_millis(Ms, #{}).

format_millis(Ms, Opts) when is_integer(Ms) ->
    case maps:get(raw, Opts, false) of
        true -> format_utc_millis(Ms);
        false -> format_local_millis(Ms)
    end;
format_millis(Value, Opts) ->
    Str = wfcli_text:to_list(Value),
    case re:run(Str, "^[+-]?[0-9]+$", [{capture, none}]) of
        match ->
            case string:to_integer(Str) of
                {Int, _} -> format_millis(Int, Opts);
                _ -> Str
            end;
        _ -> Str
    end.

format_utc_millis(Ms) ->
    Secs = Ms div 1000,
    try calendar:system_time_to_rfc3339(Secs, [{unit, second}, {offset, "Z"}]) of
        S -> S
    catch _:_ -> integer_to_list(Secs)
    end.

format_local_millis(Ms) ->
    Secs = Ms div 1000,
    try
        {Local, OffsetSecs} = local_time_with_offset(Secs),
        format_rfc3339(Local, format_offset(OffsetSecs))
    catch _:_ ->
        integer_to_list(Secs)
    end.

local_time_with_offset(Secs) ->
    Utc = calendar:system_time_to_universal_time(Secs, second),
    Local = case erlang:function_exported(calendar, system_time_to_local_time, 2) of
        true -> calendar:system_time_to_local_time(Secs, second);
        false -> calendar:universal_time_to_local_time(Utc)
    end,
    OffsetSecs = calendar:datetime_to_gregorian_seconds(Local) -
        calendar:datetime_to_gregorian_seconds(Utc),
    {Local, OffsetSecs}.

format_rfc3339({{Y, M, D}, {H, Min, S}}, Offset) ->
    lists:flatten(
      io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0w~s",
                    [Y, M, D, H, Min, S, Offset])).

format_offset(OffsetSecs) ->
    Sign = case OffsetSecs < 0 of true -> "-"; false -> "+" end,
    Abs = abs(OffsetSecs),
    Hours = Abs div 3600,
    Mins = (Abs rem 3600) div 60,
    lists:flatten(io_lib:format("~s~2..0w:~2..0w", [Sign, Hours, Mins])).
