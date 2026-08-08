%%%-------------------------------------------------------------------
%% Diagnostic control surface for standalone native companion.
%%%-------------------------------------------------------------------
-module(wfcli_companion_cli).

-export([run/1, help/0, help/1, known_commands/0]).

-ifdef(TEST).
-export([preview_directory/1]).
-endif.

-doc "Manage companion lifecycle, setup, and diagnostics.".
-spec run([string()]) -> ok | no_return().
run(Args) ->
    Aliases = #{"-h" => "--help"},
    case wfcli_cli_args:expand_aliases(Args, Aliases) of
        ["--help" | _] -> help(), halt(0);
        ["status"] -> status();
        ["start"] -> start();
        ["stop"] -> stop();
        ["restart"] -> restart();
        ["show"] -> set_visibility(<<"overlay">>, "overlay", true);
        ["hide"] -> set_visibility(<<"overlay">>, "overlay", false);
        ["hud", "show"] -> set_visibility(<<"hud">>, "HUD", true);
        ["hud", "hide"] -> set_visibility(<<"hud">>, "HUD", false);
        ["probe"] -> diagnostic(["probe"]);
        ["paths"] -> wfcli_path_cli:run(["wfcompanion"]);
        ["screenshot" | Rest] -> screenshot(Rest);
        ["relic-ocr" | Rest] -> diagnostic(["relic-ocr" | Rest]);
        ["preview" | Rest] -> preview(Rest);
        ["logs"] -> diagnostic(["logs"]);
        ["install" | Rest] -> install(Rest);
        ["uninstall" | Rest] -> uninstall(Rest);
        [] -> help(), halt(1);
        [Command | _] ->
            Suggest = wfcli_cli_suggest:suggest(Command, known_commands()),
            fail(io_lib:format("unknown companion command: ~s~s", [Command, Suggest]))
    end.

-doc "Print companion diagnostic command help.".
-spec help() -> ok.
help() -> io:put_chars(wfcli_help_text:companion_help()).

-spec help([string()]) -> ok.
help([]) -> help();
help(["preview" | _]) ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli companion preview list [--animated]\n"
      "  wfcli companion preview image TYPE|all [PATH]\n"
      "  wfcli companion preview video TYPE|all [PATH]\n");
help(["screenshot" | _]) ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli companion screenshot [FILE]\n");
help(["relic-ocr" | _]) ->
    io:put_chars(
      "USAGE:\n"
      "  wfcli companion relic-ocr [IMAGE]\n");
help(["hud" | _]) ->
    io:put_chars("USAGE:\n  wfcli companion hud show|hide\n");
help([Command | _]) when Command =:= "install"; Command =:= "uninstall" ->
    io:format("USAGE:~n  wfcli companion ~s [--dry-run]~n", [Command]);
help([Command | _]) ->
    case lists:member(Command, known_commands()) of
        true -> io:format("USAGE:~n  wfcli companion ~s~n", [Command]);
        false -> help()
    end.

-doc "Known companion diagnostic subcommands.".
-spec known_commands() -> [string()].
known_commands() ->
    ["status", "start", "stop", "restart", "show", "hide", "hud", "probe",
     "screenshot", "relic-ocr", "preview", "logs", "paths", "install", "uninstall",
     "help", "--help", "-h"].

status() ->
    Managed = wfcli_companion_process:unit_active(),
    io:format("wfcompanion~n  wfcli-managed service: ~s~n",
              [case Managed of true -> "active"; false -> "inactive" end]),
    case daemon_status() of
        {running, Local, Player} ->
            print_local(Local),
            print_player(Player);
        stopped -> io:format("wfdaemon stopped; no companion connection state~n");
        {error, Reason} -> fail(wfcli_client:format_error(Reason))
    end.

start() ->
    case connected_companions() of
        {ok, [_ | _] = Details} ->
            io:format("wfcompanion already connected~n"),
            print_companions(Details);
        {ok, []} ->
            case wfcli_companion_process:start() of
                {ok, already_running, _Output} ->
                    io:format("wfcompanion managed service already active~n");
                {ok, started, Output} ->
                    io:format("wfcompanion started as user service~n"),
                    print_command_output(Output);
                {error, Reason} -> fail(format_process_error(Reason))
            end;
        {error, Reason} -> fail(wfcli_client:format_error(Reason))
    end.

stop() ->
    case stop_result() of
        {ok, stopped, Output} ->
            io:format("wfcompanion stopped~n"),
            print_command_output(Output);
        {ok, not_running, _Output} -> io:format("wfcompanion not running~n");
        {error, Reason} -> fail(format_process_error(Reason))
    end.

