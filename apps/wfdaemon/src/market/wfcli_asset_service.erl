%%%-------------------------------------------------------------------
%% Daemon-owned cache for catalog image assets.
%%%-------------------------------------------------------------------
-module(wfcli_asset_service).

-behaviour(gen_server).

-export([start_link/0, resolve/1, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CACHE_VERSION, 1).
-define(DEFAULT_BASE_URL, "https://cdn.warframestat.us/img/").
-define(DEFAULT_MARKET_BASE_URL, "https://warframe.market/static/assets/").
-define(MAX_ASSETS, 64).
-define(MAX_ASSET_BYTES, 8388608).
-define(FRESH_MS, 604800000).

-type state() :: #{
    root := file:filename_all(),
    index_path := file:filename_all(),
    entries := map()
}.

-doc "Start the persistent catalog asset cache.".
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Resolve catalog image names to validated local cache files.".
-spec resolve([map()]) -> {ok, [map()]} | {error, term()}.
resolve(Assets) ->
    gen_server:call(?SERVER, {resolve, Assets}, 60000).

-doc "Return cache location and object count.".
-spec status() -> map().
status() ->
    gen_server:call(?SERVER, status).

-spec init([]) -> {ok, state()}.
init([]) ->
    Root = cache_root(),
    IndexPath = filename:join(Root, "index.term"),
    {ok, #{root => Root, index_path => IndexPath,
           entries => load_index(IndexPath)}}.

-spec handle_call(term(), gen_server:from(), state()) -> {reply, term(), state()}.
handle_call({resolve, Assets}, _From, State)
  when is_list(Assets), length(Assets) =< ?MAX_ASSETS ->
    {Results, State1} = resolve_assets(Assets, State),
    {reply, {ok, Results}, State1};
handle_call({resolve, _Assets}, _From, State) ->
    {reply, {error, invalid_assets}, State};
handle_call(status, _From, State) ->
    {reply, #{cache_root => maps:get(root, State),
              objects => map_size(maps:get(entries, State))}, State};
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_request, Request}}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Message, State) -> {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(_Message, State) -> {noreply, State}.

-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) -> ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

resolve_assets(Assets, State) ->
    Prepared = prepare_assets(Assets, State, 0, []),
    Fetches = [{Position, Request} || {Position, {fetch, Request}} <- Prepared],
    commit_assets(Prepared, fetch_parallel(Fetches), State, []).

prepare_assets([], _State, _Position, Acc) -> lists:reverse(Acc);
prepare_assets([Spec | Rest], State, Position, Acc) ->
    Prepared = prepare_asset(Spec, State),
    prepare_assets(Rest, State, Position + 1, [{Position, Prepared} | Acc]).

