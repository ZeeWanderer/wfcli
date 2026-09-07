use super::{args, files, support::*};
use clap::Subcommand;
use serde_json::json;
use std::path::PathBuf;
use wfcompanion::{game_observer, inspect};

#[derive(Subcommand)]
pub enum Game {
    /// Show the running process and executable identity.
    Process,
    /// Probe the active adapter, or list supported builds offline.
    Adapter {
        #[arg(long)]
        list: bool,
    },
    /// Capture game item metadata.
    Metadata {
        #[arg(long)]
        output: Option<PathBuf>,
    },
    /// Read, search, follow pointers and capture selected memory.
    #[command(subcommand)]
    Memory(Memory),
    /// Enumerate movies and text objects; run typed UI queries.
    #[command(subcommand)]
    Ui(Ui),
    /// Inspect retained API payloads and their changes.
    #[command(subcommand)]
    Gep(Gep),
    /// Subscribe to game debug events without competing with companion.
    #[command(subcommand)]
    Events(Events),
    /// Discover, extract and search game cache resources.
    #[command(subcommand)]
    Cache(files::Cache),
    /// Inspect or decompile Warframe Luau bytecode.
    #[command(subcommand)]
    Script(files::Script),
    /// Read build-keyed Ghidra reports.
    #[command(subcommand)]
    Report(files::Report),
}

#[derive(Subcommand)]
pub enum Memory {
    /// List mappings and available captured ranges.
    Maps {
        #[command(flatten)]
        source: args::Source,
    },
    /// Write a bounded memory range as raw bytes on stdout.
    Read {
        #[command(flatten)]
        source: args::Source,
        #[arg(value_parser = args::number)]
        address: u64,
        length: usize,
    },
    /// Find exact hexadecimal bytes in selected mappings.
    Scan {
        #[command(flatten)]
        source: args::Source,
        #[command(flatten)]
        selection: args::Selection,
        #[arg(value_parser = args::hex)]
        pattern: args::Hex,
        #[arg(long, default_value_t = 4096)]
        limit: usize,
        #[arg(long, default_value_t = 1073741824)]
        max_bytes: u64,
    },
    /// Find literal UTF-8 text; use -- before terms beginning with a dash.
    Find {
        #[command(flatten)]
        source: args::Source,
        #[command(flatten)]
        selection: args::Selection,
        text: String,
        #[arg(long, default_value_t = 4096)]
        limit: usize,
        #[arg(long, default_value_t = 1073741824)]
        max_bytes: u64,
    },
    /// Find stored pointers into ADDRESS:LENGTH.
    Refs {
        #[command(flatten)]
        source: args::Source,
        #[command(flatten)]
        selection: args::Selection,
        #[arg(value_parser = args::number)]
        address: u64,
        #[arg(long, default_value_t = 1)]
        length: u64,
        #[arg(long, default_value_t = 4096)]
        limit: usize,
        #[arg(long, default_value_t = 1073741824)]
        max_bytes: u64,
    },
    /// Find a pointer path, with explicit traversal and coverage limits.
    Path {
        #[command(flatten)]
        source: args::Source,
        #[command(flatten)]
        walk: args::Walk,
        #[arg(value_parser = args::number)]
        root: u64,
        #[arg(value_parser = args::number)]
        target: u64,
        #[arg(long, default_value_t = 1)]
        length: u64,
    },
    /// Capture selected roots/ranges into a new private evidence directory.
    Capture {
        #[command(flatten)]
        source: args::Source,
        #[command(flatten)]
        walk: args::Walk,
        directory: PathBuf,
        #[arg(long = "root", value_parser = args::number)]
        roots: Vec<u64>,
    },
}

#[derive(Subcommand)]
pub enum Ui {
    /// Query the current movie registry using the build adapter.
    State {
        #[command(flatten)]
        source: args::Source,
    },
    /// Discover movies from available bytes, including saved captures.
    Movies {
        #[command(flatten)]
        source: args::Source,
    },
    /// Enumerate known text objects, instance names and current values.
    Objects {
        #[command(flatten)]
        source: args::Source,
        /// Movie path substring; empty selects every discovered movie.
        #[arg(default_value = "")]
        movie: String,
        #[arg(long, default_value_t = 1024)]
        text_bytes: usize,
        #[arg(long, default_value_t = 2048)]
        limit: usize,
    },
    /// Find text and its display-object references in available memory.
    Find {
        #[command(flatten)]
        source: args::Source,
        #[arg(required = true)]
        terms: Vec<String>,
    },
    /// Resolve relic selection/reward data from known UI objects.
    Relic {
        #[command(flatten)]
        source: args::Source,
    },
    /// Capture movies and their reachable UI objects from the running game.
    Capture {
        directory: PathBuf,
        terms: Vec<String>,
    },
    /// Show recorded acquisition metadata and replay typed relic probes.
    Replay { directory: PathBuf },
}

