%%%-------------------------------------------------------------------
%% Shared help text snippets.
%%%-------------------------------------------------------------------
-module(wfcli_help_text).

-export([
    query_guide/0,
    query_examples/0,
    mods_examples/0,
    items_examples/0,
    worldstate_summary/2,
    worldstate_watch/1,
    worldstate_subcommand/4,
    exports_summary/0,
    query_command_help/0,
    player_help/0,
    market_help/0,
    companion_help/0,
    mcp_help/0,
    update_help/0,
    daemon_help/0,
    visualize_help/0,
    forma_plan_help/0
]).

mcp_help() ->
    [
        "USAGE:\n",
        "  wfcli mcp\n",
        "\n",
        "DESCRIPTION:\n",
        "  Serve newline-delimited MCP JSON-RPC over standard input and output.\n",
        "  Requests use the same persistent wfdaemon as terminal commands.\n",
        "\n",
        "NOTES:\n",
        "  Standard output is reserved for protocol messages; diagnostics use standard error.\n",
        "  Closing the MCP process cancels its queued or running daemon requests.\n"
    ].

query_guide() ->
    [
        "  - Adjacent terms are ANDed. Use uppercase OR, AND, NOT, and parentheses.\n",
        "  - Precedence: NOT, then AND, then OR. Quoted text matches one substring phrase.\n",
        "  - Operators: =, !=, ~, >=, <=, >, <, or key:value for defaults.\n",
        "  - Inside one filter, value1|value2 means either value; use OR between expressions.\n",
        "  - Backslash escapes the next syntax character. Boolean keywords are uppercase only.\n",
        "  - Sorting: sort=field or sort=-field (desc).\n"
    ].

query_examples() ->
    [
        "  query: wfcli query \"type=Fissure void\"\n",
        "  query: wfcli query \"type=Fissure|Alert data.MissionType=MT_DEFENSE\"\n",
        "  query: wfcli query '(fissure OR alert) NOT expired'\n",
        "  query: wfcli query \"type=Alert sort=expiry\"\n",
        "  query: wfcli watch --spec \"alerts:reward~endo\"\n",
        "  query: wfcli watch --spec \"fissures:extract=data.Node\"\n"
    ].

mods_examples() ->
    [
        "  mods:  wfcli mods type=MELEE polarity=V toxin\n",
        "  mods:  wfcli mods rarity:rare compat:claws\n",
        "  mods:  wfcli mods baseDrain>=4 type=MELEE|PRIMARY\n",
        "  mods:  wfcli mods '(toxin OR cold) NOT rarity=common'\n",
        "  mods:  wfcli mods --type MELEE --polarity V --text toxin\n",
        "  mods:  wfcli mods sort=-baseDrain type=MELEE\n"
    ].

items_examples() ->
    [
        "  items: wfcli items file=ExportWeapons_en.json name:braton\n",
        "  items: wfcli items productCategory=Primary text:burst\n",
        "  items: wfcli items file=ExportResources_en.json|ExportRelicArcane_en.json\n"
    ].

worldstate_summary(CommandNames, DefaultCache) ->
    [
        "USAGE:\n",
        "  wfcli <data-command> [options] [query]\n",
        "  wfcli watch [options] --spec SPEC...\n",
        "\n",
        "COMMON OPTIONS:\n",
        "  --search QUERY     filter entries (a bare query also works) [-q]\n",
        "  --output-format F  table | block (default: table) [-f]\n",
        "  --raw              keep raw identifiers and UTC timestamps\n",
        "  --refresh          force refetch ignoring cache\n",
        "  --ttl SECONDS      cache TTL (min 60s, default 60s)\n",
        io_lib:format("  --cache FILE       cache file path (default: ~s)~n", [DefaultCache]),
        "\n",
        "SPECIAL MODES:\n",
        "  wfcli teshin                   list current Steel Path offerings\n",
        "  wfcli baro inventory         list the published Baro manifest\n",
        "  wfcli prime-vault inventory list Prime Vault manifest items\n",
        "  wfcli calendar --day N         select one calendar day\n",
        "  wfcli events --lang CODE       select event message language\n",
        "\n",
        "WATCHING:\n",
        "  Add --watch to one data command, or use 'wfcli watch' for several.\n",
        "  Run 'wfcli help watch' for watch options and examples.\n",
        "\n",
        "NOTES:\n",
        "  Commands list their category by default; add a query to filter it.\n",
        "  Run 'wfcli help <command>' or 'wfcli <command> --help' for exact options.\n",
        "  Run 'wfcli update --help' for metadata refresh options.\n",
        "\n",
        io_lib:format("DATA COMMANDS:\n  ~s~n", [string:join(CommandNames, ", ")])
    ].