prepare_asset(#{<<"id">> := Id, <<"image_name">> := Name} = Spec, State)
  when is_binary(Id), is_binary(Name) ->
    Source = maps:get(<<"source">>, Spec, <<"wfcd">>),
    case valid_asset_name(Source, Name) of
        true -> prepare_valid(Id, Source, Name, State);
        false -> {ready, unavailable(Id, invalid_image_name)}
    end;
prepare_asset(Spec, _State) ->
    Id = case Spec of
        #{<<"id">> := Value} when is_binary(Value) -> Value;
        _ -> <<>>
    end,
    {ready, unavailable(Id, invalid_asset)}.

prepare_valid(Id, Source, Name, State) ->
    Entries = maps:get(entries, State),
    Key = {Source, Name},
    Cached = maps:get(Key, Entries, undefined),
    case usable_cached(Cached) andalso fresh(Cached) of
        true -> {ready, descriptor(Id, Source, Name, Cached, false)};
        false -> {fetch, {Id, Source, Name, Cached}}
    end.

fetch_parallel([]) -> #{};
fetch_parallel(Fetches) ->
    Parent = self(),
    Pending = lists:foldl(
      fun({Position, Request}, Acc) ->
          {Pid, Monitor} = spawn_monitor(fun() ->
              Parent ! {asset_fetch_result, self(), Position,
                        safe_fetch_asset(Request)}
          end),
          Acc#{Pid => {Monitor, Position}}
      end, #{}, Fetches),
    collect_fetches(Pending, #{}).

collect_fetches(Pending, Results) when map_size(Pending) =:= 0 -> Results;
collect_fetches(Pending, Results) ->
    receive
        {asset_fetch_result, Pid, Position, Result} ->
            case maps:take(Pid, Pending) of
                {{Monitor, Position}, Rest} ->
                    erlang:demonitor(Monitor, [flush]),
                    collect_fetches(Rest, Results#{Position => Result});
                error -> collect_fetches(Pending, Results)
            end;
        {'DOWN', Monitor, process, Pid, Reason} ->
            case maps:take(Pid, Pending) of
                {{Monitor, Position}, Rest} ->
                    collect_fetches(
                      Rest, Results#{Position => {error, {asset_worker_down, Reason}}});
                error -> collect_fetches(Pending, Results)
            end
    end.

safe_fetch_asset(Request) ->
    try fetch_asset(Request)
    catch Class:Reason -> {error, {asset_fetch_crash, Class, Reason}}
    end.

fetch_asset({_Id, Source, Name, Cached}) ->
    Url = asset_url(Source, Name),
    Headers = request_headers(Cached),
    case http_get(Url, Headers) of
        {ok, 304, _ResponseHeaders, _Body} when is_map(Cached) ->
            {entry, Cached#{fetched_at => erlang:system_time(millisecond)}};
        {ok, 200, ResponseHeaders, Body0} ->
            Body = iolist_to_binary(Body0),
            case validate_body(Body, ResponseHeaders) of
                {ok, MediaType, Extension} ->
                    {body, Url, Body, MediaType, Extension, ResponseHeaders};
                {error, Reason} -> {error, Reason}
            end;
        {ok, Status, _ResponseHeaders, _Body} ->
            {error, {asset_http_status, Status}};
        {error, Reason} -> {error, {asset_http_failed, Reason}};
        Other -> {error, {invalid_asset_http_result, Other}}
    end.

commit_assets([], _Fetched, State, Acc) -> {lists:reverse(Acc), State};
commit_assets([{_Position, {ready, Result}} | Rest], Fetched, State, Acc) ->
    commit_assets(Rest, Fetched, State, [Result | Acc]);
commit_assets([{Position, {fetch, {Id, Source, Name, Cached}}} | Rest],
              Fetched, State, Acc) ->
    {Result, State1} = commit_fetch(
                         Id, Source, Name, Cached,
                         maps:get(Position, Fetched,
                                  {error, asset_worker_missing}), State),
    commit_assets(Rest, Fetched, State1, [Result | Acc]).

commit_fetch(Id, Source, Name, _Cached, {entry, Entry}, State) ->
    save_entry({Source, Name}, Source, Name, Entry, State, Id, false);
commit_fetch(Id, Source, Name, _Cached,
             {body, Url, Body, MediaType, Extension, Headers}, State) ->
    store_body(Id, Source, Name, Url, Body, MediaType, Extension, Headers, State);
commit_fetch(Id, Source, Name, Cached, {error, Reason}, State) ->
    stale_or_error(Id, Source, Name, Cached, Reason, State).

store_body(Id, Source, Name, Url, Body, MediaType, Extension, Headers, State) ->
    Digest = hex(crypto:hash(sha256, Body)),
    Objects = filename:join(maps:get(root, State), "objects"),
    Path = filename:join(Objects, binary_to_list(<<Digest/binary, Extension/binary>>)),
    ok = filelib:ensure_dir(Path),
    case write_object(Path, Body) of
        ok ->
            Entry = #{url => list_to_binary(Url), path => list_to_binary(Path),
                      digest => Digest, media_type => MediaType,
                      size => byte_size(Body),
                      etag => response_header(<<"etag">>, Headers),
                      last_modified => response_header(<<"last-modified">>, Headers),
                      fetched_at => erlang:system_time(millisecond)},
            save_entry({Source, Name}, Source, Name, Entry, State, Id, false);
        {error, Reason} ->
            {unavailable(Id, {asset_cache_write_failed, Reason}), State}
    end.

save_entry(Key, Source, Name, Entry, State, Id, Stale) ->
    Entries = (maps:get(entries, State))#{Key => Entry},
    State1 = State#{entries => Entries},
    case persist_index(maps:get(index_path, State), Entries) of
        ok -> {descriptor(Id, Source, Name, Entry, Stale), State1};
        {error, Reason} ->
            {unavailable(Id, {asset_index_write_failed, Reason}), State}
    end.

stale_or_error(Id, Source, Name, Cached, _Reason, State) when is_map(Cached) ->
    case usable_cached(Cached) of
        true -> {descriptor(Id, Source, Name, Cached, true), State};
        false -> {unavailable(Id, asset_unavailable), State}
    end;
stale_or_error(Id, _Source, _Name, _Cached, Reason, State) ->
    {unavailable(Id, Reason), State}.

descriptor(Id, Source, Name, Entry, Stale) ->
    #{<<"id">> => Id, <<"ok">> => true, <<"image_name">> => Name,
      <<"source">> => Source,
      <<"path">> => maps:get(path, Entry),
      <<"digest">> => maps:get(digest, Entry),
      <<"media_type">> => maps:get(media_type, Entry),
      <<"size">> => maps:get(size, Entry),
      <<"stale">> => Stale}.

unavailable(Id, Reason) ->
    #{<<"id">> => Id, <<"ok">> => false,
      <<"error">> => iolist_to_binary(io_lib:format("~p", [Reason]))}.

valid_asset_name(<<"wfcd">>, Name) -> valid_image_name(Name);
valid_asset_name(<<"market">>, Name) -> valid_market_path(Name);
valid_asset_name(_Source, _Name) -> false.

valid_image_name(Name) when byte_size(Name) > 0, byte_size(Name) =< 255 ->
    binary:match(Name, <<"/">>) =:= nomatch
    andalso binary:match(Name, <<"\\">>) =:= nomatch
    andalso binary:match(Name, <<"..">>) =:= nomatch
    andalso binary:match(Name, <<":">>) =:= nomatch
    andalso binary:match(Name, <<0>>) =:= nomatch;
valid_image_name(_Name) -> false.

valid_market_path(Name) when byte_size(Name) > 0, byte_size(Name) =< 512 ->
    (binary:match(Name, <<"items/images/">>) =:= {0, 13}
     orelse binary:match(Name, <<"sub_icons/">>) =:= {0, 10})
    andalso binary:match(Name, <<"..">>) =:= nomatch
    andalso binary:match(Name, <<"\\">>) =:= nomatch
    andalso binary:match(Name, <<":">>) =:= nomatch
    andalso binary:match(Name, <<0>>) =:= nomatch;
valid_market_path(_Name) -> false.

asset_url(<<"wfcd">>, Name) ->
    Base = application:get_env(wfdaemon, asset_base_url, ?DEFAULT_BASE_URL),
    Base ++ uri_string:quote(binary_to_list(Name));
asset_url(<<"market">>, Name) ->
    Base = application:get_env(wfdaemon, market_asset_base_url,
                               ?DEFAULT_MARKET_BASE_URL),
    Base ++ binary_to_list(Name).

request_headers(Cached) ->
    Base = [{"user-agent", "wfcli/0.1 (+https://github.com/ZeeWanderer/wfcli)"},
            {"accept", "image/png,image/jpeg"}],
    conditional_header("if-none-match", etag, Cached,
      conditional_header("if-modified-since", last_modified, Cached, Base)).

conditional_header(_Name, _Key, Cached, Headers) when not is_map(Cached) -> Headers;
conditional_header(Name, Key, Cached, Headers) ->
    case maps:get(Key, Cached, undefined) of
        Value when is_binary(Value), byte_size(Value) > 0 ->
            [{Name, binary_to_list(Value)} | Headers];
        _ -> Headers
    end.

http_get(Url, Headers) ->
    try
        case application:get_env(wfdaemon, asset_http_fun) of
            {ok, Fun} when is_function(Fun, 2) -> Fun(Url, Headers);
            _ -> real_http_get(Url, Headers)
        end
    catch Class:Reason -> {error, {asset_http_crash, Class, Reason}}
    end.

real_http_get(Url, Headers) ->
    case httpc:request(get, {Url, Headers}, [{timeout, 15000}],
                       [{body_format, binary}]) of
        {ok, {{_Version, Status, _Reason}, ResponseHeaders, Body}} ->
            {ok, Status, ResponseHeaders, Body};
        {error, Reason} -> {error, Reason}
    end.

validate_body(Body, _Headers) when byte_size(Body) > ?MAX_ASSET_BYTES ->
    {error, asset_too_large};
validate_body(<<16#89, "PNG", 13, 10, 26, 10, _/binary>>, _Headers) ->
    {ok, <<"image/png">>, <<".png">>};
validate_body(<<16#ff, 16#d8, 16#ff, _/binary>>, _Headers) ->
    {ok, <<"image/jpeg">>, <<".jpg">>};
validate_body(_Body, _Headers) ->
    {error, invalid_asset_body}.

response_header(Name, Headers) ->
    Lower = binary_to_list(Name),
    case lists:dropwhile(
           fun({Key, _Value}) ->
               string:lowercase(wfcli_text:to_list(Key)) =/= Lower
           end,
           Headers) of
        [{_Key, Value} | _] -> wfcli_text:to_binary(Value);
        [] -> undefined
    end.

usable_cached(Entry) when is_map(Entry) ->
    case maps:get(path, Entry, undefined) of
        Path when is_binary(Path) -> filelib:is_file(binary_to_list(Path));
        _ -> false
    end;
usable_cached(_Entry) -> false.

fresh(Entry) ->
    Now = erlang:system_time(millisecond),
    Now - maps:get(fetched_at, Entry, 0) < ?FRESH_MS.

write_object(Path, Body) ->
    case filelib:is_file(Path) of
        true -> ok;
        false ->
            Temp = Path ++ ".tmp",
            case file:write_file(Temp, Body) of
                ok -> file:rename(Temp, Path);
                {error, _Reason} = Error -> Error
            end
    end.

cache_root() ->
    case application:get_env(wfdaemon, asset_cache_dir) of
        {ok, Path} -> Path;
        undefined -> wfcli_paths:cache_file("assets")
    end.

load_index(Path) ->
    case file:read_file(Path) of
        {ok, Binary} ->
            try binary_to_term(Binary, [safe]) of
                #{version := ?CACHE_VERSION, entries := Entries} when is_map(Entries) -> Entries;
                _ -> #{}
            catch _:_ -> #{}
            end;
        {error, _Reason} -> #{}
    end.

persist_index(Path, Entries) ->
    ok = filelib:ensure_dir(Path),
    Temp = Path ++ ".tmp",
    Binary = term_to_binary(#{version => ?CACHE_VERSION, entries => Entries}, [compressed]),
    case file:write_file(Temp, Binary) of
        ok -> file:rename(Temp, Path);
        {error, _Reason} = Error -> Error
    end.

hex(Binary) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#f))>> || <<Byte>> <= Binary >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.
