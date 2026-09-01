use std::path::PathBuf;
use std::process::ExitCode;

use serde_json::json;
use wfcompanion::game_observer;

const HELP: &str = r#"wfinspect - explicit wfcli runtime diagnostics

Usage:
  wfinspect <area> <command>

Areas:
  game  inspect the local Warframe process

Run `wfinspect <area> help` for area commands.
"#;

const GAME_HELP: &str = r#"Usage:
  wfinspect game process
  wfinspect game metadata [--output FILE]
  wfinspect game cache <command>
  wfinspect game ui <command>

Commands:
  process   print detected process and executable identity
  metadata  capture executable-keyed game metadata used by wfdaemon
  cache     inspect installed Evolution Engine cache packages
  ui        inspect loaded Scaleform UI state
"#;

const CACHE_HELP: &str = r#"Usage:
  wfinspect game cache paths CACHE_DIR PACKAGE [SUBSTRING]
  wfinspect game cache extract CACHE_DIR PACKAGE INTERNAL_PATH OUTPUT_PREFIX
  wfinspect game cache find CACHE_DIR PACKAGE TEXT

Commands:
  paths    list package paths without decompressing resources
  extract  extract matching H/B/F resources to OUTPUT_PREFIX.<split>.raw
  find     search decompressed package resources for exact bytes

Environment:
  WFINSPECT_OODLE_LIBRARY  licensed liboo2corelinux64.so path used when needed
"#;

const UI_HELP: &str = r#"Usage:
  wfinspect game ui state
  wfinspect game ui relic
  wfinspect game ui movies
  wfinspect game ui find TERM...
  wfinspect game ui refs ADDRESS [LENGTH]
  wfinspect game ui path ROOT TARGET [LENGTH]
  wfinspect game ui capture DIRECTORY [TERM...]

Commands:
  state    read the bounded Scaleform movie registry
  relic    inspect active relic-selection or reward UI state
  movies   explicitly scan and print loaded Scaleform movie records
  find     find exact UTF-8/UTF-16 UI text and its direct references
  refs     find pointers into an address range; LENGTH defaults to 512 bytes
  path     trace a bounded pointer path from ROOT to TARGET
  capture  save a bounded Scaleform object graph for offline inspection
"#;

#[derive(Debug, PartialEq)]
enum Command {
    Help(&'static str),
    GameProcess,
    GameMetadata(Option<PathBuf>),
    GameCachePaths(PathBuf, String, Option<String>),
    GameCacheExtract(PathBuf, String, String, PathBuf),
    GameCacheFind(PathBuf, String, String),
    GameUiState,
    GameUiRelic,
    GameUiMovies,
    GameUiFind(Vec<String>),
    GameUiRefs(u64, u64),
    GameUiPath(u64, u64, u64),
    GameUiCapture(PathBuf, Vec<String>),
}

fn main() -> ExitCode {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    let result = parse(&args).and_then(run);
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("wfinspect: {error}");
            ExitCode::FAILURE
        }
    }
}