worldstate_watch(DefaultCache) ->
    [
        "USAGE:\n",
        "  wfcli watch [options] --spec SPEC [--spec SPEC...]\n",
        "  wfcli watch [options] -- SPEC...\n",
        "\n",
        "WATCH OPTIONS:\n",
        "  --spec SPEC        watch spec (repeatable, or use -- to end options)\n",
        "  --interval SECONDS watch refresh interval (min 60s, default 60s)\n",
        "  --once             print one update and exit\n",
        "  --always           print every tick, even when unchanged [-a]\n",
        "  --diff-style S     inline | list | diff | none (default: inline)\n",
        "  --diff             shortcut for --diff-style list [-d]\n",
        "  --clear            clear screen before output (--no-clear disables)\n",
        "  --output-format F  table | block (default: block) [-f]\n",
        "\n",
        "DATA OPTIONS:\n",
        "  --refresh          force the initial refetch\n",
        "  --ttl SECONDS      cache TTL (min 60s, default 60s)\n",
        io_lib:format("  --cache FILE       cache file path (default: ~s)~n", [DefaultCache]),
        "\n",
        "SPEC FORMAT:\n",
        "  <command> or <command>:<query>; use '|' for multiple commands.\n",
        "\n",
        "EXAMPLES:\n",
        "  wfcli watch --spec alerts\n",
        "  wfcli watch --spec 'fissures:tier=lith' --spec 'alerts:reward~endo'\n",
        "  wfcli alerts --watch --always\n"
    ].

worldstate_subcommand(Sub, teshin, Description, _DefaultCache) ->
    [
        "USAGE:\n",
        io_lib:format("  wfcli ~s [options] [query]~n", [Sub]),
        "\n",
        "DESCRIPTION:\n",
        io_lib:format("  ~s.\n", [sentence_case(Description)]),
        "  Shows this week's rotating reward and all evergreen offerings.\n",
        "\n",
        "QUERY AND OUTPUT:\n",
        "  --search QUERY     filter offerings (a bare query also works) [-q]\n",
        "  --output-format F  table | block (default: table) [-f]\n",
        "  --format F         alias for --output-format\n",
        "\n",
        "NOTES:\n",
        "  Inventory is calculated from WFCD's eight-week Steel Path rotation.\n",
        "  No live vendor endpoint is queried; watch mode is not supported.\n",
        "\n",
        "EXAMPLES:\n",
        "  wfcli teshin\n",
        "  wfcli teshin riven\n",
        "  wfcli teshin --output-format block\n"
    ];
worldstate_subcommand(Sub, Type, Description, DefaultCache) ->
    [
        "USAGE:\n",
        io_lib:format("  wfcli ~s [options] [query]~n", [Sub]),
        inventory_usage(Sub, Type),
        "\n",
        "DESCRIPTION:\n",
        io_lib:format("  ~s.\n", [sentence_case(Description)]),
        command_options(Type),
        "\n",
        "QUERY AND OUTPUT:\n",
        "  --search QUERY     filter entries (a bare query also works) [-q]\n",
        command_output_option(Type),
        "  --format F         alias for --output-format\n",
        "  --raw              keep raw identifiers and UTC timestamps\n",
        "\n",
        "DATA FRESHNESS:\n",
        "  --refresh          force refetch ignoring cache\n",
        "  --ttl SECONDS      cache TTL (min 60s, default 60s)\n",
        io_lib:format("  --cache FILE       cache file path (default: ~s)~n", [DefaultCache]),
        "\n",
        "WATCH OPTIONS:\n",
        "  --watch            keep watching this command [-w]\n",
        "  --interval SECONDS refresh interval (min/default: 60s)\n",
        "  --once             print one update and exit\n",
        "  --always           print unchanged ticks too [-a]\n",
        "  --diff-style S     inline | list | diff | none (default: inline)\n",
        "  --diff             shortcut for --diff-style list [-d]\n",
        "  --clear            clear screen before output (--no-clear disables)\n",
        command_notes(Type),
        "\n",
        "EXAMPLES:\n",
        command_examples(Sub, Type)
    ].

