%%%-------------------------------------------------------------------
%% XDG desktop launcher installation for wfgui.
%%%-------------------------------------------------------------------
-module(wfcli_gui_desktop).

-export([install/0, uninstall/0, status/0]).

-ifdef(TEST).
-export([desktop_entry/1]).
-endif.

-define(DESKTOP_FILE, "wfgui.desktop").
-define(ICON_FILE, "wfgui.png").

-doc "Install the wfgui desktop entry and icon into XDG_DATA_HOME.".
-spec install() -> {ok, map()} | {error, term()}.
install() ->
    case {paths(), gui_binary(), icon_source()} of
        {{ok, Paths}, {ok, Gui}, {ok, IconSource}} ->
            install(Paths, Gui, IconSource);
        {{error, _Reason} = Error, _, _} -> Error;
        {_, {error, _Reason} = Error, _} -> Error;
        {_, _, {error, _Reason} = Error} -> Error
    end.

-doc "Remove the wfgui desktop entry and installed icon.".
-spec uninstall() -> {ok, map()} | {error, term()}.
uninstall() ->
    case paths() of
        {ok, Paths} ->
            case delete_files([maps:get(desktop, Paths), maps:get(icon, Paths)]) of
                ok -> {ok, Paths#{installed => false}};
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error -> Error
    end.

-doc "Return desktop entry paths and whether both files are installed.".
-spec status() -> {ok, map()} | {error, term()}.
status() ->
    case paths() of
        {ok, Paths} ->
            Installed = filelib:is_regular(maps:get(desktop, Paths)) andalso
                        filelib:is_regular(maps:get(icon, Paths)),
            {ok, Paths#{installed => Installed}};
        {error, _Reason} = Error -> Error
    end.

install(Paths, Gui, IconSource) ->
    Desktop = maps:get(desktop, Paths),
    Icon = maps:get(icon, Paths),
    case {filelib:ensure_dir(Desktop), filelib:ensure_dir(Icon),
          file:read_file(IconSource)} of
        {ok, ok, {ok, IconData}} ->
            case file:write_file(Icon, IconData) of
                ok ->
                    case file:write_file(Desktop, desktop_entry(Gui)) of
                        ok -> {ok, Paths#{installed => true, executable => Gui}};
                        {error, Reason} -> {error, {desktop_write_failed, Desktop, Reason}}
                    end;
                {error, Reason} -> {error, {icon_write_failed, Icon, Reason}}
            end;
        {{error, Reason}, _, _} -> {error, {directory_create_failed, Desktop, Reason}};
        {_, {error, Reason}, _} -> {error, {directory_create_failed, Icon, Reason}};
        {_, _, {error, Reason}} -> {error, {icon_read_failed, IconSource, Reason}}
    end.

paths() ->
    case data_home() of
        {ok, Home} ->
            {ok, #{desktop => filename:join([Home, "applications", ?DESKTOP_FILE]),
                   icon => filename:join([Home, "icons", "hicolor", "48x48",
                                          "apps", ?ICON_FILE])}};
        {error, _Reason} = Error -> Error
    end.

data_home() ->
    case os:getenv("XDG_DATA_HOME") of
        Value when is_list(Value), Value =/= "" -> {ok, filename:absname(Value)};
        _ ->
            case os:getenv("HOME") of
                Home when is_list(Home), Home =/= "" ->
                    {ok, filename:join(Home, ".local/share")};
                _ -> {error, home_directory_unavailable}
            end
    end.

gui_binary() ->
    find_regular(gui_binary_candidates(), gui_binary_not_found).

gui_binary_candidates() ->
    environment_path("WFGUI_BIN") ++
    [filename:join([Root, "bin", "wfgui"])
     || Root <- [wfcli_build:update_root(), wfcli_build:install_root()]] ++
    executable_path("wfgui").

icon_source() ->
    find_regular(
      environment_path("WFGUI_ICON") ++
      [filename:join([Root, "share", "wfcli", ?ICON_FILE])
       || Root <- [wfcli_build:update_root(), wfcli_build:install_root()]],
      gui_icon_not_found).

environment_path(Name) ->
    case os:getenv(Name) of
        Value when is_list(Value), Value =/= "" -> [filename:absname(Value)];
        _ -> []
    end.

executable_path(Name) ->
    case os:find_executable(Name) of false -> []; Path -> [Path] end.

find_regular(Paths, Error) ->
    case [filename:absname(Path) || Path <- Paths, filelib:is_regular(Path)] of
        [Path | _] -> {ok, Path};
        [] -> {error, {Error, Paths}}
    end.

delete_files([]) -> ok;
delete_files([Path | Rest]) ->
    case file:delete(Path) of
        ok -> delete_files(Rest);
        {error, enoent} -> delete_files(Rest);
        {error, Reason} -> {error, {delete_failed, Path, Reason}}
    end.

desktop_entry(Gui) ->
    iolist_to_binary([
        "[Desktop Entry]\n",
        "Type=Application\n",
        "Name=wfgui\n",
        "Comment=Warframe companion and planner\n",
        "Exec=", quote_exec(Gui), "\n",
        "Icon=wfgui\n",
        "Terminal=false\n",
        "Categories=Game;\n",
        "Keywords=Warframe;relics;inventory;mastery;\n",
        "StartupNotify=true\n",
        "StartupWMClass=wfgui\n",
        "X-GNOME-UsesNotifications=true\n"
    ]).

quote_exec(Path) -> [$", quote_exec_chars(Path), $"].

quote_exec_chars([]) -> [];
quote_exec_chars([Char | Rest])
  when Char =:= $\\; Char =:= $"; Char =:= $`; Char =:= $$ ->
    [$\\, Char | quote_exec_chars(Rest)];
quote_exec_chars([Char | Rest]) ->
    [Char | quote_exec_chars(Rest)].