#[derive(Subcommand)]
pub enum Gep {
    /// Report retained responses; optionally save exact payload bytes.
    State {
        #[arg(long)]
        payload_dir: Option<PathBuf>,
    },
    /// Stream response changes, with optional private payload files.
    Watch {
        #[command(flatten)]
        watch: args::Watch,
        #[arg(long)]
        payload_dir: Option<PathBuf>,
    },
}

#[derive(Subcommand)]
pub enum Events {
    /// Stream debug records from the single per-Proton-prefix owner.
    Watch {
        #[command(flatten)]
        watch: args::Watch,
    },
}

impl Game {
    pub fn run(self) -> Result<(), String> {
        match self {
            Self::Process => process(),
            Self::Adapter { list: true } => print_json(&game_observer::adapter::list()),
            Self::Adapter { list: false } => adapter(),
            Self::Metadata { output } => metadata(output),
            Self::Memory(command) => command.run(),
            Self::Ui(command) => command.run(),
            Self::Cache(command) => command.run(),
            Self::Script(command) => command.run(),
            Self::Report(command) => command.run(),
            Self::Gep(Gep::State { payload_dir }) => print_json(
                &inspect::gep::state_with_payloads(game_pid()?, payload_dir.as_deref())?,
            ),
            Self::Gep(Gep::Watch { watch, payload_dir }) => {
                let pid = game_pid()?;
                print_ndjson("game.gep", "start", &game_observer::identify_process(pid)?)?;
                let summary = inspect::gep::watch_payloads(
                    pid,
                    watch.seconds,
                    watch.limit,
                    payload_dir.as_deref(),
                    |event| print_ndjson("game.gep", "payload", event),
                )?;
                print_ndjson("game.gep", "summary", &summary)
            }
            Self::Events(Events::Watch { watch }) => {
                print_ndjson(
                    "game.events",
                    "start",
                    &game_observer::identify_process(game_pid()?)?,
                )?;
                let summary = inspect::events::watch_stream(watch.seconds, watch.limit, |event| {
                    print_ndjson("game.events", "event", event)
                })?;
                print_ndjson("game.events", "summary", &summary)?;
                if let Some(reason) = summary.stopped {
                    return Err(reason);
                }
                Ok(())
            }
        }
    }
}

impl Memory {
    fn run(self) -> Result<(), String> {
        use inspect::memory;
        match self {
            Self::Maps { source } => print_json(&memory::maps(source.open()?)?),
            Self::Read {
                source,
                address,
                length,
            } => write_bytes(&memory::read(source.open()?, address, length)?),
            Self::Scan {
                source,
                selection,
                pattern,
                limit,
                max_bytes,
            } => print_json(&memory::scan_with(
                source.open()?,
                &pattern.0,
                &selection.query(),
                limit,
                max_bytes,
            )?),
            Self::Find {
                source,
                selection,
                text,
                limit,
                max_bytes,
            } => print_json(&memory::scan_with(
                source.open()?,
                text.as_bytes(),
                &selection.query(),
                limit,
                max_bytes,
            )?),
            Self::Refs {
                source,
                selection,
                address,
                length,
                limit,
                max_bytes,
            } => print_json(&memory::references(
                source.open()?,
                args::target(address, length)?,
                &selection.query(),
                limit,
                max_bytes,
            )?),
            Self::Path {
                source,
                walk,
                root,
                target,
                length,
            } => print_json(&memory::path(
                source.open()?,
                root,
                Some(args::target(target, length)?),
                &walk.query(),
            )?),
            Self::Capture {
                source,
                walk,
                directory,
                roots,
            } => print_json(&memory::capture(
                source.open()?,
                &directory,
                &roots,
                &walk.query(),
            )?),
        }
    }
}

impl Ui {
    fn run(self) -> Result<(), String> {
        use inspect::memory;
        match self {
            Self::State { source } => print_json(&memory::ui_state(source.open()?)?),
            Self::Movies { source } => print_json(&memory::ui_movies(source.open()?)?),
            Self::Objects {
                source,
                movie,
                text_bytes,
                limit,
            } => print_json(&memory::ui_objects(
                source.open()?,
                &movie,
                text_bytes,
                limit,
            )?),
            Self::Find { source, terms } => print_json(&memory::ui_find(source.open()?, &terms)?),
            Self::Relic { source } => print_json(&memory::ui_relic(source.open()?)?),
            Self::Capture { directory, terms } => {
                let evidence =
                    game_observer::ui::capture_evidence(game_pid()?, &directory, &terms)?;
                print_json(&json!({"evidence": evidence}))
            }
            Self::Replay { directory } => {
                print_json(&game_observer::ui::replay_evidence(&directory)?)
            }
        }
    }
}