inventory_usage(Sub, Type) when Type =:= baro; Type =:= prime_vault ->
    io_lib:format("  wfcli ~s inventory [options] [query]~n", [Sub]);
inventory_usage(_Sub, _Type) -> [].

command_options(baro) ->
    ["\nCOMMAND OPTIONS:\n",
     "  inventory          list offerings in the published Baro manifest\n",
     "  --inventory        equivalent option form\n"];
command_options(prime_vault) ->
    ["\nCOMMAND OPTIONS:\n",
     "  inventory          list Prime Vault manifest and evergreen items\n",
     "  --inventory        equivalent option form\n"];
command_options(calendar) ->
    ["\nCOMMAND OPTIONS:\n",
     "  --day N            filter by calendar day number\n"];
command_options(event) ->
    ["\nCOMMAND OPTIONS:\n",
     "  --lang CODE        event message language (default: en)\n"];
command_options(archimedea) ->
    ["\nCOMMAND OPTIONS:\n",
     "  deep, --deep       show only Deep Archimedea\n",
     "  temporal, --temporal show only Temporal Archimedea\n"];
command_options(_Type) -> [].

command_output_option(archimedea) ->
    "  --output-format F  table | block (default: block) [-f]\n";
command_output_option(_Type) ->
    "  --output-format F  table | block (default: table) [-f]\n".

command_notes(Type) when Type =:= baro; Type =:= prime_vault ->
    ["\nNOTES:\n",
     "  Inventory mode cannot be combined with --watch.\n",
     "  Inventory is empty when the current worldstate publishes no manifest.\n"];
command_notes(archimedea) ->
    ["\nNOTES:\n",
     "  Mission output includes normal risks and additional Elite risks.\n",
     "  Loadout choices are account-specific and absent from public worldstate.\n"];
command_notes(_Type) ->
    ["\nNOTES:\n",
     "  Run 'wfcli help watch' for multi-command watches.\n"].

command_examples(_Sub, baro) ->
    ["  wfcli baro\n",
     "  wfcli baro inventory\n",
     "  wfcli baro inventory primed\n"];
command_examples(_Sub, prime_vault) ->
    ["  wfcli prime-vault\n",
     "  wfcli prime-vault inventory\n"];
command_examples(_Sub, calendar) ->
    ["  wfcli calendar --day 3\n",
     "  wfcli calendar --watch --always\n"];
command_examples(_Sub, event) ->
    ["  wfcli events\n",
     "  wfcli events --lang fr\n"];
command_examples(_Sub, archimedea) ->
    ["  wfcli archimedea\n",
     "  wfcli archimedea deep\n",
     "  wfcli archimedea temporal\n",
     "  wfcli archimedea --search 'risk~regeneration'\n"];
command_examples(Sub, _Type) ->
    [io_lib:format("  wfcli ~s~n", [Sub]),
     io_lib:format("  wfcli ~s QUERY~n", [Sub]),
     io_lib:format("  wfcli ~s --watch --always~n", [Sub])].

sentence_case([First | Rest]) when is_integer(First, $a, $z) ->
    [First - ($a - $A) | Rest];
sentence_case(Text) -> Text.

exports_summary() ->
    [
        "USAGE:\n",
        "  wfcli <command> [options] [query]\n",
        "\n",
        "COMMANDS:\n",
        "  mods, items, codex, enemies, drops\n",
        "\n",
        "NOTES:\n",
        "  Run 'wfcli help query' for query syntax details.\n"
    ].

query_command_help() ->
    [
        "USAGE:\n",
        "  wfcli query [options] <query...>\n",
        "\n",
        "OPTIONS:\n",
        "  --output-format F  block | table (default: table) [-f]\n",
        "  --raw              disable item/faction resolution and keep UTC timestamps\n",
        "  --refresh          force refetch ignoring cache\n",
        "  --ttl SECONDS      cache TTL (min 60s, default 60s)\n",
        "  --cache FILE       cache file path\n",
        "  --lang CODE        event language code (default: en)\n",
        "  --exports-dir DIR  override export file location\n",
        "  --knowledge-dir DIR override WFCD cache location\n",
        "  --limit N          limit matches per dataset (default: unlimited)\n",
        "  --offset N         skip matches per dataset (default 0)\n",
        "\n",
        "QUERY SYNTAX:\n",
        query_guide(),
        "  Dataset selector: dataset=default|worldstate|mods|items|codex|enemies|drops|player|market|all.\n",
        "  Default searches all public datasets; all also includes local player and market data.\n",
        "  Data keys: name, id, type, projected fields, and data.<path>.\n",
        "  Full raw tree: type=raw_worldstate with absolute data.<path>.\n",
        "  Watch extracts: extract=data.<path>.\n",
        "\n",
        "EXAMPLES:\n",
        query_examples(),
        "  query: wfcli query 'dataset=codex|drops serration'\n",
        mods_examples(),
        items_examples()
    ].

