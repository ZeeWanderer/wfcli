mod assets;
mod capture;
mod daemon;
mod debug_output;
mod desktop;
mod external;
mod focus;
mod incident;
mod inventory;
mod observer;
mod overlay;
mod painter;
mod preview;
mod relic;
mod shortcut;
mod ui_layout;

use std::path::PathBuf;
use std::process::{Command as ProcessCommand, ExitCode};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::Instant;

use serde_json::Value;

const HELP: &str = r#"wfcompanion - Linux/Proton Warframe observer and overlay

Usage:
  wfcompanion
  wfcompanion launch -- COMMAND [ARG...]
  wfcompanion probe
  wfcompanion screenshot [--target active|screen] OUTPUT.png
  wfcompanion relic-ocr [--target active|screen] [IMAGE]
  wfcompanion preview --list
  wfcompanion preview TYPE OUTPUT.png
  wfcompanion preview --all OUTPUT_DIR
  wfcompanion preview --animate TYPE OUTPUT.webm
  wfcompanion preview --animate-all OUTPUT_DIR
  wfcompanion logs
  wfcompanion --relic-screenshot IMAGE

Commands:
  launch             Run Warframe command and keep companion alive with it
  probe              Print detected Warframe process state as JSON
  screenshot         Capture active window or full screen through Spectacle
  relic-ocr          Print OCR candidates from saved or newly captured image
  preview            Render mock overlays onto a transparent output-sized image
  logs               Print incident log path and recent entries

Options:
  -h, --help         Show this help
  --relic-screenshot Start overlay and process a saved image (developer mode)

Environment:
  WFCOMPANION_CAPTURE_DIR      Shared temporary capture directory
  WFCOMPANION_RELIC_SCREENSHOT Saved image used instead of live capture
  WFCOMPANION_SPECTACLE        Spectacle executable path
  WFCOMPANION_TESSERACT        Tesseract executable path
  WFCOMPANION_DEBUG_BRIDGE     Proton DBWIN helper path
  WFCOMPANION_PREVIEW_SIZE     Preview size override as WIDTHxHEIGHT
  WFCOMPANION_KSCREEN_DOCTOR   kscreen-doctor executable path
  WFCOMPANION_FFMPEG           ffmpeg executable path
  WFCOMPANION_LOG              Incident log path
"#;

#[derive(Debug)]
pub(crate) enum UiEvent {
    Connected(Value),
    Disconnected(String),
    Snapshot {
        dataset: String,
        data: Value,
    },
    OverlayVisible(bool),
    HudVisible(bool),
    RelicScene {
        scene: relic::Scene,
        deadline: Option<Instant>,
    },
    RelicDismiss,
    InteractionToggle,
    Shutdown,
}

#[derive(Debug, Eq, PartialEq)]
enum Command {
    Overlay {
        launch: Option<Vec<String>>,
        relic_screenshot: Option<PathBuf>,
    },
    Probe,
    Screenshot {
        target: capture::Target,
        path: PathBuf,
    },
    RelicOcr {
        target: capture::Target,
        path: Option<PathBuf>,
    },
    Preview(PreviewRequest),
    Logs,
    Help,
}

#[derive(Debug, Eq, PartialEq)]
enum PreviewRequest {
    List,
    One { name: String, path: PathBuf },
    All { directory: PathBuf },
    Animate { name: String, path: PathBuf },
    AnimateAll { directory: PathBuf },
}

