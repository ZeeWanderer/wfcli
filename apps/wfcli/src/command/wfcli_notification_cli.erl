%%%-------------------------------------------------------------------
%% Fissure notification policy command.
%%%-------------------------------------------------------------------
-module(wfcli_notification_cli).

-export([run/1, help/0]).

-doc "Show or change daemon-owned fissure notification policy.".
-spec run([string()]) -> ok | no_return().
run([]) -> show();
run(["status"]) -> show();
run([Mode]) when Mode =:= "off"; Mode =:= "on"; Mode =:= "persistent" ->
    set_mode(Mode);
run([Arg | _]) when Arg =:= "help"; Arg =:= "--help"; Arg =:= "-h" ->
    help();
run([Mode | _]) ->
    fail(io_lib:format("unknown notification mode: ~s", [Mode])).

-doc "Print notification command help.".
-spec help() -> ok.
help() ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli notifications [status]\n"
      "  wfcli notifications off\n"
      "  wfcli notifications on\n"
      "  wfcli notifications persistent\n"
      "\n"
      "MODES:\n"
      "  off         disable fissure notifications\n"
      "  on          notify while at least one GUI is connected\n"
      "  persistent  notify while wfdaemon is running\n").

show() ->
    case wfcli_client:call(notification_settings) of
        {ok, Settings} when is_map(Settings) -> print(Settings);
        {error, Reason} -> fail(wfcli_client:format_error(Reason))
    end.

set_mode(Name) ->
    Mode = case Name of "on" -> <<"session">>; _ -> list_to_binary(Name) end,
    Patch = #{<<"fissures">> => #{<<"mode">> => Mode}},
    case wfcli_client:call({notification_settings, Patch}) of
        {ok, Settings} when is_map(Settings) -> print(Settings);
        {error, Reason} -> fail(wfcli_client:format_error(Reason))
    end.

print(Settings) ->
    Fissures = maps:get(<<"fissures">>, Settings, #{}),
    Mode = maps:get(<<"mode">>, Fissures, <<"off">>),
    Display = case Mode of <<"session">> -> <<"on">>; _ -> Mode end,
    io:format("Fissure notifications: ~ts~n", [Display]).

fail(Message) ->
    io:format("error: ~ts~n", [Message]),
    halt(1).
