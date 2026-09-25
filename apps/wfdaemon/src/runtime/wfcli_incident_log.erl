-module(wfcli_incident_log).

-export([install/0]).

install() ->
    case logger:get_handler_config(wfdaemon_incidents) of
        {ok, _} -> ok;
        {error, _} -> add_handler()
    end.

add_handler() ->
    Path = application:get_env(wfdaemon, incident_log_file, wfcli_paths:state_file("wfdaemon.log")),
    Config = #{level => warning,
               config => #{file => Path, max_no_bytes => 1024 * 1024, max_no_files => 2},
               formatter => {logger_formatter, #{single_line => true, max_size => 8192}}},
    Result = case filelib:ensure_dir(Path) of
        ok -> logger:add_handler(wfdaemon_incidents, logger_std_h, Config);
        Error -> Error
    end,
    case Result of
        ok -> ok;
        {error, {already_exist, wfdaemon_incidents}} -> ok;
        {error, Reason} ->
            logger:error("daemon incident log unavailable: ~ts: ~p", [Path, Reason])
    end.
