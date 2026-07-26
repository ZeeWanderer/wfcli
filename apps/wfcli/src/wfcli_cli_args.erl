%%%-------------------------------------------------------------------
%% CLI argument helpers.
%%%-------------------------------------------------------------------
-module(wfcli_cli_args).

-export([expand_aliases/2, has_help_flag/1, strip_help_flags/1,
         prompt_enabled/1, prompt_suggestions/2, strip_prompt_flag/1]).

expand_aliases(Args, Aliases) ->
    lists:map(fun(A) -> maps:get(A, Aliases, A) end, Args).

has_help_flag(Args) ->
    lists:any(fun is_help_flag/1, Args).

strip_help_flags(Args) ->
    [A || A <- Args, not is_help_flag(A)].

prompt_enabled(Args) ->
    not lists:member("--no-suggest-prompt", Args).

strip_prompt_flag(Args) ->
    { [A || A <- Args, A =/= "--no-suggest-prompt"], prompt_enabled(Args) }.

prompt_suggestions(Args0, Candidates) ->
    {Args, Prompt} = strip_prompt_flag(Args0),
    case Prompt of
        false -> Args;
        true -> [maybe_prompt_arg(A, Candidates) || A <- Args]
    end.

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

is_flag([$- | _]) -> true;
is_flag(_) -> false.