fn parse(args: &[String]) -> Result<Command, String> {
    let args = args.iter().map(String::as_str).collect::<Vec<_>>();
    match args.as_slice() {
        [] | ["help" | "--help" | "-h"] => Ok(Command::Help(HELP)),
        ["game"] | ["game", "help" | "--help" | "-h"] => Ok(Command::Help(GAME_HELP)),
        ["game", "process"] => Ok(Command::GameProcess),
        ["game", "process", "help" | "--help" | "-h"] => Ok(Command::Help(GAME_HELP)),
        ["game", "metadata"] => Ok(Command::GameMetadata(None)),
        ["game", "metadata", "--output", output] => {
            Ok(Command::GameMetadata(Some(PathBuf::from(output))))
        }
        ["game", "metadata", "help" | "--help" | "-h"] => Ok(Command::Help(GAME_HELP)),
        ["game", "cache"] | ["game", "cache", "help" | "--help" | "-h"] => {
            Ok(Command::Help(CACHE_HELP))
        }
        ["game", "cache", "paths", "help" | "--help" | "-h"] => Ok(Command::Help(CACHE_HELP)),
        ["game", "cache", "paths", cache, package] => Ok(Command::GameCachePaths(
            PathBuf::from(cache),
            (*package).to_owned(),
            None,
        )),
        ["game", "cache", "paths", cache, package, substring] => Ok(Command::GameCachePaths(
            PathBuf::from(cache),
            (*package).to_owned(),
            Some((*substring).to_owned()),
        )),
        ["game", "cache", "extract", "help" | "--help" | "-h"] => Ok(Command::Help(CACHE_HELP)),
        ["game", "cache", "extract", cache, package, resource, output] => {
            Ok(Command::GameCacheExtract(
                PathBuf::from(cache),
                (*package).to_owned(),
                (*resource).to_owned(),
                PathBuf::from(output),
            ))
        }
        ["game", "cache", "find", "help" | "--help" | "-h"] => Ok(Command::Help(CACHE_HELP)),
        ["game", "cache", "find", cache, package, text] => Ok(Command::GameCacheFind(
            PathBuf::from(cache),
            (*package).to_owned(),
            (*text).to_owned(),
        )),
        ["game", "ui"] | ["game", "ui", "help" | "--help" | "-h"] => Ok(Command::Help(UI_HELP)),
        ["game", "ui", "state"] => Ok(Command::GameUiState),
        ["game", "ui", "state", "help" | "--help" | "-h"] => Ok(Command::Help(UI_HELP)),
        ["game", "ui", "relic"] => Ok(Command::GameUiRelic),
        ["game", "ui", "relic", "help" | "--help" | "-h"] => Ok(Command::Help(UI_HELP)),
        ["game", "ui", "movies"] => Ok(Command::GameUiMovies),
        ["game", "ui", "movies", "help" | "--help" | "-h"] => Ok(Command::Help(UI_HELP)),
        ["game", "ui", "find", "help" | "--help" | "-h"] => Ok(Command::Help(UI_HELP)),
        ["game", "ui", "find", terms @ ..] if !terms.is_empty() => Ok(Command::GameUiFind(
            terms.iter().map(|term| (*term).to_owned()).collect(),
        )),
        ["game", "ui", "find"] => Err("game ui find requires at least one term".to_owned()),
        ["game", "ui", "refs", "help" | "--help" | "-h"] => Ok(Command::Help(UI_HELP)),
        ["game", "ui", "refs", address] => {
            let start = parse_number(address)?;
            Ok(Command::GameUiRefs(start, 512))
        }
        ["game", "ui", "refs", address, length] => Ok(Command::GameUiRefs(
            parse_number(address)?,
            parse_number(length)?,
        )),
        ["game", "ui", "refs"] => Err("game ui refs requires an address".to_owned()),
        ["game", "ui", "path", "help" | "--help" | "-h"] => Ok(Command::Help(UI_HELP)),
        ["game", "ui", "path", root, target] => Ok(Command::GameUiPath(
            parse_number(root)?,
            parse_number(target)?,
            512,
        )),
        ["game", "ui", "path", root, target, length] => Ok(Command::GameUiPath(
            parse_number(root)?,
            parse_number(target)?,
            parse_number(length)?,
        )),
        ["game", "ui", "path", ..] => {
            Err("game ui path requires a root and target address".to_owned())
        }
        ["game", "ui", "capture", "help" | "--help" | "-h"] => Ok(Command::Help(UI_HELP)),
        ["game", "ui", "capture", directory, terms @ ..] => Ok(Command::GameUiCapture(
            PathBuf::from(directory),
            terms.iter().map(|term| (*term).to_owned()).collect(),
        )),
        ["game", "ui", "capture"] => Err("game ui capture requires an output directory".to_owned()),
        _ => Err(format!("unknown command: {}", args.join(" "))),
    }
}

fn run(command: Command) -> Result<(), String> {
    match command {
        Command::Help(help) => {
            print!("{help}");
            Ok(())
        }
        Command::GameProcess => process(),
        Command::GameMetadata(output) => metadata(output),
        Command::GameCachePaths(cache, package, substring) => {
            cache_paths(cache, package, substring)
        }
        Command::GameCacheExtract(cache, package, resource, output) => {
            cache_extract(cache, package, resource, output)
        }
        Command::GameCacheFind(cache, package, text) => cache_find(cache, package, text),
        Command::GameUiState => state(),
        Command::GameUiRelic => relic(),
        Command::GameUiMovies => movies(),
        Command::GameUiFind(terms) => find(terms),
        Command::GameUiRefs(start, length) => refs(start, length),
        Command::GameUiPath(root, target, length) => path(root, target, length),
        Command::GameUiCapture(directory, terms) => capture(directory, terms),
    }
}

fn parse_number(value: &str) -> Result<u64, String> {
    if let Some(hex) = value.strip_prefix("0x") {
        u64::from_str_radix(hex, 16).map_err(|_| format!("invalid number: {value}"))
    } else {
        value
            .parse()
            .map_err(|_| format!("invalid number: {value}"))
    }
}

