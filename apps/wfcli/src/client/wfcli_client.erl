%%%-------------------------------------------------------------------
%% Stable public facade for daemon lifecycle and request transport.
%%%-------------------------------------------------------------------
-module(wfcli_client).

-export([
    status/0,
    start/0,
    start/1,
    stop/0,
    restart/0,
    restart/1,
    update/1,
    hot_update/1,
    hot_update_beam_dir/0,
    call/1,
    one_shot/1,
    subscribe/1,
    next/2,
    unsubscribe/1,
    ensure_running/0,
    format_error/1,
    daemon_node/0,
    release_script_candidates/0,
    release_environment/0
]).

-ifdef(TEST).
-export([handshake_compatibility/2, readiness_result/2, terminate_port_process/1]).
-endif.

-type control_result() ::
    {ok, started | already_running | stopped | restarted, node()} | {error, term()}.
-type idle_policy() :: persistent | idle | {idle, pos_integer()}.

-doc "Return daemon status without auto-starting it.".
-spec status() -> {running, node(), map()} | {stopped, node()} | {error, term()}.
status() -> wfcli_daemon_client:status().

-doc "Start wfdaemon using its configured persistent policy.".
-spec start() -> control_result().
start() -> wfcli_daemon_client:start().

-doc "Start wfdaemon and apply one idle policy.".
-spec start(idle_policy()) -> control_result().
start(Policy) -> wfcli_daemon_client:start(Policy).

-doc "Stop wfdaemon if running.".
-spec stop() -> control_result().
stop() -> wfcli_daemon_client:stop().

-doc "Restart wfdaemon using its persistent policy.".
-spec restart() -> control_result().
restart() -> wfcli_daemon_client:restart().

-doc "Restart wfdaemon and apply one idle policy.".
-spec restart(idle_policy()) -> control_result().
restart(Policy) -> wfcli_daemon_client:restart(Policy).

-doc "Apply an OTP release upgrade by release package name.".
-spec update(string()) -> {ok, term()} | {error, term()}.
update(ReleaseName) -> wfcli_daemon_client:update(ReleaseName).

-doc "Hot-load daemon BEAMs from embedded code or one build directory.".
-spec hot_update(auto | file:filename_all()) -> {ok, map()} | {error, term()}.
hot_update(Source) -> wfcli_daemon_client:hot_update(Source).

-doc "Find the local daemon BEAM directory used for development hot updates.".
-spec hot_update_beam_dir() -> {ok, file:filename_all()} | {error, term()}.
hot_update_beam_dir() -> wfcli_daemon_client:hot_update_beam_dir().

-doc "Call daemon request API, starting it when absent.".
-spec call(term()) -> {ok, term()} | {error, term()}.
call(Request) -> wfcli_client_transport:call(Request).

-doc "Submit one request and wait for its asynchronous response.".
-spec one_shot(map()) -> {ok, term()} | {error, term()}.
one_shot(Request) -> wfcli_client_transport:one_shot(Request).

-doc "Register a persistent daemon request stream.".
-spec subscribe(map()) -> {ok, map()} | {error, term()}.
subscribe(Request) -> wfcli_client_transport:subscribe(Request).

-doc "Wait for the next response from a request stream.".
-spec next(map(), timeout()) -> {ok, term()} | {error, term()}.
next(Handle, Timeout) -> wfcli_client_transport:next(Handle, Timeout).

-doc "Cancel a daemon request stream.".
-spec unsubscribe(map()) -> ok | {error, term()}.
unsubscribe(Handle) -> wfcli_client_transport:unsubscribe(Handle).

-doc "Return a compatible daemon, starting or updating it when needed.".
-spec ensure_running() -> {ok, started | already_running, node()} | {error, term()}.
ensure_running() -> wfcli_daemon_client:ensure_running().

-doc "Format daemon and protocol failures for terminal output.".
-spec format_error(term()) -> string().
format_error(Reason) -> wfcli_daemon_client:format_error(Reason).

-doc "Return configured distributed daemon node name.".
-spec daemon_node() -> node().
daemon_node() -> wfcli_daemon_client:daemon_node().

-doc "Return daemon release-script discovery candidates.".
-spec release_script_candidates() -> [file:filename_all()].
release_script_candidates() -> wfcli_daemon_client:release_script_candidates().

-doc "Return environment passed to a spawned daemon release.".
-spec release_environment() -> [{string(), string() | false}].
release_environment() -> wfcli_daemon_client:release_environment().

-ifdef(TEST).
handshake_compatibility(Reply, Version) ->
    wfcli_daemon_client:handshake_compatibility(Reply, Version).

readiness_result(Ping, Call) -> wfcli_daemon_client:readiness_result(Ping, Call).

terminate_port_process(Port) -> wfcli_daemon_client:terminate_port_process(Port).
-endif.
