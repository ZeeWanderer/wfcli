use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::io::Read;
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use image::{DynamicImage, ImageFormat, RgbaImage};
use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::{Fd, OwnedValue};

static CAPTURE_SEQUENCE: AtomicU64 = AtomicU64::new(1);
const CAPTURE_WAIT: Duration = Duration::from_secs(3);
const KWIN_SERVICE: &str = "org.kde.KWin";
const KWIN_SCREENSHOT_PATH: &str = "/org/kde/KWin/ScreenShot2";
const KWIN_SCREENSHOT_INTERFACE: &str = "org.kde.KWin.ScreenShot2";
const KWIN_PATH: &str = "/KWin";
const KWIN_INTERFACE: &str = "org.kde.KWin";
const KWIN_RUNNER_PATH: &str = "/WindowsRunner";
const KWIN_RUNNER_INTERFACE: &str = "org.kde.krunner1";
const WARFRAME_RESOURCE_CLASS: &str = "steam_app_230410";
const QIMAGE_FORMAT_RGB32: u32 = 4;
const QIMAGE_FORMAT_ARGB32: u32 = 5;
const QIMAGE_FORMAT_ARGB32_PREMULTIPLIED: u32 = 6;
static WARFRAME_WINDOW_ID: OnceLock<Mutex<Option<String>>> = OnceLock::new();

type RunnerMatch = (
    String,
    String,
    String,
    i32,
    f64,
    HashMap<String, OwnedValue>,
);

pub(crate) fn relic_window() -> Result<DynamicImage, String> {
    if let Some(path) = std::env::var_os("WFCOMPANION_RELIC_SCREENSHOT") {
        return load(Path::new(&path));
    }

    capture()
}

pub(crate) fn capture() -> Result<DynamicImage, String> {
    capture_warframe()
}

pub(crate) fn save(path: &Path) -> Result<(u32, u32), String> {
    let image = capture()?;
    let dimensions = (image.width(), image.height());
    image
        .save_with_format(path, ImageFormat::Png)
        .map_err(|error| format!("could not write {}: {error}", path.display()))?;
    Ok(dimensions)
}

fn capture_warframe() -> Result<DynamicImage, String> {
    crate::desktop::ensure_identity()
        .map_err(|error| format!("desktop screenshot identity: {error}"))?;
    let connection = Connection::session()
        .map_err(|error| format!("could not connect to session D-Bus: {error}"))?;
    let cached = warframe_window_id().lock().unwrap().clone();
    if let Some(window_id) = cached {
        if let Ok(image) = capture_window(&connection, &window_id) {
            return Ok(image);
        }
        *warframe_window_id().lock().unwrap() = None;
    }

    let window_id = find_warframe_window(&connection)?;
    let image = capture_window(&connection, &window_id)?;
    *warframe_window_id().lock().unwrap() = Some(window_id);
    Ok(image)
}

fn capture_window(connection: &Connection, window_id: &str) -> Result<DynamicImage, String> {
    let proxy = screenshot_proxy(connection)?;
    let (mut reader, writer) = capture_pipe()?;
    let options = HashMap::<String, OwnedValue>::new();
    let metadata = proxy
        .call(
            "CaptureWindow",
            &(window_id, options, Fd::from(writer.as_fd())),
        )
        .map_err(|error| format!("KWin Warframe screenshot failed: {error}"))?;
    drop(writer);
    read_raw_image(&mut reader, metadata)
}

fn find_warframe_window(connection: &Connection) -> Result<String, String> {
    let runner = Proxy::new(
        connection,
        KWIN_SERVICE,
        KWIN_RUNNER_PATH,
        KWIN_RUNNER_INTERFACE,
    )
    .map_err(|error| format!("KWin window runner unavailable: {error}"))?;
    let matches: Vec<RunnerMatch> = runner
        .call("Match", &(WARFRAME_RESOURCE_CLASS,))
        .map_err(|error| format!("could not find Warframe window: {error}"))?;
    let kwin = Proxy::new(connection, KWIN_SERVICE, KWIN_PATH, KWIN_INTERFACE)
        .map_err(|error| format!("KWin window interface unavailable: {error}"))?;

    for (id, _, _, _, _, _) in matches {
        let Some(window_id) = runner_window_id(&id) else {
            continue;
        };
        let info: HashMap<String, OwnedValue> = kwin
            .call("getWindowInfo", &(window_id,))
            .map_err(|error| format!("could not inspect Warframe window: {error}"))?;
        if metadata_str(&info, "resourceClass") == Some(WARFRAME_RESOURCE_CLASS) {
            return Ok(window_id.trim_matches(['{', '}']).to_owned());
        }
    }
    Err("Warframe window not found".to_owned())
}

fn runner_window_id(match_id: &str) -> Option<&str> {
    let (action, window_id) = match_id.split_once('_')?;
    (action == "0").then(|| window_id.trim_matches(['{', '}']))
}

fn warframe_window_id() -> &'static Mutex<Option<String>> {
    WARFRAME_WINDOW_ID.get_or_init(|| Mutex::new(None))
}

