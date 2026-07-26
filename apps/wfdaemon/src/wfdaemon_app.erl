%%%-------------------------------------------------------------------
%% wfdaemon OTP application.
%%%-------------------------------------------------------------------
-module(wfdaemon_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    StateDir = wfcli_paths:state_dir(),
    case {file:get_cwd(), filelib:ensure_path(StateDir)} of
        {{ok, PreviousDir}, ok} ->
            case file:set_cwd(StateDir) of
                ok -> start_supervisor(PreviousDir);
                {error, Reason} -> {error, {state_directory_unusable, StateDir, Reason}}
            end;
        {{error, Reason}, _} -> {error, {working_directory_unavailable, Reason}};
        {_, {error, Reason}} -> {error, {state_directory_unusable, StateDir, Reason}}
    end.

start_supervisor(PreviousDir) ->
    case wfcli_sup:start_link() of
        {ok, Pid} -> {ok, Pid, PreviousDir};
        Error ->
            _ = file:set_cwd(PreviousDir),
            Error
    end.

stop(PreviousDir) ->
    _ = file:set_cwd(PreviousDir),
    ok.