player_help() ->
    [
        "USAGE:\n",
        "  wfcli player\n",
        "  wfcli player [query options] QUERY...\n",
        "\n",
        "DESCRIPTION:\n",
        "  Shows daemon-owned local player data. With QUERY, delegates to the standard\n",
        "  query DSL using dataset=player.\n",
        "\n",
        "EXAMPLES:\n",
        "  wfcli player\n",
        "  wfcli player source=game\n",
        "  wfcli player 'data.phase=game'\n",
        "  wfcli player --format block inventory\n",
        "\n",
        "NOTES:\n",
        "  Player data is populated by wfcompanion and remains local to wfdaemon.\n",
        "  Run 'wfcli help query' for operators and common query options.\n"
    ].

market_help() ->
    [
        "USAGE:\n",
        "  wfcli market [options] QUERY...\n",
        "\n",
        "DESCRIPTION:\n",
        "  Resolves QUERY against Warframe Market items, then fetches top online PC\n",
        "  cross-play sell and buy orders. Uses the standard query DSL.\n",
        "\n",
        "OPTIONS:\n",
        "  --output-format F  table | block (default: table) [-f]\n",
        "  --refresh          bypass quote TTL\n",
        "  --ttl SECONDS      quote TTL (min/default: 60s)\n",
        "  --limit N          quote at most N matching items (maximum: 100)\n",
        "  --search QUERY     explicit query string\n",
        "\n",
        "NOTES:\n",
        "  Broad queries over 20 items are rejected unless --limit is explicit.\n",
        "  dataset=market searches catalog plus cached quotes; it never fetches every price.\n",
        "\n",
        "EXAMPLES:\n",
        "  wfcli market 'name=\"Saryn Prime Set\"'\n",
        "  wfcli market 'saryn prime set'\n",
        "  wfcli market --limit 5 'tag=prime warframe'\n",
        "  wfcli query 'dataset=market lowest_sell<50'\n"
    ].

companion_help() ->
    [
        "USAGE:\n",
        "  wfcli companion <command>\n",
        "\n",
        "PREFERRED STEAM LAUNCH OPTION:\n",
        "  /absolute/path/to/wfcompanion launch -- %command%\n",
        "  Set it in Warframe > Properties > General > Launch Options.\n",
        "\n",
        "COMMANDS:\n",
        "  start              start detached standalone companion\n",
        "  stop               stop companion started by wfcli\n",
        "  restart            restart companion started by wfcli\n",
        "  status             show process, connection, and player-source state\n",
        "  show               enable the overlay\n",
        "  hide               disable the entire overlay\n",
        "  hud show|hide      show or hide the diagnostic info panel\n",
        "  probe              print detected Warframe process state\n",
        "  screenshot [FILE]   capture Warframe\n",
        "  relic-ocr [FILE]    OCR saved image or a Warframe capture\n",
        "  preview list        list registered overlay previews\n",
        "  preview image TYPE|all [PATH] render still previews\n",
        "  preview video TYPE|all [PATH] render animated previews\n",
        "  logs               show incident log path and recent entries\n",
        "  paths              show companion XDG directories\n",
        "  install [--dry-run] edit Steam launch options automatically\n",
        "  uninstall [--dry-run] restore options saved by install\n",
        "\n",
        "NOTES:\n",
        "  Steam launch mode is preferred and exits with Warframe.\n",
        "  hide suppresses automatic contextual overlays until show or restart.\n",
        "  Production starts with the HUD hidden; development starts with it shown.\n",
        "  screenshot defaults to the user cache when FILE is omitted.\n",
        "  Preview output defaults to the ignored previews/ directory.\n",
        "  Close Steam before install or uninstall.\n"
    ].

