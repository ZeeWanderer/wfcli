use clap::{CommandFactory, Parser, Subcommand};
use std::process::ExitCode;
use wfcompanion::inspect;

#[path = "wfinspect/args.rs"]
mod args;
#[path = "wfinspect/files.rs"]
mod files;
#[path = "wfinspect/game.rs"]
mod game;
#[path = "wfinspect/support.rs"]
mod support;
use support::*;

/// Read-only Warframe research: live memory, captures, resources and runtime events.
#[derive(Parser)]
#[command(
    name = "wfinspect",
    version,
    propagate_version = true,
    arg_required_else_help = true
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Report game adapters and external tool availability.
    Doctor,
    /// Inspect game memory, events and resource files.
    #[command(subcommand)]
    Game(game::Game),
    /// Inspect the daemon handshake, datasets and subscriptions.
    #[command(subcommand)]
    Daemon(Daemon),
    /// Generate shell completion; redirect into your shell's completion directory.
    Completion { shell: clap_complete::Shell },
}

#[derive(Subcommand)]
enum Daemon {
    /// Connect and report negotiated interfaces.
    Handshake,
    /// Fetch a dataset; rejected requests exit nonzero and retain the server reply.
    Get { dataset: String },
    /// Stream dataset revision notifications as NDJSON.
    Subscribe {
        dataset: String,
        #[command(flatten)]
        watch: args::Watch,
    },
}

fn main() -> ExitCode {
    let mut arguments = std::env::args_os().collect::<Vec<_>>();
    if arguments.last().is_some_and(|arg| arg == "help") && !arguments.iter().any(|arg| arg == "--")
    {
        *arguments.last_mut().unwrap() = "--help".into();
    }
    let cli = Cli::parse_from(arguments);
    match run(cli.command) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) if error == BROKEN_PIPE => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("wfinspect: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run(command: Command) -> Result<(), String> {
    match command {
        Command::Doctor => doctor(),
        Command::Game(command) => command.run(),
        Command::Completion { shell } => {
            let mut script = Vec::new();
            let invoked = std::env::args_os().next().map(std::path::PathBuf::from);
            let name = invoked
                .as_deref()
                .and_then(std::path::Path::file_name)
                .and_then(|name| name.to_str())
                .unwrap_or("wfinspect");
            clap_complete::generate(shell, &mut Cli::command(), name, &mut script);
            write_bytes(&script)
        }
        Command::Daemon(Daemon::Handshake) => print_json(&inspect::daemon::handshake()?),
        Command::Daemon(Daemon::Get { dataset }) => {
            let report = inspect::daemon::dataset(&dataset)?;
            print_json(&report)?;
            if report
                .response
                .get("ok")
                .and_then(serde_json::Value::as_bool)
                != Some(true)
            {
                return Err("daemon rejected dataset request (see response)".into());
            }
            Ok(())
        }
        Command::Daemon(Daemon::Subscribe { dataset, watch }) => {
            let summary = inspect::daemon::subscribe_stream(
                &dataset,
                watch.seconds,
                watch.limit,
                |record| print_ndjson("daemon.subscription", "event", record),
            )?;
            print_ndjson("daemon.subscription", "summary", &summary)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_tree_and_leaf_help_are_consistent() {
        Cli::command().debug_assert();
        for command in [
            vec!["game", "cache", "paths", "/nonexistent", "Font", "--help"],
            vec!["game", "ui", "objects", "--help"],
            vec!["game", "memory", "path", "--help"],
        ] {
            let error = Cli::try_parse_from(std::iter::once("wfinspect").chain(command))
                .err()
                .unwrap();
            assert_eq!(error.kind(), clap::error::ErrorKind::DisplayHelp);
        }
    }

    #[test]
    fn literals_and_mistyped_flags_remain_distinct() {
        assert!(
            Cli::try_parse_from(["wfinspect", "game", "ui", "find", "--mistyped-option"]).is_err()
        );
        assert!(
            Cli::try_parse_from([
                "wfinspect",
                "game",
                "ui",
                "find",
                "--capture",
                "capture",
                "--",
                "help"
            ])
            .is_ok()
        );
        assert!(Cli::try_parse_from(["wfinspect", "game", "memory", "scan", "a\u{20ac}"]).is_err());
        assert!(Cli::try_parse_from(["wfinspect", "game", "adapter", "--list"]).is_ok());
        assert!(
            Cli::try_parse_from([
                "wfinspect",
                "game",
                "script",
                "info",
                "-",
                "--adapter",
                "build"
            ])
            .is_ok()
        );
    }
}
