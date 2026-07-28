use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use image::{DynamicImage, ImageFormat};

static CAPTURE_SEQUENCE: AtomicU64 = AtomicU64::new(1);
const CAPTURE_WAIT: Duration = Duration::from_secs(3);
const CAPTURE_RETRY: Duration = Duration::from_millis(50);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Target {
    Active,
    Screen,
}

pub(crate) fn active_window() -> Result<DynamicImage, String> {
    if let Some(path) = std::env::var_os("WFCOMPANION_RELIC_SCREENSHOT") {
        return load(Path::new(&path));
    }

    spectacle_capture(Target::Active)
}

pub(crate) fn capture(target: Target) -> Result<DynamicImage, String> {
    spectacle_capture(target)
}

pub(crate) fn save(target: Target, path: &Path) -> Result<(u32, u32), String> {
    let image = spectacle_capture(target)?;
    let dimensions = (image.width(), image.height());
    image
        .save_with_format(path, ImageFormat::Png)
        .map_err(|error| format!("could not write {}: {error}", path.display()))?;
    Ok(dimensions)
}

fn spectacle_capture(target: Target) -> Result<DynamicImage, String> {
    let spectacle = crate::external::resolve(
        "WFCOMPANION_SPECTACLE",
        "spectacle",
        option_env!("WFCOMPANION_BUILD_SPECTACLE"),
        &[
            PathBuf::from("/usr/bin/spectacle"),
            PathBuf::from("/usr/local/bin/spectacle"),
        ],
    );
    spectacle_capture_with(&spectacle, target)
}

fn spectacle_capture_with(spectacle: &OsStr, target: Target) -> Result<DynamicImage, String> {
    let path = temporary_png("capture")?;
    let mut command = Command::new(spectacle);
    command.args(["--background", "--nonotify"]);
    match target {
        Target::Active => {
            command.args(["--activewindow", "--no-decoration"]);
        }
        Target::Screen => {
            command.arg("--fullscreen");
        }
    }
    let output = command
        .arg("--output")
        .arg(&path)
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("could not run spectacle: {error}"))?;
    if !output.status.success() {
        let _ = fs::remove_file(&path);
        let message = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return Err(if message.is_empty() {
            format!("spectacle exited with {}", output.status)
        } else {
            format!("spectacle: {message}")
        });
    }

    let result = wait_for_image(&path);
    let _ = fs::remove_file(&path);
    result
}

pub(crate) fn temporary_png(label: &str) -> Result<PathBuf, String> {
    let directory = capture_dir();
    fs::create_dir_all(&directory).map_err(|error| {
        format!(
            "could not create capture directory {}: {error}",
            directory.display()
        )
    })?;
    let sequence = CAPTURE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    Ok(directory.join(format!(
        "wfcompanion-{label}-{}-{sequence}.png",
        std::process::id()
    )))
}

pub(crate) fn capture_dir() -> PathBuf {
    #[cfg(test)]
    if std::env::var_os("WFCOMPANION_CAPTURE_DIR").is_none() {
        return std::env::temp_dir().join("wfcli/captures");
    }
    capture_dir_from(
        std::env::var_os("WFCOMPANION_CAPTURE_DIR").as_deref(),
        std::env::var_os("XDG_CACHE_HOME").as_deref(),
        std::env::var_os("HOME").as_deref(),
        &std::env::temp_dir(),
    )
}

fn capture_dir_from(
    override_dir: Option<&OsStr>,
    xdg_cache: Option<&OsStr>,
    home: Option<&OsStr>,
    temp: &Path,
) -> PathBuf {
    if let Some(directory) = override_dir {
        return PathBuf::from(directory);
    }
    if let Some(directory) = xdg_cache {
        return PathBuf::from(directory).join("wfcli/captures");
    }
    if let Some(directory) = home {
        return PathBuf::from(directory).join(".cache/wfcli/captures");
    }
    temp.join("wfcli/captures")
}

