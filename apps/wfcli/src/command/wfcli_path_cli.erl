%%%-------------------------------------------------------------------
%% Read-only report of per-application XDG directories.
%%%-------------------------------------------------------------------
-module(wfcli_path_cli).

-include_lib("kernel/include/file.hrl").

-export([run/1, help/0]).
-ifdef(TEST).
-export([describe/1, app_paths/1, decode_owner_report/2, report_tree/1,
         filesystem_tree/1, links_in_scope/3]).
-endif.

-define(MAX_SYMLINKS, 40).

-spec run([string()]) -> ok | no_return().
run([]) ->
    print_merged(owner_reports());
run(["--apps"]) ->
    print_reports(owner_reports());
run(["wfcli"]) ->
    print_reports([owner_report(wfcli)]);
run(["wfdaemon"]) ->
    print_reports([owner_report(wfdaemon)]);
run(["wfcompanion"]) ->
    print_reports([owner_report(wfcompanion)]);
run(["wfgui"]) ->
    print_reports([owner_report(wfgui)]);
run(["-h"]) ->
    help();
run(["--help"]) ->
    help();
run(["help"]) ->
    help();
run([App | _]) ->
    io:format("error: unknown application: ~s~n", [App]),
    help(),
    halt(1).

-spec help() -> ok.
help() ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli paths\n"
      "  wfcli paths --apps\n"
      "  wfcli paths <wfcli|wfdaemon|wfcompanion|wfgui>\n"
      "\n"
      "DESCRIPTION:\n"
      "  Merge per-user directories into one filesystem tree without creating\n"
      "  them. Symlink nodes show their target and retain logical children.\n"
      "\n"
      "OPTIONS:\n"
      "  --apps   group directories by owning application\n").

owner_reports() ->
    [owner_report(wfcli), owner_report(wfdaemon),
     owner_report(wfcompanion), owner_report(wfgui)].

print_merged(Reports) ->
    {Paths, Errors} = collect_paths(Reports, [], []),
    Descriptions = [describe_path(Path) || Path <- lists:usort(Paths)],
    io:put_chars(wfcli_tree:format(filesystem_tree(Descriptions))),
    print_report_errors(Errors).

collect_paths([], Paths, Errors) -> {Paths, lists:reverse(Errors)};
collect_paths([{_App, {ok, AppPaths}} | Rest], Paths, Errors) ->
    collect_paths(Rest, [Path || {_Kind, Path} <- AppPaths] ++ Paths, Errors);
collect_paths([{App, {error, Reason}} | Rest], Paths, Errors) ->
    collect_paths(Rest, Paths, [{App, Reason} | Errors]).

print_report_errors([]) -> ok;
print_report_errors([{App, Reason} | Rest]) ->
    io:format(standard_error, "warning: ~s paths unavailable: ~s~n",
              [app_label(App), wfcli_client:format_error(Reason)]),
    print_report_errors(Rest).

print_reports(Reports) ->
    io:put_chars(wfcli_tree:format(report_tree(Reports))).

report_tree([Report]) -> report_node(Report);
report_tree(Reports) -> {<<"paths">>, [report_node(Report) || Report <- Reports]}.

