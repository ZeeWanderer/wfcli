%%%-------------------------------------------------------------------
%% CLI argument helpers.
%%%-------------------------------------------------------------------
-module(wfcli_cli_args).

-export([expand_aliases/2, has_help_flag/1, help_path/1, strip_help_flags/1,
         prompt_enabled/1, prompt_suggestions/2, strip_prompt_flag/1, interactive/0]).

expand_aliases(Args, Aliases) ->
    map_options(fun(Options) -> [maps:get(A, Aliases, A) || A <- Options] end, Args).

has_help_flag(Args) ->
    lists:any(fun is_help_flag/1, option_args(Args)).

help_path(["completion", "candidates" | _]) ->
    none;
help_path(["help" | Rest]) ->
    {help, scope_path(strip_help(Rest))};
help_path(Args) ->
    case has_help_flag(Args) orelse
         (not lists:member("--", Args) andalso trailing_help(Args)) of
        true -> {help, scope_path(strip_help(Args))};
        false -> none
    end.

strip_help_flags(Args) ->
    map_options(fun(Options) -> [A || A <- Options, not is_help_flag(A)] end, Args).

prompt_enabled(Args) ->
    not lists:member("--no-suggest-prompt", option_args(Args)).

strip_prompt_flag(Args) ->
    {map_options(fun(Options) -> [A || A <- Options, A =/= "--no-suggest-prompt"] end,
                 Args), prompt_enabled(Args)}.

prompt_suggestions(Args0, Candidates) ->
    {Args, Prompt} = strip_prompt_flag(Args0),
    case Prompt andalso application:get_env(wfcli, suggest_prompt, true)
         andalso interactive() of
        false -> Args;
        true -> map_options(fun(Options) -> [maybe_prompt_arg(A, Candidates) || A <- Options] end,
                            Args)
    end.

interactive() ->
    case io:getopts() of
        Options when is_list(Options) ->
            proplists:get_value(stdin, Options, false) andalso
                proplists:get_value(stdout, Options, false);
        _ -> false
    end.

option_args(Args) -> lists:takewhile(fun(A) -> A =/= "--" end, Args).

map_options(Fun, Args) ->
    {Options, Rest} = lists:splitwith(fun(A) -> A =/= "--" end, Args),
    Fun(Options) ++ Rest.

maybe_prompt_arg(Arg, Candidates) ->
    case is_flag(Arg) of
        false -> Arg;
        true ->
            case lists:member(Arg, Candidates) of
                true -> Arg;
                false ->
                    case wfcli_cli_suggest:suggest_match(Arg, Candidates) of
                        {ok, Suggestion} -> maybe_accept_suggestion(Arg, Suggestion);
                        none -> Arg
                    end
            end
    end.

maybe_accept_suggestion(Arg, Suggestion) ->
    io:format("unknown arg: ~s. use ~s? [enter to accept] ", [Arg, Suggestion]),
    case safe_get_line() of
        accept -> Suggestion;
        _ -> Arg
    end.

safe_get_line() ->
    try io:get_line("") of
        eof -> decline;
        Line when is_list(Line) ->
            case string:lowercase(string:trim(Line)) of
                "" -> accept;
                "y" -> accept;
                _ -> decline
            end;
        _ -> decline
    catch _:_ ->
        decline
    end.

is_help_flag("-h") -> true;
is_help_flag("--help") -> true;
is_help_flag(_) -> false.

trailing_help([]) -> false;
trailing_help(Args) -> lists:last(Args) =:= "help".

strip_help(Args) ->
    [Arg || Arg <- Args, not is_help_flag(Arg) andalso Arg =/= "help"].

scope_path([]) -> [];
scope_path([[ $- | _ ] | _]) -> [];
scope_path([Arg | Rest]) -> [Arg | scope_path(Rest)].

is_flag([$- | _]) -> true;
is_flag(_) -> false.
