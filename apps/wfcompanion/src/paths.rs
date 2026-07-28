use std::fs;
use std::path::{Path, PathBuf};

pub(crate) fn print() -> Result<(), String> {
    println!("wfcompanion");
    print_path("cache", &crate::capture::capture_dir());
    print_path("state", parent(&crate::incident::log_path())?);
    print_path("runtime", parent(&crate::daemon::daemon_socket_path())?);
    print_path("data", parent(&crate::desktop::identity_path()?)?);
    Ok(())
}

fn parent(path: &Path) -> Result<&Path, String> {
    path.parent()
        .ok_or_else(|| format!("path has no parent: {}", path.display()))
}

fn print_path(kind: &str, path: &Path) {
    print!("  {kind:<8} {}", path.display());
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => match fs::read_link(path) {
            Ok(target) => println!(" -> {}", absolute_target(path, &target).display()),
            Err(error) => println!(" (error: {error})"),
        },
        Ok(metadata) if metadata.is_dir() => println!(),
        Ok(metadata) if metadata.is_file() => println!(" (file)"),
        Ok(_) => println!(" (other)"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => println!(" (missing)"),
        Err(error) => println!(" (error: {error})"),
    }
}

fn absolute_target(path: &Path, target: &Path) -> PathBuf {
    if target.is_absolute() {
        target.to_owned()
    } else {
        path.parent().unwrap_or_else(|| Path::new(".")).join(target)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relative_symlink_target_uses_link_parent() {
        assert_eq!(
            absolute_target(Path::new("/tmp/link"), Path::new("target")),
            PathBuf::from("/tmp/target")
        );
    }
}