restart() ->
    case stop_result() of
        {ok, _State, _Output} -> start();
        {error, Reason} -> fail(format_process_error(Reason))
    end.

stop_result() ->
    case connected_companions() of
        {ok, Details} ->
            Modes = [maps:get(mode, Detail, <<"unknown">>) || Detail <- Details],
            case lists:member(<<"launch">>, Modes) of
                true -> {error, steam_launch_companion};
                false -> stop_managed_or_refuse(Details)
            end;
        {error, Reason} -> {error, Reason}
    end.

stop_managed_or_refuse(Details) ->
    case wfcli_companion_process:unit_active() of
        true ->
            case wfcli_companion_process:stop() of
                {ok, Output} -> {ok, stopped, Output};
                {error, _Reason} = Error -> Error
            end;
        false when Details =:= [] -> {ok, not_running, <<>>};
        false -> {error, unmanaged_companion}
    end.

set_visibility(CommandName, Label, Visible) ->
    Command = #{<<"command">> => CommandName, <<"visible">> => Visible},
    case wfcli_client:call({companion_command, Command}) of
        {ok, {ok, 0}} -> fail("no wfcompanion is connected");
        {ok, {ok, Count}} ->
            State = case Visible of true -> "shown"; false -> "hidden" end,
            io:format("~s ~s on ~p companion(s)~n", [Label, State, Count]);
        {error, Reason} -> fail(wfcli_client:format_error(Reason))
    end.

print_local(unavailable) -> io:format("wfcompanion API unavailable~n");
print_local(Local) ->
    io:format("wfcompanion API~n"),
    io:format("  socket: ~s~n", [maps:get(socket, Local)]),
    io:format("  companion protocol: ~p~n", [maps:get(protocol, Local)]),
    io:format("  connections: ~p~n", [maps:get(connections, Local)]),
    io:format("  companions: ~p~n", [maps:get(companions, Local)]),
    print_companions(maps:get(companion_details, Local, [])).

print_companions([]) -> ok;
print_companions(Details) ->
    lists:foreach(
      fun(Detail) ->
          io:format("    pid: ~p, mode: ~ts, version: ~ts~n",
                    [maps:get(os_pid, Detail, undefined),
                     maps:get(mode, Detail, <<"unknown">>),
                     maps:get(version, Detail, <<"unknown">>)])
      end,
      Details).

print_player(unavailable) -> ok;
print_player(Player) ->
    io:format("  player revision: ~p~n", [maps:get(revision, Player, 0)]),
    io:format("  player sources: ~s~n",
              [string:join([wfcli_text:to_list(S) || S <- maps:get(sources, Player, [])], ", ")]),
    io:format("  game active: ~p~n", [maps:get(game_active, Player, false)]).

daemon_status() ->
    case wfcli_client:status() of
        {running, _Node, Info} ->
            {running, maps:get(local_api, Info, unavailable),
             maps:get(player, Info, unavailable)};
        {stopped, _Node} -> stopped;
        {error, _Reason} = Error -> Error
    end.

connected_companions() ->
    case daemon_status() of
        {running, Local, _Player} when is_map(Local) ->
            {ok, maps:get(companion_details, Local, [])};
        {running, unavailable, _Player} -> {ok, []};
        stopped -> {ok, []};
        {error, _Reason} = Error -> Error
    end.

screenshot(Args) ->
    case Args of
        [] ->
            Output = wfcli_paths:cache_file("companion-screenshot.png"),
            ok = filelib:ensure_dir(Output),
            diagnostic(["screenshot", Output]);
        [[ $- | _ ] = Option | _] ->
            fail(io_lib:format("unknown screenshot option: ~s", [Option]));
        [_Path] ->
            diagnostic(["screenshot" | Args]);
        _ ->
            fail("screenshot accepts one output path")
    end.

preview(["list"]) -> diagnostic(["preview", "list"]);
preview(["list", "--animated"]) -> diagnostic(["preview", "list", "--animated"]);
preview(["image", "all"]) -> preview(["image", "all", default_preview_directory()]);
preview(["image", "all", Directory]) -> diagnostic(["preview", "image", "all", Directory]);
preview(["image", Type]) ->
    preview(["image", Type, filename:join(default_preview_directory(), Type ++ ".png")]);
