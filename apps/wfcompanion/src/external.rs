use std::ffi::{OsStr, OsString};
use std::path::PathBuf;

pub(crate) fn resolve(
    environment: &str,
    executable: &str,
    build_path: Option<&str>,
    extra_paths: &[PathBuf],
) -> OsString {
    if let Some(configured) = std::env::var_os(environment)
        && !configured.is_empty()
    {
        return configured;
    }
    candidate_paths(
        std::env::var_os("PATH").as_deref(),
        executable,
        build_path,
        extra_paths,
    )
    .into_iter()
    .find(|path| path.is_file())
    .map(PathBuf::into_os_string)
    .unwrap_or_else(|| OsString::from(executable))
}

fn candidate_paths(
    path: Option<&OsStr>,
    executable: &str,
    build_path: Option<&str>,
    extra_paths: &[PathBuf],
) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(path) = path {
        for directory in std::env::split_paths(path) {
            push_unique(&mut candidates, directory.join(executable));
        }
    }
    if let Some(build_path) = build_path
        && !build_path.is_empty()
    {
        push_unique(&mut candidates, PathBuf::from(build_path));
    }
    for path in extra_paths {
        push_unique(&mut candidates, path.clone());
    }
    candidates
}

fn push_unique(candidates: &mut Vec<PathBuf>, candidate: PathBuf) {
    if !candidate.as_os_str().is_empty() && !candidates.contains(&candidate) {
        candidates.push(candidate);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn candidate_order_survives_restricted_runtime_path() {
        let path = std::env::join_paths([Path::new("/steam/bin")]).unwrap();
        let candidates = candidate_paths(
            Some(&path),
            "tesseract",
            Some("/build/tesseract"),
            &[PathBuf::from("/known/tesseract")],
        );
        assert_eq!(
            candidates,
            vec![
                PathBuf::from("/steam/bin/tesseract"),
                PathBuf::from("/build/tesseract"),
                PathBuf::from("/known/tesseract"),
            ]
        );
    }
}