fn game_pid() -> Result<u32, String> {
    game_observer::find_warframe()
        .pid()
        .ok_or_else(|| "Warframe is not running".to_owned())
}

fn state() -> Result<(), String> {
    let pid = game_pid()?;
    print_json(&game_observer::ui::bounded_probe(pid))
}

fn relic() -> Result<(), String> {
    let pid = game_pid()?;
    let selection = game_observer::ui::probe_relic_selection(pid)
        .map(|value| json!({"status": "available", "value": value}))
        .unwrap_or_else(|error| json!({"status": "unavailable", "error": error}));
    let rewards = game_observer::ui::probe_relic_rewards(pid)
        .map(|value| json!({"status": "available", "value": value}))
        .unwrap_or_else(|error| json!({"status": "unavailable", "error": error}));
    print_json(&json!({"pid": pid, "selection": selection, "rewards": rewards}))
}

fn process() -> Result<(), String> {
    let state = game_observer::find_warframe();
    let identity = game_observer::current_process_identity()?;
    print_json(&json!({"game": state, "identity": identity}))
}

fn metadata(output: Option<PathBuf>) -> Result<(), String> {
    let captured = game_observer::metadata::capture(game_pid()?)?;
    let rendered = serde_json::to_string_pretty(&captured)
        .map_err(|error| format!("could not encode report: {error}"))?;
    if let Some(path) = output {
        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("could not create {}: {error}", parent.display()))?;
        }
        std::fs::write(&path, format!("{rendered}\n"))
            .map_err(|error| format!("could not write {}: {error}", path.display()))?;
    } else {
        println!("{rendered}");
    }
    Ok(())
}

fn cache_paths(
    cache_dir: PathBuf,
    package: String,
    substring: Option<String>,
) -> Result<(), String> {
    let mut paths = wfcompanion::inspect::cache::paths(&cache_dir, &package)?;
    if let Some(substring) = substring {
        paths.retain(|entry| entry.path.contains(&substring));
    }
    print_json(&json!({
        "cache_dir": cache_dir,
        "package": package,
        "paths": paths,
    }))
}

fn cache_extract(
    cache_dir: PathBuf,
    package: String,
    resource: String,
    output: PathBuf,
) -> Result<(), String> {
    let extracted = wfcompanion::inspect::cache::extract(&cache_dir, &package, &resource, &output)?;
    print_json(&json!({
        "cache_dir": cache_dir,
        "package": package,
        "resources": extracted,
    }))
}

fn cache_find(cache_dir: PathBuf, package: String, text: String) -> Result<(), String> {
    let matches = wfcompanion::inspect::cache::find(&cache_dir, &package, text.as_bytes())?;
    print_json(&json!({
        "cache_dir": cache_dir,
        "package": package,
        "matches": matches,
    }))
}

fn movies() -> Result<(), String> {
    let state = game_observer::find_warframe();
    let pid = state
        .pid()
        .ok_or_else(|| "Warframe is not running".to_owned())?;
    let identity = game_observer::identify_process(pid)?;
    let scan = game_observer::ui::explicit_scan(pid)?;
    print_json(&json!({"identity": identity, "ui": scan}))
}

fn find(terms: Vec<String>) -> Result<(), String> {
    let state = game_observer::find_warframe();
    let pid = state
        .pid()
        .ok_or_else(|| "Warframe is not running".to_owned())?;
    let identity = game_observer::identify_process(pid)?;
    let text = game_observer::ui::explicit_text_scan(pid, &terms)?;
    print_json(&json!({"identity": identity, "text": text}))
}

fn refs(start: u64, length: u64) -> Result<(), String> {
    let pid = game_pid()?;
    let end = start
        .checked_add(length)
        .ok_or_else(|| "pointer target range overflows".to_owned())?;
    print_json(&game_observer::ui::explicit_pointer_scan(pid, start, end)?)
}

fn path(root: u64, target: u64, length: u64) -> Result<(), String> {
    let pid = game_pid()?;
    let end = target
        .checked_add(length)
        .ok_or_else(|| "pointer target range overflows".to_owned())?;
    print_json(&game_observer::ui::explicit_pointer_path(
        pid, root, target, end,
    )?)
}

