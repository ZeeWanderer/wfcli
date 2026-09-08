pub mod game_observer;
pub mod inspect;
pub mod local_protocol;

pub fn executable_path() -> Option<&'static std::path::Path> {
    static PATH: std::sync::OnceLock<Option<std::path::PathBuf>> = std::sync::OnceLock::new();
    // Directory exchange changes /proc/self/exe; helper lookup must keep the startup prefix.
    PATH.get_or_init(|| std::env::current_exe().ok()).as_deref()
}
