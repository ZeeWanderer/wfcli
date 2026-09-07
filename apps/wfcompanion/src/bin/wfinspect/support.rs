use serde::Serialize;
use serde_json::json;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use wfcompanion::game_observer;
pub(super) const BROKEN_PIPE: &str = "__wfinspect_broken_pipe__";

pub(super) enum ScriptAction {
    Info,
    Normalize,
    Disassemble,
    Decompile,
}
pub(super) enum ScriptInput {
    Stdin,
    File(PathBuf),
    Cache {
        directory: PathBuf,
        package: String,
        resource: String,
    },
}

pub(super) fn doctor() -> Result<(), String> {
    let game = match game_observer::current_process_identity() {
        Ok(identity) => json!({
            "status": if identity.is_some() { "running" } else { "stopped" },
            "adapter": game_observer::adapter::support(identity.as_ref()),
            "identity": identity,
        }),
        Err(error) => json!({"status": "error", "error": error}),
    };
    print_json(&json!({
        "wfinspect": {"version": env!("CARGO_PKG_VERSION")},
        "tools": {
            "luau_decompiler": wfcompanion::inspect::luau::decompiler_status(),
            "oodle_decoder": wfcompanion::inspect::cache::oodle_decoder_status(),
        },
        "game": game,
    }))
}

pub(super) fn script(
    action: ScriptAction,
    input: ScriptInput,
    adapter: Option<String>,
) -> Result<(), String> {
    let (bytecode, source) = read_script(input)?;
    let adapter = match adapter {
        Some(adapter) => adapter,
        None => game_observer::current_process_identity()?
            .map(|identity| identity.executable.sha256)
            .ok_or_else(|| "--adapter is required when Warframe is not running".to_owned())?,
    };
    match action {
        ScriptAction::Info => print_json(&json!({
            "source": source,
            "script": wfcompanion::inspect::luau::info(&bytecode, &adapter)?,
        })),
        ScriptAction::Normalize => {
            write_bytes(&wfcompanion::inspect::luau::normalize(&bytecode, &adapter)?)
        }
        ScriptAction::Disassemble => write_stdout(&wfcompanion::inspect::luau::disassemble(
            &bytecode, &adapter,
        )?),
        ScriptAction::Decompile => {
            write_stdout(&wfcompanion::inspect::luau::decompile(&bytecode, &adapter)?)
        }
    }
}

pub(super) fn write_bytes(bytes: &[u8]) -> Result<(), String> {
    match io::stdout().lock().write_all(bytes) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => Err(BROKEN_PIPE.to_owned()),
        Err(error) => Err(format!("could not write standard output: {error}")),
    }
}

pub(super) fn read_script(input: ScriptInput) -> Result<(Vec<u8>, serde_json::Value), String> {
    match input {
        ScriptInput::Stdin => {
            let mut bytes = Vec::new();
            io::stdin()
                .read_to_end(&mut bytes)
                .map_err(|error| format!("could not read standard input: {error}"))?;
            Ok((bytes, json!({"kind": "stdin"})))
        }
        ScriptInput::File(path) => {
            let bytes = std::fs::read(&path)
                .map_err(|error| format!("could not read {}: {error}", path.display()))?;
            Ok((bytes, json!({"kind": "file", "path": path})))
        }
        ScriptInput::Cache {
            directory,
            package,
            resource,
        } => {
            let body = wfcompanion::inspect::cache::read_resource_split(
                &directory, &package, &resource, 'B',
            )?;
            Ok((
                body.data,
                json!({
                    "kind": "cache",
                    "directory": directory,
                    "package": package,
                    "path": body.path,
                    "split": body.split,
                }),
            ))
        }
    }
}

pub(super) fn game_pid() -> Result<u32, String> {
    game_observer::find_warframe()
        .pid()
        .ok_or_else(|| "Warframe is not running".to_owned())
}

pub(super) fn process() -> Result<(), String> {
    let state = game_observer::find_warframe();
    let identity = game_observer::current_process_identity()?;
    print_json(&json!({"game": state, "identity": identity}))
}

pub(super) fn adapter() -> Result<(), String> {
    let pid = game_pid()?;
    let identity = game_observer::identify_process(pid)?;
    let scaleform = game_observer::ui::bounded_probe_for_identity(pid, &identity);
    let metadata = game_observer::metadata::capture_for_identity(pid, identity.clone())
        .map(|value| json!({"status": "available", "value": value}))
        .unwrap_or_else(|reason| json!({"status": "unavailable", "reason": reason}));
    print_json(&json!({
        "identity": identity,
        "adapter": game_observer::adapter::support(Some(&identity)),
        "probes": {
            "game_metadata": metadata,
            "scaleform": scaleform,
        },
    }))
}

pub(super) fn metadata(output: Option<PathBuf>) -> Result<(), String> {
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
        write_stdout(&format!("{rendered}\n"))?;
    }
    Ok(())
}

pub(super) fn cache_paths(
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

pub(super) fn cache_extract(
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

pub(super) fn print_json(value: &impl serde::Serialize) -> Result<(), String> {
    let rendered = serde_json::to_string_pretty(value)
        .map_err(|error| format!("could not encode report: {error}"))?;
    write_stdout(&format!("{rendered}\n"))
}

pub(super) fn print_ndjson<T: Serialize>(
    stream: &'static str,
    record: &'static str,
    data: &T,
) -> Result<(), String> {
    #[derive(Serialize)]
    struct Envelope<'a, T> {
        schema: &'static str,
        schema_version: u8,
        emitted_at_unix_ms: u128,
        stream: &'static str,
        record: &'static str,
        data: &'a T,
    }

    let mut line = serde_json::to_vec(&Envelope {
        schema: "wfinspect.stream",
        schema_version: 1,
        emitted_at_unix_ms: wfcompanion::inspect::unix_time_ms(),
        stream,
        record,
        data,
    })
    .map_err(|error| format!("could not encode stream record: {error}"))?;
    line.push(b'\n');
    let mut output = io::stdout().lock();
    match output.write_all(&line).and_then(|()| output.flush()) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => Err(BROKEN_PIPE.to_owned()),
        Err(error) => Err(format!("could not write output: {error}")),
    }
}

pub(super) fn write_stdout(text: &str) -> Result<(), String> {
    match io::stdout().lock().write_all(text.as_bytes()) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::BrokenPipe => Ok(()),
        Err(error) => Err(format!("could not write output: {error}")),
    }
}
