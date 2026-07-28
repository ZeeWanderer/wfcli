%%%-------------------------------------------------------------------
%% Stable user-owned paths shared by CLI help and daemon persistence.
%%%-------------------------------------------------------------------
-module(wfcli_paths).

-export([cache_dir/0, cache_file/1, config_dir/0, config_file/1,
         state_dir/0, state_file/1, runtime_dir/0, runtime_file/1]).

-doc "Return the per-user wfcli cache directory without creating it.".
-spec cache_dir() -> file:filename_all().
cache_dir() ->
    Base = case os:getenv("XDG_CACHE_HOME") of
               false -> filename:join(home_dir(), ".cache");
               "" -> filename:join(home_dir(), ".cache");
               Value -> Value
           end,
    filename:join(Base, "wfcli").

-doc "Return a named file under the per-user wfcli cache directory.".
-spec cache_file(file:filename_all()) -> file:filename_all().
cache_file(Name) -> filename:join(cache_dir(), Name).

-doc "Return the per-user wfcli configuration directory without creating it.".
-spec config_dir() -> file:filename_all().
config_dir() ->
    Base = case os:getenv("XDG_CONFIG_HOME") of
               false -> filename:join(home_dir(), ".config");
               "" -> filename:join(home_dir(), ".config");
               Value -> Value
           end,
    filename:join(Base, "wfcli").

-doc "Return a named file under the per-user wfcli configuration directory.".
-spec config_file(file:filename_all()) -> file:filename_all().
config_file(Name) -> filename:join(config_dir(), Name).

-doc "Return the per-user wfcli persistent state directory without creating it.".
-spec state_dir() -> file:filename_all().
state_dir() ->
    Base = case os:getenv("XDG_STATE_HOME") of
               false -> filename:join([home_dir(), ".local", "state"]);
               "" -> filename:join([home_dir(), ".local", "state"]);
               Value -> Value
           end,
    filename:join(Base, "wfcli").

-doc "Return a named file under the per-user wfcli state directory.".
-spec state_file(file:filename_all()) -> file:filename_all().
state_file(Name) -> filename:join(state_dir(), Name).

-doc "Return per-user runtime directory used for local sockets and ephemeral state.".
-spec runtime_dir() -> file:filename_all().
runtime_dir() ->
    Base = case os:getenv("XDG_RUNTIME_DIR") of
               false -> cache_dir();
               "" -> cache_dir();
               Value -> Value
           end,
    filename:join(Base, "wfcli").

-doc "Return a named file under the per-user runtime directory.".
-spec runtime_file(file:filename_all()) -> file:filename_all().
runtime_file(Name) -> filename:join(runtime_dir(), Name).

home_dir() ->
    case os:getenv("HOME") of
        false -> ".";
        "" -> ".";
        Value -> Value
    end.