update_help() ->
    [
        "USAGE:\n",
        "  wfcli update [options]\n",
        "\n",
        "METADATA UPDATES:\n",
        "  --default          refresh standard managed metadata (implicit with no flags)\n",
        "  --all              refresh every managed metadata source\n",
        "  --nodes            refresh solNodes.json\n",
        "  --languages        refresh languages.json\n",
        "  --manifest         refresh ExportManifest.json\n",
        "  --exports          refresh all PublicExport metadata files\n",
        "  --recipes          refresh ExportRecipes.json\n",
        "  --upgrades         refresh ExportUpgrades.json (mods/Arcanes)\n",
        "  --weapons          refresh ExportWeapons.json\n",
        "  --warframes        refresh ExportWarframes.json\n",
        "  --resources        refresh ExportResources.json\n",
        "  --wfcd             refresh versioned WFCD enemy data\n",
        "\n",
        "CACHE REFRESH:\n",
        "  --worldstate       refresh worldstate cache\n",
        "  --trader           refresh trader inventory cache\n",
        "  --cache FILE       override worldstate cache file\n",
        "  --trader-cache FILE override trader inventory cache file\n"
    ].

daemon_help() ->
    [
        "USAGE:\n",
        "  wfcli daemon <command>\n",
        "\n",
        "COMMANDS:\n",
        "  status             show daemon state without starting it\n",
        "  paths              show daemon XDG directories\n",
        "  ensure             start if absent; preserve a running daemon's idle policy\n",
        "  start [OPTIONS]    start or pin wfdaemon until explicit stop\n",
        "  stop               stop wfdaemon release if running\n",
        "  restart [OPTIONS]  stop then start; persistent by default\n",
        "  autostart [status] show systemd user-service state\n",
        "  autostart enable   start now and at user login\n",
        "  autostart disable  disable login startup; leave daemon running\n",
        "  update             hot-load changed BEAMs from local build\n",
        "  update --beam-dir DIR use an explicit build ebin directory\n",
        "  update --release RELEASE apply OTP release upgrade package\n",
        "\n",
        "START OPTIONS:\n",
        "  --idle-shutdown    stop after configured idle timeout\n",
        "  --idle-timeout SEC stop after SEC idle seconds\n",
        "\n",
        "ENV:\n",
        "  WFCLI_DAEMON_NODE   override daemon node (default: wfdaemon@localhost)\n",
        "  WFCLI_DAEMON_SCRIPT override release script path\n",
        "  WFCLI_HOT_BEAM_DIR  override hot-update ebin directory\n",
        "\n",
        "NOTES:\n",
        "  Build daemon release with `rebar3 release`; normal CLI stays `rebar3 escriptize`.\n",
        "  Run `rebar3 compile` before local hot update. Rebuild release to persist after restart.\n"
    ].

visualize_help() ->
    [
        "USAGE:\n",
        "  wfcli visualize --plan FILE [--viz MODE] [--viz-output FILE] [--viz-config] [--config FILE]\n",
        "\n",
        "OPTIONS:\n",
        "  --plan FILE        YAML produced by forma-plan --output (required)\n",
        "  --viz MODE         html | image (default: html)\n",
        "  --viz-output FILE  write visualization to FILE (html/svg)\n",
        "  --viz-config       also visualize the input configuration layout\n",
        "  --config FILE      explicit config file to visualize (defaults to plan's config path)\n",
        "  bare FILE          first bare arg is treated as --plan FILE\n"
    ].

forma_plan_help() ->
    [
        "USAGE:\n",
        "  wfcli forma-plan [options]\n",
        "\n",
        "OPTIONS:\n",
        "  --config FILE        load build definitions (YAML, repeatable)\n",
        "  --allow-omni         allow Omni Forma (Umbral not covered)\n",
        "  --allow-umbral-forma allow Umbral Forma (off by default)\n",
        "  --prefer-omni        bias toward Omni where flexible\n",
        "  --max-forma N        cap total Forma expenditure\n",
        "  --show-alt           show alternate near-optimal plans\n",
        "  --output FILE        write plan YAML (default: auto-named .plan.yml)\n",
        "  --visualize          render plan (html by default) and open it\n",
        "  --viz MODE           choose viz mode: html | image\n",
        "  --viz-output FILE    write visualization to FILE (html/svg)\n",
        "  --viz-config         also visualize the input config layout\n",
        "\n",
        "NOTES:\n",
        "  configs define item capacity/base polarities, aura/stance/exilus, and builds with mod polarity/cost.\n"
    ].
