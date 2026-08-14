%%%-------------------------------------------------------------------
%% Atomic durable store for build catalogs, revisions, goals, and results.
%%%-------------------------------------------------------------------
-module(wfcli_build_store).

-export([load/0, save/1, path/0, empty/0]).

-define(SCHEMA, 2).

-doc "Load the build repository; a missing file is an empty repository.".
-spec load() -> {ok, map()} | {error, term()}.
load() ->
    Path = path(),
    case file:read_file(Path) of
        {ok, Binary} ->
            _ = file:change_mode(Path, 8#600),
            try binary_to_term(Binary, [safe]) of
                Store = #{schema := ?SCHEMA} -> {ok, normalize(Store)};
                Store = #{schema := 1} -> {ok, migrate(Store)};
                _Other -> {error, unsupported_build_store}
            catch error:Reason -> {error, {invalid_build_store, Reason}}
            end;
        {error, enoent} -> {ok, empty()};
        {error, Reason} -> {error, Reason}
    end.

-doc "Replace the repository atomically.".
-spec save(map()) -> ok | {error, term()}.
save(Store) when is_map(Store) ->
    Path = path(),
    case filelib:ensure_dir(Path) of
        ok ->
            Temp = Path ++ ".tmp",
            Data = term_to_binary(normalize(Store), [compressed, deterministic]),
            case file:write_file(Temp, Data, [binary]) of
                ok ->
                    _ = file:change_mode(Temp, 8#600),
                    case file:rename(Temp, Path) of
                        ok -> file:change_mode(Path, 8#600);
                        {error, _Reason} = Error -> Error
                    end;
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

-doc "Return configured build repository path.".
-spec path() -> file:filename_all().
path() ->
    case application:get_env(wfdaemon, build_store_file) of
        {ok, Path} -> Path;
        undefined -> wfcli_paths:state_file("builds.term")
    end.

-doc "Return an empty versioned repository.".
-spec empty() -> map().
empty() ->
    #{schema => ?SCHEMA, catalogs => #{}, revisions => #{}, latest => #{},
      goals => #{}, results => #{}}.

normalize(Store) ->
    Store#{schema => ?SCHEMA,
           catalogs => maps:get(catalogs, Store, #{}),
           revisions => maps:get(revisions, Store, #{}),
           latest => maps:get(latest, Store, #{}),
           goals => maps:get(goals, Store, #{}),
           results => maps:get(results, Store, #{})}.

migrate(Store) -> normalize(Store#{schema => ?SCHEMA}).