fn wait_for_image(path: &Path) -> Result<DynamicImage, String> {
    let deadline = Instant::now() + CAPTURE_WAIT;
    loop {
        match load(path) {
            Ok(image) => return Ok(image),
            Err(error) if Instant::now() < deadline => {
                let _ = error;
                thread::sleep(CAPTURE_RETRY);
            }
            Err(error) => {
                return Err(format!(
                    "{error}; spectacle exited successfully but capture was not readable after {} ms",
                    CAPTURE_WAIT.as_millis()
                ));
            }
        }
    }
}

fn load(path: &Path) -> Result<DynamicImage, String> {
    image::open(path).map_err(|error| format!("could not read {}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn capture_directory_prefers_shared_user_cache() {
        assert_eq!(
            capture_dir_from(None, Some(OsStr::new("/cache")), None, Path::new("/tmp")),
            PathBuf::from("/cache/wfcli/captures")
        );
        assert_eq!(
            capture_dir_from(
                None,
                None,
                Some(OsStr::new("/home/test")),
                Path::new("/tmp")
            ),
            PathBuf::from("/home/test/.cache/wfcli/captures")
        );
    }

    #[test]
    fn capture_directory_override_wins() {
        assert_eq!(
            capture_dir_from(
                Some(OsStr::new("/shared")),
                Some(OsStr::new("/cache")),
                Some(OsStr::new("/home/test")),
                Path::new("/tmp")
            ),
            PathBuf::from("/shared")
        );
    }

    #[test]
    fn waits_for_delayed_capture_write() {
        let path = temporary_png("delayed-test").unwrap();
        let writer_path = path.clone();
        let writer = thread::spawn(move || {
            thread::sleep(Duration::from_millis(100));
            DynamicImage::new_rgb8(8, 6)
                .save_with_format(writer_path, ImageFormat::Png)
                .unwrap();
        });
        let image = wait_for_image(&path).unwrap();
        writer.join().unwrap();
        let _ = fs::remove_file(path);
        assert_eq!((image.width(), image.height()), (8, 6));
    }

    #[cfg(unix)]
    #[test]
    fn spectacle_capture_reads_requested_output_path() {
        let fixture = std::env::temp_dir().join(format!(
            "wfcompanion-fake-capture-{}.png",
            std::process::id()
        ));
        DynamicImage::new_rgb8(8, 6)
            .save_with_format(&fixture, ImageFormat::Png)
            .unwrap();
        let script = std::env::temp_dir().join(format!(
            "wfcompanion-fake-spectacle-{}.sh",
            std::process::id()
        ));
        fs::write(
            &script,
            format!(
                "#!/bin/sh\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = --output ]; then\n    shift\n    cp -- '{}' \"$1\"\n    exit $?\n  fi\n  shift\ndone\nexit 2\n",
                fixture.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        let image = spectacle_capture_with(script.as_os_str(), Target::Active).unwrap();
        let _ = fs::remove_file(script);
        let _ = fs::remove_file(fixture);
        assert_eq!((image.width(), image.height()), (8, 6));
    }

    #[cfg(unix)]
    #[test]
    fn full_screen_capture_uses_fullscreen_flag() {
        let arguments = std::env::temp_dir().join(format!(
            "wfcompanion-fake-spectacle-args-{}.txt",
            std::process::id()
        ));
        let script = std::env::temp_dir().join(format!(
            "wfcompanion-fake-spectacle-screen-{}.sh",
            std::process::id()
        ));
        fs::write(
            &script,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{}'\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = --output ]; then\n    shift\n    printf 'not-an-image' > \"$1\"\n    exit 1\n  fi\n  shift\ndone\nexit 2\n",
                arguments.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(spectacle_capture_with(script.as_os_str(), Target::Screen).is_err());
        let captured = fs::read_to_string(&arguments).unwrap();
        let _ = fs::remove_file(script);
        let _ = fs::remove_file(arguments);
        assert!(captured.lines().any(|argument| argument == "--fullscreen"));
        assert!(
            !captured
                .lines()
                .any(|argument| argument == "--activewindow")
        );
    }
}