fn screenshot_proxy(connection: &Connection) -> Result<Proxy<'_>, String> {
    Proxy::new(
        connection,
        KWIN_SERVICE,
        KWIN_SCREENSHOT_PATH,
        KWIN_SCREENSHOT_INTERFACE,
    )
    .map_err(|error| format!("KWin screenshot interface unavailable: {error}"))
}

fn capture_pipe() -> Result<(UnixStream, UnixStream), String> {
    let (reader, writer) =
        UnixStream::pair().map_err(|error| format!("could not create screenshot pipe: {error}"))?;
    reader
        .set_read_timeout(Some(CAPTURE_WAIT))
        .map_err(|error| format!("could not configure screenshot pipe: {error}"))?;
    Ok((reader, writer))
}

fn read_raw_image(
    reader: &mut UnixStream,
    metadata: HashMap<String, OwnedValue>,
) -> Result<DynamicImage, String> {
    let width = metadata_u32(&metadata, "width")?;
    let height = metadata_u32(&metadata, "height")?;
    let stride = metadata_u32(&metadata, "stride")?;
    let format = metadata_u32(&metadata, "format")?;
    let row_bytes = width
        .checked_mul(4)
        .ok_or_else(|| "KWin screenshot width overflow".to_owned())?;
    if stride < row_bytes {
        return Err(format!(
            "KWin screenshot stride {stride} is smaller than row size {row_bytes}"
        ));
    }
    let byte_count = usize::try_from(
        stride
            .checked_mul(height)
            .ok_or_else(|| "KWin screenshot size overflow".to_owned())?,
    )
    .map_err(|_| "KWin screenshot is too large".to_owned())?;
    let mut raw = vec![0; byte_count];
    reader
        .read_exact(&mut raw)
        .map_err(|error| format!("could not read KWin screenshot pixels: {error}"))?;
    qimage_to_rgba(raw, width, height, stride, format).map(DynamicImage::ImageRgba8)
}

fn metadata_u32(metadata: &HashMap<String, OwnedValue>, key: &str) -> Result<u32, String> {
    metadata
        .get(key)
        .and_then(|value| u32::try_from(value).ok())
        .ok_or_else(|| format!("KWin screenshot metadata has no valid {key}"))
}

fn metadata_str<'a>(metadata: &'a HashMap<String, OwnedValue>, key: &str) -> Option<&'a str> {
    metadata
        .get(key)
        .and_then(|value| <&str>::try_from(value).ok())
}

fn qimage_to_rgba(
    raw: Vec<u8>,
    width: u32,
    height: u32,
    stride: u32,
    format: u32,
) -> Result<RgbaImage, String> {
    if cfg!(target_endian = "big") {
        return Err("KWin screenshot conversion does not support big-endian targets".to_owned());
    }
    if !matches!(
        format,
        QIMAGE_FORMAT_RGB32 | QIMAGE_FORMAT_ARGB32 | QIMAGE_FORMAT_ARGB32_PREMULTIPLIED
    ) {
        return Err(format!("unsupported KWin QImage format {format}"));
    }
    let mut rgba = Vec::with_capacity(width as usize * height as usize * 4);
    for row in raw.chunks_exact(stride as usize).take(height as usize) {
        for pixel in row[..width as usize * 4].chunks_exact(4) {
            let alpha = if format == QIMAGE_FORMAT_RGB32 {
                255
            } else {
                pixel[3]
            };
            let (red, green, blue) =
                if format == QIMAGE_FORMAT_ARGB32_PREMULTIPLIED && alpha > 0 && alpha < 255 {
                    (
                        unpremultiply(pixel[2], alpha),
                        unpremultiply(pixel[1], alpha),
                        unpremultiply(pixel[0], alpha),
                    )
                } else {
                    (pixel[2], pixel[1], pixel[0])
                };
            rgba.extend_from_slice(&[red, green, blue, alpha]);
        }
    }
    RgbaImage::from_raw(width, height, rgba)
        .ok_or_else(|| "could not construct image from KWin screenshot".to_owned())
}

fn unpremultiply(channel: u8, alpha: u8) -> u8 {
    ((u16::from(channel) * 255 + u16::from(alpha) / 2) / u16::from(alpha)).min(255) as u8
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

fn load(path: &Path) -> Result<DynamicImage, String> {
    image::open(path).map_err(|error| format!("could not read {}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn converts_premultiplied_bgra_with_stride() {
        let raw = vec![25, 50, 100, 128, 0, 0, 0, 0, 10, 20, 30, 255, 0, 0, 0, 0];
        let image = qimage_to_rgba(raw, 1, 2, 8, QIMAGE_FORMAT_ARGB32_PREMULTIPLIED).unwrap();
        assert_eq!(image.get_pixel(0, 0).0, [199, 100, 50, 128]);
        assert_eq!(image.get_pixel(0, 1).0, [30, 20, 10, 255]);
    }

    #[test]
    fn extracts_window_id_from_activate_match() {
        assert_eq!(
            runner_window_id("0_{a2ca4507-2eba-4167-a14f-30b22808bc4c}"),
            Some("a2ca4507-2eba-4167-a14f-30b22808bc4c")
        );
        assert_eq!(runner_window_id("2_{uuid}"), None);
        assert_eq!(runner_window_id("invalid"), None);
    }
}