preview(["image", Type, Path]) -> diagnostic(["preview", "image", Type, Path]);
preview(["video", "all"]) -> preview(["video", "all", default_preview_directory()]);
preview(["video", "all", Directory]) -> diagnostic(["preview", "video", "all", Directory]);
preview(["video", Type]) ->
    preview(["video", Type, filename:join(default_preview_directory(), Type ++ ".webm")]);
preview(["video", Type, Path]) -> diagnostic(["preview", "video", Type, Path]);
preview(_Args) ->
    fail("preview requires list [--animated], image TYPE|all [PATH], "
         "or video TYPE|all [PATH]").

default_preview_directory() ->
    case wfcli_companion_process:binary() of
        {ok, Companion} -> preview_directory(Companion);
        {error, _Reason} -> filename:absname("previews")
    end.

preview_directory(Companion) ->
    BinDir = filename:dirname(filename:absname(Companion)),
    Parent = filename:dirname(BinDir),
    Root = case filename:basename(Parent) of
               Name when Name =:= "build"; Name =:= "dev"; Name =:= "prod" ->
                   filename:dirname(Parent);
               _ -> Parent
           end,
    filename:join(Root, "previews").

diagnostic(Args) ->
    case wfcli_companion_process:run(Args) of
        {ok, Output} -> print_command_output(Output);
        {error, Reason} -> fail(format_process_error(Reason))
    end.

install(Args) ->
    case dry_run(Args) of
        {ok, DryRun} ->
            case wfcli_companion_process:binary() of
                {ok, Companion} ->
                    print_steam_result(
                      wfcli_companion_steam:install(Companion, DryRun), install);
                {error, Reason} -> fail(format_process_error(Reason))
            end;
        error -> fail("install accepts only --dry-run")
    end.

uninstall(Args) ->
    case dry_run(Args) of
        {ok, DryRun} ->
            print_steam_result(wfcli_companion_steam:uninstall(DryRun), uninstall);
        error -> fail("uninstall accepts only --dry-run")
    end.

dry_run([]) -> {ok, false};
dry_run(["--dry-run"]) -> {ok, true};
dry_run(_Args) -> error.

print_steam_result({ok, Result}, install) ->
    Action = case maps:get(dry_run, Result) of true -> "would install"; false -> "installed" end,
    io:format("wfcompanion ~s for Warframe~n", [Action]),
    io:format("  config: ~ts~n", [maps:get(config, Result)]),
    io:format("  previous: ~ts~n", [maps:get(current, Result)]),
    io:format("  launch options: ~ts~n", [maps:get(proposed, Result)]);
print_steam_result({ok, Result}, uninstall) ->
    Action = case maps:get(dry_run, Result) of true -> "would uninstall"; false -> "uninstalled" end,
    io:format("wfcompanion ~s from Warframe~n", [Action]),
    io:format("  config: ~ts~n", [maps:get(config, Result)]),
    io:format("  restored: ~ts~n", [maps:get(original, Result)]);
print_steam_result({error, Reason}, _Action) -> fail(format_steam_error(Reason)).

format_steam_error(steam_running) ->
    "Steam is running; close Steam before changing launch options";
format_steam_error(companion_not_installed) -> "wfcompanion Steam wrapper is not installed";
format_steam_error(warframe_steam_config_not_found) ->
    "Warframe Steam configuration was not found";
format_steam_error({multiple_warframe_steam_configs, Paths}) ->
    io_lib:format("multiple Steam users contain Warframe: ~p", [Paths]);
format_steam_error({launch_options_changed, Current}) ->
    io_lib:format("Warframe launch options changed after install; refusing overwrite: ~ts", [Current]);
format_steam_error(Reason) -> io_lib:format("Steam setup failed: ~p", [Reason]).

format_process_error(steam_launch_companion) ->
    "companion is Steam launch wrapper; stop it by exiting Warframe";
format_process_error(unmanaged_companion) ->
    "companion is connected but was not started by wfcli; refusing to kill it";
format_process_error({companion_binary_not_found, _Candidates}) ->
    "wfcompanion binary not found; run `make companion`";
format_process_error({exit_status, Status, Output}) ->
    io_lib:format("command exited with status ~p: ~ts", [Status, string:trim(Output)]);
format_process_error({companion_start_failed, Reason}) -> format_process_error(Reason);
format_process_error(Reason) -> io_lib:format("companion command failed: ~p", [Reason]).

print_command_output(<<>>) -> ok;
print_command_output(Output) ->
    io:put_chars(Output),
    case binary:last(Output) of $\n -> ok; _ -> io:put_chars("\n") end.

fail(Message) ->
    io:format("error: ~ts~n", [Message]),
    halt(1).