filesystem_tree(Descriptions) ->
    Statuses = maps:from_list(
                 [{maps:get(path, Description), maps:get(status, Description)}
                  || Description <- Descriptions]),
    Links = maps:from_list(
              lists:append([maps:get(links, Description)
                            || Description <- Descriptions])),
    Trie = lists:foldl(
             fun(Description, Acc) ->
                     insert_path(maps:get(path, Description), Acc)
             end,
             #{}, Descriptions),
    {<<"/">>, trie_nodes(Trie, "/", Statuses, Links)}.

insert_path(Path, Trie) ->
    ["/" | Components] = filename:split(normalize_absolute(Path)),
    insert_components(Components, Trie).

insert_components([], Trie) -> Trie;
insert_components([Component | Rest], Trie) ->
    Child = maps:get(Component, Trie, #{}),
    Trie#{Component => insert_components(Rest, Child)}.

trie_nodes(Trie, Parent, Statuses, Links) ->
    [begin
         Logical = filename:join(Parent, Name),
         {tree_label(Name, Logical, Statuses, Links),
          trie_nodes(maps:get(Name, Trie), Logical, Statuses, Links)}
     end || Name <- lists:sort(maps:keys(Trie))].

tree_label(Name, Path, Statuses, Links) ->
    LinkLabel = case maps:find(Path, Links) of
                    {ok, Target} -> [Name, " -> ", Target];
                    error -> Name
                end,
    [LinkLabel, suffix(maps:get(Path, Statuses, undefined))].

report_node({App, {ok, Paths}}) ->
    {app_label(App), [path_node(Path) || Path <- describe_paths(Paths)]};
report_node({App, {error, Reason}}) ->
    {app_label(App), [{["unavailable: ", wfcli_client:format_error(Reason)], []}]}.

path_node(#{kind := Kind, path := Path, status := Status, links := Links}) ->
    PathNode = {["path ", Path, suffix(Status)], []},
    LinkNodes = [{["link ", Link, " -> ", Target], []}
                 || {Link, Target} <- Links],
    {kind_label(Kind), [PathNode | LinkNodes]}.

owner_report(wfcli) ->
    {wfcli, {ok, app_paths(wfcli)}};
owner_report(wfdaemon) ->
    {wfdaemon, daemon_paths()};
owner_report(wfcompanion) ->
    {wfcompanion, native_report(<<"wfcompanion">>,
                                fun() -> wfcli_companion_process:run(["paths"]) end)};
owner_report(wfgui) ->
    {wfgui, native_report(<<"wfgui">>, fun wfcli_gui_desktop:path_report/0)}.

daemon_paths() ->
    case wfcli_client:status() of
        {running, _Node, Info} ->
            case maps:get(paths, Info, undefined) of
                Paths when is_list(Paths) -> {ok, Paths};
                _ -> {ok, app_paths(wfdaemon)}
            end;
        {stopped, _Node} -> {ok, app_paths(wfdaemon)};
        {error, _Reason} -> {ok, app_paths(wfdaemon)}
    end.

native_report(App, Run) ->
    case Run() of
        {ok, Output} -> decode_owner_report(App, Output);
        {error, _Reason} = Error -> Error
    end.

decode_owner_report(ExpectedApp, Output) ->
    try jsone:decode(Output, [{object_format, map}]) of
        #{<<"app">> := ExpectedApp, <<"paths">> := Paths} when is_list(Paths) ->
            decode_paths(Paths, []);
        #{<<"app">> := App} ->
            {error, {unexpected_path_report_app, App}};
        _ ->
            {error, invalid_path_report}
    catch
        error:Reason -> {error, {invalid_path_report_json, Reason}}
    end.

decode_paths([], Acc) -> {ok, lists:reverse(Acc)};
decode_paths([#{<<"kind">> := Kind, <<"path">> := Path} | Rest], Acc)
  when is_binary(Kind), is_binary(Path) ->
    decode_paths(Rest, [{Kind, unicode:characters_to_list(Path)} | Acc]);
decode_paths([_ | _], _Acc) -> {error, invalid_path_report_entry}.

app_paths(App) -> wfcli_paths:directories(App).

describe_paths(Paths) ->
    [maps:put(kind, Kind, describe_path(Path)) || {Kind, Path} <- Paths].

describe_path(Path) ->
    Absolute = normalize_absolute(Path),
    {Status, Links} = describe(Absolute),
    #{path => Absolute, status => Status, links => Links}.

describe(Path) ->
    Absolute = normalize_absolute(Path),
    case resolve_path(Absolute, ?MAX_SYMLINKS) of
        {ok, Effective, Links, _} ->
            {describe_direct(Effective), visible_links(Absolute, Links)};
        {error, Reason} -> {{error, Reason}, []}
    end.

visible_links(Path, Links) ->
    case os:getenv("HOME") of
        Home when is_list(Home), Home =/= "" -> links_in_scope(Path, Links, Home);
        _ -> Links
    end.

links_in_scope(Path, Links, Home) ->
    Scope = normalize_absolute(Home),
    case path_within(Path, Scope) of
        true -> lists:dropwhile(
                  fun({Link, _Target}) -> not path_within(Link, Scope) end,
                  Links);
        false -> Links
    end.

path_within(Path, Scope) ->
    lists:prefix(filename:split(Scope), filename:split(Path)).

describe_direct(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = symlink}} ->
            case file:read_link(Path) of
                {ok, Target} -> {symlink, absolute_target(Path, Target)};
                {error, Reason} -> {error, Reason}
            end;
        {ok, #file_info{type = directory}} -> directory;
        {ok, #file_info{type = Type}} -> Type;
        {error, enoent} -> missing;
        {error, Reason} -> {error, Reason}
    end.

resolve_path("/", LinksLeft) ->
    {ok, "/", [], LinksLeft};
resolve_path(Path, LinksLeft) ->
    Parent = filename:dirname(Path),
    Name = filename:basename(Path),
    case resolve_path(Parent, LinksLeft) of
        {ok, EffectiveParent, ParentLinks, Remaining} ->
            Candidate = filename:join(EffectiveParent, Name),
            resolve_candidate(Path, Candidate, ParentLinks, Remaining);
        Error -> Error
    end.

resolve_candidate(LogicalPath, Candidate, ParentLinks, LinksLeft) ->
    case file:read_link_info(Candidate) of
        {ok, #file_info{type = symlink}} when LinksLeft > 0 ->
            case file:read_link(Candidate) of
                {ok, Target} ->
                    TargetPath = normalize_absolute(absolute_target(Candidate, Target)),
                    case resolve_path(TargetPath, LinksLeft - 1) of
                        {ok, Effective, TargetLinks, Remaining} ->
                            Links = ParentLinks ++
                                    [{LogicalPath, TargetPath} | TargetLinks],
                            {ok, Effective, Links, Remaining};
                        Error -> Error
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {ok, #file_info{type = symlink}} ->
            {error, eloop};
        {ok, _} ->
            {ok, Candidate, ParentLinks, LinksLeft};
        {error, enoent} ->
            {ok, Candidate, ParentLinks, LinksLeft};
        {error, Reason} ->
            {error, Reason}
    end.

normalize_absolute(Path) ->
    Parts = filename:split(filename:absname(Path)),
    filename:join(["/" | lists:reverse(normalize_parts(tl(Parts), []))]).

normalize_parts([], Acc) -> Acc;
normalize_parts(["." | Rest], Acc) -> normalize_parts(Rest, Acc);
normalize_parts([".." | Rest], [_ | Acc]) -> normalize_parts(Rest, Acc);
normalize_parts([".." | Rest], []) -> normalize_parts(Rest, []);
normalize_parts([Part | Rest], Acc) -> normalize_parts(Rest, [Part | Acc]).

absolute_target(Path, Target) ->
    case filename:pathtype(Target) of
        absolute -> Target;
        _ -> filename:absname(Target, filename:dirname(Path))
    end.

app_label(App) when is_atom(App) -> atom_to_binary(App);
app_label(App) -> App.

kind_label(Kind) when is_atom(Kind) -> atom_to_binary(Kind);
kind_label(Kind) -> Kind.

suffix(directory) -> "";
suffix(undefined) -> "";
suffix(missing) -> " (missing)";
suffix({symlink, Target}) -> [" -> ", Target];
suffix(Type) when is_atom(Type) -> [" (", atom_to_list(Type), ")"];
suffix({error, Reason}) -> io_lib:format(" (error: ~p)", [Reason]).
