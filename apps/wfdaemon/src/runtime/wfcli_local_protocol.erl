%%%-------------------------------------------------------------------
%% JSON-lines protocol shared by wfdaemon and native companion clients.
%%%-------------------------------------------------------------------
-module(wfcli_local_protocol).

-export([decode/1, encode/1, protocol_version/0]).

-define(PROTOCOL_VERSION, 7).

-doc "Native companion protocol version.".
-spec protocol_version() -> pos_integer().
protocol_version() -> ?PROTOCOL_VERSION.

-doc "Decode one JSON protocol line into a binary-keyed map.".
-spec decode(binary()) -> {ok, map()} | {error, term()}.
decode(Line) when is_binary(Line) ->
    try jsone:decode(Line, [{object_format, map}]) of
        Map when is_map(Map) -> {ok, Map};
        Other -> {error, {expected_object, Other}}
    catch
        error:Reason -> {error, {invalid_json, Reason}}
    end.

-doc "Encode one binary-keyed protocol map as a JSON line.".
-spec encode(map()) -> iodata().
encode(Map) when is_map(Map) ->
    [jsone:encode(Map), $\n].
