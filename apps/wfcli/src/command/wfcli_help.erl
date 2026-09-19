-module(wfcli_help).

-export([command/0, run/1, text/1]).

command() ->
    #{help => "show command help", handler => fun(Args) -> run(maps:get(topic, Args, [])) end,
      arguments => [#{name => topic, nargs => all, required => false, default => [],
                      help => "command path or query-syntax"}]}.

run(Topic) ->
    case valid_topic(Topic) of
        true -> io:put_chars(text(Topic));
        false -> wfcli_cli:fail(["unknown help topic: ", lists:join(" ", Topic)])
    end.

valid_topic(["query-syntax"]) -> true;
valid_topic(["commands"]) -> true;
valid_topic(["--help"]) -> true;
valid_topic(["-h"]) -> true;
valid_topic(Topic) ->
    try wfcli_cli_args:node(Topic, wfcli_cli:command()) of
        _ -> true
    catch error:{badkey, _} -> false; error:function_clause -> false end.

text(["commands"]) -> text([]);
text(["--help"]) -> text([]);
text(["-h"]) -> text([]);
text(["query-syntax"]) ->
    [wfcli_help_text:query_guide(), "\n", wfcli_help_text:query_examples()];
text([]) ->
    Groups = wfcli_cli:command_groups(),
    Width = lists:max([length(Name) || {_, Rows} <- Groups, {Name, _} <- Rows]),
    ["USAGE:\n  wfcli <command> [options]\n\n",
     [[Group, ":\n", [["  ", string:pad(Name, Width), "  ", Summary, "\n"]
                      || {Name, Summary} <- Rows], "\n"]
      || {Group, Rows} <- Groups],
     "Use 'wfcli COMMAND --help' for options, 'wfcli help query-syntax' for queries.\n"];
text(Path) ->
    Node = wfcli_cli_args:node(Path, wfcli_cli:command()),
    Help = wfcli_cli_args:flag(help, "help", "show this help"),
    Display = Node#{help => maps:get(summary, Node, maps:get(help, Node, "")),
                    arguments => [Help#{short => $h} | [display_argument(Arg)
                                  || Arg <- maps:get(arguments, Node, [])]]},
    [argparse:help(Display, #{progname => string:join(["wfcli" | Path], " "),
                             columns => min(100, wfcli_tty:terminal_width())}),
     maps:get(notes, Node, "")].

display_argument(#{default := []} = Arg) -> display_argument(maps:remove(default, Arg));
display_argument(#{long := "-" ++ Long} = Arg) -> Arg#{name => Long};
display_argument(#{name := query_tokens} = Arg) -> Arg#{name => "QUERY"};
display_argument(Arg) -> Arg.