fn main() -> ExitCode {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    match parse_command(&arguments).and_then(run_command) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            incident::error("command.failed", &error);
            eprintln!("wfcompanion: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run_command(command: Command) -> Result<(), String> {
    match command {
        Command::Help => {
            print!("{HELP}");
            Ok(())
        }
        Command::Probe => {
            println!(
                "{}",
                serde_json::to_string(&observer::find_warframe()).unwrap()
            );
            Ok(())
        }
        Command::Logs => incident::print_recent(100),
        Command::Screenshot { target, path } => {
            let (width, height) = capture::save(target, &path)?;
            println!("saved {} ({width}x{height})", path.display());
            Ok(())
        }
        Command::RelicOcr { target, path } => {
            let report = match path {
                Some(path) => relic::diagnose(&path)?,
                None => {
                    let image = capture::capture(target)?;
                    relic::diagnose_image(&image, serde_json::Value::String("capture".to_owned()))?
                }
            };
            println!(
                "{}",
                serde_json::to_string_pretty(&report)
                    .map_err(|error| format!("could not format OCR report: {error}"))?
            );
            Ok(())
        }
        Command::Preview(PreviewRequest::List) => {
            for name in preview::names() {
                println!("{name}");
            }
            Ok(())
        }
        Command::Preview(request) => {
            let dimensions = preview::current_dimensions()?;
            for path in preview::render(request, dimensions)? {
                println!(
                    "saved {} ({}x{})",
                    path.display(),
                    dimensions.0,
                    dimensions.1
                );
            }
            Ok(())
        }
        Command::Overlay {
            launch,
            relic_screenshot,
        } => run_overlay(launch, relic_screenshot),
    }
}

fn run_overlay(
    launch_command: Option<Vec<String>>,
    relic_screenshot: Option<PathBuf>,
) -> Result<(), String> {
    let stopping = Arc::new(AtomicBool::new(false));
    let (ui_tx, ui_rx) = mpsc::channel();
    let mode = if launch_command.is_some() {
        "launch"
    } else {
        "standalone"
    };
    incident::info(
        "process.start",
        format!("mode={mode} version={}", env!("WFCLI_VERSION")),
    );
    let outbound = daemon::spawn(ui_tx.clone(), Arc::clone(&stopping), mode);
    let (relic_tx, relic_rx) = mpsc::channel();
    observer::spawn(outbound.clone(), relic_tx.clone(), Arc::clone(&stopping));
    relic::spawn(relic_rx, outbound, ui_tx.clone(), Arc::clone(&stopping));
    if let Some(path) = relic_screenshot {
        let _ = relic_tx.send(relic::Trigger::Screenshot(path));
    }
    if let Some(command) = launch_command {
        spawn_game(command, ui_tx.clone());
    }

    let shortcut = shortcut::spawn(ui_tx);
    let result = overlay::run(ui_rx, shortcut, Arc::clone(&stopping));
    stopping.store(true, Ordering::Relaxed);
    incident::info("process.stop", format!("mode={mode}"));
    result.map_err(|error| error.to_string())
}

fn parse_command(arguments: &[String]) -> Result<Command, String> {
    let Some(command) = arguments.first().map(String::as_str) else {
        return Ok(Command::Overlay {
            launch: None,
            relic_screenshot: None,
        });
    };
    match command {
        "-h" | "--help" | "help" if arguments.len() == 1 => Ok(Command::Help),
        "--probe" | "probe" if arguments.len() == 1 => Ok(Command::Probe),
        "screenshot" => parse_capture_command(&arguments[1..], true),
        "relic-ocr" => parse_capture_command(&arguments[1..], false),
        "preview" => parse_preview_command(&arguments[1..]),
        "logs" if arguments.len() == 1 => Ok(Command::Logs),
        "--relic-screenshot" if arguments.len() == 2 => Ok(Command::Overlay {
            launch: None,
            relic_screenshot: Some(PathBuf::from(&arguments[1])),
        }),
        "launch" => parse_launch_command(&arguments[1..]),
        _ => Err(format!(
            "invalid arguments: {}; run `wfcompanion --help`",
            arguments.join(" ")
        )),
    }
}

fn parse_preview_command(arguments: &[String]) -> Result<Command, String> {
    match arguments {
        [option] if option == "--list" => Ok(Command::Preview(PreviewRequest::List)),
        [option, directory] if option == "--all" => Ok(Command::Preview(PreviewRequest::All {
            directory: PathBuf::from(directory),
        })),
        [option, name, path] if option == "--animate" => {
            Ok(Command::Preview(PreviewRequest::Animate {
                name: name.clone(),
                path: PathBuf::from(path),
            }))
        }
        [option, directory] if option == "--animate-all" => {
            Ok(Command::Preview(PreviewRequest::AnimateAll {
                directory: PathBuf::from(directory),
            }))
        }
        [name, path] if !name.starts_with('-') => Ok(Command::Preview(PreviewRequest::One {
            name: name.clone(),
            path: PathBuf::from(path),
        })),
        _ => Err(
            "preview requires --list, --all OUTPUT_DIR, --animate TYPE OUTPUT.webm, --animate-all OUTPUT_DIR, or TYPE OUTPUT.png"
                .to_owned(),
        ),
    }
}

fn parse_capture_command(arguments: &[String], require_path: bool) -> Result<Command, String> {
    let mut target = capture::Target::Active;
    let mut path = None;
    let mut index = 0;
    while index < arguments.len() {
        match arguments[index].as_str() {
            "--target" if index + 1 < arguments.len() => {
                target = match arguments[index + 1].as_str() {
                    "active" => capture::Target::Active,
                    "screen" => capture::Target::Screen,
                    value => return Err(format!("invalid capture target: {value}")),
                };
                index += 2;
            }
            argument if argument.starts_with('-') => {
                return Err(format!("unknown capture option: {argument}"));
            }
            argument if path.is_none() => {
                path = Some(PathBuf::from(argument));
                index += 1;
            }
            argument => return Err(format!("unexpected capture argument: {argument}")),
        }
    }
    if require_path && path.is_none() {
        return Err("screenshot requires an output path".to_owned());
    }
    if require_path {
        Ok(Command::Screenshot {
            target,
            path: path.unwrap(),
        })
    } else {
        Ok(Command::RelicOcr { target, path })
    }
}

fn parse_launch_command(arguments: &[String]) -> Result<Command, String> {
    let mut command = arguments.to_vec();
    if command.first().is_some_and(|arg| arg == "--") {
        command.remove(0);
    }
    if command.is_empty() {
        Err("launch requires command after --".to_owned())
    } else {
        Ok(Command::Overlay {
            launch: Some(command),
            relic_screenshot: None,
        })
    }
}

fn spawn_game(command: Vec<String>, ui: mpsc::Sender<UiEvent>) {
    thread::spawn(move || {
        let mut child = match ProcessCommand::new(&command[0]).args(&command[1..]).spawn() {
            Ok(child) => child,
            Err(error) => {
                eprintln!("wfcompanion: failed to launch game: {error}");
                let _ = ui.send(UiEvent::Shutdown);
                return;
            }
        };
        let _ = child.wait();
        let _ = ui.send(UiEvent::Shutdown);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn arguments(values: &[&str]) -> Vec<String> {
        values.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn parses_steam_launch_wrapper() {
        assert_eq!(
            parse_command(&arguments(&["launch", "--", "/game", "arg"])),
            Ok(Command::Overlay {
                launch: Some(arguments(&["/game", "arg"])),
                relic_screenshot: None,
            })
        );
    }

    #[test]
    fn parses_diagnostic_commands() {
        assert_eq!(
            parse_command(&arguments(&["screenshot", "capture.png"])),
            Ok(Command::Screenshot {
                target: capture::Target::Active,
                path: PathBuf::from("capture.png"),
            })
        );
        assert_eq!(
            parse_command(&arguments(&["preview", "relic-rewards", "preview.png"])),
            Ok(Command::Preview(PreviewRequest::One {
                name: "relic-rewards".to_owned(),
                path: PathBuf::from("preview.png"),
            }))
        );
        assert_eq!(
            parse_command(&arguments(&["preview", "--all", "previews"])),
            Ok(Command::Preview(PreviewRequest::All {
                directory: PathBuf::from("previews"),
            }))
        );
        assert_eq!(
            parse_command(&arguments(&[
                "preview",
                "--animate",
                "relic-loading",
                "preview.webm",
            ])),
            Ok(Command::Preview(PreviewRequest::Animate {
                name: "relic-loading".to_owned(),
                path: PathBuf::from("preview.webm"),
            }))
        );
        assert_eq!(
            parse_command(&arguments(&["relic-ocr", "rewards.jpg"])),
            Ok(Command::RelicOcr {
                target: capture::Target::Active,
                path: Some(PathBuf::from("rewards.jpg")),
            })
        );
    }

    #[test]
    fn parses_full_screen_capture_and_live_ocr() {
        assert_eq!(
            parse_command(&arguments(&[
                "screenshot",
                "--target",
                "screen",
                "capture.png"
            ])),
            Ok(Command::Screenshot {
                target: capture::Target::Screen,
                path: PathBuf::from("capture.png"),
            })
        );
        assert_eq!(
            parse_command(&arguments(&["relic-ocr", "--target", "screen"])),
            Ok(Command::RelicOcr {
                target: capture::Target::Screen,
                path: None,
            })
        );
    }

    #[test]
    fn rejects_empty_launch_command() {
        assert_eq!(
            parse_command(&arguments(&["launch", "--"])),
            Err("launch requires command after --".to_owned())
        );
    }
}