fn capture(directory: PathBuf, terms: Vec<String>) -> Result<(), String> {
    let state = game_observer::find_warframe();
    let pid = state
        .pid()
        .ok_or_else(|| "Warframe is not running".to_owned())?;
    let identity = game_observer::identify_process(pid)?;
    let evidence = game_observer::ui::capture_evidence(pid, &directory, &terms)?;
    print_json(&json!({"identity": identity, "evidence": evidence}))
}

fn print_json(value: &impl serde::Serialize) -> Result<(), String> {
    println!(
        "{}",
        serde_json::to_string_pretty(value)
            .map_err(|error| format!("could not encode report: {error}"))?
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn parses_namespaced_commands() {
        assert_eq!(parse(&args(&["game", "process"])), Ok(Command::GameProcess));
        assert_eq!(
            parse(&args(&["game", "metadata"])),
            Ok(Command::GameMetadata(None))
        );
        assert_eq!(
            parse(&args(&[
                "game",
                "metadata",
                "--output",
                "/tmp/metadata.json"
            ])),
            Ok(Command::GameMetadata(Some(PathBuf::from(
                "/tmp/metadata.json"
            ))))
        );
        assert_eq!(
            parse(&args(&[
                "game",
                "cache",
                "paths",
                "/game/Cache.Windows",
                "Font",
                "Conquest"
            ])),
            Ok(Command::GameCachePaths(
                PathBuf::from("/game/Cache.Windows"),
                "Font".to_owned(),
                Some("Conquest".to_owned()),
            ))
        );
        assert_eq!(
            parse(&args(&[
                "game",
                "cache",
                "extract",
                "/game/Cache.Windows",
                "Font",
                "/Lotus/Scripts/Test.lua",
                "/tmp/test"
            ])),
            Ok(Command::GameCacheExtract(
                PathBuf::from("/game/Cache.Windows"),
                "Font".to_owned(),
                "/Lotus/Scripts/Test.lua".to_owned(),
                PathBuf::from("/tmp/test"),
            ))
        );
        assert_eq!(
            parse(&args(&["game", "ui", "movies"])),
            Ok(Command::GameUiMovies)
        );
        assert_eq!(
            parse(&args(&["game", "ui", "state"])),
            Ok(Command::GameUiState)
        );
        assert_eq!(
            parse(&args(&["game", "ui", "relic"])),
            Ok(Command::GameUiRelic)
        );
        assert_eq!(
            parse(&args(&["game", "ui", "find", "RESOURCE DRONES"])),
            Ok(Command::GameUiFind(vec!["RESOURCE DRONES".to_owned()]))
        );
        assert_eq!(
            parse(&args(&[
                "game",
                "ui",
                "find",
                "NEO ERA",
                "EQUIP FOR MISSION"
            ])),
            Ok(Command::GameUiFind(vec![
                "NEO ERA".to_owned(),
                "EQUIP FOR MISSION".to_owned(),
            ]))
        );
        assert!(parse(&args(&["game", "ui", "find"])).is_err());
        assert_eq!(
            parse(&args(&["game", "ui", "refs", "0x1000"])),
            Ok(Command::GameUiRefs(0x1000, 512))
        );
        assert_eq!(
            parse(&args(&["game", "ui", "refs", "4096", "128"])),
            Ok(Command::GameUiRefs(4096, 128))
        );
        assert_eq!(
            parse(&args(&["game", "ui", "path", "0x1000", "0x2000"])),
            Ok(Command::GameUiPath(0x1000, 0x2000, 512))
        );
        assert_eq!(
            parse(&args(&["game", "ui", "capture", "/tmp/evidence"])),
            Ok(Command::GameUiCapture(
                PathBuf::from("/tmp/evidence"),
                Vec::new(),
            ))
        );
        assert_eq!(
            parse(&args(&[
                "game",
                "ui",
                "capture",
                "/tmp/evidence",
                "RESOURCE DRONES",
            ])),
            Ok(Command::GameUiCapture(
                PathBuf::from("/tmp/evidence"),
                vec!["RESOURCE DRONES".to_owned()],
            ))
        );
    }

    #[test]
    fn help_tracks_command_scope() {
        assert_eq!(parse(&args(&[])), Ok(Command::Help(HELP)));
        assert_eq!(
            parse(&args(&["game", "help"])),
            Ok(Command::Help(GAME_HELP))
        );
        assert_eq!(
            parse(&args(&["game", "ui", "--help"])),
            Ok(Command::Help(UI_HELP))
        );
        assert_eq!(
            parse(&args(&["game", "cache", "--help"])),
            Ok(Command::Help(CACHE_HELP))
        );
    }
}
